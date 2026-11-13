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

import json
import os
import random
import urllib.request
from urllib.parse import parse_qs, quote, unquote, urlparse
import re

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

FACET_SORT = {"name", "count", "recent_update", "recent_release", "random", "my_rating"}
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

# 分类评分（演员 / 导演 / 厂牌 / 标签 / 系列）：落在旁挂自己的 user.db，
# 不写 amane 的库 —— 上游没有这个字段，也不该被我们改表。
RATING_DDL = """
CREATE TABLE IF NOT EXISTS facet_rating (
    kind       TEXT    NOT NULL,
    facet_id   INTEGER NOT NULL,
    stars      INTEGER NOT NULL,
    updated_at TEXT    NOT NULL,
    PRIMARY KEY (kind, facet_id)
);
"""

RATING_KINDS = {"tag", "series", "studio", "publisher", "director", "actor"}


def _user_db_path() -> str:
    """user.db 的绝对路径：跨库 JOIN 要 ATTACH 真实文件，不能靠 A.user_db() 的连接。"""
    return os.path.join(os.environ.get("DATA_DIR", "/data"), "user.db")


def _row_rating(row) -> int:
    """聚合行里的「我的评分」；没挂 user.db 或没打过分时返回 0。"""
    try:
        return _num(row["my_rating"])
    except (IndexError, KeyError):
        return 0


def _attach_user(conn) -> bool:
    """把 user.db 挂到 upstream 连接上（别名 u）。已经挂过返回 True。"""
    try:
        conn.execute("ATTACH DATABASE ? AS u", (_user_db_path(),))
        return True
    except Exception as exc:  # noqa: BLE001
        if "already" in str(exc).lower():
            return True
        A.log(f"WARN facets 无法挂载 user.db（评分不可用）: {exc}")
        return False


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
    """影片海报：统一交给核心 `public_image` 转外网可达路径。

    以前这里对 `/api/resources/` 直接返回原路径，客户端会把它分流到上游 8000 ——
    外网访问时整片白屏（2.5.5.22）。
    """
    for key in ("poster_url", "thumb_url", "poster_urls", "thumb_urls"):
        value = item.get(key)
        urls = value if isinstance(value, list) else ([value] if isinstance(value, str) else [])
        for u in urls:
            if not isinstance(u, str):
                continue
            p = A.public_image(u)
            if p:
                return p
    return ""


def _apply_overrides(items: list) -> list:
    """把本地覆盖层（改过的片名 / 演员 / 封面）盖到卡片上（2.5.5.7）。

    扩展是独立文件、不经过核心的 `query_meta`，所以这里必须显式套一次 ——
    否则「详情页换了封面，标签页里还是旧图」。核心没这个函数时静默跳过。
    """
    fn = getattr(A, "apply_overrides", None)
    if fn is None:
        return items
    try:
        return fn(items)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 套覆盖层失败: {exc}")
        return items


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


# 核心 1.3.41+ 在每条 amane_db() 连接上注册了 amane_rel(name, kw)（关键词相关性
# 分档）。只检测一次：老核心没有这个函数时退回 LIKE，「能搜到」比「排得好」重要。
_REL_OK: bool | None = None


def _has_rel() -> bool:
    global _REL_OK
    if _REL_OK is None:
        try:
            with A.amane_db() as conn:
                conn.execute("SELECT amane_rel('a', 'a')").fetchone()
            _REL_OK = True
        except Exception:  # noqa: BLE001
            _REL_OK = False
            A.log("WARN facets: 核心未提供 amane_rel，搜索退回 LIKE")
    return _REL_OK


# 每个 metadata 的最新入库时间先聚一次再 JOIN：直接连 media_files 会按文件数放大行数，
# 逼着外面用 COUNT(DISTINCT)，在 6 万行关联表上要多花几百毫秒。
_RECENT_JOIN = ("LEFT JOIN (SELECT metadata_id, MAX(created_at) AS last_at "
                "FROM media_files GROUP BY metadata_id) f "
                "ON f.metadata_id = m.id ")


def _agg_sql(kind: str, search: str, favorite: str, hidden: set | None = None,
             rating: str = "", with_rating: bool = True) -> tuple[str, list]:
    """分类聚合子查询：实体行 + 片数 + 最新入库 / 最新发行。

    片数口径与上游一致（关联分类数挂载行、标量分类数同名 metadata 行）。

    搜索（2.4.6.21）用核心的 `amane_rel()` 而不是 LIKE：归一化（全角/大小写/连字符）
    之后再分档，「越精准越靠前」靠的是 SELECT 里的 rel 列，排序在 facets_list 里拼。
    老核心没注册这个函数时退回 LIKE，至少还能搜到。
    """
    where: list[str] = []
    args: list = []
    select_args: list = []
    rel = search and _has_rel()
    if search:
        if rel:
            where.append("amane_rel(e.name, ?) IS NOT NULL")
            args.append(search)
        else:
            where.append("e.name LIKE ? ESCAPE '\\'")
            args.append(_like(search))
    if favorite in ("true", "false"):
        where.append("e.is_favorite = ?")
        args.append(1 if favorite == "true" else 0)
    # 分类评分筛选：`none` = 还没打分的（用户要「找出想打分但忘了打的」）
    if rating and with_rating:
        if rating == "none":
            where.append("r.stars IS NULL")
        elif rating.isdigit():
            where.append("r.stars = ?")
            args.append(int(rating))
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
           "MAX(f.last_at) AS last_added")
    if with_rating:
        sql += ", r.stars AS my_rating"
    if rel:
        # 相关性档位要在 SELECT 里算：ORDER BY 直接引用 rel，翻页也不会变
        sql += ", MIN(amane_rel(e.name, ?)) AS rel"
        select_args.append(search)
    join = ("LEFT JOIN u.facet_rating r ON r.kind = ? AND r.facet_id = e.id "
            if with_rating else "")
    sql += " " + head + join + _RECENT_JOIN + cond + "GROUP BY e.id"
    # 参数按占位符出现顺序：SELECT 里的 rel → JOIN 里的 kind → WHERE
    return sql, select_args + ([kind] if with_rating else []) + args


_ORDER_COL = {
    "count": "cnt",
    "recent_update": "last_added",
    "recent_release": "last_release",
    "my_rating": "my_rating",
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


_PREFIX_RE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9]{1,11})[\s_-]")


def _prefix_of(number: str) -> str:
    """单个番号的前缀（`SPSD-14` → `SPSD`）；认不出就回空串。

    与 `_prefixes()` 用同一个正则，避免「厂牌页显示 SPSD、详情页却算成 SPS」这种不一致。
    """
    m = _PREFIX_RE.match(number or "")
    return m.group(1).upper() if m else ""


def on_browse_where(query: dict) -> dict:
    """`?prefix=SPSD` —— 同番号前缀的影片（2.4.6.18）。

    番号前缀是厂牌自己的编号体系（GIGA 的 SPSD、IDEA POCKET 的 IPZZ），
    详情页点前缀就能看「这个系列编号的全部作品」。语义属于 facets（前缀就是从
    分类统计里提炼出来的），所以放这里，核心 browse 只当普通筛选条件用。
    """
    raw = ((query.get("prefix") or [""])[0]).strip().upper()
    if not raw:
        return {}
    if not re.fullmatch(r"[A-Z][A-Z0-9]{1,11}", raw):
        return {"clauses": [("1 = 0", [])]}
    # LIKE 里 `_` / `%` 是通配符，前缀只允许字母数字就能直接拼；参数仍然走占位符
    return {"clauses": [("m.number LIKE ?", [f"{raw}%"])]}


