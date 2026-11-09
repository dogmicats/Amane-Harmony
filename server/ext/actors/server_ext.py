#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：演员页数据代理（scope=public，随公版一起发布）。

数据源是 amane 上游自带的 /api/actors* 与 /api/metadata，本服务不建表、不写库，
只做三件事：

  1. 只透传白名单参数 —— 扩展不能变成任意上游查询入口；
  2. 把 image_urls / poster_urls / thumb_urls 里的外链统一转成
     `/img?b=<base64url>&t=...`（由核心 public_image() 处理），
     客户端 Store.img() 直接补前缀即可，绕开 ArkUI 对 % 的二次编码；
  3. 裁剪成页面真正需要的字段 —— 列表不带 overview / raw / provider 快照，
     外网流量下省掉大半响应体。

不 import server.py：所有依赖由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import re
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.parse
import urllib.request

A = None  # type: ignore[assignment]

SORT_VALUES = {
    "name", "count", "updated_at", "has_image",
    "birthday", "height", "bust", "waist", "hip", "cup",
}
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


def _str_list(value) -> list[str]:
    return [x for x in (value or []) if isinstance(x, str)] if isinstance(value, list) else []


def _images(urls) -> list[str]:
    """外链头像 → 代理 URL；白名单外的主机（如 commons.wikimedia.org）直接丢掉。"""
    out: list[str] = []
    for u in _str_list(urls):
        p = A.public_image(u)
        if p and p not in out:
            out.append(p)
    return out


def _poster(item: dict) -> str:
    """影片海报：amane 本地缓存优先，其次外链代理。"""
    for key in ("poster_urls", "thumb_urls"):
        for u in _str_list(item.get(key)):
            if u.startswith("/api/resources/"):
                return u
            p = A.public_image(u)
            if p:
                return p
    return ""


def _card(a: dict) -> dict:
    imgs = _images(a.get("image_urls"))
    return {
        "id": _num(a.get("id")),
        "name": _text(a.get("name")),
        "count": _num(a.get("count")),
        "gender": (_text(a.get("gender")) or "unknown").strip().lower(),
        "birthday": _text(a.get("birthday")),
        "birthplace": _text(a.get("birthplace")),
        "height": _num(a.get("height")),
        "bust": _num(a.get("bust")),
        "waist": _num(a.get("waist")),
        "hip": _num(a.get("hip")),
        "cup": _text(a.get("cup")),
        "avatar": imgs[0] if imgs else "",
    }


def _upstream(path: str, params: dict, handler):
    try:
        return A.amane_get(path, params)
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 上游 {path} 失败: {exc}")
        handler._error(502, f"amane 演员数据不可用: {exc}")
        return None


_CUP = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")


def _range(params: dict, query: dict, key: str, lo: int = 0, hi: int = 300) -> None:
    """把 `<key>_min` / `<key>_max` 这类数值筛选从 query 抄进上游参数。"""
    for edge in ("min", "max"):
        raw = _one(query, f"{key}_{edge}")
        if raw == "":
            continue
        try:
            value = int(raw)
        except (TypeError, ValueError):
            continue
        params[f"{key}_{edge}"] = max(lo, min(value, hi))


def _date_range(params: dict, query: dict, key: str) -> None:
    for edge in ("min", "max"):
        raw = _one(query, f"{key}_{edge}")
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
            params[f"{key}_{edge}"] = raw


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


