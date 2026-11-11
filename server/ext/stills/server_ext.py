#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：抽卡模式（随机剧照墙）—— 任意列表页的随机剧照来源（scope=public）。

演员详情页原来有一块「盲盒剧照」，只服务单个演员。用户要求把它扩展到
**每个列表页**（标签 / 系列 / 制片商 / 发行商 / 导演 / 我的标签 / 媒体库 / 收藏），
所以这里把「取随机剧照」抽成一个通用的 scope 参数，而不是每个页面各写一套 SQL：

    GET /api/user/stills?scope=tag&id=12&limit=10

    scope = tag | series | studio | publisher | director | user_tag
          | actor | library | favorite | all
    id    = 对应实体 id（scope=all / favorite 时可省略）
    limit = 1..36，客户端一次多拿（默认 10 条），本地轮换，换一批不再等网络

三条口径沿用演员页那套（真机验证过的经验，别重新拍脑袋）：

  1. **首帧就要摆对**：每条带 `ratio`（核心 img_dims 缓存，命中零网络；
     没量过只取图片头 128KB），客户端瀑布流第一帧就是最终版式。
  2. **随机要分散**：先随机挑若干部片，再在片内轮转取图，避免一屏全是同一部。
  3. **时间要有预算**：测比例共用一个 2 秒总预算，超时先返回已有的，
     剩下的丢后台预热（下次直接命中缓存）。

不 import server.py：依赖全部由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait as fwait

A = None  # type: ignore[assignment]

# 内置 scope。每个值对应 _scope_where() 里的一条 SQL 片段。
# 此外还接受**扩展声明的 scope**：不在这张表里的值会去问 `stills_where` 钩子
# （共演筛选结果页就是 `scope=cast`，筛选 SQL 留在 actors 扩展里，只有一份）。
SCOPES = {
    "tag", "series", "studio", "publisher", "director", "user_tag",
    "actor", "library", "favorite", "all",
}

# 测比例的全局预算：再多 scope 也不许超过这个时间，超了先返回已有的。
MEASURE_BUDGET: float = 2.0
# 候选片数上限：一次最多看这么多部片的剧照（每部取一张，剩下的轮转）。
CANDIDATE_CAP: int = 96

# ---- 喜爱的剧照（用户数据，落 user.db，不写上游） -------------------------- #
# 一条记录 = 「喜欢这部片里的这张图」。key 用 (影片 id, 图片地址)：
# 地址就是客户端拿到的 /img?b=…&t=…（IMAGE_TOKEN 是持久化密钥，重启不变），
# 所以同一张图在不同页面点两次不会重复，取消也按同一对键删。
# ratio 是喜欢那一刻的宽高比，存下来后瀑布流不用再逐张量图。
DDL = """
CREATE TABLE IF NOT EXISTS still_likes (
    metadata_id INTEGER NOT NULL,
    url         TEXT NOT NULL,
    ratio       REAL NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    PRIMARY KEY (metadata_id, url)
);
CREATE INDEX IF NOT EXISTS idx_still_likes_created ON still_likes(created_at DESC);
"""

# 图片地址一律走核心代理（/img?b=…）：只收这种形态，别把本表当任意 URL 仓库。
_IMG_PREFIX = "/img?"
MAX_URL_LEN = 2048


def _one(query: dict, key: str, default: str = "") -> str:
    return (query.get(key) or [default])[0]


def _text(value) -> str:
    return value if isinstance(value, str) else ""


def _int(value, default: int, lo: int, hi: int) -> int:
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def _fav_ids(limit: int) -> list[int]:
    """收藏是旁挂 user.db 的 favorites 表，跨不到 amane 的只读库，先取 id 再 IN。"""
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id FROM favorites ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN stills 取收藏失败: {exc}")
        return []
    return [int(r["metadata_id"]) for r in rows]


