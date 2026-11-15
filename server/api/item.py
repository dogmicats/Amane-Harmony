"""item 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class ItemMixin(object):
    @route("GET", r"/api/user/item/(\d+)")
    def item(self, query, metadata_id, *_) -> None:
        with amane_db() as conn:
            rows = conn.execute(f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (int(metadata_id),)).fetchall()
            if not rows:
                return self._error(404, "条目不存在")
            data = item_of(rows[0])
            # 详情页是覆盖层最主要的面（改完立刻要看到），单条查一次不算开销
            apply_overrides([data])
            extra = _json_dict(rows[0]["extrafanart_urls"])
            stills: list[str] = []
            sources: list[str] = []
            for urls in extra.values():
                for url in _json_list(urls):
                    if isinstance(url, str) and url.startswith("http") and len(stills) < 12:
                        sources.append(url)
                        stills.append(_img_proxy(url))
            data["stills"] = stills
            # 和 stills 等长的宽高比：详情页瀑布流要按真实比例各自定高，
            # 否则竖版海报被塞进横框就只有「砍头」一个下场。量不出来给 0，客户端自己补。
            data["still_ratios"] = _still_ratios(sources)
            files = conn.execute(
                "SELECT id, path, size, duration, definition, mosaic, has_subtitle_in_name, "
                "has_external_subtitle, library_id FROM media_files WHERE metadata_id = ? ORDER BY id",
                (int(metadata_id),),
            ).fetchall()
        data["files"] = [dict(f) for f in files]
        # 详情页标记也在服务端算：客户端不必再从 files 里各拼一遍，
        # 一个数据源 = 所有详情页天然一致（见 docs/UI_RULES.md）。
        labels: list[str] = []
        mosaics = {str((f["mosaic"] or "")).upper() for f in files}
        if "UNCENSORED" in mosaics:
            labels.append("无码")
        if "CRACKED" in mosaics:
            labels.append("破解")
        if "LEAKED" in mosaics:
            labels.append("流出")
        if any(f["has_subtitle_in_name"] or f["has_external_subtitle"] for f in files):
            labels.append("中字")
        data["marks"] = labels
        with amane_db() as conn:
            # amane 的「评价」：网友推荐 / 讨论帖引用，早于 updated_at 的是原帖
            rows = conn.execute(
                "SELECT id, body, created_at, updated_at FROM comments "
                "WHERE metadata_id = ? ORDER BY created_at DESC LIMIT 40",
                (int(metadata_id),),
            ).fetchall()
        data["comments"] = [
            {
                "id": r["id"],
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
            }
            for r in rows
        ]
        # 我自己写的评价：按时间倒序全部插到最前，并打 mine 标记（客户端高亮 + 就地改删）
        with user_db() as conn:
            mine_rows = conn.execute(
                "SELECT id, body, created_at, updated_at FROM user_comments "
                "WHERE metadata_id = ? ORDER BY id DESC",
                (int(metadata_id),),
            ).fetchall()
        mine_list = []
        for r in mine_rows:
            body_text = (r["body"] or "").strip()
            if not body_text:
                continue
            mine_list.append({
                "id": int(r["id"]),
                "body": body_text,
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
                "mine": True,
            })
        data["comments"] = mine_list + data["comments"]
        data["my_comment"] = mine_list[0]["body"] if mine_list else ""
        data["my_comment_count"] = len(mine_list)
        with user_db() as conn:
            fav = conn.execute("SELECT 1 FROM favorites WHERE metadata_id = ?", (int(metadata_id),)).fetchone()
            hist = conn.execute(
                "SELECT position, duration, finished FROM history WHERE metadata_id = ?", (int(metadata_id),)
            ).fetchone()
        data["favorite"] = bool(fav)
        data["position"] = round(hist["position"], 1) if hist else 0
        data["duration"] = round(hist["duration"], 1) if hist else 0
        data["finished"] = bool(hist["finished"]) if hist else False
        data.update(EXT.call("item_extra", int(metadata_id)))
        self._json(data)

    @route("GET", r"/api/user/item/(\d+)/similar")
    def item_similar(self, query, metadata_id, *_) -> None:
        """详情页「相似影片」。limit 默认 12，上限 24（横滑一屏别拉太多）。"""
        limit = max(1, min(int((query.get("limit") or ["12"])[0]), 24))
        self._json({"items": build_similar(int(metadata_id), limit)})

    @route("POST", r"/api/user/item/(\d+)/comment")
    def comment_add(self, query, metadata_id, *_) -> None:
        """新增一条「我的评价」。一部片可以写多条，不覆盖旧的。

        与上游 comments（只读库里的刮削内容）分开存 user.db；详情接口会把我写的
        这些按时间倒序插在评价列表最前并标 mine=true。上限 4000 字。
        """
        text = str((self._body() or {}).get("body") or "").strip()
        mid = int(metadata_id)
        if not text:
            return self._error(400, "评价不能为空")
        if len(text) > 4000:
            return self._error(400, "评价太长了（上限 4000 字）")
        now = now_iso()
        with user_db() as conn:
            cur = conn.execute(
                "INSERT INTO user_comments(metadata_id, body, created_at, updated_at) "
                "VALUES(?, ?, ?, ?)", (mid, text, now, now))
            new_id = cur.lastrowid
        self._json({"ok": True, "id": new_id, "body": text, "created_at": now})

    @route("PUT", r"/api/user/item/(\d+)/comment/(\d+)")
    def comment_edit(self, query, metadata_id, comment_id, *_) -> None:
        text = str((self._body() or {}).get("body") or "").strip()
        if not text:
            return self._error(400, "评价不能为空（要删请用 DELETE）")
        if len(text) > 4000:
            return self._error(400, "评价太长了（上限 4000 字）")
        with user_db() as conn:
            n = conn.execute(
                "UPDATE user_comments SET body = ?, updated_at = ? WHERE id = ? AND metadata_id = ?",
                (text, now_iso(), int(comment_id), int(metadata_id))).rowcount
        if not n:
            return self._error(404, "这条评价不存在")
        self._json({"ok": True, "id": int(comment_id), "body": text})

    @route("DELETE", r"/api/user/item/(\d+)/comment/(\d+)")
    def comment_del_one(self, query, metadata_id, comment_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM user_comments WHERE id = ? AND metadata_id = ?",
                         (int(comment_id), int(metadata_id)))
        self._json({"ok": True})

    @route("DELETE", r"/api/user/item/(\d+)/comment")
    def comment_del_all(self, query, metadata_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM user_comments WHERE metadata_id = ?", (int(metadata_id),))
        self._json({"ok": True})

    @route("GET", r"/api/user/mycomments")
    def my_comments(self, query, *_) -> None:
        """「我的评价」列表页：我写过的全部评价 + 影片基本信息。

        影片信息在 amane.db（只读）、评价在 user.db，跨库不能 JOIN，所以先取评价
        再按 id 批量补片名/海报。
        """
        try:
            limit = max(1, min(int((query.get("limit") or ["200"])[0]), 500))
        except ValueError:
            return self._error(400, "limit 必须是整数")
        with user_db() as conn:
            rows = conn.execute(
                "SELECT id, metadata_id, body, created_at, updated_at FROM user_comments "
                "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        info = {int(m["id"]): m for m in fetch_by_ids([int(r["metadata_id"]) for r in rows])}
        out = []
        for r in rows:
            base = info.get(int(r["metadata_id"]))
            card = {}
            if base:
                try:
                    card = item_of(base)
                except Exception:  # noqa: BLE001
                    # fetch_by_ids 已经在某些版本里就返回成品 dict，直接拿来用
                    card = dict(base)
            out.append({
                "id": int(r["id"]),
                "metadata_id": int(r["metadata_id"]),
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
                "number": card.get("number", ""),
                "title": card.get("title", ""),
                "poster": card.get("poster", ""),
            })
        self._json({"items": out})

    @route("GET", r"/api/user/annotations/(\d+)")
    def annotations_of(self, query, metadata_id, *_) -> None:
        """某部片的弹幕。

        `?file=<file_key>` 指定版本/集：弹幕是**跟着文件走**的，不同清晰度、
        不同集共用一个时间轴必然串戏，所以默认必须带 file_key。
        不带 file 时回退成「这部片全部文件」的合集（老客户端兼容），
        并额外返回 `files`（每个文件多少条），管理页据此分组。
        """
        key = (query.get("file") or [""])[0]
        key = key[:64]
        with user_db() as conn:
            if key:
                rows = conn.execute(
                    "SELECT id, t_ms, body, created_at FROM annotations "
                    "WHERE metadata_id = ? AND file_key = ? ORDER BY t_ms",
                    (int(metadata_id), key)).fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, file_key, t_ms, body, created_at FROM annotations "
                    "WHERE metadata_id = ? ORDER BY t_ms", (int(metadata_id),)).fetchall()
            files = conn.execute(
                "SELECT file_key, COUNT(*) AS n FROM annotations "
                "WHERE metadata_id = ? GROUP BY file_key",
                (int(metadata_id),)).fetchall()
        names = annotation_file_names([str(r["file_key"] or "") for r in files])
        self._json({
            "items": [dict(r) for r in rows],
            "files": [{"file_key": str(r["file_key"] or ""), "name": names.get(
                str(r["file_key"] or ""), ""), "count": int(r["n"])} for r in files],
        })

    @route("GET", r"/api/user/annotations")
    def annotations_all(self, query, *_) -> None:
        """我的全部批注（汇总页）：跨库不能 JOIN，先取批注再按 id 补片名/海报。"""
        try:
            limit = max(1, min(int((query.get("limit") or ["300"])[0]), 1000))
        except ValueError:
            return self._error(400, "limit 必须是整数")
        with user_db() as conn:
            rows = conn.execute(
                "SELECT id, metadata_id, file_key, t_ms, body, created_at FROM annotations "
                "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        info = {int(m["id"]): m for m in fetch_by_ids([int(r["metadata_id"]) for r in rows])}
        names = annotation_file_names([str(r["file_key"] or "") for r in rows])
        out = []
        for r in rows:
            base = info.get(int(r["metadata_id"]))
            card = {}
            if base:
                try:
                    card = item_of(base)
                except Exception:  # noqa: BLE001
                    card = dict(base)
            fk = str(r["file_key"] or "")
            out.append({
                "id": int(r["id"]),
                "metadata_id": int(r["metadata_id"]),
                "file_key": fk,
                "file_name": names.get(fk, ""),
                "t_ms": int(r["t_ms"] or 0),
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "number": card.get("number", ""),
                "title": card.get("title", ""),
                "poster": card.get("poster", ""),
            })
        self._json({"items": out})

    @route("POST", r"/api/user/annotations/(\d+)")
    def annotation_add(self, query, metadata_id, *_) -> None:
        body = self._body() or {}
        text = str(body.get("body") or "").strip()
        if not text:
            return self._error(400, "批注不能为空")
        if len(text) > 200:
            return self._error(400, "批注太长了（上限 200 字）")
        file_key = str(body.get("file_key") or "")[:64]
        try:
            t_ms = int(round(float(body.get("t") or 0) * 1000))
        except (TypeError, ValueError):
            t_ms = 0
        t_ms = max(0, min(t_ms, 24 * 3600 * 1000))
        with user_db() as conn:
            cur = conn.execute(
                "INSERT INTO annotations(metadata_id, file_key, t_ms, body, created_at) "
                "VALUES(?,?,?,?,?)",
                (int(metadata_id), file_key, t_ms, text, now_iso()))
            new_id = cur.lastrowid
        self._json({"ok": True, "id": new_id, "file_key": file_key,
                    "t_ms": t_ms, "body": text})

    @route("DELETE", r"/api/user/annotations/(\d+)/(\d+)")
    def annotation_del(self, query, metadata_id, annotation_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM annotations WHERE id = ? AND metadata_id = ?",
                         (int(annotation_id), int(metadata_id)))
        self._json({"ok": True})