def actors_list(handler, query, *_):
    """GET /api/user/actors —— 演员网格，分页 + 搜索 + 排序 + 多维筛选。

    上游 ActorBrowseParams 支持的筛选比这里多得多（出生地包含匹配、user_tag_ids、
    saved_query_id 等），这里只透传页面真正会用的几类，并逐个做白名单校验 ——
    扩展不能变成任意上游查询入口。
    """
    params: dict = {
        "offset": _int(_one(query, "offset", "0"), 0, 0, 100000),
        "limit": _int(_one(query, "limit", "30"), 30, 1, 200),
        "sort_by": _one(query, "sort_by", "count"),
        "order": _one(query, "order", "desc"),
    }
    if params["sort_by"] not in SORT_VALUES:
        params["sort_by"] = "count"
    if params["order"] not in ("asc", "desc"):
        params["order"] = "desc"
    search = _one(query, "search")
    if search:
        params["search"] = search
    if _one(query, "has_image", "true") in ("true", "1"):
        params["has_image"] = "true"
    if _one(query, "has_person") in ("true", "1"):
        params["has_person"] = "true"
    gender = query.get("gender") or []
    if gender:
        picked = [g for g in gender if g in ("female", "male", "unknown")]
        if picked:
            params["gender"] = picked

    # 数值区间：身高 / 三围
    for key in ("height", "bust", "waist", "hip"):
        _range(params, query, key)
    # 罩杯区间：字母序，上游大小写不敏感
    for edge in ("min", "max"):
        cup = _one(query, f"cup_{edge}").strip().upper()
        if len(cup) == 1 and cup in _CUP:
            params[f"cup_{edge}"] = cup
    _date_range(params, query, "birthday")
    place = _one(query, "birthplace").strip()
    if place:
        params["birthplace"] = place[:40]

    data = _upstream("/api/actors", params, handler)
    if data is None:
        return
    items = [_card(a) for a in (data.get("items") or []) if isinstance(a, dict)]
    handler._json({
        "items": items,
        "total": _num(data.get("total")),
        "offset": params["offset"],
        "limit": params["limit"],
    })


def actors_detail(handler, query, actor_id, *_):
    """GET /api/user/actors/{id} —— 详情，列表刻意不返回的字段在这里补齐。"""
    data = _upstream(f"/api/actors/{int(actor_id)}", {}, handler)
    if data is None:
        return
    out = _card(data)
    out.update({
        "aliases": _str_list(data.get("aliases")),
        "overview": _text(data.get("overview")),
        "tagline": _text(data.get("tagline")),
        "birthplace": _text(data.get("birthplace")),
        "bust": _num(data.get("bust")),
        "waist": _num(data.get("waist")),
        "hip": _num(data.get("hip")),
        "avatars": _images(data.get("image_urls")) + gallery_of(int(actor_id)),
        "updated_at": _text(data.get("updated_at")),
    })
    handler._json(out)


def actors_media(handler, query, actor_id, *_):
    """GET /api/user/actors/{id}/media —— 该演员参演的影片（复用上游筛选）。

    除了本人，还允许追加：`tag_id`（按标签收窄）、`co_actor_id`（合作演员，
    上游多值 actor_id 是 AND）、`has_subtitle` / `mosaic` / `definition`。
    演员详情页的「更多筛选」子界面就靠这些参数。
    """
    params: dict = {
        "actor_id": [int(actor_id)],
        "offset": _int(_one(query, "offset", "0"), 0, 0, 100000),
        "limit": _int(_one(query, "limit", "24"), 24, 1, 200),
        "sort_by": _one(query, "sort_by", "release"),
        "order": _one(query, "order", "desc"),
    }
    if params["sort_by"] not in MEDIA_SORT:
        params["sort_by"] = "release"
    if params["order"] not in ("asc", "desc"):
        params["order"] = "desc"

    for extra in _ids(query, "co_actor_id"):
        if extra not in params["actor_id"]:
            params["actor_id"].append(extra)
    tags = _ids(query, "tag_id")
    if tags:
        params["tag_id"] = tags
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
        try:
            score = float(m.get("score") or 0)
        except (TypeError, ValueError):
            score = 0.0
        items.append({
            "id": _num(m.get("id")),
            "number": _text(m.get("number")),
            "title": _text(m.get("title")),
            "release": _text(m.get("release")),
            "score": round(score, 2),
            "poster": _poster(m),
            "marks": marks_map.get(_num(m.get("id")), []),
        })
    handler._json({
        "items": items,
        "total": _num(data.get("total")),
        "offset": params["offset"],
        "limit": params["limit"],
    })