def _scope_where(scope: str, sid: int) -> tuple[str, list] | None:
    """scope → (WHERE 片段, 参数)。返回 None 表示参数不合法。"""
    if scope == "all":
        return "1 = 1", []
    if scope == "favorite":
        ids = _fav_ids(4000)
        if not ids:
            return "1 = 0", []          # 没有收藏：空结果，不算错误
        ph = ",".join("?" * len(ids))
        return f"m.id IN ({ph})", ids
    if sid <= 0:
        return None
    if scope == "tag":
        return ("m.id IN (SELECT metadata_id FROM metadata_tags WHERE tag_id = ?)", [sid])
    if scope == "director":
        return ("m.id IN (SELECT metadata_id FROM metadata_directors WHERE director_id = ?)", [sid])
    if scope == "user_tag":
        return ("m.id IN (SELECT metadata_id FROM metadata_user_tags WHERE user_tag_id = ?)", [sid])
    if scope == "actor":
        return ("m.id IN (SELECT metadata_id FROM metadata_actors WHERE actor_id = ?)", [sid])
    if scope == "library":
        return ("m.id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)", [sid])
    # 标量分类：metadata 上存的是名字，不是 id（与 facets 扩展同一口径）
    if scope == "series":
        return ("m.series IN (SELECT name FROM series WHERE id = ?)", [sid])
    if scope == "studio":
        return ("m.studio IN (SELECT name FROM studios WHERE id = ?)", [sid])
    if scope == "publisher":
        return ("m.publisher IN (SELECT name FROM publishers WHERE id = ?)", [sid])
    return None


def _hook_scope(scope: str, query: dict):
    """问各扩展「这个 scope 的筛选片段长什么样」。

    范围归属于谁，就由谁的扩展回答：共演的筛选 SQL 在 actors 扩展里只有一份，
    抽卡墙拿过去套同一套 WHERE，结果页筛了什么、抽卡就抽什么。
    核心 ≥1.3.14 才注入 call_hook；注入不到就当不支持，回 400。
    """
    fn = getattr(A, "call_hook", None)
    if fn is None:
        return None
    try:
        res = fn("stills_where", scope, query)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN stills 钩子 {scope} 失败: {exc}")
        return None
    if not isinstance(res, dict):
        return None
    where = res.get("where")
    if not isinstance(where, str) or not where.strip():
        return None
    args = res.get("args")
    return where, (list(args) if isinstance(args, (list, tuple)) else [])


def _lane_urls(raw) -> list[str]:
    """extrafanart_urls 是「分组 → URL 列表」的字典（历史数据也有纯数组）。"""
    try:
        extra = A.json.loads(raw) if isinstance(raw, str) else {}
    except (TypeError, ValueError):
        extra = {}
    urls: list[str] = []
    if isinstance(extra, dict):
        for group in extra.values():
            urls.extend([u for u in (group or []) if isinstance(u, str) and u.startswith("http")])
    elif isinstance(extra, list):
        urls = [u for u in extra if isinstance(u, str) and u.startswith("http")]
    return list(dict.fromkeys(urls))


