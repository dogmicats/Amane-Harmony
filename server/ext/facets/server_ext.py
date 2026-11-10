#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：分类（facets）浏览 —— 标签 / 系列 / 制片商 / 用户标签（scope=public）。

上游 amane 的分类体系是一套统一的 facet：actor / director / tag / studio /
publisher / series / user_tag。本扩展只暴露「按分类浏览影片」这条链路，
不建表、不写库，三件事：

  1. `GET /api/user/facets/{kind}` 分类条目列表：片数 / 缩略图 / 收藏位，
     并支持「最近更新（系列内最新入库）」「最新发布（系列内最晚发行）」「随机」三种排序；
  2. `GET /api/user/facets/{kind}/{id}/media` 代理 `/api/metadata?{kind}_id=`；
  3. `POST /api/user/facets/{kind}/{id}/favorite` 给分类打收藏（与影片收藏无关）；
     `POST /api/user/facets/{kind}/{id}/hide` 在列表里隐藏 / 恢复这个分类（软过滤，
     只写旁挂服务的 user.db，不动 amane 的库与刮削规则）；
  4. `GET /api/user/item/{id}/facets` 把「这部片属于哪个系列 / 有哪些标签」
     一次补齐（上游 /api/metadata/{id} 的 id 字段是 name→id 的字典，
     核心 /api/user/item/{id} 只给名字，客户端拿不到 id 就没法跳分类页）。

图片统一走核心 public_image() 转成 `/img?b=<base64url>&t=`，避免 ArkUI 对 % 的二次编码。
不 import server.py：依赖由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

import random

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

FACET_SORT = {"name", "count", "recent_update", "recent_release", "random"}
MEDIA_SORT = {
    "number", "title", "studio", "release",
    "created_at", "updated_at", "file_count", "score", "random",
}

# 可收藏的分类（与上游 FAVORITE_FACET_ENTITIES 同口径）：实体表上有 is_favorite 列。
FAVORITE_KINDS = {"tag", "series", "studio", "publisher", "director"}

# 关联分类：(实体表, 关联表, 关联表指向实体的外键列)
LINK_SPEC = {
    "tag": ("tags", "metadata_tags", "tag_id"),
    "director": ("directors", "metadata_directors", "director_id"),
}
# 标量分类：(实体表, Metadata 上存放该分类名字的列)
SCALAR_SPEC = {
    "series": ("series", "series"),
    "studio": ("studios", "studio"),
    "publisher": ("publishers", "publisher"),
}

# 分类列表的缩略图张数。两种版式：
#   - 标签 / 系列：三张横排，铺满 3 列网格的小卡；
#   - 导演 / 制片商：8 张横排成一整条长图（用户要求「每一排一个导演」，
#     一排里多张照片连成一大条，像一排胶片）。
# 张数不同是因为客户端版式不同，不是漏改。
POSTER_KINDS = {"series": 3, "tag": 3, "director": 8, "studio": 8}

# 「隐藏分类」是旁挂服务自己的偏好表，不写 amane 的库，也不动刮削规则：
# 用户只是不想在标签列表里看到没价值的标签（DMM独家之类），不是要删数据。
HIDDEN_DDL = """
CREATE TABLE IF NOT EXISTS facet_hidden (
    kind       TEXT    NOT NULL,
    facet_id   INTEGER NOT NULL,
    created_at TEXT    NOT NULL,
    PRIMARY KEY (kind, facet_id)
);
"""


def _hidden_ids(kind: str) -> set:
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT facet_id FROM facet_hidden WHERE kind = ?", (kind,)
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 读隐藏表失败: {exc}")
        return set()
    return {_num(r[0]) for r in rows}


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


def _esc(value: str) -> str:
    """LIKE 转义（不含通配符）：联想要拼 `前缀%`，不能直接套 _like 的 `%…%`。"""
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _like(value: str) -> str:
    return f"%{_esc(value)}%"


# 每个 metadata 的最新入库时间先聚一次再 JOIN：直接连 media_files 会按文件数放大行数，
# 逼着外面用 COUNT(DISTINCT)，在 6 万行关联表上要多花几百毫秒。
_RECENT_JOIN = ("LEFT JOIN (SELECT metadata_id, MAX(created_at) AS last_at "
                "FROM media_files GROUP BY metadata_id) f "
                "ON f.metadata_id = m.id ")


