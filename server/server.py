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

环境变量（都可省略，省略时按平台自动发现，见下）：
  AMANE_BASE        amane 地址；不给则按 docker 8000 / 桌面版 18000 探测
  AMANE_DATA        amane 的 data 目录；不给则按平台默认（见 _default_data_dirs）
  AMANE_UPSTREAM_CONF  上游配置文件的路径，默认 <仓库>/config/upstream.json
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
import io
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
from urllib.request import Request, build_opener, ProxyHandler, urlopen

VERSION = "2.6.0"

# 「看完」的唯一口径：客户端 PlayerPage.saveProgress 与服务端兜底都用它。
# 两处各写一个数（曾经 0.95 / 0.92）会出现「客户端显示看完、服务端没标完」的错位。
FINISH_RATIO = 0.95

def _upstream_conf() -> dict:
    """上游配置文件（`tools/upstream.py discover --write` 生成）。

    只存数据目录与地址，**不存 token** —— token 永远从上游自己的 `<data>/token` 读，
    免得仓库里/启动脚本里多一份凭据副本。
    """
    path = os.environ.get("AMANE_UPSTREAM_CONF") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config", "upstream.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


UPSTREAM_CONF = _upstream_conf()


def _default_data_dirs() -> list:
    """上游数据目录候选（顺序即优先级）。

    `/amane-data` 是本仓库 docker 部署的挂载点；桌面版按上游文档的约定：
    Windows `%LOCALAPPDATA%\\Amane`、macOS `~/Library/Application Support/Amane`。
    Linux 桌面版上游文档没给，按源码运行的 `./data` 和 XDG 兜底。
    """
    out = ["/amane-data"]
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        out.append(os.path.join(base, "Amane"))
    elif sys.platform == "darwin":
        out.append(os.path.expanduser("~/Library/Application Support/Amane"))
    else:
        out.append(os.path.expanduser("~/.local/share/amane"))
        out.append(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"))
    return out


def _resolve_data_dir() -> str:
    """挑一个真的存在 amane.db 的目录；都不存在就退回第一个候选（让报错清晰）。"""
    explicit = os.environ.get("AMANE_DATA") or UPSTREAM_CONF.get("data_dir")
    for cand in [explicit] + _default_data_dirs():
        if cand and os.path.isfile(os.path.join(cand, "amane.db")):
            return cand
    return explicit or _default_data_dirs()[0]


def _reachable(url: str) -> bool:
    try:
        with urlopen(url, timeout=0.6) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001 - 探测而已，任何失败都算不通
        return False


def _resolve_base() -> str:
    """上游地址：环境变量 > 配置文件 > 实测。

    桌面版只监听 `127.0.0.1:18000`，Docker 是 `8000`。写死 8000 会让 Windows 上的旁挂
    直接 502，而报错还在「图片加载失败」这种远端表象上 —— 所以这里实测一次再定。
    """
    for cand in (os.environ.get("AMANE_BASE"), UPSTREAM_CONF.get("base")):
        if cand:
            return cand.rstrip("/")
    for port in ("18000", "8000"):
        url = f"http://127.0.0.1:{port}"
        if _reachable(url + "/api/health"):
            return url
    return "http://127.0.0.1:8000"


AMANE_BASE = _resolve_base()
AMANE_DATA = _resolve_data_dir()
DATA_DIR = os.environ.get("DATA_DIR", "/data")
PHOTO_DIR = os.environ.get("PHOTO_DIR") or os.path.join(DATA_DIR, "photos")

# 可选依赖（Pillow）：只有「用剧照生成 GIF 轮播封面」用得到。
# 镜像 python:slim 没带 Pillow，装到持久卷 /data/pylibs，重启容器不丢；
# 装不上也不影响其它功能 —— 那个端点会返回「服务端缺少 Pillow」。
_PYLIB_DIR = os.path.join(DATA_DIR, "pylibs")
if os.path.isdir(_PYLIB_DIR) and _PYLIB_DIR not in sys.path:
    sys.path.insert(0, _PYLIB_DIR)


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

# 本地片是否直读文件（见 play() 里的说明）。默认关，等压测达标再开。
USE_LOCAL_PLAY = os.environ.get("AMANE_PLAY_LOCAL", "1") == "1"
IMAGE_TOKEN = _read_secret("IMAGE_TOKEN")

# --------------------------------------------------------------------------- #
# 上游能力自检（P1）
#
# 上游在持续发版，旁挂靠「只读它的表 + 调它的 HTTP」活着。逐个版本适配是无底洞，
# 所以只做一件事：**启动后看一眼需要的东西还在不在**，缺了就报出来并降级，
# 而不是等某个页面 500 了再猜。完整的能力矩阵与漂移比对在 tools/upstream.py。
# --------------------------------------------------------------------------- #

# 旁挂真正依赖的「能力」：列在就用，不在就降级（不是所有上游版本都有）。
UPSTREAM_NEEDS = {
    "trailer": ("metadata", "trailer_urls"),      # 预告片地址；没有就详情页不显示
    "actor_alias": ("actor_aliases", ""),         # 演员别名；没有则搜索只按名字命中
    "mosaic": ("media_files", "mosaic"),          # 马赛克标记；没有则标记/筛选不可用
    "resources": ("resources", ""),               # 资源库（图片/预告片落盘）
}

_UPSTREAM_CAPS: dict = {"at": 0.0, "value": None}


def upstream_caps(refresh: bool = False) -> dict:
    """上游是谁、什么版本、缺什么。60 秒缓存 —— 页面刷新不该每次都开库。"""
    now = time.time()
    if not refresh and _UPSTREAM_CAPS["value"] and now - _UPSTREAM_CAPS["at"] < 60:
        return _UPSTREAM_CAPS["value"]

    version, reachable = "", False
    try:
        req = Request(AMANE_BASE + "/api/health")
        if AMANE_TOKEN:
            req.add_header("Authorization", f"Bearer {AMANE_TOKEN}")
        with urlopen(req, timeout=2.0) as resp:
            reachable = resp.status == 200
            version = str(json.loads(resp.read(4096).decode("utf-8")).get("version") or "")
    except Exception as exc:  # noqa: BLE001 - 连不上要能说清，不能把旁挂带崩
        log(f"WARN 上游健康检查失败 {AMANE_BASE}: {exc}")

    degraded: list = []
    found: dict = {}
    try:
        with amane_db() as conn:
            tables = {r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
            for cap, (table, column) in UPSTREAM_NEEDS.items():
                if table not in tables:
                    found[cap] = False
                    degraded.append(f"{cap}: 缺表 {table}")
                    continue
                if column:
                    cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
                    if column not in cols:
                        found[cap] = False
                        degraded.append(f"{cap}: 缺列 {table}.{column}")
                        continue
                found[cap] = True
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 上游表结构自检失败 {AMANE_DB}: {exc}")
        degraded.append(f"schema: 读不到 {AMANE_DB}")

    value = {
        "base": AMANE_BASE,
        "data_dir": AMANE_DATA,
        "config": bool(UPSTREAM_CONF),
        "reachable": reachable,
        "version": version,
        "caps": found,
        "degraded": degraded,
        "checked_at": now_iso(),
    }
    _UPSTREAM_CAPS.update({"at": now, "value": value})
    return value


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
# 检索归一化：简繁 + 拼音（2.5.1）
#
# 目标只有一个：**输得不准也要搜得到**。
#   * 输繁体（癡女）要命中简体（痴女）—— 逐字 t2s，只改查询侧，不动库里的数据；
#   * 输拼音首字母（scg）要命中中文名（搜查官）—— 预先算好「名字 → 首字母/全拼」，
#     命中后拿回 (kind, name) 再拼回原 WHERE，**不建影片级索引**（那要几万行）。
#
# 两张表是离线生成后随代码部署的静态数据（`tools/gen_cjk_tables.py`）：
#   data/t2s.tsv     繁 → 简
#   data/pinyin.tsv  汉字 → 首字母 / 全拼
# 部署镜像 python:3.12-slim 装不了 pypinyin / opencc，所以运行时只读这两张表；
# 表缺失时所有新能力**静默降级**，检索行为与没做这个功能时完全一致。
#
# data/alias.tsv 是「俗称 → 库里真有的名字」的补丁表（牛头人 / ntr → 那个日文标签）：
# 俗称本身不是任何一条记录的名字，拼音引擎无从命中，只能靠这张小表桥接。
# 它是**数据**，加词不用改代码。
# --------------------------------------------------------------------------- #
_CJK_DIR = os.environ.get(
    "CJK_DATA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data"))
_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
_CJK_TABLES: dict | None = None


class _CjkTables:
    """只读容器：t2s（繁→简）、jp（日文新字体→简）、py（字→(首字母, 全拼)）、alias（俗称→目标）。"""

    __slots__ = ("t2s", "jp", "py", "alias")

    def __init__(self) -> None:
        self.t2s: dict[str, str] = {}
        self.jp: dict[str, str] = {}
        self.py: dict[str, tuple[str, str]] = {}
        self.alias: dict[str, list[tuple[str, str]]] = {}

    @property
    def ready(self) -> bool:
        return bool(self.t2s or self.py)


def _read_tsv(name: str) -> list[list[str]]:
    path = os.path.join(_CJK_DIR, name)
    try:
        # utf-8-sig：Windows 记事本编辑 alias.tsv 会带 BOM，带 BOM 时首行的第一个
        # 键会变成 "\ufeff牛头人"，看着像「加了这个词却没生效」。这里统一吃掉。
        with open(path, encoding="utf-8-sig") as fh:
            return [line.rstrip("\n").split("\t") for line in fh if line.strip()]
    except OSError as exc:
        log(f"WARN 读不到 {path}（{name} 相关检索降级）: {exc}")
        return []


def cjk_tables() -> _CjkTables:
    """懒加载。改表不用重启（dev 期方便），所以只在进程内缓存一次。"""
    global _CJK_TABLES
    if _CJK_TABLES is not None:
        return _CJK_TABLES
    t = _CjkTables()
    for row in _read_tsv("t2s.tsv"):
        if len(row) >= 2 and len(row[0]) == 1 and len(row[1]) == 1:
            t.t2s[row[0]] = row[1]
    for row in _read_tsv("jp2s.tsv"):
        if len(row) >= 2 and len(row[0]) == 1 and len(row[1]) == 1:
            t.jp[row[0]] = row[1]
    for row in _read_tsv("pinyin.tsv"):
        if len(row) >= 3 and len(row[0]) == 1:
            t.py[row[0]] = (row[1], row[2])
    for row in _read_tsv("alias.tsv"):
        if len(row) >= 3 and row[1] in ("tag", "series", "actor"):
            t.alias.setdefault(row[0].strip().lower(), []).append((row[1], row[2].strip()))
    _CJK_TABLES = t
    if not t.ready:
        log("WARN 中文检索表缺失，简繁/拼音检索关闭（其余行为不变）")
    return t


def has_cjk(text) -> bool:
    return bool(text) and _CJK_RE.search(str(text)) is not None


def t2s_text(text) -> str:
    """繁体 → 简体，逐字，查不到就原样保留。"""
    if not text:
        return ""
    table = cjk_tables().t2s
    if not table:
        return str(text)
    return "".join(table.get(ch, ch) for ch in str(text))


def fold_text(text) -> str:
    """把一个词折成「规范形」：日文新字体 → 繁体 → 简体。

    库里混着日文写法（女捜查官、三上悠亜、戦队），中文用户只会打简体。
    折叠本身不查库、不改任何数据，只是让两边落到同一个可比形
    （派生表 `name_variant` 就是这么建出来的，见 build_name_pinyin）。
    """
    if not text:
        return ""
    t = cjk_tables()
    if not t.jp and not t.t2s:
        return str(text)
    out: list[str] = []
    for ch in str(text):
        mid = t.jp.get(ch, ch)
        out.append(t.t2s.get(mid, mid))
    return "".join(out)


def norm_query(text) -> str:
    """搜索词归一化入口：日文新字体 + 繁转简。LIKE / amane_rel 仍按原有逻辑跑。"""
    return fold_text(text)


def name_sig(name: str) -> tuple[str, str]:
    """一个名字的 (首字母串, 全拼串)。

    汉字查表；ASCII 字母数字原样保留（`NTRH` 这种混排名也能被 `ntrh` 命中）；
    假名 / 其它符号跳过 —— 它们本来就没法用拼音打出来。
    """
    py = cjk_tables().py
    initials: list[str] = []
    full: list[str] = []
    for ch in str(name or ""):
        got = py.get(ch)
        if got is not None:
            initials.append(got[0])
            full.append(got[1])
        elif ch.isascii() and ch.isalnum():
            low = ch.lower()
            initials.append(low)
            full.append(low)
    return "".join(initials), "".join(full)


# 只索引名字，不索引到影片：命中 (kind, name) 之后拼回原 WHERE（见 browsing 里的
# _PY_COND）。建影片级索引要几万~几十万行，且每次入库都得重算，不划算。
_PY_KINDS: dict[str, str] = {
    "tag": "SELECT name FROM tags WHERE name IS NOT NULL AND name != ''",
    "series": "SELECT name FROM series WHERE name IS NOT NULL AND name != ''",
    "actor": "SELECT name FROM actors WHERE name IS NOT NULL AND name != ''",
}

NAME_PINYIN_DDL = """
CREATE TABLE IF NOT EXISTS name_pinyin (
    kind     TEXT NOT NULL,
    name     TEXT NOT NULL,
    initials TEXT NOT NULL,
    pinyin   TEXT NOT NULL,
    PRIMARY KEY (kind, name)
);
CREATE INDEX IF NOT EXISTS idx_name_pinyin_initials ON name_pinyin(initials);
CREATE INDEX IF NOT EXISTS idx_name_pinyin_pinyin ON name_pinyin(pinyin);
"""

_PY_BUILD_LOCK = threading.Lock()
_PY_STAMP = 0                      # 每次重建 +1，用来作废查询缓存
_PY_CACHE: dict[str, list[tuple[str, str]]] = {}


def name_pinyin_count() -> int:
    try:
        with user_db() as conn:
            return int(conn.execute("SELECT COUNT(*) FROM name_pinyin").fetchone()[0])
    except sqlite3.Error:
        return 0


def build_name_pinyin(force: bool = False) -> dict:
    """从 amane 主库读三类中文名，算好首字母/全拼写进 user.db。幂等（可重复跑）。"""
    global _PY_STAMP
    tables = cjk_tables()
    if not tables.py:
        return {"ok": False, "reason": "pinyin.tsv 缺失或为空"}
    with _PY_BUILD_LOCK:
        start = time.time()
        rows: list[tuple[str, str, str, str]] = []
        with amane_db() as conn:
            for kind, sql in _PY_KINDS.items():
                try:
                    names = [r[0] for r in conn.execute(sql).fetchall()]
                except sqlite3.Error as exc:
                    log(f"WARN 建拼音索引读 {kind} 失败: {exc}")
                    continue
                for name in names:
                    ini, full = name_sig(name)
                    if ini:
                        rows.append((kind, name, ini, full))
        # 俗称补丁：目标名本身没有中文（例如那个日文 NTR 标签），签名只能来自俗称
        by_key = {(r[0], r[1]): r for r in rows}
        for alias, targets in tables.alias.items():
            ini, full = name_sig(alias)
            if not ini:
                continue
            for kind, target in targets:
                cur = by_key.get((kind, target))
                if cur is None:
                    new = (kind, target, ini, full)
                    rows.append(new)
                    by_key[(kind, target)] = new
                elif ini not in cur[2]:
                    # 同一个名字带多种俗称：签名用空格拼起来，查询侧按包含匹配
                    merged = (cur[0], cur[1], f"{cur[2]} {ini}", f"{cur[3]} {full}")
                    idx = rows.index(cur)
                    rows[idx] = merged
                    by_key[(kind, target)] = merged
        # amane 主库里的名字会变（重新刮削 / 新入库），整表重建最省事
        with user_db() as conn:
            conn.execute("DELETE FROM name_pinyin")
            conn.executemany(
                "INSERT OR REPLACE INTO name_pinyin(kind, name, initials, pinyin) "
                "VALUES(?,?,?,?)", rows)
        _PY_STAMP += 1
        _PY_CACHE.clear()
        variant = build_variants(rows)
        spent = round((time.time() - start) * 1000)
        log(f"中文索引重建完成：名字 {len(rows)} 条，折叠别名 {variant} 条，{spent}ms")
        return {"ok": True, "count": len(rows), "variant": variant, "ms": spent}


# 折叠别名的范围（2.5.1.18）：
#   * tag / actor —— 人们真的会照着打字的名字，必须收；
#   * series —— 只收短名。库里 240 个含日文异体字的系列**全是长日文标题**，
#     没人会把「10発中出しするまで…」简化了再打，收进来只是白占地方。
_VARIANT_SERIES_MAX = 12


def build_variants(rows: list[tuple]) -> int:
    """把「写法不同但折叠后一样」的名字做成别名行。

    为什么做成别名而不是索引级折叠：别名这套管线（browse 条件、suggest 实体、
    可能不全提示）**已经全通了**，直接复用；也不用改 `name_pinyin` 的结构和
    browse 的标签匹配。代价只是多一张派生表，重建索引时顺手生成。

    规则：名字折叠后与原名不同 → 记一行 `alias=折叠形, target=原名`。
    查询侧再做一次**包含**匹配，所以打半个词（搜查官）也能落到「女捜查官」。
    """
    pairs: list[tuple] = []
    seen: set[tuple[str, str, str]] = set()
    for row in rows:
        kind, name = str(row[0]), str(row[1])
        if not name:
            continue
        if kind == "series" and len(name) > _VARIANT_SERIES_MAX:
            continue
        folded = fold_text(name)
        if not folded or folded == name:
            continue
        key = (folded, kind, name)
        if key in seen:
            continue
        seen.add(key)
        pairs.append(key)
    try:
        with user_db() as conn:
            conn.execute("DELETE FROM name_variant")
            conn.executemany(
                "INSERT OR REPLACE INTO name_variant(alias, kind, target) VALUES(?,?,?)",
                pairs)
    except sqlite3.Error as exc:
        log(f"WARN 折叠别名写入失败: {exc}")
        return 0
    return len(pairs)


def pinyin_names(token: str, limit: int = 12) -> list[tuple[str, str]]:
    """把拼音 token 解析成 [(kind, name)]。

    匹配规则：首字母串**包含** token，或全拼串**包含** token。用包含而不只是前缀，
    是为了「ntr」也能命中签名 `ntr`/`niutouren` 之外的组合（如「n…t…r」）；
    结果按「首字母全等 > 前缀 > 其它」排序，噪声大的排后面。
    """
    tok = (token or "").strip().lower()
    if len(tok) < 2 or len(tok) > 20 or not tok.isascii() or not tok.isalpha():
        return []
    cached = _PY_CACHE.get(tok)
    if cached is not None:
        return cached
    out: list[tuple[str, str]] = []
    # 2 个字的首字母（jr / rq / cn）只做**前缀**匹配：
    # 用包含匹配的话「jr」会把全库签名里任意位置出现 j…r 的名字都捞进来
    # （实测 jr 命中 1151 部、耗时 180ms，其中大半是噪音）。3 个字以上才允许包含。
    loose = len(tok) >= 3
    ini_pat = f"%{tok}%" if loose else f"{tok}%"
    try:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT kind, name FROM name_pinyin "
                "WHERE initials LIKE ? OR pinyin LIKE ? "
                "ORDER BY CASE WHEN initials = ? THEN 0 WHEN initials LIKE ? THEN 1 "
                "ELSE 2 END, LENGTH(name) LIMIT ?",
                (ini_pat, ini_pat, tok, f"{tok}%", limit),
            ).fetchall()
        out = [(str(r[0]), str(r[1])) for r in rows]
    except sqlite3.Error:
        return []
    if len(_PY_CACHE) > 512:
        _PY_CACHE.clear()
    _PY_CACHE[tok] = out
    return out


# (kind, name) → 拼进 WHERE 的片段。tag 走子查询，series 是标量，actor 在
# metadata.actors 里（逗号分隔的规范名，用 LIKE 足够）。
_PY_COND: dict[str, str] = {
    "tag": ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
            "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)"),
    "series": "m.series = ?",
    "actor": "m.actors LIKE ?",
}
# 一个词最多扩出几条名字条件（见 search_clauses 的说明）
_PY_MAX_CLAUSES = 6


def pinyin_clauses(token: str) -> list[tuple[str, tuple]]:
    """拼音 token → [(条件, 参数)]；解析不到就返回空（等于没加条件）。"""
    out: list[tuple[str, tuple]] = []
    seen: set[tuple[str, str]] = set()
    for kind, name in pinyin_names(token):
        key = (kind, name)
        if key in seen:
            continue
        seen.add(key)
        sql = _PY_COND.get(kind)
        if not sql:
            continue
        out.append((sql, (f"%{name}%" if kind == "actor" else name,)))
    return out


_EXTRA_ALIASES: dict[str, list[tuple[str, str]]] | None = None


def extra_aliases() -> dict[str, list[tuple[str, str]]]:
    """用户自己维护的别名（user.db 的 `search_alias`），与出厂 alias.tsv 取并集。

    进程内缓存一次：这张表只由下面三个接口改写，写完调 `reset_alias_cache()`。
    """
    global _EXTRA_ALIASES
    if _EXTRA_ALIASES is not None:
        return _EXTRA_ALIASES
    out: dict[str, list[tuple[str, str]]] = {}
    try:
        with user_db() as conn:
            rows = conn.execute("SELECT alias, kind, target FROM search_alias").fetchall()
        for r in rows:
            out.setdefault(str(r[0]).strip().lower(), []).append((str(r[1]), str(r[2])))
    except sqlite3.Error as exc:
        # 表还没建（老库首次启动）不算错，只是暂时没有用户别名
        log(f"INFO 读 search_alias 跳过: {exc}")
    _EXTRA_ALIASES = out
    return out


def reset_alias_cache() -> None:
    global _EXTRA_ALIASES
    _EXTRA_ALIASES = None


def variant_pairs(token: str, limit: int = 40) -> list[tuple[str, str]]:
    """「折叠别名」：写法不同、折叠后一样的那批名字。

    表 `name_variant` 由 `build_variants()` 从当前库扫出来（女捜查官 → 女搜查官）。
    这里先**精确**再**包含**：精确命中的是整名（打「女搜查官」），包含命中的是半截
    （打「搜查官」也能落到「女捜查官」）。只对这张表做包含匹配 —— 手工别名表里
    有很多 `ntr` / `ntr人妻` 这种，做包含匹配会互相打架。
    """
    tok = str(token or "").strip()
    if len(tok) < 2:
        return []
    key = tok.lower()
    out: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    try:
        with user_db() as conn:
            exact = conn.execute(
                "SELECT kind, target FROM name_variant "
                "WHERE alias = ? ORDER BY LENGTH(alias) LIMIT ?",
                (key, limit)).fetchall()
            for r in exact:
                pair = (str(r[0]), str(r[1]))
                if pair not in seen:
                    seen.add(pair)
                    out.append(pair)
            more = conn.execute(
                "SELECT kind, target FROM name_variant "
                "WHERE alias LIKE ? ORDER BY LENGTH(alias) LIMIT ?",
                (f"%{key}%", limit)).fetchall()
            for r in more:
                pair = (str(r[0]), str(r[1]))
                if pair not in seen:
                    seen.add(pair)
                    out.append(pair)
                if len(out) >= limit:
                    break
    except sqlite3.Error:
        return []
    return out[:limit]


def variant_group_clauses(token: str) -> list[tuple[str, tuple]]:
    """把折叠别名**按类型合并**成最多 3 条 SQL 条件。

    一个词可能牵出十几个名字（搜「搜查官」→ 女捜查官、秘密捜査官の女…）。
    一个名字一条 `IN (SELECT …)` 会很快撞上 `_PY_MAX_CLAUSES` 的上限，
    而且每加一条就要多扫一遍关联表。合并成「一个 IN 里放多个名字」后，
    条数恒定、扫描次数恒定。
    """
    pairs = variant_pairs(token)
    if not pairs:
        return []
    by_kind: dict[str, list[str]] = {}
    for kind, name in pairs:
        by_kind.setdefault(kind, []).append(name)
    out: list[tuple[str, tuple]] = []
    tags = by_kind.get("tag") or []
    if tags:
        marks = ",".join("?" * len(tags))
        out.append((
            "m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
            f"JOIN tags t ON t.id = mt.tag_id WHERE t.name IN ({marks}))",
            tuple(tags)))
    series = by_kind.get("series") or []
    if series:
        marks = ",".join("?" * len(series))
        out.append((f"m.series IN ({marks})", tuple(series)))
    actors = by_kind.get("actor") or []
    if actors:
        out.append(("(" + " OR ".join(["m.actors LIKE ?"] * len(actors)) + ")",
                    tuple(f"%{n}%" for n in actors)))
    return out


def alias_clauses(token: str) -> list[tuple[str, tuple]]:
    """俗称 → 库里真有的名字。

    为什么需要这一层：俗称（牛头人 / 搜查官 / ntr）不是任何一条记录的**名字**，
    拼音引擎和 LIKE 都无从命中；而用户脑子里想的就是这个词。
    数据来自三处（取并集）：
      1. `data/alias.tsv` —— 出厂默认，随代码走，public 部署也有；
      2. user.db 的 `search_alias` 表 —— 用户/管理员自己加的，不出仓库；
      3. user.db 的 `name_variant` 表 —— 从库里扫出来的**写法差异**（2.5.1.18），
         折叠后与原名不同的那些，重建索引时自动生成。这一层按类型合并成几条 SQL，
         不占 `_PY_MAX_CLAUSES` 的槽位。
    """
    key = str(token or "").strip().lower()
    pairs = list(cjk_tables().alias.get(key) or []) + list(extra_aliases().get(key) or [])
    out: list[tuple[str, tuple]] = []
    seen: set[tuple[str, str]] = set()
    for kind, name in pairs:
        if (kind, name) in seen:
            continue
        seen.add((kind, name))
        sql = _PY_COND.get(kind)
        if not sql:
            continue
        out.append((sql, (f"%{name}%" if kind == "actor" else name,)))
    out.extend(variant_group_clauses(key))
    return out


def alias_targets(token: str) -> list[tuple[str, str]]:
    """俗称解析成 [(kind, 目标名)]，供 suggest 拿去问扩展要实体行。"""
    key = str(token or "").strip().lower()
    pairs = (list(cjk_tables().alias.get(key) or [])
             + list(extra_aliases().get(key) or [])
             + variant_pairs(key))
    out: list[tuple[str, str]] = []
    for kind, name in pairs:
        if (kind, name) not in out:
            out.append((kind, name))
    return out


_MATCH_KINDS = ("tag", "series")


def names_hit_by(q: str, limit: int = 6) -> list[tuple[str, str]]:
    """一个词现在会命中**哪些实体名**：别名目标 + 拼音解析 + 标签/系列名字面包含。

    这是「漏算了谁」的基准：拿这些名字去找字面相近的兄弟，去掉已经在里面的，
    剩下的就是「这次搜索没覆盖到、但看起来是同一个东西」。
    """
    w = norm_query(q).strip()
    if not w:
        return []
    out: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def push(kind: str, name: str) -> None:
        if kind in _MATCH_KINDS and name and (kind, name) not in seen:
            seen.add((kind, name))
            out.append((kind, name))

    for kind, name in alias_targets(w):
        push(kind, name)
    for tok in re.split(r"[\s\-_/]+", w)[:4]:
        for kind, name in pinyin_names(tok, 6):
            push(kind, name)
    # 字面包含：只在长度 ≥2 时做（单个字几乎必然命中一堆无关名字）
    if len(w) >= 2:
        try:
            with amane_db() as conn:
                for name in conn.execute(
                        "SELECT name FROM tags WHERE name LIKE ? LIMIT ?",
                        (f"%{w}%", limit)).fetchall():
                    push("tag", str(name[0]))
                for name in conn.execute(
                        "SELECT name FROM series WHERE name LIKE ? LIMIT ?",
                        (f"%{w}%", limit)).fetchall():
                    push("series", str(name[0]))
        except sqlite3.Error:
            pass
    return out[:limit]


def missing_names(q: str, limit: int = 4) -> list[dict]:
    """「这个词明明有结果，但库里还有个像的名字没算进来」。

    判据只做**字面**（含相同汉字），所以它给的是**线索**而不是断言 ——
    界面上的措辞必须留余地（「还有个名字没算进来」，不是「这是同一类」）。
    语义上的等同（搜查官 → 女检察官）程序永远猜不出来，那部分只能靠人。
    """
    hit = names_hit_by(q)
    if not hit:
        return []
    covered: set[tuple[str, str]] = set(hit)
    for kind, name in alias_targets(norm_query(q)):
        covered.add((kind, name))
    seen: set[tuple[str, str]] = set()
    cands: list[dict] = []
    counts = _alias_film_counts([{"kind": k, "target": n} for k, n in hit])
    used_base = 0
    for kind, name in hit:
        # 基准只取**短标签名**：系列名和长日文标签本身就是一句话，
        # 拿它当「像不像」的锚点会牵出一堆无关结果（实测「痴女」会牵到
        # 「彼女のお姉さんは巨乳と中出しOKで…」这种长系列名）。
        if kind != "tag" or len(name) > 10:
            continue
        # 只挂 1~2 部片的标签不足以代表一个「概念」，当锚点只会制造噪音
        if counts.get((kind, name), 0) < 20:
            continue
        if used_base >= 4:
            break
        used_base += 1
        for c in alias_candidates(name, 3, 2):
            key = (str(c["kind"]), str(c["target"]))
            if key in covered or key in seen:
                continue
            if int(c.get("films") or 0) <= 0 or len(key[1]) > 12:
                continue
            # 「基准词只是候选词的一部分」是**细分标签**，不是同一个东西的另一种写法：
            # 恶堕 ⊂ 恶堕妆容、中出 ⊂ 乞求中出 —— 这类一律不推，否则提示会变噪音。
            if name in key[1] and len(key[1]) > len(name):
                continue
            seen.add(key)
            cands.append({
                "kind": key[0], "target": key[1], "films": int(c["films"]),
                # 它是从哪个已命中的名字联想出来的，界面上可以写「和 X 字面相近」
                "near": name,
                "same_kind": key[0] == kind,
            })
    cands.sort(key=lambda x: (0 if x["same_kind"] else 1, -int(x["films"])))
    return cands[:limit]





_ALIAS_KIND_CN = {"tag": "标签", "series": "系列", "actor": "演员"}


def _alias_film_counts(pairs: list[dict]) -> dict[tuple[str, str], int]:
    """每个 (kind, target) 在库里挂了多少部片 —— 别名的「有没有用」就看这个数。"""
    out: dict[tuple[str, str], int] = {}
    if not pairs:
        return out
    sql = {
        "tag": ("SELECT COUNT(*) FROM metadata_tags mt JOIN tags t ON t.id = mt.tag_id "
                "WHERE t.name = ?"),
        "series": "SELECT COUNT(*) FROM metadata WHERE series = ?",
        "actor": "SELECT COUNT(*) FROM metadata WHERE actors LIKE ?",
    }
    try:
        with amane_db() as conn:
            for item in pairs:
                key = (str(item["kind"]), str(item["target"]))
                if key in out:
                    continue
                query = sql.get(key[0])
                if not query:
                    continue
                arg = f"%{key[1]}%" if key[0] == "actor" else key[1]
                out[key] = int(conn.execute(query, (arg,)).fetchone()[0] or 0)
    except sqlite3.Error as exc:
        log(f"WARN 统计别名命中数: {exc}")
    return out


