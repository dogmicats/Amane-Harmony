#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：分类（facets）浏览 —— 标签 / 系列 / 制片商 / 用户标签（scope=public）。

上游 amane 的分类体系是一套统一的 facet：actor / director / tag / studio /
publisher / series / user_tag。本扩展只暴露「按分类浏览影片」这条链路，
不建表、不写库，三件事：

  1. `GET /api/user/facets/{kind}` 代理 `/api/facets/{kind}`（分页 + 搜索 + 排序）；
  2. `GET /api/user/facets/{kind}/{id}/media` 代理 `/api/metadata?{kind}_id=`；
  3. `GET /api/user/item/{id}/facets` 把「这部片属于哪个系列 / 有哪些标签」
     一次补齐（上游 /api/metadata/{id} 的 id 字段是 name→id 的字典，
     核心 /api/user/item/{id} 只给名字，客户端拿不到 id 就没法跳分类页）。

图片统一走核心 public_image() 转成 `/img?b=<base64url>&t=`，避免 ArkUI 对 % 的二次编码。
不 import server.py：依赖由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

A = None  # type: ignore[assignment]

# kind -> /api/metadata 的筛选参数名
KIND_PARAM = {
    "tag": "tag_id",
    "series": "series_id",
    "studio": "studio_id",
    "publisher": "publisher_id",
    "user_tag": "user_tag_id",
    "director": "director_id",
}

FACET_SORT = {"name", "count"}
MEDIA_SORT = {
    "number", "title", "studio", "release",
    "created_at", "updated_at", "file_count", "score",
}


def _one(query: dict, key: str, default: str = "") -> str:
    return (query.get(key) or [default])[0]


def _int(value, default: int, lo: int, hi: int) -> int:
    try:
        n = int(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(n, hi))