def stills(handler, query, *_):
    """GET /api/user/stills —— 任意 scope 的随机剧照墙。"""
    scope = _text(_one(query, "scope", "all")).strip().lower()
    sid = _int(_one(query, "id", "0"), 0, 0, 10 ** 9)
    limit = _int(_one(query, "limit", "10"), 10, 1, 36)
    if scope in SCOPES:
        built = _scope_where(scope, sid)
        if built is None:
            return handler._error(400, f"scope={scope} 需要有效的 id")
        where, args = built
    else:
        hooked = _hook_scope(scope, query)
        if hooked is None:
            return handler._error(400, f"不支持的 scope: {scope or '(空)'}")
        where, args = hooked

    want = max(limit * 3, 24)
    if want > CANDIDATE_CAP:
        want = CANDIDATE_CAP
    sql = (
        "SELECT m.id, m.number, m.extrafanart_urls FROM metadata m "
        "WHERE " + where + " "
        "AND EXISTS (SELECT 1 FROM media_files f WHERE f.metadata_id = m.id) "
        "AND m.extrafanart_urls IS NOT NULL "
        "AND m.extrafanart_urls NOT IN ('', '[]', '{}') "
        "ORDER BY RANDOM() LIMIT ?"
    )
    try:
        with A.amane_db() as conn:
            rows = conn.execute(sql, (*args, want)).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR stills 取剧照失败 scope={scope} id={sid}: {exc}")
        return handler._error(500, f"剧照查询失败: {exc}")

    # 每部片一组候选 URL（打乱），按「轮转」各取一张，保证一屏里片名分散
    lanes: list[tuple[dict, list[str]]] = []
    for r in rows:
        urls = _lane_urls(r["extrafanart_urls"])
        if not urls:
            continue
        random.shuffle(urls)
        lanes.append(({"id": _int(r["id"], 0, 0, 10 ** 9), "number": _text(r["number"])}, urls))

    items: list = []
    used: set[str] = set()
    deadline = time.time() + MEASURE_BUDGET

    def measure(pairs: list[tuple[dict, str]], cap: int) -> None:
        """并行量尺寸，合格的收进 items。

        两个关键点（都是真机实测踩出来的）：
          1. 只量「还需要的那几张」，不再整池全量（以前 90 部全量要 3~6 秒）；
          2. **硬预算**：用 wait(timeout=剩余预算) 等，到点就走。以前用
             `pool.map`，一张图卡到 8 秒超时就把整个请求拖到 8 秒 ——
             换成 fwait 之后最慢也在 2 秒出头返回，没量完的线程继续跑，
             结果落进 img_dims 缓存，下次直接命中。
        """
        if not pairs:
            return
        pairs = pairs[:max(cap * 2, 8)]
        pool = ThreadPoolExecutor(max_workers=min(16, len(pairs)))
        try:
            futs = {}
            for pair in pairs:
                futs[pool.submit(A.image_dims, pair[1])] = pair
            budget = max(0.05, deadline - time.time())
            done, _pending = fwait(list(futs.keys()), timeout=budget)
            for fut in done:
                if len(items) >= cap:
                    break
                row, url = futs[fut]
                try:
                    size = fut.result()
                except Exception:  # noqa: BLE001
                    size = None
                if not size or url in used:
                    continue
                proxied = A.public_image(url)
                if not proxied:
                    continue
                used.add(url)
                w, h = size
                items.append({
                    "id": row["id"],
                    "number": row["number"],
                    "url": proxied,
                    "ratio": round(w / h, 3),
                })
        finally:
            # 不等没回来的线程：它们只是量尺寸，回来会写进缓存给下一批用
            pool.shutdown(wait=False, cancel_futures=True)

    for round_no in range(4):
        if len(items) >= limit or time.time() > deadline:
            break
        pairs: list[tuple[dict, str]] = []
        for row, urls in lanes:
            if len(urls) <= round_no:
                continue
            pairs.append((row, urls[round_no]))
        need = limit - len(items)
        measure(pairs[:max(need + 4, 8)], limit)

    # 预算用完还差几张：把「还没量过」的也照样摆上去（ratio=0，客户端自己量一遍再重排）。
    # 一面墙缺一半，比「首帧比例略歪、180ms 后对齐」更难看。
    if len(items) < limit:
        for row, urls in lanes:
            if len(items) >= limit:
                break
            if urls[0] in used:      # 这部片已经出过一张了，别再占位
                continue
            for url in urls:
                if url in used:
                    continue
                proxied = A.public_image(url)
                if not proxied:
                    continue
                used.add(url)
                items.append({"id": row["id"], "number": row["number"], "url": proxied, "ratio": 0})
                break

    # 没量到比例的那几张，后台补进 img_dims，下一批就准了
    leftover: list[str] = []
    for _row, urls in lanes:
        for url in urls:
            if url not in used:
                leftover.append(url)
                break
    # 后台把这一批里「没量过」的图也量一遍（并行 4 路），写进 img_dims：
    # 客户端池子里剩下的那 20 张下次「换一批」就全是现成比例，不再跳位。
    if leftover:
        def warm() -> None:
            pool = ThreadPoolExecutor(max_workers=4)
            try:
                list(pool.map(A.image_dims, leftover[:40]))
            except Exception:  # noqa: BLE001
                pass
            finally:
                pool.shutdown(wait=False)

        try:
            threading.Thread(target=warm, daemon=True, name="stills-warm").start()
        except RuntimeError:
            pass

    handler._json({
        "scope": scope,
        "id": sid,
        "items": items,
        # 客户端据此判断「这个范围里到底有没有剧照」，空墙文案要分得清
        "candidates": len(lanes),
    })


# --------------------------------------------------------------------- hooks
def on_item_extra(mid: int) -> dict:
    """详情页补 `still_likes`：这部片里已经被喜欢的剧照地址。

    只回地址数组，客户端拿它和 `stills` 逐个比对，决定心形实心还是空心 ——
    不另开一次请求，也不把「第几张」这种易漂的序号写进库里。
    """
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT url FROM still_likes WHERE metadata_id = ? ORDER BY created_at DESC",
                (int(mid),),
            ).fetchall()
        return {"still_likes": [_text(r["url"]) for r in rows if _text(r["url"])]}
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR stills item_extra id={mid}: {exc}")
        return {"still_likes": []}