_MISS_KEEP = 200          # miss 表最多留多少条（和搜索历史一个量级）
_MISS_MAX_HITS = 2        # 严格搜索结果 ≤ 2 条才算「没搜到」

_ALIAS_CAND_SQL = {
    "tag": ("SELECT t.name AS name, COUNT(mt.metadata_id) AS films FROM tags t "
            "LEFT JOIN metadata_tags mt ON mt.tag_id = t.id WHERE {where} "
            "GROUP BY t.id ORDER BY films DESC LIMIT 60"),
    "series": ("SELECT s.name AS name, COUNT(m.id) AS films FROM series s "
               "LEFT JOIN metadata m ON m.series = s.name WHERE {where} "
               "GROUP BY s.id ORDER BY films DESC LIMIT 60"),
    "actor": ("SELECT a.name AS name, COUNT(m.id) AS films FROM actors a "
              "LEFT JOIN metadata m ON m.actors LIKE '%' || a.name || '%' WHERE {where} "
              "GROUP BY a.id ORDER BY films DESC LIMIT 60"),
}


def alias_candidates(word: str, limit: int = 4, min_shared: int = 1) -> list[dict]:
    """给一个「搜不到的词」猜几个库里的名字。

    猜的依据只有**字面重合**（含相同汉字 / 拼音首字母重合），因为语义（搜查官 →
    女检察官）程序是猜不出来的 —— 这也是为什么界面上要留「自己去库里找」的路。
    猜不准是常态，所以每条都带 `films`，用户一眼能看出哪个才是他想要的。
    """
    w = norm_query(word).strip()
    if not w:
        return []
    chars: list[str] = []
    for ch in w:
        if has_cjk(ch) and ch not in chars:
            chars.append(ch)
    if not chars:
        chars = [w]  # 纯英文/拼音词：整体当子串找
    chars = chars[:5]
    where = " OR ".join(["t.name LIKE ?"] * len(chars))
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    try:
        with amane_db() as conn:
            for kind, sql in _ALIAS_CAND_SQL.items():
                if kind == "tag":
                    clause = where
                    args = [f"%{c}%" for c in chars]
                else:
                    alias_char = "s" if kind == "series" else "a"
                    clause = where.replace("t.name", f"{alias_char}.name")
                    args = [f"%{c}%" for c in chars]
                try:
                    rows = conn.execute(sql.format(where=clause), args).fetchall()
                except sqlite3.Error:
                    continue
                for r in rows:
                    name = str(r["name"] or "")
                    if not name or (kind, name) in seen:
                        continue
                    # 重合度 = **我打的字有几个出现在这个名字里**（而不是占名字多长）。
                    # 后者会让「艺人」这种两字名里撞上「人」就拿到 0.5 分，
                    # 把真答案（人妻 = 1.0）挤掉。分母用查询长度更符合直觉。
                    shared = len({c for c in chars if c in name})
                    if shared < min_shared:
                        continue
                    score = shared / max(1, len(chars))
                    seen.add((kind, name))
                    out.append({"kind": kind, "target": name,
                                "films": int(r["films"] or 0), "_score": score})
    except sqlite3.Error as exc:
        log(f"WARN 别名候选: {exc}")
    # 我打的字覆盖得多 > 片多 > 名字短
    out.sort(key=lambda x: (-x["_score"], -x["films"], len(str(x["target"]))))
    picked: list[dict] = []
    for kind in ("tag", "series", "actor"):
        per = [x for x in out if x["kind"] == kind][:limit]
        picked.extend(per)
    picked.sort(key=lambda x: (-x["_score"], -x["films"]))
    picked = picked[:limit]
    for item in picked:
        item.pop("_score", None)
    return picked


def record_search_miss(raw: str, q_norm: str, hits: int) -> None:
    """记下「严格搜索也几乎没结果」的词，供别名页当待办。

    只在 `qmode != or` 时调用：客户端放宽重试那次结果会变多，记下来就是假账。
    """
    q = re.sub(r"\s+", " ", (q_norm or "")).strip().lower()
    if len(q) < 2 or hits > _MISS_MAX_HITS:
        return
    now = now_iso()
    try:
        with user_db() as conn:
            conn.execute(
                "INSERT INTO search_miss(q, raw, hits, times, first_at, last_at) "
                "VALUES(?,?,?,1,?,?) ON CONFLICT(q) DO UPDATE SET "
                "raw = excluded.raw, hits = excluded.hits, times = times + 1, "
                "last_at = excluded.last_at",
                (q, (raw or q_norm or q)[:60], int(hits), now, now))
            conn.execute(
                "DELETE FROM search_miss WHERE q NOT IN ("
                "SELECT q FROM search_miss ORDER BY last_at DESC LIMIT ?)", (_MISS_KEEP,))
    except sqlite3.Error as exc:
        log(f"WARN 记录搜索落空: {exc}")


def _alias_target_exists(kind: str, target: str) -> tuple[bool, list[str]]:
    """目标名在库里存不存在；不存在时给几个最像的名字（错一个字的常见情况）。"""
    sql = {
        "tag": "SELECT name FROM tags WHERE name = ?",
        "series": "SELECT name FROM series WHERE name = ?",
        "actor": "SELECT name FROM actors WHERE name = ?",
    }.get(kind)
    if not sql:
        return False, []
    try:
        with amane_db() as conn:
            if conn.execute(sql, (target,)).fetchone():
                return True, []
            key = target[:6] or target
            hint = [str(r[0]) for r in conn.execute(
                sql.replace("name = ?", "name LIKE ?"), (f"%{key}%",)).fetchall()[:4]]
        return False, hint
    except sqlite3.Error:
        return False, []


def search_clauses(token: str) -> list[tuple[str, tuple]]:
    """一个词能扩出的全部「名字类」条件：拼音命中 + 俗称补丁（去重）。

    **上限 6 条**：这些条件在 SQL 里是一个大 OR，每条带一个 `IN (SELECT …)`，
    实测 20 多条时 `browse?q=jr` 会从 60ms 涨到 190ms。按 pinyin_names 的排序
    （首字母全等 > 前缀 > 其它）取前 6 个名字，噪音和耗时都下来了。

    **俗称排在最前**：它只有几条、而且是人工挑的高精度映射，被拼音挤掉就等于没生效
    （`ntr` 曾因为槽位被别人占满，丢掉了 `寝取` 那 23 部）。
    """
    merged: list[tuple[str, tuple]] = []
    seen: set[tuple] = set()
    for cond, vals in alias_clauses(token) + pinyin_clauses(token):
        key = (cond, tuple(vals))
        if key in seen:
            continue
        seen.add(key)
        merged.append((cond, vals))
        if len(merged) >= _PY_MAX_CLAUSES:
            break
    return merged


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
        # 拼音检索派生表（2.5.1）：只收 tag/series/actor 的中文名。
        # 内容由 amane 主库算出来，所以整表可以随时 DROP 重建（见 build_name_pinyin）。
        conn.executescript(NAME_PINYIN_DDL)
        # 检索别名（2.5.1.6）：俗称 → 库里真有的名字，形状对齐 amane 的 actor_aliases。
        # 存在 user.db 而不是 amane.db：amane.db 是只读的上游库，我们只做加法。
        # 出厂默认在 data/alias.tsv，这张表只放用户/管理员自己加的（并集生效）。
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS search_alias (
                alias      TEXT NOT NULL,
                kind       TEXT NOT NULL,
                target     TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(alias, kind, target)
            );
            -- 「搜了但没搜到」的词（2.5.1.11）。别名这张表的真正难点不是怎么加，
            -- 是**用户根本不知道该加什么** —— 让他凭记忆维护一张表不现实。
            -- 所以反过来：把「严格搜索后结果 < 3 条」的词记下来，进别名页就是待办清单。
            CREATE TABLE IF NOT EXISTS search_miss (
                q        TEXT PRIMARY KEY,   -- 归一化键（小写 + 压空格 + 繁转简）
                raw      TEXT NOT NULL,      -- 最后一次输入的原文（展示用）
                hits     INTEGER NOT NULL,
                times    INTEGER NOT NULL DEFAULT 1,
                first_at TEXT NOT NULL,
                last_at  TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_search_miss_last ON search_miss(last_at DESC);
            -- 折叠别名（2.5.1.18）：库里「写法不同、折叠后一样」的名字。
            -- 例：标签「女捜查官」折成「女搜查官」，于是 alias=女搜查官 → target=女捜查官。
            -- 由 build_name_pinyin 从 amane 主库扫出来、随索引重建；**不进 alias.tsv**
            -- （出厂别名要跟代码走、与库无关，而这张表天生依赖当前库里的名字）。
            CREATE TABLE IF NOT EXISTS name_variant (
                alias  TEXT NOT NULL,
                kind   TEXT NOT NULL,
                target TEXT NOT NULL,
                PRIMARY KEY(alias, kind, target)
            );
            CREATE INDEX IF NOT EXISTS idx_name_variant_alias ON name_variant(alias);
            """
            + STATS_DDL
            + TIER_DDL
            + META_OVERRIDE_DDL
            + COVER_OVERRIDE_DDL
            + CAST_DDL)
        # 派生表结构升级（2.5.3 加 scope / 按日存热度）：老库先 DROP 再建，聚合读时重算
        stats_schema_sync(conn)
        # 加列不能靠 CREATE IF NOT EXISTS：老库那张表已经在了，得显式 ALTER
        cols = {r[1] for r in conn.execute("PRAGMA table_info(tier_snapshot)").fetchall()}
        if cols and "title" not in cols:
            conn.execute("ALTER TABLE tier_snapshot ADD COLUMN title TEXT NOT NULL DEFAULT ''")
        # 2.5.5.20：封面同时存一张 16:9 横版（模糊背景 + 完整海报，不裁切）。
        # 竖版位（海报）用 gif/原图，横版位（继续观看 / 每日推荐 / 横幅）用它 ——
        # 否则竖图塞进横框只剩中间一条，用户看到的就是「局部截图」。
        for table in ("meta_override", "cover_override"):
            tcols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
            if tcols and "wide" not in tcols:
                conn.execute(
                    f"ALTER TABLE {table} ADD COLUMN wide TEXT NOT NULL DEFAULT ''")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------------------- #
# 播放采样与报表统计（2.5.3）
#
# 为什么另起一张表：`history` 是**覆盖式**的（一片一行，只留最后位置）。拖一下进度、
# 再看一遍，之前那次就被盖掉，写进去改不回来 —— 用它算「最常看哪一段」永远算不准，
# 而且越用越偏。所以采样改成**只追加**：每次上报新增一行，永不改旧行；口径错了就
# 按新口径整批重算，不靠猜。
#
# 分层（派生层随时可 DROP 重建，见 POST /api/user/stats/rebuild）：
#   play_progress  原始采样（只 INSERT；明细保留 STATS_KEEP_DAYS 天）
#   stats_daily    按 (日, 片)：观看秒数 / 采样数 / 最大位置 / 当日是否看完
#   stats_hour     按 (日, 小时)：时段与星期分布
#   stats_heat     按 (片, 5% 分桶)：热度条；metadata_id = 0 那一份是全库合计
#   stats_meta     口径版本、已消费到的采样 id、清洗计数（JSON）
#
# 归日/归时一律用**客户端上报的本地日期与小时**（local_date / local_hour）：
# 容器时区是 UTC，按服务端算会把「同一晚看的两部」劈成两天。老客户端不带这两个
# 字段时按服务端本地时间兜底，并在 quality 里体现为估算。
# --------------------------------------------------------------------------- #

STATS_VERSION = 2              # 口径版本：算法一改就 +1，页面标注口径版本
STATS_SCHEMA = 2               # 派生表**结构**版本：结构变了先 DROP 再重建（派生数据可重算）
STATS_KEEP_DAYS = 730          # 明细保留 2 年（聚合结果不受影响）
STATS_JUMP_SECS = 1800.0       # 一次前进超过 30 分钟 = 拖动，不算观看
STATS_HEAT_BUCKETS = 20        # 热度条分桶数（每桶 5%）
STATS_MIN_FILMS = 3            # 少于这个部数只算「数据少」，页面显示占位
STATS_SCOPES = ("real", "test")  # 观看口径：真实数据 / 测试数据（src=test 的采样）

STATS_DDL = """
CREATE TABLE IF NOT EXISTS play_progress (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metadata_id INTEGER NOT NULL,
    at          TEXT NOT NULL,                -- 服务端收到的 UTC 时间（排重/排序用）
    local_date  TEXT NOT NULL,                -- 客户端本地日期 YYYY-MM-DD（归日唯一依据）
    local_hour  INTEGER NOT NULL DEFAULT -1,  -- 客户端本地小时 0-23（-1 = 不知道）
    position    REAL NOT NULL DEFAULT 0,
    duration    REAL NOT NULL DEFAULT 0,
    src         TEXT NOT NULL DEFAULT 'app',   -- app = 专用采样；legacy = history 顺带采；test = 测试数据
    trusted     INTEGER NOT NULL DEFAULT 1    -- 0 = 结构性垃圾（时长为 0、位置为负），不进统计
);
CREATE INDEX IF NOT EXISTS idx_pp_mid  ON play_progress(metadata_id, at);
CREATE INDEX IF NOT EXISTS idx_pp_date ON play_progress(local_date);

CREATE TABLE IF NOT EXISTS stats_daily (
    date        TEXT NOT NULL,
    metadata_id INTEGER NOT NULL,
    scope       TEXT NOT NULL DEFAULT 'real',  -- real / test：测试数据与真实数据分开算
    secs        REAL NOT NULL DEFAULT 0,
    samples     INTEGER NOT NULL DEFAULT 0,
    max_pos     REAL NOT NULL DEFAULT 0,
    duration    REAL NOT NULL DEFAULT 0,
    finished    INTEGER NOT NULL DEFAULT 0,
    version     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(date, metadata_id, scope)
);

CREATE TABLE IF NOT EXISTS stats_hour (
    local_date TEXT NOT NULL,
    local_hour INTEGER NOT NULL,
    scope      TEXT NOT NULL DEFAULT 'real',
    secs       REAL NOT NULL DEFAULT 0,
    samples    INTEGER NOT NULL DEFAULT 0,
    version    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(local_date, local_hour, scope)
);

-- 热度按「日」存：时间范围一换就要重算占比，汇总成一行就没法筛了
CREATE TABLE IF NOT EXISTS stats_heat (
    local_date  TEXT NOT NULL,
    metadata_id INTEGER NOT NULL,   -- 0 表示全库合计
    bucket      INTEGER NOT NULL,   -- 0..STATS_HEAT_BUCKETS-1
    scope       TEXT NOT NULL DEFAULT 'real',
    secs        REAL NOT NULL DEFAULT 0,
    version     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(local_date, metadata_id, bucket, scope)
);

CREATE TABLE IF NOT EXISTS stats_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

# 派生表的索引单独放着：老库升级时要先 DROP 再建，索引不能跟建表语句一起跑
# （老表没有 scope 列时会 "no such column: scope"，服务直接起不来）。
STATS_INDEX_DDL = """
CREATE INDEX IF NOT EXISTS idx_stats_daily_mid ON stats_daily(metadata_id);
CREATE INDEX IF NOT EXISTS idx_stats_heat_mid  ON stats_heat(metadata_id, scope);
"""

_STATS_LOCK = threading.Lock()


def _stats_known_ids() -> set:
    """库里真实存在的 metadata_id。已删影片的采样保留（不删），但不进任何榜。"""
    with amane_db() as conn:
        return {r[0] for r in conn.execute("SELECT id FROM metadata")}


def _local_parts(body: dict) -> tuple[str, int]:
    """从上报里取「本地日期 + 本地小时」。

    优先 `local_date` / `local_hour`（客户端自己的时区）；退而用 `at` 里的日期时间
    （带偏移量的 ISO 串，如 `2026-11-11T23:40:12+08:00`）；都没有才用服务端本地时间。
    """
    hour = -1
    try:
        hour = int(body.get("local_hour"))
    except (TypeError, ValueError):
        hour = -1
    if hour < 0 or hour > 23:
        hour = -1
    raw_date = str(body.get("local_date") or "")[:10]
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw_date or ""):
        return raw_date, hour
    at = str(body.get("at") or "")
    hit = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2})", at)
    if hit:
        return hit.group(1), (hour if hour >= 0 else int(hit.group(2)))
    now = datetime.now()
    return now.strftime("%Y-%m-%d"), (hour if hour >= 0 else now.hour)


def stats_scope_of(src: str) -> str:
    """采样来源 → 统计口径。`src=test` 是给测试版看的模拟数据，绝不混进真实数字。"""
    return "test" if (src or "").strip().lower() == "test" else "real"


def stats_schema_sync(conn: sqlite3.Connection) -> bool:
    """派生表结构升级：结构版本变了就整表 DROP 再建（派生数据本来就能从采样重算）。

    `CREATE TABLE IF NOT EXISTS` 改不了老表的列，所以加列/改主键必须显式 DROP —— 否则
    老库升级上来会「看起来有表、写进去报错」。丢掉的是聚合结果，下次读端点自动重建。
    """
    row = conn.execute("SELECT value FROM stats_meta WHERE key='schema'").fetchone()
    try:
        have = int(row["value"]) if row else 0
    except (TypeError, ValueError):
        have = 0
    if have == STATS_SCHEMA:
        conn.executescript(STATS_INDEX_DDL)
        return False
    for table in ("stats_daily", "stats_hour", "stats_heat"):
        conn.execute(f"DROP TABLE IF EXISTS {table}")
    conn.executescript(STATS_DDL)
    conn.executescript(STATS_INDEX_DDL)
    conn.execute(
        "INSERT INTO stats_meta(key, value) VALUES('schema', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(STATS_SCHEMA),))
    log(f"统计派生表重建结构 schema={STATS_SCHEMA}（旧聚合已丢弃，读时自动重算）")
    return True


def hidden_facet_ids(kind: str = "tag") -> set:
    """已被用户隐藏的分类 id（`facet_hidden`，facets 扩展写的那张表）。

    统计要**跟列表/筛选同一口径**：用户隐藏了「DMM」这类没意义的标签，就不该在
    标签榜里再看到它。表由扩展建，所以这里是软依赖 —— 表不在就当没隐藏。
    """
    try:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT facet_id FROM facet_hidden WHERE kind = ?", (kind,)).fetchall()
    except sqlite3.Error:
        return set()
    out = set()
    for r in rows:
        try:
            out.add(int(r[0]))
        except (TypeError, ValueError):
            continue
    return out


def stats_range(query: dict) -> tuple[str, str]:
    """`from` / `to`（YYYY-MM-DD，含两端）；非法或缺失就当没限制。

    所有报表都吃这两个参数 —— **除了年报这类天生固定窗口的**，凡「按时间算出来」的
    数字都应该跟着范围走，不许把全部历史一股脑摊进来。
    """
    def pick(key: str) -> str:
        raw = (query.get(key) or [""])[0].strip()[:10]
        return raw if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw or "") else ""

    start, end = pick("from"), pick("to")
    if start and end and start > end:
        start, end = end, start
    return start, end


def stats_scope(query: dict) -> str:
    """`scope`：`real`（默认，真实观看）/ `test`（模拟测试数据）/ `all`（两者合计）。"""
    raw = ((query.get("scope") or [""])[0] or "").strip().lower()
    return raw if raw in ("real", "test", "all") else "real"


def stats_range_sql(column: str, start: str, end: str) -> tuple[str, list]:
    """拼 `AND <column> BETWEEN ? AND ?`；没范围就返回空串。"""
    where = ""
    args: list = []
    if start:
        where += f" AND {column} >= ?"
        args.append(start)
    if end:
        where += f" AND {column} <= ?"
        args.append(end)
    return where, args


def stats_scope_sql(column: str, scope: str) -> tuple[str, list]:
    if scope in STATS_SCOPES:
        return f" AND {column} = ?", [scope]
    return "", []


def add_sample(conn: sqlite3.Connection, metadata_id: int, position: float, duration: float,
               local_date: str, local_hour: int, src: str = "app") -> int:
    """只追加一行采样。**没有任何 UPDATE** —— 这是整层的根约定。"""
    # trusted=0 只标「结构性垃圾」：时长为 0 或位置为负。拖动、回拖这类可疑但
    # 可能合法的采样仍然 trusted=1，由 rebuild 按 delta 判定 —— 不然重算也说不出话。
    trusted = 1 if (duration > 0 and position >= 0) else 0
    cur = conn.execute(
        "INSERT INTO play_progress(metadata_id, at, local_date, local_hour, position, duration, src, trusted) "
        "VALUES(?,?,?,?,?,?,?,?)",
        (int(metadata_id), now_iso(), local_date, int(local_hour),
         round(float(position), 1), round(float(duration), 1), src, trusted),
    )
    return cur.lastrowid