def _num(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _text(value) -> str:
    return value if isinstance(value, str) else ""


def _poster(item: dict) -> str:
    """影片海报：amane 本地缓存优先，其次外链代理；与 actors 扩展保持同一规则。"""
    for key in ("poster_url", "thumb_url", "poster_urls", "thumb_urls"):
        value = item.get(key)
        urls = value if isinstance(value, list) else ([value] if isinstance(value, str) else [])
        for u in urls:
            if not isinstance(u, str):
                continue
            if u.startswith("/api/resources/"):
                return u
            p = A.public_image(u)
            if p:
                return p
    return ""


def _card(m: dict) -> dict:
    try:
        score = float(m.get("score") or 0)
    except (TypeError, ValueError):
        score = 0.0
    return {
        "id": _num(m.get("id")),
        "number": _text(m.get("number")),
        "title": _text(m.get("title")),
        "release": _text(m.get("release")),
        "score": round(score, 2),
        "poster": _poster(m),
    }


def _upstream(path: str, params: dict, handler):
    try:
        return A.amane_get(path, params)
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 上游 {path} 失败: {exc}")
        handler._error(502, f"amane 分类数据不可用: {exc}")
        return None


# --------------------------------------------------------------------- 路由
def _marks_of(ids: list) -> dict:
    """一次性汇总这些影片的媒体标记：无码 / 破解 / 流出 / 中字。

    分类页、演员作品、共演结果都要显示，所以统一在服务端算好，
    别让客户端为 20 张卡片各查一次。
    """
    ids = [int(i) for i in ids if int(i or 0) > 0]
    if not ids:
        return {}
    ph = ",".join("?" * len(ids))
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, "
                "MAX(CASE WHEN UPPER(mosaic)='CRACKED' THEN 1 ELSE 0 END) c, "
                "MAX(CASE WHEN UPPER(mosaic)='LEAKED' THEN 1 ELSE 0 END) l, "
                "MAX(CASE WHEN UPPER(mosaic)='UNCENSORED' THEN 1 ELSE 0 END) u, "
                "MAX(CASE WHEN has_subtitle_in_name=1 OR has_external_subtitle=1 "
                "THEN 1 ELSE 0 END) s "
                "FROM media_files WHERE metadata_id IN (" + ph + ") "
                "GROUP BY metadata_id",
                ids,
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 取媒体标记失败: {exc}")
        return {}
    out: dict = {}
    for r in rows:
        marks: list = []
        if r["u"]:
            marks.append("无码")
        if r["c"]:
            marks.append("破解")
        if r["l"]:
            marks.append("流出")
        if r["s"]:
            marks.append("中字")
        if marks:
            out[r["metadata_id"]] = marks
    return out


def facets_list(handler, query, kind, *_):
    """GET /api/user/facets/{kind} —— 分类条目列表（标签云 / 系列 / 制片商…）。"""
    if kind not in KIND_PARAM:
        return handler._error(400, f"不支持的分类: {kind}")
    sort_by = _one(query, "sort_by", "count")
    if sort_by not in FACET_SORT:
        sort_by = "count"
    order = _one(query, "order", "desc")
    if order not in ("asc", "desc"):
        order = "desc"
    params: dict = {
        "offset": _int(_one(query, "offset", "0"), 0, 0, 100000),
        "limit": _int(_one(query, "limit", "40"), 40, 1, 500),
        "sort_by": sort_by,
        "order": order,
        "search": _one(query, "search"),
    }
    # favorite 只有部分分类支持，前端不乱传就不会触发上游 400
    fav = _one(query, "favorite")
    if fav in ("true", "false"):
        params["favorite"] = fav
    data = _upstream(f"/api/facets/{kind}", params, handler)
    if data is None:
        return
    items = []
    for it in (data.get("items") or []):
        if not isinstance(it, dict):
            continue
        items.append({
            "id": _num(it.get("id")),
            "name": _text(it.get("name")),
            "count": _num(it.get("count")),
        })
    handler._json({
        "kind": kind,
        "items": items,
        "total": _num(data.get("total")),
        "offset": params["offset"],
        "limit": params["limit"],
    })


def facets_media(handler, query, kind, facet_id, *_):
    """GET /api/user/facets/{kind}/{id}/media —— 该分类下的影片。"""
    if kind not in KIND_PARAM:
        return handler._error(400, f"不支持的分类: {kind}")
    sort_by = _one(query, "sort_by", "release")
    if sort_by not in MEDIA_SORT:
        sort_by = "release"
    order = _one(query, "order", "desc")
    if order not in ("asc", "desc"):
        order = "desc"
    offset = _int(_one(query, "offset", "0"), 0, 0, 100000)
    limit = _int(_one(query, "limit", "30"), 30, 1, 200)
    params: dict = {
        KIND_PARAM[kind]: _int(facet_id, 0, 0, 10 ** 9),
        "offset": offset,
        "limit": limit,
        "sort_by": sort_by,
        "order": order,
    }
    # 与影片库一致的筛选口径：字幕 / 马赛克 / 分辨率
    if _one(query, "has_subtitle") in ("true", "1"):
        params["has_subtitle"] = "true"
    mosaic = _one(query, "mosaic")
    if mosaic in ("uncensored", "cracked", "leaked"):
        params["mosaic"] = mosaic
    definition = _one(query, "definition")
    if definition:
        params["definition"] = definition
    data = _upstream("/api/metadata", params, handler)
    if data is None:
        return
    rows = [m for m in (data.get("items") or []) if isinstance(m, dict)]
    marks_map = _marks_of([_num(m.get("id")) for m in rows])
    items = []
    for m in rows:
        card = _card(m)
        card["marks"] = marks_map.get(card["id"], [])
        items.append(card)
    handler._json({
        "kind": kind,
        "id": params[KIND_PARAM[kind]],
        "items": items,
        "total": _num(data.get("total")),
        "offset": offset,
        "limit": limit,
    })


def _poster_of(row) -> str:
    for key in ("poster_urls", "thumb_urls"):
        raw = row[key]
        try:
            urls = A.json.loads(raw) if isinstance(raw, str) else (raw or [])
        except (TypeError, ValueError):
            urls = []
        if not isinstance(urls, list):
            continue
        for u in urls:
            if not isinstance(u, str):
                continue
            if u.startswith("/api/resources/"):
                return u
            p = A.public_image(u)
            if p:
                return p
    return ""


def _series_posters(name: str, limit: int = 4) -> list[str]:
    """系列封面：取系列内最近 N 部的海报，客户端拼四宫格。

    amane 的系列归属是 metadata.series 文本（名字），没有 series_id 外键，
    所以这里按名字直查只读库，只取有文件的条目。
    """
    if not name:
        return []
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT poster_urls, thumb_urls FROM metadata "
                "WHERE series = ? AND id IN (SELECT metadata_id FROM media_files) "
                "ORDER BY release DESC, id DESC LIMIT ?",
                (name, max(1, min(limit, 9))),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取系列封面失败: {exc}")
        return []
    out: list[str] = []
    for r in rows:
        p = _poster_of(r)
        if p and p not in out:
            out.append(p)
    return out


def item_facets(handler, query, metadata_id, *_):
    """GET /api/user/item/{id}/facets —— 单片的分类归属（系列 / 标签 / 制片商…）。

    核心 /api/user/item/{id} 只返回名字，客户端要「点标签看同类」「看所属系列」
    必须有 id，所以这里额外补一次上游详情。系列顺带取一次 count，
    详情页就能直接写「同系列 N 部」。
    """
    mid = _int(metadata_id, 0, 1, 10 ** 9)
    data = _upstream(f"/api/metadata/{mid}", {}, handler)
    if data is None:
        return
    meta = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}

    def pairs(key: str) -> list[dict]:
        raw = data.get(key)
        out: list[dict] = []
        if isinstance(raw, dict):
            for name, fid in raw.items():
                fid_n = _num(fid)
                if fid_n > 0 and isinstance(name, str):
                    out.append({"id": fid_n, "name": name, "count": 0})
        return out

    def brief(id_key: str, name_key: str, facet_kind: str) -> dict:
        fid = _num(data.get(id_key))
        name = _text(meta.get(name_key))
        if fid <= 0:
            return {"id": 0, "name": name, "count": 0}
        count = 0
        try:
            facet = A.amane_get(f"/api/facets/{facet_kind}/{fid}")
            count = _num(facet.get("count"))
            name = _text(facet.get("name")) or name
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN facets 取 {facet_kind}/{fid} 计数失败: {exc}")
        return {"id": fid, "name": name, "count": count}

    handler._json({
        "id": mid,
        "series": dict(brief("series_id", "series", "series"), posters=_series_posters(_text(meta.get("series")))),
        "studio": brief("studio_id", "studio", "studio"),
        "publisher": brief("publisher_id", "publisher", "publisher"),
        "tags": pairs("tag_ids"),
        "user_tags": [
            {"id": _num(t.get("id")), "name": _text(t.get("name")), "count": 0}
            for t in (data.get("user_tags") or []) if isinstance(t, dict)
        ],
        "directors": pairs("director_ids"),
    })


ROUTES = [
    ("GET", r"/api/user/facets/([a-z_]+)", facets_list),
    ("GET", r"/api/user/facets/([a-z_]+)/(\d+)/media", facets_media),
    ("GET", r"/api/user/item/(\d+)/facets", item_facets),
]


def install(api) -> dict:
    global A  # noqa: PLW0603
    A = api
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 facets 已启用（{len(ROUTES)} 个公开端点）")
    return {"id": "facets", "enabled": True, "scope": "public"}