def _agg_sql(kind: str, search: str, favorite: str, hidden: set | None = None) -> tuple[str, list]:
    """分类聚合子查询：实体行 + 片数 + 最新入库 / 最新发行。

    片数口径与上游一致（关联分类数挂载行、标量分类数同名 metadata 行）。
    """
    where: list[str] = []
    args: list = []
    if search:
        where.append("e.name LIKE ? ESCAPE '\\'")
        args.append(_like(search))
    if favorite in ("true", "false"):
        where.append("e.is_favorite = ?")
        args.append(1 if favorite == "true" else 0)
    if hidden:
        ph = ",".join("?" * len(hidden))
        where.append(f"e.id NOT IN ({ph})")
        args.extend(sorted(hidden))
    cond = ("WHERE " + " AND ".join(where) + " ") if where else ""
    if kind in LINK_SPEC:
        ent, link, fk = LINK_SPEC[kind]
        head = (f"FROM {ent} e "
                f"LEFT JOIN {link} l ON l.{fk} = e.id "
                f"LEFT JOIN metadata m ON m.id = l.metadata_id ")
    else:
        table, col = SCALAR_SPEC[kind]
        head = f"FROM {table} e LEFT JOIN metadata m ON m.{col} = e.name "
    sql = ("SELECT e.id AS id, e.name AS name, e.is_favorite AS fav, "
           "COUNT(m.id) AS cnt, MAX(m.release) AS last_release, "
           "MAX(f.last_at) AS last_added " + head + _RECENT_JOIN + cond +
           "GROUP BY e.id")
    return sql, args


_ORDER_COL = {
    "count": "cnt",
    "recent_update": "last_added",
    "recent_release": "last_release",
}


def _order_sql(sort_by: str, order: str, seed: int = 0) -> str:
    direction = "DESC" if order == "desc" else "ASC"
    if sort_by == "name":
        return f"e.name COLLATE NOCASE {direction}, e.id ASC"
    if sort_by == "random":
        # 不用 RANDOM()：那会每翻一页重摇一次，出现重复和漏项。
        # 拿 seed 和 id 做一次线性同余打散，同一个 seed 下顺序固定，翻页才接得上。
        return f"((e.id * 1103515245 + {int(seed)}) % 2147483647) ASC"
    col = _ORDER_COL[sort_by]
    # NULL（没有影片 / 没有发行日）永远沉底：DESC 时 SQLite 会把它顶到最前面
    return f"({col} IS NULL) ASC, {col} {direction}, e.name COLLATE NOCASE ASC"


def _posters_of(rows, limit: int = 3) -> dict:
    out: dict = {}
    for row in rows:
        key = row["k"]
        bucket = out.setdefault(key, [])
        if len(bucket) >= limit:
            continue
        p = _poster_of(row)
        if p and p not in bucket:
            bucket.append(p)
    return out


def _poster_map(kind: str, ids: list) -> dict:
    """一页分类的缩略图：按发行时间倒序取前几张。

    单条查询取全页，避免 40 个分类各查一次；结果在 Python 里按 POSTER_KINDS
    截到每种版式需要的张数（标签/系列 3 张、导演/制片商 8 张）。
    """
    limit = POSTER_KINDS.get(kind, 0)
    if not limit or not ids:
        return {}
    ph = ",".join("?" * len(ids))
    if kind in LINK_SPEC:
        _ent, link, fk = LINK_SPEC[kind]
        sql = (f"SELECT l.{fk} AS k, m.poster_urls, m.thumb_urls FROM {link} l "
               f"JOIN metadata m ON m.id = l.metadata_id "
               f"WHERE l.{fk} IN ({ph}) ORDER BY m.release DESC, m.id DESC")
    else:
        table, col = SCALAR_SPEC[kind]
        sql = (f"SELECT e.id AS k, m.poster_urls, m.thumb_urls FROM {table} e "
               f"JOIN metadata m ON m.{col} = e.name "
               f"WHERE e.id IN ({ph}) ORDER BY m.release DESC, m.id DESC")
    try:
        with A.amane_db() as conn:
            rows = conn.execute(sql, ids).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取分类缩略图失败: {exc}")
        return {}
    return _posters_of(rows, limit)