def _prefixes(kind: str, ids: list) -> dict:
    """制片商 / 发行商的「番号前缀」TOP3（2.4.5.15）。

    番号形如 `SPSD-14`、`IPZZ-037`，前缀就是厂牌自己的编号体系：看到 SPSD/GHKQ/THZ
    就知道是 GIGA，看到 IPX/IPZZ 就知道是 IDEA POCKET —— 对不上日文厂牌名时，
    这串字母比名字更容易认。同一厂牌常有多套前缀（不同系列 / 不同年代），
    按作品数取前三，客户端用 `/` 连起来显示。

    只对 studio / publisher 生效：标签、系列没有厂牌级番号体系。
    一页最多 20 个厂牌，一次把这些厂牌的番号全捞出来在内存里归堆就够了，
    不额外缓存（数据一入库就变，缓存反而要处理失效）。
    """
    if kind not in ("studio", "publisher") or not ids:
        return {}
    table, col = SCALAR_SPEC[kind]
    marks = ",".join("?" * len(ids))
    try:
        with A.amane_db() as conn:
            names = {_num(r["id"]): r["name"] for r in conn.execute(
                f"SELECT id, name FROM {table} WHERE id IN ({marks})", ids)}
            if not names:
                return {}
            keys = [n for n in names.values() if n]
            rows = conn.execute(
                f"SELECT m.{col} AS k, m.number AS n FROM metadata m "
                f"WHERE m.{col} IN ({','.join('?' * len(keys))}) "
                f"AND m.number IS NOT NULL AND m.number <> ''", keys).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取番号前缀失败 {kind}: {exc}")
        return {}

    buckets: dict = {}
    for row in rows:
        m = _PREFIX_RE.match(row["n"] or "")
        if m is None:
            continue
        bucket = buckets.setdefault(row["k"], {})
        key = m.group(1).upper()
        bucket[key] = bucket.get(key, 0) + 1

    out: dict = {}
    for fid, name in names.items():
        counts = buckets.get(name) or {}
        if not counts:
            continue
        top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
        out[fid] = [k for k, _c in top]
    return out


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


def _poster_both(kind: str, ids: list, limit: int = 0) -> tuple[dict, dict]:
    """一页分类的缩略图：URL 列表 + 带影片 id 的条目列表。

    单条查询取全页，避免 40 个分类各查一次；张数默认按 POSTER_KINDS 的版式需求
    （标签/系列 3 张、导演/制片商 8 张）。收藏页的横版行需要能一直往右滑
    （2.4.5.13 用户反馈：标签/系列只出 3 部，演员与制片厂却能滑很多），
    那里显式传 `limit=12`，让四类收藏的观感一致。

    为什么要多回一份 `posterItems`：收藏页的行里点海报要直接进那部影片，
    只有 URL 没有 id 就跳不了。原有 `posters`（纯 URL）保持不变，老页面不受影响。
    """
    if limit <= 0:
        limit = POSTER_KINDS.get(kind, 0)
    if not limit or not ids:
        return {}, {}
    ph = ",".join("?" * len(ids))
    if kind in LINK_SPEC:
        _ent, link, fk = LINK_SPEC[kind]
        sql = (f"SELECT l.{fk} AS k, m.id AS mid, m.poster_urls, m.thumb_urls FROM {link} l "
               f"JOIN metadata m ON m.id = l.metadata_id "
               f"WHERE l.{fk} IN ({ph}) ORDER BY m.release DESC, m.id DESC")
    else:
        table, col = SCALAR_SPEC[kind]
        sql = (f"SELECT e.id AS k, m.id AS mid, m.poster_urls, m.thumb_urls FROM {table} e "
               f"JOIN metadata m ON m.{col} = e.name "
               f"WHERE e.id IN ({ph}) ORDER BY m.release DESC, m.id DESC")
    try:
        with A.amane_db() as conn:
            rows = conn.execute(sql, ids).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取分类缩略图失败: {exc}")
        return {}, {}
    urls: dict = {}
    items: dict = {}
    for row in rows:
        key = row["k"]
        bucket = urls.setdefault(key, [])
        if len(bucket) >= limit:
            continue
        p = _poster_of(row)
        if not p or p in bucket:
            continue
        bucket.append(p)
        items.setdefault(key, []).append({"id": _num(row["mid"]), "url": p})
    return urls, items


def _poster_map(kind: str, ids: list) -> dict:
    """一页分类的缩略图（只要 URL，给分类列表 / 详情头部用）。"""
    return _poster_both(kind, ids)[0]


def _series_top_tags(ids: list, counts: dict, hidden: set, per: int = 3) -> dict:
    """每个系列占比最高的几个标签（排除隐藏标签）。

    收藏页的「系列」横版行要把这几个标签画成属性胶囊，所以放在列表接口里一次算完，
    不让客户端为每个系列各请求一次 `/tags`。`ratio` = 该标签片数 / 这个系列的片数，
    与系列页顶部那份统计同口径。
    """
    if not ids:
        return {}
    ph = ",".join("?" * len(ids))
    sql = ("SELECT s.id AS sid, t.id AS tid, t.name AS tname, "
           "COUNT(DISTINCT mt.metadata_id) AS n "
           "FROM series s JOIN metadata m ON m.series = s.name "
           "JOIN metadata_tags mt ON mt.metadata_id = m.id "
           "JOIN tags t ON t.id = mt.tag_id "
           f"WHERE s.id IN ({ph})")
    args: list = list(ids)
    if hidden:
        sql += f" AND t.id NOT IN ({','.join('?' * len(hidden))})"
        args.extend(sorted(hidden))
    sql += " GROUP BY s.id, t.id ORDER BY s.id, n DESC"
    out: dict = {}
    try:
        with A.amane_db() as conn:
            for r in conn.execute(sql, args):
                sid = _num(r["sid"])
                bucket = out.setdefault(sid, [])
                if len(bucket) >= per:
                    continue
                total = max(1, counts.get(sid, 0))
                bucket.append({
                    "id": _num(r["tid"]),
                    "name": _text(r["tname"]),
                    "ratio": round(_num(r["n"]) / total, 3),
                })
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取系列属性失败: {exc}")
        return {}
    return out


