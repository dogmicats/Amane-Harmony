"""search 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class SearchMixin(object):
    @route("GET", r"/api/user/suggest")
    def suggest(self, query, *_) -> None:
        """搜索联想：输入即搜，准确优先、模糊递进。

        三档递进（客户端按返回顺序直接渲染，tier 只是排序键）：
          1 精确：番号去连字符后等于 / 前缀命中，或标题以关键词开头；
          2 模糊：番号 / 标题包含关键词；
          3 扩大：演员 / 系列 / 制片商命中，或拆词后任一词命中。

        `types` 是「这一次搜哪些类型」的多选：film / actor / director / tag /
        series / studio，逗号分隔。**不带这个参数就只搜影片、返回结构与旧版逐字段
        一致**（2.2.14 及以前的客户端不认识 type/name，多给的实体行会被它画成空卡）。
        演员 / 导演 / 标签这些实体不在这里直连表：核心通过 `suggest_entities`
        钩子问扩展要，关掉对应扩展就自然没有那一类。
        """
        raw = ((query.get("q") or [""])[0]).strip()
        if not raw:
            return self._json({"items": [], "q": raw, "types": [], "supported": []})

        asked = {x.strip().lower() for x in (query.get("types") or [""])[0].split(",") if x.strip()}
        kinds = [k for k in SUGGEST_KINDS if k in asked] or ["film"]
        try:
            per = max(1, min(20, int((query.get("per") or ["6"])[0])))
        except ValueError:
            per = 6
        # 只搜影片时保持旧的 14 条上限；混搜时给实体让几个位置。
        limit = 14 if kinds == ["film"] else 10

        # 检索归一化（2.5.1）：繁体先转简体。`raw` 保留原文（回显 + 番号大小写），
        # `raw_q` 之后全部用它 —— 用户打「癡女」时，「痴女」标签也要能联想出来。
        raw_q = norm_query(raw)
        norm = re.sub(r"[\s\-_/]+", "", raw_q).upper()
        tokens = [t for t in re.split(r"[\s\-_/]+", raw_q) if t][:6]
        picked: dict[int, tuple] = {}

        def grab(tier: int, where: str, params: tuple, cap: int,
                 order: str = "LENGTH(m.number), m.id") -> None:
            if len(picked) >= limit or not params:
                return
            try:
                with amane_db() as conn:
                    rows = conn.execute(
                        f"SELECT {META_COLUMNS} FROM metadata m "
                        "JOIN (SELECT DISTINCT metadata_id FROM media_files) f ON f.metadata_id = m.id "
                        f"WHERE {where} ORDER BY {order} LIMIT ?",
                        (*params, cap),
                    ).fetchall()
            except sqlite3.Error as exc:
                log(f"WARN suggest: {exc}")
                return
            for r in rows:
                if len(picked) >= limit:
                    break  # 档位之间也要守住上限，否则 8+4+10 会溢出到 20 多条
                if r["id"] in picked:
                    continue
                picked[r["id"]] = (tier, len(picked), item_of(r))

        # 拼音解析出来的中文名：既用来找影片（下面是 2c 档），也用来问扩展要实体行。
        # 用户打「scg」，扩展按字面 LIKE 找不到「搜查官」，只能由核心把名字翻译好再交给它。
        py_names: list[str] = []

        if norm and "film" in kinds:
            # 1) 番号精确 / 前缀；标题开头
            grab(1, "REPLACE(UPPER(m.number), '-', '') LIKE ?", (norm + "%",), 8)
            grab(1, "UPPER(m.title) LIKE ?", (raw_q.upper() + "%",), 4)
            # 2a) 演员别名回查：metadata.actors 存的是规范名（つぼみ），别名「蕾」只在
            #     actor_aliases 里，普通条件命中不了。核心不认演员表，让扩展把别名解析成
            #     影片 id 交回来，这里只负责「这些 id 也要出现」。
            #     必须排在「标题包含」之前：蕾 是「芭蕾」的一部分，库里有 108 部片标题带它，
            #     先跑标题匹配会把她的 49 部作品全挤掉 —— 用户搜的是人，不是芭蕾。
            alias_ids = [int(i) for i in (EXT.call("suggest_films", raw_q, 4).get("ids") or [])
                         if int(i or 0) > 0]
            if alias_ids and len(picked) < limit:
                # 这批按发行时间倒序：别名命中通常就是「这个人的片」，最新的一部最可能是想找的
                grab(2, f"m.id IN ({','.join('?' * len(alias_ids))})", tuple(alias_ids), 4,
                     "m.release DESC, m.id DESC")
            # 2b) 番号 / 标题包含
            grab(2, "(REPLACE(UPPER(m.number), '-', '') LIKE ? OR UPPER(m.title) LIKE ?)",
                 (f"%{norm}%", f"%{raw_q.upper()}%"), 10)
            # 2c) 拼音命中（2.5.1）：排在上面的番号/标题之后 —— 用户打得出番号就打得出，
            #     打不出番号、只记得中文名（或只会打首字母）时才轮到这里。
            py_cond_sql: list[str] = []
            py_cond_vals: list = []
            for tok in tokens:
                for cond, cond_vals in search_clauses(tok):
                    py_cond_sql.append(cond)
                    py_cond_vals.extend(cond_vals)
                    name = str(cond_vals[0]).strip("%")
                    if name not in py_names and len(py_names) < 3:
                        py_names.append(name)
            if py_cond_sql and len(picked) < limit:
                grab(3, "(" + " OR ".join(py_cond_sql) + ")", tuple(py_cond_vals), 8,
                     "m.release DESC, m.id DESC")
            # 3) 演员 / 系列 / 制片商，或拆词任一命中（扩大范围）
            actor_likes = " OR ".join(["m.actors LIKE ?"] * len(tokens))
            grab(3, f"(m.series LIKE ? OR m.studio LIKE ? OR {actor_likes})",
                 (f"%{raw_q}%", f"%{raw_q}%", *[f"%{t}%" for t in tokens]), 10)

        items = []
        for _, (_, _, item) in sorted(picked.items(), key=lambda kv: (kv[1][0], kv[1][1])):
            item["tier"] = picked[item["id"]][0]
            item["type"] = "film"
            items.append(item)

        # 实体命中：扩展各自查自己的表/上游，返回 {kind: {"total": n, "items": [...]}}。
        entity_kinds = [k for k in kinds if k != "film"]
        totals: dict = {}
        if entity_kinds:
            # 先按用户输入的原文问一次（保持原有行为）；拼音解析出中文名时再补问一次，
            # 这样「scg」能带出「搜查官」这个标签行，而不用核心自己去碰扩展的数据。
            queries: list[str] = [raw_q]
            for name in py_names:
                if name and name != raw_q:
                    queries.append(name)
            merged: dict = {}
            for qy in queries:
                got = EXT.call("suggest_entities", qy, entity_kinds)
                for kind, bucket in (got or {}).items():
                    if not isinstance(bucket, dict):
                        continue
                    # 多轮结果并起来：total 取最大（同一个 kind 的「有多少个」只该往上报大），
                    # items 去重后按顺序拼接，不因为多问了一次就重复出现同一行。
                    cur = merged.setdefault(kind, {"total": 0, "items": []})
                    cur["total"] = max(int(cur["total"]), int(bucket.get("total") or 0))
                    have = {int(h.get("id") or 0) for h in cur["items"] if isinstance(h, dict)}
                    for hit in (bucket.get("items") or []):
                        if isinstance(hit, dict) and int(hit.get("id") or 0) not in have:
                            cur["items"].append(hit)
                            have.add(int(hit.get("id") or 0))
            for kind in entity_kinds:
                bucket = merged.get(kind)
                if not isinstance(bucket, dict):
                    continue
                totals[kind] = int(bucket.get("total") or 0)
                for hit in (bucket.get("items") or [])[:per]:
                    if isinstance(hit, dict) and int(hit.get("id") or 0) > 0:
                        items.append(hit)

        self._json({
            "items": items,
            "q": raw,
            # types 回显「这次真搜了哪几类」，supported 是服务端**全量**能力：
            # 两个都要回，客户端才能分得清「没勾」和「装了但服务端不支持」。
            "types": kinds,
            "supported": suggest_supported(),
            "totals": totals,
            # 检索归一化（2.5.1）：拼音解析出的中文名（没有就是空数组）。
            # 客户端可以用它做「已按拼音匹配到：搜查官」这类提示；老客户端忽略即可。
            "q_pinyin": py_names,
            # 原文与它不同就说明这次做过繁转简
            "q_norm": raw_q,
        })

    @route("GET", r"/api/user/search/history")
    def search_history(self, query, *_) -> None:
        try:
            limit = max(1, min(60, int((query.get("limit") or ["20"])[0])))
        except ValueError:
            limit = 20
        with user_db() as conn:
            rows = conn.execute(
                "SELECT q, hits, used_at FROM search_history ORDER BY used_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({
            "items": [{"q": r["q"], "hits": r["hits"], "usedAt": r["used_at"]} for r in rows],
            "total": total,
        })

    @route("POST", r"/api/user/search/history")
    def search_history_add(self, query, *_) -> None:
        raw = str(self._body().get("q") or "").strip()
        if not raw:
            return self._error(422, "q 必填")
        text = raw[:60]
        # 归一化只用于去重：大小写 / 多余空格不同的算同一条，但展示仍用最后一次输入的原文
        norm = re.sub(r"\s+", " ", text).lower()
        now = now_iso()
        with user_db() as conn:
            conn.execute(
                "INSERT INTO search_history(q, norm, hits, created_at, used_at) VALUES(?,?,1,?,?) "
                "ON CONFLICT(norm) DO UPDATE SET q = excluded.q, hits = hits + 1, "
                "used_at = excluded.used_at",
                (text, norm, now, now),
            )
            conn.execute(
                "DELETE FROM search_history WHERE norm NOT IN ("
                "SELECT norm FROM search_history ORDER BY used_at DESC LIMIT ?)",
                (SEARCH_HISTORY_KEEP,),
            )
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({"ok": True, "total": total})

    @route("DELETE", r"/api/user/search/history")
    def search_history_del(self, query, *_) -> None:
        """带 `q` 删单条，不带 `q` 清空。"""
        text = ((query.get("q") or [""])[0]).strip()
        with user_db() as conn:
            if text:
                conn.execute("DELETE FROM search_history WHERE norm = ?",
                             (re.sub(r"\s+", " ", text).lower(),))
            else:
                conn.execute("DELETE FROM search_history")
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({"ok": True, "total": total})

    @route("GET", r"/api/user/search/reindex")
    def search_index_status(self, query, *_) -> None:
        """看一眼拼音索引建好没有：条目数 + 表在不在。"""
        t = cjk_tables()
        self._json({
            "ok": True,
            "tables": {"t2s": len(t.t2s), "pinyin": len(t.py), "alias": len(t.alias)},
            "names": name_pinyin_count(),
            "qmode": "and|or（browse 的 qmode 参数）",
        })

    @route("POST", r"/api/user/search/reindex")
    def search_reindex(self, query, *_) -> None:
        """重建拼音索引（幂等）。

        什么时候用：新入库一批片子、重新刮削改了标签名、批量改了系列名之后。
        平时不用管 —— 服务启动时发现表空会自己建一次。
        """
        try:
            out = build_name_pinyin()
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR 重建拼音索引: {exc}")
            return self._error(500, f"重建失败：{exc}")
        if not out.get("ok"):
            return self._error(400, str(out.get("reason") or "重建失败"))
        self._json(out)

    @route("GET", r"/api/user/search/misses")
    def miss_list(self, query, *_) -> None:
        """「搜了没搜到」的词 —— 别名页的待办清单。

        为什么要这张表：别名靠用户维护，可用户**不知道该维护什么**。
        与其让他面对一张空表发呆，不如从真实的搜索记录里反推：
        这些词你搜过、严格条件下几乎一条都没有，八成是俗称或错字。
        每条都带上猜出来的候选（按字面重合度，语义猜不出，所以界面上要留「自己找」）。
        """
        try:
            limit = max(1, min(100, int((query.get("limit") or ["40"])[0])))
        except ValueError:
            limit = 40
        only_unhandled = ((query.get("todo") or [""])[0]).strip() == "1"
        with user_db() as conn:
            rows = conn.execute(
                "SELECT q, raw, hits, times, first_at, last_at FROM search_miss "
                "ORDER BY last_at DESC LIMIT ?", (limit,)).fetchall()
        have: dict[str, list[dict]] = {}
        for alias, pairs in cjk_tables().alias.items():
            for kind, target in pairs:
                have.setdefault(target, []).append({"alias": alias, "kind": kind})
        for alias, pairs in extra_aliases().items():
            for kind, target in pairs:
                have.setdefault(target, []).append({"alias": alias, "kind": kind})
        items: list[dict] = []
        for r in rows:
            cands = alias_candidates(str(r["raw"] or r["q"]))
            for c in cands:
                c["aliases"] = have.get(str(c["target"]), [])
            handled = any(c["aliases"] for c in cands)
            if only_unhandled and handled:
                continue
            items.append({
                "q": r["q"],
                "raw": r["raw"],
                "hits": int(r["hits"]),
                "times": int(r["times"]),
                "last_at": r["last_at"],
                "candidates": cands,
                # 候选里已经有别名的，说明这条基本处理过了，界面上可以沉下去
                "handled": handled,
            })
        self._json({"items": items, "total": len(items)})

    @route("DELETE", r"/api/user/search/misses")
    def miss_del(self, query, *_) -> None:
        """`?q=` 删一条（不想管 / 已经加过别名）；不带就清空。"""
        q = ((query.get("q") or [""])[0]).strip().lower()
        with user_db() as conn:
            if q:
                conn.execute("DELETE FROM search_miss WHERE q = ?", (q,))
            else:
                conn.execute("DELETE FROM search_miss")
            left = conn.execute("SELECT COUNT(*) FROM search_miss").fetchone()[0]
        self._json({"ok": True, "total": left})

    @route("GET", r"/api/user/search/aliases")
    def alias_list(self, query, *_) -> None:
        """列出全部别名。`films` 是目标名在库里挂了多少部片 —— 一眼看出这条有没有用。

        `?target=名字` 只回指向这个名字的别名：详情页要显示「又名：搜查官」时用，
        客户端也可以一次拉全量自己映射（别名一共就几十条）。
        """
        merged: list[dict] = []
        seen: set[tuple] = set()
        builtin = cjk_tables().alias
        for alias, pairs in builtin.items():
            for kind, target in pairs:
                if (alias, kind, target) in seen:
                    continue
                seen.add((alias, kind, target))
                merged.append({"alias": alias, "kind": kind, "target": target,
                               "source": "builtin"})
        for alias, pairs in extra_aliases().items():
            for kind, target in pairs:
                if (alias, kind, target) in seen:
                    continue
                seen.add((alias, kind, target))
                merged.append({"alias": alias, "kind": kind, "target": target,
                               "source": "user"})
        counts = _alias_film_counts(merged)
        for item in merged:
            item["films"] = counts.get((item["kind"], item["target"]), 0)
        want_target = ((query.get("target") or [""])[0]).strip()
        if want_target:
            merged = [x for x in merged if str(x["target"]) == want_target]
        merged.sort(key=lambda x: (-int(x["films"]), x["alias"]))
        # 折叠别名（写法差异）不进这个列表：它有一千多条，全倒出来只会淹没人加的。
        # 但页面上要让人知道「有一部分已经自动处理了」，所以回个数字。
        try:
            with user_db() as conn:
                variants = int(conn.execute(
                    "SELECT COUNT(*) FROM name_variant").fetchone()[0])
        except sqlite3.Error:
            variants = 0
        self._json({"items": merged, "total": len(merged), "variants": variants})

    @route("GET", r"/api/user/search/expand")
    def expand(self, query, *_) -> None:
        """`?q=词` → 这个词现在命中了哪些名字 + 哪些看起来是同一个东西却没算进来。

        别名要解决的不止「搜不到」，还有「只搜到一半」：
        搜「搜查官」出 188 部，可库里还有个标签叫「女捜查官」（67 部，捜 是日文写法），
        一个字之差就不在这次结果里。这类缺口是**字面**能看见的，所以能提示；
        而语义上的等号（搜查官 = 女检察官）看不见，那部分只能靠人。
        """
        raw = ((query.get("q") or [""])[0]).strip()
        if not raw:
            return self._json({"q": "", "matched": [], "missing": [], "total": 0})
        hit = names_hit_by(raw)
        counts = _alias_film_counts(
            [{"kind": k, "target": n} for k, n in hit])
        matched = [{"kind": k, "target": n, "films": counts.get((k, n), 0)}
                   for k, n in hit]
        missing = missing_names(raw)
        self._json({
            "q": raw,
            "q_norm": norm_query(raw),
            "matched": matched,
            "missing": missing,
            "total": len(missing),
        })

    @route("POST", r"/api/user/search/aliases")
    def alias_add(self, query, *_) -> None:
        """body：`{alias, target, kind?}` 或 `{alias, targets:[{kind,target}, …]}`。

        `target` 必须是库里真实存在的名字（否则别名指不到任何片，加了等于没加），
        这里会先核一遍，核不到就 404，并把「最像的几个」带回去方便纠错。

        `targets`（2.5.1.15 起）：**一个俗称挂多个名字**。别名要解决的不止「搜不到」，
        还有「一个说法对应好几个标签」（ntr → 寝取 + 寝取り・寝取られ・NTR），
        批量提交比让客户端循环 POST 更省事，也不会出现「一半成功一半失败」。
        """
        body = self._body() or {}
        alias = str(body.get("alias") or "").strip()
        kind_default = str(body.get("kind") or "tag").strip().lower()
        if not alias:
            return self._error(422, "alias 必填")
        if len(alias) > 40:
            return self._error(422, "俗称太长了（上限 40 字）")

        specs: list[tuple[str, str]] = []
        raw_targets = body.get("targets")
        if isinstance(raw_targets, list) and raw_targets:
            for item in raw_targets:
                if isinstance(item, dict):
                    kind = str(item.get("kind") or kind_default).strip().lower()
                    target = str(item.get("target") or "").strip()
                else:
                    kind = kind_default
                    target = str(item or "").strip()
                if target:
                    specs.append((kind, target))
        else:
            target = str(body.get("target") or "").strip()
            if target:
                specs.append((kind_default, target))
        if not specs:
            return self._error(422, "target 或 targets 必填")

        bad: list[dict] = []
        for kind, target in specs:
            if kind not in _PY_COND:
                return self._error(422, "kind 只能是 tag / series / actor")
            if len(target) > 80:
                return self._error(422, "名字太长了（上限 80 字）")
            exists, hint = _alias_target_exists(kind, target)
            if not exists:
                bad.append({"kind": kind, "target": target, "hint": hint})
        if bad:
            # 一个都不写：部分成功最难排查（用户以为全加上了）
            first = bad[0]
            msg = f"库里没有名为「{first['target']}」的{_ALIAS_KIND_CN.get(first['kind'], first['kind'])}"
            if first["hint"]:
                msg += f"，你是不是想找：{' / '.join(first['hint'])}"
            if len(bad) > 1:
                msg += f"（还有 {len(bad) - 1} 个名字也没找到）"
            return self._error(404, msg)

        with user_db() as conn:
            conn.executemany(
                "INSERT OR REPLACE INTO search_alias(alias, kind, target, created_at) "
                "VALUES(?,?,?,?)",
                [(alias, kind, target, now_iso()) for kind, target in specs])
        reset_alias_cache()
        self._json({
            "ok": True, "alias": alias,
            "targets": [{"kind": k, "target": t} for k, t in specs],
            "count": len(specs),
        })

    @route("DELETE", r"/api/user/search/aliases")
    def alias_del(self, query, *_) -> None:
        """`?alias=xxx` 删这个俗称的全部别名；再给 `target` 就只删那一条。

        出厂默认（alias.tsv）删不掉 —— 它是随代码走的文件，不是数据。
        """
        alias = ((query.get("alias") or [""])[0]).strip()
        target = ((query.get("target") or [""])[0]).strip()
        if not alias:
            return self._error(422, "alias 必填")
        with user_db() as conn:
            if target:
                cur = conn.execute(
                    "DELETE FROM search_alias WHERE alias = ? AND target = ?", (alias, target))
            else:
                cur = conn.execute("DELETE FROM search_alias WHERE alias = ?", (alias,))
            removed = cur.rowcount
        reset_alias_cache()
        builtin = (alias.lower() in cjk_tables().alias)
        self._json({"ok": True, "removed": removed, "builtin_still_active": builtin})

    @route("POST", r"/api/user/names/check")
    def names_check(self, query, *_) -> None:
        """保存元数据前问一句：这些系列 / 标签 / 厂牌，库里到底有没有。

        客户端拿到 `exists:false` 就弹「库里没有，是否新建」—— 确认后照常 PUT
        覆盖层；新名字由 facets 扩展以虚拟分类的形式出现在列表里。
        只读查询，不写任何东西。
        """
        body = self._body()
        items = body.get("items")
        tables = {"series": "series", "tag": "tags", "studio": "studios", "actor": "actors"}
        out: list = []
        if isinstance(items, list) and items:
            with amane_db() as conn:
                for it in items[:60]:
                    if not isinstance(it, dict):
                        continue
                    kind = str(it.get("kind") or "")
                    name = str(it.get("name") or "").strip()
                    if not name:
                        continue
                    table = tables.get(kind)
                    if table is None:
                        # 不认的类别不拦（宁可少提示，也别拦着用户存）
                        out.append({"kind": kind, "name": name, "exists": True})
                        continue
                    try:
                        row = conn.execute(
                            f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (name,)).fetchone()
                        exists = row is not None
                    except sqlite3.Error:
                        exists = True
                    # 用户先在管理页「＋」建好的自建名也算存在，否则每存一次都会被问
                    # 「库里没有，是否新建」，等于自建标签白建了。
                    if not exists and kind in ("series", "tag"):
                        try:
                            with user_db() as uconn:
                                uconn.execute(
                                    "CREATE TABLE IF NOT EXISTS self_facets("
                                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                                hit = uconn.execute(
                                    "SELECT 1 FROM self_facets WHERE kind = ? AND name = ?",
                                    (kind, name)).fetchone()
                            exists = hit is not None
                        except sqlite3.Error as exc:
                            log(f"WARN names/check 查自建登记表失败: {exc}")
                    out.append({"kind": kind, "name": name, "exists": exists})
        self._json({"ok": True, "data": {"items": out}})
