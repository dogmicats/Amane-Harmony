#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：我的评分（1–5 星）。

与上游 metadata.scores（javdb 外站评分）完全是两套数据：这里只存用户自己
打的分，落在 user.db，不碰 amane.db，也不改上游评分的筛选与排序。

靠四个通用钩子接进核心，核心 server.py 不出现 ratings 字样：
  * item_extra    —— 详情接口补 `my_rating`；
  * marks_extra   —— 列表卡片标记追加「★N」；
  * browse_where  —— `myrating=<1..5|none>` 过滤任意列表；
  * browse_sort   —— `sort=myrating` 时提供按分数分档的 CASE 表达式。

排序为什么用 CASE 分档而不是 JOIN：browse 的 SQL 跑在 amane.db 的只读连接上，
评分表在 user.db，跨库不能 JOIN。改成按分数把 id 分成 5 组，生成只有 5 个
WHEN 的 CASE，未打分的 ELSE 0 排最后，SQL 长度与评分数量线性相关但表达式深度恒定。
"""
from __future__ import annotations

A = None  # type: ignore[assignment]

DDL = """
CREATE TABLE IF NOT EXISTS user_ratings (
    metadata_id INTEGER PRIMARY KEY,
    score       INTEGER NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_user_ratings_score ON user_ratings(score);
"""

SORT_KEY = "myrating"


# --------------------------------------------------------------------- hooks
def on_item_extra(mid: int) -> dict:
    try:
        with A.user_db() as conn:
            row = conn.execute(
                "SELECT score FROM user_ratings WHERE metadata_id = ?", (mid,)
            ).fetchone()
        return {"my_rating": int(row["score"]) if row else 0}
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR ratings item_extra id={mid}: {exc}")
        return {"my_rating": 0}


def on_marks_extra(items: list) -> dict:
    """列表卡补 `my_rating`（0 = 没打过分）。

    挂在 marks_extra 上是因为核心的 `attach_marks()` 是所有影片列表的必经之路
    （媒体库/首页/收藏/历史/标签/演员作品/共演），一个钩子就能全覆盖。
    早先这里往 `marks` 里塞「★N」，与海报卡新加的「我的评价」标签重复，
    2.4.6 起改成只给数值字段，由客户端按星级语义渲染文字。
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
                f"SELECT metadata_id, score FROM user_ratings WHERE metadata_id IN ({ph})",
                ids,
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN ratings marks_extra: {exc}")
        return {}
    scores = {int(r["metadata_id"]): int(r["score"]) for r in rows}
    for it in items:
        if not isinstance(it, dict):
            continue
        it["my_rating"] = max(0, min(5, scores.get(int(it.get("id") or 0), 0)))
    return {}


def on_browse_where(query: dict) -> dict:
    """myrating=5 / 4 / … 「N 星及以上」；myrating=none 「还没打过分」。"""
    raw = ((query.get("myrating") or [""])[0]).strip().lower()
    if not raw:
        return {}
    try:
        with A.user_db() as conn:
            if raw == "none":
                ids = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT metadata_id FROM user_ratings")]
            elif raw in ("1", "2", "3", "4", "5"):
                ids = [int(r["metadata_id"]) for r in conn.execute(
                    "SELECT metadata_id FROM user_ratings WHERE score >= ?", (int(raw),))]
            else:
                return {}
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN ratings browse_where: {exc}")
        return {}
    if raw == "none":
        if not ids:
            return {}  # 全库都没打过分，条件恒真
        return {"clauses": [(f"m.id NOT IN ({','.join(str(i) for i in ids)})", [])]}
    if not ids:
        return {"clauses": [("1 = 0", [])]}
    return {"clauses": [(f"m.id IN ({','.join(str(i) for i in ids)})", [])]}


def on_browse_sort(sort: str):
    """求值型钩子：只回答自己认识的排序键，其余返回 None 让核心按 SORTS 处理。"""
    if sort != SORT_KEY:
        return None
    try:
        with A.user_db() as conn:
            rows = conn.execute("SELECT metadata_id, score FROM user_ratings").fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN ratings browse_sort: {exc}")
        return {"expr": "0", "dir": "desc"}
    buckets: dict[int, list[int]] = {}
    for r in rows:
        score = max(1, min(5, int(r["score"])))
        buckets.setdefault(score, []).append(int(r["metadata_id"]))
    if not buckets:
        return {"expr": "0", "dir": "desc"}
    whens = [
        f"WHEN m.id IN ({','.join(str(i) for i in buckets[s])}) THEN {s}"
        for s in sorted(buckets, reverse=True)
    ]
    return {"expr": "CASE " + " ".join(whens) + " ELSE 0 END", "dir": "desc"}


# --------------------------------------------------------------------- routes
def get_one(self, query, mid, *_):
    with A.user_db() as conn:
        row = conn.execute(
            "SELECT score, updated_at FROM user_ratings WHERE metadata_id = ?", (int(mid),)
        ).fetchone()
    self._json({"score": int(row["score"]) if row else 0,
                "updated_at": row["updated_at"] if row else ""})


def put_one(self, query, mid, *_):
    """score 0 表示清除评分；1–5 之外报错。"""
    body = self._body() or {}
    try:
        score = int(body.get("score", 0))
    except (TypeError, ValueError):
        return self._error(400, "score 必须是 0–5 的整数")
    if score < 0 or score > 5:
        return self._error(400, "score 必须是 0–5 的整数")
    mid_i = int(mid)
    with A.user_db() as conn:
        if score == 0:
            conn.execute("DELETE FROM user_ratings WHERE metadata_id = ?", (mid_i,))
        else:
            conn.execute(
                "INSERT INTO user_ratings(metadata_id, score, updated_at) VALUES(?, ?, ?) "
                "ON CONFLICT(metadata_id) DO UPDATE SET score=excluded.score, "
                "updated_at=excluded.updated_at",
                (mid_i, score, A.now_iso()),
            )
    A.log(f"我的评分 id={mid_i} → {score}")
    self._json({"ok": True, "score": score})


def del_one(self, query, mid, *_):
    with A.user_db() as conn:
        conn.execute("DELETE FROM user_ratings WHERE metadata_id = ?", (int(mid),))
    self._json({"ok": True, "score": 0})


def list_all(self, query, *_):
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT metadata_id, score, updated_at FROM user_ratings "
            "ORDER BY score DESC, updated_at DESC"
        ).fetchall()
    self._json({"items": [dict(r) for r in rows]})


ROUTES = [
    ("GET",    r"/api/user/ratings",          list_all),
    ("GET",    r"/api/user/ratings/(\d+)",    get_one),
    ("PUT",    r"/api/user/ratings/(\d+)",    put_one),
    ("DELETE", r"/api/user/ratings/(\d+)",    del_one),
]


def install(api) -> dict:
    global A
    A = api
    api.add_ddl(DDL)
    api.hook("item_extra", on_item_extra)
    api.hook("marks_extra", on_marks_extra)
    api.hook("browse_where", on_browse_where)
    api.hook("browse_sort", on_browse_sort)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    A.log(f"扩展 ratings 已启用（{len(ROUTES)} 个端点 + 4 钩子）")
    return {"id": "ratings", "enabled": True, "scope": "public"}
