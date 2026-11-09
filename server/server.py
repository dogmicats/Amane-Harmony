#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""amane-user —— amane 的用户数据旁挂服务（收藏 / 观看历史 / 每日推荐 / 图片代理）。

为什么不是改 amane：amane 是官方镜像（ghcr.io/sqzw-x/amane），不带用户表，
也没有收藏和播放进度，插件契约只暴露「片源」和「播放源」两类，注册不了 HTTP 路由。
所以这里旁挂一个只依赖标准库的小服务：

  * 收藏、观看历史、播放进度 —— 自己的 SQLite（/data/user.db）
  * 首页聚合、每日推荐、分页浏览、搜索 —— 只读 amane 的 amane.db，一次 SQL 出数据
  * 图片代理 —— 手机只连 NAS，海报统一由 NAS 抓取并落盘缓存

播放流走本服务的 /api/user/play 代理：mpv-arkts 的 httpHeaders 会把
"Authorization" 编码成 "%65%authorization" 发出去（amane 直接 401），
而 amane 的 /api/playback 又不认 query token。所以客户端把 token 放在 URL 里，
由这里用正确的 Bearer 头回源，再把 Range 响应流式转发。局域网/外网同一条路径。

环境变量：
  AMANE_BASE        amane 地址，默认 http://127.0.0.1:8000
  AMANE_DATA        amane 的 data 目录（只读挂载），默认 /amane-data
  DATA_DIR          本服务数据目录，默认 /data
  PORT              监听端口，默认 8770
  AMANE_TOKEN       不给则读 {AMANE_DATA}/token
  IMAGE_TOKEN       不给则读 {AMANE_DATA}/image_token（图片代理鉴权用）
  PUBLIC_AMANE_URL  写进图片 URL 的对外地址（可选，不填则由客户端自己拼）
  MEDIA_PATH_MAP    amane 内路径到本服务可见路径的映射，如 /media2=/mnt/media2,/media=/mnt/media
  IMG_HOST_ALLOW_EXTRA  追加允许代理的图片主机（逗号分隔）
  IMG_REFERER       抓取外链图片时携带的 Referer（可选）
  EXTENSIONS_MANIFEST   扩展清单路径，默认 /app/extensions.json