def _virtual_facets(kind: str, known: set) -> list:
    """用户自己新建的分类：覆盖层里有、库里没有的系列名 / 标签名（2.5.5.4）。

    只从 `meta_override.fields` 里读，不建第二张表 —— 覆盖层本来就是这些
    新名字的唯一来源。数量很小（几十条），一次全扫可接受。
    """
    if kind not in ("series", "tag"):
        return []
    field = "series" if kind == "series" else "tags"
    counts: dict = {}
    try:
        with A.user_db() as conn:
            rows = conn.execute("SELECT fields FROM meta_override").fetchall()
    except Exception:  # noqa: BLE001
        return []
    for r in rows:
        try:
            fields = json.loads(r["fields"] or "{}")
        except (TypeError, ValueError):
            continue
        if not isinstance(fields, dict):
            continue
        value = fields.get(field)
        names = value if isinstance(value, list) else ([value] if isinstance(value, str) else [])
        for raw in names:
            name = str(raw or "").strip()
            if name and name not in known:
                counts[name] = counts.get(name, 0) + 1
    out = [{"name": k, "count": v} for k, v in counts.items() if v > 0]
    out.sort(key=lambda v: (-v["count"], v["name"]))
    return out


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
    rating = _one(query, "rating")
    if rating not in ("none", "1", "2", "3", "4", "5"):
        rating = ""
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
    agg, args = _agg_sql(kind, search, fav, hidden, rating, with_rating=True)
    # 搜索时相关性是主序，用户选的排序退成次级：搜「三上」时「三上悠亜」必须排在
    # 「三上理子」前面，而不是谁作品多谁在前。
    order_sql = _order_sql(sort_by, order, seed)
    if search and _has_rel():
        order_sql = "rel ASC, " + order_sql
    try:
        with A.amane_db() as conn:
            # 评分在 user.db，跨库 JOIN 靠 ATTACH；挂不上就退化成「不带评分」的查询
            if not _attach_user(conn):
                agg, args = _agg_sql(kind, search, fav, hidden, "", with_rating=False)
            total = _num(conn.execute(f"SELECT COUNT(*) FROM ({agg})", args).fetchone()[0])
            rows = conn.execute(
                f"{agg} ORDER BY {order_sql} LIMIT ? OFFSET ?",
                args + [params["limit"], params["offset"]],
            ).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 分类聚合失败 {kind}: {exc}")
        return handler._error(502, f"amane 分类数据不可用: {exc}")
    ids = [_num(r["id"]) for r in rows]
    # 收藏页要能一直滑：四类统一给 12 张，而不是按分类版式各给 3/8 张
    posters, poster_items = _poster_both(kind, ids, 12 if fav == "true" else 0)
    prefixes = _prefixes(kind, ids)
    # 系列的「属性」＝占比最高的几个标签（隐藏标签已排除），收藏页画成彩色胶囊
    top_tags: dict = {}
    if kind == "series" and fav == "true" and ids:
        counts = {_num(r["id"]): _num(r["cnt"]) for r in rows}
        top_tags = _series_top_tags(ids, counts, _hidden_ids("tag"))
    items = []
    # 一次取全量自定义封面，别在循环里逐个查（列表 40 项就是 40 次查询）
    covers = _facet_covers(kind)
    for r in rows:
        fid = _num(r["id"])
        fname = _text(r["name"])
        items.append({
            "id": fid,
            "name": fname,
            "count": _num(r["cnt"]),
            "isFavorite": bool(r["fav"]),
            "myRating": _row_rating(r),
            "posters": posters.get(fid, []),
            "posterItems": poster_items.get(fid, []),
            "topTags": top_tags.get(fid, []),
            "prefixes": prefixes.get(fid, []),
            "lastRelease": _text(r["last_release"])[:10],
            "lastAdded": _text(r["last_added"])[:10],
            "isHidden": fid in hidden_all,
            "logo": _logo_url(kind, fid),
            "cover": covers.get(fname, ""),
        })
    # 用户自己新建的系列 / 标签：库里没有，但要让它在列表里看得见（2.5.5.4）。
    # 搜索时也要算进来 —— 否则「搜一下我建的标签」永远搜不到（2.5.5.20）。
    if params["offset"] == 0 and kind in ("series", "tag"):
        known = {it["name"] for it in items}
        wanted = _virtual_facets(kind, known)
        if search:
            # 这里只能用扩展内自己的归一化（core 的 `_norm_kw` 不在本模块命名空间，
            # 2.5.5.23 就是在这里 NameError 把整个搜索打成 500 的）
            kw = str(search or "").strip().lower()
            if kw:
                wanted = [v for v in wanted if kw in str(v["name"]).lower()]
            else:
                wanted = []
        for v in wanted[:20]:
            items.append({
                "id": 0, "name": v["name"], "count": v["count"],
                "isFavorite": False, "myRating": 0,
                "posters": [], "posterItems": [], "topTags": [], "prefixes": [],
                "lastRelease": "", "lastAdded": "", "isHidden": False,
                "logo": "", "cover": covers.get(v["name"], ""), "virtual": True,
            })
        if wanted:
            total = total + len(wanted[:20])

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



# 制片厂官方 logo：只认厂牌自己的家网站点，取它的 favicon。
# 为什么不做「全网搜图」：搜来的图不可控（尺寸、水印、甚至认错厂），
# favicon 是厂牌自己挂的、稳定、体积极小，缓存一次就不再联网。
STUDIO_SITES = {
    # 覆盖「片数前 50」里能拿到官网的厂牌。域名都实测过首页可达；
    # 有 403/CF 拦截或查不到官网的厂牌**不写**（不写=不显示，不挂错图）。
    "GIGA": "www.giga-web.jp",
    "MOODYZ": "moodyz.com",
    "S1 NO.1 STYLE": "s1s1s1.com",
    "S1": "s1s1s1.com",
    "ATTACKERS": "attackers.net",
    "SOD CREATE": "www.sod.co.jp",
    "SOD": "www.sod.co.jp",
    "IDEA POCKET": "ideapocket.com",
    "マドンナ": "madonna-av.com",
    "MADONNA": "madonna-av.com",
    "プレステージ": "prestige-av.com",
    "PRESTIGE": "prestige-av.com",
    "ダスッ！": "dasdas.jp",
    "ワンズファクトリー": "wanzfactory.com",
    "WANZ": "wanzfactory.com",
    "本中": "honnaka.com",
    "HONNAKA": "honnaka.com",
    "KAWAII": "kawaii-av.com",
    "無垢": "muku.tv",
    "MUKU": "muku.tv",
    "FALENO": "faleno.jp",
    "FALENO TUBE": "faleno.jp",
    "FITCH": "fitch-av.com",
    "溜池ゴロー": "tameike.com",
    "TAMEIKE": "tameike.com",
    "GLORY QUEST": "glory-quest.com",
    "E-BODY": "e-body.net",
    "ナチュラルハイ": "natural-high.co.jp",
    "OPPAI": "oppai-av.com",
    "アリスJAPAN": "alicejapan.co.jp",
    "ケイ・エム・プロデュース": "kmpro.co.jp",
    "東京熱": "tokyo-hot.com",
    "ROOKIE": "rookie-av.jp",
    "MARLO MEDIA": "marlo-media.com",
    "TMA": "tma.co.jp",
    "ながえスタイル": "www.nagae-style.com",
    "DAHLIA": "dahlia-av.jp",
    "レアルワークス": "real-works.jp",
    "MUTEKI": "muteki-av.com",
    "S-CUTE": "s-cute.com",
    "MAXING": "maxing.jp",
}


def _migrate_logo_exts() -> None:
    """老缓存里 `studio-*.ico` 很多其实是 PNG 字节；按真实格式改名一次。"""
    photos = os.path.join(os.environ.get("DATA_DIR", "/data"), "photos")
    try:
        names = [n for n in os.listdir(photos) if n.startswith("studio-")]
    except OSError:
        return
    fixed = 0
    for name in names:
        path = os.path.join(photos, name)
        try:
            with open(path, "rb") as fh:
                head = fh.read(512)
        except OSError:
            continue
        real = _sniff_ext(head)
        if not real or name.endswith(real):
            continue
        target = os.path.join(photos, os.path.splitext(name)[0] + real)
        try:
            if not os.path.exists(target):
                os.replace(path, target)
            else:
                os.remove(path)
            fixed += 1
        except OSError as exc:
            A.log(f"WARN facets 迁移 logo 后缀失败 {name}: {exc}")
    if fixed:
        A.log(f"facets 厂牌 logo 后缀已按真实格式修正 {fixed} 个")