def actors_lookup(handler, query, *_):
    """GET /api/user/actors/lookup?name=... —— 影片详情里的演员名反查实体 id。

    /api/user/item/{id} 只给名字数组，没有 actor_ids；点演员名进演员页要先解析。
    先精确匹配展示名，再在少量候选里找别名，找不到回 id=0 让客户端提示。
    """
    name = _one(query, "name")
    if not name:
        return handler._error(400, "缺少 name")
    data = _upstream("/api/actors", {"search": name, "limit": 50}, handler)
    if data is None:
        return
    candidates = [a for a in (data.get("items") or []) if isinstance(a, dict)]
    for a in candidates:
        if _text(a.get("name")) == name:
            return handler._json({"id": _num(a.get("id")), "name": name})
    for a in candidates[:10]:
        aid = _num(a.get("id"))
        if not aid:
            continue
        try:
            full = A.amane_get(f"/api/actors/{aid}")
        except Exception:  # noqa: BLE001
            continue
        if name in _str_list(full.get("aliases")):
            return handler._json({"id": aid, "name": _text(a.get("name")) or name})
    return handler._json({"id": 0, "name": name})


# --------------------------------------------------------------------- 阵容 / 共演

def _poster_of(row) -> str:
    """从 metadata 行取海报：本地缓存优先，其次外链代理。"""
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


def _avatars_for(ids: list[int]) -> dict:
    """批量取头像：一次上游 /api/actors?ids=…，避免逐个演员发 N 次请求。"""
    if not ids:
        return {}
    try:
        data = A.amane_get("/api/actors", {"ids": ids, "limit": len(ids)})
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN actors 批量取头像失败: {exc}")
        return {}
    out: dict = {}
    for a in (data.get("items") or []):
        if not isinstance(a, dict):
            continue
        imgs = _images(a.get("image_urls"))
        out[_num(a.get("id"))] = imgs[0] if imgs else ""
    return out


def _cast_rows(metadata_ids: list[int]) -> dict:
    """一次查出这些影片的演员（含性别），用于结果卡片上直接展示阵容。"""
    if not metadata_ids:
        return {}
    ph = ",".join("?" * len(metadata_ids))
    out: dict = {}
    with A.amane_db() as conn:
        rows = conn.execute(
            "SELECT ma.metadata_id, a.id, a.name, a.gender FROM metadata_actors ma "
            "JOIN actors a ON a.id = ma.actor_id "
            f"WHERE ma.metadata_id IN ({ph}) ORDER BY ma.position, a.id",
            metadata_ids,
        ).fetchall()
    for r in rows:
        # 库里存的是大写 FEMALE/MALE，客户端一律按小写比较性别，
        # 这里统一小写，否则「只看女演员」会把整个阵容过滤空、头像全消失。
        gender = (r["gender"] or "unknown").strip().lower()
        out.setdefault(r["metadata_id"], []).append({
            "id": r["id"],
            "name": r["name"] or "",
            "gender": gender,
        })
    return out


def item_cast(handler, query, metadata_id, *_):
    """GET /api/user/item/{id}/cast —— 影片出演阵容（带头像）。

    核心 /api/user/item/{id} 只有演员名，没 id 也没头像；Emby 式的「头像+姓名」
    需要实体 id，这里按 position 取一次阵容，再用一次批量请求补齐头像。
    """
    mid = _int(metadata_id, 0, 1, 10 ** 9)
    cast = _cast_rows([mid]).get(mid, [])
    if not cast:
        return handler._json({"items": []})
    avatars = _avatars_for([c["id"] for c in cast])
    for c in cast:
        c["avatar"] = avatars.get(c["id"], "")
    handler._json({"items": cast})


CAST_SORT = {
    "release": "m.release",
    "number": "m.number COLLATE NOCASE",
    "updated_at": "m.updated_at",
    "runtime": "m.runtime",
    "score": "CAST(json_extract(m.scores, '$.javdb') AS REAL)",
}


def _ids(query: dict, key: str) -> list[int]:
    out: list[int] = []
    for raw in (query.get(key) or []):
        for part in str(raw).split(","):
            part = part.strip()
            if part.isdigit():
                n = int(part)
                if 0 < n < 10 ** 9 and n not in out:
                    out.append(n)
    return out[:20]