"""

from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import os
import random
import re
import sqlite3
import sys
import threading
import time
import traceback
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, build_opener, ProxyHandler

VERSION = "2.2.0"

AMANE_BASE = os.environ.get("AMANE_BASE", "http://127.0.0.1:8000").rstrip("/")
AMANE_DATA = os.environ.get("AMANE_DATA", "/amane-data")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
PHOTO_DIR = os.environ.get("PHOTO_DIR") or os.path.join(DATA_DIR, "photos")


def save_photo(name: str, blob: bytes) -> str:
    """把上传的写真图落到 PHOTO_DIR，返回相对访问路径。"""
    if not re.fullmatch(r"[0-9a-f]{8,64}\.(?:jpg|png|webp|gif)", name):
        raise ValueError("非法的图片文件名")
    os.makedirs(PHOTO_DIR, exist_ok=True)
    path = os.path.join(PHOTO_DIR, name)
    with open(path, "wb") as fh:
        fh.write(blob)
    return f"/api/user/photo/{name}"
PORT = int(os.environ.get("PORT", "8770"))
PUBLIC_AMANE_URL = os.environ.get("PUBLIC_AMANE_URL", "").rstrip("/")

USER_DB = os.path.join(DATA_DIR, "user.db")
AMANE_DB = os.path.join(AMANE_DATA, "amane.db")
IMAGE_CACHE = os.path.join(DATA_DIR, "imgcache")


def _read_secret(name: str) -> str:
    env = os.environ.get(name)
    if env:
        return env.strip()
    path = os.path.join(AMANE_DATA, name.lower().replace("amane_", ""))
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


AMANE_TOKEN = _read_secret("AMANE_TOKEN")
IMAGE_TOKEN = _read_secret("IMAGE_TOKEN")

# 外链图片主机白名单（防 SSRF）。默认只放通用 CDN 后缀，
# 具体海报站点由部署者按自己的刮削来源追加：
#   IMG_HOST_ALLOW_EXTRA=poster-cdn.example,image-host.example
_IMG_HOST_BASE = ["githubusercontent.com", "jsdelivr.net", "images", "cdn", "img", "static"]
IMG_HOST_ALLOW = tuple(_IMG_HOST_BASE + [
    h.strip() for h in os.environ.get("IMG_HOST_ALLOW_EXTRA", "").split(",") if h.strip()
])

_opener = build_opener(ProxyHandler({}))
_log_lock = threading.Lock()


def log(msg: str) -> None:
    with _log_lock:
        sys.stdout.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        sys.stdout.flush()


# --------------------------------------------------------------------------- #
# 扩展宿主（Extension Host）
#
# 核心服务只提供通用能力：收藏 / 观看历史 / 首页聚合 / 图片代理 / 播放流代理。
# 个性化能力（例如把网盘库搬到本地库）放在 extensions/ 下，按
# /app/extensions.json 清单动态加载。scope=private 的扩展不随公版发布，
# 因此 public 部署既没有这些端点，也不包含任何个人库拓扑信息。
# --------------------------------------------------------------------------- #

EXTENSIONS_MANIFEST = os.environ.get("EXTENSIONS_MANIFEST", "/app/extensions.json")


class ExtensionHost:
    """极薄的插件壳：路由 / 建表 / 钩子三件事，扩展自己注册，核心不感知具体功能。"""

    def __init__(self) -> None:
        self.loaded: list[dict] = []
        self.ddl: list[str] = []
        self.init_fns: list = []
        self.hooks: dict[str, list] = {}

    def route(self, method: str, pattern: str):
        return route(method, pattern)  # route 在本文件后面定义，load() 运行时才引用

    def add_ddl(self, sql: str) -> None:
        self.ddl.append(sql)

    def add_init(self, fn) -> None:
        self.init_fns.append(fn)

    def hook(self, name: str, fn) -> None:
        self.hooks.setdefault(name, []).append(fn)

    def call(self, name: str, *args) -> dict:
        """跑一组钩子并合并结果；单个扩展出错不影响核心流程。"""
        merged: dict = {}
        for fn in self.hooks.get(name, []):
            try:
                out = fn(*args)
                if isinstance(out, dict):
                    merged.update(out)
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook {name}: {exc}")
        return merged

    def load(self) -> None:
        import importlib.util
        from types import SimpleNamespace
        try:
            with open(EXTENSIONS_MANIFEST, encoding="utf-8") as fh:
                manifest = json.load(fh)
        except (OSError, ValueError) as exc:
            log(f"扩展清单读不到 {EXTENSIONS_MANIFEST}: {exc}；以无扩展模式启动")
            return
        api = SimpleNamespace(
            route=self.route, add_ddl=self.add_ddl, add_init=self.add_init, hook=self.hook,
            user_db=user_db, amane_db=amane_db, log=log, now_iso=now_iso,
            os=os, json=json, datetime=datetime, timedelta=timedelta, timezone=timezone,
            # 通用上游能力：扩展不必自己读凭据文件 / 拼图片代理 URL
            amane_get=amane_get, public_image=public_image,
            # 上传类扩展要把文件落盘，统一走核心，别各写一套路径规则
            save_photo=save_photo, photo_dir=PHOTO_DIR,
        )
        base = os.path.dirname(EXTENSIONS_MANIFEST)
        for item in manifest.get("extensions", []):
            rel = item.get("entry")
            if not rel:
                continue
            path = os.path.join(base, rel)
            if not os.path.isfile(path):
                log(f"WARN 扩展 {item.get('id')} 入口不存在: {path}")
                continue
            try:
                spec = importlib.util.spec_from_file_location(f"amane_ext_{item['id']}", path)
                mod = importlib.util.module_from_spec(spec)
                sys.modules[spec.name] = mod
                spec.loader.exec_module(mod)
                self.loaded.append(mod.install(api) or {"id": item["id"]})
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 加载扩展 {item.get('id')} 失败: {exc}\n{traceback.format_exc()}")
        log(f"扩展加载完成：{[x.get('id') for x in self.loaded] or '无'}")


EXT = ExtensionHost()


# --------------------------------------------------------------------------- #
# 数据库
# --------------------------------------------------------------------------- #

@contextmanager
def user_db():
    """每次用完关闭：原来 with 只提交不关闭，久了会堆积连接和 fd。"""
    conn = sqlite3.connect(USER_DB, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def amane_db():
    """只读打开 amane 主库。

    amane 会定期 checkpoint 甚至重建 WAL，重建后旧的 -shm 映射立刻失效，
    表现为 sqlite3 报 "file is not a database"。所以：
      1. 每次新建连接（用完就关，不持有陈旧映射）；
      2. 打不开先重试一次；
      3. 还不行退回 immutable（读不到未 checkpoint 的写，但不至于 500）。
    """
    conn = None
    for attempt in range(2):
        try:
            conn = sqlite3.connect(f"file:{AMANE_DB}?mode=ro", uri=True, timeout=10)
            conn.row_factory = sqlite3.Row
            conn.execute("SELECT 1 FROM metadata LIMIT 1").fetchone()
            break
        except sqlite3.DatabaseError as exc:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
            if attempt == 1:
                log(f"amane.db 只读打开失败，退回 immutable: {exc}")
            else:
                time.sleep(0.05)
    if conn is None:
        conn = sqlite3.connect(f"file:{AMANE_DB}?mode=ro&immutable=1", uri=True, timeout=10)
        conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_user_db() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)
    with user_db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS favorites (
                metadata_id INTEGER PRIMARY KEY,
                created_at  TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS history (
                metadata_id INTEGER PRIMARY KEY,
                position    REAL NOT NULL DEFAULT 0,
                duration    REAL NOT NULL DEFAULT 0,
                played_at   TEXT NOT NULL,
                finished    INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_history_played ON history(played_at DESC);
            """
            + "\n".join(EXT.ddl)
        )
        for fn in EXT.init_fns:
            fn(conn)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------------------- #
# amane 元数据（直读 SQLite）
# --------------------------------------------------------------------------- #

META_COLUMNS = (
    "m.id, m.number, m.title, m.plot, m.actors, m.tags, m.studio, m.series, "
    "m.release, m.runtime, m.content_type, m.poster_urls, m.thumb_urls, "
    "m.extrafanart_urls, m.scores, m.updated_at"
)

# 排序键 -> (SQL 表达式, 默认方向)。评分在 scores JSON 里，只有 javdb 一个来源。
SORTS = {
    "recent": ("m.updated_at", "desc"),
    "release": ("m.release", "desc"),
    "number": ("m.number", "asc"),
    "score": ("CAST(json_extract(m.scores, '$.javdb') AS REAL)", "desc"),
    "title": ("m.title COLLATE NOCASE", "asc"),
    "runtime": ("m.runtime", "desc"),
    "random": ("RANDOM()", "desc"),
}


def _json_list(raw) -> list:
    if not raw:
        return []
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def _json_dict(raw) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _b64url(raw: str) -> str:
    """URL-safe base64，去掉填充，结果只含 A-Za-z0-9-_。

    ArkUI 的 Image 组件会对 URL 中的 % 做二次编码，导致 %2F 变成 %252F，
    服务端 urlparse 拿不到 hostname → 400 host not allowed。用 base64 绕开。
    """
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")


def _unb64url(raw: str) -> str:
    return base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8")


def _img_proxy(url: str) -> str:
    return f"/img?b={_b64url(url)}&t={IMAGE_TOKEN}"


