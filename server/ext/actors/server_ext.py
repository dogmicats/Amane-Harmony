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
import threading
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


def _director_names(metadata_ids: list[int]) -> dict:
    """一次查出这些影片的导演名（结果卡上要写「导演：xxx」，方便判断要不要排除）。"""
    if not metadata_ids:
        return {}
    ph = ",".join("?" * len(metadata_ids))
    out: dict = {}
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT md.metadata_id, d.name FROM metadata_directors md "
                "JOIN directors d ON d.id = md.director_id "
                f"WHERE md.metadata_id IN ({ph}) ORDER BY d.id", metadata_ids).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 取导演名失败: {exc}")
        return {}
    for r in rows:
        name = (r["name"] or "").strip()
        if name:
            out.setdefault(r["metadata_id"], []).append(name)
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
    "random": "RANDOM()",
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


def _sizes(query: dict, key: str) -> list[int]:
    """人数离散集合：`female_n=1,2` = 「1 个女演员 或 2 个女演员」。

    和 `_ids` 的区别是**允许 0**（`male_n=0` 就是「这部片没有男演员」），
    而 `_ids` 会把 0 当无效值丢掉。
    """
    out: list[int] = []
    for raw in (query.get(key) or []):
        for part in str(raw).split(","):
            part = part.strip()
            if not part.isdigit():
                continue
            n = int(part)
            if 0 <= n <= 99 and n not in out:
                out.append(n)
    return out[:8]


