"""稍后再看（watch later）。

一个纯用户侧的标记：把「现在不想看、回头再看」的片子单独排一队，
既不是收藏（收藏是「我拥有/我中意」），也不是观看记录（那个是已经看过的）。

存哪：旁挂服务自己的 user.db，**不写 amane 的库**，也不触发入库、不影响评分。
理由是这条数据只对使用者本人有意义，上游没有对应概念（没有 watch_later 列）。

两个钩子 + 三个端点：
  * `item_extra`   → 详情页回 `watch_later: true/false`，页面不用额外请求；
  * `browse_where` → `?watchlater=1` 让核心 browse 只出这个队列里的片子，
    这样列表自动带上标记、我的评分、播放进度等核心字段，不用另写一套列表接口；
  * `GET /watch_later`      → 仅 id 列表（客户端判断状态、页头计数用）；
    `POST /watch_later/{id}` → 加入（幂等）；
    `DELETE /watch_later/{id}` → 移出。

顺序：`created_at` 倒序 = 最近加入的排前面；`created_at` 用旁挂服务的 now_iso()，
同一秒内加入的两条按 rowid 兜底，保证顺序稳定。
"""

# 由 install() 注入的扩展宿主（server.py 的 ExtensionHost）
A = None

DDL = """
CREATE TABLE IF NOT EXISTS watch_later (
    metadata_id INTEGER PRIMARY KEY,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_watch_later_created ON watch_later(created_at DESC);
"""


def _num(v) -> int:
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


def _ids() -> list:
    """队列里的影片 id，最近加入的在前。"""
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT metadata_id FROM watch_later ORDER BY created_at DESC, rowid DESC"
        ).fetchall()
    return [_num(r["metadata_id"]) for r in rows if _num(r["metadata_id"]) > 0]


# --------------------------------------------------------------------- hooks
def on_item_extra(mid: int) -> dict:
    """详情页补 `watch_later`：这一部在不在队列里。"""
    try:
        with A.user_db() as conn:
            row = conn.execute(
                "SELECT 1 FROM watch_later WHERE metadata_id = ?", (int(mid),)).fetchone()
        return {"watch_later": row is not None}
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN watch_later item_extra id={mid}: {exc}")
        return {"watch_later": False}


def on_browse_where(query: dict) -> dict:
    """`?watchlater=1` 只出队列里的片子。

    返回 clauses 而不是自己拼 SQL：核心会把它 AND 进 browse 的 WHERE，
    标记、我的评分、播放进度这些字段就都由核心照常补齐。
    """
    raw = ((query.get("watchlater") or [""])[0]).strip().lower()
    if raw not in ("1", "true", "yes"):
        return {}
    try:
        ids = _ids()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN watch_later browse_where: {exc}")
        return {}
    if not ids:
        return {"clauses": [("1 = 0", [])]}
    return {"clauses": [(f"m.id IN ({','.join(str(i) for i in ids)})", [])]}


# --------------------------------------------------------------------- routes
def list_ids(handler, query, *_):
    """GET /api/user/watch_later —— 只有 id 列表（客户端判断状态、页头计数）。"""
    try:
        ids = _ids()
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"读取稍后再看失败: {exc}")
    handler._json({"ids": ids, "total": len(ids)})


def add(handler, query, mid, *_):
    """POST /api/user/watch_later/{id} —— 加入稍后再看（重复加入不报错）。"""
    # 必须把 body 读掉：这个端点不需要参数，但 keep-alive 连接上没读完的
    # 请求体会被当成下一个请求的开头（实测客户端带 `{}` 时下一个 GET 会变成
    # `{}GET ...` 直接 501）。读掉就算丢掉，也比污染连接好。
    handler._body()
    meta_id = _num(mid)
    if meta_id <= 0:
        return handler._error(400, "影片 id 不合法")
    try:
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO watch_later(metadata_id, created_at) VALUES(?, ?) "
                "ON CONFLICT(metadata_id) DO NOTHING", (meta_id, A.now_iso()))
            total = int(conn.execute(
                "SELECT COUNT(*) AS c FROM watch_later").fetchone()["c"])
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR watch_later add {meta_id}: {exc}")
        return handler._error(500, f"加入稍后再看失败: {exc}")
    handler._json({"ok": True, "id": meta_id, "watch_later": True, "total": total})


def remove(handler, query, mid, *_):
    """DELETE /api/user/watch_later/{id} —— 移出稍后再看（本来没有也回 ok）。"""
    meta_id = _num(mid)
    if meta_id <= 0:
        return handler._error(400, "影片 id 不合法")
    try:
        with A.user_db() as conn:
            conn.execute("DELETE FROM watch_later WHERE metadata_id = ?", (meta_id,))
            total = int(conn.execute(
                "SELECT COUNT(*) AS c FROM watch_later").fetchone()["c"])
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR watch_later remove {meta_id}: {exc}")
        return handler._error(500, f"移出稍后再看失败: {exc}")
    handler._json({"ok": True, "id": meta_id, "watch_later": False, "total": total})


ROUTES = [
    ("GET", r"/api/user/watch_later", list_ids),
    ("POST", r"/api/user/watch_later/(\d+)", add),
    ("DELETE", r"/api/user/watch_later/(\d+)", remove),
]


def install(api) -> dict:
    global A  # noqa: PLW0603
    A = api
    api.add_ddl(DDL)
    api.hook("item_extra", on_item_extra)
    api.hook("browse_where", on_browse_where)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 watch_later 已启用（{len(ROUTES)} 个端点 + 2 个钩子）")
    return {"id": "watch_later", "routes": len(ROUTES)}
