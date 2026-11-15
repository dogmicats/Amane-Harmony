"""mine 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class MineMixin(object):
    @route("GET", r"/api/user/favorites")
    def favorites(self, query, *_) -> None:
        limit = int((query.get("limit") or ["60"])[0])
        offset = int((query.get("offset") or ["0"])[0])
        with user_db() as conn:
            ids = [r["metadata_id"] for r in conn.execute(
                "SELECT metadata_id FROM favorites ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (max(1, min(limit, 200)), max(0, offset)),
            )]
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        items = fetch_by_ids(ids)
        with amane_db() as conn:
            attach_marks(conn, items)
        self._json({"items": items, "total": total})

    @route("GET", r"/api/user/favorites/ids")
    def favorite_ids(self, query, *_) -> None:
        with user_db() as conn:
            ids = [r["metadata_id"] for r in conn.execute("SELECT metadata_id FROM favorites")]
        self._json({"ids": ids})

    @route("PUT", r"/api/user/favorites/(\d+)")
    def favorite_add(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        with user_db() as conn:
            conn.execute(
                "INSERT INTO favorites(metadata_id, created_at) VALUES(?, ?) "
                "ON CONFLICT(metadata_id) DO NOTHING",
                (mid, now_iso()),
            )
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        extra = EXT.call("favorite_add", mid)
        self._json({"ok": True, "favorite": True, "total": total, **extra})

    @route("DELETE", r"/api/user/favorites/(\d+)")
    def favorite_del(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        with user_db() as conn:
            conn.execute("DELETE FROM favorites WHERE metadata_id = ?", (mid,))
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        extra = EXT.call("favorite_del", mid)
        self._json({"ok": True, "favorite": False, "total": total, **extra})

    @route("GET", r"/api/user/history")
    def history(self, query, *_) -> None:
        limit = int((query.get("limit") or ["60"])[0])
        offset = int((query.get("offset") or ["0"])[0])
        only_unfinished = (query.get("unfinished") or [""])[0] in ("1", "true")
        clause = "WHERE finished = 0" if only_unfinished else ""
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, position, duration, played_at, finished FROM history {clause} "
                "ORDER BY played_at DESC LIMIT ? OFFSET ?",
                (max(1, min(limit, 200)), max(0, offset)),
            ).fetchall()
            total = conn.execute(f"SELECT COUNT(*) FROM history {clause}").fetchone()[0]
        meta = {m["id"]: m for m in fetch_by_ids([r["metadata_id"] for r in rows])}
        items = []
        for r in rows:
            base = meta.get(r["metadata_id"])
            if not base:
                continue
            item = dict(base)
            item["position"] = round(r["position"], 1)
            item["duration"] = round(r["duration"], 1)
            item["played_at"] = r["played_at"]
            item["finished"] = bool(r["finished"])
            items.append(item)
        self._json({"items": items, "total": total})

    @route("POST", r"/api/user/history")
    def history_upsert(self, query, *_) -> None:
        body = self._body()
        try:
            mid = int(body.get("metadata_id"))
        except (TypeError, ValueError):
            return self._error(422, "metadata_id 必填")
        position = max(0.0, float(body.get("position") or 0))
        duration = max(0.0, float(body.get("duration") or 0))
        # 已看完的口径只有一个：0.95，与客户端 PlayerPage.saveProgress 完全一致。
        # 从前这里是 0.92、客户端是 0.95，会出现「客户端显示看完、服务端没标完」的错位。
        finished = 1 if (body.get("finished") or (duration and position >= duration * FINISH_RATIO)) else 0
        if not finished and position < 5:
            return self._json({"ok": True, "skipped": True})
        with user_db() as conn:
            conn.execute(
                "INSERT INTO history(metadata_id, position, duration, played_at, finished) VALUES(?,?,?,?,?) "
                # finished 一旦置 1 就不再回落：重看开头几秒不该把「已看完」抹掉
                "ON CONFLICT(metadata_id) DO UPDATE SET position=excluded.position, "
                "duration=excluded.duration, played_at=excluded.played_at, "
                "finished=MAX(history.finished, excluded.finished)",
                (mid, position, duration, now_iso(), finished),
            )
            # 顺带采一个样（2.5.3）：老客户端只发 history、不发专用采样接口。有了这一行，
            # 它们也能贡献「部数 / 时长 / 时段」，只是粒度粗（src=legacy，页面标「只能估算」）。
            # 新客户端同时发两个接口时会被「同一分钟只留最早一条」去掉重复，不会翻倍。
            try:
                ldate, lhour = _local_parts(body)
                add_sample(conn, mid, position, duration, ldate, lhour, "legacy")
            except (TypeError, ValueError) as exc:
                log(f"WARN 采样写入失败: {exc}")
            row = conn.execute(
                "SELECT position, duration, finished FROM history WHERE metadata_id = ?", (mid,)
            ).fetchone()
        self._json({"ok": True, "position": row["position"], "duration": row["duration"],
                    "finished": bool(row["finished"])})

    @route("DELETE", r"/api/user/history/(\d+)")
    def history_del(self, query, metadata_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM history WHERE metadata_id = ?", (int(metadata_id),))
        self._json({"ok": True})