def _cast_filter(query: dict) -> dict:
    """共演筛选参数 → SQL 片段。**这是唯一来源**。

    cast_find 用它出结果列表，stills 扩展的 `scope=cast`（走 `stills_where` 钩子）
    用它抽剧照 —— 以后加筛选条件只改这里，两边不会漂。
    （「结果页按条件筛了、抽卡却还是全库」就是两处各写一份的典型后果。）

    返回 where / params / having / extra / body + 回显用的 echo。
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
    # 离散人数集合（「1 女 或 2 女」）：非空时在 HAVING 里再加一条 IN，
    # 与上面的 BETWEEN 并存（区间保持 0~99 时两者不会互相打架）。
    female_n = _sizes(query, "female_n")
    male_n = _sizes(query, "male_n")
    director_ids = _ids(query, "director_id")
    skip_dirs = _ids(query, "exclude_director_id")

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
    # 导演：包含=只要这几位（多选为「或」，与「演员必须同时出现」不同 ——
    # 导演栏是用来收窄/剔除流水线厂的，选两个导演想看的是这两人的片子合集）；
    # 排除=这几位导演的片子整片剔掉，正好用来干掉「n女n男 + 某导演」的固定搭配。
    if director_ids:
        ph = ",".join("?" * len(director_ids))
        where.append(
            "m.id IN (SELECT metadata_id FROM metadata_directors "
            f"WHERE director_id IN ({ph}))")
        params.extend(director_ids)
    if skip_dirs:
        ph = ",".join("?" * len(skip_dirs))
        where.append(
            "m.id NOT IN (SELECT metadata_id FROM metadata_directors "
            f"WHERE director_id IN ({ph}))")
        params.extend(skip_dirs)
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

    # HAVING 里不能用 SELECT 别名：COUNT 查询的投影里没有这些别名，SQLite 会直接报
    # "no such column"，所以条件写完整聚合表达式。
    female_sum = "SUM(CASE WHEN LOWER(a.gender) = 'female' THEN 1 ELSE 0 END)"
    male_sum = "SUM(CASE WHEN LOWER(a.gender) = 'male' THEN 1 ELSE 0 END)"
    having = [f"{female_sum} BETWEEN ? AND ?", f"{male_sum} BETWEEN ? AND ?",
              "COUNT(ma.actor_id) BETWEEN ? AND ?"]
    extra = [fmin, fmax, mmin, mmax, cmin, cmax]
    if female_n:
        having.append(f"{female_sum} IN ({','.join('?' * len(female_n))})")
        extra.extend(female_n)
    if male_n:
        having.append(f"{male_sum} IN ({','.join('?' * len(male_n))})")
        extra.extend(male_n)
    body = (
        "FROM metadata m "
        "JOIN metadata_actors ma ON ma.metadata_id = m.id "
        "JOIN actors a ON a.id = ma.actor_id "
        "WHERE " + " AND ".join(where) + " "
        "GROUP BY m.id "
        "HAVING " + " AND ".join(having)
    )
    return {
        "where": where,
        "params": params,
        "having": having,
        "extra": extra,
        "body": body,
        "echo": {
            "female_min": fmin, "female_max": fmax,
            "male_min": mmin, "male_max": mmax,
            "cast_min": cmin, "cast_max": cmax,
            "female_n": female_n, "male_n": male_n,
            "director_id": director_ids, "exclude_director_id": skip_dirs,
        },
    }


def cast_find(handler, query, *_):
    """GET /api/user/cast/find —— 按演员阵容找片（共演 / 女演员人数）。

    上游 /api/metadata 只能按 actor_id 做 AND 过滤，答不了「这部片有 N 个女演员」
    这类问题，所以这里直接对 amane 只读库做一次聚合查询：

      * `actor_id=1&actor_id=2`  这些演员必须同时出现（具体 N 男 N 女共演）
      * `female_min/female_max`  女演员人数区间
      * `male_min/male_max`      男演员人数区间
      * `female_n=1,2` / `male_n=0,1` 人数离散集合（客户端「1女 2女 3女 4女」
        方形多选就是它：勾了几个就是「这几个数量里的任意一个」，不是区间）
      * `cast_min/cast_max`      总人数区间
      * `director_id=…` / `exclude_director_id=…` 按导演收窄 / 排除
        （「n女n男 + 某导演」的组合可以从结果里整片剔掉）

    筛选条件全部来自 _cast_filter()，与抽卡墙的 `scope=cast` 共用同一份 SQL。
    只返回有文件的条目，默认按发行日期倒序。
    """
    f = _cast_filter(query)
    params: list = f["params"]
    extra: list = f["extra"]
    body: str = f["body"]

    sort_by = _one(query, "sort_by", "release")
    if sort_by not in CAST_SORT:
        sort_by = "release"
    order = "ASC" if _one(query, "order", "desc") == "asc" else "DESC"
    offset = _int(_one(query, "offset", "0"), 0, 0, 100000)
    limit = _int(_one(query, "limit", "30"), 30, 1, 100)

    agg = (
        "SUM(CASE WHEN LOWER(a.gender) = 'female' THEN 1 ELSE 0 END) AS female_count, "
        "SUM(CASE WHEN LOWER(a.gender) = 'male' THEN 1 ELSE 0 END) AS male_count, "
        "COUNT(ma.actor_id) AS cast_total"
    )

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
    dir_map = _director_names(mids)

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
            "directors": dir_map.get(r["id"], [])[:3],
        })
    handler._json({
        "items": items,
        "total": _num(total),
        "offset": offset,
        "limit": limit,
        **f["echo"],
    })


def stills_where(scope: str, query: dict):
    """求值钩子（stills 扩展调）：`scope=cast` 的「metadata m」过滤片段。

    返回 None = 不归我管，stills 会继续问下一个扩展、都没有就回 400。
    抽卡墙因此能按**同一套共演筛选条件**抽片，而不是退回全库。
    """
    if scope != "cast":
        return None
    f = _cast_filter(query)
    return {
        "where": "m.id IN (SELECT m.id " + f["body"] + ")",
        "args": list(f["params"]) + list(f["extra"]),
        "note": f["echo"],
    }


def actors_stills(handler, query, actor_id, *_):
    """GET /api/user/actors/{id}/stills —— 该演员作品的随机剧照墙。

    两条硬要求（用户实测反馈）：
      1. **首帧就要摆对**：以前不下发比例，客户端只能先按 3:2 铺、图片加载完再重排，
         看到的就是「先方块罗列、再变成瀑布流」。现在每条带 `ratio`（核心的
         img_dims 缓存，命中零网络；没量过只取图片头 128KB）。
      2. **「再抽一次」要快**：一次多给（limit 的 3 倍，上限 36），客户端自己轮换池子，
         换一批不再等网络。

    随机口径不变：先随机挑若干部片，再在每部片内部随机挑一张，避免一屏全是同一部。
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
                (aid, max(limit * 3, 24)),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR actors 取剧照失败: {exc}")
        return handler._error(500, f"剧照查询失败: {exc}")

    # 每部片一组候选 URL（打乱），按「轮转」方式各取一张，保证一屏里片名分散
    lanes: list[tuple[dict, list[str]]] = []
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
        urls = list(dict.fromkeys(urls))
        if not urls:
            continue
        random.shuffle(urls)
        lanes.append(({"id": _num(r["id"]), "number": _text(r["number"])}, urls))

    items: list = []
    used: set[str] = set()

    deadline = time.time() + 2.0   # 全局预算：别每轮各算一次，否则 4 轮能拖到 6 秒

    def measure(pairs: list[tuple[dict, str]], cap: int) -> None:
        """并行量尺寸并把合格的收进 items。

        只量「还需要的那几张」：以前每轮都把整池（90 部）全量一遍，limit=1 也要
        量 90 张 → 3.7 秒。现在按需取，全程共用 2 秒预算，超时先返回已有的，
        剩下交给后台预热，下次直接命中缓存。
        """
        if not pairs:
            return
        chunk = 20
        for start in range(0, len(pairs), chunk):
            if len(items) >= cap or time.time() > deadline:
                break
            part = pairs[start:start + chunk]
            with ThreadPoolExecutor(max_workers=16) as pool:
                sizes = list(pool.map(lambda pair: A.image_dims(pair[1]), part))
            for (row, url), size in zip(part, sizes):
                if len(items) >= cap or not size:
                    continue
                if url in used:
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

    # 第一轮：每部片各取第一张，按需（limit + 余量）量
    for round_no in range(4):
        if len(items) >= limit:
            break
        pairs: list[tuple[dict, str]] = []
        for row, urls in lanes:
            if len(urls) <= round_no:
                continue
            pairs.append((row, urls[round_no]))
        need = limit - len(items)
        measure(pairs[:max(need + 4, 8)], limit)

    # 没量到比例的先照样返回（客户端会自己量），后台补进 img_dims，下一批就准了
    leftover: list[str] = []
    for _row, urls in lanes:
        for url in urls:
            if url not in used:
                leftover.append(url)
                break
    if leftover and len(items) < limit:
        def warm() -> None:
            for url in leftover[:40]:
                try:
                    A.image_dims(url)
                except Exception:  # noqa: BLE001
                    pass

        try:
            threading.Thread(target=warm, daemon=True, name="still-warm").start()
        except RuntimeError:
            pass

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