def pick_poster(row: sqlite3.Row) -> str:
    """海报优先级：amane 本地缓存 > 外链（经本服务代理）。"""
    for url in _json_list(row["poster_urls"]) + _json_list(row["thumb_urls"]):
        if not isinstance(url, str):
            continue
        if url.startswith("/api/resources/"):
            return url
        if url.startswith("http"):
            return _img_proxy(url)
    return ""


def pick_fanart(row: sqlite3.Row) -> str:
    """横图：剧照第一张 > thumb > 海报（客户端自行模糊放大）。"""
    extra = _json_dict(row["extrafanart_urls"])
    for urls in extra.values():
        for url in _json_list(urls):
            if isinstance(url, str) and url.startswith("http"):
                return _img_proxy(url)
    for url in _json_list(row["thumb_urls"]):
        if isinstance(url, str) and url.startswith("/api/resources/"):
            return url
        if isinstance(url, str) and url.startswith("http"):
            return _img_proxy(url)
    return pick_poster(row)


def marks_of(conn: sqlite3.Connection, ids: list) -> dict:
    """一次查出这些影片的媒体标记：无码 / 破解 / 流出 / 中字。

    列表页（媒体库、收藏、首页）都要显示，所以统一在这里算，
    避免每个接口各写一遍 SQL。注意库里存的是大写枚举。
    """
    clean = [int(i) for i in ids if i]
    if not clean:
        return {}
    marks: dict[int, list[str]] = {}
    try:
        ph = ",".join("?" * len(clean))
        rows = conn.execute(
            "SELECT metadata_id, "
            "MAX(CASE WHEN UPPER(mosaic)='CRACKED' THEN 1 ELSE 0 END) c, "
            "MAX(CASE WHEN UPPER(mosaic)='LEAKED' THEN 1 ELSE 0 END) l, "
            "MAX(CASE WHEN UPPER(mosaic)='UNCENSORED' THEN 1 ELSE 0 END) u, "
            "MAX(CASE WHEN has_subtitle_in_name=1 OR has_external_subtitle=1 "
            "THEN 1 ELSE 0 END) s "
            "FROM media_files WHERE metadata_id IN (" + ph + ") GROUP BY metadata_id",
            clean,
        ).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN marks_of: {exc}")
        return {}
    for r in rows:
        labels: list[str] = []
        if r["u"]:
            labels.append("无码")
        if r["c"]:
            labels.append("破解")
        if r["l"]:
            labels.append("流出")
        if r["s"]:
            labels.append("中字")
        if labels:
            marks[r[0]] = labels
    return marks


def attach_marks(conn: sqlite3.Connection, items: list) -> list:
    """就地给列表补 marks 字段（没有标记的给空数组，前端不必判空）。"""
    got = marks_of(conn, [it.get("id") for it in items if isinstance(it, dict)])
    for it in items:
        if isinstance(it, dict):
            it["marks"] = got.get(it.get("id"), [])
    return items


def attach_marks_auto(items: list) -> list:
    """没有现成连接时用它（首页聚合、历史记录这些跨库查询点）。

    影片标记是**所有影片列表页**的必备字段：媒体库、首页、收藏、
    观看记录、标签/系列/制片厂/导演、演员作品、共演结果，一个都不能漏。
    规范见 docs/UI_RULES.md。
    """
    if not items:
        return items
    with amane_db() as conn:
        return attach_marks(conn, items)


def item_of(row: sqlite3.Row) -> dict:
    scores = _json_dict(row["scores"])
    score = 0.0
    for key in ("javdb", "r18dev", "javbus", "avg"):
        try:
            value = float(scores.get(key) or 0)
        except (TypeError, ValueError):
            value = 0.0
        if value:
            score = value
            break
    return {
        "id": row["id"],
        "number": row["number"],
        "title": row["title"] or "",
        "plot": row["plot"] or "",
        "actors": _json_list(row["actors"])[:8],
        "tags": _json_list(row["tags"])[:12],
        "studio": row["studio"] or "",
        "series": row["series"] or "",
        "release": row["release"] or "",
        "runtime": row["runtime"] or 0,
        "content_type": row["content_type"] or "",
        "score": round(score, 2),
        "poster": pick_poster(row),
        "fanart": pick_fanart(row),
        "updated_at": row["updated_at"] or "",
    }


def query_meta(conn: sqlite3.Connection, where: str, params: tuple, order: str, limit: int, offset: int = 0):
    sql = (
        f"SELECT {META_COLUMNS} FROM metadata m "
        f"JOIN (SELECT DISTINCT metadata_id FROM media_files) f ON f.metadata_id = m.id "
    )
    if where:
        sql += f"WHERE {where} "
    sql += f"ORDER BY {order} LIMIT ? OFFSET ?"
    rows = conn.execute(sql, (*params, max(1, min(limit, 200)), max(0, offset))).fetchall()
    return [item_of(r) for r in rows]


def count_meta(conn: sqlite3.Connection, where: str, params: tuple) -> int:
    sql = (
        "SELECT COUNT(*) FROM metadata m JOIN "
        "(SELECT DISTINCT metadata_id FROM media_files) f ON f.metadata_id = m.id "
    )
    if where:
        sql += f"WHERE {where} "
    return int(conn.execute(sql, params).fetchone()[0])