# --------------------------------------------------------------------- routes
def like_still(handler, query, *_):
    """POST /api/user/stills/like —— 喜欢 / 取消喜欢一张剧照。

    body: {id: 影片 id, url: 图片地址, ratio?: 宽高比, liked?: true|false}
    liked 缺省 true；传 false 就是取消。同一张图反复点只更新 ratio，不重复记。
    """
    body = handler._body() or {}
    try:
        mid = int(body.get("id") or 0)
    except (TypeError, ValueError):
        return handler._error(400, "id 必须是整数")
    if mid <= 0:
        return handler._error(400, "id 必填")
    url = _text(body.get("url")).strip()
    if not url.startswith(_IMG_PREFIX) or len(url) > MAX_URL_LEN:
        return handler._error(400, "url 必须是本服务的图片代理地址")
    try:
        ratio = float(body.get("ratio") or 0)
    except (TypeError, ValueError):
        ratio = 0.0
    if not (0.1 <= ratio <= 10):
        ratio = 0.0
    raw_liked = body.get("liked", True)
    liked = not (raw_liked is False
                 or str(raw_liked).strip().lower() in ("0", "false", "no"))
    try:
        with A.user_db() as conn:
            if liked:
                conn.execute(
                    "INSERT INTO still_likes(metadata_id, url, ratio, created_at) "
                    "VALUES(?, ?, ?, ?) "
                    "ON CONFLICT(metadata_id, url) DO UPDATE SET ratio=excluded.ratio",
                    (mid, url, ratio, A.now_iso()),
                )
            else:
                conn.execute(
                    "DELETE FROM still_likes WHERE metadata_id = ? AND url = ?", (mid, url))
            total = int(conn.execute(
                "SELECT COUNT(*) AS c FROM still_likes").fetchone()["c"])
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR stills like id={mid} liked={liked}: {exc}")
        return handler._error(500, f"保存失败: {exc}")
    handler._json({"ok": True, "liked": liked, "total": total})


def liked_stills(handler, query, *_):
    """GET /api/user/stills/liked —— 所有被喜欢的剧照。

    `order` 默认 `recent`（喜欢时间倒序）；传 `random` 则每次重新打乱 ——
    收藏页的瀑布流用随机，目的是「翻到哪张看哪张」，而不是反复看最近的三张。
    分页在随机模式下没有稳定顺序，客户端一次取满即可。
    """
    limit = _int(_one(query, "limit", "200"), 200, 1, 200)
    offset = _int(_one(query, "offset", "0"), 0, 0, 10 ** 9)
    order = _one(query, "order", "recent").strip().lower()
    order_sql = "RANDOM()" if order == "random" else "created_at DESC, rowid DESC"
    try:
        with A.user_db() as conn:
            total = int(conn.execute(
                "SELECT COUNT(*) AS c FROM still_likes").fetchone()["c"])
            rows = conn.execute(
                "SELECT metadata_id, url, ratio, created_at FROM still_likes "
                f"ORDER BY {order_sql} LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR stills liked: {exc}")
        return handler._error(500, f"读取喜爱的剧照失败: {exc}")

    meta: dict = {}
    ids = sorted({int(r["metadata_id"]) for r in rows})
    if ids:
        ph = ",".join("?" * len(ids))
        try:
            with A.amane_db() as conn:
                for r in conn.execute(
                        f"SELECT id, number, title FROM metadata WHERE id IN ({ph})", ids):
                    meta[int(r["id"])] = (_text(r["number"]), _text(r["title"]))
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN stills liked 补片名失败: {exc}")

    items = []
    for r in rows:
        mid = int(r["metadata_id"])
        number, title = meta.get(mid, ("", ""))
        items.append({
            "id": mid,
            "number": number,
            "title": title,
            "url": _text(r["url"]),
            "ratio": round(float(r["ratio"] or 0), 3),
            "created_at": _text(r["created_at"]),
        })
    handler._json({"items": items, "total": total, "offset": offset,
                   "limit": limit, "order": order})


ROUTES = [
    ("GET", r"/api/user/stills", stills),
    ("GET", r"/api/user/stills/liked", liked_stills),
    ("POST", r"/api/user/stills/like", like_still),
]


def install(api) -> dict:
    global A
    A = api
    api.add_ddl(DDL)
    api.hook("item_extra", on_item_extra)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    return {"id": "stills", "routes": len(ROUTES), "scopes": sorted(SCOPES)}
