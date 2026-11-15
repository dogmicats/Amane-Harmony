"""virtual 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class VirtualMixin(object):
    @route("GET", r"/api/user/virtual_facets")
    def virtual_facets(self, query, *_) -> None:
        counts: dict = {"series": {}, "tag": {}}
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields FROM meta_override").fetchall()
        except sqlite3.Error as exc:
            return self._error(500, f"读覆盖层失败: {exc}")
        for r in rows:
            fields = _json_dict(r["fields"])
            for kind, field in (("series", "series"), ("tag", "tags")):
                value = fields.get(field)
                names = value if isinstance(value, list) else (
                    [value] if isinstance(value, str) else [])
                for raw in names:
                    name = str(raw or "").strip()
                    if name:
                        buckets = counts[kind]
                        buckets[name] = buckets.get(name, 0) + 1
        out: list = []
        try:
            with amane_db() as conn:
                for kind, table in (("series", "series"), ("tag", "tags")):
                    for name, films in counts[kind].items():
                        row = conn.execute(
                            f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1",
                            (name,)).fetchone()
                        # 库里已有的同名分类不算「自建」，不进这个列表
                        if row is None:
                            out.append({"kind": kind, "name": name, "films": films})
        except sqlite3.Error as exc:
            return self._error(502, f"读分类表失败: {exc}")
        # 登记表里「先建好、还没挂到任何片」的名字也要出现（films=0），
        # 否则用户在管理页点加号建完，列表里看不到它，以为没成功。
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                reg = conn.execute(
                    "SELECT kind, name FROM self_facets").fetchall()
        except sqlite3.Error as exc:
            log(f"WARN 读自建登记表失败: {exc}")
            reg = []
        seen = {(v["kind"], v["name"]) for v in out}
        for r in reg:
            kind = str(r["kind"] or "")
            name = str(r["name"] or "")
            if kind not in ("series", "tag") or not name:
                continue
            if (kind, name) in seen:
                continue
            out.append({"kind": kind, "name": name, "films": counts[kind].get(name, 0)})

        out.sort(key=lambda v: (-v["films"], v["name"]))
        # 管理页要画成「一行一条带封面」，把换过的封面一次带上（没有就空，客户端用首字）
        covers: dict = {}
        for kind in ("series", "tag"):
            names = [v["name"] for v in out if v["kind"] == kind]
            if names:
                covers.update(cover_override_map(kind, names))
        for v in out:
            v["cover"] = covers.get(v["name"], "")
            # 没换过封面时，管理页要能像「制片厂」那样拼贴显示。
            # 注意：自建名字在库里**没有**对应记录，按名字查 metadata 是空的 ——
            # 必须先用覆盖层拿到「被改成这个名字的片」的 id，再取它们海报。
            posters: list = []
            try:
                mids = override_ids_for(v["kind"], v["name"])[:6]
                if mids:
                    ph = ",".join("?" * len(mids))
                    with amane_db() as conn:
                        rows = conn.execute(
                            f"SELECT poster_urls, thumb_urls FROM metadata "
                            f"WHERE id IN ({ph})", mids).fetchall()
                    for r in rows:
                        for u in (_json_list(r["poster_urls"]) + _json_list(r["thumb_urls"])):
                            p = public_image(u)
                            if p and p not in posters:
                                posters.append(p)
                                break
                if not posters:
                    for u in cover_gif_sources_for(v["kind"], v["name"], 4):
                        p = public_image(u)
                        if p and p not in posters:
                            posters.append(p)
            except Exception as exc:  # noqa: BLE001
                log(f"WARN 自建分类取拼贴失败 {v['name']}: {exc}")
            v["posters"] = posters[:4]
        self._json({"ok": True, "data": {"items": out, "total": len(out)}})

    @route("POST", r"/api/user/virtual_facets/create")
    def virtual_facet_create(self, query, *_) -> None:
        """先建一个自建系列 / 标签（可以先没有片挂着）。

        只写 `self_facets` 登记表，不动任何影片的覆盖字段；等用户在某部片的
        编辑页里填这个名字时，两边自然对上（列表按名字合并）。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        name = str(body.get("name") or "").strip()
        if kind not in ("series", "tag"):
            return self._error(400, "kind 只能是 series 或 tag")
        if not name:
            return self._error(400, "名字不能为空")
        if len(name) > 60:
            return self._error(400, "名字太长了（最多 60 字）")
        # 和库里已有分类重名就没意义了：那种名字不在「自建」范围内
        try:
            with amane_db() as conn:
                table = "series" if kind == "series" else "tags"
                row = conn.execute(
                    f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (name,)).fetchone()
        except sqlite3.Error as exc:
            return self._error(502, f"读分类表失败: {exc}")
        if row is not None:
            return self._error(409, "库里已经有同名的分类了")
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                exists = conn.execute(
                    "SELECT 1 FROM self_facets WHERE kind = ? AND name = ?",
                    (kind, name)).fetchone()
                if exists is None:
                    conn.execute(
                        "INSERT INTO self_facets(kind, name, created_at) VALUES(?,?,?)",
                        (kind, name, datetime.now(timezone.utc).isoformat(timespec="seconds")))
                conn.commit()
        except sqlite3.Error as exc:
            return self._error(500, f"写自建登记表失败: {exc}")
        self._json({"ok": True, "data": {"kind": kind, "name": name}})

    @route("POST", r"/api/user/virtual_facets/delete")
    def virtual_facet_delete(self, query, *_) -> None:
        """删掉一个自建分类：把它从所有片的覆盖字段里摘掉（只动覆盖层）。

        原分类不在这个入口的范围内 —— kind 只收 series / tag，且只处理
        「覆盖层里被写成这个名字」的部分，库里原有分类一字不动。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        name = str(body.get("name") or "").strip()
        if kind not in ("series", "tag") or not name:
            return self._error(400, "要指定 kind（series / tag）与 name")
        field = "series" if kind == "series" else "tags"
        touched = 0
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields, cover FROM meta_override").fetchall()
                for r in rows:
                    fields = _json_dict(r["fields"])
                    changed = False
                    if field == "series":
                        if str(fields.get("series") or "").strip() == name:
                            fields.pop("series", None)
                            changed = True
                    else:
                        cur = fields.get("tags")
                        if isinstance(cur, list):
                            keep = [t for t in cur if str(t or "").strip() != name]
                            if len(keep) != len(cur):
                                if keep:
                                    fields["tags"] = keep
                                else:
                                    fields.pop("tags", None)
                                changed = True
                    if not changed:
                        continue
                    touched += 1
                    mid = int(r["metadata_id"])
                    if fields or str(r["cover"] or ""):
                        conn.execute(
                            "UPDATE meta_override SET fields = ?, updated_at = ? "
                            "WHERE metadata_id = ?",
                            (json.dumps(fields, ensure_ascii=False), now_iso(), mid))
                    else:
                        conn.execute(
                            "DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        except sqlite3.Error as exc:
            return self._error(500, f"删除失败: {exc}")
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                conn.execute(
                    "DELETE FROM self_facets WHERE kind = ? AND name = ?",
                    (kind, name))
                conn.commit()
        except sqlite3.Error as exc:
            log(f"WARN 清理自建登记表失败 {kind}={name}: {exc}")
        invalidate_item_caches()
        log(f"删除自建分类 {kind}={name}，影响 {touched} 部")
        self._json({"ok": True, "data": {"kind": kind, "name": name, "removed": touched}})

    @route("POST", r"/api/user/virtual_facets/rename")
    def virtual_facet_rename(self, query, *_) -> None:
        """重命名一个自建分类：把所有片覆盖层里的旧名替换成新名。

        - 新名在库里已存在 → 这些片就直接归入那个原生分类（`native: true`，
          客户端据此提示「已并入库里的同名分类」）。
        - 新名也是另一个自建名 → 两个自建分类合并。
        - 只动覆盖层，库里的分类一个字不改。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        src = str(body.get("from") or "").strip()
        dst = str(body.get("to") or "").strip()
        if kind not in ("series", "tag"):
            return self._error(400, "kind 只支持 series / tag")
        if not src or not dst:
            return self._error(400, "要指定 from 与 to")
        if src == dst:
            return self._json({"ok": True, "data": {"kind": kind, "from": src,
                                                    "to": dst, "renamed": 0, "native": False}})
        field = "series" if kind == "series" else "tags"
        touched = 0
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields FROM meta_override").fetchall()
                for r in rows:
                    fields = _json_dict(r["fields"])
                    if field == "series":
                        if str(fields.get("series") or "").strip() != src:
                            continue
                        fields["series"] = dst
                    else:
                        cur = fields.get("tags")
                        if not isinstance(cur, list):
                            continue
                        kept: list = []
                        hit = False
                        for tag in cur:
                            if str(tag or "").strip() == src:
                                hit = True
                                if dst not in kept:
                                    kept.append(dst)
                            else:
                                kept.append(tag)
                        if not hit:
                            continue
                        fields["tags"] = kept
                    touched += 1
                    conn.execute(
                        "UPDATE meta_override SET fields = ?, updated_at = ? "
                        "WHERE metadata_id = ?",
                        (json.dumps(fields, ensure_ascii=False), now_iso(),
                         int(r["metadata_id"])))
        except sqlite3.Error as exc:
            return self._error(500, f"重命名失败: {exc}")
        native = False
        try:
            with amane_db() as conn:
                table = "series" if kind == "series" else "tags"
                native = conn.execute(
                    f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (dst,)).fetchone() is not None
        except sqlite3.Error:
            native = False
        invalidate_item_caches()
        log(f"重命名自建分类 {kind}: {src} -> {dst}，影响 {touched} 部（native={native}）")
        self._json({"ok": True, "data": {"kind": kind, "from": src, "to": dst,
                                         "renamed": touched, "native": native}})
