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
  AMANE_PLAY_CACHE_MB  播放块缓存上限（MB），默认 320
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
import select
import socket
import sqlite3
import sys
import threading
import time
import traceback
import unicodedata
from collections import OrderedDict
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, build_opener, ProxyHandler

VERSION = "2.5.0"

# 「看完」的唯一口径：客户端 PlayerPage.saveProgress 与服务端兜底都用它。
# 两处各写一个数（曾经 0.95 / 0.92）会出现「客户端显示看完、服务端没标完」的错位。
FINISH_RATIO = 0.95

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
# 关键词相关性：清单页搜索框统一口径（2.4.6.21）
#
# 各清单（影片库 / 演员 / 标签·系列·导演 / 收藏）除了「指定筛选」，还要能直接打
# 关键词搜。只做 LIKE 有两个问题：一是全角/大小写/连字符不同就搜不到，二是命中
# 之后没有「像不像」的顺序 —— 搜「三上」时「三上悠亜」和「三上理子」谁在前全看
# 作品数。所以这里给出一套归一化 + 分档打分：
#
#   0 完全相等      normalize 之后一模一样（SPSD-014 = spsd014）
#   1 前缀          名字以关键词开头
#   2 词首          多词名字里任一词以关键词开头（Yui Hatano ← hatano）
#   3 包含          名字里带这段
#   4 子序列        字符按序出现即可（大桥未久 ← 大桥久），只对短查询开放
#   None 不命中
#
# 为什么做成 SQLite 函数：过滤（IS NOT NULL）和排序（升序）都得在 SQL 里一次
# 完成，否则「先取一页再排」会让分页算不准；这几张表都只有几千~几万行，全表过
# 一次 Python 回调在可接受范围内。
# --------------------------------------------------------------------------- #
_SEP_RE = re.compile(
    r"[\s\-_·・./\\|,，、;；:：()（）\[\]【】「」『』!！?？'\"“”‘’+~@#&*]+")


def _norm_kw(text) -> str:
    """全角转半角 + 小写 + 去掉分隔符：`ＳＰＳＤ_014` / `spsd-014` 都归一成 `spsd014`。"""
    if not text:
        return ""
    s = unicodedata.normalize("NFKC", str(text)).lower()
    return _SEP_RE.sub("", s)


def _subseq(needle: str, hay: str) -> bool:
    """needle 的字符按顺序全部出现在 hay 里（不要求连续）。"""
    if not needle:
        return False
    it = iter(hay)
    return all(ch in it for ch in needle)