def rebuild_stats() -> dict:
    """按当前口径把派生层整批重建（幂等）。

    清洗规则（对应 docs/TASKS/2.5.3-report-next.md §2，判重口径本版有调整）：
      * 位置没变的重复上报（客户端重试 / 暂停中反复上报）只留一条；
      * 同一天同一部片的**首次**采样不计时长（不知道上次看到哪，不能凭空算）；
      * delta 在 (0, 1800] 计入观看；> 1800 视为拖动、<= 0 视为回拖，都不计时长；
      * 时长为 0 / trusted=0 / 找不到对应影片 → 不进任何统计（找不到的单独计数）。
    """
    started = time.time()
    with _STATS_LOCK:
        with user_db() as conn:
            cutoff = (date.today() - timedelta(days=STATS_KEEP_DAYS)).strftime("%Y-%m-%d")
            pruned = conn.execute(
                "DELETE FROM play_progress WHERE local_date < ?", (cutoff,)).rowcount
            rows = conn.execute(
                "SELECT metadata_id, at, local_date, local_hour, position, duration, trusted, src "
                "FROM play_progress ORDER BY metadata_id, local_date, at, id").fetchall()
            known = _stats_known_ids()

            daily: dict = {}
            hourly: dict = {}
            heat: dict = {}
            quality = {"samples": len(rows), "dropped": 0, "jump": 0,
                       "rewind": 0, "unknown": 0, "dup": 0, "pruned": pruned,
                       "real": 0, "test": 0}
            prev_pos: dict = {}

            for r in rows:
                mid = r["metadata_id"]
                day = (r["local_date"] or "")[:10]
                if r["trusted"] == 0 or r["duration"] <= 0 or not day:
                    quality["dropped"] += 1
                    continue
                if mid not in known:
                    quality["unknown"] += 1
                    continue

                # 口径分家：测试数据与真实数据各算一套，页面上切换看，绝不混在一起
                scope = stats_scope_of(r["src"])
                quality[scope] += 1

                dur = float(r["duration"])
                pos = min(max(float(r["position"]), 0.0), dur)
                key = (mid, day, scope)
                last = prev_pos.get(key)
                prev_pos[key] = pos
                secs = 0.0
                if last is not None:
                    delta = pos - last
                    if abs(delta) < 0.5:
                        # 进度没动 = 同一条采样被重发（客户端重试 / 暂停中反复上报）。
                        # 这里刻意按「位置是否变化」判重，而不是按分钟：正常播放时
                        # 一分钟内本来就有好几条位置不同的采样，按分钟会把它们全吃掉。
                        quality["dup"] += 1
                        continue
                    if delta > STATS_JUMP_SECS:
                        quality["jump"] += 1
                    elif delta <= 0:
                        quality["rewind"] += 1
                    else:
                        secs = delta

                d = daily.setdefault((day, mid, scope), {"secs": 0.0, "samples": 0,
                                                         "max_pos": 0.0, "duration": dur})
                d["secs"] += secs
                d["samples"] += 1
                d["max_pos"] = max(d["max_pos"], pos)
                d["duration"] = max(d["duration"], dur)

                hour = int(r["local_hour"]) if r["local_hour"] is not None else -1
                h = hourly.setdefault((day, hour, scope), {"secs": 0.0, "samples": 0})
                h["secs"] += secs
                h["samples"] += 1

                # 热度按日存：换了时间范围要重新算占比，只留一行合计就筛不动了
                bucket = min(STATS_HEAT_BUCKETS - 1, int(pos / dur * STATS_HEAT_BUCKETS))
                heat[(day, mid, bucket, scope)] = heat.get((day, mid, bucket, scope), 0.0) + secs
                heat[(day, 0, bucket, scope)] = heat.get((day, 0, bucket, scope), 0.0) + secs

            conn.execute("DELETE FROM stats_daily")
            conn.executemany(
                "INSERT INTO stats_daily(date, metadata_id, scope, secs, samples, max_pos, duration, "
                "finished, version) VALUES(?,?,?,?,?,?,?,?,?)",
                [(day, mid, scope, round(v["secs"], 1), v["samples"], round(v["max_pos"], 1),
                  round(v["duration"], 1),
                  1 if (v["duration"] > 0 and v["max_pos"] >= v["duration"] * FINISH_RATIO) else 0,
                  STATS_VERSION) for (day, mid, scope), v in daily.items()])
            conn.execute("DELETE FROM stats_hour")
            conn.executemany(
                "INSERT INTO stats_hour(local_date, local_hour, scope, secs, samples, version) "
                "VALUES(?,?,?,?,?,?)",
                [(day, hour, scope, round(v["secs"], 1), v["samples"], STATS_VERSION)
                 for (day, hour, scope), v in hourly.items()])
            conn.execute("DELETE FROM stats_heat")
            conn.executemany(
                "INSERT INTO stats_heat(local_date, metadata_id, bucket, scope, secs, version) "
                "VALUES(?,?,?,?,?,?)",
                [(day, mid, bucket, scope, round(secs, 1), STATS_VERSION)
                 for (day, mid, bucket, scope), secs in heat.items()])

            max_id = conn.execute(
                "SELECT COALESCE(MAX(id), 0) FROM play_progress").fetchone()[0]
            meta = {"version": str(STATS_VERSION), "last_id": str(max_id),
                    "quality": json.dumps(quality, ensure_ascii=False),
                    "built_at": now_iso()}
            for key, value in meta.items():
                conn.execute(
                    "INSERT INTO stats_meta(key, value) VALUES(?,?) "
                    "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    quality["days"] = len({k[0] for k in daily})
    quality["films"] = len({k[1] for k in daily})
    quality["ms"] = int((time.time() - started) * 1000)
    return quality


def stats_stale() -> bool:
    """口径变了或有新采样 → 需要重建。"""
    with user_db() as conn:
        ver = conn.execute("SELECT value FROM stats_meta WHERE key='version'").fetchone()
        last = conn.execute("SELECT value FROM stats_meta WHERE key='last_id'").fetchone()
        max_id = conn.execute("SELECT COALESCE(MAX(id), 0) FROM play_progress").fetchone()[0]
    try:
        ver_n = int(ver["value"]) if ver else 0
        last_n = int(last["value"]) if last else -1
    except (TypeError, ValueError):
        return True
    return ver_n != STATS_VERSION or last_n != max_id


def ensure_stats() -> None:
    """读统计前调一次：过期就重建。失败不抛（宁可给旧的，也别让页面 500）。"""
    try:
        if stats_stale():
            quality = rebuild_stats()
            log(f"统计重建 version={STATS_VERSION} samples={quality['samples']} "
                f"days={quality['days']} films={quality['films']} {quality['ms']}ms")
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 统计重建失败: {exc}")


def stats_quality() -> dict:
    with user_db() as conn:
        row = conn.execute("SELECT value FROM stats_meta WHERE key='quality'").fetchone()
    if not row:
        return {}
    try:
        data = json.loads(row["value"])
    except (TypeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def stats_env(ok: bool, confidence: str, data: dict, reason: str = "",
              range_=None, scope: str = "") -> dict:
    """统一信封：页面只认 `ok` 与 `confidence`，不该看见 0 却以为真的没看过。

    `range` / `scope` 原样回显这次用的是哪个时间范围、哪个口径 —— 页面要拿它显示
    「2026-09-01 ~ 2026-11-11 · 真实数据」，用户才不会把两个范围的结果看串。
    """
    out = {"ok": ok, "version": STATS_VERSION, "confidence": confidence, "data": data}
    if range_ is not None:
        start, end = range_
        out["range"] = {"from": start or None, "to": end or None}
    if scope:
        out["scope"] = scope
    if not ok:
        out["reason"] = reason or "数据还在积累"
    return out


def stats_confidence(films: int, days: int) -> str:
    if films >= STATS_MIN_FILMS and days >= 7:
        return "full"
    if films > 0:
        return "sparse"
    return "estimate"


def stats_top_items(kind: str, film_secs: dict, limit: int, hidden: set | None = None) -> list[dict]:
    """偏好榜：按「看过的部数 + 时长」排。

    名字一律**现取**（`stats_*` 里只存 id）：标签改名、演员合并、影片删掉都不会把
    历史弄丢 —— 这也正是把元数据和统计分开存的原因。

    `hidden` = 用户隐藏的分类 id：**标签榜要跟标签列表同一口径**，用户已经在列表里
    藏掉的东西（DMM 这类无意义标签），不该在统计榜里偷偷冒出来。
    """
    ids = list(film_secs)
    if not ids:
        return []
    hidden = hidden or set()
    agg: dict = {}
    with amane_db() as conn:
        for start in range(0, len(ids), 400):
            chunk = ids[start:start + 400]
            marks = ",".join("?" * len(chunk))
            if kind == "actor":
                sql = ("SELECT ma.metadata_id AS mid, a.id AS nid, a.name AS name "
                       "FROM metadata_actors ma JOIN actors a ON a.id = ma.actor_id "
                       f"WHERE ma.metadata_id IN ({marks})")
            elif kind == "tag":
                sql = ("SELECT mt.metadata_id AS mid, t.id AS nid, t.name AS name "
                       "FROM metadata_tags mt JOIN tags t ON t.id = mt.tag_id "
                       f"WHERE mt.metadata_id IN ({marks})")
            else:  # studio：metadata 上直接是名字，没有 id 可用
                sql = ("SELECT m.id AS mid, 0 AS nid, m.studio AS name FROM metadata m "
                       f"WHERE m.id IN ({marks}) AND m.studio IS NOT NULL AND m.studio != ''")
            for row in conn.execute(sql, chunk):
                if kind == "tag" and int(row["nid"]) in hidden:
                    continue
                key = (row["name"], row["nid"])
                slot = agg.setdefault(key, {"name": row["name"], "id": row["nid"],
                                            "films": 0, "seconds": 0.0})
                slot["films"] += 1
                slot["seconds"] += film_secs.get(row["mid"], 0.0)

    ranked = sorted(agg.values(), key=lambda v: (v["seconds"], v["films"]), reverse=True)
    out = []
    for v in ranked[:limit]:
        out.append({"name": v["name"], "id": v["id"], "films": v["films"],
                    "seconds": round(v["seconds"]),
                    "hours": round(v["seconds"] / 3600, 1)})
    return out


def tag_hygiene_candidates(limit: int = 12) -> list[dict]:
    """「该隐藏的标签」候选：给用户一份待办，而不是让他凭记忆想哪些没用。

    判据只有**字面与覆盖率**，不猜语义 —— 2.5.1.17 试过按编辑距离找近似名，1880 对
    几乎全错（`中出`/`乞求中出`、`M女`/`美少女`），那套已整段删掉。这里同理：
    命中不了就宁可不提，提错了用户会连真标签一起藏掉。

    四种理由：
      * `near_all`    几乎每部片都有（覆盖率 ≥30% 且 ≥50 部）—— 没有区分度；
      * `studio_name` 与某个厂牌同名 —— 多半是刮削把厂牌塞进了标签；
      * `brand_like`  纯大写/编号式，或 DMM / FANZA 这类站点名；
      * 已被隐藏的直接不出现在候选里。
    """
    hidden = hidden_facet_ids("tag")
    with amane_db() as conn:
        total = conn.execute("SELECT COUNT(*) FROM metadata").fetchone()[0] or 0
        rows = conn.execute(
            "SELECT t.id AS id, t.name AS name, COUNT(mt.metadata_id) AS films "
            "FROM tags t LEFT JOIN metadata_tags mt ON mt.tag_id = t.id "
            "GROUP BY t.id").fetchall()
        studios = {str(r[0]) for r in conn.execute("SELECT name FROM studios").fetchall()
                   if r[0]}

    total = max(int(total), 1)
    brand = re.compile(r"(?i)^(dmm|fanza|jav|mgstage|sod|prestige|moodyz|ideapocket)$")
    ascii_name = re.compile(r"^[A-Za-z0-9_.\-& ]{3,}$")
    lower_word = re.compile(r"[a-z]{4,}")

    out = []
    for r in rows:
        try:
            tid, films = int(r["id"]), int(r["films"] or 0)
        except (TypeError, ValueError):
            continue
        name = str(r["name"] or "").strip()
        if not name or tid in hidden:
            continue
        ratio = films / total
        reason = ""
        if films >= 50 and ratio >= 0.30:
            reason = "near_all"
        elif name in studios:
            reason = "studio_name"
        elif brand.match(name) or (ascii_name.match(name) and not lower_word.search(name)):
            reason = "brand_like"
        if not reason:
            continue
        out.append({"id": tid, "name": name, "films": films,
                    "coverage": round(ratio, 3), "reason": reason})

    out.sort(key=lambda v: (-v["coverage"], -v["films"]))
    return out[:limit]


# --------------------------------------------------------------------------- #
# 报表 v2（2.5.3 第二批）：弃片 / 流失曲线 / 吃灰 / 转化漏斗 / 评分冲突
#
# 全部只读**派生层** `stats_daily`（它已经是「按日 × 按片」的聚合）加两张小表
# （`favorites` / `user_ratings`），**不碰 `play_progress` 明细** —— 明细几十万行，
# 每开一次页面扫一遍会明显变慢。派生层每次 rebuild 都会跟着更新，所以不另建表。
# --------------------------------------------------------------------------- #

STATS_OPEN_SECS = 60.0       # 「打开了」的门槛：至少看了 1 分钟
STATS_DROP_DAYS = 7          # 「打开后 7 天没再动」才算弃
STATS_MIN_SAMPLE = 5         # 样本 <5 的实体不进榜（防「1 投 1 弃」排第一）


def stats_films(conn, start: str, end: str, scope: str) -> dict:
    """按片聚合：首末日期、秒数、看了几天、最好完成率。"""
    dw, dargs = stats_range_sql("date", start, end)
    sw, sargs = stats_scope_sql("scope", scope)
    rows = conn.execute(
        "SELECT metadata_id, MIN(date) AS first_day, MAX(date) AS last_day, "
        "COALESCE(SUM(secs), 0) AS secs, COUNT(*) AS days, MAX(finished) AS finished, "
        "MAX(CASE WHEN duration > 0 THEN max_pos / duration ELSE 0 END) AS ratio "
        f"FROM stats_daily WHERE 1=1{dw}{sw} GROUP BY metadata_id",
        dargs + sargs).fetchall()
    out = {}
    for r in rows:
        out[int(r["metadata_id"])] = {
            "first": r["first_day"], "last": r["last_day"],
            "secs": float(r["secs"] or 0), "days": int(r["days"] or 0),
            "finished": int(r["finished"] or 0), "ratio": float(r["ratio"] or 0),
        }
    return out


def stats_entity_of(kind: str, mids) -> dict:
    """mid → [(名字, id)]；按 400 一段查，避免一条 SQL 的占位符太多。"""
    ids = list(mids)
    out: dict = {}
    if not ids:
        return out
    with amane_db() as conn:
        for start in range(0, len(ids), 400):
            chunk = ids[start:start + 400]
            marks = ",".join("?" * len(chunk))
            if kind == "actor":
                sql = ("SELECT ma.metadata_id AS mid, a.id AS nid, a.name AS name "
                       "FROM metadata_actors ma JOIN actors a ON a.id = ma.actor_id "
                       f"WHERE ma.metadata_id IN ({marks})")
            elif kind == "tag":
                sql = ("SELECT mt.metadata_id AS mid, t.id AS nid, t.name AS name "
                       "FROM metadata_tags mt JOIN tags t ON t.id = mt.tag_id "
                       f"WHERE mt.metadata_id IN ({marks})")
            else:  # studio：metadata 上只有名字
                sql = ("SELECT m.id AS mid, 0 AS nid, m.studio AS name FROM metadata m "
                       f"WHERE m.id IN ({marks}) AND m.studio IS NOT NULL AND m.studio != ''")
            for row in conn.execute(sql, chunk):
                out.setdefault(int(row["mid"]), []).append(
                    (str(row["name"]), int(row["nid"])))
    return out


def stats_day_ratios(conn, scope: str) -> dict:
    """mid → 按日期排好的完成率序列（判定「重看」用）。"""
    sw, sargs = stats_scope_sql("scope", scope)
    rows = conn.execute(
        "SELECT metadata_id, date, MAX(max_pos) AS pos, MAX(duration) AS dur "
        f"FROM stats_daily WHERE 1=1{sw} GROUP BY metadata_id, date "
        "ORDER BY metadata_id, date", sargs).fetchall()
    out: dict = {}
    for r in rows:
        dur = float(r["dur"] or 0)
        ratio = min(float(r["pos"] or 0) / dur, 1.0) if dur > 0 else 0.0
        out.setdefault(int(r["metadata_id"]), []).append((r["date"], ratio))
    return out


def stats_replays(series) -> int:
    """重看次数：完成率从 ≥0.95 掉回 <0.2 的那些「重新开始」。"""
    count = 0
    for i in range(1, len(series)):
        if series[i - 1][1] >= FINISH_RATIO and series[i][1] < 0.2:
            count += 1
    return count


def titles_of(ids) -> dict:
    """id → {number,title,vote}（榜单只要这几个字，别整包 `item_of`）。

    注意列名是 `scores`（复数，上游把多个站点的分存成一列/一个数），写成 `score`
    会直接 `no such column` —— 这个坑在统计里踩过一次。
    """
    head = [int(i) for i in ids][:200]
    if not head:
        return {}
    out = {}
    with amane_db() as conn:
        marks = ",".join("?" * len(head))
        rows = conn.execute(
            f"SELECT id, number, title, scores FROM metadata WHERE id IN ({marks})",
            head).fetchall()
    for r in rows:
        # `scores` 是 JSON 串（`{"giga": 3.0, "javdb": 4.2}`），不是一个数 ——
        # 直接 float() 会炸。这里取各站均值，没有数值就记 0。
        vote = 0.0
        try:
            raw = json.loads(r["scores"] or "{}")
            if isinstance(raw, dict):
                vals = [float(v) for v in raw.values() if isinstance(v, (int, float))]
                if vals:
                    vote = sum(vals) / len(vals)
            elif isinstance(raw, (int, float)):
                vote = float(raw)
        except (TypeError, ValueError):
            vote = 0.0
        out[int(r["id"])] = {"number": r["number"] or "", "title": r["title"] or "",
                             "vote": vote}
    return out


# --------------------------------------------------------------------------- #
# Tier 图（2.5.4）：把星级排成五档，一次「生成」= 一张快照
#
# 为什么是快照而不是每次现算：图是要存历史、挑一张挂在统计页上的（用户能留几张对比）。
# 快照存**筛选条件 + 每档的条目 id/展示图/文字**，之后库里的评分变了也不动这张图 ——
# 要更新就重新生成，旧的自然留在历史里。图只存 URL，不存二进制。
#
# 五档固定（用户定，不许改档名）：5 夯 / 4 顶级 / 3 人上人 / 2 NPC / 1 拉完了。
# 分档、排序、上限、默认条件**全在服务端算**，客户端只渲染（契约见
# `docs/TASKS/2.5.4-tierlist.md` §4）。
# --------------------------------------------------------------------------- #

TIER_VERSION = 1
TIER_SLOTS = ((5, "夯"), (4, "顶级"), (3, "人上人"), (2, "NPC"), (1, "拉完了"))
TIER_KINDS = ("film", "actor", "director", "studio", "tag", "series")
TIER_KIND_NAMES = {"film": "影片", "actor": "演员", "director": "导演",
                   "studio": "厂牌", "tag": "标签", "series": "系列"}
TIER_LIMIT_DEFAULT = 20
TIER_LIMIT_MAX = 60

TIER_DDL = """CREATE TABLE IF NOT EXISTS tier_snapshot (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    filters    TEXT NOT NULL,
    payload    TEXT NOT NULL,
    summary    TEXT NOT NULL,
    -- 图名（2.5.4.10）：用户自己填就用自己的，留空由 tier_title() 按条件+分布起名
    title      TEXT NOT NULL DEFAULT '',
    thumbs     TEXT NOT NULL,
    created_at TEXT NOT NULL,
    picked     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tier_created ON tier_snapshot(created_at DESC);
"""

# 2.5.5 元数据覆盖层：只存**被改过的字段**，amane 库一个字都不写。
# 为什么不写回库：库是刮削产物，写回去下次刮削就冲掉，删了也不好找回。
META_OVERRIDE_DDL = """
CREATE TABLE IF NOT EXISTS meta_override (
    metadata_id INTEGER PRIMARY KEY,
    fields      TEXT NOT NULL DEFAULT '{}',   -- JSON：只含改过的键
    cover       TEXT NOT NULL DEFAULT '',     -- 站内相对路径 /api/user/photo/xxx.gif
    updated_at  TEXT NOT NULL
);
"""

# 2.5.6 投屏令牌：电视 / 盒子只认这一种「只能读媒体」的短时凭证。
#
# 为什么不能直接把主 token 交给电视：那是万能钥匙（能改覆盖层、能删快照），
# 一旦进了电视的日志或第三方 App 就等于泄露。这里发的是**只读媒体专用**的：
# 仅 `/play` `/streams` `/photo` `/studio-logo` 四条 GET/HEAD 路径认它，别的一律 401。
CAST_DDL = """
CREATE TABLE IF NOT EXISTS cast_token (
    token      TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cast_exp ON cast_token(expires_at);
"""

# 2.5.5.4 分类封面：系列 / 标签 / 厂牌 / 演员 / 媒体库也能换封面（含动图）。
# key 一律用**名字**，不用 id —— 用户自己新起的系列在库里没有 id，
# 用名字才能让「新建的分类」和「库里的分类」走同一套封面。
COVER_OVERRIDE_DDL = """
CREATE TABLE IF NOT EXISTS cover_override (
    kind       TEXT NOT NULL,                 -- series / tag / studio / actor / library
    key        TEXT NOT NULL,                 -- 分类名（媒体库用 lib-<id>）
    url        TEXT NOT NULL DEFAULT '',      -- 站内相对路径
    updated_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY(kind, key)
);
"""
COVER_KINDS = ("series", "tag", "studio", "actor", "library")


def tier_filters(body: dict) -> dict:
    """请求体 → 规范化筛选条件（越界一律夹到合法区间，不报错）。"""
    def pick_int(key: str, lo: int, hi: int, default: int) -> int:
        try:
            value = int(body.get(key))
        except (TypeError, ValueError):
            return default
        return max(lo, min(hi, value))

    kinds: list = []
    raw = body.get("kinds")
    if isinstance(raw, list):
        for item in raw:
            name = str(item)
            if name in TIER_KINDS and name not in kinds:
                kinds.append(name)
    if not kinds:
        kinds = list(TIER_KINDS)

    def pick_date(key: str) -> str:
        raw_date = str(body.get(key) or "")[:10]
        return raw_date if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw_date or "") else ""

    out = {
        "kinds": kinds,
        "score_min": pick_int("score_min", 1, 5, 1),
        "score_max": pick_int("score_max", 1, 5, 5),
        "date_from": pick_date("date_from"),
        "date_to": pick_date("date_to"),
        "actor_gender": str(body.get("actor_gender") or "").strip().lower()[:8],
        "studio_id": pick_int("studio_id", 0, 10 ** 9, 0),
        "tag_id": pick_int("tag_id", 0, 10 ** 9, 0),
        "series_id": pick_int("series_id", 0, 10 ** 9, 0),
        "favorite_only": body.get("favorite_only") is True,
        "include_unrated": body.get("include_unrated") is True,
        "limit_per_tier": pick_int("limit_per_tier", 1, TIER_LIMIT_MAX, TIER_LIMIT_DEFAULT),
        # 非契约字段：默认那张快照用它取「最近一个月打过分的」，客户端不必传
        "rated_days": pick_int("rated_days", 0, 3650, 0),
        # 图名：用户填了就用他的（去掉控制字符、截 40 字），留空交给 tier_title()
        "title": _tier_clean_title(body.get("title")),
    }
    if out["score_min"] > out["score_max"]:
        out["score_min"], out["score_max"] = out["score_max"], out["score_min"]
    return out


def tier_film_candidates(f: dict):
    """影片级筛选命中时返回候选 id 集合；一条都不设就返回 None（= 不限制）。

    收藏在 user.db、其余在 amane.db，**不能跨库写一条 SQL** —— 先取 amane 侧的集合，
    再在 Python 里跟收藏求交。
    """
    clauses: list = []
    args: list = []
    if f["date_from"]:
        clauses.append("m.release >= ?")
        args.append(f["date_from"])
    if f["date_to"]:
        clauses.append("m.release <= ?")
        args.append(f["date_to"])
    if f["studio_id"]:
        clauses.append("m.studio = (SELECT name FROM studios WHERE id = ?)")
        args.append(f["studio_id"])
    if f["series_id"]:
        clauses.append("m.series = (SELECT name FROM series WHERE id = ?)")
        args.append(f["series_id"])
    if f["tag_id"]:
        clauses.append("m.id IN (SELECT metadata_id FROM metadata_tags WHERE tag_id = ?)")
        args.append(f["tag_id"])
    if f["actor_gender"] in ("female", "male"):
        # 不能直接 `a.gender = 'FEMALE'`：库里这一列大小写混用（上游有 `Female` / `female`），
        # 大写比较在部分库上会一条都筛不出来 —— 与 actors 扩展 1.3.43 同一个坑
        clauses.append(
            "m.id IN (SELECT ma.metadata_id FROM metadata_actors ma "
            "JOIN actors a ON a.id = ma.actor_id WHERE LOWER(TRIM(a.gender)) = ?)")
        args.append(f["actor_gender"])

    cand = None
    if clauses:
        sql = "SELECT m.id FROM metadata m WHERE " + " AND ".join(clauses)
        with amane_db() as conn:
            cand = {int(r[0]) for r in conn.execute(sql, args)}
    if f["favorite_only"]:
        with user_db() as conn:
            fav = {int(r[0]) for r in conn.execute("SELECT metadata_id FROM favorites")}
        cand = fav if cand is None else (cand & fav)
    return cand


def actor_gender_map(ids: list) -> dict:
    """演员 id → `female` / `male` / 空串。

    库里 `actors.gender` 大小写混用（上游存在 `Male` / `Female`），一律 `strip().lower()`
    再比 —— 与 actors 扩展 `?gender=` 踩过的坑同源（1.3.43）。
    """
    out: dict = {}
    if not ids:
        return out
    head = ids[:900]
    marks = ",".join("?" * len(head))
    try:
        with amane_db() as conn:
            for r in conn.execute(
                    f"SELECT id, gender FROM actors WHERE id IN ({marks})", head):
                out[int(r["id"])] = str(r["gender"] or "").strip().lower()
    except Exception as exc:  # noqa: BLE001
        log(f"WARN tier 取演员性别失败: {exc}")
    return out


def tier_entity_meta(kind: str, ids: list) -> tuple:
    """分类 id → (名字表, 封面表)。封面取「它名下最新一部片的封面」，演员优先用头像。"""
    names: dict = {}
    covers: dict = {}
    if not ids:
        return names, covers
    head = ids[:400]
    marks = ",".join("?" * len(head))
    with amane_db() as conn:
        if kind == "actor":
            for r in conn.execute(
                    f"SELECT id, name, image_urls FROM actors WHERE id IN ({marks})", head):
                name = str(r["name"] or "")
                names[int(r["id"])] = name
                urls = _json_list(r["image_urls"])
                cover = public_image(urls[0]) if urls and isinstance(urls[0], str) else ""
                if cover:
                    covers[int(r["id"])] = cover
        else:
            table = {"director": "directors", "studio": "studios",
                     "tag": "tags", "series": "series"}[kind]
            for r in conn.execute(f"SELECT id, name FROM {table} WHERE id IN ({marks})", head):
                names[int(r["id"])] = str(r["name"] or "")

        # 没头像 / 非演员：用名下最新一部片的封面顶上
        need = [i for i in head if i not in covers and names.get(i)]
        for eid in need[:80]:
            name = names[eid]
            if kind == "actor":
                sql = ("SELECT m.poster_urls, m.thumb_urls FROM metadata m "
                       "JOIN metadata_actors x ON x.metadata_id = m.id "
                       "WHERE x.actor_id = ? ORDER BY m.release DESC LIMIT 1")
                args = (eid,)
            elif kind == "director":
                sql = ("SELECT m.poster_urls, m.thumb_urls FROM metadata m "
                       "JOIN metadata_directors x ON x.metadata_id = m.id "
                       "WHERE x.director_id = ? ORDER BY m.release DESC LIMIT 1")
                args = (eid,)
            elif kind == "tag":
                sql = ("SELECT m.poster_urls, m.thumb_urls FROM metadata m "
                       "JOIN metadata_tags x ON x.metadata_id = m.id "
                       "WHERE x.tag_id = ? ORDER BY m.release DESC LIMIT 1")
                args = (eid,)
            elif kind == "series":
                sql = ("SELECT m.poster_urls, m.thumb_urls FROM metadata m "
                       "WHERE m.series = ? ORDER BY m.release DESC LIMIT 1")
                args = (name,)
            else:  # studio
                sql = ("SELECT m.poster_urls, m.thumb_urls FROM metadata m "
                       "WHERE m.studio = ? ORDER BY m.release DESC LIMIT 1")
                args = (name,)
            row = conn.execute(sql, args).fetchone()
            if row:
                poster = pick_poster(row)
                if poster:
                    covers[eid] = poster
    return names, covers


def tier_entities_in(cand: set) -> set:
    """哪些分类（kind, id）名下至少有一部片落在候选集里 —— 给「带影片级筛选」时用。"""
    out: set = set()
    ids = sorted(cand)
    if not ids:
        return out
    with amane_db() as conn:
        for start in range(0, len(ids), 400):
            chunk = ids[start:start + 400]
            marks = ",".join("?" * len(chunk))
            for kind, sql in (
                ("actor", f"SELECT DISTINCT actor_id FROM metadata_actors WHERE metadata_id IN ({marks})"),
                ("director", f"SELECT DISTINCT director_id FROM metadata_directors WHERE metadata_id IN ({marks})"),
                ("tag", f"SELECT DISTINCT tag_id FROM metadata_tags WHERE metadata_id IN ({marks})"),
            ):
                for r in conn.execute(sql, chunk):
                    out.add((kind, int(r[0])))
            series_names = [str(r[0]).strip() for r in conn.execute(
                f"SELECT DISTINCT series FROM metadata WHERE id IN ({marks}) "
                "AND series IS NOT NULL AND series != ''", chunk)]
            studio_names = [str(r[0]).strip() for r in conn.execute(
                f"SELECT DISTINCT studio FROM metadata WHERE id IN ({marks}) "
                "AND studio IS NOT NULL AND studio != ''", chunk)]
            for kind, table, names in (("series", "series", series_names),
                                       ("studio", "studios", studio_names)):
                if not names:
                    continue
                ph = ",".join("?" * len(names))
                for r in conn.execute(f"SELECT id FROM {table} WHERE name IN ({ph})", names):
                    out.add((kind, int(r[0])))
    return out


def tier_items(f: dict) -> list:
    """按筛选条件把「有评分的条目」摊平成一串条目（含展示图与评级时间）。"""
    cand = tier_film_candidates(f)
    cutoff = ""
    if f["rated_days"]:
        cutoff = (datetime.now(timezone.utc)
                  - timedelta(days=f["rated_days"])).isoformat(timespec="seconds")

    items: list = []

    if "film" in f["kinds"]:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, score, updated_at FROM user_ratings").fetchall()
        keep = [(int(r["metadata_id"]), int(r["score"]), str(r["updated_at"] or ""))
                for r in rows if f["score_min"] <= int(r["score"]) <= f["score_max"]]
        if cand is not None:
            keep = [x for x in keep if x[0] in cand]
        if cutoff:
            keep = [x for x in keep if x[2] >= cutoff]
        metas = {m["id"]: m for m in fetch_by_ids([x[0] for x in keep])}
        for mid, score, at in keep:
            meta = metas.get(mid)
            if not meta:
                continue
            items.append({"id": mid, "kind": "film", "name": "",
                          "number": meta["number"] or "",
                          "image": meta["poster"] or "", "score": score,
                          "rated_at": at})

    ent_kinds = [k for k in f["kinds"] if k != "film"]
    if ent_kinds:
        with user_db() as conn:
            try:
                rows = conn.execute(
                    "SELECT kind, facet_id, stars, updated_at FROM facet_rating").fetchall()
            except sqlite3.Error:
                rows = []          # 分类评分表还没建（老库）：当作一条都没打
        allowed = tier_entities_in(cand) if cand is not None else None
        for kind in ent_kinds:
            kept = [(int(r["facet_id"]), int(r["stars"]), str(r["updated_at"] or ""))
                    for r in rows
                    if str(r["kind"]) == kind and f["score_min"] <= int(r["stars"]) <= f["score_max"]]
            if allowed is not None:
                kept = [x for x in kept if (kind, x[0]) in allowed]
            if cutoff:
                kept = [x for x in kept if x[2] >= cutoff]
            # 演员性别（2.5.4.11 修）：以前 `actor_gender` 只被解析、从没参与过滤，
            # 选「只看女」照样把男演员排进来。空性别视为不匹配（选了性别就只看确定的）。
            if kind == "actor" and f["actor_gender"] in ("female", "male"):
                gmap = actor_gender_map([x[0] for x in kept])
                kept = [x for x in kept if gmap.get(x[0]) == f["actor_gender"]]
            ids = [x[0] for x in kept]
            names, covers = tier_entity_meta(kind, ids)
            for eid, score, at in kept:
                name = names.get(eid, "")
                if not name:
                    continue
                items.append({"id": eid, "kind": kind, "name": name, "number": "",
                              "image": covers.get(eid, ""), "score": score,
                              "rated_at": at})
    return items


def tier_build(f: dict) -> dict:
    """条目 → 五档（每档按评级时间倒序，超上限给 more）。"""
    items = tier_items(f)
    limit = f["limit_per_tier"]
    tiers = []
    total = 0
    counts: dict = {}
    for score, title in TIER_SLOTS:
        group = [it for it in items if it["score"] == score]
        group.sort(key=lambda v: (v["rated_at"], v["name"], v["number"]), reverse=True)
        total += len(group)
        counts[score] = len(group)
        tiers.append({"score": score, "title": title,
                      "items": group[:limit], "more": max(0, len(group) - limit)})

    if f["include_unrated"]:
        rated_films = {it["id"] for it in items if it["kind"] == "film"}
        cand = tier_film_candidates(f)
        pool = sorted(cand or set())
        with amane_db() as conn:
            if pool:
                ph = ",".join("?" * len(pool[:900]))
                rows = conn.execute(
                    f"SELECT id, release FROM metadata WHERE id IN ({ph}) "
                    "ORDER BY release DESC", pool[:900]).fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, release FROM metadata ORDER BY release DESC LIMIT 900").fetchall()
        unrated_ids = [int(r["id"]) for r in rows if int(r["id"]) not in rated_films]
        metas = {m["id"]: m for m in fetch_by_ids(unrated_ids[:limit])}
        unrated = [{"id": mid, "kind": "film", "name": "",
                    "number": metas[mid]["number"] or "",
                    "image": metas[mid]["poster"] or "", "score": 0, "rated_at": ""}
                   for mid in unrated_ids[:limit] if mid in metas]
        tiers.append({"score": 0, "title": "未评分", "items": unrated,
                      "more": max(0, len(unrated_ids) - limit)})

    return {"tiers": tiers, "total": total, "counts": counts}


def _tier_clean_title(raw) -> str:
    """用户手填的图名：去控制字符、限 40 字（换行会把列表排版搞乱）。"""
    text = re.sub(r"[\x00-\x1f\x7f]", "", str(raw or "")).strip()
    return text[:40]


def tier_title(f: dict, data: dict) -> str:
    """默认图名 —— 不用「时间-筛选项」那种冷串，按**条件 + 数据分布**起个像人说的话。

    三段拼成 `<时间>的<内容>：<判断>`：

      * 时间词：整年区间 → 「今年」/「2024 年」；单月区间 → 「3 月」；近 N 天 → 「近 30 天」；
        默认那张（按打星时间筛的）同样走「近 N 天」；不限制 → 「历代」。
      * 内容词：单类 → 影片 / 演员 / 导演 / 厂牌 / 标签 / 系列；多类 → 「混搭」；
        只看收藏 → 前面加「私藏」。
      * 判断词看五档的**真实分布**（不是每档展示的那 20 个）：五成以上 5 星 → 神仙打架；
        五成以上 1 星 → 塌房现场；两头都有 → 两极分化；只有 5 星 → 一片好评；
        只有 1 星 → 全军覆没；都在中间 → 都还行；一条都没有 → 空空如也。

    实际产出形如：「今年的演员：神仙打架」「历代的影片：两极分化」
    「近 30 天的私藏影片：都还行」。
    """
    counts = data.get("counts") or {}
    rated = sum(int(counts.get(s, 0) or 0) for s in (1, 2, 3, 4, 5))
    if rated <= 0:
        return "还没打星的座次表"

    today = date.today()
    if f["date_from"] or f["date_to"]:
        y0 = (f["date_from"] or "")[:4]
        y1 = (f["date_to"] or "")[:4]
        if (f["date_from"] or "")[5:] == "01-01" and (not y1 or y1 == y0):
            window = "今年" if y0 == str(today.year) else f"{y0} 年"
        elif f["date_from"] and f["date_to"] and f["date_from"][:7] == f["date_to"][:7]:
            window = f"{int(f['date_from'][5:7])} 月"
        else:
            window = "这段时间"
    elif f["rated_days"]:
        window = f"近 {f['rated_days']} 天"
    else:
        window = "历代"

    if len(f["kinds"]) == 1:
        noun = TIER_KIND_NAMES.get(f["kinds"][0], "内容")
    else:
        noun = "混搭"
    if f["favorite_only"]:
        noun = f"私藏{noun}"

    five = int(counts.get(5, 0) or 0)
    one = int(counts.get(1, 0) or 0)
    r5 = five / rated
    r1 = one / rated
    if r5 >= 0.5:
        verdict = "神仙打架"
    elif r1 >= 0.5:
        verdict = "塌房现场"
    elif five and one:
        verdict = "两极分化"
    elif five:
        verdict = "一片好评"
    elif one:
        verdict = "全军覆没"
    else:
        verdict = "都还行"
    return f"{window}的{noun}：{verdict}"


def tier_summary(f: dict, total: int) -> str:
    """列表里那一行摘要（客户端直接显示，不自己拼）。"""
    kinds = " + ".join(TIER_KIND_NAMES.get(k, k) for k in f["kinds"])
    if f["date_from"] or f["date_to"]:
        span = f"{f['date_from'] or '最早'} ~ {f['date_to'] or '今天'}"
    elif f["rated_days"]:
        # 默认那张按「最近 N 天打的星」筛，摘要必须说出来 —— 否则用户以为看到的是全部
        span = f"最近 {f['rated_days']} 天打的星"
    else:
        span = "全部"
    extra = " · 只看收藏" if f["favorite_only"] else ""
    return f"{kinds} · {span}{extra} · 共 {total} 个"


def tier_store(f: dict, data: dict) -> dict:
    """落一张快照并返回接口该给的那份 data。"""
    summary = tier_summary(f, data["total"])
    thumbs = []
    for tier in data["tiers"]:
        for it in tier["items"]:
            image = it.get("image") or ""
            if image and image not in thumbs:
                thumbs.append(image)
            if len(thumbs) >= 3:
                break
        if len(thumbs) >= 3:
            break
    created = now_iso()
    # 用户填了就用他的，留空按条件 + 分布自动起名（见 tier_title）
    title = f.get("title") or tier_title(f, data)
    with user_db() as conn:
        cur = conn.execute(
            "INSERT INTO tier_snapshot(filters, payload, summary, title, thumbs, created_at, picked) "
            "VALUES(?,?,?,?,?,?,0)",
            (json.dumps(f, ensure_ascii=False), json.dumps(data, ensure_ascii=False),
             summary, title, json.dumps(thumbs, ensure_ascii=False), created))
        sid = int(cur.lastrowid)
    return {"id": sid, "created_at": created, "tiers": data["tiers"],
            "total": data["total"], "summary": summary, "title": title, "thumbs": thumbs}


def tier_guess_title(filters_raw: str, payload: dict) -> str:
    """给 2.5.4.10 之前落的老快照**读时**补一个名字（不写库）。

    counts 用每档 `items + more` 还原 —— `more` 就是被截掉的那部分，加起来正好是真实条数，
    所以老图也能算出一句准确的判断词。
    """
    try:
        f = json.loads(filters_raw or "")
    except (TypeError, ValueError):
        return ""
    if not isinstance(f, dict):
        return ""
    total = int(payload.get("total") or 0)
    if total <= 0:
        return ""
    counts: dict = {}
    for tier in payload.get("tiers") or []:
        try:
            score = int(tier.get("score"))
        except (TypeError, ValueError):
            continue
        counts[score] = len(tier.get("items") or []) + int(tier.get("more") or 0)
    view = {
        "kinds": f.get("kinds") or list(TIER_KINDS),
        "date_from": str(f.get("date_from") or ""),
        "date_to": str(f.get("date_to") or ""),
        "rated_days": int(f.get("rated_days") or 0),
        "favorite_only": bool(f.get("favorite_only")),
    }
    return tier_title(view, {"counts": counts, "total": total})


def tier_row_to_data(row: sqlite3.Row) -> dict:
    try:
        payload = json.loads(row["payload"])
    except (TypeError, ValueError):
        payload = {"tiers": [], "total": 0}
    try:
        thumbs = json.loads(row["thumbs"])
    except (TypeError, ValueError):
        thumbs = []
    # 老快照没有 title 列（2.5.4.10 之前落的）：回空串，客户端退回显示 summary
    try:
        title = str(row["title"] or "")
    except (IndexError, KeyError):
        title = ""
    if not title:
        title = tier_guess_title(str(row["filters"] or ""), payload)
    return {"id": int(row["id"]), "created_at": str(row["created_at"] or ""),
            "tiers": payload.get("tiers", []), "total": int(payload.get("total", 0)),
            "summary": str(row["summary"] or ""), "title": title, "thumbs": thumbs,
            "picked": bool(row["picked"])}


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
    # 2.5.7.7：按文件个数排（多版本的排前面，方便清理）。相关子查询，5k 行量级够快。
    "versions": ("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id)", "desc"),
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
    """海报：本地资源 > 外链，统一转成外网可达路径（`public_image` 负责分流）。"""
    for url in _json_list(row["poster_urls"]) + _json_list(row["thumb_urls"]):
        if not isinstance(url, str):
            continue
        proxy = public_image(url)
        if proxy:
            return proxy
    return ""


FAN_MIN_W = 720          # 横图首选宽度（与横幅同口径）
FAN_FALLBACK_W = 400     # 没有 720 宽时，退一步的底线（至少要能看）


def _is_wide(w: int, h: int, min_w: int = FAN_MIN_W) -> bool:
    """是不是一张能铺横框的图：够宽 + 横版。"""
    return w >= min_w and h > 0 and (w / h) >= 1.25


_fan_dims_warming: set = set()
_fan_dims_lock = threading.Lock()
_fan_dims_queue: list = []
_fan_dims_worker: list = []          # 单元素：worker 是否已启动（避免重复起线程）
_fan_dims_used: list = [0, 0.0]      # [本窗口已量张数, 窗口起点]
FAN_DIMS_PER_HOUR = 240              # 每小时最多量这么多张（够横幅/推荐换代，不占满带宽）
FAN_DIMS_MAX_QUEUE = 120             # 队列上限：再多就丢，下次访问重新排队


def _fan_dims_loop() -> None:
    """唯一的后台量图线程：一次一张、有每小时配额。

    原来是「每次缓存未命中就 new 一个线程、一次量 6 张」—— 客户端下拉刷新连点几次
    就会同时开出十几条线程、几十个外网连接。这里收成一条常驻线程 + 配额。
    """
    while True:
        with _fan_dims_lock:
            url = _fan_dims_queue.pop(0) if _fan_dims_queue else ""
        if not url:
            time.sleep(2.0)
            continue
        with _fan_dims_lock:
            now = time.time()
            if now - _fan_dims_used[1] >= 3600:
                _fan_dims_used[0], _fan_dims_used[1] = 0, now
            over = _fan_dims_used[0] >= FAN_DIMS_PER_HOUR
            if not over:
                _fan_dims_used[0] += 1
        if over:
            # 配额用完：把这条放回队尾，等下一个窗口，别丢
            with _fan_dims_lock:
                _fan_dims_queue.append(url)
            time.sleep(30.0)
            continue
        try:
            image_dims(url)          # 自己会落 img_dims
        except Exception as exc:  # noqa: BLE001
            log(f"WARN fan dims: {exc}")
        finally:
            with _fan_dims_lock:
                _fan_dims_warming.discard(url)


def _kick_fan_dims(cands: list) -> None:
    """缓存里没有这部片的尺寸时，把它排进后台队列（本线程不等）。

    推荐/横幅每次换一批，不可能全部预热完；不补的话没量过的片会一直用兜底图。
    补一次之后这台机器上的后续请求就换成真剧照了。
    """
    todo = [u for u in cands[:6] if isinstance(u, str) and u.startswith("http")]
    if not todo:
        return
    with _fan_dims_lock:
        for u in todo:
            if u in _fan_dims_warming:
                continue
            if len(_fan_dims_queue) >= FAN_DIMS_MAX_QUEUE:
                break
            _fan_dims_warming.add(u)
            _fan_dims_queue.append(u)
        fresh = not _fan_dims_worker
        if fresh:
            _fan_dims_worker.append(True)
    if fresh:
        try:
            threading.Thread(target=_fan_dims_loop, daemon=True, name="fan-dims").start()
        except RuntimeError as exc:
            log(f"WARN fan dims thread: {exc}")
            _fan_dims_worker.clear()


def _dims_bulk(urls: list, limit: int = 12) -> dict:
    """批量读 `img_dims` 缓存，**不联网**。只返回已知宽高的条目。

    列表接口每屏要算 20~40 部，在这里调 `image_dims()` 会变成一次请求几十个外网连接，
    所以只查缓存；没预热到的片走原行为（先用第一张），后台预热补上后自然变好。
    """
    head = [u for u in urls[:limit] if isinstance(u, str) and u]
    if not head:
        return {}
    out: dict = {}
    try:
        with user_db() as conn:
            ph = ",".join("?" * len(head))
            for r in conn.execute(f"SELECT url, w, h FROM img_dims WHERE url IN ({ph})", head):
                try:
                    w, h = int(r["w"] or 0), int(r["h"] or 0)
                except (TypeError, ValueError):
                    continue
                if w > 0 and h > 0:
                    out[r["url"]] = (w, h)
    except sqlite3.Error:
        return {}
    return out


def _first_thumb(row: sqlite3.Row) -> str:
    """`thumb_urls` 的第一张。

    2026-11-12 抽样 14 部实测：剧照第一张只有 8/14 是合格横图（javbus 的 `jp-1`
    约四成是 533×800 竖版封面、javdb 的 `_l_0` 有 147×200 小图），而 thumb
    **14/14 全是 800×5xx 横图**。所以「尺寸还没量到」时用它兜底，
    首屏就不会再出现被拉扁的竖版小图。
    """
    for url in _json_list(row["thumb_urls"]):
        proxy = public_image(url)
        if proxy:
            return proxy
    return ""


def pick_fanart(row: sqlite3.Row) -> str:
    """横图：已验证的剧照 > thumb（未量过尺寸时）> 非竖版剧照 > 海报。

    2.5.7.5 起不再无脑取第一张：javdb 的 `_l_0.jpg` 有一批实际是 147x200 的竖版小图，
    javbus 的 `jp-1` 也常是 533x800 的竖版封面 —— 塞进横框只裁中间一条，糊且不像剧照。
    2.5.7.17 起改成**三级**：只认缓存里验证过的横图，没量过的直接用 thumb 兜底
    （实测 thumb 全是 800 宽横图），同时后台排一张去量；量到之后就换成真剧照。
    这样「每日推荐/横幅」第一次出现就不糊，**不需要任何全库预热脚本**。
    **只用缓存、不联网**（列表接口每屏要算 20~40 部）。
    """
    extra = _json_dict(row["extrafanart_urls"])
    cands = [u for urls in extra.values() for u in _json_list(urls)
             if isinstance(u, str) and u.startswith("http")]
    if cands:
        dims = _dims_bulk(cands)
        # 1) 已验证的横图：先看 720 宽，再退一步 400 宽
        for min_w in (FAN_MIN_W, FAN_FALLBACK_W):
            for url in cands:
                d = dims.get(url)
                if d and _is_wide(d[0], d[1], min_w):
                    return _img_proxy(url)
        # 2) 这批还没量过 → 立刻用 thumb 兜底（不糊），同时排后台去量
        unknown = [u for u in cands if u not in dims]
        if unknown:
            _kick_fan_dims(cands)
            thumb = _first_thumb(row)
            if thumb:
                return thumb
        # 3) 都不是横图：跳过已知竖版/小图的，其余按原顺序
        for url in cands:
            d = dims.get(url)
            if d and not _is_wide(d[0], d[1], FAN_FALLBACK_W):
                continue
            return _img_proxy(url)
        return _img_proxy(cands[0])
    return _first_thumb(row) or pick_poster(row)


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


def versions_of(conn: sqlite3.Connection, ids: list) -> dict:
    """一次查出这些影片各有几个文件（= 几个版本）。

    2.5.7.7：给「多版本」这个属性提供数据。口径就是上游 `media_files` 里该
    `metadata_id` 的行数 —— 文件管理页看到几条，这里就是几。**不做缓存**：
    每次列表请求现算，所以用户在文件管理里删掉一个版本、或者脚本把新文件入库，
    下一次刷新列表就变（这就是「实时」）。
    注意：一部片被切成 A/B 两段时也会算成 2，和「两个清晰度版本」分不开 ——
    上游没有能区分二者的字段，宁可多报也不漏报（用途是「找出来人工确认」）。
    """
    clean = [int(i) for i in ids if i]
    if not clean:
        return {}
    counts: dict[int, int] = {}
    try:
        ph = ",".join("?" * len(clean))
        rows = conn.execute(
            "SELECT metadata_id, COUNT(*) c FROM media_files "
            "WHERE metadata_id IN (" + ph + ") GROUP BY metadata_id",
            clean,
        ).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN versions_of: {exc}")
        return {}
    for r in rows:
        counts[r[0]] = int(r[1])
    return counts


def attach_marks(conn: sqlite3.Connection, items: list) -> list:
    """就地给列表补 marks 字段（没有标记的给空数组，前端不必判空）。

    顺带补 `versions`（该片的文件个数，2.5.7.7）：同一个 `media_files` 聚合，
    不额外多一次查询；没有文件的片给 0，前端据此判断「有/无多版本」。
    """
    got = marks_of(conn, [it.get("id") for it in items if isinstance(it, dict)])
    counts = versions_of(conn, [it.get("id") for it in items if isinstance(it, dict)])
    for it in items:
        if isinstance(it, dict):
            it["marks"] = got.get(it.get("id"), [])
            it["versions"] = counts.get(it.get("id"), 0)
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


# --------------------------------------------------------------------------- #
# 元数据覆盖层（2.5.5）
#
# 用户在手机上改片名 / 演员 / 标签 / 封面时，**只写 user.db 的 meta_override**，
# amane 的库一个字都不动（它是刮削产物，写回去下次刮削就冲掉）。
# 读的时候「覆盖优先」：列表、详情、搜索、收藏、观看记录都吃同一份合并结果，
# 客户端不做合并判断。批量取一页时只查一次（`meta_override_map`），别逐条查。
# --------------------------------------------------------------------------- #

OVERRIDE_TEXT_FIELDS = ("title", "plot", "series", "studio", "release", "note")
OVERRIDE_LIST_FIELDS = ("actors", "tags")


def meta_override_map(ids) -> dict:
    """一页的覆盖数据：`{mid: {"fields": {...}, "cover": "..."}}`。

    一条都没改过就返回空 dict —— 调用方据此直接跳过整段逻辑（99% 的请求走这条路）。
    """
    out: dict = {}
    head = [int(i) for i in ids if i][:500]
    if not head:
        return out
    marks = ",".join("?" * len(head))
    try:
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, fields, cover, wide FROM meta_override "
                f"WHERE metadata_id IN ({marks})", head).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读覆盖层失败: {exc}")
        return out
    for r in rows:
        out[int(r["metadata_id"])] = {
            "fields": _json_dict(r["fields"]),
            "cover": str(r["cover"] or ""),
            "wide": str(r["wide"] or "") if "wide" in r.keys() else "",
        }
    return out