def facets_list(handler, query, kind, *_):
    """GET /api/user/facets/{kind} —— 分类条目列表（标签云 / 系列 / 制片商…）。

    tag / series / studio / publisher / director 直读只读库自算，因为上游分类列表
    只支持按名字和片数排序，而「最近更新 / 最新发布」「缩略图」「是否收藏」
    三样它都给不了；user_tag 没有收藏位，继续代理上游。
    """
    if kind not in KIND_PARAM:
        return handler._error(400, f"不支持的分类: {kind}")
    sort_by = _one(query, "sort_by", "count")
    if sort_by not in FACET_SORT:
        sort_by = "count"
    order = _one(query, "order", "desc")
    if order not in ("asc", "desc"):
        order = "desc"
    search = _one(query, "search")
    fav = _one(query, "favorite")
    if fav not in ("true", "false"):
        fav = ""
    include_hidden = _one(query, "include_hidden") in ("true", "1")
    params: dict = {
        "offset": _int(_one(query, "offset", "0"), 0, 0, 100000),
        "limit": _int(_one(query, "limit", "40"), 40, 1, 500),
    }

    if kind not in LINK_SPEC and kind not in SCALAR_SPEC:
        return _facets_list_upstream(handler, kind, params, sort_by, order, search, fav)

    hidden_all = _hidden_ids(kind)
    hidden = set() if include_hidden else hidden_all
    # 随机排序要一个 seed：客户端第一次不带，服务端给一个并回传，
    # 后续翻页带着同一个 seed 才接得上（不带就每页重摇，会重复也会漏）。
    seed = _int(_one(query, "seed", "0"), 0, 0, 2 ** 31 - 1)
    if sort_by == "random" and seed == 0:
        seed = random.randrange(1, 2 ** 31 - 1)
    agg, args = _agg_sql(kind, search, fav, hidden)
    try:
        with A.amane_db() as conn:
            total = _num(conn.execute(f"SELECT COUNT(*) FROM ({agg})", args).fetchone()[0])
            rows = conn.execute(
                f"{agg} ORDER BY {_order_sql(sort_by, order, seed)} LIMIT ? OFFSET ?",
                args + [params["limit"], params["offset"]],
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 分类聚合失败 {kind}: {exc}")
        return handler._error(502, f"amane 分类数据不可用: {exc}")
    ids = [_num(r["id"]) for r in rows]
    posters = _poster_map(kind, ids)
    items = []
    for r in rows:
        fid = _num(r["id"])
        items.append({
            "id": fid,
            "name": _text(r["name"]),
            "count": _num(r["cnt"]),
            "isFavorite": bool(r["fav"]),
            "posters": posters.get(fid, []),
            "lastRelease": _text(r["last_release"])[:10],
            "lastAdded": _text(r["last_added"])[:10],
            "isHidden": fid in hidden_all,
        })
    handler._json({
        "kind": kind,
        "items": items,
        "total": total,
        "offset": params["offset"],
        "limit": params["limit"],
        "sort_by": sort_by,
        "seed": seed,
        "includeHidden": include_hidden,
        "hiddenCount": len(hidden_all),
        "order": order,
    })


def _facets_list_upstream(handler, kind, params, sort_by, order, search, fav) -> None:
    """没有收藏位 / 不需要额外字段的分类：原样代理上游。"""
    up: dict = {
        "offset": params["offset"],
        "limit": params["limit"],
        "sort_by": "name" if sort_by == "name" else "count",
        "order": order,
        "search": search,
    }
    data = _upstream(f"/api/facets/{kind}", up, handler)
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
            "isFavorite": bool(it.get("is_favorite")),
            "posters": [],
            "lastRelease": "",
            "lastAdded": "",
            "isHidden": False,
        })
    handler._json({
        "kind": kind,
        "items": items,
        "total": _num(data.get("total")),
        "offset": params["offset"],
        "limit": params["limit"],
        "sort_by": sort_by,
        "order": order,
    })