def fetch_by_ids(ids: list[int]) -> list[dict]:
    if not ids:
        return []
    marks = ",".join("?" * len(ids))
    with amane_db() as conn:
        rows = conn.execute(f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id IN ({marks})", ids).fetchall()
    by_id = {r["id"]: item_of(r) for r in rows}
    out = [by_id[i] for i in ids if i in by_id]
    # 观看记录等页面直接吃这里的字段，标记必须一起给
    return attach_marks_auto(out)


def attach_progress(items: list[dict]) -> list[dict]:
    """给列表补上播放进度，客户端据此画进度条。"""
    if not items:
        return items
    ids = [it["id"] for it in items]
    marks = ",".join("?" * len(ids))
    with user_db() as conn:
        rows = conn.execute(
            f"SELECT metadata_id, position, duration FROM history WHERE metadata_id IN ({marks})", ids
        ).fetchall()
    prog = {r["metadata_id"]: (r["position"], r["duration"]) for r in rows}
    for it in items:
        pos, dur = prog.get(it["id"], (0.0, 0.0))
        it["position"] = round(pos, 1)
        it["duration"] = round(dur, 1)
    return items


# --------------------------------------------------------------------------- #
# 首页聚合
# --------------------------------------------------------------------------- #

_home_cache: dict[str, tuple[float, dict]] = {}
HOME_TTL = 300.0


def libraries() -> list[dict]:
    with amane_db() as conn:
        rows = conn.execute(
            "SELECT l.id, l.name, COUNT(DISTINCT f.metadata_id) AS n "
            "FROM libraries l LEFT JOIN media_files f ON f.library_id = l.id "
            "GROUP BY l.id ORDER BY l.id"
        ).fetchall()
    return [{"id": r["id"], "name": r["name"], "count": r["n"]} for r in rows if r["n"]]


def build_home() -> dict:
    libs = libraries()
    rows_out: list[dict] = []
    with amane_db() as conn:
        for lib in libs:
            items = query_meta(conn, "f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)",
                               (lib["id"],), "m.updated_at DESC", 18)
            if items and lib["count"] >= 4:
                rows_out.append({"kind": "library", "id": f"lib-{lib['id']}", "title": lib["name"],
                                 "library_id": lib["id"], "count": lib["count"],
                                 "items": attach_marks(conn, attach_progress(items))})

    recommend = build_recommend(20)
    hero = [x for x in recommend if x["fanart"]][:6] or recommend[:4]

    return {
        "hero": hero,
        "continue": build_continue(),
        "rows": rows_out,
        "recommend": recommend,
        "libraries": libs,
        "generated_at": now_iso(),
    }


def build_continue() -> list[dict]:
    """继续观看不缓存：刚看完一集回到首页应当立刻反映出来。"""
    with user_db() as conn:
        hist = conn.execute(
            "SELECT metadata_id, position, duration, played_at FROM history "
            "WHERE finished = 0 AND position > 30 ORDER BY played_at DESC LIMIT 12"
        ).fetchall()
    progress = {r["metadata_id"]: (r["position"], r["duration"]) for r in hist}
    out = []
    for item in fetch_by_ids([r["metadata_id"] for r in hist]):
        pos, dur = progress.get(item["id"], (0, 0))
        row = dict(item)
        row["position"] = round(pos, 1)
        row["duration"] = round(dur, 1)
        out.append(row)
    return out


def build_recommend(limit: int = 20) -> list[dict]:
    libs = [lib for lib in libraries() if lib["count"] >= 30]
    if not libs:
        with amane_db() as conn:
            return attach_marks(conn, attach_progress(query_meta(conn, "", (), "m.updated_at DESC", limit)))
    pool: list[dict] = []
    with amane_db() as conn:
        for lib in libs:
            items = query_meta(
                conn,
                "f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)",
                (lib["id"],),
                "RANDOM()",
                40,
            )
            pool.extend(items)
    seen: set[int] = set()
    uniq = []
    for item in pool:
        if item["id"] in seen or not item["poster"]:
            continue
        seen.add(item["id"])
        uniq.append(item)
    rng = random.Random(date.today().isoformat())
    rng.shuffle(uniq)
    return attach_marks_auto(attach_progress(uniq[:limit]))


def cached_home() -> dict:
    """库行 / 推荐 / hero 缓存 5 分钟；继续观看每次现算。"""
    key = date.today().isoformat()
    hit = _home_cache.get(key)
    now = time.time()
    if hit and now - hit[0] < HOME_TTL:
        base = dict(hit[1])
    else:
        data = build_home()
        base = {k: v for k, v in data.items() if k != "continue"}
        _home_cache.clear()
        _home_cache[key] = (now, base)
        base = dict(base)
    base["continue"] = build_continue()
    base["generated_at"] = now_iso()
    return base


# --------------------------------------------------------------------------- #
# 图片代理
# --------------------------------------------------------------------------- #

_host_ok_cache: dict[str, bool] = {}


def host_allowed(url: str) -> bool:
    try:
        host = (urlparse(url).hostname or "").lower()
    except ValueError:
        return False
    if not host:
        return False
    if host in _host_ok_cache:
        return _host_ok_cache[host]
    ok = any(host == h or host.endswith("." + h) or h in host for h in IMG_HOST_ALLOW)
    _host_ok_cache[host] = ok
    return ok


# --------------------------------------------------------------------------- #
# 扩展可复用的通用能力
#
# 核心只提供「怎么安全地去上游取数、怎么把外链图片变成客户端能加载的 URL」，
# 不认识任何具体扩展。扩展由 ExtensionHost.load() 注入这两个函数，
# 因此不必自己读 /amane-data/token，也不会和核心的白名单判断产生分叉。
# --------------------------------------------------------------------------- #

def amane_get(path: str, params: dict | None = None, timeout: int = 12) -> dict:
    """带 Bearer 向 amane 上游请求 JSON；供需要代理上游数据的扩展复用。"""
    from urllib.parse import urlencode
    url = AMANE_BASE + path
    if params:
        clean = {k: v for k, v in params.items() if v is not None and v != ""}
        url += "?" + urlencode(clean, doseq=True)
    req = Request(url, headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
    with _opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def public_image(url: str) -> str:
    """外链图片 → /img?b=<base64url>&t=...；非白名单 host 直接丢弃。

    ArkUI 的 Image 会对 URL 里的 % 做二次编码，所以外链一律不能原样下发，
    由这里统一转成核心图片代理可识别的形式。
    """
    if not isinstance(url, str) or not url.startswith("http"):
        return ""
    if not host_allowed(url):
        return ""
    return _img_proxy(url)


def serve_image(url: str) -> tuple[bytes, str]:
    os.makedirs(IMAGE_CACHE, exist_ok=True)
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()
    for ext in (".jpg", ".png", ".webp", ".gif"):
        path = os.path.join(IMAGE_CACHE, digest + ext)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            ctype = mimetypes.guess_type(path)[0] or "image/jpeg"
            with open(path, "rb") as fh:
                return fh.read(), ctype
    if not host_allowed(url):
        log(f"图片域名不在白名单: {urlparse(url).hostname} | {url[:140]}")
        raise ValueError("host not allowed")
    req = Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/122 Safari/537.36",
        "Referer": os.environ.get("IMG_REFERER", ""),
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
    })
    with _opener.open(req, timeout=20) as resp:
        data = resp.read(8 * 1024 * 1024)
        ctype = resp.headers.get("Content-Type", "image/jpeg").split(";")[0]
    if not data:
        raise ValueError("empty image")
    ext = ".jpg"
    if "png" in ctype:
        ext = ".png"
    elif "webp" in ctype:
        ext = ".webp"
    elif "gif" in ctype:
        ext = ".gif"
    with open(os.path.join(IMAGE_CACHE, digest + ext), "wb") as fh:
        fh.write(data)
    return data, ctype


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