def _logo_url(kind: str, fid: int) -> str:
    """制片厂的 logo 路径（只回已缓存的）。

    列表不主动联网：一次 20 个厂牌去抓 favicon 会把列表拖到十秒级。
    缓存由 `/facets/studio/{id}/logo` 在用户真正打开厂牌页时产生，
    之后列表里就直接有了。
    """
    if kind != "studio":
        return ""
    if _logo_file(fid) is None:
        return ""
    # 走扩展自己的取图路由，不走核心的 /api/user/photo/：
    # 那条路由只认 `<sha1>.(jpg|png|webp|gif)`（写真库上传用的），
    # `studio-64.ico` 这种名字它一律 404 —— 这就是「方块里有图但显示空白」的原因。
    return f"/api/user/studio-logo/{fid}"


def _logo_file(fid: int) -> str:
    """已缓存的厂牌 logo 文件路径；没有就 None。"""
    photos = os.path.join(os.environ.get("DATA_DIR", "/data"), "photos")
    for ext in (".ico", ".png", ".jpg", ".jpeg", ".webp", ".svg"):
        path = os.path.join(photos, f"studio-{fid}{ext}")
        if os.path.isfile(path):
            return path
    return None


def _logo_blob(path: str) -> tuple:
    """读厂牌 logo 并**按真实字节**判定格式，返回 `(blob, content_type)`。

    缓存里的后缀不能信：实测 19 个文件里有 3 个 .ico 其实是 JPEG，另 5 个是带
    ICO 外壳的 PNG（Vista 起 ico 允许内嵌 PNG）。客户端按 Content-Type 解码，
    格式报错就整块空白。
    BMP 型老 ico 客户端解不了，直接 404，让页面退化成「首字圆圈」——
    有内容总比一块白板强。
    """
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        return blob, "image/png"
    if blob[:3] == b"\xff\xd8\xff":
        return blob, "image/jpeg"
    if blob[:6] in (b"GIF87a", b"GIF89a"):
        return blob, "image/gif"
    if blob[:4] == b"\x00\x00\x01\x00":
        # ICO 容器：找里面内嵌的 PNG，从它开始到文件尾就是一张完整 PNG
        idx = blob.find(b"\x89PNG\r\n\x1a\n")
        if idx >= 0:
            return blob[idx:], "image/png"
        return b"", ""
    if blob.lstrip()[:5] in (b"<svg ", b"<?xml"):
        return blob, "image/svg+xml"
    return b"", ""


def _fetch_bytes(url: str, limit: int = 524288, timeout: float = 8) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(limit)


def _sniff_ext(blob: bytes) -> str:
    """按文件头判真实格式：`.ico` 地址常常返回 PNG 字节，后缀写错客户端就显示不出来。"""
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if blob[:2] == b"\xff\xd8":
        return ".jpg"
    if blob[:3] == b"GIF":
        return ".gif"
    if blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
        return ".webp"
    head = blob[:400].lstrip()
    if head[:5] == b"<?xml" or head[:4] == b"<svg":
        return ".svg"
    if blob[:4] == b"\x00\x00\x01\x00":
        return ".ico"
    return ""