def cast_find(handler, query, *_):
    """GET /api/user/cast/find —— 按演员阵容找片（共演 / 女演员人数）。

    上游 /api/metadata 只能按 actor_id 做 AND 过滤，答不了「这部片有 N 个女演员」
    这类问题，所以这里直接对 amane 只读库做一次聚合查询：

      * `actor_id=1&actor_id=2`  这些演员必须同时出现（具体 N 男 N 女共演）
      * `female_min/female_max`  女演员人数区间
      * `male_min/male_max`      男演员人数区间
      * `cast_min/cast_max`      总人数区间

    只返回有文件的条目，默认按发行日期倒序。
    """
    actor_ids = _ids(query, "actor_id")
    fmin = _int(_one(query, "female_min", "0"), 0, 0, 99)
    fmax = _int(_one(query, "female_max", "99"), 99, 0, 99)
    mmin = _int(_one(query, "male_min", "0"), 0, 0, 99)
    mmax = _int(_one(query, "male_max", "99"), 99, 0, 99)
    cmin = _int(_one(query, "cast_min", "0"), 0, 0, 99)
    cmax = _int(_one(query, "cast_max", "99"), 99, 0, 99)
    if fmin > fmax:
        fmin, fmax = fmax, fmin
    if mmin > mmax:
        mmin, mmax = mmax, mmin
    if cmin > cmax:
        cmin, cmax = cmax, cmin

    sort_by = _one(query, "sort_by", "release")
    if sort_by not in CAST_SORT:
        sort_by = "release"
    order = "ASC" if _one(query, "order", "desc") == "asc" else "DESC"
    offset = _int(_one(query, "offset", "0"), 0, 0, 100000)
    limit = _int(_one(query, "limit", "30"), 30, 1, 100)

    where = ["EXISTS (SELECT 1 FROM media_files f WHERE f.metadata_id = m.id)"]
    params: list = []
    if actor_ids:
        ph = ",".join("?" * len(actor_ids))
        where.append(
            "m.id IN (SELECT metadata_id FROM metadata_actors "
            f"WHERE actor_id IN ({ph}) GROUP BY metadata_id HAVING COUNT(DISTINCT actor_id) = {len(actor_ids)})"
        )
        params.extend(actor_ids)

    # 与影片库同口径的附加筛选：标签（AND）/ 字幕 / 马赛克 / 年份区间
    tag_ids = _ids(query, "tag_id")
    if tag_ids:
        ph = ",".join("?" * len(tag_ids))
        where.append(
            "m.id IN (SELECT metadata_id FROM metadata_tags "
            f"WHERE tag_id IN ({ph}) GROUP BY metadata_id HAVING COUNT(DISTINCT tag_id) = {len(tag_ids)})"
        )
        params.extend(tag_ids)
    if _one(query, "has_subtitle") in ("true", "1"):
        where.append(
            "EXISTS (SELECT 1 FROM media_files f2 WHERE f2.metadata_id = m.id "
            "AND (f2.has_subtitle_in_name = 1 OR f2.has_external_subtitle = 1))"
        )
    mosaic = _one(query, "mosaic")
    if mosaic in ("uncensored", "cracked", "leaked"):
        # 库里存的是大写 CRACKED / LEAKED / UNCENSORED，直接比小写永远为空
        where.append(
            "EXISTS (SELECT 1 FROM media_files f3 WHERE f3.metadata_id = m.id "
            "AND UPPER(f3.mosaic) = UPPER(?))")
        params.append(mosaic)
    year_from = _one(query, "year_from")
    year_to = _one(query, "year_to")
    if year_from.isdigit() or year_to.isdigit():
        lo = int(year_from) if year_from.isdigit() else 0
        hi = int(year_to) if year_to.isdigit() else 9999
        if lo > hi:
            lo, hi = hi, lo
        where.append("CAST(substr(m.release, 1, 4) AS INTEGER) BETWEEN ? AND ?")
        params.extend([lo, hi])

    agg = (
        "SUM(CASE WHEN LOWER(a.gender) = 'female' THEN 1 ELSE 0 END) AS female_count, "
        "SUM(CASE WHEN LOWER(a.gender) = 'male' THEN 1 ELSE 0 END) AS male_count, "
        "COUNT(ma.actor_id) AS cast_total"
    )
    # HAVING 里不能用 SELECT 别名：COUNT 查询的投影里没有这些别名，SQLite 会直接报
    # "no such column"，所以条件写完整聚合表达式。
    female_sum = "SUM(CASE WHEN LOWER(a.gender) = 'female' THEN 1 ELSE 0 END)"
    male_sum = "SUM(CASE WHEN LOWER(a.gender) = 'male' THEN 1 ELSE 0 END)"
    body = (
        "FROM metadata m "
        "JOIN metadata_actors ma ON ma.metadata_id = m.id "
        "JOIN actors a ON a.id = ma.actor_id "
        "WHERE " + " AND ".join(where) + " "
        "GROUP BY m.id "
        f"HAVING {female_sum} BETWEEN ? AND ? AND {male_sum} BETWEEN ? AND ? "
        "AND COUNT(ma.actor_id) BETWEEN ? AND ?"
    )
    extra = [fmin, fmax, mmin, mmax, cmin, cmax]

    try:
        with A.amane_db() as conn:
            total = conn.execute(
                "SELECT COUNT(*) FROM (SELECT m.id " + body + ")", params + extra
            ).fetchone()[0]
            rows = conn.execute(
                "SELECT m.id, m.number, m.title, m.release, m.runtime, m.content_type, "
                "m.poster_urls, m.thumb_urls, m.scores, " + agg + " " + body +
                f" ORDER BY {CAST_SORT[sort_by]} {order}, m.id DESC LIMIT ? OFFSET ?",
                params + extra + [limit, offset],
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR cast_find 查询失败: {exc}")
        return handler._error(500, f"共演查询失败: {exc}")

    mids = [r["id"] for r in rows]
    marks_map = _marks_of(mids)
    cast_map = _cast_rows(mids)
    avatars = _avatars_for(sorted({c["id"] for lst in cast_map.values() for c in lst}))

    items = []
    for r in rows:
        cast = cast_map.get(r["id"], [])
        for c in cast:
            c["avatar"] = avatars.get(c["id"], "")
        try:
            score = float((A.json.loads(r["scores"]) if isinstance(r["scores"], str) else {}).get("javdb") or 0)
        except (TypeError, ValueError):
            score = 0.0
        items.append({
            "id": r["id"],
            "number": _text(r["number"]),
            "title": _text(r["title"]),
            "release": _text(r["release"]),
            "runtime": _num(r["runtime"]),
            "content_type": _text(r["content_type"]),
            "score": round(score, 2),
            "poster": _poster_of(r),
            "marks": marks_map.get(r["id"], []),
            "female_count": _num(r["female_count"]),
            "male_count": _num(r["male_count"]),
            "cast_total": _num(r["cast_total"]),
            "cast": cast[:8],
        })
    handler._json({
        "items": items,
        "total": _num(total),
        "offset": offset,
        "limit": limit,
        "female_min": fmin, "female_max": fmax,
        "male_min": mmin, "male_max": mmax,
        "cast_min": cmin, "cast_max": cmax,
    })


def _head_alive(url: str, min_bytes: int = 10240) -> bool:
    """HEAD 一下，用来丢掉 "now printing" 占位图。

    dmm 在片子还没出 sample 时会返回一张固定的小图（实测 2732 字节），
    而真剧照通常 60KB 以上。拿不到 Content-Length 就放行，避免误杀。
    """
    try:
        req = urllib.request.Request(
            url, method="HEAD", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = resp.headers.get("Content-Length")
            if not raw:
                return True
            return int(raw) >= min_bytes
    except Exception:  # noqa: BLE001
        return True


def actors_stills(handler, query, actor_id, *_):
    """GET /api/user/actors/{id}/stills —— 该演员作品的随机剧照墙。

    两步随机：先随机挑若干部片子，再**在每部片子内部随机挑一张**。
    以前固定取每部的第一张，结果一屏八张全是各片的第 1 张，很单调。

    另外会 HEAD 校验一次，把 dmm 的 "now printing" 占位小图丢掉。
    """
    aid = _int(actor_id, 0, 1, 10 ** 9)
    limit = _int(_one(query, "limit", "12"), 12, 1, 36)
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT m.id, m.number, m.extrafanart_urls FROM metadata m "
                "WHERE m.id IN (SELECT metadata_id FROM metadata_actors WHERE actor_id = ?) "
                "AND EXISTS (SELECT 1 FROM media_files f WHERE f.metadata_id = m.id) "
                "AND m.extrafanart_urls IS NOT NULL "
                "AND m.extrafanart_urls NOT IN ('', '[]', '{}') "
                "ORDER BY RANDOM() LIMIT ?",
                (aid, max(limit * 2, 12)),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 取剧照失败: {exc}")
        return handler._error(500, f"剧照查询失败: {exc}")

    picks: list = []
    for r in rows:
        raw = r["extrafanart_urls"]
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
        if not urls:
            continue
        picks.append((r, random.choice(urls)))

    alive: list = []
    if picks:
        with ThreadPoolExecutor(max_workers=6) as pool:
            flags = list(pool.map(lambda pr: _head_alive(pr[1]), picks))
        for (r, u), ok in zip(picks, flags):
            if ok:
                alive.append((r, u))

    items: list = []
    for r, u in alive:
        proxied = A.public_image(u)
        if not proxied:
            continue
        items.append({"id": _num(r["id"]), "number": _text(r["number"]), "url": proxied})
        if len(items) >= limit:
            break
    handler._json({"items": items, "actor_id": aid})


# --------------------------------------------------------------------- 写真库

GALLERY_DDL = (
    "CREATE TABLE IF NOT EXISTS actor_gallery ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " actor_id INTEGER NOT NULL,"
    " url TEXT NOT NULL,"
    " created_at TEXT NOT NULL,"
    " UNIQUE(actor_id, url));"
)


def gallery_of(actor_id: int) -> list[str]:
    """用户自己补的写真（存在旁挂 user.db，不动 amane 的上游数据）。"""
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT url FROM actor_gallery WHERE actor_id = ? ORDER BY id DESC",
                (actor_id,)).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN actors 读写真库失败: {exc}")
        return []
    out: list[str] = []
    for r in rows:
        url = r["url"] if not isinstance(r, tuple) else r[0]
        # 上传入库的图存在旁挂服务自己的 /api/user/photo/ 下，已经是可直接访问的
        # 相对地址，不能再过 public_image（那是给外链转 /img?b= 用的）。
        if url.startswith("/api/user/photo/"):
            out.append(url)
            continue
        proxied = A.public_image(url)
        if proxied:
            out.append(proxied)
    return out


def gallery_list(handler, query, actor_id, *_):
    """GET /api/user/actors/{id}/gallery —— 只回自定义写真（上游头像另算）。"""
    aid = _int(actor_id, 0, 1, 10 ** 9)
    handler._json({"actor_id": aid, "items": gallery_of(aid)})


def gallery_add(handler, query, actor_id, *_):
    """POST /api/user/actors/{id}/gallery —— 粘一个图片 URL 就收进写真库。"""
    aid = _int(actor_id, 0, 1, 10 ** 9)
    body = handler._body()
    url = str(body.get("url") or "").strip()
    if not url.startswith(("http://", "https://")):
        return handler._error(400, "只接受 http(s) 图片地址")
    if not A.public_image(url):
        return handler._error(400, "这个域名不在图片白名单里，客户端加载不了")
    try:
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO actor_gallery(actor_id, url, created_at) VALUES(?,?,?) "
                "ON CONFLICT(actor_id, url) DO NOTHING",
                (aid, url, A.now_iso()))
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 写写真库失败: {exc}")
        return handler._error(500, f"保存失败: {exc}")
    handler._json({"ok": True, "items": gallery_of(aid)})


