"""backup 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class BackupMixin(object):
    @route("GET", r"/api/user/backup/export")
    def backup_export(self, query, *_):
        """导出收藏 / 评分 / 历史 / 稍后再看 / 清单 + 内容快照（2.6.2.x）。

        以**番号**为锚：`metadata_id` 是上游库的自增 id，换库/重建之后就对不上了，
        而番号是这部片唯一稳定的东西。快照（番号/标题/片商）跟着一起带出去，
        这样导入端即使找不到对应条目，也知道导的是什么。
        """
        with user_db() as conn:
            favs = {r["metadata_id"]: r["created_at"] for r in conn.execute(
                "SELECT metadata_id, created_at FROM favorites")}
            hist = {r["metadata_id"]: dict(r) for r in conn.execute(
                "SELECT metadata_id, position, duration, played_at, finished FROM history")}
            later = {r["metadata_id"]: r["created_at"] for r in conn.execute(
                "SELECT metadata_id, created_at FROM watch_later")}
            rates = {r["metadata_id"]: r["score"] for r in conn.execute(
                "SELECT metadata_id, score FROM user_ratings")}
            colls: dict[int, list[str]] = {}
            for r in conn.execute(
                    "SELECT c.name AS name, i.metadata_id AS mid FROM collection_items i "
                    "JOIN collections c ON c.id = i.collection_id ORDER BY c.name"):
                colls.setdefault(r["mid"], []).append(r["name"])
        ids = set(favs) | set(hist) | set(later) | set(rates) | set(colls)
        snap: dict[int, dict] = {}
        if ids:
            ph = ",".join("?" * len(ids))
            with amane_db() as conn:
                for r in conn.execute(
                        f"SELECT id, number, title, studio FROM metadata WHERE id IN ({ph})",
                        tuple(ids)):
                    snap[int(r["id"])] = {"number": str(r["number"] or ""),
                                          "title": str(r["title"] or ""),
                                          "studio": str(r["studio"] or "")}
        items = []
        for mid in sorted(ids):
            s = snap.get(mid, {})
            h = hist.get(mid)
            items.append({
                "number": s.get("number", ""),
                "metadata_id": mid,
                # —— 内容快照：导入端没匹配到也能看出这是哪部 ——
                "title": s.get("title", ""),
                "studio": s.get("studio", ""),
                "favorite_at": favs.get(mid, ""),
                "rating": rates.get(mid, 0),
                "watch_later_at": later.get(mid, ""),
                "history": None if h is None else {
                    "position": round(float(h["position"] or 0), 1),
                    "duration": round(float(h["duration"] or 0), 1),
                    "played_at": h["played_at"],
                    "finished": int(h["finished"] or 0),
                },
                "collections": colls.get(mid, []),
            })
        self._json({
            "format": self.BACKUP_FORMAT,
            "exported_at": now_iso(),
            "server_version": VERSION,
            "count": len(items),
            "counts": {"favorites": len(favs), "ratings": len(rates), "history": len(hist),
                       "watch_later": len(later), "collections": len(colls)},
            "items": items,
        })

    @route("POST", r"/api/user/backup/import")
    def backup_import(self, query, *_):
        """导入备份：**按番号为主键**匹配，匹配不到的记进 `unmatched`，不猜。

        `mode=merge`（默认）只补缺、覆盖有值的字段；`mode=replace` 会先清空这五张表。
        `dry_run=1` 只统计不写库（客户端先给用户看一眼再决定）；
        `kinds=favorites,ratings,...` 只导其中几类；真导入前会先拍一张快照，`/backup/rollback` 可撤回。
        """
        body = self._body()
        items = body.get("items") or []
        if not isinstance(items, list) or not items:
            return self._error(422, "没有可导入的数据")
        mode = str((query.get("mode") or [body.get("mode") or "merge"])[0]).lower()
        if mode not in ("merge", "replace"):
            mode = "merge"
        dry_raw = (query.get("dry_run") or [body.get("dry_run") or ""])[0]
        dry_run = str(dry_raw).lower() in ("1", "true", "yes")
        raw_kinds = query.get("kinds") or [body.get("kinds") or "all"]
        kinds_txt = raw_kinds[0] if isinstance(raw_kinds, list) else str(raw_kinds)
        if isinstance(kinds_txt, list):
            kinds_txt = ",".join(str(x) for x in kinds_txt)
        want = {k.strip() for k in str(kinds_txt).split(",") if k.strip()}
        do_all = (not want) or ("all" in want)
        def on(k: str) -> bool:
            return do_all or k in want
        applied = {"favorites": 0, "ratings": 0, "history": 0,
                   "watch_later": 0, "collections": 0}
        unmatched: list[str] = []
        now = now_iso()
        snap_name = ""
        if not dry_run:
            snap_name = backup_write(backup_snapshot())
        with user_db() as conn:
            if mode == "replace" and not dry_run:
                for t in ("favorites", "user_ratings", "history", "watch_later"):
                    conn.execute(f"DELETE FROM {t}")
                conn.execute("DELETE FROM collection_items")
            for it in items:
                if not isinstance(it, dict):
                    continue
                number = str(it.get("number") or "").strip()
                mid = 0
                if number:
                    with amane_db() as adb:
                        row = adb.execute(
                            "SELECT id FROM metadata WHERE number = ? LIMIT 1", (number,)).fetchone()
                    if row is not None:
                        mid = int(row["id"])
                if mid <= 0:
                    try:
                        cand = int(it.get("metadata_id") or 0)
                    except (TypeError, ValueError):
                        cand = 0
                    if cand > 0:
                        with amane_db() as adb:
                            row = adb.execute(
                                "SELECT id FROM metadata WHERE id = ? LIMIT 1", (cand,)).fetchone()
                        if row is not None:
                            mid = int(row["id"])
                if mid <= 0:
                    unmatched.append(number or str(it.get("metadata_id") or "?"))
                    continue
                if on("favorites") and str(it.get("favorite_at") or "") != "":
                    if not dry_run:
                        conn.execute(
                            "INSERT INTO favorites(metadata_id, created_at) VALUES(?,?) "
                            "ON CONFLICT(metadata_id) DO NOTHING",
                            (mid, str(it["favorite_at"])))
                    applied["favorites"] += 1
                try:
                    score = int(it.get("rating") or 0)
                except (TypeError, ValueError):
                    score = 0
                if on("ratings") and score > 0:
                    if not dry_run:
                        conn.execute(
                            "INSERT INTO user_ratings(metadata_id, score, updated_at) VALUES(?,?,?) "
                            "ON CONFLICT(metadata_id) DO UPDATE SET score = excluded.score, "
                            "updated_at = excluded.updated_at",
                            (mid, score, now))
                    applied["ratings"] += 1
                if on("watch_later") and str(it.get("watch_later_at") or "") != "":
                    if not dry_run:
                        conn.execute(
                            "INSERT INTO watch_later(metadata_id, created_at) VALUES(?,?) "
                            "ON CONFLICT(metadata_id) DO NOTHING",
                            (mid, str(it["watch_later_at"])))
                    applied["watch_later"] += 1
                h = it.get("history")
                if on("history") and isinstance(h, dict):
                    pos = float(h.get("position") or 0)
                    if pos > 0 or int(h.get("finished") or 0) > 0:
                        if not dry_run:
                            conn.execute(
                                "INSERT INTO history(metadata_id, position, duration, played_at, finished) "
                                "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                                "position = MAX(history.position, excluded.position), "
                                "duration = excluded.duration, played_at = excluded.played_at, "
                                "finished = MAX(history.finished, excluded.finished)",
                                (mid, pos, float(h.get("duration") or 0),
                                 str(h.get("played_at") or now), 1 if h.get("finished") else 0))
                        applied["history"] += 1
                if not on("collections"):
                    continue
                for name in (it.get("collections") or []):
                    cname = str(name or "").strip()
                    if not cname:
                        continue
                    if dry_run:
                        applied["collections"] += 1
                        continue
                    conn.execute("INSERT OR IGNORE INTO collections(name, created_at) VALUES(?,?)",
                                 (cname, now))
                    crow = conn.execute(
                        "SELECT id FROM collections WHERE name = ?", (cname,)).fetchone()
                    if crow is None:
                        continue
                    conn.execute(
                        "INSERT OR IGNORE INTO collection_items(collection_id, metadata_id, created_at) "
                        "VALUES(?,?,?)", (int(crow["id"]), mid, now))
                    applied["collections"] += 1
        self._json({"ok": True, "mode": mode, "dry_run": dry_run, "applied": applied,
                    "matched": len(items) - len(unmatched), "unmatched": unmatched[:200],
                    "unmatched_count": len(unmatched), "snapshot": snap_name})

    @route("GET", r"/api/user/backup/rollback-info")
    def backup_rollback_info(self, query, *_):
        """有没有可回滚的导入前快照（客户端用它决定是否显示「撤销导入」）。"""
        name, snap = backup_latest()
        self._json({
            "available": name != "",
            "file": name,
            "taken_at": "" if snap is None else str(snap.get("taken_at") or ""),
            "counts": {} if snap is None else {
                "favorites": len(snap.get("favorites") or []),
                "ratings": len(snap.get("user_ratings") or []),
                "history": len(snap.get("history") or []),
                "watch_later": len(snap.get("watch_later") or []),
                "collections": len(snap.get("collections") or []),
            },
        })

    @route("POST", r"/api/user/backup/rollback")
    def backup_rollback(self, query, *_):
        """用最近一份「导入前快照」把数据整表恢复回去（导入搞坏了就用它）。"""
        name, snap = backup_latest()
        if snap is None:
            return self._error(404, "没有可回滚的导入前快照")
        counts = backup_restore(snap)
        invalidate_item_caches()
        self._json({"ok": True, "restored_from": name,
                    "taken_at": str(snap.get("taken_at") or ""), "counts": counts})