def apply_overrides(items: list) -> list:
    """把覆盖层盖到条目上（就地改，返回同一个 list）。"""
    if not items:
        return items
    ids = [it.get("id") for it in items if isinstance(it, dict)]
    ovs = meta_override_map(ids)
    if not ovs:
        return items
    for it in items:
        ov = ovs.get(int(it.get("id") or 0))
        if not ov:
            continue
        for key, value in (ov["fields"] or {}).items():
            if key in OVERRIDE_TEXT_FIELDS or key in OVERRIDE_LIST_FIELDS or key == "number":
                it[key] = value
                it["overridden"] = True
        if ov["cover"]:
            it["poster"] = ov["cover"]
            # 横图位（继续观看 / 每日推荐 / 横幅）读的是 fanart：有 16:9 衍生图就用它，
            # 没有才退回竖版（会裁切，但至少是同一张图）。
            it["fanart"] = ov.get("wide") or ov["cover"]
            it["poster_is_custom"] = True
            it["overridden"] = True
    return items


def cover_override_both(kind: str, keys) -> dict:
    """`{key: {url, wide}}` —— 详情页头部是横条、列表是竖卡，两张图都要给。"""
    out: dict = {}
    head = [str(k) for k in keys if k][:300]
    if not head:
        return out
    marks = ",".join("?" * len(head))
    try:
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT \"key\", url, wide FROM cover_override "
                f"WHERE kind = ? AND \"key\" IN ({marks})", (kind, *head)).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读分类封面失败: {exc}")
        return out
    for r in rows:
        out[str(r["key"])] = {
            "url": str(r["url"] or ""),
            "wide": str(r["wide"] or "") if "wide" in r.keys() else "",
        }
    return out


def cover_override_map(kind: str, keys) -> dict:
    """一批分类的封面：`{key: url}`，没换过的不出现在结果里。"""
    out: dict = {}
    head = [str(k) for k in keys if k][:300]
    if not head:
        return out
    marks = ",".join("?" * len(head))
    try:
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT \"key\", url FROM cover_override "
                f"WHERE kind = ? AND \"key\" IN ({marks})", (kind, *head)).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读分类封面失败: {exc}")
        return out
    for r in rows:
        out[str(r["key"])] = str(r["url"] or "")
    return out


def cover_override_all(kind: str) -> dict:
    """某个分类下所有已换的封面（列表页一次取完，别逐个查）。"""
    try:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT \"key\", url FROM cover_override WHERE kind = ?", (kind,)).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读分类封面失败: {exc}")
        return {}
    return {str(r["key"]): str(r["url"] or "") for r in rows if r["url"]}


def _save_uploaded_image(body: dict) -> tuple:
    """把 body 里的 base64 存成 photos 里的图，返回 `(url, 错误说明)`。

    复用核心的 `save_photo()`（文件名按内容 sha1 起，客户端不传文件名），
    与影片封面上传走同一条落盘路径，不另建第二套上传。
    """
    raw = str(body.get("data") or "")
    if raw.startswith("data:"):
        comma = raw.find(",")
        raw = raw[comma + 1:] if comma > 0 else raw
    try:
        blob = base64.b64decode(raw, validate=False)
    except Exception:  # noqa: BLE001
        return "", "图片数据无法解析"
    if not blob:
        return "", "空图片"
    if len(blob) > 12 * 1024 * 1024:
        return "", "图片太大（上限 12MB）"

    ext = str(body.get("ext") or "").lower().lstrip(".")
    if ext == "jpeg":
        ext = "jpg"
    if ext not in ("jpg", "png", "webp", "gif"):
        if blob[:3] == b"\xff\xd8\xff":
            ext = "jpg"
        elif blob[:8] == b"\x89PNG\r\n\x1a\n":
            ext = "png"
        elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
            ext = "webp"
        elif blob[:3] == b"GIF":
            ext = "gif"
        else:
            return "", "只支持 jpg / png / webp / gif"
    name = f"{hashlib.sha1(blob).hexdigest()}.{ext}"
    try:
        save_photo(name, blob)
    except Exception as exc:  # noqa: BLE001
        return "", f"保存失败: {exc}"
    return f"/api/user/photo/{name}", ""


# --------------------------------------------------------------------------- #
# GIF 轮播封面（2.5.5.5）
#
# 用一部片自己的剧照拼一段循环动图，存成普通封面（`meta_override.cover`），
# 客户端 Image 就会自己播 —— 不需要另建一套「动图播放器」。
# 依赖 Pillow（可选）：容器镜像没带，装在 /data/pylibs，见文件头。
# --------------------------------------------------------------------------- #

_GIF_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
           "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


def _flatten_http_urls(raw, limit: int = 12) -> list[str]:
    """把 extrafanart_urls / poster_urls 这种「分组 JSON」摊平成一串地址。"""
    try:
        data = _json_dict(raw) if isinstance(raw, str) else (raw or [])
    except (TypeError, ValueError):
        return []
    if isinstance(data, dict):
        groups = list(data.values())
    elif isinstance(data, list):
        groups = data
    else:
        return []
    out: list[str] = []
    for g in groups:
        for u in (g if isinstance(g, list) else [g]):
            if isinstance(u, str) and (u.startswith("http") or u.startswith("/api/resources/")):
                if u not in out:
                    out.append(u)
            if len(out) >= limit:
                return out
    return out