def gallery_remove(handler, query, actor_id, *_):
    """DELETE /api/user/actors/{id}/gallery?url=... —— 只删自定义条目。"""
    aid = _int(actor_id, 0, 1, 10 ** 9)
    url = _one(query, "url").strip()
    if not url:
        return handler._error(400, "缺少 url")
    with A.user_db() as conn:
        conn.execute("DELETE FROM actor_gallery WHERE actor_id = ? AND url = ?", (aid, url))
    handler._json({"ok": True, "items": gallery_of(aid)})


def gallery_upload(handler, query, actor_id, *_):
    """POST /api/user/actors/{id}/gallery/upload —— 手机相册里的图直接入库。

    body: {"data": "<base64（可带 data:image/...;base64, 前缀）>", "ext": "jpg"}
    图片落到 DATA_DIR/photos/<sha1>.<ext>，由核心的 /api/user/photo/<name> 提供访问，
    不经过图片白名单（本来就是自家文件）。
    """
    aid = _int(actor_id, 0, 1, 10 ** 9)
    body = handler._body()
    raw = str(body.get("data") or "")
    if raw.startswith("data:"):
        comma = raw.find(",")
        raw = raw[comma + 1:] if comma > 0 else raw
    try:
        blob = base64.b64decode(raw, validate=False)
    except Exception:  # noqa: BLE001
        return handler._error(400, "图片数据无法解析")
    if not blob:
        return handler._error(400, "空图片")
    if len(blob) > 12 * 1024 * 1024:
        return handler._error(413, "图片太大（上限 12MB）")

    ext = str(body.get("ext") or "").lower().lstrip(".")
    if ext in ("jpeg",):
        ext = "jpg"
    if ext not in ("jpg", "png", "webp", "gif"):
        # 用文件头猜
        if blob[:3] == b"\xff\xd8\xff":
            ext = "jpg"
        elif blob[:8] == b"\x89PNG\r\n\x1a\n":
            ext = "png"
        elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
            ext = "webp"
        elif blob[:3] == b"GIF":
            ext = "gif"
        else:
            return handler._error(400, "只支持 jpg / png / webp / gif")

    digest = hashlib.sha1(blob).hexdigest()
    name = f"{digest}.{ext}"
    try:
        A.save_photo(name, blob)
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 写真保存失败: {exc}")
        return handler._error(500, f"保存失败: {exc}")

    url = f"/api/user/photo/{name}"
    try:
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO actor_gallery(actor_id, url, created_at) VALUES(?,?,?) "
                "ON CONFLICT(actor_id, url) DO NOTHING",
                (aid, url, A.now_iso()))
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 写真入库失败: {exc}")
        return handler._error(500, f"入库失败: {exc}")
    handler._json({"ok": True, "url": url, "items": gallery_of(aid)})