# --------------------------------------------------------------------- 搜索联想
# 核心 /api/user/suggest 的 `suggest_entities` 钩子。演员是核心唯一认不出来的
# 实体（metadata.actors 只是一串名字，点不进任何页面），所以按名字命中演员表，
# 交给核心排在影片后面；客户端点它进的是演员作品列表。
SUGGEST_LIMIT = 6


def _suggest_actors(raw: str, limit: int) -> dict:
    """名字命中优先，其次别名命中，再按作品数 —— 排序必须在 SQL 里做，LIMIT 之后再排会漏人。

    amane 认演员靠「actors.name + actor_aliases」两处：中文圈习惯叫的「蕾」是
    「つぼみ」的别名。只按 name 匹配就会出现「演员列表里搜得到、搜索联想里搜不到」
    （演员列表走上游 /api/actors?search=，那边是认别名的）。
    """
    esc = raw.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    like = f"%{esc}%"
    prefix = f"{esc}%"
    sql = (
        "SELECT a.id AS id, a.name AS name, a.gender AS gender, "
        "(SELECT COUNT(*) FROM metadata_actors ma WHERE ma.actor_id = a.id) AS cnt, "
        # 0 名字前缀 · 1 别名完全相同 · 2 名字包含 · 3 别名前缀/包含 · 4 兜底
        # 「蕾」这种完全等于别名的命中必须排在「名字里恰好带这个字」的人前面，
        # 否则搜 蕾 会先给出一堆莲实克蕾儿，真正叫这个名的 つぼみ 排到后面。
        "CASE WHEN a.name LIKE ? ESCAPE '\\' THEN 0 "
        "WHEN EXISTS (SELECT 1 FROM actor_aliases ae WHERE ae.actor_id = a.id "
        "AND ae.name = ? COLLATE NOCASE) THEN 1 "
        "WHEN a.name LIKE ? ESCAPE '\\' THEN 2 "
        "WHEN EXISTS (SELECT 1 FROM actor_aliases ap WHERE ap.actor_id = a.id "
        "AND ap.name LIKE ? ESCAPE '\\') THEN 3 ELSE 4 END AS pre, "
        # 命中的那个别名（按名字命中时留空），卡片上标一句「别名 蕾」才不莫名其妙
        "(SELECT al.name FROM actor_aliases al WHERE al.actor_id = a.id "
        "AND al.name LIKE ? ESCAPE '\\' ORDER BY al.position, al.id LIMIT 1) AS ali "
        "FROM actors a "
        "WHERE a.name LIKE ? ESCAPE '\\' "
        "OR EXISTS (SELECT 1 FROM actor_aliases ax WHERE ax.actor_id = a.id "
        "AND ax.name LIKE ? ESCAPE '\\') "
        "ORDER BY pre ASC, cnt DESC, LENGTH(a.name) ASC, a.id ASC LIMIT ?"
    )
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                sql, (prefix, raw, like, prefix, like, like, like, limit)).fetchall()
            total = _num(conn.execute(
                "SELECT COUNT(*) FROM actors a WHERE a.name LIKE ? ESCAPE '\\' "
                "OR EXISTS (SELECT 1 FROM actor_aliases ax WHERE ax.actor_id = a.id "
                "AND ax.name LIKE ? ESCAPE '\\')", (like, like)).fetchone()[0])
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN actors 联想失败: {exc}")
        return {"total": 0, "items": []}

    avatars = _avatars_for([_num(r["id"]) for r in rows])
    items = []
    for r in rows:
        aid = _num(r["id"])
        pre = _num(r["pre"])
        items.append({
            "type": "actor",
            "id": aid,
            "name": _text(r["name"]),
            "count": _num(r["cnt"]),
            "gender": (_text(r["gender"]) or "unknown").strip().lower(),
            # 按别名命中的才带出来；名字自己命中时留空，免得「つぼみ 别名 つぼみ」
            "alias": "" if pre == 0 else _text(r["ali"]),
            "image": avatars.get(aid, ""),
            "tier": 1 if pre <= 1 else (2 if pre <= 3 else 3),
        })
    return {"total": total, "items": items}


