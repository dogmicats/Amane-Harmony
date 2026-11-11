#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：收藏夹（用户自创清单）。

一部影片可以同时属于多个清单；清单里的片子隐含「已收藏」，取消收藏时
自动清掉所有清单关联（挂 favorite_del 钩子，客户端不用额外发请求）。

数据全在 user.db，核心 server.py 不出现 collections 字样，靠四个通用钩子接入：
  * item_extra      —— 详情接口补 `collection_ids`；
  * favorite_del    —— 取消收藏时清关联；
  * browse_where    —— `collection=<id>` / `collection=none` 过滤任意列表；
  * (无 marks_extra)—— 不在卡片标记里塞清单名，避免污染统一徽标。
"""
from __future__ import annotations

A = None  # type: ignore[assignment]

DDL = """
CREATE TABLE IF NOT EXISTS collections (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS collection_items (
    collection_id INTEGER NOT NULL,
    metadata_id   INTEGER NOT NULL,
    created_at    TEXT NOT NULL,
    UNIQUE(collection_id, metadata_id)
);
CREATE INDEX IF NOT EXISTS idx_collection_items_meta ON collection_items(metadata_id);
"""

MAX_NAME = 24
MAX_LISTS = 60


def _clean_name(raw) -> str:
    return " ".join(str(raw or "").split())[:MAX_NAME]


def _int(raw, default: int = 0) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------- hooks
def on_item_extra(mid: int) -> dict:
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT collection_id FROM collection_items WHERE metadata_id = ? "
                "ORDER BY collection_id", (mid,)
            ).fetchall()
        return {"collection_ids": [int(r["collection_id"]) for r in rows]}
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR collections item_extra id={mid}: {exc}")
        return {"collection_ids": []}


def on_favorite_del(mid: int) -> dict:
    """取消收藏 = 退出所有清单。保留 favorites 表本身由核心处理。"""
    try:
        with A.user_db() as conn:
            conn.execute("DELETE FROM collection_items WHERE metadata_id = ?", (mid,))
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR collections favorite_del id={mid}: {exc}")
    return {}


def on_marks_extra(items: list) -> dict:
    """列表卡补 `collection_ids`：历史记录这类不走 browse 的列表页要能按清单筛。

    挂在 marks_extra 上，和 ratings 一样借核心 `attach_marks()` 覆盖所有影片列表；
    客户端只在需要按收藏夹筛选的页面读它，不显示时只多一个小数组。
    """
    if not items:
        return {}
    ids = [int(it.get("id")) for it in items if isinstance(it, dict) and it.get("id")]
    if not ids:
        return {}
    ph = ",".join("?" * len(ids))
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, collection_id FROM collection_items "
                f"WHERE metadata_id IN ({ph})", ids
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN collections marks_extra: {exc}")
        return {}
    bucket: dict[int, list] = {}
    for r in rows:
        bucket.setdefault(int(r["metadata_id"]), []).append(int(r["collection_id"]))
    for it in items:
        if not isinstance(it, dict):
            continue
        it["collection_ids"] = sorted(bucket.get(int(it.get("id") or 0), []))
    return {}


def on_browse_where(query: dict) -> dict:
    """collection=<清单id> 只出该清单；none = 收藏了但没归类；any = 全部收藏。

    注意返回的是 clauses 列表，核心会按顺序 AND 起来；多个扩展各自返回
    clauses 时由核心逐扩展累加，不能靠 EXT.call() 的 dict 合并。
    `any` 是给收藏页用的：那一页要能按「我的评分」筛选和排序，走 browse 才能用
    核心的排序能力，而 browse 本身并不知道「哪些片子被收藏了」。
    """
    raw = ((query.get("collection") or [""])[0]).strip().lower()
    if not raw:
        return {}
    try:
        with A.user_db() as conn:
            if raw == "any":
                ids = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT metadata_id FROM favorites")]
            elif raw == "none":
                # 「已收藏但没归入任何清单」：以 favorites 为准，排除已归类的
                fav = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT metadata_id FROM favorites")]
                placed = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT DISTINCT metadata_id FROM collection_items")]
                ids = sorted(set(fav) - set(placed))
            else:
                cid = _int(raw, -1)
                if cid <= 0:
                    return {}
                ids = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT metadata_id FROM collection_items WHERE collection_id = ?", (cid,))]
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN collections browse_where: {exc}")
        return {}
    if not ids:
        return {"clauses": [("1 = 0", [])]}
    return {"clauses": [(f"m.id IN ({','.join(str(i) for i in ids)})", [])]}


# --------------------------------------------------------------------- routes
def list_all(self, query, *_):
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT c.id, c.name, c.created_at, "
            "  (SELECT COUNT(*) FROM collection_items i WHERE i.collection_id = c.id) n "
            "FROM collections c ORDER BY c.id"
        ).fetchall()
        placed = conn.execute(
            "SELECT COUNT(DISTINCT metadata_id) FROM collection_items").fetchone()[0]
        favs = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
    self._json({"items": [dict(r) for r in rows], "placed": placed, "favorites": favs})


def create(self, query, *_):
    name = _clean_name((self._body() or {}).get("name"))
    if not name:
        return self._error(400, "清单名不能为空")
    with A.user_db() as conn:
        if conn.execute("SELECT COUNT(*) FROM collections").fetchone()[0] >= MAX_LISTS:
            return self._error(400, f"清单最多 {MAX_LISTS} 个")
        try:
            cur = conn.execute(
                "INSERT INTO collections(name, created_at) VALUES(?, ?)", (name, A.now_iso()))
        except Exception as exc:  # noqa: BLE001
            if "UNIQUE" in str(exc).upper():
                return self._error(409, "已经有同名清单了")
            raise
        cid = cur.lastrowid
    self._json({"ok": True, "id": cid, "name": name})


def rename(self, query, cid, *_):
    name = _clean_name((self._body() or {}).get("name"))
    if not name:
        return self._error(400, "清单名不能为空")
    with A.user_db() as conn:
        try:
            cur = conn.execute(
                "UPDATE collections SET name = ? WHERE id = ?", (name, int(cid)))
        except Exception as exc:  # noqa: BLE001
            if "UNIQUE" in str(exc).upper():
                return self._error(409, "已经有同名清单了")
            raise
        if not cur.rowcount:
            return self._error(404, "清单不存在")
    self._json({"ok": True, "id": int(cid), "name": name})


def remove(self, query, cid, *_):
    with A.user_db() as conn:
        cur = conn.execute("DELETE FROM collections WHERE id = ?", (int(cid),))
        conn.execute("DELETE FROM collection_items WHERE collection_id = ?", (int(cid),))
    if not cur.rowcount:
        return self._error(404, "清单不存在")
    self._json({"ok": True, "removed": int(cid)})


def of_item(self, query, mid, *_):
    rows = []
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT collection_id FROM collection_items WHERE metadata_id = ? "
            "ORDER BY collection_id", (int(mid),)
        ).fetchall()
    self._json({"ids": [int(r["collection_id"]) for r in rows]})


def set_item(self, query, mid, *_):
    """设置这部影片归到哪些清单；非空时自动补一条 favorites（归类即收藏）。"""
    raw = (self._body() or {}).get("ids") or []
    if not isinstance(raw, list):
        return self._error(400, "ids 必须是数组")
    ids = sorted({_int(x, -1) for x in raw if _int(x, -1) > 0})[:MAX_LISTS]
    mid_i = int(mid)
    with A.user_db() as conn:
        known = {int(r["id"]) for r in conn.execute("SELECT id FROM collections")}
        ids = [i for i in ids if i in known]
        conn.execute("DELETE FROM collection_items WHERE metadata_id = ?", (mid_i,))
        now = A.now_iso()
        for cid in ids:
            conn.execute(
                "INSERT OR IGNORE INTO collection_items(collection_id, metadata_id, created_at) "
                "VALUES(?, ?, ?)", (cid, mid_i, now))
        if ids:
            conn.execute(
                "INSERT OR IGNORE INTO favorites(metadata_id, created_at) VALUES(?, ?)",
                (mid_i, now))
    self._json({"ok": True, "ids": ids, "favorite": bool(ids)})


ROUTES = [
    ("GET",    r"/api/user/collections",               list_all),
    ("POST",   r"/api/user/collections",               create),
    ("PUT",    r"/api/user/collections/(\d+)",         rename),
    ("DELETE", r"/api/user/collections/(\d+)",         remove),
    ("GET",    r"/api/user/collections/of/(\d+)",      of_item),
    ("PUT",    r"/api/user/collections/of/(\d+)",      set_item),
]


def install(api) -> dict:
    global A
    A = api
    api.add_ddl(DDL)
    api.hook("item_extra", on_item_extra)
    api.hook("marks_extra", on_marks_extra)
    api.hook("favorite_del", on_favorite_del)
    api.hook("browse_where", on_browse_where)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    A.log(f"扩展 collections 已启用（{len(ROUTES)} 个端点 + 3 钩子）")
    return {"id": "collections", "enabled": True, "scope": "public"}