def _img_size(blob: bytes) -> tuple[int, int]:
    """从文件头读宽高（不依赖 PIL）。读不出返回 (0, 0)。"""
    try:
        if blob[:8] == b"\x89PNG\r\n\x1a\n":
            return (int.from_bytes(blob[16:20], "big"), int.from_bytes(blob[20:24], "big"))
        if blob[:3] == b"GIF":
            return (int.from_bytes(blob[6:8], "little"), int.from_bytes(blob[8:10], "little"))
        if blob[:2] == b"\xff\xd8":
            i = 2
            n = len(blob)
            while i < n - 9:
                if blob[i] != 0xFF:
                    i += 1
                    continue
                marker = blob[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                              0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h = int.from_bytes(blob[i + 5:i + 7], "big")
                    w = int.from_bytes(blob[i + 7:i + 9], "big")
                    return (w, h)
                seg = int.from_bytes(blob[i + 2:i + 4], "big")
                i += 2 + seg
        if blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
            kind = blob[12:16]
            if kind == b"VP8X":
                w = 1 + int.from_bytes(blob[24:27], "little")
                h = 1 + int.from_bytes(blob[27:30], "little")
                return (w, h)
            if kind == b"VP8 ":
                w = int.from_bytes(blob[26:28], "little") & 0x3FFF
                h = int.from_bytes(blob[28:30], "little") & 0x3FFF
                return (w, h)
    except Exception:  # noqa: BLE001 - 头部畸形就当读不出
        return (0, 0)
    return (0, 0)


def _bing_images(name: str, limit: int = 8) -> list:
    """Bing 图片搜索的结果 [(图片直链, 所在页面)]。

    用 HTML 版（`murl` / `purl` 都在页面里），不需要 API key。
    """
    q = quote(f"{name} ロゴ")
    html = _fetch_bytes(f"https://www.bing.com/images/search?q={q}", 800000).decode(
        "utf-8", "replace")
    out: list = []
    for m in re.finditer(r'murl&quot;:&quot;(.*?)&quot;.*?purl&quot;:&quot;(.*?)&quot;', html):
        img, page = m.group(1), m.group(2)
        if img.startswith("http"):
            out.append((img, page))
        if len(out) >= limit:
            break
    return out


def _image_search_logo(name: str, prefer_host: str) -> tuple[bytes, str]:
    """图片搜索 + 多重印证：多张结果「长得一样」才认。

    没有 PIL，所以不去解码像素，改用两个稳的判据：
      1. 图片所在页面的域名 == 厂牌官网 → 直接可信；
      2. 否则要求**至少 3 张**结果尺寸完全相同、体积相差 <10%（同一张图被多个站转载）；
         只凑到 1–2 张就当没找到，避免挂错图。
    """
    cands: list = []
    for img_url, page_url in _bing_images(name):
        try:
            blob = _fetch_bytes(img_url, 400000, timeout=6)
        except Exception:  # noqa: BLE001 - 单张失败不影响其它
            continue
        w, h = _img_size(blob)
        if w < 64 or h < 64 or w > 1200 or h > 1200:
            continue
        if len(blob) > 300000:
            continue
        try:
            host = urlparse(page_url).netloc.lower()
        except ValueError:
            host = ""
        cands.append({"url": img_url, "host": host, "blob": blob, "w": w, "h": h})

    if not cands:
        return b"", ""
    host_ok = prefer_host.lower()
    if host_ok:
        for c in cands:
            if host_ok in c["host"]:
                return c["blob"], c["url"]
    for c in cands:
        same = [d for d in cands
                if d["w"] == c["w"] and d["h"] == c["h"]
                and abs(len(d["blob"]) - len(c["blob"])) <= max(2048, len(c["blob"]) // 10)]
        if len(same) >= 3:
            same.sort(key=lambda d: len(d["blob"]), reverse=True)
            return same[0]["blob"], same[0]["url"]
    return b"", ""


def _wiki_logo(name: str) -> tuple[bytes, str]:
    """维基百科的词条配图（很多厂牌有条目，infobox 里就有 logo）。

    比「官网 favicon」覆盖面大得多：官网常见 403/改版，维基是稳定接口。
    """
    for lang in ("ja", "en"):
        # 先按标题精确取；取不到再用搜索找最像的那条（很多厂牌在维基的词条名
        # 和库里的名字不完全一致，比如带 / 或副标题）。
        titles: list[str] = [name]
        try:
            api = ("https://%s.wikipedia.org/w/api.php?action=query&format=json"
                   "&list=search&srlimit=1&srsearch=%s" % (lang, quote(name)))
            data = json.loads(_fetch_bytes(api, 200000).decode("utf-8", "replace"))
            hits = ((data.get("query") or {}).get("search") or [])
            if hits:
                found = str(hits[0].get("title") or "").strip()
                if found and found not in titles:
                    titles.append(found)
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN facets 维基搜索失败 {lang}/{name}: {exc}")
        for title in titles:
            try:
                api = ("https://%s.wikipedia.org/w/api.php?action=query&format=json"
                       "&prop=pageimages&piprop=thumbnail&pithumbsize=400&redirects=1&titles=%s"
                       % (lang, quote(title)))
                data = json.loads(_fetch_bytes(api, 200000).decode("utf-8", "replace"))
                pages = (data.get("query") or {}).get("pages") or {}
                for page in pages.values():
                    src = ((page.get("thumbnail") or {}).get("source") or "").strip()
                    if not src:
                        src = ((page.get("original") or {}).get("source") or "").strip()
                    if not src:
                        continue
                    blob = _fetch_bytes(src)
                    if len(blob) > 64:
                        return blob, src
            except Exception as exc:  # noqa: BLE001
                A.log(f"WARN facets 维基取图失败 {lang}/{title}: {exc}")
    return b"", ""


def _site_logo(domain: str) -> bytes:
    """官网首页声明的图标：rel=icon → apple-touch-icon → og:image → /favicon.ico。"""
    html = _fetch_bytes(f"https://{domain}/", 400000).decode("utf-8", "replace")
    cand = ""
    for pat in (r'<link[^>]+rel="(?:shortcut )?icon"[^>]+href="([^"]+)"',
                r'<link[^>]+rel="apple-touch-icon"[^>]+href="([^"]+)"',
                r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"'):
        m = re.search(pat, html, re.I)
        if m:
            cand = m.group(1)
            break
    if not cand:
        cand = "/favicon.ico"
    if cand.startswith("//"):
        cand = "https:" + cand
    elif cand.startswith("/"):
        cand = f"https://{domain}" + cand
    elif not cand.startswith("http"):
        cand = f"https://{domain}/" + cand
    return _fetch_bytes(cand)


def _logo_ext(src: str) -> str:
    low = src.lower().split("?")[0]
    for ext in (".png", ".jpg", ".jpeg", ".webp", ".svg", ".ico"):
        if low.endswith(ext):
            return ".jpg" if ext == ".jpeg" else ext
    return ".png"


# 搜索引擎找到的官网域名缓存：省得每次都搜。
_SITE_CACHE_NAME = "studio-sites.json"
# 明显不是厂牌官网的站点，搜到了也要跳过。
_SKIP_HOSTS = (
    "wikipedia.org", "twitter.com", "x.com", "youtube.com", "instagram.com",
    "facebook.com", "tiktok.com", "amazon.co.jp", "dmm.co.jp", "dmm.com",
    "javdb.com", "javbus.com", "av-wiki.net", "note.com", "fc2.com",
    "seesaawiki.jp", "ameblo.jp", "blogspot.", "google.", "bing.",
)


def _site_cache() -> dict:
    path = os.path.join(os.environ.get("DATA_DIR", "/data"), _SITE_CACHE_NAME)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _site_cache_put(name: str, domain: str) -> None:
    cache = _site_cache()
    cache[name] = domain
    path = os.path.join(os.environ.get("DATA_DIR", "/data"), _SITE_CACHE_NAME)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(cache, fh, ensure_ascii=False, indent=1)
    except OSError as exc:
        A.log(f"WARN facets 写域名缓存失败: {exc}")


def _ok_host(host: str) -> bool:
    if not host:
        return False
    low = host.lower()
    if any(bad in low for bad in _SKIP_HOSTS):
        return False
    return "." in low


def _search_site(name: str) -> str:
    """用搜索引擎找这个厂牌的官网域名（Google 抓不动，用 DDG / Bing 的 HTML 结果）。

    只取「第一个看起来像厂牌自己站点」的结果，再交给 `_site_logo` 去拿图标 ——
    这样即使我们内置域名表里没有，也能落到正确站点上。
    """
    query = quote(f"{name} AV メーカー 公式サイト")
    engines = (
        ("ddg", f"https://html.duckduckgo.com/html/?q={query}"),
        ("bing", f"https://www.bing.com/search?q={query}"),
    )
    for tag, url in engines:
        try:
            html = _fetch_bytes(url, 400000).decode("utf-8", "replace")
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN facets 搜索 {tag} 失败 {name}: {exc}")
            continue
        cands: list[str] = []
        if tag == "ddg":
            for raw in re.findall(r"uddg=([^&\"]+)", html)[:8]:
                cands.append(unquote(raw))
        else:
            for raw in re.findall(r'<h2><a[^>]+href="(https?://[^"]+)"', html)[:8]:
                cands.append(raw)
        for link in cands:
            try:
                host = urlparse(link).netloc
            except ValueError:
                continue
            if _ok_host(host):
                return host
    return ""


def _studio_logo(handler, query, studio_id, *_):
    """GET /api/user/facets/studio/{id}/logo —— 厂牌 logo。

    来源按顺序试：
      1. 厂牌自己的官网（内置域名表）：rel=icon / og:image，最正；
      2. 维基百科词条配图：官网 403 或查不到域名时兜底（覆盖面大得多）；
    两步都拿不到就 404，客户端不显示 —— 宁缺勿错。
    """
    try:
        fid = int(studio_id)
    except (TypeError, ValueError):
        return handler._error(400, "非法的制片厂 id")
    name = ""
    try:
        with A.amane_db() as conn:
            table = SCALAR_SPEC.get("studio", ("studios", "studio"))[0]
            row = conn.execute(f"SELECT name FROM {table} WHERE id = ?", (fid,)).fetchone()
        if row:
            name = _text(row[0])
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 取制片厂名失败 {fid}: {exc}")
    if not name:
        return handler._error(404, "没有这个制片厂")

    photos = os.path.join(os.environ.get("DATA_DIR", "/data"), "photos")
    cached = _logo_url("studio", fid)
    if cached:
        return handler._json({"id": fid, "name": name, "url": cached})
    blob = b""
    ext = ".png"
    errors: list[str] = []

    domain = STUDIO_SITES.get(name.strip().upper(), "")
    if not domain:
        domain = _site_cache().get(name, "")
    if not domain:
        domain = _search_site(name)
        if domain:
            _site_cache_put(name, domain)
            A.log(f"facets 搜索到厂牌官网 {name} -> {domain}")
    if domain:
        try:
            blob = _site_logo(domain)
            ext = ".ico"
        except Exception as exc:  # noqa: BLE001
            errors.append(f"官网 {exc}")
            A.log(f"WARN facets 官网取图失败 {name} ({domain}): {exc}")

    if len(blob) > 300000:
        errors.append("官网图太大")
        blob = b""

    if len(blob) >= 64 and _sniff_ext(blob) == ".ico":
        # 真 ICO：手机端解码不了，宁可继续找 PNG/JPG，也不要塞个解不开的文件
        errors.append("官网只有 .ico")
        blob = b""

    if len(blob) < 64:
        # 图片搜索：多张结果互相印证（≥3 张同尺寸同体积，或页面域名就是官网）
        main_host = domain if domain else ""
        blob, src = _image_search_logo(name, main_host)
        if len(blob) >= 64:
            ext = _logo_ext(src)
            A.log(f"facets 图片搜索命中 {name} <- {src[:60]}")

    if len(blob) < 64:
        blob, src = _wiki_logo(name)
        if len(blob) >= 64:
            ext = _logo_ext(src)

    if len(blob) < 64:
        detail = "；".join(errors) if errors else "官网未收录、维基也没有配图"
        return handler._error(404, f"取不到 logo：{detail}")

    # 最终防线：太大（多半是被读取上限截断的图，或根本不是 logo）、太小都不要
    if len(blob) < 64 or len(blob) > 300000:
        return handler._error(404, "取到的图不可信（过大/过小）")

    sniffed = _sniff_ext(blob)
    if sniffed:
        ext = sniffed
    fname = f"studio-{fid}{ext}"
    try:
        os.makedirs(photos, exist_ok=True)
        with open(os.path.join(photos, fname), "wb") as fh:
            fh.write(blob)
    except OSError as exc:
        return handler._error(500, f"缓存失败：{exc}")
    handler._json({"id": fid, "name": name, "url": f"/api/user/studio-logo/{fid}"})


def studio_logo(handler, query, sid, *_):
    """GET /api/user/studio-logo/{id} —— 已缓存的厂牌 logo。

    不直接复用核心 `/api/user/photo/<name>`：那条路由的 pattern 只放行
    `<sha1>.(jpg|png|webp|gif)`，`studio-64.ico` 这种名字会 404；
    而且缓存里的后缀与真实字节经常对不上（见 `_logo_blob`）。
    """
    try:
        fid = int(sid)
    except (TypeError, ValueError):
        return handler._error(400, "id 不合法")
    path = _logo_file(fid)
    if path is None:
        return handler._error(404, "还没有这个厂牌的 logo")
    try:
        blob, ctype = _logo_blob(path)
    except OSError as exc:
        return handler._error(500, f"读图失败：{exc}")
    if not blob:
        return handler._error(404, "这个 logo 的格式手机端解不了")
    handler.send_response(200)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(blob)))
    handler.send_header("Cache-Control", "public, max-age=604800")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(blob)


def facet_rating(handler, query, kind, facet_id, *_):
    """POST /api/user/facets/{kind}/{id}/rating —— 给分类打星（0 = 清除）。

    与影片评分分开存：影片评分在上游的 metadata 上，分类评分是旁挂自己的偏好，
    落在 user.db 的 facet_rating 里（`kind + facet_id` 唯一）。
    """
    if kind not in RATING_KINDS:
        return handler._error(400, f"这类分类不支持评分: {kind}")
    body = handler._body()
    try:
        stars = int(body.get("stars") or 0)
    except (TypeError, ValueError):
        return handler._error(400, "stars 必须是 0-5 的整数")
    if stars < 0 or stars > 5:
        return handler._error(400, "stars 必须是 0-5 的整数")
    fid = int(facet_id)
    try:
        with A.user_db() as conn:
            if stars == 0:
                conn.execute("DELETE FROM facet_rating WHERE kind = ? AND facet_id = ?",
                             (kind, fid))
            else:
                conn.execute(
                    "INSERT INTO facet_rating (kind, facet_id, stars, updated_at) "
                    "VALUES (?, ?, ?, ?) ON CONFLICT(kind, facet_id) DO UPDATE SET "
                    "stars = excluded.stars, updated_at = excluded.updated_at",
                    (kind, fid, stars, A.now_iso()),
                )
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR facets 评分 {kind}/{fid} 失败: {exc}")
        return handler._error(500, f"评分失败: {exc}")
    handler._json({"kind": kind, "id": fid, "stars": stars})


def _facet_covers(kind: str) -> dict:
    """某个分类下用户换过的封面 `{名字: url}`（2.5.5.4）。

    key 用名字不用 id：用户自己新起的系列在库里没有 id。表可能不存在
    （老服务端 / 没升级），一律当「没换过」。
    """
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT \"key\", url FROM cover_override WHERE kind = ?", (kind,)).fetchall()
    except Exception:  # noqa: BLE001
        return {}
    out: dict = {}
    for r in rows:
        url = str(r["url"] or "")
        if url:
            out[str(r["key"])] = url
    return out


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
    # 我的评分必须在这里给：分类影片墙只是重取一次 media，头部的星是从这份 facet 里读的。
    # 少这个字段 → 打完星一返回就变回 0（用户报的「打了星没保存」就是这个）。
    stars = 0
    try:
        with A.user_db() as conn:
            r = conn.execute(
                "SELECT stars FROM facet_rating WHERE kind = ? AND facet_id = ?",
                (kind, fid)).fetchone()
        if r is not None:
            stars = _num(r[0])
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 读分类评分失败 {kind}/{fid}: {exc}")
    name = _text(row["name"])
    return {
        "id": _num(row["id"]),
        "name": name,
        "isFavorite": bool(row["is_favorite"]),
        "myRating": stars,
        "isHidden": fid in _hidden_ids(kind),
        "prefixes": _prefixes(kind, [fid]).get(fid, []),
        "posters": _poster_map(kind, [fid]).get(fid, []),
        "logo": _logo_url(kind, fid),
        # 用户换过的封面（系列 / 标签 / 厂牌），没换过是空串
        "cover": _facet_covers(kind).get(name, ""),
    }


def _score_from_scores(raw) -> float:
    """metadata 没有 `score` 列，评分在 `scores` 这个 JSON 里 —— 按 item_of 的口径取均值。"""
    try:
        data = json.loads(raw) if isinstance(raw, str) else (raw or {})
    except (TypeError, ValueError):
        return 0.0
    if not isinstance(data, dict):
        return 0.0
    vals: list = []
    for key in ("javdb", "r18dev", "javbus", "avg"):
        try:
            value = float(data.get(key) or 0)
        except (TypeError, ValueError):
            continue
        if value > 0:
            vals.append(value)
    return round(sum(vals) / len(vals), 2) if vals else 0.0


def _fan_poster(raw) -> str:
    """没竖版海报时拿横图顶位：宁可裁一刀，也别给一张空白卡。"""
    try:
        data = json.loads(raw) if isinstance(raw, str) else (raw or [])
    except (TypeError, ValueError):
        return ""
    if isinstance(data, dict):
        flat: list = []
        for v in data.values():
            flat.extend(v if isinstance(v, list) else [v])
        data = flat
    if not isinstance(data, list):
        return ""
    for u in data:
        if not isinstance(u, str):
            continue
        p = A.public_image(u)
        if p:
            return p
    return ""


def _media_by_name(kind: str, name: str) -> list:
    """按分类**名字**取影片：库里的 + 覆盖层里被改成这个名字的（2.5.5.4）。

    自建系列 / 标签在库里没有 id，上游的 `/api/metadata?series_id=` 查不到，
    所以这条路径直接读只读库，再把覆盖层的 metadata_id 补进来。
    """
    items: list = []
    seen: set = set()
    try:
        with A.amane_db() as conn:
            if kind == "series":
                rows = conn.execute(
                    "SELECT id, number, title, release, scores, poster_urls, thumb_urls, extrafanart_urls "
                    "FROM metadata WHERE series = ? "
                    "AND id IN (SELECT metadata_id FROM media_files) "
                    "ORDER BY release DESC, id DESC", (name,)).fetchall()
            else:
                rows = conn.execute(
                    "SELECT m.id, m.number, m.title, m.release, m.scores, "
                    "m.poster_urls, m.thumb_urls, m.extrafanart_urls FROM metadata m "
                    "JOIN metadata_tags mt ON mt.metadata_id = m.id "
                    "JOIN tags t ON t.id = mt.tag_id "
                    "WHERE t.name = ? AND m.id IN (SELECT metadata_id FROM media_files) "
                    "ORDER BY m.release DESC, m.id DESC", (name,)).fetchall()
            for r in rows:
                card = _card(dict(r, score=_score_from_scores(r['scores'])))
                if not card["poster"]:
                    card["poster"] = _fan_poster(r["extrafanart_urls"])
                if card["id"] and card["id"] not in seen:
                    seen.add(card["id"])
                    items.append(card)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets 按名字取 {kind}={name} 失败: {exc}")
        return []

    # 覆盖层：用户在手机上把这几个片改到了这个系列 / 标签下
    extra: list = []
    try:
        with A.user_db() as conn:
            ovs = conn.execute("SELECT metadata_id, fields FROM meta_override").fetchall()
    except Exception:  # noqa: BLE001
        ovs = []
    field = "series" if kind == "series" else "tags"
    for r in ovs:
        mid = _num(r["metadata_id"])
        if mid <= 0 or mid in seen:
            continue
        try:
            fields = json.loads(r["fields"] or "{}")
        except (TypeError, ValueError):
            continue
        if not isinstance(fields, dict):
            continue
        value = fields.get(field)
        names = value if isinstance(value, list) else ([value] if isinstance(value, str) else [])
        if any(str(v or "").strip() == name for v in names):
            extra.append(mid)
    if extra:
        try:
            with A.amane_db() as conn:
                marks = ",".join("?" * len(extra))
                rows = conn.execute(
                    f"SELECT id, number, title, release, scores, poster_urls, thumb_urls, extrafanart_urls "
                    f"FROM metadata WHERE id IN ({marks})", extra).fetchall()
                for r in rows:
                    card = _card(dict(r, score=_score_from_scores(r['scores'])))
                if not card["poster"]:
                    card["poster"] = _fan_poster(r["extrafanart_urls"])
                    if card["id"] and card["id"] not in seen:
                        seen.add(card["id"])
                        items.append(card)
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN facets 覆盖层补 {kind}={name} 失败: {exc}")

    items.sort(key=lambda it: (it.get("release") or "", it.get("id") or 0), reverse=True)
    return items


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
    # 自建分类（覆盖层里新起的系列 / 标签）没有 id：按名字本地取，不走上游
    want_name = _one(query, "name").strip()
    if params[KIND_PARAM[kind]] <= 0 and want_name:
        rows_all = _media_by_name(kind, want_name)
        if sort_by == "random":
            random.shuffle(rows_all)
        page = rows_all[offset:offset + limit]
        _apply_overrides(page)
        marks_map = _marks_of([it["id"] for it in page])
        for it in page:
            it["marks"] = marks_map.get(it["id"], [])
        try:
            A.call("marks_extra", page)
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN facets marks_extra: {exc}")
        return handler._json({
            "kind": kind,
            "id": 0,
            "facet": {
                "id": 0, "name": want_name, "virtual": True,
                "isFavorite": False, "myRating": 0, "isHidden": False,
                "posters": [], "prefixes": [], "logo": "",
                "cover": _facet_covers(kind).get(want_name, ""),
            },
            "items": page,
            "total": len(rows_all),
            "offset": offset,
            "limit": limit,
            "sort_by": sort_by,
        })

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
    _apply_overrides(items)
    # ratings / collections：海报角标要显示「我的评价」，这两项由扩展钩子补
    try:
        A.call("marks_extra", items)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN facets marks_extra: {exc}")
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
    """分类缩略图用的单张海报：同样要转成外网可达路径（2.5.5.24）。

    这里以前对 `/api/resources/` 直接返回原路径 —— 结果分类列表的拼贴图
    全指向内网上游，外网访问时整排空白；点进详情页才走另一条（已修）的路径。
    """
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
        "prefix": _prefix_of(_text(meta.get("number"))),
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


def facets_tags(handler, query, kind, facet_id, *_):
    """GET /api/user/facets/{kind}/{id}/tags —— 这个分类下最常出现的标签。

    用途有两个，本质是同一件事「这一堆片共同的标签有哪些」：
      * 系列页 → 提炼「系列属性」（一个系列里大多数片都有的标签，比如 NTR）；
      * 标签页 → 再叠加第二个标签做 AND 收窄（既有 NTR 又有搜查官）。
    ratio = count / 该分类影片总数，客户端据此把「≥50%」当属性、更低的当偶发。
    """
    if kind not in KIND_PARAM:
        return handler._error(400, f"不支持的分类: {kind}")
    fid = _int(facet_id, 0, 0, 10 ** 9)
    limit = _int(_one(query, "limit", "16"), 16, 1, 64)
    if kind == "tag":
        cond, params = ("m.id IN (SELECT metadata_id FROM metadata_tags WHERE tag_id = ?)", [fid])
    elif kind == "director":
        cond, params = ("m.id IN (SELECT metadata_id FROM metadata_directors WHERE director_id = ?)", [fid])
    elif kind in SCALAR_SPEC:
        table, col = SCALAR_SPEC[kind]
        cond, params = (f"m.{col} = (SELECT name FROM {table} WHERE id = ?)", [fid])
    else:
        return handler._error(400, f"不支持的分类: {kind}")
    try:
        with A.amane_db() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) FROM metadata m WHERE {cond}", params).fetchone()[0]
            # 隐藏的标签是**全局隐藏**：既不能当「系列属性」，也不能出现在叠加筛选里，
            # 所以在统计源头就剔掉，而不是等客户端过滤（客户端还有别的入口）。
            hidden = _hidden_ids("tag")
            extra = ""
            args = list(params)
            if hidden:
                extra = f" AND t.id NOT IN ({','.join('?' * len(hidden))})"
                args.extend(sorted(hidden))
            rows = conn.execute(
                "SELECT t.id, t.name, COUNT(DISTINCT mt.metadata_id) n "
                "FROM metadata m JOIN metadata_tags mt ON mt.metadata_id = m.id "
                "JOIN tags t ON t.id = mt.tag_id "
                f"WHERE {cond}{extra} GROUP BY t.id ORDER BY n DESC, t.name LIMIT ?",
                args + [limit]).fetchall()
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"取标签统计失败: {exc}")
    total = max(1, int(total))
    handler._json({
        "kind": kind,
        "id": fid,
        "total": int(total),
        "items": [
            {"id": int(r["id"]), "name": r["name"] or "",
             "count": int(r["n"]), "ratio": round(int(r["n"]) / total, 3)}
            for r in rows
        ],
    })