# --------------------------------------------------------------------- 写真来源

# gfriends 是社区维护的演员头像/写真库（GitHub: gfriends/gfriends），
# 同一个人在不同厂牌目录下常有 -1 / -2 这类多张变体，正好当写真素材。
GF_INDEX_URL = "https://cdn.jsdelivr.net/gh/gfriends/gfriends@master/Filetree.json"
GF_CDN = "https://cdn.jsdelivr.net/gh/gfriends/gfriends@master/Content"
GF_TTL = 24 * 3600
_GF = {"at": 0.0, "by_name": {}}


def _gf_cache_path() -> str:
    base = os.path.dirname(getattr(A, "photo_dir", "/data/photos"))
    return os.path.join(base, "gfriends-index.json")


def _gf_index() -> dict:
    """索引（约 6MB JSON）→ {演员名: [候选相对路径]}，进程内 + 磁盘双层缓存。"""
    if _GF["by_name"] and time.time() - _GF["at"] < GF_TTL:
        return _GF["by_name"]

    path = _gf_cache_path()
    raw = ""
    try:
        if os.path.isfile(path) and time.time() - os.path.getmtime(path) < GF_TTL:
            with open(path, encoding="utf-8") as fh:
                raw = fh.read()
    except OSError:
        raw = ""
    if not raw:
        try:
            req = urllib.request.Request(GF_INDEX_URL, headers={"User-Agent": "amane-user"})
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(raw)
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN actors gfriends 索引拉取失败: {exc}")
            return _GF["by_name"]

    try:
        data = json.loads(raw)
    except ValueError:
        return _GF["by_name"]

    by_name: dict = {}
    for company, files in (data.get("Content") or {}).items():
        if not isinstance(files, dict):
            continue
        for key, real in files.items():
            if not isinstance(real, str):
                continue
            stem = os.path.splitext(str(key))[0]
            # 「三上悠亜-1」→ 主名「三上悠亜」，保留全部变体
            name = stem
            tail = stem.rsplit("-", 1)
            if len(tail) == 2 and tail[1].isdigit():
                name = tail[0]
            url = f"{GF_CDN}/{urllib.parse.quote(company)}/{urllib.parse.quote(real.split('?')[0])}"
            by_name.setdefault(name, []).append(url)

    _GF["by_name"] = by_name
    _GF["at"] = time.time()
    A.log(f"actors gfriends 索引就绪：{len(by_name)} 位演员")
    return by_name