def facet_favorite(handler, query, kind, facet_id, *_):
    """POST /api/user/facets/{kind}/{id}/favorite —— 给分类打收藏 / 取消收藏。

    分类收藏是 amane 自己的列（series.is_favorite 等），与「影片收藏 + 自动入库」
    完全无关：这里只写一个布尔位，不动媒体文件、不进收藏表。
    上游只有批量端点，且动作是「置为」而不是「取反」，所以客户端必须传目标值。
    """
    if kind not in FAVORITE_KINDS:
        return handler._error(400, f"该分类不支持收藏: {kind}")
    fid = _int(facet_id, 0, 1, 10 ** 9)
    body = handler._body() or {}
    raw = body.get("favorite")
    if isinstance(raw, bool):
        want = raw
    elif isinstance(raw, (int, float)):
        want = bool(raw)
    else:
        want = str(raw).strip().lower() in ("1", "true", "yes", "on")
    action = "favorite" if want else "unfavorite"
    try:
        data = A.amane_post(f"/api/facets/{kind}/batch", {"action": action, "facet_ids": [fid]})
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 收藏 {kind}/{fid} 失败: {exc}")
        return handler._error(502, f"收藏失败: {exc}")
    if _num(data.get("missing")) > 0:
        return handler._error(404, "分类不存在")
    handler._json({
        "kind": kind,
        "id": fid,
        "favorite": want,
        "changed": _num(data.get("changed")),
        "unchanged": _num(data.get("unchanged")),
    })


def facet_hide(handler, query, kind, facet_id, *_):
    """POST /api/user/facets/{kind}/{id}/hide —— 在浏览列表里隐藏 / 恢复这个分类。

    隐藏只写旁挂服务自己的 `facet_hidden` 表（user.db），**不动 amane 的库、
    不动刮削规则、不删任何影片关联**：用户说的是「懒得因为这个动刮削设置」，
    所以这里只是列表层的一个软过滤，随时可以恢复。
    """
    if kind not in FAVORITE_KINDS:
        return handler._error(400, f"该分类不支持隐藏: {kind}")
    fid = _int(facet_id, 0, 1, 10 ** 9)
    body = handler._body() or {}
    raw = body.get("hidden")
    if isinstance(raw, bool):
        want = raw
    elif isinstance(raw, (int, float)):
        want = bool(raw)
    else:
        want = str(raw).strip().lower() in ("1", "true", "yes", "on")
    try:
        with A.user_db() as conn:
            if want:
                conn.execute(
                    "INSERT OR REPLACE INTO facet_hidden (kind, facet_id, created_at) VALUES (?, ?, ?)",
                    (kind, fid, A.now_iso()),
                )
            else:
                conn.execute(
                    "DELETE FROM facet_hidden WHERE kind = ? AND facet_id = ?", (kind, fid)
                )
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 隐藏 {kind}/{fid} 失败: {exc}")
        return handler._error(500, f"隐藏失败: {exc}")
    A.log(f"分类{'隐藏' if want else '取消隐藏'}: {kind}/{fid}")
    handler._json({"kind": kind, "id": fid, "hidden": want})



def _facet_head(kind: str, fid: int) -> dict:
    """单个分类的头部信息（名字 / 收藏位 / 缩略图），分类影片墙的标题栏要用。"""
    if kind in LINK_SPEC:
        table = LINK_SPEC[kind][0]
    elif kind in SCALAR_SPEC:
        table = SCALAR_SPEC[kind][0]
    else:
        return {}
    try:
        with A.amane_db() as conn:
            row = conn.execute(
                f"SELECT id, name, is_favorite FROM {table} WHERE id = ?", (fid,)
            ).fetchone()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取分类 {kind}/{fid} 失败: {exc}")
        return {}
    if row is None:
        return {}
    return {
        "id": _num(row["id"]),
        "name": _text(row["name"]),
        "isFavorite": bool(row["is_favorite"]),
        "isHidden": fid in _hidden_ids(kind),
        "posters": _poster_map(kind, [fid]).get(fid, []),
    }


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
    if sort_by == "random":
        # 上游不支持 RANDOM()：先探 total，再在结果集里随机开一扇窗。
        # 窗口内顺序稳定，翻页续接；刷新页面才重新随机。
        probe_params = dict(params)
        probe_params.update({"offset": 0, "limit": 1, "sort_by": "release", "order": "desc"})
        probe = _upstream("/api/metadata", probe_params, handler)
        if probe is None:
            return
        total_probe = _num(probe.get("total"))
        params["offset"] = random.randrange(max(1, total_probe - limit + 1)) \
            if total_probe > limit else 0
        params["sort_by"] = "release"
        params["order"] = "desc"
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
        "facet": _facet_head(kind, params[KIND_PARAM[kind]]),
        "items": items,
        "total": _num(data.get("total")),
        "offset": params["offset"],
        "limit": limit,
        "sort_by": sort_by,
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