def series_by_tags(handler, query, *_):
    """GET /api/user/facets/series/by-tags?tags=1,2 —— 同时具备这些标签的系列。

    「这个系列大部分片都有 NTR」这种属性，本质上就是系列集合上的 AND 过滤：
    只要某系列里同时出现这些标签，就算命中（不要求每一部都有）。
    独立成端点而不是塞进 facets_list：那边有本地/上游两条取数路径，动它风险大。
    """
    raw = (_one(query, "tags") or "").strip()
    ids = [int(x) for x in raw.split(",") if x.strip().isdigit()][:8]
    if not ids:
        return handler._json({"items": [], "total": 0})
    limit = _int(_one(query, "limit", "40"), 40, 1, 80)
    n = len(ids)
    ph = ",".join("?" * n)
    sql = (
        "SELECT m.series AS name, COUNT(*) n, MIN(m.id) sample_id "
        "FROM metadata m JOIN metadata_tags mt ON mt.metadata_id = m.id "
        "WHERE m.series IS NOT NULL AND TRIM(m.series) <> '' "
        f"AND mt.tag_id IN ({ph}) "
        "GROUP BY m.series HAVING COUNT(DISTINCT mt.tag_id) = ? "
        "ORDER BY n DESC LIMIT ?"
    )
    try:
        with A.amane_db() as conn:
            rows = conn.execute(sql, ids + [n, limit]).fetchall()
            names = [r["name"] for r in rows]
            id_map = {}
            posters = {}
            if names:
                ph2 = ",".join("?" * len(names))
                for r in conn.execute(f"SELECT id, name FROM series WHERE name IN ({ph2})", names):
                    id_map[r["name"]] = int(r["id"])
                sids = [int(r["sample_id"]) for r in rows]
                ph3 = ",".join("?" * len(sids))
                for r in conn.execute(
                        f"SELECT id, poster_urls, thumb_urls FROM metadata WHERE id IN ({ph3})", sids):
                    posters[int(r["id"])] = _poster_of(r)
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"按属性筛系列失败: {exc}")
    items = [{
        "id": id_map.get(r["name"], 0),
        "name": r["name"] or "",
        "count": int(r["n"]),
        "poster": posters.get(int(r["sample_id"]), ""),
    } for r in rows]
    handler._json({"items": items, "total": len(items), "tags": ids})