ROUTES = []


def route(method: str, pattern: str):
    regex = re.compile("^" + pattern + "$")

    def deco(fn):
        ROUTES.append((method, regex, fn))
        return fn

    return deco


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"amane-user/{VERSION}"

    # -- 基础设施 ---------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if os.environ.get("VERBOSE"):
            log(f"{self.address_string()} {fmt % args}")

    def _json(self, payload: dict | list, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, detail: str) -> None:
        self._json({"detail": detail}, status)

    def _authed(self, query: dict) -> bool:
        if not AMANE_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {AMANE_TOKEN}":
            return True
        return (query.get("token") or [""])[0] == AMANE_TOKEN

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0 or length > 16 * 1024 * 1024:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    # -- 分发 -------------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_HEAD(self) -> None:  # noqa: N802
        # mpv 会用 HEAD 探测长度/类型，只回头部不读流
        self._dispatch("HEAD")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        try:
            if parsed.path == "/img":
                return self._image(query)
            if parsed.path == "/api/user/ping":
                return self._json({"ok": True, "version": VERSION, "time": now_iso()})
            if not self._authed(query):
                return self._error(401, "缺少或无效的 token")
            for m, regex, fn in ROUTES:
                if m != method:
                    continue
                match = regex.match(parsed.path)
                if match:
                    return fn(self, query, *match.groups())
            return self._error(404, "not found")
        except BrokenPipeError:
            return
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR {method} {self.path}: {exc}\n{traceback.format_exc()}")
            return self._error(500, str(exc))

    # -- 图片 -------------------------------------------------------------

    def _image(self, query: dict) -> None:
        url = (query.get("u") or [""])[0]
        encoded = (query.get("b") or [""])[0]
        token = (query.get("t") or [""])[0]
        if IMAGE_TOKEN and token != IMAGE_TOKEN and not self._authed(query):
            return self._error(401, "图片 token 无效")
        if encoded:
            try:
                url = _unb64url(encoded)
            except (ValueError, UnicodeDecodeError):
                return self._error(400, "b 解码失败")
        if not url:
            return self._error(400, "缺少 u")
        if not (url.startswith("http://") or url.startswith("https://")):
            return self._error(400, "只代理 http(s) 图片")
        try:
            data, ctype = serve_image(url)
        except ValueError as exc:
            return self._error(400, str(exc))
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            return self._error(502, f"抓取失败: {exc}")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        self.wfile.write(data)

    # -- 播放流代理 -------------------------------------------------------
    #
    # 为什么不直连 amane：@mpv-ohos/mpv-arkts 1.0.0 的 httpHeaders 实现有 bug，
    # 会把 "Authorization" 编成 "%65%authorization"（Caddy access.log 实锤），
    # amane 一律 401；而 /api/playback 又不像 /api/resources 那样认 ?token=。
    # 于是客户端只把 token 放进 URL（mpv 对 query 没有任何加工），由这里补正确的
    # Bearer 头回源，Range / 206 / Content-Range 原样透传。
    # 纯标准库流式转发，不在内存里攒整个文件；ThreadingHTTPServer 每路一个线程。

    PLAY_HOP_HEADERS = (
        "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
        "ETag", "Last-Modified", "Cache-Control",
    )

    @route("GET", r"/api/user/photo/([0-9a-f]{8,64}\.(?:jpg|png|webp|gif))")
    @route("HEAD", r"/api/user/photo/([0-9a-f]{8,64}\.(?:jpg|png|webp|gif))")
    def photo(self, query: dict, name: str) -> None:
        """写真库上传的本地图片（自家文件，不走图片白名单）。"""
        path = os.path.join(PHOTO_DIR, name)
        if not os.path.isfile(path):
            return self._error(404, "图片不存在")
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError as exc:
            return self._error(500, str(exc))
        ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(blob)

    @route("GET", r"/api/user/streams/([^/]+)/(\d+)")
    def streams(self, query: dict, source: str, mid: str) -> None:
        """列出该条目在这个播放源上的所有流，并补上本地文件信息。

        一个元数据下挂多个版本（不同分辨率、正片/分段、网盘与本地各一份）是常态。
        amane 的流 key 形如 `f<media_file_id>`，用它回查 media_files 就能给出
        「文件名 / 分辨率 / 体积 / 时长 / 字幕 / 所在库」，客户端据此让用户选版本。
        `available` 是**浏览器口径**（WMV 之类会被标 false），但客户端用 mpv，
        所以不可用项照样返回、只排在后面，由用户自己决定。
        """
        source = source[:64]
        try:
            data = amane_get(f"/api/playback/{source}/{int(mid)}/streams")
        except Exception as exc:  # noqa: BLE001
            return self._error(502, f"上游播放源不可用: {exc}")
        items = [x for x in (data.get("items") or []) if isinstance(x, dict)]

        ids: list[int] = []
        for it in items:
            key = str(it.get("key") or "")
            if key[:1] == "f" and key[1:].isdigit():
                ids.append(int(key[1:]))
        info: dict[int, sqlite3.Row] = {}
        libs: dict[int, str] = {}
        if ids:
            ph = ",".join("?" * len(ids))
            with amane_db() as conn:
                for r in conn.execute(
                    "SELECT id, path, size, duration, definition, library_id, "
                    "has_subtitle_in_name, has_external_subtitle FROM media_files "
                    f"WHERE id IN ({ph})",
                    ids,
                ):
                    info[r["id"]] = r
                for r in conn.execute("SELECT id, name FROM libraries"):
                    libs[r["id"]] = r["name"] or ""

        out: list[dict] = []
        for it in items:
            key = str(it.get("key") or "")
            fid = int(key[1:]) if key[:1] == "f" and key[1:].isdigit() else 0
            row = info.get(fid)
            name = str(it.get("name") or "")
            # 上游 name 形如「本机文件 · XXX.mkv」，去掉前缀只留文件名
            base = name.split(" · ")[-1].split("/")[-1] or name
            try:
                size = int(row["size"] or 0) if row is not None else 0
            except (TypeError, ValueError):
                size = 0
            try:
                duration = round(float(row["duration"] or 0), 1) if row is not None else 0
            except (TypeError, ValueError):
                duration = 0
            out.append({
                "key": key,
                "file_id": fid,
                "name": base,
                "size": size,
                "duration": duration,
                "definition": (row["definition"] or "") if row is not None else "",
                "has_subtitle": bool(
                    row is not None and (row["has_subtitle_in_name"] or row["has_external_subtitle"])
                ),
                "library": libs.get(row["library_id"], "") if row is not None else "",
                "content_type": str(it.get("content_type") or ""),
                "available": bool(it.get("available")),
                "detail": str(it.get("detail") or ""),
            })
        out.sort(key=lambda x: (0 if x["available"] else 1, -x["size"]))
        self._json({"items": out, "source": source, "metadata_id": int(mid)})

    @route("GET", r"/api/user/play/([^/]+)/(\d+)")
    @route("HEAD", r"/api/user/play/([^/]+)/(\d+)")
    def play(self, query: dict, source: str, mid: str) -> None:
        head_only: bool = self.command == "HEAD"
        # ?key=f<文件id> 指定版本；不带 key 时仍交给上游自己挑一条
        key = (query.get("key") or [""])[0]
        suffix = ""
        if re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", key):
            suffix = f"/streams/{key}"
        upstream: str = f"{AMANE_BASE}/api/playback/{source}/{mid}{suffix}"
        req_headers: dict[str, str] = {"Authorization": f"Bearer {AMANE_TOKEN}"}
        for key in ("Range", "If-Range", "If-Modified-Since", "If-None-Match"):
            val = self.headers.get(key)
            if val:
                req_headers[key] = val

        log(f"play {source}/{mid}{suffix} range={self.headers.get('Range', '-')}")
        resp = None
        try:
            resp = _opener.open(Request(upstream, headers=req_headers), timeout=180)
            self.send_response(resp.status)
            for key in self.PLAY_HOP_HEADERS:
                val = resp.headers.get(key)
                if val:
                    self.send_header(key, val)
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if head_only or resp.status not in (200, 206):
                return
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except HTTPError as exc:
            # 上游 4xx/5xx：把状态码和响应体透传，别让客户端误以为流已建立
            try:
                body = exc.read()
                self.send_response(exc.code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            self.close_connection = True
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as exc:
            # 客户端 seek / 退出播放，正常收尾，不打错误日志
            log(f"play {source}/{mid} client disconnected: {type(exc).__name__}")
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            log(f"play {upstream} failed: {exc}\n{traceback.format_exc()}")
            self.close_connection = True
        finally:
            if resp is not None:
                try:
                    resp.close()
                except Exception:  # noqa: BLE001
                    pass

    # -- 首页 / 浏览 -------------------------------------------------------

    @route("GET", r"/api/user/home")
    def home(self, query, *_) -> None:
        self._json(cached_home())

    @route("GET", r"/api/user/config")
    def client_config(self, query, *_) -> None:
        """客户端启动时拿一次：图片 token、播放源 id、库列表。"""
        source = "nas.local"
        try:
            req = Request(f"{AMANE_BASE}/api/playback/sources",
                          headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
            with _opener.open(req, timeout=8) as resp:
                data = json.load(resp)
            items = data.get("items") or []
            if items:
                source = items[0].get("source_id") or source
        except Exception as exc:  # noqa: BLE001
            log(f"读播放源失败，回退 {source}: {exc}")
        self._json({
            "version": VERSION,
            "image_token": IMAGE_TOKEN,
            "playback_source": source,
            "libraries": libraries(),
            "public_amane_url": PUBLIC_AMANE_URL,
            "generated_at": now_iso(),
        })

    @route("GET", r"/api/user/recommend")
    def recommend(self, query, *_) -> None:
        limit = int((query.get("limit") or ["20"])[0])
        self._json({"items": build_recommend(limit)})

    @route("GET", r"/api/user/libraries")
    def libs(self, query, *_) -> None:
        self._json({"items": libraries()})

    @route("GET", r"/api/user/browse")
    def browse(self, query, *_) -> None:
        def arg(name: str, default: str = "") -> str:
            return (query.get(name) or [default])[0].strip()

        try:
            limit = min(120, max(1, int(arg("limit", "40"))))
            offset = max(0, int(arg("offset", "0")))
        except ValueError:
            return self._error(400, "limit/offset 必须是整数")

        lib_id = arg("library_id")
        search = arg("q")

        sort = arg("sort", "recent").lower()
        if sort not in SORTS:
            sort = "recent"
        column, default_dir = SORTS[sort]
        direction = arg("order", default_dir).lower()
        if direction not in ("asc", "desc"):
            direction = default_dir
        if sort == "random":
            order = "RANDOM()"
        else:
            # 次级键保证分页稳定（同分/同日期不会在翻页时重复或漏项）
            order = f"{column} {direction.upper()}, m.id DESC"

        where: list[str] = []
        params: tuple = ()

        if lib_id:
            try:
                where.append("f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)")
                params = (*params, int(lib_id))
            except ValueError:
                return self._error(400, "library_id 必须是整数")

        if search:
            # 模糊搜索：按空格 / 连字符拆词，每个词都要命中（AND）。
            # number 额外去掉连字符再比一次，这样 "ipzz932" 能搜到 "IPZZ-932"，
            # "ipzz 932" 拆成两个词也照样命中。
            tokens = [x for x in re.split(r"[\s\-_/]+", search) if x][:6]
            for tok in tokens:
                where.append(
                    "(m.number LIKE ? OR REPLACE(m.number, '-', '') LIKE ? "
                    "OR m.title LIKE ? OR m.actors LIKE ? OR m.series LIKE ?)")
                like = f"%{tok}%"
                params = (*params, like, like, like, like, like)

        # 马赛克：CRACKED / LEAKED / NONE（原版无标记）
        mosaic = arg("mosaic").upper()
        if mosaic:
            wanted = [v for v in mosaic.split(",") if v in ("CRACKED", "LEAKED", "NONE")]
            if wanted:
                parts: list[str] = []
                for value in wanted:
                    if value == "NONE":
                        parts.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                     "AND x.mosaic IS NOT NULL AND x.mosaic != '')")
                    else:
                        parts.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                     "AND x.mosaic = ?)")
                        params = (*params, value)
                where.append("(" + " OR ".join(parts) + ")")

        ctype = arg("ctype").upper()
        if ctype:
            values = [v for v in ctype.split(",") if v]
            if values:
                marks = ",".join("?" * len(values))
                where.append(f"UPPER(m.content_type) IN ({marks})")
                params = (*params, *values)

        # 字幕：1 有（内嵌或外挂），0 无
        sub = arg("sub")
        if sub == "1":
            where.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                         "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")
        elif sub == "0":
            where.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                         "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")

        year_from = arg("year_from")
        year_to = arg("year_to")
        if year_from.isdigit():
            where.append("substr(m.release, 1, 4) >= ?")
            params = (*params, year_from)
        if year_to.isdigit():
            where.append("substr(m.release, 1, 4) <= ?")
            params = (*params, year_to)

        min_score = arg("min_score")
        if min_score:
            try:
                where.append("CAST(json_extract(m.scores, '$.javdb') AS REAL) >= ?")
                params = (*params, float(min_score))
            except ValueError:
                pass

        clause = " AND ".join(where)
        with amane_db() as conn:
            items = query_meta(conn, clause, params, order, limit, offset)
            attach_marks(conn, items)
            total = count_meta(conn, clause, params)
        self._json({
            "items": attach_progress(items),
            "total": total,
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": direction,
        })

    @route("GET", r"/api/user/item/(\d+)")
    def item(self, query, metadata_id, *_) -> None:
        with amane_db() as conn:
            rows = conn.execute(f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (int(metadata_id),)).fetchall()
            if not rows:
                return self._error(404, "条目不存在")
            data = item_of(rows[0])
            extra = _json_dict(rows[0]["extrafanart_urls"])
            stills: list[str] = []
            for urls in extra.values():
                for url in _json_list(urls):
                    if isinstance(url, str) and url.startswith("http") and len(stills) < 12:
                        stills.append(_img_proxy(url))
            data["stills"] = stills
            files = conn.execute(
                "SELECT id, path, size, duration, definition, mosaic, has_subtitle_in_name, "
                "has_external_subtitle, library_id FROM media_files WHERE metadata_id = ? ORDER BY id",
                (int(metadata_id),),
            ).fetchall()
        data["files"] = [dict(f) for f in files]
        # 详情页标记也在服务端算：客户端不必再从 files 里各拼一遍，
        # 一个数据源 = 所有详情页天然一致（见 docs/UI_RULES.md）。
        labels: list[str] = []
        mosaics = {str((f["mosaic"] or "")).upper() for f in files}
        if "UNCENSORED" in mosaics:
            labels.append("无码")
        if "CRACKED" in mosaics:
            labels.append("破解")
        if "LEAKED" in mosaics:
            labels.append("流出")
        if any(f["has_subtitle_in_name"] or f["has_external_subtitle"] for f in files):
            labels.append("中字")
        data["marks"] = labels
        with amane_db() as conn:
            # amane 的「评价」：网友推荐 / 讨论帖引用，早于 updated_at 的是原帖
            rows = conn.execute(
                "SELECT id, body, created_at, updated_at FROM comments "
                "WHERE metadata_id = ? ORDER BY created_at DESC LIMIT 40",
                (int(metadata_id),),
            ).fetchall()
        data["comments"] = [
            {
                "id": r["id"],
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
            }
            for r in rows
        ]
        with user_db() as conn:
            fav = conn.execute("SELECT 1 FROM favorites WHERE metadata_id = ?", (int(metadata_id),)).fetchone()
            hist = conn.execute(
                "SELECT position, duration, finished FROM history WHERE metadata_id = ?", (int(metadata_id),)
            ).fetchone()
        data["favorite"] = bool(fav)
        data["position"] = round(hist["position"], 1) if hist else 0
        data["duration"] = round(hist["duration"], 1) if hist else 0
        data["finished"] = bool(hist["finished"]) if hist else False
        data.update(EXT.call("item_extra", int(metadata_id)))
        self._json(data)

    @route("GET", r"/api/user/extensions")
    def extensions(self, query, *_) -> None:
        """客户端据此决定要不要显示私有扩展的 UI。"""
        self._json({"items": EXT.loaded, "version": VERSION})

    @route("POST", r"/api/user/crash")
    def crash_report(self, query, *_) -> None:
        body = self._body()
        text = str(body.get("text") or "")[:20000]
        if text:
            try:
                os.makedirs(DATA_DIR, exist_ok=True)
                with open(os.path.join(DATA_DIR, "crash-reports.log"), "a", encoding="utf-8") as fh:
                    fh.write(f"\n===== {now_iso()} =====\n{text}\n")
            except OSError as exc:
                return self._error(500, str(exc))
        self._json({"ok": True, "bytes": len(text)})

    # -- 收藏 -------------------------------------------------------------

    @route("GET", r"/api/user/favorites")
    def favorites(self, query, *_) -> None:
        limit = int((query.get("limit") or ["60"])[0])
        offset = int((query.get("offset") or ["0"])[0])
        with user_db() as conn:
            ids = [r["metadata_id"] for r in conn.execute(
                "SELECT metadata_id FROM favorites ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (max(1, min(limit, 200)), max(0, offset)),
            )]
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        items = fetch_by_ids(ids)
        with amane_db() as conn:
            attach_marks(conn, items)
        self._json({"items": items, "total": total})

    @route("GET", r"/api/user/favorites/ids")
    def favorite_ids(self, query, *_) -> None:
        with user_db() as conn:
            ids = [r["metadata_id"] for r in conn.execute("SELECT metadata_id FROM favorites")]
        self._json({"ids": ids})

    @route("PUT", r"/api/user/favorites/(\d+)")
    def favorite_add(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        with user_db() as conn:
            conn.execute(
                "INSERT INTO favorites(metadata_id, created_at) VALUES(?, ?) "
                "ON CONFLICT(metadata_id) DO NOTHING",
                (mid, now_iso()),
            )
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        extra = EXT.call("favorite_add", mid)
        self._json({"ok": True, "favorite": True, "total": total, **extra})

    @route("DELETE", r"/api/user/favorites/(\d+)")
    def favorite_del(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        with user_db() as conn:
            conn.execute("DELETE FROM favorites WHERE metadata_id = ?", (mid,))
            total = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
        extra = EXT.call("favorite_del", mid)
        self._json({"ok": True, "favorite": False, "total": total, **extra})

    # -- 历史 -------------------------------------------------------------

    @route("GET", r"/api/user/history")
    def history(self, query, *_) -> None:
        limit = int((query.get("limit") or ["60"])[0])
        offset = int((query.get("offset") or ["0"])[0])
        only_unfinished = (query.get("unfinished") or [""])[0] in ("1", "true")
        clause = "WHERE finished = 0" if only_unfinished else ""
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, position, duration, played_at, finished FROM history {clause} "
                "ORDER BY played_at DESC LIMIT ? OFFSET ?",
                (max(1, min(limit, 200)), max(0, offset)),
            ).fetchall()
            total = conn.execute(f"SELECT COUNT(*) FROM history {clause}").fetchone()[0]
        meta = {m["id"]: m for m in fetch_by_ids([r["metadata_id"] for r in rows])}
        items = []
        for r in rows:
            base = meta.get(r["metadata_id"])
            if not base:
                continue
            item = dict(base)
            item["position"] = round(r["position"], 1)
            item["duration"] = round(r["duration"], 1)
            item["played_at"] = r["played_at"]
            item["finished"] = bool(r["finished"])
            items.append(item)
        self._json({"items": items, "total": total})

    @route("POST", r"/api/user/history")
    def history_upsert(self, query, *_) -> None:
        body = self._body()
        try:
            mid = int(body.get("metadata_id"))
        except (TypeError, ValueError):
            return self._error(422, "metadata_id 必填")
        position = max(0.0, float(body.get("position") or 0))
        duration = max(0.0, float(body.get("duration") or 0))
        finished = 1 if (body.get("finished") or (duration and position >= duration * 0.92)) else 0
        if not finished and position < 5:
            return self._json({"ok": True, "skipped": True})
        with user_db() as conn:
            conn.execute(
                "INSERT INTO history(metadata_id, position, duration, played_at, finished) VALUES(?,?,?,?,?) "
                "ON CONFLICT(metadata_id) DO UPDATE SET position=excluded.position, "
                "duration=excluded.duration, played_at=excluded.played_at, finished=excluded.finished",
                (mid, position, duration, now_iso(), finished),
            )
            row = conn.execute(
                "SELECT position, duration, finished FROM history WHERE metadata_id = ?", (mid,)
            ).fetchone()
        self._json({"ok": True, "position": row["position"], "duration": row["duration"],
                    "finished": bool(row["finished"])})

    @route("DELETE", r"/api/user/history/(\d+)")
    def history_del(self, query, metadata_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM history WHERE metadata_id = ?", (int(metadata_id),))
        self._json({"ok": True})

    @route("GET", r"/api/user/stats")
    def stats(self, query, *_) -> None:
        with user_db() as conn:
            fav = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
            hist = conn.execute("SELECT COUNT(*) FROM history").fetchone()[0]
            done = conn.execute("SELECT COUNT(*) FROM history WHERE finished = 1").fetchone()[0]
        with amane_db() as conn:
            total = conn.execute("SELECT COUNT(DISTINCT metadata_id) FROM media_files").fetchone()[0]
        self._json({"favorites": fav, "history": hist, "finished": done, "library_items": total})


def main() -> None:
    EXT.load()
    init_user_db()
    os.makedirs(IMAGE_CACHE, exist_ok=True)
    log(f"amane-user {VERSION} on :{PORT}  amane={AMANE_BASE}  db={USER_DB}")
    if not AMANE_TOKEN:
        log("WARN 没读到 amane token，接口将不校验鉴权")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