def _download(url: str, limit: int = 8 * 1024 * 1024) -> tuple[bytes, str] | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "amane-user"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            ctype = (resp.headers.get("Content-Type") or "").lower()
            if "image" not in ctype:
                return None
            blob = resp.read(limit)
    except Exception:  # noqa: BLE001
        return None
    if not blob:
        return None
    ext = "jpg"
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        ext = "png"
    elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
        ext = "webp"
    elif blob[:3] == b"GIF":
        ext = "gif"
    return blob, ext


def gallery_fetch(handler, query, actor_id, *_):
    """POST /api/user/actors/{id}/gallery/fetch —— 按演员名从 gfriends 拉写真。

    body: {"limit": 8}（默认 8，上限 24）
    图会**下载到本地**再入库，这样 CDN 挂了也不影响已入库的写真，
    也不受图片白名单限制（自家文件）。
    """
    aid = _int(actor_id, 0, 1, 10 ** 9)
    body = handler._body()
    limit = _int(str(body.get("limit") or "8"), 8, 1, 24)

    name = ""
    try:
        with A.amane_db() as conn:
            row = conn.execute("SELECT name FROM actors WHERE id = ?", (aid,)).fetchone()
            if row is not None:
                name = (row["name"] if not isinstance(row, tuple) else row[0]) or ""
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 查演员名失败: {exc}")
    if not name:
        return handler._error(404, "演员不存在")

    index = _gf_index()
    if not index:
        return handler._error(502, "写真索引不可用（拉不到 gfriends 索引）")

    candidates = list(index.get(name.strip(), []))
    if not candidates:
        # 名字里带空格/全半角差异时做一次宽松匹配
        key = name.strip().replace(" ", "")
        for k, v in index.items():
            if k.replace(" ", "") == key:
                candidates = list(v)
                break
    if not candidates:
        return handler._json({"ok": True, "added": 0, "items": gallery_of(aid),
                              "note": f"gfriends 里没有「{name}」的图"})

    have = set(gallery_of(aid))
    added = 0
    for url in candidates:
        if added >= limit:
            break
        got = _download(url)
        if got is None:
            continue
        blob, ext = got
        digest = hashlib.sha1(blob).hexdigest()
        fname = f"{digest}.{ext}"
        rel = f"/api/user/photo/{fname}"
        if rel in have:
            continue
        try:
            A.save_photo(fname, blob)
            with A.user_db() as conn:
                conn.execute(
                    "INSERT INTO actor_gallery(actor_id, url, created_at) VALUES(?,?,?) "
                    "ON CONFLICT(actor_id, url) DO NOTHING", (aid, rel, A.now_iso()))
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN actors 写真入库失败（{url}）: {exc}")
            continue
        have.add(rel)
        added += 1

    handler._json({"ok": True, "added": added, "total": len(candidates),
                   "items": gallery_of(aid), "source": "gfriends"})


ROUTES = [
    ("GET", r"/api/user/actors", actors_list),
    ("GET", r"/api/user/actors/lookup", actors_lookup),
    ("GET", r"/api/user/actors/(\d+)", actors_detail),
    ("GET", r"/api/user/actors/(\d+)/media", actors_media),
    ("GET", r"/api/user/actors/(\d+)/stills", actors_stills),
    ("GET", r"/api/user/actors/(\d+)/gallery", gallery_list),
    ("POST", r"/api/user/actors/(\d+)/gallery", gallery_add),
    ("POST", r"/api/user/actors/(\d+)/gallery/upload", gallery_upload),
    ("POST", r"/api/user/actors/(\d+)/gallery/fetch", gallery_fetch),
    ("DELETE", r"/api/user/actors/(\d+)/gallery", gallery_remove),
    ("GET", r"/api/user/cast/find", cast_find),
    ("GET", r"/api/user/item/(\d+)/cast", item_cast),
]


def install(api) -> dict:
    global A  # noqa: PLW0603
    A = api
    api.add_ddl(GALLERY_DDL)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 actors 已启用（{len(ROUTES)} 个公开端点）")
    return {"id": "actors", "enabled": True, "scope": "public"}