def suggest_entities(raw: str, kinds: list) -> dict:
    """返回 {kind: {"total": n, "items": [...]}}；没被要求的 kind 不出现。"""
    if "actor" not in (kinds or []):
        return {}
    return {"actor": _suggest_actors(raw, SUGGEST_LIMIT)}


def suggest_kinds() -> dict:
    """告诉核心「我这一摊能联想哪些类型」，核心据此回答 supported。"""
    return {"actors": ["actor"]}


def suggest_films(raw: str, limit: int) -> dict:
    """按**演员别名**回查影片 id，补进影片联想。

    `metadata.actors` 存的是规范名（つぼみ），别名（蕾）只在 `actor_aliases` 里 ——
    所以搜「蕾」按普通影片条件是命中不了的。核心不认演员表，这里按别名把 id 解析出来，
    核心只管「这些 id 也要出现在影片里」。只回 id，海报/标题仍由核心统一取。
    """
    esc = raw.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    like = f"%{esc}%"
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT DISTINCT m.id AS id, m.release AS rel "
                "FROM actor_aliases al "
                "JOIN metadata_actors ma ON ma.actor_id = al.actor_id "
                "JOIN metadata m ON m.id = ma.metadata_id "
                "WHERE al.name LIKE ? ESCAPE '\\' "
                "AND m.id IN (SELECT metadata_id FROM media_files) "
                "ORDER BY m.release DESC, m.id DESC LIMIT ?",
                (like, max(1, min(limit, 12))),
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN actors 别名回查影片失败: {exc}")
        return {"ids": []}
    return {"ids": [_num(r["id"]) for r in rows if _num(r["id"]) > 0]}


def install(api) -> dict:
    global A  # noqa: PLW0603
    A = api
    api.add_ddl(GALLERY_DDL)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("suggest_entities", suggest_entities)
    api.hook("suggest_kinds", suggest_kinds)
    api.hook("suggest_films", suggest_films)
    # stills 扩展的「求值钩子」：共演筛选结果页要按同一套条件抽剧照，
    # 筛选 SQL 只留 _cast_filter 一份，别在抽卡里再抄一遍。
    api.hook("stills_where", stills_where)
    api.log(f"扩展 actors 已启用（{len(ROUTES)} 个公开端点 + 搜索联想 + 抽卡范围）")
    return {"id": "actors", "enabled": True, "scope": "public"}