def _series_posters(name: str, limit: int = 3) -> list[str]:
    """系列封面：取系列内最近 N 部的海报，客户端三张横排并列展示。

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
    ("POST", r"/api/user/facets/([a-z_]+)/(\d+)/favorite", facet_favorite),
    ("POST", r"/api/user/facets/([a-z_]+)/(\d+)/hide", facet_hide),
    ("GET", r"/api/user/item/(\d+)/facets", item_facets),
]


# --------------------------------------------------------------------- 搜索联想
# 核心 /api/user/suggest 的 `suggest_entities` 钩子：关键词命中分类名时，
# 把「标签 / 导演 / 系列 / 制片商」当成可点的一等结果交给它（点进去是分类影片墙）。
# 为什么不放在核心里：这些表是 facets 扩展自己的领地，核心只认 film；
# 关掉扩展，联想就自然只剩影片，不会因为找不到表而报 500。
SUGGEST_KINDS = ("tag", "director", "series", "studio")
SUGGEST_LIMIT = 6


def _suggest_kind(kind: str, raw: str, limit: int) -> dict:
    """一个分类的联想命中：名字前缀优先，其次按片数。

    排序不能交给上层：`SELECT … LIMIT 6` 之后再排序只会得到「片数最多的 6 个里
    前缀命中的那几个」，前缀命中的分类反而可能根本进不了前 6。
    """
    if kind in LINK_SPEC:
        ent, link, fk = LINK_SPEC[kind]
        head = (f"FROM {ent} e LEFT JOIN {link} l ON l.{fk} = e.id "
                f"LEFT JOIN metadata m ON m.id = l.metadata_id ")
    else:
        ent, col = SCALAR_SPEC[kind]
        head = f"FROM {ent} e LEFT JOIN metadata m ON m.{col} = e.name "

    cond = "WHERE e.name LIKE ? ESCAPE '\\'"
    cond_args: list = [_like(raw)]
    hidden = _hidden_ids(kind)
    if hidden:
        cond += f" AND e.id NOT IN ({','.join('?' * len(hidden))})"
        cond_args.extend(sorted(hidden))

    sql = ("SELECT e.id AS id, e.name AS name, COUNT(m.id) AS cnt, "
           "CASE WHEN e.name LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END AS pre "
           + head + cond + " GROUP BY e.id "
           "ORDER BY pre ASC, cnt DESC, LENGTH(e.name) ASC, e.id ASC LIMIT ?")
    try:
        with A.amane_db() as conn:
            rows = conn.execute(sql, (_esc(raw) + "%", *cond_args, limit)).fetchall()
            total = _num(conn.execute(
                f"SELECT COUNT(*) FROM {ent} e {cond}", cond_args).fetchone()[0])
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 联想 {kind} 失败: {exc}")
        return {"total": 0, "items": []}

    ids = [_num(r["id"]) for r in rows]
    posters = _poster_map(kind, ids)
    items = []
    for r in rows:
        fid = _num(r["id"])
        items.append({
            "type": kind,
            "id": fid,
            "name": _text(r["name"]),
            "count": _num(r["cnt"]),
            # 分类的「封面」就是它最近几部片的第一张海报，和分类列表里的缩略图同源
            "image": (posters.get(fid) or [""])[0],
            "tier": 1 if not r["pre"] else 2,
        })
    return {"total": total, "items": items}


def suggest_entities(raw: str, kinds: list) -> dict:
    """返回 {kind: {"total": n, "items": [...]}}；没被要求的 kind 不出现。"""
    wanted = [k for k in SUGGEST_KINDS if k in (kinds or [])]
    return {kind: _suggest_kind(kind, raw, SUGGEST_LIMIT) for kind in wanted}


def suggest_kinds() -> dict:
    """告诉核心「我这一摊能联想哪些类型」，核心据此回答 supported。"""
    return {"facets": list(SUGGEST_KINDS)}


def install(api) -> dict:
    global A  # noqa: PLW0603
    A = api
    api.add_ddl(HIDDEN_DDL)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("suggest_entities", suggest_entities)
    api.hook("suggest_kinds", suggest_kinds)
    api.log(f"扩展 facets 已启用（{len(ROUTES)} 个公开端点 + 搜索联想）")
    return {"id": "facets", "enabled": True, "scope": "public"}
