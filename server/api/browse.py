"""browse 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class BrowseMixin(object):
    @route("GET", r"/api/user/browse")
    def browse(self, query, *_) -> None:
        def arg(name: str, default: str = "") -> str:
            return (query.get(name) or [default])[0].strip()

        try:
            limit = min(120, max(1, int(arg("limit", "40"))))
            offset = max(0, int(arg("offset", "0")))
        except ValueError:
            return self._error(400, "limit/offset 必须是整数")

        lib_id = arg("library_id")
        search = arg("q")
        # 检索归一化（2.5.1）：先繁转简，后面拆词 / 排序 / 匹配统一用归一化后的词。
        # 只影响查询侧：库里的数据一个字节都不改，关掉功能也不会留下脏数据。
        search_norm = norm_query(search)
        # q 与 qmode 是「词之间」的关系：and（默认，全部词都要命中）/ or（任一词命中即可）。
        # 客户端在结果过少时自己退到 or，服务端不替它决定（避免搜索结果忽多忽少）。
        qmode = arg("qmode", "and").lower()
        tokens = [x for x in re.split(r"[\s\-_/]+", search_norm) if x][:6]
        groups: list[tuple[str, tuple]] = []

        sort = arg("sort", "recent").lower()
        # 扩展可以提供核心 SORTS 里没有的排序键（数据落在 user.db 时跨库不能 JOIN，
        # 由扩展给出分档 CASE 表达式）。求值型钩子：不认识这个 sort 就返回 None。
        ext_sort = EXT.call_hook("browse_sort", sort)
        if sort not in SORTS and not ext_sort:
            sort = "recent"
            ext_sort = None
        column, default_dir = SORTS.get(sort, ("m.id", "desc"))
        want_dir = (ext_sort or {}).get("dir") or default_dir
        direction = arg("order", want_dir).lower()
        if direction not in ("asc", "desc"):
            direction = want_dir
        # 出演年龄看哪个性别：默认女优，male 显式切男优。排序与区间筛选共用这一个。
        age_gender = cast_age_gender_of(arg("cast_age_gender"))
        if sort == "random":
            order = "RANDOM()"
        elif ext_sort and ext_sort.get("expr"):
            order = f"{ext_sort['expr']} {direction.upper()}, m.id DESC"
        elif sort == "cast_age":
            # 升序比「该性别里最年轻的那位」，降序比「该性别里最年长的那位」。
            # 约 29% 影片没有可算岁数的演员：NULL 在 SQLite 的 ASC 里排最前，
            # 会把一堆「查不出年龄」的片顶到首页。先按 IS NULL 沉底，再按岁数排。
            key = CAST_AGE_SORT_SQL[age_gender][direction]
            order = f"({key} IS NULL), {key} {direction.upper()}, m.id DESC"
        else:
            # 次级键保证分页稳定（同分/同日期不会在翻页时重复或漏项）
            order = f"{column} {direction.upper()}, m.id DESC"

        # 有搜索词时相关性优先（2.4.6.21）：番号全等 / 去连字符全等 > 番号前缀 >
        # 标题包含 > 系列包含 > 演员等其它命中。用户选的排序退成次级键 ——
        # 否则搜「IPZZ-932」时最像的那部会被「最近更新」埋到第一页之外。
        rel_params: tuple = ()
        if search:
            # 排序用归一化后的词：繁体输入（癡女）也要让标题里写「痴女」的那部排前面，
            # 否则「命中靠 t2s、排序靠原文」会排出一堆不相关的。
            kw_esc = re.sub(r"([%_\\])", r"\\\1", search_norm)
            order = (
                "CASE WHEN UPPER(m.number) = UPPER(?) THEN 0 "
                "WHEN REPLACE(UPPER(m.number), '-', '') = REPLACE(UPPER(?), '-', '') THEN 0 "
                "WHEN UPPER(m.number) LIKE UPPER(?) ESCAPE '\\' THEN 1 "
                "WHEN m.title LIKE ? ESCAPE '\\' THEN 2 "
                "WHEN m.series LIKE ? ESCAPE '\\' THEN 3 "
                "ELSE 4 END ASC, " + order
            )
            rel_params = (
                search_norm, search_norm, kw_esc + "%",
                "%" + kw_esc + "%", "%" + kw_esc + "%"
            )

        where: list[str] = []
        params: tuple = ()

        # 媒体库筛选：`library_id=3`（单选，老客户端）或 `libs=1,2`（多选，2026-11-15）。
        # 多选的语义是**同时出现在每个所选库里**（AND），不是「任一」——
        # 用户原话「筛选同时出现在哪些媒体库的内容」，所以每加一个库结果只会更少。
        lib_ids: list[int] = []
        libs_raw = arg("libs")
        if libs_raw:
            for part in libs_raw.split(","):
                part = part.strip()
                if not part:
                    continue
                try:
                    lib_ids.append(int(part))
                except ValueError:
                    return self._error(400, "libs 里的库 id 必须是整数")
        elif lib_id:
            try:
                lib_ids.append(int(lib_id))
            except ValueError:
                return self._error(400, "library_id 必须是整数")

        if lib_ids:
            for lid in lib_ids:
                where.append("f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)")
                params = (*params, lid)

        # 按分类**名字**筛（2.5.5.16）：自建分类（覆盖层里新起的系列 / 标签）没有 id，
        # 只能按名字查。把「库里本来属于这个名字的」和「被改到这个名字下的」并成一条，
        # 这样自建分类和原分类走同一个 browse —— 关键词 / 评分 / 收藏 / 排序全部等价。
        facet_kind = arg("facet_kind").lower()
        facet_name = arg("facet_name")
        if facet_name and facet_kind in ("series", "tag", "studio", "actor"):
            over_ids = override_ids_for(facet_kind, facet_name)
            if facet_kind in ("series", "studio"):
                cond = "m.%s = ?" % facet_kind
                fparams: list = [facet_name]
            elif facet_kind == "actor":
                cond = "m.actors LIKE ?"
                fparams = [f"%{facet_name}%"]
            else:
                cond = ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                        "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)")
                fparams = [facet_name]
            if over_ids:
                marks = ",".join("?" * len(over_ids))
                cond = f"({cond} OR m.id IN ({marks}))"
                fparams = fparams + over_ids
            where.append(cond)
            params = (*params, *fparams)

        if search:
            # 模糊搜索：按空格 / 连字符拆词，每个词都要命中（AND）。
            # number 额外去掉连字符再比一次，这样 "ipzz932" 能搜到 "IPZZ-932"，
            # "ipzz 932" 拆成两个词也照样命中。
            # 再叠一层 amane_rel：全角输入（ｉｐｚｚ－９３２）、大小写、少打一个连字符
            # 都能命中 —— LIKE 只认字面，归一化得交给这个标量函数。
            # 只对番号做：标题是长日文，逐行归一化+子序列会让搜索从 40ms 涨到 400ms，
            # 而中文标题本来就是全角，LIKE 已经能命中。
            #
            # 2.5.1 起每个词还有三条额外通路（都只改**查询侧**，不动库里的数据）：
            #   ① 繁体转简体（癡女 → 痴女）；
            #   ② 标签名子查询（原来只搜 number/title/actors/series，标签词根本搜不到）；
            #   ③ 拼音首字母 / 全拼（scg → 搜查官，ntr → 牛头人）。
            for tok in tokens:
                like = f"%{tok}%"
                # 番号相关的三条只在「这个词可能是番号」时才加。
                # 判据用归一化后的形状：NFKC 之后全是 ASCII 字母数字（`ｉｐｚｚ－９３２`
                # 归一成 `ipzz932` 也算）。纯中文词根本不可能出现在番号里，加上去纯亏：
                # 实测 browse?q=痴女 从 163ms 降到 65ms（P50，NAS 本地）。
                nkw = _norm_kw(tok)
                numish = bool(nkw) and all(ch.isascii() and ch.isalnum() for ch in nkw)
                num_conds: list[str] = []
                num_vals: list = []
                if numish:
                    num_conds = [
                        "m.number LIKE ?",
                        "REPLACE(m.number, '-', '') LIKE ?",
                        "amane_rel(m.number, ?) IS NOT NULL",
                    ]
                    num_vals = [like, like, tok]
                conds = num_conds + [
                    "m.title LIKE ?",
                    "m.actors LIKE ?",
                    "m.series LIKE ?",
                ]
                vals: list = num_vals + [like, like, like]
                if has_cjk(tok):
                    # 标签名不会出现在 metadata 的任何一个文本列里，只能走关联表。
                    # 只对含中文的词加：番号/英文字母词走标签匹配纯属浪费（那几万行
                    # 关联表扫一遍要十几毫秒，而英文词基本不可能命中中文标签名）。
                    conds.append(
                        "m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                        "JOIN tags t ON t.id = mt.tag_id WHERE t.name LIKE ?)")
                    vals.append(like)
                for cond, cond_params in search_clauses(tok):
                    conds.append(cond)
                    vals.extend(cond_params)
                groups.append(("(" + " OR ".join(conds) + ")", tuple(vals)))
            # 词与词之间默认 AND（保持原有语义）；qmode=or 时放宽成「命中任一词即可」，
            # 由客户端在「结果太少」时自己决定要不要退这一步 —— 服务端只提供能力。
            if qmode == "or" and len(groups) > 1:
                where.append("(" + " OR ".join(g[0] for g in groups) + ")")
                params = (*params, *[v for g in groups for v in g[1]])
            else:
                for cond, cond_params in groups:
                    where.append(cond)
                    params = (*params, *cond_params)

        # 马赛克：CRACKED / LEAKED / NONE（原版无标记）
        mosaic = arg("mosaic").upper()
        if mosaic:
            wanted = [v for v in mosaic.split(",") if v in ("CRACKED", "LEAKED", "NONE")]
            if wanted:
                parts: list[str] = []
                for value in wanted:
                    if value == "NONE":
                        parts.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                     "AND x.mosaic IS NOT NULL AND x.mosaic != '')")
                    else:
                        parts.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                     "AND x.mosaic = ?)")
                        params = (*params, value)
                where.append("(" + " OR ".join(parts) + ")")

        ctype = arg("ctype").upper()
        if ctype:
            values = [v for v in ctype.split(",") if v]
            if values:
                marks = ",".join("?" * len(values))
                where.append(f"UPPER(m.content_type) IN ({marks})")
                params = (*params, *values)

        # 字幕：1 有（内嵌或外挂），0 无
        sub = arg("sub")
        if sub == "1":
            where.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                         "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")
        elif sub == "0":
            where.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                         "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")

        # 多版本（2.5.7.7）：1 = 只看有 2 个以上文件的，0 = 只看单文件的，留空 = 全部。
        # 口径与 versions_of() 同一句 SQL（media_files 行数），现算不缓存 ——
        # 文件管理里删掉一个版本 / 脚本新入库一个文件，下次刷新就变。
        multi = arg("multi")
        if multi == "1":
            where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) >= 2")
        elif multi == "0":
            where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) = 1")

        year_from = arg("year_from")
        year_to = arg("year_to")
        if year_from.isdigit():
            where.append("substr(m.release, 1, 4) >= ?")
            params = (*params, year_from)
        if year_to.isdigit():
            where.append("substr(m.release, 1, 4) <= ?")
            params = (*params, year_to)

        min_score = arg("min_score")
        if min_score:
            try:
                where.append("CAST(json_extract(m.scores, '$.javdb') AS REAL) >= ?")
                params = (*params, float(min_score))
            except ValueError:
                pass

        # 出演时岁数：上游没有这个字段，用 发行日 − 演员生日 在只读库里现算周岁。
        # 只看 age_gender 指定的那个性别（默认女优），任一位该性别演员落在区间即命中；
        # 没生日 / 性别 UNKNOWN 的演员天然不参与（扩展 actors 的 /item/{id}/cast
        # 用同一口径展示，口径见那里的 _age_of()）。
        age_min = arg("cast_age_min")
        age_max = arg("cast_age_max")
        if age_min.isdigit() or age_max.isdigit():
            # 下限与 _age_of() / cast_age_sql() 一致收到 18：低于 18 的岁数一律不参与。
            lo = int(age_min) if age_min.isdigit() else 18
            hi = int(age_max) if age_max.isdigit() else 90
            lo, hi = max(18, min(lo, 90)), max(18, min(hi, 90))
            if lo > hi:
                lo, hi = hi, lo
            where.append(
                "EXISTS (SELECT 1 FROM metadata_actors ca "
                "JOIN actors cab ON cab.id = ca.actor_id "
                "WHERE ca.metadata_id = m.id AND cab.gender = ? "
                "AND substr(cab.birthday, 1, 10) GLOB "
                "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
                "AND substr(m.release, 1, 10) GLOB "
                "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' "
                "AND (CAST(strftime('%Y', substr(m.release, 1, 10)) AS INTEGER) "
                "- CAST(strftime('%Y', substr(cab.birthday, 1, 10)) AS INTEGER) "
                "- (CASE WHEN strftime('%m-%d', substr(m.release, 1, 10)) "
                "< strftime('%m-%d', substr(cab.birthday, 1, 10)) THEN 1 ELSE 0 END)) "
                "BETWEEN ? AND ?)")
            params = (*params, _CAST_AGE_LABEL[age_gender], lo, hi)

        # 维度过滤（标签 / 导演 / 演员 / 系列 / 制片商 / 发行商），口径见 _DIM_FILTERS。
        for dim, dim_sql in _DIM_FILTERS.items():
            raw = arg(dim)
            if not raw:
                continue
            vals = [x.strip() for x in raw.split(",") if x.strip().isdigit()][:12]
            if not vals:
                continue
            if "{marks}" in dim_sql:
                where.append(dim_sql.format(marks=",".join("?" * len(vals)), n=len(vals)))
                params = (*params, *[int(x) for x in vals])
            else:
                # 标量维度（系列/制片商/发行商）只有一个名字位，多值只取第一个
                where.append(dim_sql)
                params = (*params, int(vals[0]))

        # 扩展可以追加筛选条件：核心不感知具体语义，只提供 where/params 拼接点。
        # 逐个钩子取结果再累加，不能用 EXT.call()——它按 dict 合并，多个扩展
        # 同时返回 clauses 时后一个会把前一个覆盖掉（收藏夹 + 评分并存时必踩）。
        for fn in EXT.hooks.get("browse_where", []):
            try:
                out = fn(query) or {}
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook browse_where: {exc}")
                continue
            for extra in out.get("clauses", []):
                if isinstance(extra, (tuple, list)) and len(extra) == 2:
                    where.append(str(extra[0]))
                    params = (*params, *tuple(extra[1]))

        clause = " AND ".join(where)
        with amane_db() as conn:
            # 相关性档位的占位符在 ORDER BY 里（SQL 尾部），所以只给取页的那条加；
            # count_meta 的 SQL 没有 ORDER BY，用它会把参数数量对不上。
            items = query_meta(conn, clause, params + rel_params, order, limit, offset)
            attach_marks(conn, items)
            total = count_meta(conn, clause, params)

        # 覆盖层命中的片（2.5.5.25）：SQL 查的是 amane 库的原始字段，
        # 用户把系列改成「11」之后，搜「11」在库里是搜不到那部片的。
        # 只在第一页补一次，按 id 去重，最多 20 部。
        if search and tokens and offset == 0:
            try:
                extra = [i for i in override_ids_matching(tokens)
                         if i not in {it["id"] for it in items}][:20]
            except Exception as exc:  # noqa: BLE001
                extra = []
                log(f"WARN 覆盖层搜索失败: {exc}")
            if extra:
                items.extend(fetch_by_ids(extra))
                total += len(extra)
        self._json({
            "items": attach_progress(items),
            "total": total,
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": direction,
            "cast_age_gender": age_gender,
            # 回显「这次按什么语义搜的」：客户端据此判断还要不要退到 or
            "qmode": "or" if (qmode == "or" and len(groups) > 1) else "and",
            # 归一化后的词（繁转简之后）。客户端拿它做「已放宽」提示的对比，
            # 也方便排查「我明明搜的是这个」。原词在请求里，不用再回。
            "q_norm": search_norm if search else "",
        })
        # 严格搜索（qmode=and）几乎没结果 → 记进「待办」。
        # 客户端放宽那次（qmode=or）结果会变多，记下来就是假账，所以只认 and。
        if search and qmode != "or":
            record_search_miss(search, search_norm, total)