def _score_num(raw) -> float:
    """metadata.scores 是刮削来的 JSON，结构可能是 [{score:...}] 也可能直接 {score:...}。"""
    try:
        obj = A.json.loads(raw) if isinstance(raw, str) else raw
        if isinstance(obj, dict):
            return float(obj.get("score") or 0)
        if isinstance(obj, list) and obj and isinstance(obj[0], dict):
            return float(obj[0].get("score") or 0)
    except (TypeError, ValueError, AttributeError):
        pass
    return 0.0


def item_siblings(handler, query, mid, *_):
    """GET /api/user/item/{id}/siblings —— 同一系列的其它片（播放页选集面板用）。

    播放页要能「顺手换一集」，所以返回的是同系列其它条目的卡片（海报 + 番号 +
    标题 + 评分 + 演员），当前这部标 `current: true` 让客户端置灰。
    系列在 metadata 上是**名字**列，series 表里才有 id，所以先按名字聚合。
    """
    mid_n = _int(mid, 0, 0, 10 ** 9)
    limit = _int(_one(query, "limit", "40"), 40, 1, 80)
    try:
        with A.amane_db() as conn:
            row = conn.execute("SELECT series FROM metadata WHERE id = ?", (mid_n,)).fetchone()
            name = _text(row["series"]).strip() if row is not None else ""
            if not name:
                return handler._json({"series_id": 0, "name": "", "items": [], "total": 0})
            sid_row = conn.execute("SELECT id FROM series WHERE name = ?", (name,)).fetchone()
            sid = int(sid_row["id"]) if sid_row is not None else 0
            rows = conn.execute(
                "SELECT m.id, m.number, m.title, m.release, m.poster_urls, m.thumb_urls, m.scores "
                "FROM metadata m WHERE m.series = ? ORDER BY m.release DESC, m.id DESC LIMIT ?",
                (name, limit)).fetchall()
            actors_map = _actors_of([int(r["id"]) for r in rows])
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"取同系列失败: {exc}")
    items = []
    for r in rows:
        d = dict(r)
        rid = _num(d.get("id"))
        items.append({
            "id": rid,
            "number": _text(d.get("number")),
            "title": _text(d.get("title")),
            "release": _text(d.get("release")),
            "poster": _poster_of(d),
            "score": round(_score_num(d.get("scores")), 1),
            "actors": actors_map.get(rid, []),
            "current": rid == mid_n,
        })
    handler._json({"series_id": sid, "name": name, "items": items, "total": len(items)})


