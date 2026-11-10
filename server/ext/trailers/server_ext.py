#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：预告片（详情页入口 + 预告片盲盒的数据面）。

amane 刮削时会把站点给的预告片地址写进 ``metadata.trailer_urls``：
开了 ``scraping.download_resources`` 里的 ``trailer`` 就是本地 Resource（
``/api/resources/<hash>``），没开就还是源站外链 —— 两种都要能用，所以
「抽一支」和「放一支」拆成两个端点：

    GET /api/user/trailers?scope=all&id=0&limit=8&exclude=12,34
        盲盒抽签：随机给若干条**带预告片**的片子（海报 + 预告片地址）。

    GET /api/user/trailer/{mid}?i=0
        真正放：由核心做 Range 流代理（外链不带实例 token，见 server.py）。

和剧照抽卡（stills 扩展）的差别只在数据面：这里不测图片比例、不搞候选轮转，
因为一张卡就是「一屏的海报 + 一个播放键」，比例固定、一次只放一支。
播放环节的交互（看完再决定、喜欢就跳正片）全在客户端，服务端不记状态。
"""
from __future__ import annotations

A = None  # type: ignore[assignment]

# 与 stills 扩展同一套 scope 语义，方便两处入口共用「范围」概念
SCOPES = {
    "tag", "series", "studio", "publisher", "director", "user_tag",
    "actor", "library", "favorite", "all",
}

MAX_LIMIT = 24
MAX_EXCLUDE = 240
"""已看过的 id 上限：盲盒一轮最多 24 张，240 足够覆盖十几轮，再多也没意义。"""


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
    """收藏在旁挂的 user.db 里，跨不到 amane 的只读库，先取 id 再 IN。"""
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id FROM favorites ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN trailers 取收藏失败: {exc}")
        return []
    return [int(r["metadata_id"]) for r in rows]


def _scope_where(scope: str, sid: int) -> tuple[str, list] | None:
    """scope → (WHERE 片段, 参数)。None 表示参数不合法。"""
    if scope == "all":
        return "1 = 1", []
    if scope == "favorite":
        ids = _fav_ids(4000)
        if not ids:
            return "1 = 0", []
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
    # 标量分类：metadata 上存的是名字而不是 id（与 facets / stills 同一口径）
    if scope == "series":
        return ("m.series IN (SELECT name FROM series WHERE id = ?)", [sid])
    if scope == "studio":
        return ("m.studio IN (SELECT name FROM studios WHERE id = ?)", [sid])
    if scope == "publisher":
        return ("m.publisher IN (SELECT name FROM publishers WHERE id = ?)", [sid])
    return None


def _parse_exclude(raw: str) -> list[int]:
    out: list[int] = []
    for piece in (raw or "").split(","):
        piece = piece.strip()
        if not piece:
            continue
        try:
            value = int(piece)
        except ValueError:
            continue
        if value > 0:
            out.append(value)
        if len(out) >= MAX_EXCLUDE:
            break
    return out


def _json_list(raw) -> list:
    if not raw:
        return []
    try:
        value = A.json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def _poster(row) -> str:
    """卡片封面：海报优先，退到缩略图；都走旁挂服务的图片代理。"""
    for key in ("poster_urls", "thumb_urls"):
        for url in _json_list(row[key]):
            if isinstance(url, str) and url.startswith("http"):
                proxied = A.public_image(url)
                if proxied:
                    return proxied
    return ""


def trailers(handler, query, *_):
    """GET /api/user/trailers —— 盲盒抽签：随机若干条带预告片的片子。"""
    scope = _text(_one(query, "scope", "all")).strip().lower()
    sid = _int(_one(query, "id", "0"), 0, 0, 10 ** 9)
    limit = _int(_one(query, "limit", "8"), 8, 1, MAX_LIMIT)
    exclude = _parse_exclude(_one(query, "exclude", ""))

    if scope not in SCOPES:
        return handler._error(400, f"不支持的 scope: {scope or '(空)'}")
    built = _scope_where(scope, sid)
    if built is None:
        return handler._error(400, f"scope={scope} 需要有效的 id")
    where, args = built

    # 只抽「有预告片 + 有文件」的：没有文件的条目点了也放不出正片，
    # 盲盒的下一步就是「喜欢就开正片」，所以这里先剔掉。
    cond = (
        where
        + " AND EXISTS (SELECT 1 FROM media_files f WHERE f.metadata_id = m.id)"
        + " AND m.trailer_urls IS NOT NULL AND m.trailer_urls NOT IN ('', '[]', '{}')"
    )
    params: list = list(args)
    if exclude:
        ph = ",".join("?" * len(exclude))
        cond += f" AND m.id NOT IN ({ph})"
        params.extend(exclude)

    try:
        with A.amane_db() as conn:
            total = conn.execute(f"SELECT COUNT(*) FROM metadata m WHERE {cond}", tuple(params)).fetchone()[0]
            rows = conn.execute(
                "SELECT m.id, m.number, m.title, m.runtime, m.poster_urls, m.thumb_urls, m.trailer_urls "
                f"FROM metadata m WHERE {cond} ORDER BY RANDOM() LIMIT ?",
                (*params, limit),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR trailers 取预告片失败 scope={scope} id={sid}: {exc}")
        return handler._error(500, f"预告片查询失败: {exc}")

    items: list = []
    for r in rows:
        count = len([u for u in _json_list(r["trailer_urls"]) if isinstance(u, str) and u.strip()])
        poster = _poster(r)
        if not poster:
            continue   # 没封面就当没抽到，别在墙上留一块空卡
        items.append({
            "id": _int(r["id"], 0, 0, 10 ** 9),
            "number": _text(r["number"]),
            "title": _text(r["title"]),
            "runtime": _int(r["runtime"], 0, 0, 10 ** 5),
            "poster": poster,
            # 相对路径：客户端自己补宿主与 token（和 /api/user/photo 同一规则）
            "trailer": f"/api/user/trailer/{int(r['id'])}?i=0",
            "count": max(1, count),
        })

    handler._json({
        "scope": scope,
        "id": sid,
        "items": items,
        # 「这个范围里一共有多少部带预告片」——空墙文案与「换一批」都要用
        "total": total,
        "excluded": len(exclude),
    })


def item_extra(metadata_id: int) -> dict:
    """详情页钩子：这个条目有几支预告片、分别怎么放。

    不在核心 item 里算，是因为「有没有预告片」只跟 extensions.json 里这个
    扩展开没开有关：关掉它，详情页就不该出现预告片入口。
    """
    try:
        with A.amane_db() as conn:
            row = conn.execute(
                "SELECT trailer_urls FROM metadata WHERE id = ?", (int(metadata_id),)
            ).fetchone()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN trailers item_extra 失败 id={metadata_id}: {exc}")
        return {}
    if row is None:
        return {}
    urls = [u for u in _json_list(row["trailer_urls"]) if isinstance(u, str) and u.strip()]
    if not urls:
        return {}
    return {"trailers": [f"/api/user/trailer/{int(metadata_id)}?i={i}" for i in range(len(urls))]}


ROUTES = [
    ("GET", r"/api/user/trailers", trailers),
]


def install(api) -> dict:
    global A
    A = api
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("item_extra", item_extra)
    return {"id": "trailers", "routes": len(ROUTES), "scopes": sorted(SCOPES)}