def rel_score(text, kw) -> int | None:
    """相关性档位：越小越靠前，None = 不命中。给 SQLite 用的标量函数。"""
    name = _norm_kw(text)
    key = _norm_kw(kw)
    if not key or not name:
        return None
    if name == key:
        return 0
    if name.startswith(key):
        return 1
    # 词首：日/英混排的名字常用分隔符（Yui Hatano、つぼみ・蕾），任一词开头都算
    raw = unicodedata.normalize("NFKC", str(text)).lower()
    for word in _SEP_RE.split(raw):
        if word and _norm_kw(word).startswith(key):
            return 2
    if key in name:
        return 3
    # 兜底模糊只对短查询开放：长关键词做子序列几乎必然误命中一长串无关名字
    if 2 <= len(key) <= 6 and len(name) - len(key) <= 6 and _subseq(key, name):
        return 4
    return None


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

    def call_hook(self, name: str, *args):
        """求值型钩子：返回**第一个**非 None 的结果。

        与 call() 的区别是语义：call() 是「往同一份响应里各加各的字段」（dict 合并），
        这里是「这个问题归谁回答」（比如 stills 问「scope=cast 的筛选片段长什么样」）——
        需要拿到单个值，也必须能区分「不管我事（None）」和「管了但没结果（空 dict）」。
        """
        for fn in self.hooks.get(name, []):
            try:
                out = fn(*args)
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook {name}: {exc}")
                continue
            if out is not None:
                return out
        return None

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
            route=self.route, add_ddl=self.add_ddl, add_init=self.add_init,
            hook=self.hook, call_hook=self.call_hook,
            # `call` / `hooks` 是给「扩展自己的列表接口」用的：有些端点（cast/find、
            # facets/*/media）不走核心 browse，但要和 browse 同一套筛选口径，
            # 只能自己遍历 browse_where 钩子、再调 marks_extra 补字段。
            call=self.call, hooks=self.hooks,
            user_db=user_db, amane_db=amane_db, log=log, now_iso=now_iso,
            # 清单页搜索的统一相关性口径：核心已在 amane_db() 连接上注册
            # `amane_rel(name, kw)`，这里再给一份 Python 实现供扩展兜底
            rel_score=rel_score,
            os=os, json=json, datetime=datetime, timedelta=timedelta, timezone=timezone,
            # 通用上游能力：扩展不必自己读凭据文件 / 拼图片代理 URL
            amane_get=amane_get, amane_post=amane_post, public_image=public_image,
            # 通用图片能力：量宽高（img_dims 缓存 + 只取头部 128KB）
            image_dims=image_dims,
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
    # 关键词相关性打分（清单页搜索）：扩展也走这条连接，所以在这里统一注册。
    conn.create_function("amane_rel", 2, rel_score)
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
            -- 我自己写的评价：与上游 comments（amane.db 只读）完全分开存。
            -- 一部片可以写多条（id 自增），详情接口把它们按时间倒序插在评价列表最前并标 mine。
            CREATE TABLE IF NOT EXISTS user_comments (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                metadata_id INTEGER NOT NULL,
                body        TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );
            -- 索引在迁移之后再建（老库这表还没有 id 列，先建索引会直接报错）
            -- 播放器批注（R23）：某个时间点的一句话，播放到那一刻从画面上滚过。
            -- 不入摘要、不做社交，纯自用 —— 记「这里演到哪了 / 这段好」。
            CREATE TABLE IF NOT EXISTS annotations (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                metadata_id INTEGER NOT NULL,
                file_key    TEXT NOT NULL DEFAULT '',
                t_ms        INTEGER NOT NULL,
                body        TEXT NOT NULL,
                created_at  TEXT NOT NULL
            );
            -- 横幅图尺寸缓存：只下载校验一次，之后按 url 命中（含不合格的 0x0）
            CREATE TABLE IF NOT EXISTS img_dims (
                url        TEXT PRIMARY KEY,
                w          INTEGER NOT NULL DEFAULT 0,
                h          INTEGER NOT NULL DEFAULT 0,
                checked_at TEXT
            );
            -- 横幅池：只存「已验证合格」的横图（宽≥720、宽高比≥1.25），每天洗牌取用
            CREATE TABLE IF NOT EXISTS banner_ok (
                metadata_id INTEGER PRIMARY KEY,
                url         TEXT NOT NULL,
                ratio       REAL NOT NULL DEFAULT 1.778,
                updated_at  TEXT
            );
            -- 搜索历史：norm 是去重键（小写 + 压空格），q 是最后一次输入的原文（展示用）
            CREATE TABLE IF NOT EXISTS search_history (
                norm       TEXT PRIMARY KEY,
                q          TEXT NOT NULL,
                hits       INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                used_at    TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_search_used ON search_history(used_at DESC);
            """
            + "\n".join(EXT.ddl)
        )
        for fn in EXT.init_fns:
            fn(conn)
        # 迁移：2.4.5.6 之前的 user_comments 是「一片一条」（PK=metadata_id）。
        # 现在放开成多条，老表结构不同就必须重建，否则新插入会撞主键。
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='user_comments'"
        ).fetchone()
        if row and "AUTOINCREMENT" not in (row["sql"] or ""):
            conn.executescript(
                "ALTER TABLE user_comments RENAME TO user_comments_old;"
                "CREATE TABLE user_comments ("
                "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "  metadata_id INTEGER NOT NULL,"
                "  body TEXT NOT NULL,"
                "  created_at TEXT NOT NULL,"
                "  updated_at TEXT NOT NULL);"
                "CREATE INDEX IF NOT EXISTS idx_user_comments_meta "
                "  ON user_comments(metadata_id, id DESC);"
                "INSERT INTO user_comments(metadata_id, body, created_at, updated_at) "
                "  SELECT metadata_id, body, created_at, updated_at FROM user_comments_old;"
                "DROP TABLE user_comments_old;"
            )
        # 索引统一在表结构确定之后建（老库要先走上面的迁移才有 id 列）
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_comments_meta "
            "ON user_comments(metadata_id, id DESC);")
        # 迁移（1.3.35）：annotations 加 file_key —— 弹幕必须跟着「版本/集」走。
        # 一部片可能有好几个文件（不同清晰度/不同集），共用一个时间轴就会串弹幕。
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(annotations)").fetchall()]
        if "file_key" not in cols:
            conn.execute(
                "ALTER TABLE annotations ADD COLUMN file_key TEXT NOT NULL DEFAULT ''")
        conn.execute("DROP INDEX IF EXISTS idx_annotations_meta")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_annotations_file "
            "ON annotations(metadata_id, file_key, t_ms)")


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

# 联想搜索可选的类型。顺序即客户端 chip 的默认顺序，也是返回结果里的排序。
# film 由核心自己查；其余实体由扩展通过 `suggest_entities` 钩子补，核心不直连它们的表。
SUGGEST_KINDS = ("film", "actor", "director", "tag", "series", "studio")

# 搜索历史只留最近 N 条：它是「最近搜过」的快捷入口，不是操作日志。
SEARCH_HISTORY_KEEP = 30


def suggest_supported() -> list[str]:
    """服务端真正能给出的联想类型：影片永远有，其余看扩展有没有登记。

    扩展在 install 时把自己支持的 kind 挂到 `suggest_kinds` 钩子上，
    这里只做合并 —— 关掉 facets 扩展，supported 里就没有 tag/director，
    客户端据此把 chip 灰掉，而不是发一个永远空结果的参数。
    """
    kinds: set = set()
    for group in EXT.call("suggest_kinds").values():
        if isinstance(group, (list, tuple)):
            kinds.update(str(x) for x in group)
    return [k for k in SUGGEST_KINDS if k == "film" or k in kinds]


# 出演时岁数：上游没有这个字段，用 metadata.release − actors.birthday 现算周岁。
#
# 2026-11-10 用户定：这个功能是给女演员做的 —— 男演员的岁数默认既不在详情页显示、
# 也不参与筛选/排序；要算男性（「有人就喜欢看小孩男孩或大叔」）用
# cast_age_gender=male 显式切过去。性别取值只有 FEMALE / MALE（上游另有 UNKNOWN，
# 不属于任何一档，天然不参与）。
#
# 与扩展 /item/{id}/cast 的 _age_of() 同口径：只有 18–90 岁才算有效（客户端分桶
# 从 18 起）。上游有少量脏生日（只读抽查升序头部先出现 4/5/6 岁、收紧到 10 岁后
# 仍有 12 岁），不滤掉会把这些片顶到首页，也和详情页对不上。聚合里用 CASE 把
# 异常值变 NULL，SQLite 的 MIN/MAX 自动忽略 NULL；不能用 HAVING，相关子查询里
# 不想再套一层派生表。
_CAST_AGE_EXPR = (
    "CAST(strftime('%Y', substr(m.release, 1, 10)) AS INTEGER) "
    "- CAST(strftime('%Y', substr(caa.birthday, 1, 10)) AS INTEGER) "
    "- (CASE WHEN strftime('%m-%d', substr(m.release, 1, 10)) "
    "< strftime('%m-%d', substr(caa.birthday, 1, 10)) THEN 1 ELSE 0 END)"
)

# 对外只认这两个值；其他（含空）一律回落 female。
CAST_AGE_GENDERS = ("female", "male")
# 客户端 key -> 上游 actors.gender 的取值。
_CAST_AGE_LABEL = {"female": "FEMALE", "male": "MALE"}

_CAST_AGE_FROM = (
    "FROM metadata_actors cma JOIN actors caa ON caa.id = cma.actor_id "
    "WHERE cma.metadata_id = m.id AND caa.gender = '{gender}' "
    "AND substr(caa.birthday, 1, 10) GLOB "
    "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
    "AND substr(m.release, 1, 10) GLOB "
    "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*'"
)


def cast_age_gender_of(raw) -> str:
    """把 cast_age_gender 归一：只留 female / male，其余一律 female。"""
    v = str(raw or "").strip().lower()
    return v if v in CAST_AGE_GENDERS else "female"


# 维度过滤：分类墙（标签/系列/制片商/导演）、演员作品、共演结果这些列表页，
# 本质上都是「某个维度下的影片列表」。统一由 browse 承接，新加的筛选（我的评分、
# 收藏夹）和排序（我的评分）才能一处生效，不用每个端点各写一遍。
# 同一个参数里多值用逗号 = AND（演员作品页的「本人 + 合作演员」就是这个口径）。
# 每个 SQL 都以 m.id 为锚点，{marks} 是占位符个数、{n} 是多值个数。
_DIM_FILTERS: dict = {
    "tag_id": ("EXISTS (SELECT 1 FROM metadata_tags t WHERE t.metadata_id = m.id "
               "AND t.tag_id IN ({marks}) GROUP BY t.metadata_id "
               "HAVING COUNT(DISTINCT t.tag_id) = {n})"),
    "director_id": ("EXISTS (SELECT 1 FROM metadata_directors d WHERE d.metadata_id = m.id "
                    "AND d.director_id IN ({marks}) GROUP BY d.metadata_id "
                    "HAVING COUNT(DISTINCT d.director_id) = {n})"),
    "actor_id": ("EXISTS (SELECT 1 FROM metadata_actors a WHERE a.metadata_id = m.id "
                 "AND a.actor_id IN ({marks}) GROUP BY a.metadata_id "
                 "HAVING COUNT(DISTINCT a.actor_id) = {n})"),
    # 系列 / 制片商 / 发行商在 metadata 上是名字列，id 要先换名字
    "series_id": "m.series = (SELECT name FROM series WHERE id = ?)",
    "studio_id": "m.studio = (SELECT name FROM studios WHERE id = ?)",
    "publisher_id": "m.publisher = (SELECT name FROM publishers WHERE id = ?)",
}


def cast_age_sql(gender: str, agg: str) -> str:
    """一部片在指定性别里的最小 / 最大有效岁数；该性别没有可算的资料时是 NULL。"""
    g = _CAST_AGE_LABEL[cast_age_gender_of(gender)]
    return (
        "(SELECT " + agg + "(CASE WHEN " + _CAST_AGE_EXPR + " BETWEEN 18 AND 90 "
        "THEN " + _CAST_AGE_EXPR + " ELSE NULL END) "
        + _CAST_AGE_FROM.format(gender=g) + ")"
    )


# 排序键按「哪个性别 + 哪个方向」预生成：升序比该性别里最年轻的那位，
# 降序比最年长的那位（2.4.5.4 用户定，不再固定取最年轻）。
CAST_AGE_SORT_SQL = {
    g: {"asc": cast_age_sql(g, "MIN"), "desc": cast_age_sql(g, "MAX")}
    for g in CAST_AGE_GENDERS
}

# 排序键 -> (SQL 表达式, 默认方向)。评分在 scores JSON 里，只有 javdb 一个来源。
SORTS = {
    "recent": ("m.updated_at", "desc"),
    "release": ("m.release", "desc"),
    "number": ("m.number", "asc"),
    "score": ("CAST(json_extract(m.scores, '$.javdb') AS REAL)", "desc"),
    "title": ("m.title COLLATE NOCASE", "asc"),
    "runtime": ("m.runtime", "desc"),
    # 列只是占位（让 sort 校验通过），真正用哪个方向/性别在 browse() 里按参数重算。
    "cast_age": (CAST_AGE_SORT_SQL["female"]["asc"], "asc"),
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


def trailer_urls(mid: int) -> list[str]:
    """该条目的预告片地址（按刮削顺序）。

    两种形态混在一列里，客户端与流代理都要能处理：
      * ``/api/resources/<hash>`` —— 刮削时已下载到 amane 的 Resource 库，取本地文件；
      * ``http(s)://...`` —— 还没下载，或站点只给了外链（老数据基本都是这个）。

    解析失败 / 空列一律回空列表：没预告片是常态（全库只有几百部有），不是错误。
    """
    try:
        with amane_db() as conn:
            row = conn.execute("SELECT trailer_urls FROM metadata WHERE id = ?", (int(mid),)).fetchone()
    except sqlite3.Error as exc:
        log(f"WARN trailer 读库失败 id={mid}: {exc}")
        return []
    if row is None:
        return []
    out: list[str] = []
    for url in _json_list(row["trailer_urls"]):
        if not isinstance(url, str):
            continue
        url = url.strip()
        if url.startswith("/api/resources/") or url.startswith("http://") or url.startswith("https://"):
            out.append(url)
    return out


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
    # 私有扩展可以在这里追加自己的标记（例如「还行」评价）；核心不感知具体语义。
    EXT.call("marks_extra", items)
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


# --------------------------------------------------------------------------- #
# 相似影片：详情页底部推荐
#
# 四种信号的强弱差得很远：同系列几乎是「同一部片的不同集」，同演员次之，
# 共同标签是口味相近；同厂牌 / 同年份只是弱相关 —— 只按厂牌选，GIGA 的 1857 部
# 能把一整屏填满，那不叫相似。所以后两者只加分，不单独进候选。
# --------------------------------------------------------------------------- #

SIMILAR_W_SERIES = 40
SIMILAR_W_ACTOR = 12          # 每个共同演员
SIMILAR_W_TAG = 3             # 每个共同标签
SIMILAR_W_STUDIO = 6
SIMILAR_W_YEAR = 2
SIMILAR_CAND_CAP = 400        # 每路候选上限，防大系列把 SQL 撑爆


def build_similar(metadata_id: int, limit: int = 12) -> list[dict]:
    """同系列 / 同演员 / 共同标签（≥2 个）三路取候选，再按加权分排序。

    候选门槛只用强信号；同厂牌、同年份在打分阶段才计入。没有海报的不要 ——
    详情页底部是横滑卡片，缺图会露出一个空框。
    """
    limit = max(1, min(limit, 24))
    with amane_db() as conn:
        row = conn.execute(
            f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (metadata_id,)).fetchone()
        if row is None:
            return []
        base = item_of(row)
        series = base["series"].strip()
        studio = base["studio"].strip()
        year = base["release"][:4]
        actors = [a for a in base["actors"] if a]
        tag_ids = [int(r[0]) for r in conn.execute(
            "SELECT tag_id FROM metadata_tags WHERE metadata_id = ?", (metadata_id,))]

        cand: set[int] = set()
        if series:
            cand.update(r[0] for r in conn.execute(
                "SELECT id FROM metadata WHERE series = ? AND id <> ? LIMIT ?",
                (series, metadata_id, SIMILAR_CAND_CAP)))
        if actors:
            marks = ",".join("?" * len(actors))
            cand.update(r[0] for r in conn.execute(
                f"SELECT DISTINCT m.id FROM metadata m, json_each(m.actors) je "
                f"WHERE je.value IN ({marks}) AND m.id <> ? LIMIT ?",
                (*actors, metadata_id, SIMILAR_CAND_CAP)))
        if tag_ids:
            marks = ",".join("?" * len(tag_ids))
            cand.update(r[0] for r in conn.execute(
                f"SELECT metadata_id FROM metadata_tags WHERE tag_id IN ({marks}) "
                f"AND metadata_id <> ? GROUP BY metadata_id HAVING COUNT(*) >= 2 LIMIT ?",
                (*tag_ids, metadata_id, SIMILAR_CAND_CAP)))

        cand.discard(metadata_id)
        if not cand:
            return []
        ids = tuple(sorted(cand))
        marks = ",".join("?" * len(ids))
        # 列表页口径：只有还有文件的片子才出现；顺手一次取全字段
        rows = conn.execute(
            f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id IN ({marks}) "
            f"AND EXISTS (SELECT 1 FROM media_files mf WHERE mf.metadata_id = m.id)",
            ids).fetchall()
        tag_map: dict[int, set[int]] = {}
        for r in conn.execute(
                f"SELECT metadata_id, tag_id FROM metadata_tags WHERE metadata_id IN ({marks})", ids):
            tag_map.setdefault(int(r[0]), set()).add(int(r[1]))

    actor_set = set(actors)
    tag_set = set(tag_ids)
    scored: list[tuple[int, dict]] = []
    for r in rows:
        item = item_of(r)
        if not item["poster"]:
            continue
        score = 0
        if series and item["series"] == series:
            score += SIMILAR_W_SERIES
        if studio and item["studio"] == studio:
            score += SIMILAR_W_STUDIO
        if year and item["release"][:4] == year:
            score += SIMILAR_W_YEAR
        score += len(actor_set & set(item["actors"])) * SIMILAR_W_ACTOR
        score += len(tag_set & tag_map.get(item["id"], set())) * SIMILAR_W_TAG
        if score > 0:
            scored.append((score, item))

    # 先按发行日降序，再按分数稳定排序 —— 同分时新的在前
    scored.sort(key=lambda pair: pair[1]["release"] or "", reverse=True)
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return attach_marks_auto(attach_progress([it for _s, it in scored[:limit]]))


def annotation_file_names(keys: list[str]) -> dict[str, str]:
    """file_key（f<media_file_id>）→ 文件名，弹幕管理页分组时显示。

    只查一次 amane 库；拿不到就返回空名，页面退化成显示 key，不影响功能。
    """
    ids: list[int] = []
    for k in keys:
        if k[:1] == "f" and k[1:].isdigit():
            n = int(k[1:])
            if n not in ids:
                ids.append(n)
    if not ids:
        return {}
    marks = ",".join("?" * len(ids))
    out: dict[str, str] = {}
    try:
        with amane_db() as conn:
            rows = conn.execute(
                f"SELECT id, path FROM media_files WHERE id IN ({marks})", ids).fetchall()
    except sqlite3.Error:
        return {}
    for r in rows:
        path = str(r["path"] or "")
        out[f"f{int(r['id'])}"] = os.path.basename(path) or path
    return out


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
        # 每日推荐横幅：只放「宽度 ≥720 且宽高比 ≥1.25」的真横图，并带上真实比例，
        # 客户端按比例定宽（16:9 不是唯一答案：dmm 剧照多是 3:2）。
        "banners": build_banners(12),
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
    # 每日推荐用横幅展示，横图（剧照/封面 fanart）是硬需求：没有横图的往后排，
    # 不足 limit 再用竖版海报补位，保证总数不变。
    with_fan = [x for x in uniq if x["fanart"]]
    out = with_fan[:limit]
    if len(out) < limit:
        out += [x for x in uniq if not x["fanart"]][:limit - len(out)]
    return attach_marks_auto(attach_progress(out))


# --------------------------------------------------------------------------- #
# 每日推荐横幅：只挑「真横图」，并把真实宽高比带给客户端
#
# 为什么不能直接用 pick_fanart：它的候选里混着竖版样图（147x200、600x800），
# 拉到 16:9 只裁中间一条，看起来又糊又不像横幅。这里逐张验证尺寸（结果落
# user.db 的 img_dims，第二次起零下载），并让客户端按真实比例定宽。
# --------------------------------------------------------------------------- #

BANNER_TTL = 1800
BANNER_POOL_TARGET = 60          # 池子里攒够这么多张就不再预热
_banner_warm_lock = threading.Lock()
_banner_warming = False
_banner_daily_key = ""
_banner_daily_rows: list = []


def _image_size(data: bytes) -> tuple[int, int] | None:
    """纯标准库读 JPEG / PNG / WebP 的宽高（容器里没有 Pillow）。"""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
        if data[:2] == b"\xff\xd8":
            i, n = 2, len(data)
            while i + 9 < n:
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                              0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    return (int.from_bytes(data[i + 7:i + 9], "big"),
                            int.from_bytes(data[i + 5:i + 7], "big"))
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
            return None
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            fmt = data[12:16]
            if fmt == b"VP8X":
                return (1 + int.from_bytes(data[24:27], "little"),
                        1 + int.from_bytes(data[27:30], "little"))
            if fmt == b"VP8 ":
                return (int.from_bytes(data[26:28], "little") & 0x3FFF,
                        int.from_bytes(data[28:30], "little") & 0x3FFF)
            if fmt == b"VP8L":
                bits = int.from_bytes(data[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        return None
    except (IndexError, ValueError):
        return None


def _dims_get(conn: sqlite3.Connection, url: str) -> tuple[int, int] | None:
    try:
        row = conn.execute("SELECT w, h FROM img_dims WHERE url = ?", (url,)).fetchone()
    except sqlite3.Error:
        return None
    return (row["w"], row["h"]) if row else None


def _dims_put(conn: sqlite3.Connection, url: str, w: int, h: int) -> None:
    try:
        conn.execute(
            "INSERT INTO img_dims(url, w, h, checked_at) VALUES(?, ?, ?, ?) "
            "ON CONFLICT(url) DO UPDATE SET w = excluded.w, h = excluded.h, "
            "checked_at = excluded.checked_at",
            (url, int(w), int(h), now_iso()),
        )
    except sqlite3.Error as exc:
        log(f"WARN img_dims: {exc}")


IMG_PROBE_BYTES = 131072


def image_dims(url: str) -> tuple[int, int] | None:
    """量一张图的宽高，结果落 img_dims（第二次起零网络）。

    只取头部 128KB 就够读 JPEG/PNG/WebP 的尺寸信息，比整张下载快一个量级 ——
    剧照墙「再抽一次」慢、横幅预热慢，都是因为以前每次都整张拉。

    返回 None 表示取不到或不是图（同时把 0x0 记下来，避免反复重试）。
    """
    try:
        with user_db() as conn:
            dims = _dims_get(conn, url)
    except sqlite3.Error:
        dims = None
    if dims is not None:
        return (dims[0], dims[1]) if dims[0] > 0 and dims[1] > 0 else None
    if not host_allowed(url):
        return None
    size: tuple[int, int] | None = None
    try:
        req = Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/122 Safari/537.36",
            "Referer": os.environ.get("IMG_REFERER", ""),
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Range": f"bytes=0-{IMG_PROBE_BYTES - 1}",
        })
        with _opener.open(req, timeout=8) as resp:
            blob = resp.read(IMG_PROBE_BYTES)
        if blob:
            size = _image_size(blob)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError):
        size = None
    w, h = size if size else (0, 0)
    try:
        with user_db() as conn:
            _dims_put(conn, url, w, h)
    except sqlite3.Error:
        pass
    return (w, h) if w > 0 and h > 0 else None


# --------------------------------------------------------------------------- #
# 剧照宽高比：详情页瀑布流的地基
#
# 剧照里横图竖图混着来（16:9 截图 + 竖版海报），详情页原来一律按 190x107 铺开，
# 竖版就只剩中间一条。瀑布流要按真实比例各自定高，所以这里把比例一起下发。
# 尺寸复用 img_dims（横幅预热已经在量），没量过的先给 0 让客户端自己量，
# 同时后台补一刀，下次进同一部片子就准了。
# --------------------------------------------------------------------------- #

_still_dims_lock = threading.Lock()
_still_dims_warming: set[str] = set()


def _still_ratios(urls: list[str]) -> list[float]:
    """返回与 urls 等长的宽高比；0.0 = 还没量过。"""
    out: list[float] = []
    missing: list[str] = []
    try:
        with user_db() as conn:
            for url in urls:
                dims = _dims_get(conn, url)
                if dims and dims[0] > 0 and dims[1] > 0:
                    out.append(round(dims[0] / dims[1], 3))
                else:
                    out.append(0.0)
                    missing.append(url)
    except sqlite3.Error as exc:
        log(f"WARN still ratios: {exc}")
        return [0.0] * len(urls)
    if missing:
        _warm_still_dims(missing)
    return out


def _warm_still_dims(urls: list[str]) -> None:
    """后台把没量过的剧照尺寸补进 img_dims，别让详情页等下载。"""
    todo: list[str] = []
    with _still_dims_lock:
        for url in urls:
            if url not in _still_dims_warming:
                _still_dims_warming.add(url)
                todo.append(url)
    if not todo:
        return

    def run() -> None:
        try:
            for url in todo:
                # image_dims 自己会落库；命中缓存时零网络
                image_dims(url)
        except Exception as exc:  # noqa: BLE001
            log(f"WARN still dims: {exc}")
        finally:
            with _still_dims_lock:
                for url in todo:
                    _still_dims_warming.discard(url)

    try:
        threading.Thread(target=run, daemon=True, name="still-dims").start()
    except RuntimeError as exc:
        log(f"WARN still dims thread: {exc}")
        with _still_dims_lock:
            for url in todo:
                _still_dims_warming.discard(url)


def _banner_candidates(row: sqlite3.Row, per_film: int = 5) -> list[str]:
    urls: list[str] = []
    for group in _json_dict(row["extrafanart_urls"]).values():
        for url in _json_list(group):
            if isinstance(url, str) and url.startswith("http"):
                urls.append(url)
    for url in _json_list(row["thumb_urls"]):
        if isinstance(url, str) and url.startswith("http"):
            urls.append(url)
    return urls[:per_film]


def _pick_banner(conn: sqlite3.Connection, row: sqlite3.Row) -> tuple[str, float]:
    """在候选里找第一张合格横图：宽 ≥720、宽高比 ≥1.25。返回 (代理URL, 比例)。"""
    for url in _banner_candidates(row):
        if not host_allowed(url):
            continue
        dims = image_dims(url)          # 命中缓存零网络，未命中只取头部 128KB
        if not dims:
            continue
        w, h = dims
        if w >= 720 and h > 0 and w / h >= 1.25:
            return _img_proxy(url), round(w / h, 3)
    return "", 0.0


def _scan_banners(seconds: float = 5.0, tries: int = 40) -> int:
    """按当日种子扫一批候选，把合格的写进 banner_ok；返回本轮新增数。

    只做「冷路径」：首页不直接等它，由后台预热线程调用。
    """
    added = 0
    try:
        with amane_db() as conn:
            rows = conn.execute(
                "SELECT " + META_COLUMNS + " FROM metadata m "
                "JOIN (SELECT DISTINCT metadata_id FROM media_files) f ON f.metadata_id = m.id "
                "WHERE m.extrafanart_urls IS NOT NULL "
                "AND m.extrafanart_urls NOT IN ('', '{}', '[]') "
                "ORDER BY m.updated_at DESC LIMIT 900"
            ).fetchall()
            rows = list(rows)
            random.Random(date.today().isoformat()).shuffle(rows)
            with user_db() as uconn:
                done = {r["metadata_id"] for r in uconn.execute("SELECT metadata_id FROM banner_ok")}
            deadline = time.monotonic() + seconds
            checked = 0
            with user_db() as uconn:
                for row in rows:
                    if checked >= tries or time.monotonic() > deadline:
                        break
                    if row["id"] in done:
                        continue
                    checked += 1
                    url, ratio = _pick_banner(uconn, row)
                    if not url:
                        # 拒绝也落一条（url 为空）：下一轮直接跳过，不再重复探测
                        uconn.execute(
                            "INSERT INTO banner_ok(metadata_id, url, ratio, updated_at) "
                            "VALUES(?, '', 0, ?) ON CONFLICT(metadata_id) DO UPDATE SET "
                            "url = '', ratio = 0, updated_at = excluded.updated_at",
                            (row["id"], now_iso()),
                        )
                        continue
                    uconn.execute(
                        "INSERT INTO banner_ok(metadata_id, url, ratio, updated_at) "
                        "VALUES(?, ?, ?, ?) ON CONFLICT(metadata_id) DO UPDATE SET "
                        "url = excluded.url, ratio = excluded.ratio, "
                        "updated_at = excluded.updated_at",
                        (row["id"], url, ratio, now_iso()),
                    )
                    added += 1
        if added:
            log(f"横幅池 +{added}")
    except sqlite3.Error as exc:
        log(f"WARN scan banners: {exc}")
    return added


def _kick_banner_warm() -> None:
    """后台补池：首页只读池子，缺图时异步补，绝不阻塞首屏。"""
    global _banner_warming
    with _banner_warm_lock:
        if _banner_warming:
            return
        _banner_warming = True

    def worker() -> None:
        global _banner_warming
        try:
            for _ in range(6):
                with user_db() as conn:
                    n = conn.execute(
                        "SELECT COUNT(*) FROM banner_ok WHERE url <> ''"
                    ).fetchone()[0]
                if n >= BANNER_POOL_TARGET:
                    break
                if _scan_banners() == 0:
                    break
        except Exception as exc:  # noqa: BLE001
            log(f"WARN banner warm: {exc}")
        finally:
            with _banner_warm_lock:
                _banner_warming = False
            # 池子变了，让当日缓存失效
            _banner_daily_rows.clear()

    threading.Thread(target=worker, name="banner-warm", daemon=True).start()


def _banner_rows(limit: int) -> list[dict]:
    """从已校验池里按日种子洗牌取前 N；洗牌结果当日缓存。

    banner_ok 在 user.db、metadata 在 amane.db，跨库不能 JOIN：各自查再按 id 合并。
    """
    global _banner_daily_key, _banner_daily_rows
    key = date.today().isoformat()
    if _banner_daily_key != key or not _banner_daily_rows:
        with amane_db() as conn:
            metas = conn.execute(
                "SELECT " + META_COLUMNS + " FROM metadata m "
                "WHERE m.id IN (SELECT metadata_id FROM media_files) "
                "ORDER BY m.updated_at DESC LIMIT 1200"
            ).fetchall()
        by_id = {r["id"]: r for r in metas}
        with user_db() as conn:
            pool = conn.execute(
                "SELECT metadata_id, url, ratio FROM banner_ok WHERE url <> ''"
            ).fetchall()
        items = []
        for p in pool:
            row = by_id.get(p["metadata_id"])
            if row is None:
                continue
            item = item_of(row)
            item["fanart"] = p["url"]
            item["fanart_ratio"] = p["ratio"]
            items.append(item)
        random.Random(key).shuffle(items)
        _banner_daily_key = key
        _banner_daily_rows = items
    return list(_banner_daily_rows[:limit])


def build_banners(limit: int = 12) -> list[dict]:
    items = _banner_rows(limit)
    if len(items) < limit:
        _kick_banner_warm()
    if items:
        with amane_db() as conn:
            attach_marks(conn, items)
    return items


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


def amane_post(path: str, payload: dict | None = None, timeout: int = 12) -> dict:
    """带 Bearer 向上游提交 JSON（POST）；空响应体返回 {}。

    写上游只能走这条路：扩展没有凭据访问面，核心也不希望每个扩展自己读 token 文件。
    """
    body = json.dumps(payload or {}, ensure_ascii=False).encode("utf-8")
    req = Request(AMANE_BASE + path, data=body, method="POST", headers={
        "Authorization": f"Bearer {AMANE_TOKEN}",
        "Content-Type": "application/json",
    })
    with _opener.open(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw.strip() else {}


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


class _PlayJob:
    """一块数据的下载任务：边下边用，下载完进 LRU 缓存。"""

    __slots__ = ("data", "done", "failed", "cv")

    def __init__(self) -> None:
        self.data = bytearray()
        self.done = False
        self.failed = False
        self.cv = threading.Condition()


class PlayDiskCache:
    """播放块的**持久化**缓存（1.3.35）。

    为什么要有它：内存里的 `_play_blocks` 一重启就没了，而且几十 GB 的片看两分钟
    就把 320MB 挤爆，回头看同一个位置又要回源 CD2 —— 用户看到的就是「每次进去
    都重新缓存」。别的播放器之所以「点进去就秒开」，是因为它们把下过的数据留在
    了本地磁盘上。

    结构：`<DATA_DIR>/play-cache/<sha1(upstream)[:16]>/<块号>.bin`，一块一个文件，
    写完先落 `.tmp` 再改名（避免读到半块）。整块 1MiB，正好和 `PLAY_BLOCK` 对齐。

    预算：`AMANE_PLAY_DISK_MB`（默认 4096）。超了就按 mtime 从旧到新删，
    每写 64 块才检查一次，避免每块都扫目录。
    """

    def __init__(self, root: str, budget_mb: int) -> None:
        self.root = root
        self.budget = max(0, budget_mb) * 1024 * 1024
        self._lock = threading.Lock()
        self._used = 0
        self._scanned = False
        self._writes = 0
        if self.budget > 0:
            try:
                os.makedirs(self.root, exist_ok=True)
            except OSError as exc:
                log(f"play-cache mkdir failed: {exc}")
                self.budget = 0

    # -- 路径 ---------------------------------------------------------- #

    def _dir(self, upstream: str) -> str:
        name = hashlib.sha1(upstream.encode("utf-8")).hexdigest()[:16]
        return os.path.join(self.root, name)

    def _path(self, upstream: str, blk: int) -> str:
        return os.path.join(self._dir(upstream), f"{blk:08d}.bin")

    # -- 读写 ---------------------------------------------------------- #

    def get(self, upstream: str, blk: int):
        if self.budget <= 0:
            return None
        path = self._path(upstream, blk)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            return None
        if not data:
            return None
        # 读到了就刷新 mtime：最近看过的片子不会被清掉
        try:
            os.utime(path, None)
        except OSError:
            pass
        return data

    def put(self, upstream: str, blk: int, data: bytes) -> None:
        if self.budget <= 0 or not data:
            return
        d = self._dir(upstream)
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            return
        path = os.path.join(d, f"{blk:08d}.bin")
        # 临时名带上线程 id：预取线程和兜底同步取可能同时写同一块，
        # 共用一个 .tmp 会写串（然后 os.replace 出一块坏数据）
        tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
        try:
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)
        except OSError as exc:
            log(f"play-cache write {blk} failed: {exc}")
            try:
                os.remove(tmp)
            except OSError:
                pass
            return
        with self._lock:
            self._used += len(data)
            self._writes += 1
            need_trim = self._writes % 64 == 0 or self._used > self.budget
        if need_trim:
            self.trim()

    def trim(self) -> None:
        """按 mtime 从旧到新删到预算内（最多删 2000 个，避免卡住请求线程）。

        每个文件**保住开头和结尾两块**：MP4 的 moov 常在文件尾部，每次打开都要
        读它；开头那块决定「点进去多快能出画面」。这两块被挤掉，用户就会觉得
        「每次进去都在重新缓存」。
        """
        with self._lock:
            if not self._scanned:
                self._scanned = True
                self._used = self._measure()
            over = self._used - self.budget
            if over <= 0:
                return
            walked: list = []
            firsts: set = set()
            lasts: dict = {}
            for base, _dirs, files in os.walk(self.root):
                for name in files:
                    if not name.endswith(".bin"):
                        continue
                    p = os.path.join(base, name)
                    try:
                        st = os.stat(p)
                        blk = int(name[:8])
                    except (OSError, ValueError):
                        continue
                    firsts.add((base, blk))
                    if base not in lasts or blk > lasts[base]:
                        lasts[base] = blk
                    walked.append((st.st_mtime, st.st_size, p, base, blk))
                    if len(walked) >= 4000:
                        break
                if len(walked) >= 4000:
                    break
            walked.sort()
            for _mt, size, p, base, blk in walked:
                if over <= 0:
                    break
                if blk == 0 or blk == lasts.get(base):
                    continue
                try:
                    os.remove(p)
                    over -= size
                    self._used = max(0, self._used - size)
                except OSError:
                    continue

    def _measure(self) -> int:
        total = 0
        for base, _dirs, files in os.walk(self.root):
            for name in files:
                try:
                    total += os.stat(os.path.join(base, name)).st_size
                except OSError:
                    continue
        return total

    def stats(self) -> dict:
        used = self._used if self._scanned else self._measure()
        with self._lock:
            self._used = used
            self._scanned = True
        files = 0
        try:
            for _base, _dirs, names in os.walk(self.root):
                files += len(names)
        except OSError:
            pass
        return {"enabled": self.budget > 0, "used_mb": round(used / 1048576, 1),
                "budget_mb": round(self.budget / 1048576), "files": files,
                "dir": self.root}

    def clear(self) -> dict:
        removed = 0
        for base, dirs, files in os.walk(self.root, topdown=False):
            for name in files:
                try:
                    os.remove(os.path.join(base, name))
                    removed += 1
                except OSError:
                    continue
            for name in dirs:
                try:
                    os.rmdir(os.path.join(base, name))
                except OSError:
                    continue
        with self._lock:
            self._used = 0
            self._scanned = True
        return {"ok": True, "removed": removed}


PLAY_DISK = PlayDiskCache(os.path.join(DATA_DIR, "play-cache"),
                          int(os.environ.get("AMANE_PLAY_DISK_MB", "4096")))


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

    # 同一部片的并发流登记簿（source/mid → 会话列表）。
    #
    # **只清理真正僵住的流**（客户端已经不再读、write 卡住），绝不按「同片只留一路」
    # 来掐：mp4 的 moov 常常在文件尾部，mpv 正常播放就会另开一条连接读索引，
    # 两条连接互掐会变成「永远建不完缓冲」（2026-11-10 实测把用户坑了一次）。
    _stream_lock = threading.Lock()
    _stream_sessions: dict[str, list] = {}

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

    def _client_gone(self) -> bool:
        """非阻塞探测客户端是否已经断开（seek 后播放器会丢掉旧连接）。"""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if not readable:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except (OSError, ValueError):
            return True

    # ---- 网盘源块缓存 ---------------------------------------------------- #
    #
    # 为什么必须有它：像 MIDE-776 这种文件，**音轨和视频轨在文件里各占一大片**
    # （1800s 处视频在 2.21GB、音频在 3.16GB），解复用器必须来回跳 —— ffmpeg 实测
    # 8 秒里 seek 了 389 次，每次 seek 都是一条新的 Range 请求。每条都回源 CD2
    # （冷区首字节 0.3~4.6s）的话，播放器永远填不满缓存（HUD 缓存秒数 0.1s 0.1s 爬）。
    #
    # 做法：块任务（_PlayJob）边下边用 —— 客户端不必等整块下完就能拿到开头的数据；
    # 块按 1MiB 对齐存进 LRU，并**并行**预取后面若干块。这样 CD2 的冷启动延迟被
    # 多个块同时摊掉，播放点前面始终有几秒到十几秒的余量。
    PLAY_BLOCK = 1024 * 1024
    PLAY_READAHEAD = 8
    PLAY_MAX_JOBS = 16
    PLAY_CACHE_BYTES = int(os.environ.get("AMANE_PLAY_CACHE_MB", "320")) * 1024 * 1024
    _play_lock = threading.Lock()
    _play_blocks: OrderedDict = OrderedDict()
    _play_stat: dict = {"bytes": 0}
    _play_jobs: dict = {}
    _play_meta: dict[str, dict] = {}

    def _play_cache_get(self, ck: str):
        with self._play_lock:
            data = self._play_blocks.get(ck)
            if data is None:
                return None
            self._play_blocks.move_to_end(ck)
            return data

    def _play_cache_put(self, ck: str, data: bytes) -> None:
        if not data:
            return
        with self._play_lock:
            if ck in self._play_blocks:
                return
            self._play_blocks[ck] = data
            self._play_stat["bytes"] += len(data)
            while self._play_stat["bytes"] > self.PLAY_CACHE_BYTES and self._play_blocks:
                _, old = self._play_blocks.popitem(last=False)
                self._play_stat["bytes"] -= len(old)

    def _play_disk_get(self, upstream: str, blk: int):
        """先内存、再磁盘。磁盘命中同时塞回内存，后面几块连读就更快。"""
        data = PLAY_DISK.get(upstream, blk)
        if data is None:
            return None
        key = f"{upstream}#{blk}"
        self._play_cache_put(key, data)
        return data

    def _play_disk_put(self, upstream: str, blk: int, data: bytes) -> None:
        # 落盘在独立线程：1MiB 写到 NAS 盘上十几毫秒，别占着服务线程
        if not data or PLAY_DISK.budget <= 0:
            return
        try:
            threading.Thread(target=PLAY_DISK.put, args=(upstream, blk, data),
                             daemon=True, name="play-disk").start()
        except RuntimeError:
            pass

    def _play_job_for(self, upstream: str, ck: str, blk: int):
        """取（或启动）一块的下载任务；已缓存则立刻是完成状态。"""
        key = f"{ck}#{blk}"
        cached = self._play_cache_get(key)
        if cached is None:
            cached = self._play_disk_get(upstream, blk)
        if cached is not None:
            job = _PlayJob()
            job.data = bytearray(cached)
            job.done = True
            return key, job
        with self._play_lock:
            job = self._play_jobs.get(key)
            if job is not None:
                return key, job
            if len(self._play_jobs) >= self.PLAY_MAX_JOBS:
                return key, None
            job = _PlayJob()
            self._play_jobs[key] = job

        def run() -> None:
            headers = {"Authorization": f"Bearer {AMANE_TOKEN}",
                       "Range": f"bytes={blk * self.PLAY_BLOCK}-"
                                f"{blk * self.PLAY_BLOCK + self.PLAY_BLOCK - 1}"}
            try:
                with _opener.open(Request(upstream, headers=headers), timeout=120) as resp:
                    if resp.status not in (200, 206):
                        job.failed = True
                    else:
                        read_once = getattr(resp, "read1", None) or resp.read
                        while len(job.data) < self.PLAY_BLOCK:
                            # 上游万一不认 Range（回 200 整文件），这里也必须停在块大小，
                            # 否则会把整个 8GB 读进内存
                            part = read_once(min(65536, self.PLAY_BLOCK - len(job.data)))
                            if not part:
                                break
                            with job.cv:
                                job.data += part
                                job.cv.notify_all()
            except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
                job.failed = True
                log(f"play block {blk} failed: {exc}")
            finally:
                with job.cv:
                    job.done = True
                    job.cv.notify_all()
                with self._play_lock:
                    self._play_jobs.pop(key, None)
                if job.data and not job.failed:
                    self._play_cache_put(key, bytes(job.data))
                    # 落盘：下一次（哪怕服务重启后）直接命中，不用再回源。
                    # 只存**完整**的块 —— 半块写进磁盘，下次读回来会比预期短，
                    # `_play_serve_blocks` 会当成文件尾直接收工（画面就断了）。
                    if len(job.data) >= self.PLAY_BLOCK:
                        self._play_disk_put(upstream, blk, bytes(job.data))

        try:
            threading.Thread(target=run, daemon=True, name="play-block").start()
        except RuntimeError:
            with self._play_lock:
                self._play_jobs.pop(key, None)
            return key, None
        return key, job

    def _play_fetch(self, upstream: str, start: int, size: int):
        """同步取一段（任务数到上限时的兜底）。"""
        if size <= 0:
            return None
        headers = {"Authorization": f"Bearer {AMANE_TOKEN}",
                   "Range": f"bytes={start}-{start + size - 1}"}
        try:
            with _opener.open(Request(upstream, headers=headers), timeout=120) as resp:
                if resp.status not in (200, 206):
                    return None
                buf = bytearray()
                while len(buf) < size:
                    part = resp.read(min(65536, size - len(buf)))
                    if not part:
                        break
                    buf += part
                return bytes(buf) if buf else None
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
            log(f"play fetch {start}+{size} failed: {exc}")
            return None

    def _play_prefetch(self, upstream: str, ck: str, blocks: list) -> None:
        """并行预取后续块（每个块一个任务，任务表里有去重与总量上限）。"""
        for blk in blocks:
            self._play_job_for(upstream, ck, blk)

    # 元信息落盘：服务一重启，第一次打开也不用再去上游探一次 HEAD
    # （CD2 冷区首字节 0.3~4.6s，那一下就是用户感知到的「进去要等」）。
    _meta_disk_ready: dict = {"loaded": False}
    _meta_disk_lock = threading.Lock()

    def _meta_disk_path(self) -> str:
        return os.path.join(DATA_DIR, "play-meta.json")

    def _meta_disk_load(self) -> None:
        if self._meta_disk_ready["loaded"]:
            return
        with self._meta_disk_lock:
            if self._meta_disk_ready["loaded"]:
                return
            try:
                with open(self._meta_disk_path(), encoding="utf-8") as fh:
                    data = json.load(fh)
                now = time.time()
                # 文件大小不会变，给 7 天；过期只是多重探一次，不会出错
                for k, v in (data or {}).items():
                    if isinstance(v, dict) and now - float(v.get("at") or 0) < 7 * 86400:
                        self._play_meta[k] = v
                log(f"play meta loaded: {len(self._play_meta)} files")
            except (OSError, ValueError, TypeError):
                pass
            self._meta_disk_ready["loaded"] = True

    def _meta_disk_save(self) -> None:
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
            tmp = f"{self._meta_disk_path()}.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self._play_meta, fh)
            os.replace(tmp, self._meta_disk_path())
        except (OSError, ValueError, TypeError) as exc:
            log(f"play meta save failed: {exc}")

    def _play_meta_for(self, upstream: str, ck: str):
        """拿总长度 / 类型（内存 + 磁盘两层缓存，只探 1 个字节）。"""
        self._meta_disk_load()
        now = time.time()
        with self._play_lock:
            meta = self._play_meta.get(ck)
            if meta is not None and now - meta["at"] < 7 * 86400:
                return meta
        headers = {"Authorization": f"Bearer {AMANE_TOKEN}", "Range": "bytes=0-0"}
        try:
            with _opener.open(Request(upstream, headers=headers), timeout=60) as resp:
                total = 0
                cr = resp.headers.get("Content-Range") or ""
                m = re.search(r"/(\d+)\s*$", cr)
                if m:
                    total = int(m.group(1))
                elif resp.status == 200:
                    total = int(resp.headers.get("Content-Length") or 0)
                if total <= 0:
                    return None
                meta = {
                    "total": total,
                    "ctype": resp.headers.get("Content-Type") or "video/mp4",
                    "etag": resp.headers.get("ETag") or "",
                    "lm": resp.headers.get("Last-Modified") or "",
                    "cc": resp.headers.get("Cache-Control") or "",
                    "at": time.time(),
                }
        except (HTTPError, URLError, TimeoutError, OSError, ValueError):
            return None
        with self._play_lock:
            self._play_meta[ck] = meta
        # 落盘不挡这次请求
        try:
            threading.Thread(target=self._meta_disk_save, daemon=True,
                             name="play-meta").start()
        except RuntimeError:
            pass
        return meta

    def _play_wait_writable(self, session: dict, session_key: str) -> bool:
        """等 socket 可写；返回 False = 客户端已经走了。"""
        while True:
            try:
                _, ready, _ = select.select([], [self.connection], [], 2.0)
            except (OSError, ValueError):
                ready = []
            if ready:
                if session["idle"] > 0:
                    session["idle"] = 0.0
                return True
            if session["idle"] <= 0:
                session["idle"] = time.time()
            if self._client_gone():
                log(f"play {session_key} client gone, abort upstream")
                return False

    def _play_write(self, session: dict, session_key: str, data: bytes) -> str:
        """写一块给客户端；返回结束原因，空串表示继续。"""
        if not self._play_wait_writable(session, session_key):
            return "client-gone"
        try:
            self.wfile.write(data)
        except Exception as exc:  # noqa: BLE001
            log(f"play {session_key} client write failed after "
                f"{session['sent'] / 1048576:.2f}MB: {exc}")
            return f"client:{type(exc).__name__}"
        session["sent"] += len(data)
        return ""

    def _play_serve_blocks(self, upstream: str, ck: str, start: int, limit: int,
                           session: dict, session_key: str, total: int) -> str:
        """按块服务 [start, limit)：块内数据边下边发，不等整块。"""
        pos = start
        counter = 0
        while pos < limit:
            if session["ev"].is_set():
                return "stalled"
            blk = pos // self.PLAY_BLOCK
            off = pos - blk * self.PLAY_BLOCK
            need = min(self.PLAY_BLOCK - off, limit - pos)
            key, job = self._play_job_for(upstream, ck, blk)
            if job is None:
                # 并发任务到上限：同步取一块兜底，保证还能播
                blob = self._play_fetch(upstream, blk * self.PLAY_BLOCK, self.PLAY_BLOCK)
                if not blob:
                    return "fetch-failed"
                self._play_cache_put(key, blob)
                self._play_disk_put(upstream, blk, blob)
                piece = blob[off:off + need]
                reason = self._play_write(session, session_key, piece)
                if reason:
                    return reason
                pos += len(piece)
                counter += len(piece)
                continue

            got = 0
            while got < need:
                with job.cv:
                    while len(job.data) <= off + got and not job.done:
                        job.cv.wait(0.4)
                    avail = min(len(job.data) - (off + got), need - got)
                    piece = bytes(job.data[off + got:off + got + avail]) if avail > 0 else b""
                if not piece:
                    break
                reason = self._play_write(session, session_key, piece)
                if reason:
                    return reason
                got += len(piece)
                counter += len(piece)
                if counter >= 1048576:
                    counter = 0
                    if self._client_gone():
                        log(f"play {session_key} client gone, abort upstream")
                        return "client-gone"
            if got < need:
                # 这块比预期短（文件尾或上游错误），收工
                return "eof" if job.done and not job.failed else "block-short"
            pos += need
            # 播放点前面始终备着几块，CD2 的冷启动延迟被并行摊掉
            last = (total - 1) // self.PLAY_BLOCK
            if blk == last and job.data and not job.failed:
                # 最后一块通常不足 1MiB（文件尾），`run()` 那边按「完整块」判断会跳过它，
                # 但 MP4 的 moov 恰恰躺在这一块里 —— 显式存一次，下次打开就秒开
                self._play_disk_put(upstream, blk, bytes(job.data))
            self._play_prefetch(upstream, ck,
                                [b for b in range(blk + 1, min(blk + 1 + self.PLAY_READAHEAD,
                                                               last + 1))])
        return "done"

    def _play_passthrough(self, upstream: str, req_headers: dict, head_only: bool,
                          session: dict, session_key: str) -> str:
        """兜底：拿不到元信息（或 HEAD）时按原样透传。"""
        resp = _opener.open(Request(upstream, headers=req_headers), timeout=180)
        try:
            self.send_response(resp.status)
            for name in self.PLAY_HOP_HEADERS:
                val = resp.headers.get(name)
                if val:
                    self.send_header(name, val)
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if head_only or resp.status not in (200, 206):
                return "head" if head_only else f"status:{resp.status}"
            read_once = getattr(resp, "read1", None) or resp.read
            counter = 0
            while True:
                if session["ev"].is_set():
                    return "stalled"
                try:
                    chunk = read_once(65536)
                except Exception as exc:  # noqa: BLE001
                    return f"upstream:{type(exc).__name__}"
                if not chunk:
                    return "upstream-eof"
                reason = self._play_write(session, session_key, chunk)
                if reason:
                    return reason
                counter += len(chunk)
                if counter >= 1048576:
                    counter = 0
                    if self._client_gone():
                        log(f"play {session_key} client gone, abort upstream")
                        return "client-gone"
        finally:
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass

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
        for name in ("Range", "If-Range", "If-Modified-Since", "If-None-Match"):
            val = self.headers.get(name)
            if val:
                req_headers[name] = val

        client_ip = (self.client_address[0] if self.client_address else "?")
        log(f"play {source}/{mid}{suffix} from={client_ip} "
            f"range={self.headers.get('Range', '-')} ua={(self.headers.get('User-Agent') or '')[:40]}")
        # 写超时给宽一点：正常播放时 mpv 缓存满了会短时间不读，几十秒不读是正常的，
        # 这时**不能**判死（否则播放器看到 EOF 就重连，缓存永远建不满）。
        try:
            self.connection.settimeout(60)
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

        session_key = f"{source}/{mid}{suffix}"
        session: dict = {"ev": threading.Event(), "idle": 0.0, "sent": 0}
        if not head_only:
            now = time.time()
            with self._stream_lock:
                alive: list = []
                for old in self._stream_sessions.get(session_key, []):
                    # 只掐「已经卡住 1.5 秒以上」的旧流：那是客户端不读了的僵尸。
                    # 正常在跑的连接（比如 mp4 读尾部索引那一路）一律留着。
                    if old["idle"] > 0 and now - old["idle"] > 1.5:
                        old["ev"].set()
                        log(f"play {session_key} drop stalled stream "
                            f"(idle {now - old['idle']:.1f}s)")
                    else:
                        alive.append(old)
                alive.append(session)
                self._stream_sessions[session_key] = alive

        started_at = time.time()
        reason = "eof"
        try:
            meta = None if head_only else self._play_meta_for(upstream, upstream)
            if meta is None:
                reason = self._play_passthrough(upstream, req_headers, head_only,
                                                session, session_key)
                return

            total: int = meta["total"]
            start = 0
            end = total - 1
            status = 200
            m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
            if m:
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), total - 1)
                status = 206
                if start >= total or end < start:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{total}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            limit = end + 1
            self.send_response(status)
            self.send_header("Content-Type", meta["ctype"])
            self.send_header("Content-Length", str(limit - start))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Accept-Ranges", "bytes")
            for field, header in (("etag", "ETag"), ("lm", "Last-Modified"), ("cc", "Cache-Control")):
                if meta[field]:
                    self.send_header(header, meta[field])
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if head_only:
                reason = "head"
                return

            # 起播先把「头」和「尾」两块拉下来（后台线程，不挡这一帧）：
            # MP4 的 moov 大多在文件末尾，每开一次都要读它；不预热的话每次进片
            # 都得等 CD2 冷启动，用户看到的就是「每次进去都重新缓存一会儿」。
            last_blk = (total - 1) // self.PLAY_BLOCK
            warm: list = [0]
            if last_blk > 0:
                warm.append(last_blk)
            if last_blk > 1:
                warm.append(last_blk - 1)
            try:
                self._play_prefetch(upstream, upstream, warm)
            except (RuntimeError, OSError, ValueError):
                pass

            reason = self._play_serve_blocks(upstream, upstream, start, limit,
                                             session, session_key, total)
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
            reason = f"http:{exc.code}"
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as exc:
            reason = type(exc).__name__
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            log(f"play {upstream} failed: {exc}\n{traceback.format_exc()}")
            self.close_connection = True
            reason = "error"
        finally:
            if not head_only:
                spent = max(time.time() - started_at, 1e-6)
                log(f"play {session_key} end {session['sent'] / 1048576:.2f}MB "
                    f"in {spent:.1f}s = {session['sent'] / 1048576 / spent:.2f}MB/s "
                    f"({reason})")
            with self._stream_lock:
                left = [s for s in self._stream_sessions.get(session_key, []) if s is not session]
                if left:
                    self._stream_sessions[session_key] = left
                else:
                    self._stream_sessions.pop(session_key, None)

    # -- 播放缓存管理（1.3.35） -------------------------------------------- #
    #
    # 客户端「设置 → 高级 → 清理缓存」用它显示占用 / 一键清空。
    # 以前清的是手机沙箱里 mpv 的 stream-cache（作用有限），现在真正管用的是
    # 服务端这份按块落盘的缓存 —— 同一个文件第二次打开基本不用回源。
    @route("GET", r"/api/user/playcache")
    def playcache_stats(self, query, *_) -> None:
        self._json(PLAY_DISK.stats())

    @route("POST", r"/api/user/playcache/clear")
    def playcache_clear(self, query, *_) -> None:
        self._json(PLAY_DISK.clear())

    # -- 预告片 -----------------------------------------------------------
    #
    # 预告片是几十秒的小视频（几 MB），不需要 play 那套分块缓存 + 预读：
    # Range 原样透传给 mpv 就够，省一层内存缓存也省一路预取线程。
    #
    # 两种上游，**鉴权头必须分开**：
    #   * 已在 amane 的 Resource 库里（刮削时下载下来的）→ /api/resources/{hash}，
    #     带 Bearer 回源；
    #   * 还只有外链（老数据或站点只给外链）→ 直接去源站拉，**绝不能带 Bearer**，
    #     那是把实例 token 白送给第三方站点。

    @route("GET", r"/api/user/trailer/(\d+)")
    @route("HEAD", r"/api/user/trailer/(\d+)")
    def trailer(self, query: dict, mid: str) -> None:
        head_only: bool = self.command == "HEAD"
        try:
            idx = int((query.get("i") or ["0"])[0] or 0)
        except ValueError:
            idx = 0
        urls = trailer_urls(int(mid))
        if not urls:
            return self._error(404, "这个条目没有预告片")
        if idx < 0 or idx >= len(urls):
            idx = 0
        url = urls[idx]
        if url.startswith("/api/resources/"):
            upstream = f"{AMANE_BASE}{url}"
            req_headers: dict[str, str] = {"Authorization": f"Bearer {AMANE_TOKEN}"}
        elif url.startswith("http://") or url.startswith("https://"):
            upstream = url
            req_headers = {}
        else:
            return self._error(404, "预告片地址不可用")
        for name in ("Range", "If-Range", "If-Modified-Since", "If-None-Match"):
            val = self.headers.get(name)
            if val:
                req_headers[name] = val

        session_key = f"trailer/{mid}/{idx}"
        session: dict = {"ev": threading.Event(), "idle": 0.0, "sent": 0}
        log(f"trailer {mid}#{idx} "
            f"{'local' if url.startswith('/api/resources/') else 'remote'} "
            f"range={self.headers.get('Range', '-')} "
            f"ua={(self.headers.get('User-Agent') or '')[:32]}")
        try:
            self.connection.settimeout(60)
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if not head_only:
            now = time.time()
            with self._stream_lock:
                alive: list = []
                for old in self._stream_sessions.get(session_key, []):
                    if old["idle"] > 0 and now - old["idle"] > 1.5:
                        old["ev"].set()
                    else:
                        alive.append(old)
                alive.append(session)
                self._stream_sessions[session_key] = alive

        started_at = time.time()
        reason = "eof"
        try:
            reason = self._play_passthrough(upstream, req_headers, head_only, session, session_key)
        except HTTPError as exc:
            # 上游 404/403（源站下架、外链过期）也要如实回给播放页，别让 mpv 卡在「缓冲中」
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
            reason = f"http:{exc.code}"
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as exc:
            reason = type(exc).__name__
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            log(f"trailer {upstream} failed: {exc}\n{traceback.format_exc()}")
            self.close_connection = True
            reason = "error"
        finally:
            if not head_only:
                spent = max(time.time() - started_at, 1e-6)
                log(f"trailer {session_key} end {session['sent'] / 1048576:.2f}MB "
                    f"in {spent:.1f}s ({reason})")
            with self._stream_lock:
                left = [s for s in self._stream_sessions.get(session_key, []) if s is not session]
                if left:
                    self._stream_sessions[session_key] = left
                else:
                    self._stream_sessions.pop(session_key, None)

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

    @route("GET", r"/api/user/banners")
    def banners(self, query, *_) -> None:
        """每日推荐横幅（只含真横图 + 真实比例）；给调试/客户端刷新留一个独立入口。"""
        try:
            limit = max(1, min(int((query.get("limit") or ["12"])[0]), 24))
        except ValueError:
            limit = 12
        self._json({"items": build_banners(limit)})

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
        # 扩展可以提供核心 SORTS 里没有的排序键（数据落在 user.db 时跨库不能 JOIN，
        # 由扩展给出分档 CASE 表达式）。求值型钩子：不认识这个 sort 就返回 None。
        ext_sort = EXT.call_hook("browse_sort", sort)
        if sort not in SORTS and not ext_sort:
            sort = "recent"
            ext_sort = None
        column, default_dir = SORTS.get(sort, ("m.id", "desc"))
        want_dir = (ext_sort or {}).get("dir") or default_dir
        direction = arg("order", want_dir).lower()
        if direction not in ("asc", "desc"):
            direction = want_dir
        # 出演年龄看哪个性别：默认女优，male 显式切男优。排序与区间筛选共用这一个。
        age_gender = cast_age_gender_of(arg("cast_age_gender"))
        if sort == "random":
            order = "RANDOM()"
        elif ext_sort and ext_sort.get("expr"):
            order = f"{ext_sort['expr']} {direction.upper()}, m.id DESC"
        elif sort == "cast_age":
            # 升序比「该性别里最年轻的那位」，降序比「该性别里最年长的那位」。
            # 约 29% 影片没有可算岁数的演员：NULL 在 SQLite 的 ASC 里排最前，
            # 会把一堆「查不出年龄」的片顶到首页。先按 IS NULL 沉底，再按岁数排。
            key = CAST_AGE_SORT_SQL[age_gender][direction]
            order = f"({key} IS NULL), {key} {direction.upper()}, m.id DESC"
        else:
            # 次级键保证分页稳定（同分/同日期不会在翻页时重复或漏项）
            order = f"{column} {direction.upper()}, m.id DESC"

        # 有搜索词时相关性优先（2.4.6.21）：番号全等 / 去连字符全等 > 番号前缀 >
        # 标题包含 > 系列包含 > 演员等其它命中。用户选的排序退成次级键 ——
        # 否则搜「IPZZ-932」时最像的那部会被「最近更新」埋到第一页之外。
        rel_params: tuple = ()
        if search:
            kw_esc = re.sub(r"([%_\\])", r"\\\1", search)
            order = (
                "CASE WHEN UPPER(m.number) = UPPER(?) THEN 0 "
                "WHEN REPLACE(UPPER(m.number), '-', '') = REPLACE(UPPER(?), '-', '') THEN 0 "
                "WHEN UPPER(m.number) LIKE UPPER(?) ESCAPE '\\' THEN 1 "
                "WHEN m.title LIKE ? ESCAPE '\\' THEN 2 "
                "WHEN m.series LIKE ? ESCAPE '\\' THEN 3 "
                "ELSE 4 END ASC, " + order
            )
            rel_params = (
                search, search, kw_esc + "%", "%" + kw_esc + "%", "%" + kw_esc + "%"
            )

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
            # 再叠一层 amane_rel：全角输入（ｉｐｚｚ－９３２）、大小写、少打一个连字符
            # 都能命中 —— LIKE 只认字面，归一化得交给这个标量函数。
            # 只对番号做：标题是长日文，逐行归一化+子序列会让搜索从 40ms 涨到 400ms，
            # 而中文标题本来就是全角，LIKE 已经能命中。
            tokens = [x for x in re.split(r"[\s\-_/]+", search) if x][:6]
            for tok in tokens:
                where.append(
                    "(m.number LIKE ? OR REPLACE(m.number, '-', '') LIKE ? "
                    "OR m.title LIKE ? OR m.actors LIKE ? OR m.series LIKE ? "
                    "OR amane_rel(m.number, ?) IS NOT NULL)")
                like = f"%{tok}%"
                params = (*params, like, like, like, like, like, tok)

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

        # 出演时岁数：上游没有这个字段，用 发行日 − 演员生日 在只读库里现算周岁。
        # 只看 age_gender 指定的那个性别（默认女优），任一位该性别演员落在区间即命中；
        # 没生日 / 性别 UNKNOWN 的演员天然不参与（扩展 actors 的 /item/{id}/cast
        # 用同一口径展示，口径见那里的 _age_of()）。
        age_min = arg("cast_age_min")
        age_max = arg("cast_age_max")
        if age_min.isdigit() or age_max.isdigit():
            # 下限与 _age_of() / cast_age_sql() 一致收到 18：低于 18 的岁数一律不参与。
            lo = int(age_min) if age_min.isdigit() else 18
            hi = int(age_max) if age_max.isdigit() else 90
            lo, hi = max(18, min(lo, 90)), max(18, min(hi, 90))
            if lo > hi:
                lo, hi = hi, lo
            where.append(
                "EXISTS (SELECT 1 FROM metadata_actors ca "
                "JOIN actors cab ON cab.id = ca.actor_id "
                "WHERE ca.metadata_id = m.id AND cab.gender = ? "
                "AND substr(cab.birthday, 1, 10) GLOB "
                "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
                "AND substr(m.release, 1, 10) GLOB "
                "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' "
                "AND (CAST(strftime('%Y', substr(m.release, 1, 10)) AS INTEGER) "
                "- CAST(strftime('%Y', substr(cab.birthday, 1, 10)) AS INTEGER) "
                "- (CASE WHEN strftime('%m-%d', substr(m.release, 1, 10)) "
                "< strftime('%m-%d', substr(cab.birthday, 1, 10)) THEN 1 ELSE 0 END)) "
                "BETWEEN ? AND ?)")
            params = (*params, _CAST_AGE_LABEL[age_gender], lo, hi)

        # 维度过滤（标签 / 导演 / 演员 / 系列 / 制片商 / 发行商），口径见 _DIM_FILTERS。
        for dim, dim_sql in _DIM_FILTERS.items():
            raw = arg(dim)
            if not raw:
                continue
            vals = [x.strip() for x in raw.split(",") if x.strip().isdigit()][:12]
            if not vals:
                continue
            if "{marks}" in dim_sql:
                where.append(dim_sql.format(marks=",".join("?" * len(vals)), n=len(vals)))
                params = (*params, *[int(x) for x in vals])
            else:
                # 标量维度（系列/制片商/发行商）只有一个名字位，多值只取第一个
                where.append(dim_sql)
                params = (*params, int(vals[0]))

        # 扩展可以追加筛选条件：核心不感知具体语义，只提供 where/params 拼接点。
        # 逐个钩子取结果再累加，不能用 EXT.call()——它按 dict 合并，多个扩展
        # 同时返回 clauses 时后一个会把前一个覆盖掉（收藏夹 + 评分并存时必踩）。
        for fn in EXT.hooks.get("browse_where", []):
            try:
                out = fn(query) or {}
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook browse_where: {exc}")
                continue
            for extra in out.get("clauses", []):
                if isinstance(extra, (tuple, list)) and len(extra) == 2:
                    where.append(str(extra[0]))
                    params = (*params, *tuple(extra[1]))

        clause = " AND ".join(where)
        with amane_db() as conn:
            # 相关性档位的占位符在 ORDER BY 里（SQL 尾部），所以只给取页的那条加；
            # count_meta 的 SQL 没有 ORDER BY，用它会把参数数量对不上。
            items = query_meta(conn, clause, params + rel_params, order, limit, offset)
            attach_marks(conn, items)
            total = count_meta(conn, clause, params)
        self._json({
            "items": attach_progress(items),
            "total": total,
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": direction,
            "cast_age_gender": age_gender,
        })

    @route("GET", r"/api/user/suggest")
    def suggest(self, query, *_) -> None:
        """搜索联想：输入即搜，准确优先、模糊递进。

        三档递进（客户端按返回顺序直接渲染，tier 只是排序键）：
          1 精确：番号去连字符后等于 / 前缀命中，或标题以关键词开头；
          2 模糊：番号 / 标题包含关键词；
          3 扩大：演员 / 系列 / 制片商命中，或拆词后任一词命中。

        `types` 是「这一次搜哪些类型」的多选：film / actor / director / tag /
        series / studio，逗号分隔。**不带这个参数就只搜影片、返回结构与旧版逐字段
        一致**（2.2.14 及以前的客户端不认识 type/name，多给的实体行会被它画成空卡）。
        演员 / 导演 / 标签这些实体不在这里直连表：核心通过 `suggest_entities`
        钩子问扩展要，关掉对应扩展就自然没有那一类。
        """
        raw = ((query.get("q") or [""])[0]).strip()
        if not raw:
            return self._json({"items": [], "q": raw, "types": [], "supported": []})

        asked = {x.strip().lower() for x in (query.get("types") or [""])[0].split(",") if x.strip()}
        kinds = [k for k in SUGGEST_KINDS if k in asked] or ["film"]
        try:
            per = max(1, min(20, int((query.get("per") or ["6"])[0])))
        except ValueError:
            per = 6
        # 只搜影片时保持旧的 14 条上限；混搜时给实体让几个位置。
        limit = 14 if kinds == ["film"] else 10

        norm = re.sub(r"[\s\-_/]+", "", raw).upper()
        tokens = [t for t in re.split(r"[\s\-_/]+", raw) if t][:6]
        picked: dict[int, tuple] = {}

        def grab(tier: int, where: str, params: tuple, cap: int,
                 order: str = "LENGTH(m.number), m.id") -> None:
            if len(picked) >= limit or not params:
                return
            try:
                with amane_db() as conn:
                    rows = conn.execute(
                        f"SELECT {META_COLUMNS} FROM metadata m "
                        "JOIN (SELECT DISTINCT metadata_id FROM media_files) f ON f.metadata_id = m.id "
                        f"WHERE {where} ORDER BY {order} LIMIT ?",
                        (*params, cap),
                    ).fetchall()
            except sqlite3.Error as exc:
                log(f"WARN suggest: {exc}")
                return
            for r in rows:
                if len(picked) >= limit:
                    break  # 档位之间也要守住上限，否则 8+4+10 会溢出到 20 多条
                if r["id"] in picked:
                    continue
                picked[r["id"]] = (tier, len(picked), item_of(r))

        if norm and "film" in kinds:
            # 1) 番号精确 / 前缀；标题开头
            grab(1, "REPLACE(UPPER(m.number), '-', '') LIKE ?", (norm + "%",), 8)
            grab(1, "UPPER(m.title) LIKE ?", (raw.upper() + "%",), 4)
            # 2a) 演员别名回查：metadata.actors 存的是规范名（つぼみ），别名「蕾」只在
            #     actor_aliases 里，普通条件命中不了。核心不认演员表，让扩展把别名解析成
            #     影片 id 交回来，这里只负责「这些 id 也要出现」。
            #     必须排在「标题包含」之前：蕾 是「芭蕾」的一部分，库里有 108 部片标题带它，
            #     先跑标题匹配会把她的 49 部作品全挤掉 —— 用户搜的是人，不是芭蕾。
            alias_ids = [int(i) for i in (EXT.call("suggest_films", raw, 4).get("ids") or [])
                         if int(i or 0) > 0]
            if alias_ids and len(picked) < limit:
                # 这批按发行时间倒序：别名命中通常就是「这个人的片」，最新的一部最可能是想找的
                grab(2, f"m.id IN ({','.join('?' * len(alias_ids))})", tuple(alias_ids), 4,
                     "m.release DESC, m.id DESC")
            # 2b) 番号 / 标题包含
            grab(2, "(REPLACE(UPPER(m.number), '-', '') LIKE ? OR UPPER(m.title) LIKE ?)",
                 (f"%{norm}%", f"%{raw.upper()}%"), 10)
            # 3) 演员 / 系列 / 制片商，或拆词任一命中（扩大范围）
            actor_likes = " OR ".join(["m.actors LIKE ?"] * len(tokens))
            grab(3, f"(m.series LIKE ? OR m.studio LIKE ? OR {actor_likes})",
                 (f"%{raw}%", f"%{raw}%", *[f"%{t}%" for t in tokens]), 10)

        items = []
        for _, (_, _, item) in sorted(picked.items(), key=lambda kv: (kv[1][0], kv[1][1])):
            item["tier"] = picked[item["id"]][0]
            item["type"] = "film"
            items.append(item)

        # 实体命中：扩展各自查自己的表/上游，返回 {kind: {"total": n, "items": [...]}}。
        entity_kinds = [k for k in kinds if k != "film"]
        totals: dict = {}
        if entity_kinds:
            merged = EXT.call("suggest_entities", raw, entity_kinds)
            for kind in entity_kinds:
                bucket = merged.get(kind)
                if not isinstance(bucket, dict):
                    continue
                totals[kind] = int(bucket.get("total") or 0)
                for hit in (bucket.get("items") or [])[:per]:
                    if isinstance(hit, dict) and int(hit.get("id") or 0) > 0:
                        items.append(hit)

        self._json({
            "items": items,
            "q": raw,
            # types 回显「这次真搜了哪几类」，supported 是服务端**全量**能力：
            # 两个都要回，客户端才能分得清「没勾」和「装了但服务端不支持」。
            "types": kinds,
            "supported": suggest_supported(),
            "totals": totals,
        })

    # ---- 搜索历史 ---------------------------------------------------------
    # 「上次搜过什么」放服务端而不是本地偏好：重装包、换设备都还在，
    # 与收藏 / 观看记录同一套思路。只留最近 SEARCH_HISTORY_KEEP 条 —— 它是快捷入口，
    # 不是审计日志。
    @route("GET", r"/api/user/search/history")
    def search_history(self, query, *_) -> None:
        try:
            limit = max(1, min(60, int((query.get("limit") or ["20"])[0])))
        except ValueError:
            limit = 20
        with user_db() as conn:
            rows = conn.execute(
                "SELECT q, hits, used_at FROM search_history ORDER BY used_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({
            "items": [{"q": r["q"], "hits": r["hits"], "usedAt": r["used_at"]} for r in rows],
            "total": total,
        })

    @route("POST", r"/api/user/search/history")
    def search_history_add(self, query, *_) -> None:
        raw = str(self._body().get("q") or "").strip()
        if not raw:
            return self._error(422, "q 必填")
        text = raw[:60]
        # 归一化只用于去重：大小写 / 多余空格不同的算同一条，但展示仍用最后一次输入的原文
        norm = re.sub(r"\s+", " ", text).lower()
        now = now_iso()
        with user_db() as conn:
            conn.execute(
                "INSERT INTO search_history(q, norm, hits, created_at, used_at) VALUES(?,?,1,?,?) "
                "ON CONFLICT(norm) DO UPDATE SET q = excluded.q, hits = hits + 1, "
                "used_at = excluded.used_at",
                (text, norm, now, now),
            )
            conn.execute(
                "DELETE FROM search_history WHERE norm NOT IN ("
                "SELECT norm FROM search_history ORDER BY used_at DESC LIMIT ?)",
                (SEARCH_HISTORY_KEEP,),
            )
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({"ok": True, "total": total})

    @route("DELETE", r"/api/user/search/history")
    def search_history_del(self, query, *_) -> None:
        """带 `q` 删单条，不带 `q` 清空。"""
        text = ((query.get("q") or [""])[0]).strip()
        with user_db() as conn:
            if text:
                conn.execute("DELETE FROM search_history WHERE norm = ?",
                             (re.sub(r"\s+", " ", text).lower(),))
            else:
                conn.execute("DELETE FROM search_history")
            total = conn.execute("SELECT COUNT(*) FROM search_history").fetchone()[0]
        self._json({"ok": True, "total": total})

    @route("GET", r"/api/user/item/(\d+)")
    def item(self, query, metadata_id, *_) -> None:
        with amane_db() as conn:
            rows = conn.execute(f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (int(metadata_id),)).fetchall()
            if not rows:
                return self._error(404, "条目不存在")
            data = item_of(rows[0])
            extra = _json_dict(rows[0]["extrafanart_urls"])
            stills: list[str] = []
            sources: list[str] = []
            for urls in extra.values():
                for url in _json_list(urls):
                    if isinstance(url, str) and url.startswith("http") and len(stills) < 12:
                        sources.append(url)
                        stills.append(_img_proxy(url))
            data["stills"] = stills
            # 和 stills 等长的宽高比：详情页瀑布流要按真实比例各自定高，
            # 否则竖版海报被塞进横框就只有「砍头」一个下场。量不出来给 0，客户端自己补。
            data["still_ratios"] = _still_ratios(sources)
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
        # 我自己写的评价：按时间倒序全部插到最前，并打 mine 标记（客户端高亮 + 就地改删）
        with user_db() as conn:
            mine_rows = conn.execute(
                "SELECT id, body, created_at, updated_at FROM user_comments "
                "WHERE metadata_id = ? ORDER BY id DESC",
                (int(metadata_id),),
            ).fetchall()
        mine_list = []
        for r in mine_rows:
            body_text = (r["body"] or "").strip()
            if not body_text:
                continue
            mine_list.append({
                "id": int(r["id"]),
                "body": body_text,
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
                "mine": True,
            })
        data["comments"] = mine_list + data["comments"]
        data["my_comment"] = mine_list[0]["body"] if mine_list else ""
        data["my_comment_count"] = len(mine_list)
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

    @route("GET", r"/api/user/item/(\d+)/similar")
    def item_similar(self, query, metadata_id, *_) -> None:
        """详情页「相似影片」。limit 默认 12，上限 24（横滑一屏别拉太多）。"""
        limit = max(1, min(int((query.get("limit") or ["12"])[0]), 24))
        self._json({"items": build_similar(int(metadata_id), limit)})

    @route("POST", r"/api/user/item/(\d+)/comment")
    def comment_add(self, query, metadata_id, *_) -> None:
        """新增一条「我的评价」。一部片可以写多条，不覆盖旧的。

        与上游 comments（只读库里的刮削内容）分开存 user.db；详情接口会把我写的
        这些按时间倒序插在评价列表最前并标 mine=true。上限 4000 字。
        """
        text = str((self._body() or {}).get("body") or "").strip()
        mid = int(metadata_id)
        if not text:
            return self._error(400, "评价不能为空")
        if len(text) > 4000:
            return self._error(400, "评价太长了（上限 4000 字）")
        now = now_iso()
        with user_db() as conn:
            cur = conn.execute(
                "INSERT INTO user_comments(metadata_id, body, created_at, updated_at) "
                "VALUES(?, ?, ?, ?)", (mid, text, now, now))
            new_id = cur.lastrowid
        self._json({"ok": True, "id": new_id, "body": text, "created_at": now})

    @route("PUT", r"/api/user/item/(\d+)/comment/(\d+)")
    def comment_edit(self, query, metadata_id, comment_id, *_) -> None:
        text = str((self._body() or {}).get("body") or "").strip()
        if not text:
            return self._error(400, "评价不能为空（要删请用 DELETE）")
        if len(text) > 4000:
            return self._error(400, "评价太长了（上限 4000 字）")
        with user_db() as conn:
            n = conn.execute(
                "UPDATE user_comments SET body = ?, updated_at = ? WHERE id = ? AND metadata_id = ?",
                (text, now_iso(), int(comment_id), int(metadata_id))).rowcount
        if not n:
            return self._error(404, "这条评价不存在")
        self._json({"ok": True, "id": int(comment_id), "body": text})

    @route("DELETE", r"/api/user/item/(\d+)/comment/(\d+)")
    def comment_del_one(self, query, metadata_id, comment_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM user_comments WHERE id = ? AND metadata_id = ?",
                         (int(comment_id), int(metadata_id)))
        self._json({"ok": True})

    @route("DELETE", r"/api/user/item/(\d+)/comment")
    def comment_del_all(self, query, metadata_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM user_comments WHERE metadata_id = ?", (int(metadata_id),))
        self._json({"ok": True})

    @route("GET", r"/api/user/mycomments")
    def my_comments(self, query, *_) -> None:
        """「我的评价」列表页：我写过的全部评价 + 影片基本信息。

        影片信息在 amane.db（只读）、评价在 user.db，跨库不能 JOIN，所以先取评价
        再按 id 批量补片名/海报。
        """
        try:
            limit = max(1, min(int((query.get("limit") or ["200"])[0]), 500))
        except ValueError:
            return self._error(400, "limit 必须是整数")
        with user_db() as conn:
            rows = conn.execute(
                "SELECT id, metadata_id, body, created_at, updated_at FROM user_comments "
                "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        info = {int(m["id"]): m for m in fetch_by_ids([int(r["metadata_id"]) for r in rows])}
        out = []
        for r in rows:
            base = info.get(int(r["metadata_id"]))
            card = {}
            if base:
                try:
                    card = item_of(base)
                except Exception:  # noqa: BLE001
                    # fetch_by_ids 已经在某些版本里就返回成品 dict，直接拿来用
                    card = dict(base)
            out.append({
                "id": int(r["id"]),
                "metadata_id": int(r["metadata_id"]),
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "updated_at": r["updated_at"] or "",
                "number": card.get("number", ""),
                "title": card.get("title", ""),
                "poster": card.get("poster", ""),
            })
        self._json({"items": out})

    # ---- 播放器批注（R23） --------------------------------------------- #
    #
    # 一条批注 = 「某个时间点 + 一句话」。播放到那一刻从画面上滚过；汇总页点一条
    # 直接跳到那部片的那个位置。纯自用，不做社交、不进摘要。
    #
    @route("GET", r"/api/user/annotations/(\d+)")
    def annotations_of(self, query, metadata_id, *_) -> None:
        """某部片的弹幕。

        `?file=<file_key>` 指定版本/集：弹幕是**跟着文件走**的，不同清晰度、
        不同集共用一个时间轴必然串戏，所以默认必须带 file_key。
        不带 file 时回退成「这部片全部文件」的合集（老客户端兼容），
        并额外返回 `files`（每个文件多少条），管理页据此分组。
        """
        key = (query.get("file") or [""])[0]
        key = key[:64]
        with user_db() as conn:
            if key:
                rows = conn.execute(
                    "SELECT id, t_ms, body, created_at FROM annotations "
                    "WHERE metadata_id = ? AND file_key = ? ORDER BY t_ms",
                    (int(metadata_id), key)).fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, file_key, t_ms, body, created_at FROM annotations "
                    "WHERE metadata_id = ? ORDER BY t_ms", (int(metadata_id),)).fetchall()
            files = conn.execute(
                "SELECT file_key, COUNT(*) AS n FROM annotations "
                "WHERE metadata_id = ? GROUP BY file_key",
                (int(metadata_id),)).fetchall()
        names = annotation_file_names([str(r["file_key"] or "") for r in files])
        self._json({
            "items": [dict(r) for r in rows],
            "files": [{"file_key": str(r["file_key"] or ""), "name": names.get(
                str(r["file_key"] or ""), ""), "count": int(r["n"])} for r in files],
        })

    @route("GET", r"/api/user/annotations")
    def annotations_all(self, query, *_) -> None:
        """我的全部批注（汇总页）：跨库不能 JOIN，先取批注再按 id 补片名/海报。"""
        try:
            limit = max(1, min(int((query.get("limit") or ["300"])[0]), 1000))
        except ValueError:
            return self._error(400, "limit 必须是整数")
        with user_db() as conn:
            rows = conn.execute(
                "SELECT id, metadata_id, file_key, t_ms, body, created_at FROM annotations "
                "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        info = {int(m["id"]): m for m in fetch_by_ids([int(r["metadata_id"]) for r in rows])}
        names = annotation_file_names([str(r["file_key"] or "") for r in rows])
        out = []
        for r in rows:
            base = info.get(int(r["metadata_id"]))
            card = {}
            if base:
                try:
                    card = item_of(base)
                except Exception:  # noqa: BLE001
                    card = dict(base)
            fk = str(r["file_key"] or "")
            out.append({
                "id": int(r["id"]),
                "metadata_id": int(r["metadata_id"]),
                "file_key": fk,
                "file_name": names.get(fk, ""),
                "t_ms": int(r["t_ms"] or 0),
                "body": r["body"] or "",
                "created_at": r["created_at"] or "",
                "number": card.get("number", ""),
                "title": card.get("title", ""),
                "poster": card.get("poster", ""),
            })
        self._json({"items": out})

    @route("POST", r"/api/user/annotations/(\d+)")
    def annotation_add(self, query, metadata_id, *_) -> None:
        body = self._body() or {}
        text = str(body.get("body") or "").strip()
        if not text:
            return self._error(400, "批注不能为空")
        if len(text) > 200:
            return self._error(400, "批注太长了（上限 200 字）")
        file_key = str(body.get("file_key") or "")[:64]
        try:
            t_ms = int(round(float(body.get("t") or 0) * 1000))
        except (TypeError, ValueError):
            t_ms = 0
        t_ms = max(0, min(t_ms, 24 * 3600 * 1000))
        with user_db() as conn:
            cur = conn.execute(
                "INSERT INTO annotations(metadata_id, file_key, t_ms, body, created_at) "
                "VALUES(?,?,?,?,?)",
                (int(metadata_id), file_key, t_ms, text, now_iso()))
            new_id = cur.lastrowid
        self._json({"ok": True, "id": new_id, "file_key": file_key,
                    "t_ms": t_ms, "body": text})

    @route("DELETE", r"/api/user/annotations/(\d+)/(\d+)")
    def annotation_del(self, query, metadata_id, annotation_id, *_) -> None:
        with user_db() as conn:
            conn.execute("DELETE FROM annotations WHERE id = ? AND metadata_id = ?",
                         (int(annotation_id), int(metadata_id)))
        self._json({"ok": True})

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
        # 已看完的口径只有一个：0.95，与客户端 PlayerPage.saveProgress 完全一致。
        # 从前这里是 0.92、客户端是 0.95，会出现「客户端显示看完、服务端没标完」的错位。
        finished = 1 if (body.get("finished") or (duration and position >= duration * FINISH_RATIO)) else 0
        if not finished and position < 5:
            return self._json({"ok": True, "skipped": True})
        with user_db() as conn:
            conn.execute(
                "INSERT INTO history(metadata_id, position, duration, played_at, finished) VALUES(?,?,?,?,?) "
                # finished 一旦置 1 就不再回落：重看开头几秒不该把「已看完」抹掉
                "ON CONFLICT(metadata_id) DO UPDATE SET position=excluded.position, "
                "duration=excluded.duration, played_at=excluded.played_at, "
                "finished=MAX(history.finished, excluded.finished)",
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