def _actors_of(ids: list[int]) -> dict:
    """批量取每部片的演员名（前 3 个够选集面板显示）。跨表但同库，一次查完。"""
    if not ids:
        return {}
    ph = ",".join("?" * len(ids))
    out: dict = {}
    try:
        with A.amane_db() as conn:
            for r in conn.execute(
                "SELECT ma.metadata_id, a.name FROM metadata_actors ma "
                "JOIN actors a ON a.id = ma.actor_id "
                f"WHERE ma.metadata_id IN ({ph}) ORDER BY ma.metadata_id, a.name",
                ids,
            ):
                bucket = out.setdefault(int(r["metadata_id"]), [])
                if len(bucket) < 3 and r["name"]:
                    bucket.append(r["name"])
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 取选集演员失败: {exc}")
    return out


ROUTES = [
    ("GET", r"/api/user/facets/([a-z_]+)", facets_list),
    ("GET", r"/api/user/facets/([a-z_]+)/(\d+)/media", facets_media),
    ("GET", r"/api/user/facets/([a-z_]+)/(\d+)/tags", facets_tags),
    ("GET", r"/api/user/facets/series/by-tags", series_by_tags),
    ("POST", r"/api/user/facets/([a-z_]+)/(\d+)/favorite", facet_favorite),
    ("POST", r"/api/user/facets/([a-z_]+)/(\d+)/rating", facet_rating),
    ("GET", r"/api/user/facets/studio/(\d+)/logo", _studio_logo),
    ("GET", r"/api/user/studio-logo/(\d+)", studio_logo),
    ("POST", r"/api/user/facets/([a-z_]+)/(\d+)/hide", facet_hide),
    ("GET", r"/api/user/item/(\d+)/facets", item_facets),
    ("GET", r"/api/user/item/(\d+)/siblings", item_siblings),
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
    api.add_ddl(RATING_DDL)
    _migrate_logo_exts()
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("suggest_entities", suggest_entities)
    api.hook("suggest_kinds", suggest_kinds)
    # 番号前缀过滤（详情页「同番号 SPSD」标签 → browse?prefix=SPSD）
    api.hook("browse_where", on_browse_where)
    api.log(f"扩展 facets 已启用（{len(ROUTES)} 个公开端点 + 搜索联想 + 前缀筛选）")
    return {"id": "facets", "enabled": True, "scope": "public"}
