"""tier 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class TierMixin(object):
    @route("POST", r"/api/user/tier/generate")
    def tier_generate(self, query, *_) -> None:
        filters = tier_filters(self._body())
        data = tier_store(filters, tier_build(filters))
        self._json({"ok": True, "version": TIER_VERSION, "data": data})

    @route("GET", r"/api/user/tier/current")
    def tier_current(self, query, *_) -> None:
        """统计页那一块：当前选定的那张；没有选定就取最新一张；一张都没有就按默认条件现生成。"""
        row = None
        with user_db() as conn:
            row = conn.execute(
                "SELECT * FROM tier_snapshot WHERE picked = 1 "
                "ORDER BY created_at DESC, id DESC LIMIT 1").fetchone()
            if row is None:
                row = conn.execute(
                    "SELECT * FROM tier_snapshot ORDER BY created_at DESC, id DESC LIMIT 1"
                ).fetchone()
        if row is not None:
            self._json({"ok": True, "version": TIER_VERSION, "data": tier_row_to_data(row)})
            return

        # 第一次打开：默认「最近一个月打过分的影片」；一条都没有就用全部影片再试一次
        filters = tier_filters({"kinds": ["film"], "rated_days": 30})
        data = tier_build(filters)
        if data["total"] == 0:
            filters = tier_filters({"kinds": ["film"]})
            data = tier_build(filters)
        stored = tier_store(filters, data)
        if data["total"] == 0:
            self._json({"ok": False, "version": TIER_VERSION, "data": stored,
                        "reason": "还没给片子打过星，先打几部再来"})
            return
        self._json({"ok": True, "version": TIER_VERSION, "data": stored})

    @route("GET", r"/api/user/tier/snapshots")
    def tier_snapshots(self, query, *_) -> None:
        try:
            limit = int((query.get("limit") or ["20"])[0])
        except ValueError:
            limit = 20
        try:
            offset = int((query.get("offset") or ["0"])[0])
        except ValueError:
            offset = 0
        limit = max(1, min(limit, 100))
        offset = max(0, offset)
        with user_db() as conn:
            rows = conn.execute(
                "SELECT * FROM tier_snapshot ORDER BY created_at DESC, id DESC "
                "LIMIT ? OFFSET ?", (limit, offset)).fetchall()
            total = conn.execute("SELECT COUNT(*) FROM tier_snapshot").fetchone()[0]
        items = []
        for r in rows:
            d = tier_row_to_data(r)
            items.append({"id": d["id"], "created_at": d["created_at"],
                          "summary": d["summary"], "title": d["title"], "total": d["total"],
                          "thumbs": d["thumbs"], "picked": d["picked"]})
        self._json({"ok": True, "version": TIER_VERSION,
                    "data": {"items": items, "total": total}})

    @route("GET", r"/api/user/tier/snapshots/(\d+)")
    def tier_snapshot_one(self, query, sid, *_) -> None:
        """单张快照的完整内容（含 tiers/items）。

        历史记录里点「查看 / 下载」要能重画任意一张老图，而列表只给摘要与三张缩略图。
        """
        with user_db() as conn:
            row = conn.execute(
                "SELECT * FROM tier_snapshot WHERE id = ?", (int(sid),)).fetchone()
        if row is None:
            return self._error(404, "没有这张图")
        self._json({"ok": True, "version": TIER_VERSION, "data": tier_row_to_data(row)})

    @route("DELETE", r"/api/user/tier/snapshots/(\d+)")
    def tier_delete(self, query, sid, *_) -> None:
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM tier_snapshot WHERE id = ?", (int(sid),)).rowcount
        self._json({"ok": True, "version": TIER_VERSION, "data": {"removed": removed}})

    @route("POST", r"/api/user/tier/pick")
    def tier_pick(self, query, *_) -> None:
        body = self._body()
        try:
            sid = int(body.get("id"))
        except (TypeError, ValueError):
            return self._error(422, "id 必填")
        with user_db() as conn:
            row = conn.execute("SELECT id FROM tier_snapshot WHERE id = ?", (sid,)).fetchone()
            if row is None:
                return self._error(404, "没有这张图")
            conn.execute("UPDATE tier_snapshot SET picked = 0 WHERE picked = 1")
            conn.execute("UPDATE tier_snapshot SET picked = 1 WHERE id = ?", (sid,))
        self._json({"ok": True, "version": TIER_VERSION, "data": {"id": sid}})