def _fetch_image(url: str) -> bytes:
    """取一张图。Resource 库要带 Bearer 回源；外链**绝不能**带 token。"""
    if url.startswith("/api/resources/"):
        req = Request(f"{AMANE_BASE}{url}",
                      headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
    elif url.startswith("http://") or url.startswith("https://"):
        parts = url.split("/")
        origin = f"{parts[0]}//{parts[2]}/" if len(parts) > 2 else ""
        req = Request(url, headers={"User-Agent": _GIF_UA, "Referer": origin})
    else:
        return b""
    try:
        with urlopen(req, timeout=12) as resp:
            return resp.read(8 * 1024 * 1024)
    except (HTTPError, URLError, OSError, ValueError) as exc:
        log(f"WARN GIF 取图失败 {url[:56]}: {exc}")
        return b""


def _cover_frame(im, tw: int, th: int):
    """按 2:3 封面比例居中裁切并缩放（Pillow 对象进出）。"""
    from PIL import Image  # 局部 import：没装 Pillow 时只有这个功能不可用

    im = im.convert("RGB")
    w, h = im.size
    if w <= 0 or h <= 0:
        return None
    scale = max(tw / w, th / h)
    nw, nh = max(tw, int(w * scale + 0.5)), max(th, int(h * scale + 0.5))
    im = im.resize((nw, nh), Image.Resampling.LANCZOS)
    left = (nw - tw) // 2
    top = (nh - th) // 2
    return im.crop((left, top, left + tw, top + th))


def _has_pillow() -> bool:
    """Pillow 装了没（GIF 功能用；没装只影响这一个功能）。"""
    try:
        import PIL  # noqa: F401
        return True
    except ImportError:
        return False


def build_wide_jpeg(frame, width: int = 720) -> bytes:
    """把竖版封面做成 16:9 横版：模糊背景铺满 + 居中放完整海报（不裁切）。

    横版位（继续观看 / 每日推荐）原来直接拿竖版图，一裁就只剩中间一条；
    这里改用「虚化背景 + 原图居中」的构图，两边都完整。
    """
    try:
        from PIL import Image, ImageFilter
    except ImportError:
        return b""
    try:
        if not isinstance(frame, Image.Image):
            return b""
        tw = max(320, min(1280, width))
        th = int(tw * 9 / 16)
        bg = frame.convert("RGB").resize((tw, th), Image.Resampling.BILINEAR)
        bg = bg.filter(ImageFilter.GaussianBlur(20))
        # 前景按高度贴满，宽度自适应，水平居中
        scale = th / frame.size[1]
        fw = max(1, int(frame.size[0] * scale))
        fg = frame.convert("RGB").resize((fw, th), Image.Resampling.LANCZOS)
        canvas = bg
        canvas.paste(fg, ((tw - fw) // 2, 0))
        buf = io.BytesIO()
        canvas.save(buf, format="JPEG", quality=82, optimize=True)
        return buf.getvalue()
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 生成横版封面失败: {exc}")
        return b""


def make_wide_of_photo(url: str) -> str:
    """给已经落盘的封面图生成一张 16:9 横版，返回它的 URL（失败/没 Pillow 返回空）。

    上传通道（相册选图）也要，否则分类头部的横条、继续观看那些位只能拿竖图硬裁。
    """
    if not url.startswith("/api/user/photo/"):
        return ""
    if not _has_pillow():
        return ""
    path = os.path.join(PHOTO_DIR, url.rsplit("/", 1)[-1])
    if not os.path.isfile(path):
        return ""
    try:
        from PIL import Image
        with Image.open(path) as im:
            im.load()
            wide = build_wide_jpeg(im)
        if not wide:
            return ""
        wname = f"{hashlib.sha1(wide).hexdigest()}.jpg"
        save_photo(wname, wide)
        return f"/api/user/photo/{wname}"
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 生成横版失败 {url}: {exc}")
        return ""


def build_cover_gif(urls, width: int = 320, duration: int = 700,
                    max_frames: int = 8):
    """把若干张图合成循环 GIF。

    返回 `(gif_bytes, first_frame)` —— 首帧再拿去 `build_wide_jpeg` 做一张 16:9，
    这样竖版位（海报）和横版位（继续观看 / 每日推荐）都不裁切。
    """
    try:
        from PIL import Image
    except ImportError:
        return b"", None

    frames: list = []
    for u in urls:
        blob = _fetch_image(u)
        if not blob:
            continue
        try:
            im = Image.open(io.BytesIO(blob))
            im.load()
        except Exception:  # noqa: BLE001
            continue
        frame = _cover_frame(im, width, int(width * 3 / 2))
        if frame is not None:
            frames.append(frame)
        if len(frames) >= max_frames:
            break
    if not frames:
        return b"", None
    if len(frames) == 1:
        # 只有一张图也能动：原地轻微推镜（100% -> 108%）
        base = frames[0]
        tw, th = base.size
        big = base.resize((int(tw * 1.08), int(th * 1.08)), Image.Resampling.LANCZOS)
        left = (big.size[0] - tw) // 2
        top = (big.size[1] - th) // 2
        frames = [base, big.crop((left, top, left + tw, top + th))]

    # 交错插混合帧会让帧数翻倍（6 张 → 12 帧），GIF 越大解码越吃力，
    # 播起来就是「一顿一顿」。改成隔一张插一帧：6 张 → 9 帧，过渡还在，负担小一半。
    seq: list = []
    for i in range(len(frames)):
        seq.append(frames[i])
        if i % 2 == 0 and len(seq) < max_frames + 2:
            seq.append(Image.blend(frames[i], frames[(i + 1) % len(frames)], 0.5))

    pal = [f.convert("P", palette=Image.Palette.ADAPTIVE, colors=96) for f in seq]
    buf = io.BytesIO()
    pal[0].save(buf, format="GIF", save_all=True, append_images=pal[1:],
                duration=duration, loop=0, optimize=True, disposal=2)
    return buf.getvalue(), frames[0]


def cover_gif_sources(mid: int, limit: int = 12) -> list[str]:
    """这部片能拿来拼 GIF 的图：剧照优先，海报兜底。"""
    try:
        with amane_db() as conn:
            row = conn.execute(
                "SELECT extrafanart_urls, poster_urls FROM metadata WHERE id = ?",
                (mid,)).fetchone()
    except sqlite3.Error as exc:
        log(f"WARN GIF 读源图失败 {mid}: {exc}")
        return []
    if row is None:
        return []
    urls = _flatten_http_urls(row["extrafanart_urls"], limit)
    if len(urls) < limit:
        for u in _flatten_http_urls(row["poster_urls"], limit):
            if u not in urls:
                urls.append(u)
    return urls[:limit]


def cover_gif_sources_for(kind: str, key: str, limit: int = 10) -> list[str]:
    """某个分类（系列 / 标签 / 厂牌 / 演员 / 媒体库）下最近几部片的**海报**。

    分类动图先做「类里所含海报的轮播」—— 比拿剧照稳（海报每部都有），
    以后要更强的动效（抽帧、转场）再加 `source` 参数即可。
    """
    sql: str = ""
    args: tuple = ()
    try:
        with amane_db() as conn:
            if kind == "library":
                try:
                    lib_id = int(str(key).replace("lib-", "").strip())
                except ValueError:
                    return []
                sql = ("SELECT poster_urls, extrafanart_urls FROM metadata WHERE id IN "
                       "(SELECT metadata_id FROM media_files WHERE library_id = ?) "
                       "ORDER BY release DESC, id DESC LIMIT ?")
                args = (lib_id, limit)
            elif kind == "series":
                sql = ("SELECT poster_urls, extrafanart_urls FROM metadata WHERE series = ? "
                       "AND id IN (SELECT metadata_id FROM media_files) "
                       "ORDER BY release DESC, id DESC LIMIT ?")
                args = (key, limit)
            elif kind == "studio":
                sql = ("SELECT poster_urls, extrafanart_urls FROM metadata WHERE studio = ? "
                       "AND id IN (SELECT metadata_id FROM media_files) "
                       "ORDER BY release DESC, id DESC LIMIT ?")
                args = (key, limit)
            elif kind == "tag":
                sql = ("SELECT m.poster_urls, m.extrafanart_urls FROM metadata m "
                       "JOIN metadata_tags mt ON mt.metadata_id = m.id "
                       "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ? "
                       "AND m.id IN (SELECT metadata_id FROM media_files) "
                       "ORDER BY m.release DESC, m.id DESC LIMIT ?")
                args = (key, limit)
            elif kind == "actor":
                # 演员与影片的关系存在 metadata.actors 的 JSON 文本里，只能模糊匹配
                sql = ("SELECT poster_urls, extrafanart_urls FROM metadata WHERE actors LIKE ? "
                       "AND id IN (SELECT metadata_id FROM media_files) "
                       "ORDER BY release DESC, id DESC LIMIT ?")
                args = (f"%{key}%", limit)
            else:
                return []
            rows = conn.execute(sql, args).fetchall()
    except sqlite3.Error as exc:
        log(f"WARN GIF 读分类海报失败 {kind}={key}: {exc}")
        return []

    urls: list[str] = []
    for r in rows:
        # 每部片只取 1 张：多部片的封面轮播才有「换片」的感觉
        for u in _flatten_http_urls(r["poster_urls"], 1):
            if u not in urls:
                urls.append(u)
                break
        if len(urls) >= limit:
            break
    if len(urls) < 2:
        # 海报不够就补横图
        for r in rows:
            for u in _flatten_http_urls(r["extrafanart_urls"], 1):
                if u not in urls:
                    urls.append(u)
                    break
            if len(urls) >= limit:
                break
    return urls[:limit]


def override_ids_for(kind: str, name: str) -> list:
    """覆盖层里被改成这个分类名的影片 id。

    自建分类（用户在手机上新建的系列 / 标签）在库里没有 id，`browse` 的
    `<kind>_id` 筛选对它无效；有了这份 id 列表，就能把「库里本来属于这个名字的」
    和「被改到这个名字下的」并成一条条件 —— 之后关键词 / 评分 / 收藏 / 排序
    全部复用 browse 现成的那套，不用给自建分类另写一份。
    """
    field = {"tag": "tags", "actor": "actors"}.get(kind, kind)
    out: list = []
    try:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, fields FROM meta_override").fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读覆盖层分类成员失败: {exc}")
        return out
    for r in rows:
        try:
            fields = _json_dict(r["fields"])
        except (TypeError, ValueError):
            continue
        value = fields.get(field)
        names = value if isinstance(value, list) else ([value] if isinstance(value, str) else [])
        if any(str(v or "").strip() == name for v in names):
            mid = int(r["metadata_id"] or 0)
            if mid > 0:
                out.append(mid)
    return out[:800]


def override_ids_matching(tokens) -> list:
    """覆盖层里命中这些词的影片 id（片名 / 系列 / 厂牌 / 演员 / 标签 / 备注）。

    搜索跑在 amane 库上，看不到覆盖层。用户把某部片的系列改成「11」后，
    搜「11」本该能找到它 —— 这里补这份 id 列表，由 browse 追加到结果里。
    """
    cleaned = [str(t).strip().lower() for t in (tokens or []) if str(t).strip()]
    if not cleaned:
        return []
    out: list = []
    try:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, fields FROM meta_override").fetchall()
    except sqlite3.Error as exc:
        log(f"WARN 读覆盖层搜索数据失败: {exc}")
        return out
    for r in rows:
        fields = _json_dict(r["fields"])
        parts: list = [
            str(fields.get("title") or ""),
            str(fields.get("series") or ""),
            str(fields.get("studio") or ""),
            str(fields.get("note") or ""),
        ]
        for key in ("actors", "tags"):
            value = fields.get(key)
            if isinstance(value, list):
                parts.extend(str(v or "") for v in value)
        blob = " ".join(parts).lower()
        if blob and all(tk in blob for tk in cleaned):
            mid = int(r["metadata_id"] or 0)
            if mid > 0:
                out.append(mid)
    return out[:200]


def clean_override(body: dict) -> tuple:
    """校验并清洗编辑页传来的字段，返回 `(patch, 错误说明)`。

    只认白名单里的键（别的键静默忽略，免得把 `score`、`poster` 这种内部字段改坏）；
    空串 / 空数组表示「清掉这个键的覆盖」，由调用方处理。
    """
    patch: dict = {}
    for key in OVERRIDE_TEXT_FIELDS:
        if key not in body:
            continue
        text = "" if body.get(key) is None else str(body.get(key)).strip()
        if key == "release" and text and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            return {}, "发行日要 YYYY-MM-DD"
        limit = 2000 if key == "plot" else 200
        if key == "note":
            limit = 500
        patch[key] = text[:limit]
    for key in OVERRIDE_LIST_FIELDS:
        if key not in body:
            continue
        raw = body.get(key)
        if raw is None:
            patch[key] = []
            continue
        if not isinstance(raw, list):
            return {}, f"{key} 必须是数组"
        items: list = []
        for one in raw[:50]:
            name = str(one).strip()[:60]
            if name and name not in items:
                items.append(name)
        patch[key] = items
    if "number" in body:
        patch["number"] = ("" if body.get("number") is None
                           else str(body.get("number")).strip()[:32])
    if not patch:
        return {}, "没有要改的字段"
    return patch, ""


# 投屏令牌的进程内缓存：媒体请求（尤其 Range）会连打十几次，
# 每次都查 SQLite 没必要；命中就 60 秒内不再查库。
_CAST_HIT: dict = {}


def cast_cover_bytes(poster: str) -> tuple:
    """把一条片的海报取成 `(字节, Content-Type)`，给电视/盒子当封面用。

    三种形态都要认（见 `pick_poster`）：
      * `/api/resources/...` —— amane 本地缓存，要带 Bearer；
      * `/api/user/photo/...` —— 自家写真/自定义封面，直接读盘；
      * `/img?b=...` —— 已过白名单的外链代理形式，解出原链再走 `serve_image()`。
    """
    if poster.startswith("/api/resources/"):
        req = Request(AMANE_BASE + poster, headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
        with urlopen(req, timeout=20) as resp:
            return resp.read(), (resp.headers.get("Content-Type") or "image/jpeg")
    if poster.startswith("/api/user/photo/"):
        name = poster.rsplit("/", 1)[-1]
        path = os.path.join(PHOTO_DIR, name)
        if not os.path.isfile(path):
            raise ValueError("图片不存在")
        ctype = mimetypes.guess_type(path)[0] or "image/jpeg"
        with open(path, "rb") as fh:
            return fh.read(), ctype
    if poster.startswith("/img?"):
        raw = (parse_qs(urlparse(poster).query).get("b") or [""])[0]
        return serve_image(_unb64url(raw))
    if poster.startswith("http"):
        return serve_image(poster)
    raise ValueError(f"认不出的封面形态: {poster[:40]}")


def cast_token_valid(token: str) -> bool:
    """投屏令牌是否有效（存在且未过期）。"""
    now = time.time()
    hit = _CAST_HIT.get(token)
    if hit is not None and now - hit[1] < 60:
        return hit[0] > now
    exp_ts = 0.0
    try:
        with user_db() as conn:
            row = conn.execute(
                "SELECT expires_at FROM cast_token WHERE token = ?", (token,)).fetchone()
        if row is not None:
            try:
                exp_ts = datetime.fromisoformat(str(row["expires_at"])).timestamp()
            except (TypeError, ValueError):
                exp_ts = 0.0
    except sqlite3.Error as exc:
        log(f"WARN 读投屏令牌失败: {exc}")
        exp_ts = 0.0
    _CAST_HIT[token] = (exp_ts, now)
    return exp_ts > now


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
    return apply_overrides([item_of(r) for r in rows])


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
    # 覆盖层（2.5.5）：标题/演员/标签/封面这些改过就要在这里生效，
    # 观看记录、收藏、详情页都吃这一份，别在页面里各判一次。
    out = apply_overrides(out)
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
    return attach_marks_auto(attach_progress(apply_overrides([it for _s, it in scored[:limit]])))


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
# 全库统计摘要（2.5.7.21 · 每日推荐理由的「全库级」事实）
# --------------------------------------------------------------------------- #
# 口径与 query_meta / count_meta 一致：只算「还有文件的片」。
# 一次全表扫拿齐评分分布与各维度计数，按「日期 + amane.db 小时级 mtime」缓存；
# home 自己的 5 分钟缓存不会触发重扫。下发给客户端时只保留这一批卡片涉及的键，
# 所以响应体积不随全库规模膨胀。服务端老版本没有这个字段时，客户端自动跳过全库族。
_LIB_STATS_CACHE: dict = {"key": "", "data": None}
_LIB_STATS_LOCK = threading.Lock()


def _stats_score(raw) -> float:
    """与 item_of() 完全相同的评分取值口径，避免理由里的分和卡片上的分对不上。"""
    scores = _json_dict(raw)
    for key in ("javdb", "r18dev", "javbus", "avg"):
        try:
            value = float(scores.get(key) or 0)
        except (TypeError, ValueError):
            value = 0.0
        if value:
            return value
    return 0.0


def _stats_prefix(number: str) -> str:
    """与客户端 Reason.ets 的 prefixOf() 保持一致。"""
    i = number.find("-")
    return number[:i] if i > 0 else (number[:3] if len(number) > 3 else number)


def library_stats_full() -> dict:
    """全库分布：评分 0.5 分档直方图、时长 30 分钟档、各维度计数。

    返回的是**完整**字典（只存在服务端内存里）；真正下发给客户端的是
    library_stats_for() 裁剪过的子集。任何异常都降级成 total=0，绝不拖垮首页。
    """
    try:
        stamp = int(os.path.getmtime(AMANE_DB)) // 3600
    except OSError:
        stamp = 0
    key = f"{date.today().isoformat()}|{stamp}"
    hit = _LIB_STATS_CACHE
    if hit["key"] == key and hit["data"] is not None:
        return hit["data"]
    with _LIB_STATS_LOCK:
        if hit["key"] == key and hit["data"] is not None:
            return hit["data"]
        out = {
            "total": 0, "scored": 0, "avg_score": 0.0, "max_score": 0.0,
            "min_year": 0, "max_year": 0, "watched": 0, "favorites": 0,
            "tag_kinds": 0, "actor_kinds": 0, "prefix_kinds": 0,
            "score_bins": [0] * 21, "runtime_bins": [0] * 12,
            "tags": {}, "actors": {}, "series": {}, "studios": {},
            "prefixes": {}, "years": {},
        }
        try:
            with amane_db() as conn:
                rows = conn.execute(
                    "SELECT m.scores, m.tags, m.actors, m.series, m.studio, "
                    "m.number, m.release, m.runtime FROM metadata m "
                    "JOIN (SELECT DISTINCT metadata_id FROM media_files) f "
                    "ON f.metadata_id = m.id"
                ).fetchall()
            total = 0
            scored = 0
            score_sum = 0.0
            max_score = 0.0
            min_year = 9999
            max_year = 0
            bins = out["score_bins"]
            runbins = out["runtime_bins"]
            tags, actors = out["tags"], out["actors"]
            series, studios = out["series"], out["studios"]
            prefixes, years = out["prefixes"], out["years"]
            for row in rows:
                total += 1
                sc = _stats_score(row["scores"])
                if sc > 0:
                    scored += 1
                    score_sum += sc
                    if sc > max_score:
                        max_score = sc
                    b = int(round(sc * 2))
                    bins[max(0, min(20, b))] += 1
                for t in _json_list(row["tags"])[:12]:
                    tags[t] = tags.get(t, 0) + 1
                for a in _json_list(row["actors"])[:8]:
                    actors[a] = actors.get(a, 0) + 1
                s = (row["series"] or "").strip()
                if s:
                    series[s] = series.get(s, 0) + 1
                st = (row["studio"] or "").strip()
                if st:
                    studios[st] = studios.get(st, 0) + 1
                pre = _stats_prefix(row["number"] or "")
                if pre:
                    prefixes[pre] = prefixes.get(pre, 0) + 1
                rel = row["release"] or ""
                if len(rel) >= 4 and rel[:4].isdigit():
                    y = int(rel[:4])
                    if 1900 <= y <= 2100:
                        years[rel[:4]] = years.get(rel[:4], 0) + 1
                        if y < min_year:
                            min_year = y
                        if y > max_year:
                            max_year = y
                rt = row["runtime"] or 0
                if rt > 0:
                    runbins[max(0, min(11, int(rt // 30)))] += 1
            out.update({
                "total": total, "scored": scored,
                "avg_score": round(score_sum / scored, 2) if scored else 0.0,
                "max_score": round(max_score, 2),
                "min_year": min_year if min_year != 9999 else 0,
                "max_year": max_year,
                "tag_kinds": len(tags), "actor_kinds": len(actors),
                "prefix_kinds": len(prefixes),
            })
        except Exception as exc:
            log(f"WARN 全库统计扫描失败: {exc}")
            out["total"] = 0
        try:
            with user_db() as uc:
                out["watched"] = int(uc.execute(
                    "SELECT COUNT(DISTINCT metadata_id) FROM history").fetchone()[0])
                out["favorites"] = int(uc.execute(
                    "SELECT COUNT(*) FROM favorites").fetchone()[0])
        except Exception as exc:
            log(f"WARN 全库统计读用户库失败: {exc}")
        hit["key"] = key
        hit["data"] = out
        return out


def library_stats_for(items: list[dict]) -> dict:
    """只下发这批卡片涉及的键，避免把几千个标签计数塞进 home 响应。

    返回的每个维度是 [{"k": 名称, "n": 全库片数}]，客户端按 k 直接查。
    """
    full = library_stats_full()
    if not full["total"]:
        return {"total": 0}
    want: dict[str, set] = {
        "tags": set(), "actors": set(), "series": set(),
        "studios": set(), "prefixes": set(), "years": set(),
    }
    for it in items:
        for t in (it.get("tags") or [])[:12]:
            want["tags"].add(t)
        for a in (it.get("actors") or [])[:8]:
            want["actors"].add(a)
        if it.get("series"):
            want["series"].add(it["series"])
        if it.get("studio"):
            want["studios"].add(it["studio"])
        pre = _stats_prefix(it.get("number") or "")
        if pre:
            want["prefixes"].add(pre)
        rel = it.get("release") or ""
        if len(rel) >= 4 and rel[:4].isdigit():
            want["years"].add(rel[:4])

    def shrink(name: str) -> list[dict]:
        src = full[name]
        keys = sorted(want[name])
        return [{"k": k, "n": int(src.get(k, 0))} for k in keys[:120]]

    return {
        "total": full["total"], "scored": full["scored"],
        "avg_score": full["avg_score"], "max_score": full["max_score"],
        "min_year": full["min_year"], "max_year": full["max_year"],
        "watched": full["watched"], "favorites": full["favorites"],
        "tag_kinds": full["tag_kinds"], "actor_kinds": full["actor_kinds"],
        "prefix_kinds": full["prefix_kinds"],
        "score_bins": full["score_bins"], "runtime_bins": full["runtime_bins"],
        "tags": shrink("tags"), "actors": shrink("actors"),
        "series": shrink("series"), "studios": shrink("studios"),
        "prefixes": shrink("prefixes"), "years": shrink("years"),
    }


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
    # 媒体库封面（2.5.5.4）：换过的用自定义图，没换过给空串由客户端拼海报墙
    cov = cover_override_all("library")
    out: list[dict] = []
    for r in rows:
        if not r["n"]:
            continue
        key = f"lib-{r['id']}"
        out.append({"id": r["id"], "name": r["name"], "count": r["n"],
                    "cover": cov.get(key, "")})
    return out


def build_home(fresh: bool = False) -> dict:
    libs = libraries()
    rows_out: list[dict] = []
    with amane_db() as conn:
        for lib in libs:
            items = query_meta(conn, "f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)",
                               (lib["id"],), "m.updated_at DESC", 18)
            if items and lib["count"] >= 4:
                rows_out.append({"kind": "library", "id": f"lib-{lib['id']}", "title": lib["name"],
                                 "library_id": lib["id"], "count": lib["count"],
                                 # 覆盖层（2.5.5）：首页媒体库行也要吃「改过的封面 / 片名」。
                                 # 以前这里只 attach_marks，导致详情页换了封面，首页还是旧图。
                                 "items": attach_marks(conn, attach_progress(apply_overrides(items)))})

    recommend = build_recommend(20)
    # 首页这几条是用户第一眼看到的：尺寸没量过的现场补（并发 + 超时），
    # 免得发布版用户空缓存时只能看第一张糊图。
    # 下拉刷新（fresh）不跑这一步：那是几秒的联网开销，下拉只该"重新取一遍"——
    # 没量过的图已经由 pick_fanart 用 thumb 兜底，不会糊。
    if not fresh:
        _probe_home_fanarts(recommend)
    hero = [x for x in recommend if x["fanart"]][:6] or recommend[:4]
    # 每日推荐横幅：只放「宽度 ≥720 且宽高比 ≥1.25」的真横图，并带上真实比例，
    # 客户端按比例定宽（16:9 不是唯一答案：dmm 剧照多是 3:2）。
    banners = build_banners(12, fresh=fresh)
    # 2.5.7.21：全库级事实（「评分前 5%」「这个标签全库只有 7 部」）。
    # 统计失败/老服务端一律降级成 total=0，客户端会跳过全库族，其余理由照常显示。
    try:
        lib_stats = library_stats_for(list(recommend) + list(banners))
    except Exception as exc:
        log(f"WARN 首页全库统计摘要失败: {exc}")
        lib_stats = {"total": 0}

    return {
        "hero": hero,
        "continue": build_continue(),
        "rows": rows_out,
        "recommend": recommend,
        "banners": banners,
        "libraries": libs,
        "library_stats": lib_stats,
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


def _probe_home_fanarts(items: list, budget: int = 36, wait: float = 6.0) -> None:
    """首页这批的图尺寸如果没缓存，**现场并发量一批**，并就地重算 fanart。

    为什么必须在服务端做：`img_dims` 是每台机器自己的缓存，发布版用户拿到的是空表。
    只靠「后台懒预热」的话，新装用户每次翻页看到的都是第一张（常是 147x200 的封面）。
    这里宁可第一次打开慢一两秒，也不给糊图；结果落缓存，之后零网络。
    """
    ids = [int(x["id"]) for x in items if x.get("id")]
    if not ids:
        return
    try:
        with amane_db() as conn:
            ph = ",".join("?" * len(ids))
            rows = {int(r["id"]): r for r in conn.execute(
                "SELECT " + META_COLUMNS + f" FROM metadata m WHERE m.id IN ({ph})", ids)}
    except (sqlite3.Error, ValueError):
        return

    plan: dict[int, sqlite3.Row] = {}
    pool: list[list[str]] = []
    for mid, row in rows.items():
        cands = [u for lst in _json_dict(row["extrafanart_urls"]).values()
                 for u in _json_list(lst)
                 if isinstance(u, str) and u.startswith("http")][:3]
        if not cands or _dims_bulk(cands):
            continue                      # 没剧照，或已经量过 → 不动
        plan[mid] = row
        pool.append(cands)
    if not plan:
        return
    # 按「第 1 张 → 第 2 张 → 第 3 张」轮转取，让有限预算先覆盖尽可能多的片：
    # 只要知道第一张合不合格，就能决定要不要往后找。
    todo: list[str] = []
    for i in range(3):
        for cands in pool:
            if i < len(cands):
                todo.append(cands[i])
    todo = list(dict.fromkeys(todo))[:budget]

    def one(u: str) -> None:
        try:
            image_dims(u)                 # 内部有 8s 超时并落库
        except Exception:                 # noqa: BLE001
            pass

    threads = [threading.Thread(target=one, args=(u,), daemon=True) for u in todo]
    for t in threads:
        t.start()
    for t in threads:
        t.join(wait)

    for it in items:
        mid = int(it.get("id") or 0)
        if mid in plan:
            it["fanart"] = pick_fanart(plan[mid])


def build_recommend(limit: int = 20) -> list[dict]:
    libs = [lib for lib in libraries() if lib["count"] >= 30]
    if not libs:
        with amane_db() as conn:
            return attach_marks(conn, attach_progress(query_meta(conn, "", (), "m.updated_at DESC", limit)))
    pool: list[dict] = []
    # 每天的种子：推荐位要**当天固定**（用户定的），所以库里不能用 RANDOM() 抽池子 ——
    # 那会让每次请求（包括下拉刷新）拿到不同的一批 40 部。改成按「id × 常数 + 当日种子」
    # 取模排序：同一天恒定，第二天自然换一批。
    day_seed = int(date.today().strftime("%Y%m%d"))
    with amane_db() as conn:
        for lib in libs:
            items = query_meta(
                conn,
                "f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)",
                (lib["id"],),
                "((m.id * 1103515245 + %d) %% 2147483647)" % day_seed,
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
    # 覆盖层：推荐位同样要显示改过的片名 / 自定义封面
    return attach_marks_auto(attach_progress(apply_overrides(out)))


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
            for row in rows:
                if checked >= tries or time.monotonic() > deadline:
                    break
                if row["id"] in done:
                    continue
                checked += 1
                # _pick_banner 里是网络取图头（可能要 1~8 秒）。**不能把它包在写事务里**：
                # 原来整轮 40 次探测共用一条 user_db 连接，写锁一攥就是几秒，
                # 打分/入库这些写入就得排队（2026-11-12 的整库锁事故同源）。
                # 现在每写成一条就单独开一次短事务。
                url, ratio = _pick_banner(None, row)
                stamp = now_iso()
                try:
                    with user_db() as wconn:
                        if not url:
                            # 拒绝也落一条（url 为空）：下一轮直接跳过，不再重复探测
                            wconn.execute(
                                "INSERT INTO banner_ok(metadata_id, url, ratio, updated_at) "
                                "VALUES(?, '', 0, ?) ON CONFLICT(metadata_id) DO UPDATE SET "
                                "url = '', ratio = 0, updated_at = excluded.updated_at",
                                (row["id"], stamp),
                            )
                        else:
                            wconn.execute(
                                "INSERT INTO banner_ok(metadata_id, url, ratio, updated_at) "
                                "VALUES(?, ?, ?, ?) ON CONFLICT(metadata_id) DO UPDATE SET "
                                "url = excluded.url, ratio = excluded.ratio, "
                                "updated_at = excluded.updated_at",
                                (row["id"], url, ratio, stamp),
                            )
                except sqlite3.Error as exc:
                    log(f"WARN 横幅池写入失败 {row['id']}: {exc}")
                    continue
                if url:
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


def _banner_rows(limit: int, fresh: bool = False) -> list[dict]:
    """从已校验池里按日种子洗牌取前 N；洗牌结果当日缓存。

    `fresh=True`（下拉刷新）：**绕过日种子**，真随机洗一遍 —— 用户定的行为是
    「横幅每次下拉换一批」，池子是当天的（保证每张都是合格横图），顺序才换。

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
        # 覆盖层在**入缓存前**套好：列表元素是同一批 dict，出缓存时再套会污染缓存
        # （恢复默认后仍显示改过的值）。
        apply_overrides(items)
        _banner_daily_key = key
        _banner_daily_rows = items
    if fresh:
        # 下拉刷新：真随机洗一遍再取前 N（不动当日缓存，也不改推荐位的日种子）
        shuffled = list(_banner_daily_rows)
        random.shuffle(shuffled)
        return shuffled[:limit]
    return list(_banner_daily_rows[:limit])


def build_banners(limit: int = 12, fresh: bool = False) -> list[dict]:
    items = _banner_rows(limit, fresh=fresh)
    if len(items) < limit:
        _kick_banner_warm()
    if items:
        with amane_db() as conn:
            attach_marks(conn, items)
    return items


def cached_home(fresh: bool = False) -> dict:
    """库行 / 推荐 / hero 缓存 5 分钟；继续观看每次现算。

    `fresh=True`（客户端下拉刷新）**绕开这份缓存**重算一次，并把横幅重新洗一遍 ——
    「下拉只转圈不换内容」就是因为它拿的还是缓存里那份一模一样的 JSON。
    推荐位仍按当天种子（用户定的：推荐一天固定），只有横幅是每次下拉换一批。
    """
    key = date.today().isoformat()
    hit = _home_cache.get(key)
    now = time.time()
    if not fresh and hit and now - hit[0] < HOME_TTL:
        base = dict(hit[1])
    else:
        data = build_home(fresh=fresh)
        base = {k: v for k, v in data.items() if k != "continue"}
        if fresh:
            # 强制刷新不写缓存：免得把「随机挑的一批」固化成接下来 5 分钟的首页
            _home_cache.clear()
        else:
            _home_cache.clear()
            _home_cache[key] = (now, base)
        base = dict(base)
    base["continue"] = build_continue()
    base["generated_at"] = now_iso()
    return base


def invalidate_item_caches() -> None:
    """改了某部片（字段 / 封面）之后调用：首页聚合与横幅池都要立刻重算。

    以前没这一步，表现是「详情页封面换了，回首页还是旧图，等 5 分钟才好」。
    横幅缓存存的是同一批 dict，且已套过覆盖层，所以必须整池丢弃重扫。
    """
    global _banner_daily_key
    _home_cache.clear()
    _banner_daily_key = ""
    _banner_daily_rows.clear()


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
    """把库里的图片地址转成**外网可达**的旁挂路径。

    三种形态：
      * `/api/resources/<hash>` → `/api/user/res/<hash>`。上游 amane 只在内网 :8000
        可达，客户端 `Store.img()` 又按前缀把这类地址分流到上游 —— 用户在外网
        （4G / 域名访问）时这张图就是白屏。必须由旁挂转一手。
      * 外链 → `/img?b=<base64url>&t=...`（先过 host 白名单）。
      * 其它 → 空串，调用方退回占位图。
    """
    if not isinstance(url, str):
        return ""
    if url.startswith("/api/resources/"):
        return "/api/user/res/" + url[len("/api/resources/"):]
    if not url.startswith("http"):
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



class PlayPump:
    """每个文件一个**顺序**读盘线程，读到的块放进环形缓冲，供所有 Range 请求直接取用。

    为什么：像 MIDE-776 这种音轨/视频轨各占一大片的文件，解复用器每秒要发 20 条
    范围请求、位置还很分散。按请求去读盘/回源，每次都要付一次「定位 + 往返」的代价，
    永远比播放快不了。改成「一个线程顺着读、请求只从缓冲里拿」，底层 I/O 就变成纯顺序，
    这正是用户说的「双缓冲交替」——只是把交替放在服务端做，播放器完全无感。
    """

    def __init__(self, path: str, block: int) -> None:
        self.path = path
        self.block = block
        self.lock = threading.Condition()
        self.blocks: dict = {}
        self.order: list = []
        self.head = 0
        self.gen = 0
        self.dead = False
        self.max_blocks = 96
        self.window = 64          # 允许「不等改道」的前瞻窗口（块）
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        try:
            fh = open(self.path, "rb")
        except OSError as exc:
            log(f"pump open {self.path}: {exc}")
            self.dead = True
            return
        with fh:
            while not self.dead:
                with self.lock:
                    blk = self.head
                    gen = self.gen
                try:
                    fh.seek(blk * self.block)
                    data = fh.read(self.block)
                except OSError as exc:
                    log(f"pump read {self.path} blk {blk}: {exc}")
                    self.dead = True
                    return
                if not data:
                    with self.lock:
                        if self.gen == gen:
                            self.dead = True
                        self.lock.notify_all()
                    return
                with self.lock:
                    self.blocks[blk] = data
                    self.order.append(blk)
                    while len(self.order) > self.max_blocks:
                        old = self.order.pop(0)
                        if old != blk:
                            self.blocks.pop(old, None)
                    if self.gen == gen:
                        self.head = blk + 1
                    self.lock.notify_all()

    def get(self, blk: int, wait: float = 8.0) -> bytes | None:
        """要第 blk 块。不在缓冲里就让读线程跳过去读。"""
        deadline = time.time() + wait
        with self.lock:
            if blk in self.blocks:
                return self.blocks[blk]
            # 只有落在当前窗口之外才改道：窗口内的请求（含回看几块）一律排队等读线程
            # 顺序读到那儿，绝不打断正在进行的顺序读 —— 一打断就退化成随机读。
            if blk > self.head + self.window or blk < self.head - 8:
                self.head = blk
                self.gen += 1
                self.lock.notify_all()
            while blk not in self.blocks:
                left = deadline - time.time()
                if left <= 0 or self.dead:
                    return None
                self.lock.wait(min(left, 0.5))
            return self.blocks[blk]

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


_PLAY_PUMPS: dict = {}
_PUMP_LOCK = threading.Lock()

PLAY_DISK = PlayDiskCache(os.path.join(DATA_DIR, "play-cache", "v4"),
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

    # 投屏令牌只放行这四类**只读媒体**路径（2.5.6）。
    # 电视 / 盒子拿到的就是这个 `ct`，绝不能让它顺手改数据或删快照。
    CAST_PATHS = ("/api/user/play/", "/api/user/streams/",
                  "/api/user/photo/", "/api/user/studio-logo/",
                  # 电视要能自己拉字幕与封面（都是只读的东西）
                  "/api/user/subtitle/", "/api/user/subtitles",
                  "/api/user/cast/cover/")

    def _cast_ok(self, path: str, method: str, query: dict) -> bool:
        if method not in ("GET", "HEAD"):
            return False
        token = (query.get("ct") or [""])[0]
        if not re.fullmatch(r"[0-9a-f]{32}", token or ""):
            return False
        if not path.startswith(self.CAST_PATHS):
            return False
        return cast_token_valid(token)

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
            if not self._authed(query) and not self._cast_ok(parsed.path, method, query):
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

    @route("GET", r"/api/user/update/manifest")
    def update_manifest(self, query, *_) -> None:
        """把部署者准备的一份更新清单原样交给客户端。

        客户端默认按 GitHub 的 Release asset / 仓库镜像找清单；这个端点是**私有部署**
        的兜底：不联网、或想让客户端只听自己服务器的，把 update.json 放到
        `data/update.json`（或用 `UPDATE_MANIFEST` 指到别处）即可。
        没有这份文件就回 404 —— 客户端把它记成「这个源没有」，不影响其他源。
        """
        path = os.environ.get("UPDATE_MANIFEST", os.path.join(DATA_DIR, "update.json"))
        if not os.path.isfile(path):
            return self._error(404, "未配置更新清单（把 update.json 放到 data/ 目录）")
        try:
            with open(path, "rb") as fh:
                payload = json.loads(fh.read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"更新清单读不出来：{exc}")
        if not isinstance(payload, dict) or "client" not in payload:
            return self._error(500, "更新清单格式不对：缺 client 段")
        return self._json(payload)

    @route("GET", r"/api/user/res/([0-9a-fA-F]{6,64})")
    def resource_image(self, query, name, *_) -> None:
        """代理上游资源库的图（`/api/resources/<hash>`）。

        为什么必须代理：客户端 `Store.img()` 按前缀把 `/api/resources/` 分流到上游
        amane（内网 :8000）。用户在 4G / 域名访问时那台不可达，海报整片白屏 ——
        而 `/img?` 与 `/api/user/photo/` 都在旁挂服务上，外网可达。
        """
        if not self._authed(query):
            return self._error(401, "需要 token")
        target = f"{AMANE_BASE}/api/resources/{name}"
        try:
            req = Request(target, headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
            with urlopen(req, timeout=20) as resp:
                data = resp.read()
                ctype = (resp.headers.get("Content-Type")
                         or mimetypes.guess_type(name)[0] or "image/jpeg")
        except HTTPError as exc:
            return self._error(404 if exc.code == 404 else 502, f"上游返回 {exc.code}")
        except (URLError, TimeoutError, OSError) as exc:
            return self._error(502, f"抓取失败: {exc}")
        if not data:
            return self._error(404, "资源为空")
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
    # 4MiB：实测这类「音轨与视频轨各占一大片」的文件，解复用器每秒来回跳十几次，
    # 1MiB 块每次跳都要回源一次（首字节 40–300ms）。块放大到 4MiB 后，
    # 一个区域被命中一次就能连续供好几秒画面，来回次数直接降到 1/4。
    PLAY_BLOCK = 4 * 1024 * 1024
    PLAY_CACHE_VERSION = 4
    PLAY_READAHEAD = 2
    PLAY_MAX_JOBS = 96
    PLAY_CACHE_BYTES = int(os.environ.get("AMANE_PLAY_CACHE_MB", "512")) * 1024 * 1024
    # 多久「没写过东西」才算僵尸流。**不能设 1.5 秒**：mpv 自己的缓存满了会正常停止读取
    # 十几秒甚至更久，早先按 1.5 秒判死，就会出现「播着播着又被判死 → 重新起流 →
    # 再缓存」的死循环（本地片也一样，所以不是网盘的问题）。
    PLAY_STALL_DROP = float(os.environ.get("AMANE_PLAY_STALL_DROP", "30"))
    _play_lock = threading.Lock()
    _play_blocks: OrderedDict = OrderedDict()
    _play_stat: dict = {"bytes": 0}
    _play_jobs: dict = {}
    _play_meta: dict[str, dict] = {}
    # 每条 session 上一次读到的块号（判断是否顺序读）
    _play_seq: dict[str, int] = {}

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
                    elif resp.status == 200 and blk > 0:
                        # 上游没认 Range，回的是**整个文件**。把开头 1MB 当成第 blk 块，
                        # 缓存就被污染 → 一拖进度条 mpv 读到垃圾字节，会不停重开连接
                        # （「从头播没事，一拖就卡」就是这么来的）。宁可这块失败，也不写缓存。
                        job.failed = True
                        log(f"play block {blk} upstream ignored Range (200), not cached")
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
                if resp.status == 200 and start > 0:
                    log(f"play fetch {start}+{size}: upstream ignored Range (200)")
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
            # 磁盘已缓存 → 直接按需读文件写 socket（省掉整块 memcpy 与任务表开销）
            dpath = PLAY_DISK._path(upstream, blk)
            if PLAY_DISK.budget > 0 and os.path.isfile(dpath):
                try:
                    with open(dpath, "rb") as fh:
                        fh.seek(off)
                        left = need
                        while left > 0:
                            # 1MiB 一片：每片一次 select + 一次 write，小片段会把
                            # 每条请求的开销摊到 CPU 上（这类文件 20 条请求/秒）
                            chunk = fh.read(min(1048576, left))
                            if not chunk:
                                break
                            reason = self._play_write(session, session_key, chunk)
                            if reason:
                                return reason
                            left -= len(chunk)
                        if left == 0:
                            pos += need
                            counter += need
                            continue
                except OSError as exc:
                    log(f"play disk read {dpath}: {exc}")
                # 读失败/不足 → 落回下面按任务取

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
            # 只有「接着上一块」才算顺序读，才值得预读。跳着读（解复用器来回找音轨/视频轨）
            # 时预读全是废料，还会把任务池占满，把用户真正要的块挤到后面。
            prev_blk = self._play_seq.get(session_key, -2)
            self._play_seq[session_key] = blk
            if prev_blk == -2:
                # 每条 session 的**第一次**请求：把落点往后 8 块 + 文件头 4 块一次性拉下来
                # （头块里通常是索引，解复用器每次开流都要读）。只做一次，不按请求重复做。
                warm: list = list(range(blk, min(blk + 8, last + 1)))
                warm += [b for b in range(0, min(4, last + 1))]
                self._play_prefetch(upstream, ck, warm)
            # 同一片区域内的连续读（含「还停在同一块」和「刚进下一块」）都算顺序，
            # 这时预读才有用；跨区域跳（音轨↔视频轨）不预读，免得占满任务池。
            if prev_blk == -2 or (blk - prev_blk) in (0, 1):
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

    def _local_path_for(self, key: str) -> str:
        """把 `?key=f<文件id>` 翻译成容器里能直接打开的文件路径。

        上游 amane 的库里就存着绝对路径（`media_files.path`），而我们本来就能只读它的 SQLite，
        容器又挂着 `/media`、`/media2`。所以本地片不必再绕一圈上游 HTTP：
        直接开文件、seek、发字节 —— 少一整跳，也没有 token 参与。
        """
        if not key.startswith("f"):
            return ""
        try:
            fid = int(key[1:])
        except ValueError:
            return ""
        try:
            with amane_db() as conn:
                row = conn.execute(
                    "SELECT path FROM media_files WHERE id = ?", (fid,)).fetchone()
        except Exception as exc:  # noqa: BLE001
            log(f"WARN play 查文件路径失败 {fid}: {exc}")
            return ""
        path = str((row["path"] if row else "") or "")
        if not path or not os.path.isfile(path):
            return ""
        return path


    def _play_pumped(self, path: str, head_only: bool) -> str:
        """顺序读泵版：Range 请求只从缓冲取，底层只有一个顺序读盘线程。"""
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        with _PUMP_LOCK:
            pumps = [x for x in _PLAY_PUMPS.get(path, []) if not x.dead]
            pump = None
            best = None
            for cand in pumps:
                with cand.lock:
                    head = cand.head
                dist = abs(head - (start // self.PLAY_BLOCK))
                if dist <= 256 and (best is None or dist < best):
                    best = dist
                    pump = cand
            if pump is None:
                # 没有热区靠近：能复用最远的那个就复用（改道），否则新建，最多 3 个
                if len(pumps) >= 3:
                    pump = pumps[0]
                else:
                    pump = PlayPump(path, self.PLAY_BLOCK)
                    pumps.append(pump)
                _PLAY_PUMPS[path] = pumps

        pos = start
        sent = 0
        try:
            while pos <= end:
                blk = pos // self.PLAY_BLOCK
                off = pos - blk * self.PLAY_BLOCK
                want = min(self.PLAY_BLOCK - off, end - pos + 1)
                blob = pump.get(blk)
                if blob is None:
                    return "pump-miss"
                piece = bytes(blob[off:off + want])
                if piece:
                    self.wfile.write(piece)
                    sent += len(piece)
                pos += want
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    def _play_local_sendfile(self, path: str, head_only: bool) -> str:
        """用 os.sendfile 零拷贝直发本地文件。

        播放器这类「每秒几十条 Range」的访问模式，真正的成本是**每条请求的用户态拷贝**：
        读进 bytes 再 write 出去，几十次/秒就把 CPU 和延迟吃满了。
        Emby 那类软件 Direct Play 之所以顺，靠的就是内核 sendfile + 页缓存：
        协议解析在用户态，数据搬运全在内核，单条请求通常 1–3ms。
        """
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return "range-416"
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        try:
            out_fd = self.connection.fileno()
        except (OSError, ValueError):
            return "no-fd"
        sent = 0
        try:
            with open(path, "rb") as fh:
                in_fd = fh.fileno()
                # 让内核提前把接下来这一段读进页缓存（Emby 之类顺滑，靠的就是页缓存命中）。
                # 只影响缓存预读，不占额外磁盘。
                try:
                    os.posix_fadvise(in_fd, start, 32 * 1024 * 1024,
                                     os.POSIX_FADV_WILLNEED)
                except (AttributeError, OSError):
                    pass
                offset = start
                left = end - start + 1
                while left > 0:
                    n = min(left, 4 * 1024 * 1024)
                    try:
                        moved = os.sendfile(out_fd, in_fd, offset, n)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if moved == 0:
                        break
                    offset += moved
                    sent += moved
                    left -= moved
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    def _play_local_file(self, path: str, head_only: bool) -> str:
        """直接读本地文件，**并复用块缓存**（块落在容器本地盘，随机跳读才不会每次都打到 NAS）。"""
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return "range-416"
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        ck = f"local:{path}"
        pos = start
        sent = 0
        try:
            with open(path, "rb") as src:
                while pos <= end:
                    blk = pos // self.PLAY_BLOCK
                    off = pos - blk * self.PLAY_BLOCK
                    want = min(self.PLAY_BLOCK - off, end - pos + 1)
                    mkey = f"{ck}#{blk}"
                    blob = self._play_cache_get(mkey)
                    if blob is None:
                        dpath = PLAY_DISK._path(ck, blk)
                        if os.path.isfile(dpath):
                            try:
                                with open(dpath, "rb") as fh:
                                    blob = fh.read()
                            except OSError:
                                blob = None
                        if blob is None:
                            # 一次读 8 个块（32MiB）：网络盘上随机读的代价主要在「每次 seek 的
                            # 往返」，一次多读一点能把后面十几次跳读都变成命中。
                            src.seek(blk * self.PLAY_BLOCK)
                            bulk = src.read(self.PLAY_BLOCK * 8)
                            if not bulk:
                                break
                            for i in range(0, (len(bulk) + self.PLAY_BLOCK - 1) // self.PLAY_BLOCK):
                                part = bulk[i * self.PLAY_BLOCK:(i + 1) * self.PLAY_BLOCK]
                                if not part:
                                    break
                                dp = PLAY_DISK._path(ck, blk + i)
                                try:
                                    os.makedirs(os.path.dirname(dp), exist_ok=True)
                                    tmpf = dp + ".tmp"
                                    with open(tmpf, "wb") as fh:
                                        fh.write(part)
                                    os.replace(tmpf, dp)
                                except OSError:
                                    pass
                            blob = bulk[:self.PLAY_BLOCK]
                            if not blob:
                                break
                            try:
                                os.makedirs(os.path.dirname(dpath), exist_ok=True)
                                tmp = dpath + ".tmp"
                                with open(tmp, "wb") as fh:
                                    fh.write(blob)
                                os.replace(tmp, dpath)
                            except OSError:
                                pass
                        self._play_cache_put(mkey, blob)
                    piece = bytes(blob[off:off + want])
                    if piece:
                        self.wfile.write(piece)
                        sent += len(piece)
                    pos += want
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    @route("GET", r"/api/user/play/([^/]+)/(\d+)")
    @route("HEAD", r"/api/user/play/([^/]+)/(\d+)")
    def play(self, query: dict, source: str, mid: str) -> None:
        head_only: bool = self.command == "HEAD"
        # ?key=f<文件id> 指定版本；不带 key 时仍交给上游自己挑一条
        key = (query.get("key") or [""])[0]
        suffix = ""
        if re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", key):
            suffix = f"/streams/{key}"
        # 本地片：库里就有绝对路径，直接读文件，比再走一圈上游 HTTP 快得多
        # 默认本地直发（sendfile 零拷贝，单请求 9–15ms）；?local=0 强制回上游代理做 A/B。
        local_mode = (query.get("local") or ["1"])[0]
        if source == "nas.local" and key and local_mode != "0":
            local_p = self._local_path_for(key)
            if local_p:
                return self._play_local_sendfile(local_p, self.command == "HEAD")

        want_pump = (query.get("pump") or ["0"])[0] == "1"
        if source == "nas.local" and key and want_pump:
            local_p = self._local_path_for(key)
            if local_p:
                return self._play_pumped(local_p, self.command == "HEAD")

        # 本地直读目前**默认关闭**：本机压测里它反而更慢（0.82–0.84x vs 走上游 0.98x），
        # 说明这条路径的块缓存命中还有问题，先留开关（AMANE_PLAY_LOCAL=1 可开）待排查。
        if source == "nas.local" and key and USE_LOCAL_PLAY:
            local = self._local_path_for(key)
            if local:
                started_local = time.time()
                reason_local = "?"
                try:
                    self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except OSError:
                    pass
                reason_local = self._play_local_file(local, self.command == "HEAD")
                spent_local = max(time.time() - started_local, 1e-6)
                log(f"play local {os.path.basename(local)} range={self.headers.get('Range', '-')} "
                    f"-> {reason_local} in {spent_local:.2f}s")
                return

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
                    # 只掐「很久没读写」的旧流：那是客户端真的走了的僵尸。
                    # 正常在跑的连接（比如 mp4 读尾部索引那一路）一律留着。
                    if old["idle"] > 0 and now - old["idle"] > self.PLAY_STALL_DROP:
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
            # 预热策略分两种（2026-11-12 实测：拖到中间后 mpv 缓存长期 0.0–0.2s，
            # 每 4 秒播完就重缓冲，说明「跳到的那一点之后」没有提前拉）：
            #   · 从头起播 → 预热头块 + 尾块（MP4 的 moov 常在尾部）
            #   · 拖到中间 → 从落点开始连拉 8 块，让 mpv 一起来就有十几秒余量
            if start < self.PLAY_BLOCK * 2 and len(self._play_jobs) < self.PLAY_MAX_JOBS // 2:
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
                    if old["idle"] > 0 and now - old["idle"] > self.PLAY_STALL_DROP:
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
        fresh = (query.get("fresh") or ["0"])[0] in ("1", "true", "yes")
        self._json(cached_home(fresh=fresh))

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
        # 检索归一化（2.5.1）：先繁转简，后面拆词 / 排序 / 匹配统一用归一化后的词。
        # 只影响查询侧：库里的数据一个字节都不改，关掉功能也不会留下脏数据。
        search_norm = norm_query(search)
        # q 与 qmode 是「词之间」的关系：and（默认，全部词都要命中）/ or（任一词命中即可）。
        # 客户端在结果过少时自己退到 or，服务端不替它决定（避免搜索结果忽多忽少）。
        qmode = arg("qmode", "and").lower()
        tokens = [x for x in re.split(r"[\s\-_/]+", search_norm) if x][:6]
        groups: list[tuple[str, tuple]] = []

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
            # 排序用归一化后的词：繁体输入（癡女）也要让标题里写「痴女」的那部排前面，
            # 否则「命中靠 t2s、排序靠原文」会排出一堆不相关的。
            kw_esc = re.sub(r"([%_\\])", r"\\\1", search_norm)
            order = (
                "CASE WHEN UPPER(m.number) = UPPER(?) THEN 0 "
                "WHEN REPLACE(UPPER(m.number), '-', '') = REPLACE(UPPER(?), '-', '') THEN 0 "
                "WHEN UPPER(m.number) LIKE UPPER(?) ESCAPE '\\' THEN 1 "
                "WHEN m.title LIKE ? ESCAPE '\\' THEN 2 "
                "WHEN m.series LIKE ? ESCAPE '\\' THEN 3 "
                "ELSE 4 END ASC, " + order
            )
            rel_params = (
                search_norm, search_norm, kw_esc + "%",
                "%" + kw_esc + "%", "%" + kw_esc + "%"
            )

        where: list[str] = []
        params: tuple = ()

        if lib_id:
            try:
                where.append("f.metadata_id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)")
                params = (*params, int(lib_id))
            except ValueError:
                return self._error(400, "library_id 必须是整数")

        # 按分类**名字**筛（2.5.5.16）：自建分类（覆盖层里新起的系列 / 标签）没有 id，
        # 只能按名字查。把「库里本来属于这个名字的」和「被改到这个名字下的」并成一条，
        # 这样自建分类和原分类走同一个 browse —— 关键词 / 评分 / 收藏 / 排序全部等价。
        facet_kind = arg("facet_kind").lower()
        facet_name = arg("facet_name")
        if facet_name and facet_kind in ("series", "tag", "studio", "actor"):
            over_ids = override_ids_for(facet_kind, facet_name)
            if facet_kind in ("series", "studio"):
                cond = "m.%s = ?" % facet_kind
                fparams: list = [facet_name]
            elif facet_kind == "actor":
                cond = "m.actors LIKE ?"
                fparams = [f"%{facet_name}%"]
            else:
                cond = ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                        "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)")
                fparams = [facet_name]
            if over_ids:
                marks = ",".join("?" * len(over_ids))
                cond = f"({cond} OR m.id IN ({marks}))"
                fparams = fparams + over_ids
            where.append(cond)
            params = (*params, *fparams)

        if search:
            # 模糊搜索：按空格 / 连字符拆词，每个词都要命中（AND）。
            # number 额外去掉连字符再比一次，这样 "ipzz932" 能搜到 "IPZZ-932"，
            # "ipzz 932" 拆成两个词也照样命中。
            # 再叠一层 amane_rel：全角输入（ｉｐｚｚ－９３２）、大小写、少打一个连字符
            # 都能命中 —— LIKE 只认字面，归一化得交给这个标量函数。
            # 只对番号做：标题是长日文，逐行归一化+子序列会让搜索从 40ms 涨到 400ms，
            # 而中文标题本来就是全角，LIKE 已经能命中。
            #
            # 2.5.1 起每个词还有三条额外通路（都只改**查询侧**，不动库里的数据）：
            #   ① 繁体转简体（癡女 → 痴女）；
            #   ② 标签名子查询（原来只搜 number/title/actors/series，标签词根本搜不到）；
            #   ③ 拼音首字母 / 全拼（scg → 搜查官，ntr → 牛头人）。
            for tok in tokens:
                like = f"%{tok}%"
                # 番号相关的三条只在「这个词可能是番号」时才加。
                # 判据用归一化后的形状：NFKC 之后全是 ASCII 字母数字（`ｉｐｚｚ－９３２`
                # 归一成 `ipzz932` 也算）。纯中文词根本不可能出现在番号里，加上去纯亏：
                # 实测 browse?q=痴女 从 163ms 降到 65ms（P50，NAS 本地）。
                nkw = _norm_kw(tok)
                numish = bool(nkw) and all(ch.isascii() and ch.isalnum() for ch in nkw)
                num_conds: list[str] = []
                num_vals: list = []
                if numish:
                    num_conds = [
                        "m.number LIKE ?",
                        "REPLACE(m.number, '-', '') LIKE ?",
                        "amane_rel(m.number, ?) IS NOT NULL",
                    ]
                    num_vals = [like, like, tok]
                conds = num_conds + [
                    "m.title LIKE ?",
                    "m.actors LIKE ?",
                    "m.series LIKE ?",
                ]
                vals: list = num_vals + [like, like, like]
                if has_cjk(tok):
                    # 标签名不会出现在 metadata 的任何一个文本列里，只能走关联表。
                    # 只对含中文的词加：番号/英文字母词走标签匹配纯属浪费（那几万行
                    # 关联表扫一遍要十几毫秒，而英文词基本不可能命中中文标签名）。
                    conds.append(
                        "m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                        "JOIN tags t ON t.id = mt.tag_id WHERE t.name LIKE ?)")
                    vals.append(like)
                for cond, cond_params in search_clauses(tok):
                    conds.append(cond)
                    vals.extend(cond_params)
                groups.append(("(" + " OR ".join(conds) + ")", tuple(vals)))
            # 词与词之间默认 AND（保持原有语义）；qmode=or 时放宽成「命中任一词即可」，
            # 由客户端在「结果太少」时自己决定要不要退这一步 —— 服务端只提供能力。
            if qmode == "or" and len(groups) > 1:
                where.append("(" + " OR ".join(g[0] for g in groups) + ")")
                params = (*params, *[v for g in groups for v in g[1]])
            else:
                for cond, cond_params in groups:
                    where.append(cond)
                    params = (*params, *cond_params)

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

        # 多版本（2.5.7.7）：1 = 只看有 2 个以上文件的，0 = 只看单文件的，留空 = 全部。
        # 口径与 versions_of() 同一句 SQL（media_files 行数），现算不缓存 ——
        # 文件管理里删掉一个版本 / 脚本新入库一个文件，下次刷新就变。
        multi = arg("multi")
        if multi == "1":
            where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) >= 2")
        elif multi == "0":
            where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) = 1")

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

        # 覆盖层命中的片（2.5.5.25）：SQL 查的是 amane 库的原始字段，
        # 用户把系列改成「11」之后，搜「11」在库里是搜不到那部片的。
        # 只在第一页补一次，按 id 去重，最多 20 部。
        if search and tokens and offset == 0:
            try:
                extra = [i for i in override_ids_matching(tokens)
                         if i not in {it["id"] for it in items}][:20]
            except Exception as exc:  # noqa: BLE001
                extra = []
                log(f"WARN 覆盖层搜索失败: {exc}")
            if extra:
                items.extend(fetch_by_ids(extra))
                total += len(extra)
        self._json({
            "items": attach_progress(items),
            "total": total,
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": direction,
            "cast_age_gender": age_gender,
            # 回显「这次按什么语义搜的」：客户端据此判断还要不要退到 or
            "qmode": "or" if (qmode == "or" and len(groups) > 1) else "and",
            # 归一化后的词（繁转简之后）。客户端拿它做「已放宽」提示的对比，
            # 也方便排查「我明明搜的是这个」。原词在请求里，不用再回。
            "q_norm": search_norm if search else "",
        })
        # 严格搜索（qmode=and）几乎没结果 → 记进「待办」。
        # 客户端放宽那次（qmode=or）结果会变多，记下来就是假账，所以只认 and。
        if search and qmode != "or":
            record_search_miss(search, search_norm, total)

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

        # 检索归一化（2.5.1）：繁体先转简体。`raw` 保留原文（回显 + 番号大小写），
        # `raw_q` 之后全部用它 —— 用户打「癡女」时，「痴女」标签也要能联想出来。
        raw_q = norm_query(raw)
        norm = re.sub(r"[\s\-_/]+", "", raw_q).upper()
        tokens = [t for t in re.split(r"[\s\-_/]+", raw_q) if t][:6]
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

        # 拼音解析出来的中文名：既用来找影片（下面是 2c 档），也用来问扩展要实体行。
        # 用户打「scg」，扩展按字面 LIKE 找不到「搜查官」，只能由核心把名字翻译好再交给它。
        py_names: list[str] = []

        if norm and "film" in kinds:
            # 1) 番号精确 / 前缀；标题开头
            grab(1, "REPLACE(UPPER(m.number), '-', '') LIKE ?", (norm + "%",), 8)
            grab(1, "UPPER(m.title) LIKE ?", (raw_q.upper() + "%",), 4)
            # 2a) 演员别名回查：metadata.actors 存的是规范名（つぼみ），别名「蕾」只在
            #     actor_aliases 里，普通条件命中不了。核心不认演员表，让扩展把别名解析成
            #     影片 id 交回来，这里只负责「这些 id 也要出现」。
            #     必须排在「标题包含」之前：蕾 是「芭蕾」的一部分，库里有 108 部片标题带它，
            #     先跑标题匹配会把她的 49 部作品全挤掉 —— 用户搜的是人，不是芭蕾。
            alias_ids = [int(i) for i in (EXT.call("suggest_films", raw_q, 4).get("ids") or [])
                         if int(i or 0) > 0]
            if alias_ids and len(picked) < limit:
                # 这批按发行时间倒序：别名命中通常就是「这个人的片」，最新的一部最可能是想找的
                grab(2, f"m.id IN ({','.join('?' * len(alias_ids))})", tuple(alias_ids), 4,
                     "m.release DESC, m.id DESC")
            # 2b) 番号 / 标题包含
            grab(2, "(REPLACE(UPPER(m.number), '-', '') LIKE ? OR UPPER(m.title) LIKE ?)",
                 (f"%{norm}%", f"%{raw_q.upper()}%"), 10)
            # 2c) 拼音命中（2.5.1）：排在上面的番号/标题之后 —— 用户打得出番号就打得出，
            #     打不出番号、只记得中文名（或只会打首字母）时才轮到这里。
            py_cond_sql: list[str] = []
            py_cond_vals: list = []
            for tok in tokens:
                for cond, cond_vals in search_clauses(tok):
                    py_cond_sql.append(cond)
                    py_cond_vals.extend(cond_vals)
                    name = str(cond_vals[0]).strip("%")
                    if name not in py_names and len(py_names) < 3:
                        py_names.append(name)
            if py_cond_sql and len(picked) < limit:
                grab(3, "(" + " OR ".join(py_cond_sql) + ")", tuple(py_cond_vals), 8,
                     "m.release DESC, m.id DESC")
            # 3) 演员 / 系列 / 制片商，或拆词任一命中（扩大范围）
            actor_likes = " OR ".join(["m.actors LIKE ?"] * len(tokens))
            grab(3, f"(m.series LIKE ? OR m.studio LIKE ? OR {actor_likes})",
                 (f"%{raw_q}%", f"%{raw_q}%", *[f"%{t}%" for t in tokens]), 10)

        items = []
        for _, (_, _, item) in sorted(picked.items(), key=lambda kv: (kv[1][0], kv[1][1])):
            item["tier"] = picked[item["id"]][0]
            item["type"] = "film"
            items.append(item)

        # 实体命中：扩展各自查自己的表/上游，返回 {kind: {"total": n, "items": [...]}}。
        entity_kinds = [k for k in kinds if k != "film"]
        totals: dict = {}
        if entity_kinds:
            # 先按用户输入的原文问一次（保持原有行为）；拼音解析出中文名时再补问一次，
            # 这样「scg」能带出「搜查官」这个标签行，而不用核心自己去碰扩展的数据。
            queries: list[str] = [raw_q]
            for name in py_names:
                if name and name != raw_q:
                    queries.append(name)
            merged: dict = {}
            for qy in queries:
                got = EXT.call("suggest_entities", qy, entity_kinds)
                for kind, bucket in (got or {}).items():
                    if not isinstance(bucket, dict):
                        continue
                    # 多轮结果并起来：total 取最大（同一个 kind 的「有多少个」只该往上报大），
                    # items 去重后按顺序拼接，不因为多问了一次就重复出现同一行。
                    cur = merged.setdefault(kind, {"total": 0, "items": []})
                    cur["total"] = max(int(cur["total"]), int(bucket.get("total") or 0))
                    have = {int(h.get("id") or 0) for h in cur["items"] if isinstance(h, dict)}
                    for hit in (bucket.get("items") or []):
                        if isinstance(hit, dict) and int(hit.get("id") or 0) not in have:
                            cur["items"].append(hit)
                            have.add(int(hit.get("id") or 0))
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
            # 检索归一化（2.5.1）：拼音解析出的中文名（没有就是空数组）。
            # 客户端可以用它做「已按拼音匹配到：搜查官」这类提示；老客户端忽略即可。
            "q_pinyin": py_names,
            # 原文与它不同就说明这次做过繁转简
            "q_norm": raw_q,
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

    # ---- 检索索引（拼音）-------------------------------------------------
    @route("GET", r"/api/user/search/reindex")
    def search_index_status(self, query, *_) -> None:
        """看一眼拼音索引建好没有：条目数 + 表在不在。"""
        t = cjk_tables()
        self._json({
            "ok": True,
            "tables": {"t2s": len(t.t2s), "pinyin": len(t.py), "alias": len(t.alias)},
            "names": name_pinyin_count(),
            "qmode": "and|or（browse 的 qmode 参数）",
        })

    @route("POST", r"/api/user/search/reindex")
    def search_reindex(self, query, *_) -> None:
        """重建拼音索引（幂等）。

        什么时候用：新入库一批片子、重新刮削改了标签名、批量改了系列名之后。
        平时不用管 —— 服务启动时发现表空会自己建一次。
        """
        try:
            out = build_name_pinyin()
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR 重建拼音索引: {exc}")
            return self._error(500, f"重建失败：{exc}")
        if not out.get("ok"):
            return self._error(400, str(out.get("reason") or "重建失败"))
        self._json(out)

    # ---- 检索别名（俗称 → 库里真有的名字）---------------------------------
    #
    # 与演员别名（amane 自带的 actor_aliases，3836 条）同一个思路：
    # 「搜查官」在库里叫「女检察官」、「ntr」在库里叫「寝取」，用户按自己的说法搜，
    # 系统负责翻译。别名**只影响检索**，不改任何一条元数据。
    @route("GET", r"/api/user/search/misses")
    def miss_list(self, query, *_) -> None:
        """「搜了没搜到」的词 —— 别名页的待办清单。

        为什么要这张表：别名靠用户维护，可用户**不知道该维护什么**。
        与其让他面对一张空表发呆，不如从真实的搜索记录里反推：
        这些词你搜过、严格条件下几乎一条都没有，八成是俗称或错字。
        每条都带上猜出来的候选（按字面重合度，语义猜不出，所以界面上要留「自己找」）。
        """
        try:
            limit = max(1, min(100, int((query.get("limit") or ["40"])[0])))
        except ValueError:
            limit = 40
        only_unhandled = ((query.get("todo") or [""])[0]).strip() == "1"
        with user_db() as conn:
            rows = conn.execute(
                "SELECT q, raw, hits, times, first_at, last_at FROM search_miss "
                "ORDER BY last_at DESC LIMIT ?", (limit,)).fetchall()
        have: dict[str, list[dict]] = {}
        for alias, pairs in cjk_tables().alias.items():
            for kind, target in pairs:
                have.setdefault(target, []).append({"alias": alias, "kind": kind})
        for alias, pairs in extra_aliases().items():
            for kind, target in pairs:
                have.setdefault(target, []).append({"alias": alias, "kind": kind})
        items: list[dict] = []
        for r in rows:
            cands = alias_candidates(str(r["raw"] or r["q"]))
            for c in cands:
                c["aliases"] = have.get(str(c["target"]), [])
            handled = any(c["aliases"] for c in cands)
            if only_unhandled and handled:
                continue
            items.append({
                "q": r["q"],
                "raw": r["raw"],
                "hits": int(r["hits"]),
                "times": int(r["times"]),
                "last_at": r["last_at"],
                "candidates": cands,
                # 候选里已经有别名的，说明这条基本处理过了，界面上可以沉下去
                "handled": handled,
            })
        self._json({"items": items, "total": len(items)})

    @route("DELETE", r"/api/user/search/misses")
    def miss_del(self, query, *_) -> None:
        """`?q=` 删一条（不想管 / 已经加过别名）；不带就清空。"""
        q = ((query.get("q") or [""])[0]).strip().lower()
        with user_db() as conn:
            if q:
                conn.execute("DELETE FROM search_miss WHERE q = ?", (q,))
            else:
                conn.execute("DELETE FROM search_miss")
            left = conn.execute("SELECT COUNT(*) FROM search_miss").fetchone()[0]
        self._json({"ok": True, "total": left})

    @route("GET", r"/api/user/search/aliases")
    def alias_list(self, query, *_) -> None:
        """列出全部别名。`films` 是目标名在库里挂了多少部片 —— 一眼看出这条有没有用。

        `?target=名字` 只回指向这个名字的别名：详情页要显示「又名：搜查官」时用，
        客户端也可以一次拉全量自己映射（别名一共就几十条）。
        """
        merged: list[dict] = []
        seen: set[tuple] = set()
        builtin = cjk_tables().alias
        for alias, pairs in builtin.items():
            for kind, target in pairs:
                if (alias, kind, target) in seen:
                    continue
                seen.add((alias, kind, target))
                merged.append({"alias": alias, "kind": kind, "target": target,
                               "source": "builtin"})
        for alias, pairs in extra_aliases().items():
            for kind, target in pairs:
                if (alias, kind, target) in seen:
                    continue
                seen.add((alias, kind, target))
                merged.append({"alias": alias, "kind": kind, "target": target,
                               "source": "user"})
        counts = _alias_film_counts(merged)
        for item in merged:
            item["films"] = counts.get((item["kind"], item["target"]), 0)
        want_target = ((query.get("target") or [""])[0]).strip()
        if want_target:
            merged = [x for x in merged if str(x["target"]) == want_target]
        merged.sort(key=lambda x: (-int(x["films"]), x["alias"]))
        # 折叠别名（写法差异）不进这个列表：它有一千多条，全倒出来只会淹没人加的。
        # 但页面上要让人知道「有一部分已经自动处理了」，所以回个数字。
        try:
            with user_db() as conn:
                variants = int(conn.execute(
                    "SELECT COUNT(*) FROM name_variant").fetchone()[0])
        except sqlite3.Error:
            variants = 0
        self._json({"items": merged, "total": len(merged), "variants": variants})

    @route("GET", r"/api/user/search/expand")
    def expand(self, query, *_) -> None:
        """`?q=词` → 这个词现在命中了哪些名字 + 哪些看起来是同一个东西却没算进来。

        别名要解决的不止「搜不到」，还有「只搜到一半」：
        搜「搜查官」出 188 部，可库里还有个标签叫「女捜查官」（67 部，捜 是日文写法），
        一个字之差就不在这次结果里。这类缺口是**字面**能看见的，所以能提示；
        而语义上的等号（搜查官 = 女检察官）看不见，那部分只能靠人。
        """
        raw = ((query.get("q") or [""])[0]).strip()
        if not raw:
            return self._json({"q": "", "matched": [], "missing": [], "total": 0})
        hit = names_hit_by(raw)
        counts = _alias_film_counts(
            [{"kind": k, "target": n} for k, n in hit])
        matched = [{"kind": k, "target": n, "films": counts.get((k, n), 0)}
                   for k, n in hit]
        missing = missing_names(raw)
        self._json({
            "q": raw,
            "q_norm": norm_query(raw),
            "matched": matched,
            "missing": missing,
            "total": len(missing),
        })

    @route("POST", r"/api/user/search/aliases")
    def alias_add(self, query, *_) -> None:
        """body：`{alias, target, kind?}` 或 `{alias, targets:[{kind,target}, …]}`。

        `target` 必须是库里真实存在的名字（否则别名指不到任何片，加了等于没加），
        这里会先核一遍，核不到就 404，并把「最像的几个」带回去方便纠错。

        `targets`（2.5.1.15 起）：**一个俗称挂多个名字**。别名要解决的不止「搜不到」，
        还有「一个说法对应好几个标签」（ntr → 寝取 + 寝取り・寝取られ・NTR），
        批量提交比让客户端循环 POST 更省事，也不会出现「一半成功一半失败」。
        """
        body = self._body() or {}
        alias = str(body.get("alias") or "").strip()
        kind_default = str(body.get("kind") or "tag").strip().lower()
        if not alias:
            return self._error(422, "alias 必填")
        if len(alias) > 40:
            return self._error(422, "俗称太长了（上限 40 字）")

        specs: list[tuple[str, str]] = []
        raw_targets = body.get("targets")
        if isinstance(raw_targets, list) and raw_targets:
            for item in raw_targets:
                if isinstance(item, dict):
                    kind = str(item.get("kind") or kind_default).strip().lower()
                    target = str(item.get("target") or "").strip()
                else:
                    kind = kind_default
                    target = str(item or "").strip()
                if target:
                    specs.append((kind, target))
        else:
            target = str(body.get("target") or "").strip()
            if target:
                specs.append((kind_default, target))
        if not specs:
            return self._error(422, "target 或 targets 必填")

        bad: list[dict] = []
        for kind, target in specs:
            if kind not in _PY_COND:
                return self._error(422, "kind 只能是 tag / series / actor")
            if len(target) > 80:
                return self._error(422, "名字太长了（上限 80 字）")
            exists, hint = _alias_target_exists(kind, target)
            if not exists:
                bad.append({"kind": kind, "target": target, "hint": hint})
        if bad:
            # 一个都不写：部分成功最难排查（用户以为全加上了）
            first = bad[0]
            msg = f"库里没有名为「{first['target']}」的{_ALIAS_KIND_CN.get(first['kind'], first['kind'])}"
            if first["hint"]:
                msg += f"，你是不是想找：{' / '.join(first['hint'])}"
            if len(bad) > 1:
                msg += f"（还有 {len(bad) - 1} 个名字也没找到）"
            return self._error(404, msg)

        with user_db() as conn:
            conn.executemany(
                "INSERT OR REPLACE INTO search_alias(alias, kind, target, created_at) "
                "VALUES(?,?,?,?)",
                [(alias, kind, target, now_iso()) for kind, target in specs])
        reset_alias_cache()
        self._json({
            "ok": True, "alias": alias,
            "targets": [{"kind": k, "target": t} for k, t in specs],
            "count": len(specs),
        })

    @route("DELETE", r"/api/user/search/aliases")
    def alias_del(self, query, *_) -> None:
        """`?alias=xxx` 删这个俗称的全部别名；再给 `target` 就只删那一条。

        出厂默认（alias.tsv）删不掉 —— 它是随代码走的文件，不是数据。
        """
        alias = ((query.get("alias") or [""])[0]).strip()
        target = ((query.get("target") or [""])[0]).strip()
        if not alias:
            return self._error(422, "alias 必填")
        with user_db() as conn:
            if target:
                cur = conn.execute(
                    "DELETE FROM search_alias WHERE alias = ? AND target = ?", (alias, target))
            else:
                cur = conn.execute("DELETE FROM search_alias WHERE alias = ?", (alias,))
            removed = cur.rowcount
        reset_alias_cache()
        builtin = (alias.lower() in cjk_tables().alias)
        self._json({"ok": True, "removed": removed, "builtin_still_active": builtin})

    @route("GET", r"/api/user/upstream")
    def upstream_info(self, query, *_) -> None:
        """旁挂看到的「上游是谁、什么版本、缺什么能力」。

        平台差异（Windows 桌面 18000 / macOS 数据目录 / Docker /data）由启动时探测解决，
        但探测结果必须能当场看见 —— 否则又回到「表象在客户端、原因在端口」的老路。
        `refresh=1` 强制重查，其余 60 秒缓存。
        """
        caps = upstream_caps(refresh=(query.get("refresh") or [""])[0] in ("1", "true"))
        self._json(caps)

    @route("GET", r"/api/user/item/(\d+)")
    def item(self, query, metadata_id, *_) -> None:
        with amane_db() as conn:
            rows = conn.execute(f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (int(metadata_id),)).fetchall()
            if not rows:
                return self._error(404, "条目不存在")
            data = item_of(rows[0])
            # 详情页是覆盖层最主要的面（改完立刻要看到），单条查一次不算开销
            apply_overrides([data])
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
            # 顺带采一个样（2.5.3）：老客户端只发 history、不发专用采样接口。有了这一行，
            # 它们也能贡献「部数 / 时长 / 时段」，只是粒度粗（src=legacy，页面标「只能估算」）。
            # 新客户端同时发两个接口时会被「同一分钟只留最早一条」去掉重复，不会翻倍。
            try:
                ldate, lhour = _local_parts(body)
                add_sample(conn, mid, position, duration, ldate, lhour, "legacy")
            except (TypeError, ValueError) as exc:
                log(f"WARN 采样写入失败: {exc}")
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

    # -- 报表（2.5.3）-------------------------------------------------------
    #
    # 五个读端点一次定好，页面只渲染、不在页面里算（docs/TASKS/2.5.3-report-next.md §2）。
    # 统一信封 {"ok", "version", "confidence", "data"}：confidence = full / sparse / estimate，
    # `ok:false` 一律带 reason —— 样本不足时客户端显示「还在积累」，不许显示成 0 误导人。
    # 加新统计项 = 加一个端点 + 页面加一块，不动已有项。

    @route("POST", r"/api/user/stats/sample")
    def stats_sample(self, query, *_) -> None:
        """上报一个播放位置采样（只追加）。老客户端不发这个，由 history 顺带采。"""
        body = self._body()
        try:
            mid = int(body.get("metadata_id"))
        except (TypeError, ValueError):
            return self._error(422, "metadata_id 必填")
        try:
            position = max(0.0, float(body.get("position") or 0))
            duration = max(0.0, float(body.get("duration") or 0))
        except (TypeError, ValueError):
            return self._error(422, "position / duration 必须是数字")
        src = str(body.get("src") or "app")[:16]
        local_date, local_hour = _local_parts(body)
        with user_db() as conn:
            sid = add_sample(conn, mid, position, duration, local_date, local_hour, src)
            total = conn.execute("SELECT COUNT(*) FROM play_progress").fetchone()[0]
        self._json({"ok": True, "id": sid, "samples": total, "local_date": local_date,
                    "local_hour": local_hour})

    @route("GET", r"/api/user/stats/overview")
    def stats_overview(self, query, *_) -> None:
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        where = " WHERE 1=1" + dw + sw
        args = dargs + sargs
        with user_db() as conn:
            films = conn.execute(
                f"SELECT COUNT(DISTINCT metadata_id) FROM stats_daily{where}", args).fetchone()[0]
            total = conn.execute(
                f"SELECT COALESCE(SUM(secs), 0) FROM stats_daily{where}", args).fetchone()[0]
            samples = conn.execute(
                f"SELECT COALESCE(SUM(samples), 0) FROM stats_daily{where}", args).fetchone()[0]
            finished = conn.execute(
                f"SELECT COUNT(DISTINCT metadata_id) FROM stats_daily{where} AND finished = 1",
                args).fetchone()[0]
            days = [r[0] for r in conn.execute(
                f"SELECT date FROM stats_daily{where} GROUP BY date HAVING SUM(secs) > 0 "
                "ORDER BY date", args).fetchall()]
            span = conn.execute(
                f"SELECT MIN(date), MAX(date) FROM stats_daily{where}", args).fetchone()
            # 可用范围不受筛选影响：页面上「你的数据从哪到哪」要用它，否则一筛就自相矛盾
            avail = conn.execute(
                f"SELECT MIN(date), MAX(date) FROM stats_daily WHERE 1=1{sw}", sargs).fetchone()

        # 连续天数：按「有观看秒数的自然日」连成串。当前连续只在最后一天是今天/昨天时才算，
        # 否则「连续 3 天」会一直是三个月前的数字，看着像 bug。
        longest = 0
        run = 0
        last_day = None
        for raw in days:
            try:
                cur = date.fromisoformat(raw)
            except ValueError:
                continue
            run = run + 1 if (last_day and (cur - last_day).days == 1) else 1
            longest = max(longest, run)
            last_day = cur
        streak = 0
        if last_day and (date.today() - last_day).days <= 1:
            streak = run

        quality = stats_quality()
        data = {
            "films": films,
            "seconds": round(float(total)),
            "hours": round(float(total) / 3600, 1),
            "days": len(days),
            "streak": streak,
            "longest_streak": longest,
            "finished": finished,
            "from": span[0] if span else None,
            "to": span[1] if span else None,
            "available_from": avail[0] if avail else None,
            "available_to": avail[1] if avail else None,
            "samples": int(samples),
            # 两个口径各有多少条采样（测试版切口径时要用它显示「测试数据 24 条」）
            "scope_samples": {"real": int(quality.get("real", 0)),
                              "test": int(quality.get("test", 0))},
            "suspicious": -1,
            "dropped": -1,
        }
        # 质量指标只有「不加筛选」时才说得清（拖动/丢弃是全局计数，不按日存）
        if not start and not end and scope == "real":
            data["samples"] = int(quality.get("samples", 0))
            data["suspicious"] = int(quality.get("jump", 0)) + int(quality.get("rewind", 0))
            data["dropped"] = int(quality.get("dropped", 0)) + int(quality.get("unknown", 0))

        self._json(stats_env(films > 0, stats_confidence(films, len(days)), data,
                             "这个范围内还没有观看记录", range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/trend")
    def stats_trend(self, query, *_) -> None:
        ensure_stats()
        try:
            weeks = int((query.get("weeks") or ["12"])[0])
        except ValueError:
            weeks = 12
        weeks = max(4, min(weeks, 53))
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT date, metadata_id, secs, finished FROM stats_daily WHERE 1=1{dw}{sw}",
                dargs + sargs).fetchall()

        by_week: dict = {}
        for r in rows:
            try:
                day = date.fromisoformat(r["date"])
            except ValueError:
                continue
            week = day - timedelta(days=day.weekday())     # 周一为一周之始
            slot = by_week.setdefault(week, {"secs": 0.0, "started": set(), "finished": set()})
            slot["secs"] += float(r["secs"] or 0)
            slot["started"].add(r["metadata_id"])
            if r["finished"]:
                slot["finished"].add(r["metadata_id"])

        today = date.today()
        cur = today - timedelta(days=today.weekday())

        def week_of(raw: str):
            try:
                d = date.fromisoformat(raw)
            except ValueError:
                return None
            return d - timedelta(days=d.weekday())

        # 窗口：给了范围就按范围，没给就看最近 N 周（有更早数据时前扩，最多一年）
        last = week_of(end) if end else cur
        first = week_of(start) if start else None
        if last is None:
            last = cur
        if first is None:
            first = last - timedelta(weeks=weeks - 1)
            if by_week:
                first = min(first, min(by_week))
        if (last - first).days > 364:
            first = last - timedelta(weeks=52)
        if last < first:
            first, last = last, first

        items = []
        films_all: set = set()
        week = first
        while week <= last:
            slot = by_week.get(week)
            started = len(slot["started"]) if slot else 0
            done = len(slot["finished"]) if slot else 0
            secs = round(slot["secs"]) if slot else 0
            items.append({
                "week": f"{week.isocalendar()[0]}-W{week.isocalendar()[1]:02d}",
                "from": week.isoformat(),
                "to": (week + timedelta(days=6)).isoformat(),
                "films": started,
                "finished": done,
                "rate": round(done / started, 3) if started else 0.0,
                "seconds": secs,
                "hours": round(secs / 3600, 1),
            })
            if slot:
                films_all |= slot["started"]
            week += timedelta(days=7)

        data = {"weeks": items, "weeks_count": len(items), "films": len(films_all)}
        self._json(stats_env(len(films_all) > 0, stats_confidence(len(films_all), len(by_week)),
                             data, "这个范围内还没有足够的记录画趋势",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/when")
    def stats_when(self, query, *_) -> None:
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("local_date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT local_date, local_hour, secs, samples FROM stats_hour WHERE 1=1{dw}{sw}",
                dargs + sargs).fetchall()
        hours = [0.0] * 24
        hour_samples = [0] * 24
        weekdays = [0.0] * 7
        day_samples = [0] * 7
        unknown = 0
        for r in rows:
            hour = int(r["local_hour"])
            if 0 <= hour < 24:
                hours[hour] += float(r["secs"] or 0)
                hour_samples[hour] += int(r["samples"] or 0)
            else:
                unknown += int(r["samples"] or 0)   # 客户端没报本地时间，只能估算
            try:
                wd = date.fromisoformat(r["local_date"]).weekday()
            except ValueError:
                continue
            weekdays[wd] += float(r["secs"] or 0)
            day_samples[wd] += int(r["samples"] or 0)

        def top_index(values: list) -> int:
            best = -1
            for i, v in enumerate(values):
                if v > 0 and (best < 0 or v > values[best]):
                    best = i
            return best

        total = sum(hours)
        data = {
            "hours": [round(v) for v in hours],
            "hours_samples": hour_samples,
            "weekdays": [round(v) for v in weekdays],
            "weekday_samples": day_samples,
            "peak_hour": top_index(hours),
            "peak_weekday": top_index(weekdays),
            "unknown_samples": unknown,
        }
        # 时段分布的样本量口径和「部数」不同：这里看「有秒数的格子数 + 总时长」，
        # 少于 1 小时的样本画出来的柱子全是噪声。
        cells = sum(1 for v in hours if v > 0)
        conf = "full" if (total >= 3600 and cells >= 6) else ("sparse" if total > 0 else "estimate")
        self._json(stats_env(total >= 60, conf, data, "这个范围内还没有足够的记录看时段",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/heat")
    def stats_heat(self, query, *_) -> None:
        """0–100% 热度条。`mid` 缺省 = 全库平均（metadata_id=0 那份合计）。"""
        ensure_stats()
        raw = (query.get("mid") or [""])[0]
        mid = int(raw) if raw.isdigit() else 0
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("local_date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT bucket, SUM(secs) AS secs FROM stats_heat "
                f"WHERE metadata_id = ?{dw}{sw} GROUP BY bucket",
                [mid] + dargs + sargs).fetchall()
        secs = [0.0] * STATS_HEAT_BUCKETS
        for r in rows:
            bucket = int(r["bucket"])
            if 0 <= bucket < STATS_HEAT_BUCKETS:
                secs[bucket] = float(r["secs"] or 0)
        peak = max(secs) if secs else 0.0
        total = sum(secs)
        buckets = [round(v / peak, 3) if peak > 0 else 0.0 for v in secs]
        data = {
            "mid": mid or None,
            "buckets": buckets,               # 0..1，客户端直接乘以条宽
            "secs": [round(v) for v in secs],
            "total_secs": round(total),
            "peak_bucket": (secs.index(peak) if peak > 0 else -1),
            "bucket_pct": 100 / STATS_HEAT_BUCKETS,
        }
        # 少于 1 分钟样本的热度条没有意义，宁可显示「还在积累」
        self._json(stats_env(total >= 60, "full" if total >= 900 else "sparse", data,
                             "这个范围内这部片的观看位置还在积累",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/top")
    def stats_top(self, query, *_) -> None:
        ensure_stats()
        kind = (query.get("kind") or ["actor"])[0]
        if kind not in ("actor", "tag", "studio"):
            return self._error(422, "kind 只能是 actor / tag / studio")
        try:
            limit = int((query.get("limit") or ["10"])[0])
        except ValueError:
            limit = 10
        limit = max(1, min(limit, 50))
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, SUM(secs) AS secs FROM stats_daily WHERE 1=1{dw}{sw} "
                "GROUP BY metadata_id", dargs + sargs).fetchall()
        film_secs = {r["metadata_id"]: float(r["secs"] or 0) for r in rows}
        # 标签榜与标签列表同一口径：隐藏过的不出现在榜里
        hidden = hidden_facet_ids("tag") if kind == "tag" else set()
        items = stats_top_items(kind, film_secs, limit, hidden)
        data = {"kind": kind, "items": items, "films": len(film_secs),
                "hidden_tags": len(hidden) if kind == "tag" else 0}
        self._json(stats_env(bool(items), stats_confidence(len(film_secs), len(film_secs)),
                             data, "这个范围内还没有足够记录排榜",
                             range_=(start, end), scope=scope))

    @route("POST", r"/api/user/stats/rebuild")
    def stats_rebuild(self, query, *_) -> None:
        """整批重算（幂等）。改口径后由客户端或运维手动触发，平时读端点会自己判断。"""
        quality = rebuild_stats()
        self._json({"ok": True, "version": STATS_VERSION, "data": quality})

    @route("POST", r"/api/user/stats/purge")
    def stats_purge(self, query, *_) -> None:
        """清除某个时段的采样（可只清测试数据）。清完立刻重算，页面刷新就少一块。

        **真数据必须同时给 from 与 to** —— 只允许「清掉某段」，不允许一键抹平全部，
        否则一次误触就把几年的记录清零，而且采样是只追加的、删了就回不来。
        """
        body = self._body()
        start = str(body.get("from") or "")[:10]
        end = str(body.get("to") or "")[:10]
        scope = str(body.get("scope") or "test").lower()
        if scope not in ("test", "real", "all"):
            scope = "test"
        ok_date = lambda v: bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", v or ""))  # noqa: E731
        if start and not ok_date(start):
            start = ""
        if end and not ok_date(end):
            end = ""
        if scope in ("real", "all") and not (ok_date(start) and ok_date(end)):
            return self._error(422, "清除真实数据必须同时给 from 与 to（只允许清一段，防误删）")

        sql = "DELETE FROM play_progress WHERE 1=1"
        args: list = []
        if start:
            sql += " AND local_date >= ?"
            args.append(start)
        if end:
            sql += " AND local_date <= ?"
            args.append(end)
        if scope == "test":
            sql += " AND lower(src) = 'test'"
        elif scope == "real":
            sql += " AND lower(src) != 'test'"
        with user_db() as conn:
            removed = conn.execute(sql, args).rowcount
        quality = rebuild_stats()
        log(f"统计清除 scope={scope} {start or '-'}~{end or '-'} rows={removed}")
        self._json({"ok": True, "removed": removed, "version": STATS_VERSION,
                    "data": quality})

    @route("POST", r"/api/user/stats/testdata")
    def stats_testdata(self, query, *_) -> None:
        """生成一批模拟采样（`src=test`），只喂「测试数据」口径。

        为什么要有：验收要看图、看榜、看热度条，真数据不够就什么都验不出来；而模拟
        数据一旦混进真实口径，数字就永远说不清。所以两边**物理分开**：这里只写
        `src=test`，清也只清这一类，真实口径一条都不碰。
        """
        body = self._body()
        try:
            films = max(1, min(int(body.get("films") or 6), 20))
            days = max(1, min(int(body.get("days") or 28), 180))
        except (TypeError, ValueError):
            films, days = 6, 28

        with user_db() as conn:
            dropped = conn.execute(
                "DELETE FROM play_progress WHERE lower(src) = 'test'").rowcount
        with amane_db() as conn:
            rows = conn.execute(
                "SELECT id, COALESCE(NULLIF(runtime, 0), 120) AS runtime FROM metadata "
                "ORDER BY RANDOM() LIMIT ?", (films,)).fetchall()
        if not rows:
            return self._error(409, "库里没有影片，先生成不了测试数据")

        today = date.today()
        inserted = 0
        with user_db() as conn:
            for idx, row in enumerate(rows):
                mid = int(row["id"])
                dur = float(row["runtime"]) * 60.0        # runtime 的单位是分钟
                # 每部片落在不同的日子与时段，这样趋势/时段/热度三张图才有形状；
                # 三分之一「看完」（99%），其余看到一半 —— 完成率折线才有起伏。
                offset = (idx * days) // max(len(rows), 1)
                day = today - timedelta(days=offset)
                hour = 20 + (idx % 4)
                target = 0.99 if idx % 3 == 0 else 0.5
                step = max(30.0, dur * target / 6.0)
                pos = 0.0
                for _ in range(6):
                    pos = min(dur, pos + step)
                    add_sample(conn, mid, pos, dur, day.strftime("%Y-%m-%d"),
                               min(hour, 23), "test")
                    inserted += 1
        quality = rebuild_stats()
        log(f"测试数据 scope=test films={len(rows)} samples={inserted} 清旧={dropped}")
        self._json({"ok": True, "films": len(rows), "samples": inserted,
                    "removed": dropped, "version": STATS_VERSION, "data": quality})

    @route("GET", r"/api/user/stats/tag-hygiene")
    def stats_tag_hygiene(self, query, *_) -> None:
        """「这些标签该不该隐藏」的候选清单（只给字面与覆盖率判据，不猜语义）。"""
        try:
            limit = int((query.get("limit") or ["12"])[0])
        except ValueError:
            limit = 12
        limit = max(1, min(limit, 50))
        items = tag_hygiene_candidates(limit)
        data = {"items": items, "hidden": len(hidden_facet_ids("tag"))}
        self._json({"ok": True, "version": STATS_VERSION, "data": data})

    # -- 报表 v2（2.5.3 第二批）---------------------------------------------
    #
    # 四块新统计，各自独立端点、独立空态，**不改已有块**。判据全在服务端，页面只渲染。

    @route("GET", r"/api/user/stats/dropoff")
    def stats_dropoff(self, query, *_) -> None:
        """弃片榜：按演员/标签算「打开却没看完」的比例。

        口径：打开 = 累计观看 ≥60s；弃片 = 末次采样在 7 天前且最好完成率 <95%；
        样本 <5 的实体不进榜（否则「1 投 1 弃」这种人会排第一，榜单就没有说服力）。
        """
        ensure_stats()
        kind = (query.get("kind") or ["actor"])[0]
        if kind not in ("actor", "tag"):
            return self._error(422, "kind 只能是 actor / tag")
        try:
            limit = int((query.get("limit") or ["10"])[0])
        except ValueError:
            limit = 10
        limit = max(1, min(limit, 50))
        start, end = stats_range(query)
        scope = stats_scope(query)
        # 测试口径放宽门槛：模拟数据本来就只有几部，卡 5 会让整块永远空，
        # 验收时看不出「逻辑对不对」。真实口径仍按策划的 5。
        min_sample = 2 if scope == "test" else STATS_MIN_SAMPLE
        cutoff = (date.today() - timedelta(days=STATS_DROP_DAYS)).isoformat()
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)

        opened = {mid: f for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS}
        dropped = {mid for mid, f in opened.items()
                   if f["last"] <= cutoff and f["ratio"] < FINISH_RATIO}
        ent = stats_entity_of(kind, opened.keys())
        agg: dict = {}
        for mid in opened:
            for name, nid in ent.get(mid, []):
                slot = agg.setdefault((name, nid), {"name": name, "id": nid,
                                                    "opened": 0, "dropped": 0})
                slot["opened"] += 1
                if mid in dropped:
                    slot["dropped"] += 1
        items = []
        for v in agg.values():
            if v["opened"] < min_sample:
                continue
            items.append({"name": v["name"], "id": v["id"], "opened": v["opened"],
                          "dropped": v["dropped"],
                          "rate": round(v["dropped"] / v["opened"], 3)})
        items.sort(key=lambda v: (-v["rate"], -v["opened"], v["name"]))
        conf = "full" if len(opened) >= 10 else ("sparse" if opened else "estimate")
        data = {"kind": kind, "items": items[:limit], "opened": len(opened),
                "dropped": len(dropped), "cutoff": cutoff,
                "min_sample": min_sample}
        self._json(stats_env(bool(items), conf, data,
                             "样本还不够，先多看几部（同类至少要 5 部）",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/dropcurve")
    def stats_dropcurve(self, query, *_) -> None:
        """开头流失曲线：每部片看到最远的位置落进 10 个桶，再看「有多少部能撑到第 N 桶」。

        `reached[i]` 是**累计**比例（看到 ≥10%×(i+1) 的片子占比），所以最后一项接近完成率，
        而不是在 0 处最高 —— 后者是直方图，读者会读错方向。
        """
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)
        opened = [f for f in films.values() if f["secs"] >= STATS_OPEN_SECS]
        buckets = [0] * 10
        for f in opened:
            buckets[min(9, max(0, int(f["ratio"] * 10)))] += 1
        total = len(opened)
        reached = []
        for i in range(10):
            reached.append(round(sum(buckets[i:]) / total, 3) if total else 0.0)

        avg_secs = 0.0
        mids = [mid for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS]
        if mids:
            total_min, counted = 0.0, 0
            with amane_db() as conn:
                for i in range(0, len(mids), 400):
                    chunk = mids[i:i + 400]
                    marks = ",".join("?" * len(chunk))
                    row = conn.execute(
                        f"SELECT SUM(runtime), COUNT(*) FROM metadata "
                        f"WHERE id IN ({marks}) AND runtime > 0", chunk).fetchone()
                    if row and row[0]:
                        total_min += float(row[0])
                        counted += int(row[1] or 0)
            if counted:
                avg_secs = total_min / counted * 60.0

        data = {"buckets": buckets, "reached": reached, "films": total,
                "avg_runtime_secs": round(avg_secs)}
        conf = "full" if total >= 10 else ("sparse" if total else "estimate")
        self._json(stats_env(total > 0, conf, data, "还没有打开的片子",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/idle")
    def stats_idle(self, query, *_) -> None:
        """吃灰清单 + 冷落演员 / 冷落厂牌。"""
        ensure_stats()
        try:
            days = int((query.get("days") or ["30"])[0])
        except ValueError:
            days = 30
        days = max(1, min(days, 3650))
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
        with user_db() as conn:
            fav = conn.execute(
                "SELECT metadata_id, created_at FROM favorites").fetchall()
            films = stats_films(conn, "", "", "real")
        fav_ids = [int(r["metadata_id"]) for r in fav]
        fav_at = {int(r["metadata_id"]): str(r["created_at"]) for r in fav}
        idle = [mid for mid in fav_ids
                if fav_at[mid] <= cutoff and mid not in films]

        # 冷落演员 / 厂牌：收藏了他的片，却一部都没打开
        fav_ent = stats_entity_of("actor", fav_ids)
        opened_actor = {nid for pairs in stats_entity_of("actor", list(films)).values()
                        for _n, nid in pairs}
        cold_actor: dict = {}
        for mid in fav_ids:
            for name, nid in fav_ent.get(mid, []):
                if nid in opened_actor:
                    continue
                slot = cold_actor.setdefault(nid, {"id": nid, "name": name, "films": 0})
                slot["films"] += 1
        cold_studio: dict = {}
        if fav_ids:
            with amane_db() as conn:
                for i in range(0, len(fav_ids), 400):
                    chunk = fav_ids[i:i + 400]
                    marks = ",".join("?" * len(chunk))
                    for row in conn.execute(
                            f"SELECT id, studio FROM metadata WHERE id IN ({marks}) "
                            "AND studio IS NOT NULL AND studio != ''", chunk):
                        mid = int(row["id"])
                        if mid in films:
                            continue
                        name = str(row["studio"])
                        slot = cold_studio.setdefault(name, {"name": name, "films": 0})
                        slot["films"] += 1

        metas = titles_of(idle[:50])
        items = []
        for mid in idle[:50]:
            m = metas.get(mid)
            if not m:
                continue
            items.append({"id": mid, "number": m["number"], "title": m["title"],
                          "fav_at": fav_at.get(mid, "")})

        data = {
            "items": items,
            "total": len(idle),
            "days": days,
            "cold_actors": sorted(cold_actor.values(),
                                  key=lambda v: (-v["films"], v["name"]))[:10],
            "cold_studios": sorted(cold_studio.values(),
                                   key=lambda v: (-v["films"], v["name"]))[:10],
        }
        self._json(stats_env(bool(fav_ids), "full" if fav_ids else "estimate", data,
                             "还没有收藏，先收几部"))

    @route("GET", r"/api/user/stats/funnel")
    def stats_funnel(self, query, *_) -> None:
        """收藏转化漏斗：收藏 → 打开 → 看完（只看窗口内新增的收藏）。"""
        ensure_stats()
        try:
            days = int((query.get("days") or ["90"])[0])
        except ValueError:
            days = 90
        days = max(1, min(days, 3650))
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
        with user_db() as conn:
            fav = conn.execute(
                "SELECT metadata_id FROM favorites WHERE created_at >= ?", (cutoff,)).fetchall()
            films = stats_films(conn, "", "", "real")
        mids = [int(r["metadata_id"]) for r in fav]
        opened = [m for m in mids
                  if m in films and films[m]["secs"] >= STATS_OPEN_SECS]
        finished = [m for m in opened if films[m]["ratio"] >= FINISH_RATIO]
        total = len(mids)
        data = {
            "favorited": total,
            "opened": len(opened),
            "finished": len(finished),
            "open_rate": round(len(opened) / total, 3) if total else 0.0,
            "finish_rate": round(len(finished) / len(opened), 3) if opened else 0.0,
            "overall": round(len(finished) / total, 3) if total else 0.0,
            "days": days,
            "cutoff": cutoff,
        }
        conf = "full" if total >= 10 else ("sparse" if total else "estimate")
        self._json(stats_env(total > 0, conf, data, "这段时间没有新增收藏"))

    @route("GET", r"/api/user/stats/conflict")
    def stats_conflict(self, query, *_) -> None:
        """评分冲突三件事：高分低完成 / 没打分却反复看 / 与上游评分的差异。"""
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)
            ratios = stats_day_ratios(conn, scope)
            try:
                rows = conn.execute("SELECT metadata_id, score FROM user_ratings").fetchall()
            except sqlite3.Error:
                rows = []          # ratings 扩展没开：当作一条都没打分
        mine = {int(r["metadata_id"]): int(r["score"]) for r in rows}
        opened = {mid: f for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS}

        high_low = []
        for mid, f in opened.items():
            score = mine.get(mid, 0)
            if score >= 4 and f["ratio"] < 0.3:
                high_low.append({"id": mid, "score": score,
                                 "ratio": round(f["ratio"], 3),
                                 "secs": round(f["secs"])})
        high_low.sort(key=lambda v: (v["ratio"], -v["score"]))

        repeats = []
        for mid in opened:
            if mine.get(mid, 0) > 0:
                continue
            n = stats_replays(ratios.get(mid, []))
            if n >= 2:
                repeats.append({"id": mid, "replays": n, "secs": round(opened[mid]["secs"])})
        repeats.sort(key=lambda v: (-v["replays"], -v["secs"]))

        # 与上游评分的差异：上游是 10 分制，我的 5 星 ×2 再比
        head = [mid for mid in mine if mid in films][:200]
        metas = titles_of(head)
        diffs = []
        for mid in head:
            up = metas.get(mid, {}).get("vote", 0.0)
            if up <= 0:
                continue
            diffs.append(mine[mid] * 2.0 - up)
        vs = {"count": len(diffs), "mean_diff": 0.0, "harsh": 0.0, "gap": 0.0}
        if diffs:
            vs["mean_diff"] = round(sum(diffs) / len(diffs), 2)
            vs["harsh"] = round(sum(1 for d in diffs if d < 0) / len(diffs), 3)
            vs["gap"] = round(sum(1 for d in diffs if abs(d) > 1.5) / len(diffs), 3)

        # 补标题：`metas` 之前只为「打过分的片」取过，冲突榜里没打分的那些会拿到空标题
        wanted = [it["id"] for it in high_low[:8]] + [it["id"] for it in repeats[:8]]
        missing = [i for i in wanted if i not in metas]
        if missing:
            metas.update(titles_of(missing))

        for bucket in (high_low, repeats):
            for it in bucket:
                m = metas.get(it["id"], {})
                it["number"] = m.get("number", "")
                it["title"] = m.get("title", "")

        data = {"high_low": high_low[:8], "repeats": repeats[:8], "vs_upstream": vs,
                "opened": len(opened)}
        conf = "full" if len(opened) >= 10 else ("sparse" if opened else "estimate")
        self._json(stats_env(bool(opened), conf, data, "还没有足够的观看记录",
                             range_=(start, end), scope=scope))

    # -- Tier 图（2.5.4）---------------------------------------------------
    #
    # 五档固定、分档与上限全在服务端；生成即落快照（筛选条件 + 条目 + 展示图），
    # 之后再改评分也不动旧图，要更新就重新生成。契约见 `docs/TASKS/2.5.4-tierlist.md` §4。

    @route("POST", r"/api/user/tier/generate")
    def tier_generate(self, query, *_) -> None:
        filters = tier_filters(self._body())
        data = tier_store(filters, tier_build(filters))
        self._json({"ok": True, "version": TIER_VERSION, "data": data})

    @route("GET", r"/api/user/tier/current")
    def tier_current(self, query, *_) -> None:
        """统计页那一块：当前选定的那张；没有选定就取最新一张；一张都没有就按默认条件现生成。"""
        row = None
        with user_db() as conn:
            row = conn.execute(
                "SELECT * FROM tier_snapshot WHERE picked = 1 "
                "ORDER BY created_at DESC, id DESC LIMIT 1").fetchone()
            if row is None:
                row = conn.execute(
                    "SELECT * FROM tier_snapshot ORDER BY created_at DESC, id DESC LIMIT 1"
                ).fetchone()
        if row is not None:
            self._json({"ok": True, "version": TIER_VERSION, "data": tier_row_to_data(row)})
            return

        # 第一次打开：默认「最近一个月打过分的影片」；一条都没有就用全部影片再试一次
        filters = tier_filters({"kinds": ["film"], "rated_days": 30})
        data = tier_build(filters)
        if data["total"] == 0:
            filters = tier_filters({"kinds": ["film"]})
            data = tier_build(filters)
        stored = tier_store(filters, data)
        if data["total"] == 0:
            self._json({"ok": False, "version": TIER_VERSION, "data": stored,
                        "reason": "还没给片子打过星，先打几部再来"})
            return
        self._json({"ok": True, "version": TIER_VERSION, "data": stored})

    @route("GET", r"/api/user/tier/snapshots")
    def tier_snapshots(self, query, *_) -> None:
        try:
            limit = int((query.get("limit") or ["20"])[0])
        except ValueError:
            limit = 20
        try:
            offset = int((query.get("offset") or ["0"])[0])
        except ValueError:
            offset = 0
        limit = max(1, min(limit, 100))
        offset = max(0, offset)
        with user_db() as conn:
            rows = conn.execute(
                "SELECT * FROM tier_snapshot ORDER BY created_at DESC, id DESC "
                "LIMIT ? OFFSET ?", (limit, offset)).fetchall()
            total = conn.execute("SELECT COUNT(*) FROM tier_snapshot").fetchone()[0]
        items = []
        for r in rows:
            d = tier_row_to_data(r)
            items.append({"id": d["id"], "created_at": d["created_at"],
                          "summary": d["summary"], "title": d["title"], "total": d["total"],
                          "thumbs": d["thumbs"], "picked": d["picked"]})
        self._json({"ok": True, "version": TIER_VERSION,
                    "data": {"items": items, "total": total}})

    @route("GET", r"/api/user/tier/snapshots/(\d+)")
    def tier_snapshot_one(self, query, sid, *_) -> None:
        """单张快照的完整内容（含 tiers/items）。

        历史记录里点「查看 / 下载」要能重画任意一张老图，而列表只给摘要与三张缩略图。
        """
        with user_db() as conn:
            row = conn.execute(
                "SELECT * FROM tier_snapshot WHERE id = ?", (int(sid),)).fetchone()
        if row is None:
            return self._error(404, "没有这张图")
        self._json({"ok": True, "version": TIER_VERSION, "data": tier_row_to_data(row)})

    @route("DELETE", r"/api/user/tier/snapshots/(\d+)")
    def tier_delete(self, query, sid, *_) -> None:
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM tier_snapshot WHERE id = ?", (int(sid),)).rowcount
        self._json({"ok": True, "version": TIER_VERSION, "data": {"removed": removed}})

    @route("POST", r"/api/user/tier/pick")
    def tier_pick(self, query, *_) -> None:
        body = self._body()
        try:
            sid = int(body.get("id"))
        except (TypeError, ValueError):
            return self._error(422, "id 必填")
        with user_db() as conn:
            row = conn.execute("SELECT id FROM tier_snapshot WHERE id = ?", (sid,)).fetchone()
            if row is None:
                return self._error(404, "没有这张图")
            conn.execute("UPDATE tier_snapshot SET picked = 0 WHERE picked = 1")
            conn.execute("UPDATE tier_snapshot SET picked = 1 WHERE id = ?", (sid,))
        self._json({"ok": True, "version": TIER_VERSION, "data": {"id": sid}})

    # -- 元数据覆盖层（2.5.5）---------------------------------------------
    #
    # 只写 user.db 的 `meta_override`，amane 的库一个字不动；读接口「覆盖优先」。
    # 契约见 `docs/TASKS/2.5.5-metadata-cover.md` §1。

    @route("GET", r"/api/user/meta_override/(\d+)")
    def meta_override_get(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        ov = meta_override_map([mid]).get(mid) or {"fields": {}, "cover": ""}
        self._json({"ok": True, "data": {"id": mid, "fields": ov["fields"],
                                         "cover": ov["cover"]}})

    @route("PUT", r"/api/user/meta_override/(\d+)")
    def meta_override_put(self, query, metadata_id, *_) -> None:
        """部分更新：只存你传上来的键；传空串 / 空数组 = 清掉这个键的覆盖。"""
        mid = int(metadata_id)
        patch, err = clean_override(self._body())
        if err:
            return self._error(422, err)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields, cover FROM meta_override WHERE metadata_id = ?",
                (mid,)).fetchone()
            fields: dict = _json_dict(row["fields"]) if row else {}
            cover = str(row["cover"] or "") if row else ""
            for key, value in patch.items():
                if value == "" or value == []:
                    fields.pop(key, None)
                else:
                    fields[key] = value
            if fields or cover:
                conn.execute(
                    "INSERT INTO meta_override(metadata_id, fields, cover, updated_at) "
                    "VALUES(?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                    "fields = excluded.fields, cover = excluded.cover, "
                    "updated_at = excluded.updated_at",
                    (mid, json.dumps(fields, ensure_ascii=False), cover, now_iso()))
            else:
                # 一个字段都没改、也没有自定义封面 → 不留空壳记录
                conn.execute("DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "fields": fields, "cover": cover}})

    @route("DELETE", r"/api/user/meta_override/(\d+)")
    def meta_override_delete(self, query, metadata_id, *_) -> None:
        """恢复默认：字段覆盖与自定义封面一起清掉（图还留在 photos 里，不删文件）。"""
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM meta_override WHERE metadata_id = ?",
                (int(metadata_id),)).rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})

    @route("POST", r"/api/user/meta_override/clear")
    def meta_override_clear(self, query, *_) -> None:
        """清空所有本地修改（设置页），要二次确认。"""
        body = self._body()
        if body.get("confirm") is not True:
            return self._error(422, "要带 {\"confirm\": true} 才清")
        with user_db() as conn:
            removed = conn.execute("DELETE FROM meta_override").rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})

    # -- 自建分类的管理（2.5.5.16）-----------------------------------------
    #
    # 用户自己起的系列 / 标签只存在于覆盖层，库里没有它们。这里给一个「只看自建」
    # 的列表与删除入口 —— **不碰库里原有的分类**（那是别人的资产，暂不开放修改）。

    @route("GET", r"/api/user/virtual_facets")
    def virtual_facets(self, query, *_) -> None:
        counts: dict = {"series": {}, "tag": {}}
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields FROM meta_override").fetchall()
        except sqlite3.Error as exc:
            return self._error(500, f"读覆盖层失败: {exc}")
        for r in rows:
            fields = _json_dict(r["fields"])
            for kind, field in (("series", "series"), ("tag", "tags")):
                value = fields.get(field)
                names = value if isinstance(value, list) else (
                    [value] if isinstance(value, str) else [])
                for raw in names:
                    name = str(raw or "").strip()
                    if name:
                        buckets = counts[kind]
                        buckets[name] = buckets.get(name, 0) + 1
        out: list = []
        try:
            with amane_db() as conn:
                for kind, table in (("series", "series"), ("tag", "tags")):
                    for name, films in counts[kind].items():
                        row = conn.execute(
                            f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1",
                            (name,)).fetchone()
                        # 库里已有的同名分类不算「自建」，不进这个列表
                        if row is None:
                            out.append({"kind": kind, "name": name, "films": films})
        except sqlite3.Error as exc:
            return self._error(502, f"读分类表失败: {exc}")
        # 登记表里「先建好、还没挂到任何片」的名字也要出现（films=0），
        # 否则用户在管理页点加号建完，列表里看不到它，以为没成功。
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                reg = conn.execute(
                    "SELECT kind, name FROM self_facets").fetchall()
        except sqlite3.Error as exc:
            log(f"WARN 读自建登记表失败: {exc}")
            reg = []
        seen = {(v["kind"], v["name"]) for v in out}
        for r in reg:
            kind = str(r["kind"] or "")
            name = str(r["name"] or "")
            if kind not in ("series", "tag") or not name:
                continue
            if (kind, name) in seen:
                continue
            out.append({"kind": kind, "name": name, "films": counts[kind].get(name, 0)})

        out.sort(key=lambda v: (-v["films"], v["name"]))
        # 管理页要画成「一行一条带封面」，把换过的封面一次带上（没有就空，客户端用首字）
        covers: dict = {}
        for kind in ("series", "tag"):
            names = [v["name"] for v in out if v["kind"] == kind]
            if names:
                covers.update(cover_override_map(kind, names))
        for v in out:
            v["cover"] = covers.get(v["name"], "")
            # 没换过封面时，管理页要能像「制片厂」那样拼贴显示。
            # 注意：自建名字在库里**没有**对应记录，按名字查 metadata 是空的 ——
            # 必须先用覆盖层拿到「被改成这个名字的片」的 id，再取它们海报。
            posters: list = []
            try:
                mids = override_ids_for(v["kind"], v["name"])[:6]
                if mids:
                    ph = ",".join("?" * len(mids))
                    with amane_db() as conn:
                        rows = conn.execute(
                            f"SELECT poster_urls, thumb_urls FROM metadata "
                            f"WHERE id IN ({ph})", mids).fetchall()
                    for r in rows:
                        for u in (_json_list(r["poster_urls"]) + _json_list(r["thumb_urls"])):
                            p = public_image(u)
                            if p and p not in posters:
                                posters.append(p)
                                break
                if not posters:
                    for u in cover_gif_sources_for(v["kind"], v["name"], 4):
                        p = public_image(u)
                        if p and p not in posters:
                            posters.append(p)
            except Exception as exc:  # noqa: BLE001
                log(f"WARN 自建分类取拼贴失败 {v['name']}: {exc}")
            v["posters"] = posters[:4]
        self._json({"ok": True, "data": {"items": out, "total": len(out)}})

    @route("POST", r"/api/user/virtual_facets/create")
    def virtual_facet_create(self, query, *_) -> None:
        """先建一个自建系列 / 标签（可以先没有片挂着）。

        只写 `self_facets` 登记表，不动任何影片的覆盖字段；等用户在某部片的
        编辑页里填这个名字时，两边自然对上（列表按名字合并）。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        name = str(body.get("name") or "").strip()
        if kind not in ("series", "tag"):
            return self._error(400, "kind 只能是 series 或 tag")
        if not name:
            return self._error(400, "名字不能为空")
        if len(name) > 60:
            return self._error(400, "名字太长了（最多 60 字）")
        # 和库里已有分类重名就没意义了：那种名字不在「自建」范围内
        try:
            with amane_db() as conn:
                table = "series" if kind == "series" else "tags"
                row = conn.execute(
                    f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (name,)).fetchone()
        except sqlite3.Error as exc:
            return self._error(502, f"读分类表失败: {exc}")
        if row is not None:
            return self._error(409, "库里已经有同名的分类了")
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                exists = conn.execute(
                    "SELECT 1 FROM self_facets WHERE kind = ? AND name = ?",
                    (kind, name)).fetchone()
                if exists is None:
                    conn.execute(
                        "INSERT INTO self_facets(kind, name, created_at) VALUES(?,?,?)",
                        (kind, name, datetime.now(timezone.utc).isoformat(timespec="seconds")))
                conn.commit()
        except sqlite3.Error as exc:
            return self._error(500, f"写自建登记表失败: {exc}")
        self._json({"ok": True, "data": {"kind": kind, "name": name}})

    @route("POST", r"/api/user/virtual_facets/delete")
    def virtual_facet_delete(self, query, *_) -> None:
        """删掉一个自建分类：把它从所有片的覆盖字段里摘掉（只动覆盖层）。

        原分类不在这个入口的范围内 —— kind 只收 series / tag，且只处理
        「覆盖层里被写成这个名字」的部分，库里原有分类一字不动。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        name = str(body.get("name") or "").strip()
        if kind not in ("series", "tag") or not name:
            return self._error(400, "要指定 kind（series / tag）与 name")
        field = "series" if kind == "series" else "tags"
        touched = 0
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields, cover FROM meta_override").fetchall()
                for r in rows:
                    fields = _json_dict(r["fields"])
                    changed = False
                    if field == "series":
                        if str(fields.get("series") or "").strip() == name:
                            fields.pop("series", None)
                            changed = True
                    else:
                        cur = fields.get("tags")
                        if isinstance(cur, list):
                            keep = [t for t in cur if str(t or "").strip() != name]
                            if len(keep) != len(cur):
                                if keep:
                                    fields["tags"] = keep
                                else:
                                    fields.pop("tags", None)
                                changed = True
                    if not changed:
                        continue
                    touched += 1
                    mid = int(r["metadata_id"])
                    if fields or str(r["cover"] or ""):
                        conn.execute(
                            "UPDATE meta_override SET fields = ?, updated_at = ? "
                            "WHERE metadata_id = ?",
                            (json.dumps(fields, ensure_ascii=False), now_iso(), mid))
                    else:
                        conn.execute(
                            "DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        except sqlite3.Error as exc:
            return self._error(500, f"删除失败: {exc}")
        try:
            with user_db() as conn:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS self_facets("
                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                conn.execute(
                    "DELETE FROM self_facets WHERE kind = ? AND name = ?",
                    (kind, name))
                conn.commit()
        except sqlite3.Error as exc:
            log(f"WARN 清理自建登记表失败 {kind}={name}: {exc}")
        invalidate_item_caches()
        log(f"删除自建分类 {kind}={name}，影响 {touched} 部")
        self._json({"ok": True, "data": {"kind": kind, "name": name, "removed": touched}})

    @route("POST", r"/api/user/virtual_facets/rename")
    def virtual_facet_rename(self, query, *_) -> None:
        """重命名一个自建分类：把所有片覆盖层里的旧名替换成新名。

        - 新名在库里已存在 → 这些片就直接归入那个原生分类（`native: true`，
          客户端据此提示「已并入库里的同名分类」）。
        - 新名也是另一个自建名 → 两个自建分类合并。
        - 只动覆盖层，库里的分类一个字不改。
        """
        body = self._body()
        kind = str(body.get("kind") or "")
        src = str(body.get("from") or "").strip()
        dst = str(body.get("to") or "").strip()
        if kind not in ("series", "tag"):
            return self._error(400, "kind 只支持 series / tag")
        if not src or not dst:
            return self._error(400, "要指定 from 与 to")
        if src == dst:
            return self._json({"ok": True, "data": {"kind": kind, "from": src,
                                                    "to": dst, "renamed": 0, "native": False}})
        field = "series" if kind == "series" else "tags"
        touched = 0
        try:
            with user_db() as conn:
                rows = conn.execute(
                    "SELECT metadata_id, fields FROM meta_override").fetchall()
                for r in rows:
                    fields = _json_dict(r["fields"])
                    if field == "series":
                        if str(fields.get("series") or "").strip() != src:
                            continue
                        fields["series"] = dst
                    else:
                        cur = fields.get("tags")
                        if not isinstance(cur, list):
                            continue
                        kept: list = []
                        hit = False
                        for tag in cur:
                            if str(tag or "").strip() == src:
                                hit = True
                                if dst not in kept:
                                    kept.append(dst)
                            else:
                                kept.append(tag)
                        if not hit:
                            continue
                        fields["tags"] = kept
                    touched += 1
                    conn.execute(
                        "UPDATE meta_override SET fields = ?, updated_at = ? "
                        "WHERE metadata_id = ?",
                        (json.dumps(fields, ensure_ascii=False), now_iso(),
                         int(r["metadata_id"])))
        except sqlite3.Error as exc:
            return self._error(500, f"重命名失败: {exc}")
        native = False
        try:
            with amane_db() as conn:
                table = "series" if kind == "series" else "tags"
                native = conn.execute(
                    f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (dst,)).fetchone() is not None
        except sqlite3.Error:
            native = False
        invalidate_item_caches()
        log(f"重命名自建分类 {kind}: {src} -> {dst}，影响 {touched} 部（native={native}）")
        self._json({"ok": True, "data": {"kind": kind, "from": src, "to": dst,
                                         "renamed": touched, "native": native}})

    @route("POST", r"/api/user/names/check")
    def names_check(self, query, *_) -> None:
        """保存元数据前问一句：这些系列 / 标签 / 厂牌，库里到底有没有。

        客户端拿到 `exists:false` 就弹「库里没有，是否新建」—— 确认后照常 PUT
        覆盖层；新名字由 facets 扩展以虚拟分类的形式出现在列表里。
        只读查询，不写任何东西。
        """
        body = self._body()
        items = body.get("items")
        tables = {"series": "series", "tag": "tags", "studio": "studios", "actor": "actors"}
        out: list = []
        if isinstance(items, list) and items:
            with amane_db() as conn:
                for it in items[:60]:
                    if not isinstance(it, dict):
                        continue
                    kind = str(it.get("kind") or "")
                    name = str(it.get("name") or "").strip()
                    if not name:
                        continue
                    table = tables.get(kind)
                    if table is None:
                        # 不认的类别不拦（宁可少提示，也别拦着用户存）
                        out.append({"kind": kind, "name": name, "exists": True})
                        continue
                    try:
                        row = conn.execute(
                            f"SELECT 1 FROM {table} WHERE name = ? LIMIT 1", (name,)).fetchone()
                        exists = row is not None
                    except sqlite3.Error:
                        exists = True
                    # 用户先在管理页「＋」建好的自建名也算存在，否则每存一次都会被问
                    # 「库里没有，是否新建」，等于自建标签白建了。
                    if not exists and kind in ("series", "tag"):
                        try:
                            with user_db() as uconn:
                                uconn.execute(
                                    "CREATE TABLE IF NOT EXISTS self_facets("
                                    "kind TEXT NOT NULL, name TEXT NOT NULL, "
                                    "created_at TEXT NOT NULL, PRIMARY KEY(kind, name))")
                                hit = uconn.execute(
                                    "SELECT 1 FROM self_facets WHERE kind = ? AND name = ?",
                                    (kind, name)).fetchone()
                            exists = hit is not None
                        except sqlite3.Error as exc:
                            log(f"WARN names/check 查自建登记表失败: {exc}")
                    out.append({"kind": kind, "name": name, "exists": exists})
        self._json({"ok": True, "data": {"items": out}})

    @route("POST", r"/api/user/cover/(\d+)")
    def cover_upload(self, query, metadata_id, *_) -> None:
        """上传自定义封面 / 动图：body `{data: base64 或 data URI, ext}`。

        复用核心的 `save_photo()`（落到 DATA_DIR/photos/<sha1>.<ext>，由
        `/api/user/photo/<name>` 提供访问），**不另建第二套上传**。
        """
        mid = int(metadata_id)
        body = self._body()
        raw = str(body.get("data") or "")
        if raw.startswith("data:"):
            comma = raw.find(",")
            raw = raw[comma + 1:] if comma > 0 else raw
        try:
            blob = base64.b64decode(raw, validate=False)
        except Exception:  # noqa: BLE001
            return self._error(400, "图片数据无法解析")
        if not blob:
            return self._error(400, "空图片")
        if len(blob) > 12 * 1024 * 1024:
            return self._error(413, "图片太大（上限 12MB）")

        ext = str(body.get("ext") or "").lower().lstrip(".")
        if ext == "jpeg":
            ext = "jpg"
        if ext not in ("jpg", "png", "webp", "gif"):
            if blob[:3] == b"\xff\xd8\xff":
                ext = "jpg"
            elif blob[:8] == b"\x89PNG\r\n\x1a\n":
                ext = "png"
            elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
                ext = "webp"
            elif blob[:3] == b"GIF":
                ext = "gif"
            else:
                return self._error(400, "只支持 jpg / png / webp / gif")

        name = f"{hashlib.sha1(blob).hexdigest()}.{ext}"
        try:
            save_photo(name, blob)
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR 封面保存失败: {exc}")
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{name}"
        wide_url = make_wide_of_photo(url)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            fields = _json_dict(row["fields"]) if row else {}
            conn.execute(
                "INSERT INTO meta_override(metadata_id, fields, cover, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                "cover = excluded.cover, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (mid, json.dumps(fields, ensure_ascii=False), url, wide_url, now_iso()))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "url": url, "wide": wide_url}})

    @route("DELETE", r"/api/user/cover/(\d+)")
    def cover_delete(self, query, metadata_id, *_) -> None:
        """只恢复原封面，不动字段覆盖。"""
        mid = int(metadata_id)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            if row is None:
                return self._json({"ok": True, "data": {"id": mid, "cover": ""}})
            fields = _json_dict(row["fields"])
            if fields:
                conn.execute(
                    "UPDATE meta_override SET cover = '', updated_at = ? WHERE metadata_id = ?",
                    (now_iso(), mid))
            else:
                conn.execute("DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "cover": ""}})

    @route("POST", r"/api/user/cover/(\d+)/gif")
    def cover_gif(self, query, metadata_id, *_) -> None:
        """用这部片自己的剧照生成循环 GIF 当封面（2.5.5.5）。

        body 可选：`{count: 6, duration: 420, width: 360}`
        —— `count` 用几张图、`duration` 每帧毫秒、`width` 封面宽（高 = 宽 × 1.5）。
        """
        mid = int(metadata_id)
        body = self._body()

        def pick(key: str, default: int, lo: int, hi: int) -> int:
            try:
                value = int(body.get(key) or default)
            except (TypeError, ValueError):
                value = default
            return max(lo, min(hi, value))

        want = pick("count", 6, 2, 8)
        duration = pick("duration", 700, 200, 2000)
        width = pick("width", 320, 200, 600)

        urls = cover_gif_sources(mid, want + 3)
        if not urls:
            return self._error(422, "这部片没有可用图片（剧照和封面都取不到）")
        blob, first = build_cover_gif(urls, width=width, duration=duration, max_frames=want)
        if not blob:
            if not _has_pillow():
                return self._error(503, "服务端缺少 Pillow，GIF 功能不可用")
            return self._error(422, "图片下载失败，稍后再试")

        name = f"{hashlib.sha1(blob).hexdigest()}.gif"
        try:
            save_photo(name, blob)
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{name}"
        # 横版衍生图：模糊背景 + 完整海报，给继续观看 / 每日推荐那些 16:9 位
        wide_url = ""
        wide_blob = build_wide_jpeg(first) if first is not None else b""
        if wide_blob:
            wname = f"{hashlib.sha1(wide_blob).hexdigest()}.jpg"
            try:
                save_photo(wname, wide_blob)
                wide_url = f"/api/user/photo/{wname}"
            except Exception:  # noqa: BLE001
                wide_url = ""
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            fields = _json_dict(row["fields"]) if row else {}
            conn.execute(
                "INSERT INTO meta_override(metadata_id, fields, cover, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                "cover = excluded.cover, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (mid, json.dumps(fields, ensure_ascii=False), url, wide_url, now_iso()))
        invalidate_item_caches()
        log(f"cover gif mid={mid} frames={want} bytes={len(blob)} wide={bool(wide_url)}")
        self._json({"ok": True, "data": {"id": mid, "url": url, "wide": wide_url,
                                         "frames": want, "bytes": len(blob)}})

    # -- 投屏令牌（2.5.6）--------------------------------------------------
    #
    # 投屏时要把播放地址交给电视 / 盒子，而主 token 是万能钥匙（能改覆盖层、能删快照）。
    # 这里发的 `ct` 是**只读媒体专用**的短时凭证：只认 GET/HEAD 的
    # /play /streams /photo /studio-logo，别的路径一律 401。

    @route("POST", r"/api/user/cast/token")
    def cast_token_create(self, query, *_) -> None:
        body = self._body()
        try:
            hours = int(body.get("hours") or 12)
        except (TypeError, ValueError):
            hours = 12
        hours = max(1, min(72, hours))
        token = os.urandom(16).hex()
        now = datetime.now(timezone.utc)
        created = now.isoformat(timespec="seconds")
        expires = (now + timedelta(hours=hours)).isoformat(timespec="seconds")
        with user_db() as conn:
            # 顺手清掉过期的，别让表无限长
            conn.execute("DELETE FROM cast_token WHERE expires_at < ?", (created,))
            conn.execute(
                "INSERT INTO cast_token(token, created_at, expires_at) VALUES(?,?,?)",
                (token, created, expires))
        host = str(self.headers.get("Host") or "")
        self._json({"ok": True, "data": {"token": token, "created_at": created,
                                         "expires_at": expires, "ttl_hours": hours,
                                         "base": f"http://{host}" if host else ""}})

    @route("GET", r"/api/user/cast/token")
    def cast_token_list(self, query, *_) -> None:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT token, created_at, expires_at FROM cast_token "
                "ORDER BY created_at DESC").fetchall()
        items = [{"token": str(r["token"]), "created_at": str(r["created_at"]),
                  "expires_at": str(r["expires_at"])} for r in rows]
        self._json({"ok": True, "data": {"items": items}})

    @route("DELETE", r"/api/user/cast/token/([0-9a-f]{32})")
    def cast_token_delete(self, query, token, *_) -> None:
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM cast_token WHERE token = ?", (token,)).rowcount
        _CAST_HIT.pop(token, None)
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})

    @route("POST", r"/api/user/cast/link")
    def cast_link(self, query, *_) -> None:
        """给电视/盒子准备好一整套只读地址（2.5.6）。

        body：`{mid, source?, key?, hours?}`。返回的每个 URL 都已经带好 `ct`，
        前端（还没做）只要把 `url` 丢给电视即可；字幕与封面也一并给好，
        免得电视那边再拿主 token。
        """
        body = self._body()
        try:
            mid = int(body.get("mid") or 0)
        except (TypeError, ValueError):
            mid = 0
        if mid <= 0:
            return self._error(422, "mid 必填")
        source = str(body.get("source") or "nas.local")[:32]
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", source):
            return self._error(422, "source 不合法")
        key = str(body.get("key") or "")
        if key and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", key):
            return self._error(422, "key 不合法")

        with amane_db() as conn:
            rows = conn.execute(
                f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (mid,)).fetchall()
        if not rows:
            return self._error(404, "条目不存在")
        item = item_of(rows[0])
        apply_overrides([item])

        # 复用一把还没过期的钥匙；没有就现发一把（默认 12 小时）
        token = ""
        now = datetime.now(timezone.utc)
        created = now.isoformat(timespec="seconds")
        with user_db() as conn:
            row = conn.execute(
                "SELECT token FROM cast_token WHERE expires_at > ? "
                "ORDER BY created_at DESC LIMIT 1", (created,)).fetchone()
            if row is not None:
                token = str(row["token"])
        if not token:
            try:
                hours = int(body.get("hours") or 12)
            except (TypeError, ValueError):
                hours = 12
            hours = max(1, min(72, hours))
            token = os.urandom(16).hex()
            expires = (now + timedelta(hours=hours)).isoformat(timespec="seconds")
            with user_db() as conn:
                conn.execute("DELETE FROM cast_token WHERE expires_at < ?", (created,))
                conn.execute(
                    "INSERT INTO cast_token(token, created_at, expires_at) VALUES(?,?,?)",
                    (token, created, expires))
        with user_db() as conn:
            row = conn.execute(
                "SELECT expires_at FROM cast_token WHERE token = ?", (token,)).fetchone()
        expires_at = str(row["expires_at"]) if row is not None else ""

        host = str(self.headers.get("Host") or "")
        base = f"http://{host}" if host else ""
        play = f"{base}/api/user/play/{source}/{mid}?ct={token}"
        if key:
            play += f"&key={quote(key)}"
        self._json({"ok": True, "data": {
            "mid": mid,
            "number": item.get("number") or "",
            "title": item.get("title") or "",
            "source": source,
            "key": key,
            "token": token,
            "expires_at": expires_at,
            "base": base,
            "url": play,
            "cover_url": f"{base}/api/user/cast/cover/{mid}?ct={token}",
            "subtitles_url": f"{base}/api/user/subtitles?item_id={mid}&ct={token}",
            "subtitle_url_tpl": f"{base}/api/user/subtitle/{{id}}?ct={token}",
            "hint": "把 url 交给电视即可；字幕从 subtitles_url 里取 id，按 subtitle_url_tpl 拼",
        }})

    @route("GET", r"/api/user/cast/cover/(\d+)")
    def cast_cover(self, query, metadata_id, *_) -> None:
        """电视用的封面：本服务代取，电视不需要任何 token 就能看到图。"""
        mid = int(metadata_id)
        with amane_db() as conn:
            rows = conn.execute(
                f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (mid,)).fetchall()
        if not rows:
            return self._error(404, "条目不存在")
        item = item_of(rows[0])
        apply_overrides([item])
        poster = str(item.get("poster") or "")
        if not poster:
            return self._error(404, "这部片没有封面")
        try:
            blob, ctype = cast_cover_bytes(poster)
        except Exception as exc:  # noqa: BLE001
            log(f"WARN 投屏封面取图失败 {mid} {poster}: {exc}")
            return self._error(502, f"取封面失败: {exc}")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        self.wfile.write(blob)

    @route("POST", r"/api/user/facet-gif/([a-z]+)/(.+)")
    def facet_cover_gif(self, query, kind, key, *_) -> None:
        """用分类里几部片的海报拼一段轮播 GIF，当这个分类的封面（2.5.5.7）。

        先做「类里所含海报的轮播」：每部片取 1 张，最多 8 张。
        以后要更强的动效（抽帧、转场、文字）再加参数，端点不用换。
        """
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        if not name:
            return self._error(400, "缺少分类名")
        body = self._body()

        def pick(k: str, default: int, lo: int, hi: int) -> int:
            try:
                value = int(body.get(k) or default)
            except (TypeError, ValueError):
                value = default
            return max(lo, min(hi, value))

        want = pick("count", 6, 2, 8)
        duration = pick("duration", 900, 200, 2000)
        width = pick("width", 320, 200, 600)

        urls = cover_gif_sources_for(kind, name, want + 4)
        if not urls:
            return self._error(422, "这个分类下没有可用海报")
        blob, first = build_cover_gif(urls, width=width, duration=duration, max_frames=want)
        if not blob:
            if not _has_pillow():
                return self._error(503, "服务端缺少 Pillow，GIF 功能不可用")
            return self._error(422, "海报下载失败，稍后再试")

        fname = f"{hashlib.sha1(blob).hexdigest()}.gif"
        try:
            save_photo(fname, blob)
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{fname}"
        # 分类封面也配一张 16:9 横版：分类详情页头部是横条（84×46），
        # 直接塞竖版动图会被裁掉大半，用户看着就是「局部截图」。
        wide_url = ""
        wide_blob = build_wide_jpeg(first) if first is not None else b""
        if wide_blob:
            wname = f"{hashlib.sha1(wide_blob).hexdigest()}.jpg"
            try:
                save_photo(wname, wide_blob)
                wide_url = f"/api/user/photo/{wname}"
            except Exception:  # noqa: BLE001
                wide_url = ""
        with user_db() as conn:
            conn.execute(
                "INSERT INTO cover_override(kind, \"key\", url, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(kind, \"key\") DO UPDATE SET "
                "url = excluded.url, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (kind, name, url, wide_url, now_iso()))
        invalidate_item_caches()
        log(f"facet gif {kind}={name} frames={want} bytes={len(blob)} wide={bool(wide_url)}")
        self._json({"ok": True, "data": {"kind": kind, "key": name, "url": url,
                                         "wide": wide_url,
                                         "frames": want, "bytes": len(blob)}})

    # -- 分类封面（2.5.5.4）：系列 / 标签 / 厂牌 / 演员 / 媒体库 ----------------
    #
    # key 用**名字**而不是 id：用户自己新起的系列在库里没有 id，用名字才能让
    # 「新建的分类」和「库里的分类」共用一套封面。媒体库用 `lib-<id>`。

    @route("GET", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_get(self, query, kind, key, *_) -> None:
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        covers = cover_override_both(kind, [name])
        hit = covers.get(name) or {}
        self._json({"ok": True, "data": {"kind": kind, "key": name,
                                         "url": hit.get("url", ""),
                                         "wide": hit.get("wide", "")}})

    @route("POST", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_upload(self, query, kind, key, *_) -> None:
        """换分类封面（支持 gif 动图）。body `{data: base64 或 data URI, ext}`。"""
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        if not name:
            return self._error(400, "缺少分类名")
        url, err = _save_uploaded_image(self._body())
        if err:
            return self._error(413 if "太大" in err else 400, err)
        # 相册图也生成一张 16:9：分类详情页头部是横条，竖图塞进去会被裁掉大半
        wide_url = make_wide_of_photo(url)
        with user_db() as conn:
            conn.execute(
                "INSERT INTO cover_override(kind, \"key\", url, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(kind, \"key\") DO UPDATE SET "
                "url = excluded.url, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (kind, name, url, wide_url, now_iso()))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"kind": kind, "key": name, "url": url,
                                         "wide": wide_url}})

    @route("DELETE", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_delete(self, query, kind, key, *_) -> None:
        """恢复成默认封面（媒体库回到海报拼贴，分类回到拼贴/首字）。"""
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM cover_override WHERE kind = ? AND \"key\" = ?",
                (kind, name)).rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"kind": kind, "key": name, "removed": int(removed or 0)}})


def _bootstrap_name_pinyin() -> None:
    """启动后台把拼音索引建起来（空表才建）。

    为什么放后台：建表要读 amane 主库的 tags/series/actors 三张全表再逐字算读音，
    几千到几万行；放主线程会让服务晚几秒才能应答。表空着的时候拼音检索只是
    「暂时没有命中」，其余行为不受影响，所以慢一点没关系。
    """
    def run() -> None:
        try:
            if name_pinyin_count() > 0:
                return
            build_name_pinyin()
        except Exception as exc:  # noqa: BLE001
            log(f"WARN 拼音索引初始化失败: {exc}")

    threading.Thread(target=run, name="name-pinyin-init", daemon=True).start()


def main() -> None:
    EXT.load()
    init_user_db()
    os.makedirs(IMAGE_CACHE, exist_ok=True)
    log(f"amane-user {VERSION} on :{PORT}  amane={AMANE_BASE}  db={USER_DB}")
    if not AMANE_TOKEN:
        log("WARN 没读到 amane token，接口将不校验鉴权")
    cjk_tables()
    _bootstrap_name_pinyin()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
