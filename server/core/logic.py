"""业务逻辑层：聚合、检索、播放、统计等全部非 HTTP 代码（从 server.py 拆出）。

为什么是一个大文件而不是按域拆：这些函数互相引用极密（build 用 build_banners、
library 用 _stats_*、tier 用 pick_poster），按域硬切会连环 NameError。
先整体搬出，让 `api/*.py`（端点 mixin）能 import 它而**不产生循环**
（本文件不 import server），之后要细分再单独做。

边界：这里只有「算」和「查」，没有 HTTP。所有 `@route` 装饰后的端点仍在 server.py
的 Handler 里（或拆分后的 api/* mixin）。
"""
from __future__ import annotations

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
from core.config import (  # noqa: E402  (必须在常量之后，读的是同一批环境变量)
    AMANE_BASE, AMANE_DATA, AMANE_DB, AMANE_TOKEN, DATA_DIR, FINISH_RATIO,
    IMAGE_CACHE, PHOTO_DIR, PORT, PUBLIC_AMANE_URL, ROOT_DIR, UPSTREAM_CONF,
    USE_LOCAL_PLAY, USER_DB, _read_secret, save_photo,
)
from core.log import log  # noqa: E402,F401
from core.text import _SEP_RE, _norm_kw, _subseq, rel_score  # noqa: E402,F401
from core.db import amane_db, user_db  # noqa: E402,F401
from core.util import now_iso, _json_list, _json_dict  # noqa: E402,F401
from core.upstream import amane_get, amane_post  # noqa: E402,F401
from core.router import ROUTES, route  # noqa: E402,F401
from core.image import (  # noqa: E402,F401
    IMAGE_TOKEN, IMG_HOST_ALLOW, IMG_PROBE_BYTES, _b64url, _dims_get, _dims_put,
    _host_ok_cache, _image_size, _img_proxy, _unb64url, host_allowed, image_dims,
    public_image,
)
from core.ext import EXT, ExtensionHost  # noqa: E402,F401

from core.config import (  # noqa: F401
    AMANE_BASE, AMANE_DATA, AMANE_DB, AMANE_TOKEN, DATA_DIR, FINISH_RATIO,
    IMAGE_CACHE, PHOTO_DIR, PORT, PUBLIC_AMANE_URL, ROOT_DIR, UPSTREAM_CONF,
    USE_LOCAL_PLAY, USER_DB, _read_secret, save_photo,
)
from core.db import amane_db, user_db  # noqa: F401
from core.ext import EXT  # noqa: F401
from core.image import (  # noqa: F401
    IMAGE_TOKEN, IMG_HOST_ALLOW, IMG_PROBE_BYTES, _b64url, _dims_get, _dims_put,
    _host_ok_cache, _image_size, _img_proxy, _unb64url, host_allowed, image_dims,
    public_image,
)
from core.log import log  # noqa: F401
from core.router import ROUTES, route  # noqa: F401
from core.text import _norm_kw, _SEP_RE, _subseq, rel_score  # noqa: F401
from core.upstream import _opener, amane_get, amane_post  # noqa: F401
from core.util import _json_dict, _json_list, now_iso  # noqa: F401


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
"""

# VERSION 已归到 core/config.py（部署脚本的落点核对读那里）。
from core.config import VERSION  # noqa: F401


def export_to(ns: dict) -> None:
    """把本模块的**全部**名字（含下划线开头）塞进给定命名空间。

    为什么需要它：`from core.logic import *` 和 Python 的 `import *` 一样，
    **跳过所有下划线开头的名字**。而 `_bootstrap_name_pinyin` / `_local_path_for` /
    `_json_dict` 这些私有名在 main() 和 Handler 的 138 个方法里用得很多。
    2026-11-14 拆模块时就因为漏了这个，容器起来直接
    `NameError: _bootstrap_name_pinyin is not defined`。

    用法（在 server.py 或 api/*.py 顶部）：
        import core.logic as _L
        _L.export_to(globals())
    """
    import sys
    mod = sys.modules[__name__]
    for name in dir(mod):
        if not name.startswith('__'):
            ns[name] = getattr(mod, name)

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

_CJK_DIR = os.environ.get(
    "CJK_DATA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data"))


def _resolve_cjk_dir() -> str:
    """找中文检索表（t2s / jp2s / pinyin / alias）。

    2026-11-16：原来只认 `core/data`，而部署脚本把 tsv 放在**应用根目录的 `data/`**
    （`/app/data`），两边对不上 —— 后果是简繁 / 拼音 / 出厂别名全部静默降级，
    界面上看不出错，只是「搜不到某些名字」。现在按顺序找：环境变量 → core/data
    → 应用根 data，第一个真有 tsv 的胜出。
    """
    cands: list[str] = []
    env = os.environ.get("CJK_DATA_DIR")
    if env:
        cands.append(env)
    here = os.path.dirname(os.path.abspath(__file__))
    cands.append(os.path.join(here, "data"))
    cands.append(os.path.join(os.path.dirname(here), "data"))
    for path in cands:
        try:
            if any(fn.endswith(".tsv") for fn in os.listdir(path)):
                return path
        except OSError:
            continue
    return cands[-1]

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
    path = os.path.join(_resolve_cjk_dir(), name)
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
-- 索引新鲜度快照（2.8.x）：记下上次重建时 amane 主库三类名字的规模。
-- 只存一个签名字符串，不存名字本身 —— 检索时拿它和源库现况比，落后才重建。
CREATE TABLE IF NOT EXISTS name_pinyin_state (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);
"""

_PY_BUILD_LOCK = threading.Lock()

_PY_STAMP = 0                      # 每次重建 +1，用来作废查询缓存

_PY_CACHE: dict[str, list[tuple[str, str]]] = {}

# 自愈节流：拼音检索是高频路径，源库规模检查再便宜也不能每次都做。
# 失败时（读不到主库）只记时间不重建，避免每请求都去撞一个坏库。
_PY_FRESH_AT = 0.0
_PY_FRESH_GAP = 10.0        # 秒：拼音 miss 很多，最快 10s 查一次源库规模
_PY_FRESH_LOCK = threading.Lock()
_PY_FRESH_PENDING = False   # 后台重建在跑，别重复派发

def _source_name_sig() -> str:
    """amane 主库三类名字的规模签名：每类的 (条数, 最大 id)。

    为什么不用 hash 全表：签名只在「拼音检索没命中」时算一次，且要足够便宜。
    COUNT + MAX(id) 走索引，几千到几万行也是毫秒级；条数变（新入库/删）或
    id 上限变（改名重建）都能捕捉到。读不到主库返回空串，调用方据此跳过自愈。
    """
    parts: list[str] = []
    with amane_db() as conn:
        for _kind, sql in _PY_KINDS.items():
            # 从 _PY_KINDS 的 SQL 里取表名，别再单独维护一份映射（改 SQL 就自动跟上）
            match = re.search(r"\bFROM\s+(\w+)", sql)
            if match is None:
                return ""
            table = match.group(1)
            try:
                row = conn.execute(
                    f"SELECT COUNT(*), COALESCE(MAX(id), 0) FROM {table}").fetchone()
                parts.append(f"{int(row[0])}:{int(row[1])}")
            except sqlite3.Error:
                # 上游某张表没有 id 列时退回纯条数：仍能发现「新入库」，
                # 只是发现不了「改名重建」，总比整个签名失效强。
                try:
                    row = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
                    parts.append(f"{int(row[0])}:0")
                except sqlite3.Error:
                    return ""
    return "|".join(parts)

def _stored_name_sig() -> str:
    try:
        with user_db() as conn:
            row = conn.execute(
                "SELECT v FROM name_pinyin_state WHERE k='src_sig'").fetchone()
        return str(row[0]) if row else ""
    except sqlite3.Error:
        return ""

def name_pinyin_stale() -> bool:
    """拼音索引是否落后于主库。空签名（表没建/读不到主库）不算落后，避免误触发。"""
    stored = _stored_name_sig()
    if not stored:
        return False
    now = _source_name_sig()
    return bool(now) and now != stored

def ensure_name_pinyin_fresh() -> bool:
    """拼音未命中时的自愈钩子：索引落后就丢后台重建，返回是否已派发。

    为什么不直接在这里同步重建：几千行逐字算读音要几秒，挂在检索请求上
    用户会觉得「一搜就卡」。本次请求按旧索引返回（本来就是 0 命中），后台
    建完后 `_PY_CACHE` 会清掉，下一次搜索就能命中新演员。

    并发：10s 节流 + `_PY_FRESH_LOCK` 判重 + 后台线程；`build_name_pinyin`
    内部还有 `_PY_BUILD_LOCK`，所以手动 reindex 和自愈不会打架。
    """
    global _PY_FRESH_AT, _PY_FRESH_PENDING
    now = time.time()
    if now - _PY_FRESH_AT < _PY_FRESH_GAP or _PY_FRESH_PENDING:
        return False
    with _PY_FRESH_LOCK:
        if time.time() - _PY_FRESH_AT < _PY_FRESH_GAP or _PY_FRESH_PENDING:
            return False
        _PY_FRESH_AT = time.time()
        try:
            if not name_pinyin_stale():
                return False
        except Exception as exc:  # noqa: BLE001 - 自愈不能把检索带崩
            log(f"WARN 拼音索引新鲜度检查失败: {exc}")
            return False
        _PY_FRESH_PENDING = True

    def run() -> None:
        global _PY_FRESH_PENDING
        try:
            out = build_name_pinyin()
            if out.get("ok"):
                log(f"拼音索引自愈重建（源库新增名字）："
                    f"{out.get('count')} 条 / {out.get('ms')}ms")
        except Exception as exc:  # noqa: BLE001
            log(f"WARN 拼音索引自愈重建失败: {exc}")
        finally:
            with _PY_FRESH_LOCK:
                _PY_FRESH_PENDING = False

    threading.Thread(target=run, name="name-pinyin-refresh", daemon=True).start()
    return True

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
        # 先取源库签名，再读名字：若这中间有新演员入库，结果是「索引有它、
        # 签名还没跟上」→ 下次检索会多重建一次（无害）；反过来（先读名字后取
        # 签名）会漏掉这期间的新演员，而且签名显示不落后、再也不会自愈。
        sig = _source_name_sig()
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
            # 写的是这次重建开头取到的签名（见上）。中途崩了签名还是旧的，
            # 下次检索会再判为落后、再重建一次，不会把新名字永久漏掉。
            if sig:
                conn.execute(
                    "INSERT OR REPLACE INTO name_pinyin_state(k, v) VALUES('src_sig', ?)",
                    (sig,))
        _PY_STAMP += 1
        _PY_CACHE.clear()
        variant = build_variants(rows)
        spent = round((time.time() - start) * 1000)
        log(f"中文索引重建完成：名字 {len(rows)} 条，折叠别名 {variant} 条，{spent}ms")
        return {"ok": True, "count": len(rows), "variant": variant, "ms": spent}

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
        # 命中缓存也要给自愈一个机会：新演员入库后，之前查过的 token 会一直
        # 命中旧缓存，永远走不到 miss 分支（2026-11-20 这个老问题的真正形态）。
        # 检查是 10s 节流 + 一条 user.db 查询，命中路径的额外开销可忽略。
        ensure_name_pinyin_fresh()
        return cached
    out: list[tuple[str, str]] = []
    # 拼音没命中往往是「名字还没进索引」，同样触发自愈检查。
    ensure_name_pinyin_fresh()
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

_PY_COND: dict[str, str] = {
    "tag": ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
            "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)"),
    "series": "m.series = ?",
    "actor": "m.actors LIKE ?",
}

# 演员 / 标签的**正确**写法（2026-11-15 每日推荐踩过）：
# `metadata.actors` 是 JSON 文本，值是 `\uXXXX` 转义过的 —— 拿中文名去 LIKE 永远 0 行。
# 上游有 `metadata_actors` / `metadata_tags` 关联表，按名字 JOIN 才准。
DAILY_ACTOR_WHERE: str = ("m.id IN (SELECT ma.metadata_id FROM metadata_actors ma "
                          "JOIN actors a ON a.id = ma.actor_id WHERE a.name = ?)")
DAILY_TAG_WHERE: str = ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                        "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)")

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

_NUM_QUERY_RE = re.compile(r"^[a-z]{1,8}-?\d{2,6}$|^\d{3,}$", re.I)

def looks_like_number(raw: str) -> bool:
    """像番号 / 纯数字的查询：`SSIS-001`、`ssis001`、`12345`。

    这类词搜不到，说明**这部片不在库里**，不代表「用户不知道正确名字」——
    把它塞进别名待办是错的（2026-11-16 用户指出：搜番号也进了待处理）。
    别名要解决的是「同一件东西的不同叫法」，不是「库里没有」。
    """
    q = re.sub(r"[\s_]+", "", (raw or "")).strip().lower()
    if not q:
        return False
    return bool(_NUM_QUERY_RE.match(q))

def record_search_miss(raw: str, q_norm: str, hits: int) -> None:
    """记下「严格搜索也几乎没结果」的词，供别名页当待办。

    只在 `qmode != or` 时调用：客户端放宽重试那次结果会变多，记下来就是假账。
    **番号形态的词直接跳过**（见 `looks_like_number`）。
    """
    q = re.sub(r"\s+", " ", (q_norm or "")).strip().lower()
    if len(q) < 2 or hits > _MISS_MAX_HITS:
        return
    if looks_like_number(q) or looks_like_number(raw):
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

EXTENSIONS_MANIFEST = os.environ.get("EXTENSIONS_MANIFEST", "/app/extensions.json")

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
                finished    INTEGER NOT NULL DEFAULT 0,
                -- 播放次数（2026-11-20）：隔 30 分钟以上再上报才算新的一次（见 mine.py）。
                -- 客户端心跳几秒一次，不按窗口判的话这个数会直接顶到几百。
                plays       INTEGER NOT NULL DEFAULT 0
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
            -- 多版本片子的「上次看的是哪个文件」（2.6.1.14）：
            -- 一个条目常挂 2~6 个可播文件，用户每次都要重新挑一遍，记下来当默认。
            CREATE TABLE IF NOT EXISTS stream_choice (
                metadata_id INTEGER PRIMARY KEY,
                file_key    TEXT NOT NULL,
                updated_at  TEXT NOT NULL
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
        # 迁移（2026-11-20）：history 加 plays —— 「重复观看」是画像里最硬的一个信号，
        # 也是用户能直接看懂的口径（看了 5 遍的片，比打 5 星更能说明问题）。
        hcols = [r["name"] for r in conn.execute("PRAGMA table_info(history)").fetchall()]
        if "plays" not in hcols:
            conn.execute("ALTER TABLE history ADD COLUMN plays INTEGER NOT NULL DEFAULT 0")
            # 老数据没有次数：把「看过的」一律算 1 次，至少不让排序出现一堆 0
            conn.execute("UPDATE history SET plays = 1 WHERE plays = 0")
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

META_OVERRIDE_DDL = """
CREATE TABLE IF NOT EXISTS meta_override (
    metadata_id INTEGER PRIMARY KEY,
    fields      TEXT NOT NULL DEFAULT '{}',   -- JSON：只含改过的键
    cover       TEXT NOT NULL DEFAULT '',     -- 站内相对路径 /api/user/photo/xxx.gif
    updated_at  TEXT NOT NULL
);
"""

CAST_DDL = """
CREATE TABLE IF NOT EXISTS cast_token (
    token      TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cast_exp ON cast_token(expires_at);
"""

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

META_COLUMNS = (
    "m.id, m.number, m.title, m.plot, m.actors, m.tags, m.studio, m.series, "
    "m.release, m.runtime, m.content_type, m.poster_urls, m.thumb_urls, "
    "m.extrafanart_urls, m.scores, m.updated_at"
)

SUGGEST_KINDS = ("film", "actor", "director", "tag", "series", "studio")

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

_CAST_AGE_EXPR = (
    "CAST(strftime('%Y', substr(m.release, 1, 10)) AS INTEGER) "
    "- CAST(strftime('%Y', substr(caa.birthday, 1, 10)) AS INTEGER) "
    "- (CASE WHEN strftime('%m-%d', substr(m.release, 1, 10)) "
    "< strftime('%m-%d', substr(caa.birthday, 1, 10)) THEN 1 ELSE 0 END)"
)

CAST_AGE_GENDERS = ("female", "male")

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

CAST_AGE_SORT_SQL = {
    g: {"asc": cast_age_sql(g, "MIN"), "desc": cast_age_sql(g, "MAX")}
    for g in CAST_AGE_GENDERS
}

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

def fill_temp_covers(items: list) -> None:
    """没有正式封面的片，用「第三张截帧」顶上（2.6.1.50）。

    只在 `poster` 为空时填，所以两种情况都会**自动让位**：
    - 上游后来补了海报 → `pick_poster()` 有值，这里根本不跑；
    - 用户手动换封面 → `meta_override.cover` 已经盖上去，也不跑。
    因此不需要「删临时封面」这种清理动作，也不会出现临时图压住真封面。
    """
    need: list = []
    for it in items:
        if not isinstance(it, dict) or it.get("poster"):
            continue
        try:
            mid = int(it.get("id") or 0)
        except (TypeError, ValueError):
            continue
        if mid > 0:
            need.append(mid)
    if not need:
        return
    try:
        got = EXT.call("temp_covers", need)
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 临时封面失败: {exc}")
        return
    if not got:
        return
    for it in items:
        if not isinstance(it, dict) or it.get("poster"):
            continue
        url = got.get(int(it.get("id") or 0))
        if url:
            it["poster"] = url
            it["poster_temp"] = True

def apply_overrides(items: list) -> list:
    """把覆盖层盖到条目上（就地改，返回同一个 list）。"""
    if not items:
        return items
    ids = [it.get("id") for it in items if isinstance(it, dict)]
    ovs = meta_override_map(ids)
    if not ovs:
        fill_temp_covers(items)
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
    fill_temp_covers(items)
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

def build_home(fresh: bool = False, hero_pool: str = "all",
               hero_spec: dict | None = None) -> dict:
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
    if fresh:
        # 每次进首页（客户端会带 fresh=1）把推荐换一批：只洗顺序、不换集合 ——
        # 以前推荐是按分数固定排序，所以「一整天进来都是同一条」（2026-11-13 反馈）。
        # 「继续观看」不在这里，不受影响。
        random.shuffle(recommend)
    # 首页这几条是用户第一眼看到的：尺寸没量过的现场补（并发 + 超时），
    # 免得发布版用户空缓存时只能看第一张糊图。
    # 下拉刷新（fresh）不跑这一步：那是几秒的联网开销，下拉只该"重新取一遍"——
    # 没量过的图已经由 pick_fanart 用 thumb 兜底，不会糊。
    if not fresh:
        _probe_home_fanarts(recommend)
    # 每日推荐横幅：只放「宽度 ≥720 且宽高比 ≥1.25」的真横图，并带上真实比例，
    # 客户端按比例定宽（16:9 不是唯一答案：dmm 剧照多是 3:2）。
    banners = build_banners(12, fresh=fresh)
    # 顶部大图与推荐位**分开取数**（2.6.1.30「随手翻到」）：原来 hero 就是 recommend 的前 6 部，
    # 于是「每日推荐」里那几部在顶部又出现一遍，两处的语义（当日固定 / 随机）也混在一起。
    hero = build_hero(6, fresh=fresh, exclude={b["id"] for b in banners},
                      pool=hero_pool, spec=hero_spec)
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
    """继续观看不缓存：刚看完一集回到首页应当立刻反映出来。

    2.6.1.34（用户 19:24）：**不再按 finished 过滤**。
    以前 `WHERE finished = 0`，于是「看完一部、退出」之后它再也不出现在继续观看里，
    详情页的「继续播放」也跟着消失 —— 用户的原话是「应该记住每一次退出播放的位置，
    不管他是否已经播放完毕」。位置本来就一直在写（`history_upsert` 每次退出都 update
    `position`），只是被这行过滤挡在外面。播完的片 position 落在末尾，进度条自然显示满，
    按 played_at 排序也会随时间往下沉，不会长期霸榜。
    """
    with user_db() as conn:
        hist = conn.execute(
            "SELECT metadata_id, position, duration, played_at FROM history "
            "WHERE position > 30 ORDER BY played_at DESC LIMIT 12"
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
    day_seed = int(today_local().strftime("%Y%m%d"))
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
    rng = random.Random(today_local().isoformat())
    rng.shuffle(uniq)
    # 每日推荐用横幅展示，横图（剧照/封面 fanart）是硬需求：没有横图的往后排，
    # 不足 limit 再用竖版海报补位，保证总数不变。
    with_fan = [x for x in uniq if x["fanart"]]
    out = with_fan[:limit]
    if len(out) < limit:
        out += [x for x in uniq if not x["fanart"]][:limit - len(out)]
    # 覆盖层：推荐位同样要显示改过的片名 / 自定义封面
    return attach_marks_auto(attach_progress(apply_overrides(out)))

def _hero_pool_where(pool: str) -> tuple[str, tuple]:
    """把候选池翻成 amane DB 的 WHERE。

    **收藏 / 历史 / 评分都在 user.db**，不是 amane.db —— 2026-11-14 第一版直接写
    `m.id IN (SELECT ... FROM favorites)` 导致 `no such table: favorites`，
    三个池子全 500。所以这里先从 user.db 取 id 集合，再用 `IN (...)` 传入。
    空集直接返回无法命中的条件（由 build_hero 兜底退回全库）。
    """
    p = (pool or "all").strip()
    if p == "all":
        return "", ()
    try:
        if p == "fav":
            with user_db() as conn:
                ids = [int(r[0]) for r in conn.execute("SELECT metadata_id FROM favorites")]
        elif p == "unwatched":
            with user_db() as conn:
                seen = [int(r[0]) for r in conn.execute("SELECT DISTINCT metadata_id FROM history")]
            if not seen:
                return "", ()
            marks = ",".join("?" for _ in seen)
            return f"m.id NOT IN ({marks})", tuple(seen)
        elif p == "rated":
            with user_db() as conn:
                ids = [int(r[0]) for r in conn.execute(
                    "SELECT metadata_id FROM user_ratings WHERE score >= 4")]
        elif p == "recent":
            return "m.updated_at >= datetime('now', '-90 day')", ()
        else:
            return "", ()
    except Exception as exc:  # noqa: BLE001
        log(f"hero pool {p} 取 id 失败，退回全库: {exc}")
        return "", ()
    if not ids:
        return "m.id IN (NULL)", ()
    marks = ",".join("?" for _ in ids)
    return f"m.id IN ({marks})", tuple(ids)


def _hero_where(spec: dict | None) -> tuple[str, tuple]:
    """把「自由条件」翻成 amane DB 的 WHERE（2026-11-14 用户要求可自选，不再是固定预设）。

    spec 支持（都可缺省，全缺省 = 全库）：
      - `libs`: [库 id]           → 只在这些媒体库
      - `tags`: [标签名]          → 命中任一标签
      - `actor`: 演员名（子串匹配）
      - `year_from` / `year_to`   → 发行年区间
      - `min_score`               → 刮削评分下限
      - `state`: any|unwatched|watched|fav|rated（用户侧状态，来自 user.db）
    """
    if not spec:
        return "", ()
    where: list[str] = []
    params: list = []
    try:
        libs = [int(x) for x in (spec.get("libs") or []) if str(x).strip()]
        if libs:
            marks = ",".join("?" for _ in libs)
            where.append("m.id IN (SELECT metadata_id FROM media_files "
                         f"WHERE library_id IN ({marks}))")
            params.extend(libs)
        tags = [str(t) for t in (spec.get("tags") or []) if str(t).strip()]
        if tags:
            marks = ",".join("?" for _ in tags)
            where.append("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                         f"JOIN tags t ON t.id = mt.tag_id WHERE t.name IN ({marks}))")
            params.extend(tags)
        actor = str(spec.get("actor") or "").strip()
        if actor:
            # `metadata.actors` 是 **ensure_ascii 的 JSON**（`["\u6df1\u6708\u3081\u3044"]`），
            # 直接 `LIKE '%深月めい%'` 永远是 0 命中（2026-11-14 实测：直连 LIKE=0，
            # json_each 解出来 11 部）。所以按 JSON 元素匹配；非 JSON 的历史串用
            # json_array() 包成单元素，LIKE 仍按子串命中。
            where.append("EXISTS (SELECT 1 FROM json_each("
                         "CASE WHEN json_valid(m.actors) THEN m.actors "
                         "ELSE json_array(m.actors) END) WHERE value LIKE ?)")
            params.append(f"%{actor}%")
        yf = int(spec.get("year_from") or 0)
        if yf > 0:
            where.append("CAST(substr(m.release, 1, 4) AS INTEGER) >= ?")
            params.append(yf)
        yt = int(spec.get("year_to") or 0)
        if yt > 0:
            where.append("CAST(substr(m.release, 1, 4) AS INTEGER) <= ?")
            params.append(yt)
        ms = float(spec.get("min_score") or 0)
        if ms > 0:
            where.append("m.scores LIKE ?")
            params.append(f"%{int(ms)}%")

        state = str(spec.get("state") or "any").strip()
        if state != "any":
            with user_db() as conn:
                if state == "fav":
                    ids = [int(r[0]) for r in conn.execute("SELECT metadata_id FROM favorites")]
                elif state == "rated":
                    ids = [int(r[0]) for r in conn.execute(
                        "SELECT metadata_id FROM user_ratings WHERE score >= 4")]
                elif state == "watched":
                    ids = [int(r[0]) for r in conn.execute(
                        "SELECT DISTINCT metadata_id FROM history WHERE position > 0")]
                else:  # unwatched
                    seen = [int(r[0]) for r in conn.execute(
                        "SELECT DISTINCT metadata_id FROM history WHERE position > 0")]
                    if seen:
                        marks = ",".join("?" for _ in seen)
                        where.append(f"m.id NOT IN ({marks})")
                        params.extend(seen)
                    ids = []
            if state in ("fav", "rated", "watched"):
                if not ids:
                    return "m.id IN (NULL)", ()
                marks = ",".join("?" for _ in ids)
                where.append(f"m.id IN ({marks})")
                params.extend(ids)
    except Exception as exc:  # noqa: BLE001
        log(f"hero 条件解析失败，退回全库: {exc}")
        return "", ()
    return (" AND ".join(where), tuple(params))


def build_hero(limit: int = 6, fresh: bool = False, exclude: set[int] | None = None,
               pool: str = "all", spec: dict | None = None) -> list[dict]:
    """首页顶部大图（2.6.1.30「随手翻到」）。

    **和每日推荐分开的独立池子**（用户 2026-11-13 18:47 明确要求）：
    - 每日推荐（`build_recommend`）：今天这 12 部，当日种子固定，刷新也不换；
    - 随手翻到（这里）：全库随手抓几部，**下拉刷新就换一批**。
    两批互相排除（`exclude`），免得同一部在顶部和推荐位各出现一次。

    不用 `fresh` 时也按当日种子排 —— 同一个上午反复进出首页，顶部不该自己跳片；
    想看新的就下拉。
    """
    skip: set[int] = exclude if exclude else set()
    # 自由条件优先；没给条件时才走老的预设池（向后兼容 pool=fav|null|…）
    if spec:
        where, wparams = _hero_where(spec)
    else:
        where, wparams = _hero_pool_where(pool)
    with amane_db() as conn:
        if fresh:
            # 真随机：这是「随机推荐」的唯一来源
            rows = query_meta(conn, where, wparams, "RANDOM()", 160)
        else:
            # ★ 2026-11-14 12:00：不再按当日种子固定 ★
            # 用户明确：「每日推荐已经有专门的栏位了，首页 hero 图只需要每次进入都换新」。
            # 之前这里是 `(m.id * 1103515245 + day_seed) %% 2147483647`，
            # 同一天怎么进都是同一批 —— 那正好是「每日推荐」该有的语义，被误用到 hero 上了。
            # 现在不分 fresh 一律 RANDOM()；缓存那一层再由 cached_home 单独处理（hero 不进缓存）。
            rows = query_meta(conn, where, wparams, "RANDOM()", 160)
        if not rows and where:
            # 池子太窄（比如收藏里没有横图）：**退回全库**，别让首页顶部空着
            rows = query_meta(conn, "", (), "RANDOM()", 160)
    picked: list[dict] = []
    for x in rows:
        if x["id"] in skip or not x["fanart"]:
            continue
        picked.append(x)
        if len(picked) >= limit:
            break
    if not picked:
        # 极端情况：一张横图都没有 —— 退回竖版，顶部至少不空
        for x in rows:
            if x["id"] in skip:
                continue
            picked.append(x)
            if len(picked) >= limit:
                break
    return attach_marks_auto(attach_progress(picked))

BANNER_TTL = 1800

BANNER_POOL_TARGET = 60          # 池子里攒够这么多张就不再预热

# ── 「今天」按哪个时区算（2026-11-15 修）──────────────────────────────
# 用户报「每日推荐昨天和今天一样」。根因候选有两条，这里一次性都堵上：
#   ① **时区**：容器里 TZ 可能没生效（镜像缺 tzdata 时 `TZ=Asia/Shanghai` 被忽略），
#      `date.today()` 就变成 UTC 日期 —— 北京时间 08:00 才翻页。于是用户 23:00 看到的
#      和次日 07:00 看到的是同一批，主观就是「昨天=今天」。改用显式 UTC+8。
#   ② **池子小**：横幅池上限 BANNER_POOL_TARGET=60，每天各洗一次牌取前 12，两天之间
#      很容易高度重合（60 选 12，期望重合 ~2.4 张，但小池时会更像）。
#      改成「按日种子洗牌 + 按日期轮转窗口」：相邻两天必然取到不同的 12 张。
LOCAL_TZ = timezone(timedelta(hours=8))

def today_local() -> date:
    """服务器视角的「今天」= 北京时间（UTC+8），与用户体感一致。"""
    return datetime.now(LOCAL_TZ).date()

def _day_of(raw: str | None) -> date:
    """`?day=YYYY-MM-DD` 仅用于排查/对账；非法或缺省都当今天。"""
    if raw:
        try:
            return date.fromisoformat(raw.strip())
        except ValueError:
            pass
    return today_local()

_banner_warm_lock = threading.Lock()

_banner_warming = False

# 正在补图的候选（按 metadata_id），避免同一条被重复探测
_banner_id_warming: set = set()

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
            random.Random(today_local().isoformat()).shuffle(rows)
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
            # 池子变了就重新算（当日顺序由 build_banners 现算，这里没有缓存要清）
            pass

    threading.Thread(target=worker, name="banner-warm", daemon=True).start()

def _kick_banner_warm_ids(ids: list[int]) -> None:
    """**针对候选**补横图（2026-11-15）。

    以前只有「按更新时间扫 900 部、攒够 60 张就停」的通用预热 —— 于是推荐位上永远只有
    那 60 部在转。现在推荐先挑片、再看有没有合格横图；候选缺图就把这几条丢进后台探测，
    下一轮请求就能命中。不阻塞当前请求，失败只留日志。
    """
    todo: list[int] = []
    with _banner_warm_lock:
        for mid in ids:
            if mid in _banner_id_warming:
                continue
            _banner_id_warming.add(mid)
            todo.append(mid)
    if not todo:
        return

    def worker() -> None:
        try:
            for mid in todo:
                try:
                    with amane_db() as conn:
                        row = conn.execute(
                            "SELECT " + META_COLUMNS + " FROM metadata m WHERE m.id = ?",
                            (mid,),
                        ).fetchone()
                    if row is None:
                        continue
                    url, ratio = _pick_banner(None, row)
                    stamp = now_iso()
                    with user_db() as wconn:
                        wconn.execute(
                            "INSERT INTO banner_ok(metadata_id, url, ratio, updated_at) "
                            "VALUES(?, ?, ?, ?) ON CONFLICT(metadata_id) DO UPDATE SET "
                            "url = excluded.url, ratio = excluded.ratio, "
                            "updated_at = excluded.updated_at",
                            (mid, url or "", ratio if url else 0, stamp),
                        )
                except Exception as exc:          # noqa: BLE001
                    log(f"WARN 候选补横图失败 {mid}: {exc}")
        finally:
            with _banner_warm_lock:
                for mid in todo:
                    _banner_id_warming.discard(mid)

    try:
        threading.Thread(target=worker, daemon=True, name="banner-warm-ids").start()
    except RuntimeError as exc:
        log(f"WARN banner warm ids thread: {exc}")
        with _banner_warm_lock:
            for mid in todo:
                _banner_id_warming.discard(mid)

# ── 每日推荐：理由登记表 + 配额（2026-11-15）─────────────────────────────
# 设计要点（用户要求）：
#   ① **理由先定、片子后挑**：每个 kind 的「选片条件」就是它给用户的说法；
#   ② 理由会**持续新增**，所以这里是一张登记表：加一个 kind = 加一行 + 一个 picker，
#      配额由权重算，不用改 build_daily；
#   ③ 配额对用户开放，但**只给取向**（更懂我 / 均衡 / 多惊喜），不列桶名与比例。
DAILY_ORDER: tuple = ("taste", "similar", "series", "studio", "era", "top", "fresh", "explore")

DAILY_REASONS: dict = {
    # 2026-11-20：理由从「只有打分才说得出口」改成按证据强度分档 ——
    # 给过高分 > 看过好几部 > 只是常出现。隐式行为（看完、重看）也算「看过」。
    "taste":   "同演员：给过 4~5 星 / 收藏过 / 看过他好几部",
    "similar": "同标签：你偏好的口味（按看过部数）",
    "series":  "同系列 / 同番号前缀（收过几部就说几部）",
    "studio":  "厂牌：你看过最多部的",
    "era":     "年代：你看得最多的那十年",
    "top":     "库里评分高的（你还没看）",
    "fresh":   "新入库",
    "explore": "没接触过的演员",
}

DAILY_PRESETS: dict = {
    # 权重绝对值不重要，build_daily 会按比例折算成整数配额（最大余数法）
    "taste":    {"taste": 5, "similar": 3, "series": 2, "studio": 1, "era": 1,
                 "top": 2, "fresh": 1, "explore": 0},
    "balanced": {"taste": 3, "similar": 3, "series": 2, "studio": 1, "era": 1,
                 "top": 2, "fresh": 2, "explore": 1},
    "explore":  {"taste": 1, "similar": 1, "series": 1, "studio": 0, "era": 1,
                 "top": 3, "fresh": 3, "explore": 4},
}

DEFAULT_DAILY_PRESET = "balanced"

def _short_title(title: str, n: int = 14) -> str:
    t = (title or "").strip()
    return t if len(t) <= n else t[:n] + "…"

def daily_preset() -> str:
    """用户选的取向（taste / balanced / explore）。读不到 = balanced。"""
    try:
        path = os.path.join(DATA_DIR, "daily.json")
        with open(path, encoding="utf-8") as fh:
            name = str((json.load(fh) or {}).get("preset") or "")
        return name if name in DAILY_PRESETS else DEFAULT_DAILY_PRESET
    except (OSError, ValueError):
        return DEFAULT_DAILY_PRESET

def set_daily_preset(name: str) -> dict:
    if name not in DAILY_PRESETS:
        raise ValueError(f"没有这个取向：{name}")
    path = os.path.join(DATA_DIR, "daily.json")
    tmp = path + ".tmp"
    data: dict = {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh) or {}
    except (OSError, ValueError):
        data = {}
    data["preset"] = name
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return {"preset": name}

def daily_ratio() -> float | None:
    """用户拖过滑杆的探索比例（0~0.5）。None = 跟着 preset 走（三档预设的默认配比）。"""
    try:
        path = os.path.join(DATA_DIR, "daily.json")
        with open(path, encoding="utf-8") as fh:
            v = (json.load(fh) or {}).get("explore_ratio")
        if v is None:
            return None
        return max(0.0, min(0.5, float(v)))
    except (OSError, ValueError, TypeError):
        return None


def set_daily_ratio(ratio: float) -> dict:
    """存探索比例。用户要的是「别让算法越推越窄」—— 这个滑杆就是那个闸门。"""
    f = max(0.0, min(0.5, float(ratio)))
    path = os.path.join(DATA_DIR, "daily.json")
    tmp = path + ".tmp"
    data: dict = {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh) or {}
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    data["explore_ratio"] = round(f, 3)
    data.setdefault("preset", daily_preset())
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return {"explore_ratio": data["explore_ratio"]}


def daily_quotas(limit: int, preset: str | None = None) -> dict:
    """把权重折算成整数配额（最大余数法），保证总数正好 = limit。

    2026-11-20：滑杆拖过就以 `explore_ratio` 为准 —— 探索份额先切走，
    剩下的按 preset 里其余理由的相对权重分。没拖过则完全按 preset。
    """
    weights = dict(DAILY_PRESETS.get(preset or daily_preset(),
                                    DAILY_PRESETS[DEFAULT_DAILY_PRESET]))
    ratio = daily_ratio()
    if ratio is not None:
        ex = max(0, min(limit, int(round(limit * ratio))))
        base = {k: v for k, v in weights.items() if k != "explore" and v > 0}
        total = sum(base.values()) or 1
        rest = limit - ex
        raw = {k: (rest * v / total) for k, v in base.items()}
        out: dict = {k: int(v) for k, v in raw.items()}
        out["explore"] = ex
        gap = limit - sum(out.values())
        for k, _v in sorted(raw.items(), key=lambda kv: -(kv[1] - int(kv[1])))[:max(0, gap)]:
            out[k] = out.get(k, 0) + 1
        return {k: v for k, v in out.items() if v > 0}
    total = sum(w for w in weights.values() if w > 0) or 1
    raw = {k: (limit * w / total) for k, w in weights.items() if w > 0}
    out = {k: int(v) for k, v in raw.items()}
    rest = limit - sum(out.values())
    for k, _v in sorted(raw.items(), key=lambda kv: -(kv[1] - int(kv[1])))[:max(0, rest)]:
        out[k] = out.get(k, 0) + 1
    return out

def _age_days(iso_ts) -> float:
    """`played_at` 距今多少天。解析不出来按「很久以前」算（衰减到最低档）。"""
    if not iso_ts:
        return 999.0
    try:
        dt = datetime.fromisoformat(str(iso_ts))
    except ValueError:
        return 999.0
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return max(0.0, (datetime.now(timezone.utc) - dt).total_seconds() / 86400.0)


def _daily_profile() -> dict:
    """口味画像 —— 每日推荐的**理由来源**（2026-11-15）。

    以前是「先出 12 部、客户端再看着这 12 部编理由」，所以理由只能挑「这批里最高分 /
    同系列」这类**凑出来**的说法。现在反过来：画像先算好，挑片时就用它当条件，
    理由只是把条件说出来。

    读不到用户数据就返回空画像，调用方退化成「新用户配方」，不让首页塌掉。
    """
    prof: dict = {"stars": {}, "seen": set(), "disliked": set(),
                  "actors": {}, "actor_seed": {}, "tags": {}, "series": {},
                  "studios": {}, "eras": {}, "prefixes": {}, "seeds": {},
                  # 隐式行为累加进来的片（2026-11-20）：{metadata_id: 权重}
                  "implicit": {},
                  # 理由用的**整数计数**（2026-11-20）：权重是给排序的，说给用户听要
                  # 「你看过她的 4 部」这种能对上号的事实，不能报小数权重。
                  "actor_hits": {}, "tag_hits": {}, "series_hits": {},
                  "studio_hits": {}, "era_hits": {},
                  # 重看过的片：{metadata_id: plays}，理由里优先说这件事
                  "rewatch": {}}
    try:
        with user_db() as conn:
            ratings = conn.execute("SELECT metadata_id, score FROM user_ratings").fetchall()
            favs = [r["metadata_id"]
                    for r in conn.execute("SELECT metadata_id FROM favorites").fetchall()]
            prof["seen"] = {r["metadata_id"]
                            for r in conn.execute("SELECT metadata_id FROM history").fetchall()}
    except sqlite3.Error as exc:      # noqa: BLE001
        log(f"WARN 每日推荐画像：读不到用户数据（按空画像继续）{exc}")
        return prof
    stars: dict = {}
    for r in ratings:
        try:
            stars[int(r["metadata_id"])] = int(r["score"] or 0)
        except (TypeError, ValueError):
            continue
    prof["stars"] = stars
    prof["disliked"] = {mid for mid, s in stars.items() if s <= 2}
    seeds = list(dict.fromkeys([m for m, s in stars.items() if s >= 4] + list(favs)))[-80:]
    if not seeds:
        return prof
    try:
        with amane_db() as conn:
            marks = ",".join("?" * len(seeds))
            rows = conn.execute(
                f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id IN ({marks})", seeds).fetchall()
    except sqlite3.Error as exc:      # noqa: BLE001
        log(f"WARN 每日推荐画像：读不到种子片 {exc}")
        return prof
    for row in rows:
        prof["seeds"][row["id"]] = _short_title(row["title"])
        stars_of_row = int(stars.get(row["id"], 5) or 5)
        for name in _json_list(row["actors"])[:4]:
            if name:
                prof["actors"][name] = prof["actors"].get(name, 0) + 1
                prof["actor_hits"][name] = prof["actor_hits"].get(name, 0) + 1
                if name not in prof["actor_seed"]:
                    prof["actor_seed"][name] = (_short_title(row["title"]), stars_of_row)
        for name in _json_list(row["tags"])[:6]:
            if name:
                prof["tags"][name] = prof["tags"].get(name, 0) + 1
                prof["tag_hits"][name] = prof["tag_hits"].get(name, 0) + 1
        if row["series"]:
            prof["series"][row["series"]] = prof["series"].get(row["series"], 0) + 1
            prof["series_hits"][row["series"]] = prof["series_hits"].get(row["series"], 0) + 1
        if row["studio"]:
            prof["studios"][row["studio"]] = prof["studios"].get(row["studio"], 0) + 1
            prof["studio_hits"][row["studio"]] = prof["studio_hits"].get(row["studio"], 0) + 1
        year = str(row["release"] or "")[:4]
        if year.isdigit():
            era = f"{(int(year) // 10) * 10}s"
            prof["eras"][era] = prof["eras"].get(era, 0) + 1
            prof["era_hits"][era] = prof["era_hits"].get(era, 0) + 1
        prefix = (row["number"] or "").split("-")[0].strip().upper()
        if prefix:
            prof["prefixes"][prefix] = prof["prefixes"].get(prefix, 0) + 1

    # ── 隐式行为（2026-11-20）：完成度 / 跳过 / 时间衰减 ─────────────────────
    # 为什么要加：107 部看过里只有 35 部打过星 —— 评分是少数派。剩下那些
    # 「看了多久」的信号以前全扔掉，等于把大半行为数据浪费了。
    try:
        with user_db() as conn:
            hrows = conn.execute(
                "SELECT metadata_id, position, duration, played_at, finished, plays "
                "FROM history"
            ).fetchall()
    except sqlite3.Error as exc:
        hrows = []
        log(f"WARN 每日推荐画像：读不到观看历史 {exc}")
    implicit: dict[int, float] = {}
    for h in hrows:
        try:
            mid = int(h["metadata_id"])
        except (TypeError, ValueError):
            continue
        dur = float(h["duration"] or 0)
        pos = float(h["position"] or 0)
        ratio = (pos / dur) if dur > 1 else 0.0
        fin = int(h["finished"] or 0)
        try:
            plays = int(h["plays"] or 0)
        except (TypeError, ValueError):
            plays = 0
        if fin or ratio >= 0.85:
            w = 0.8
        elif ratio >= 0.4:
            w = 0.35
        elif 0 < ratio < 0.15:
            w = -0.5          # 点开就走：弱负信号
        else:
            w = 0.0
        # 重复观看（2026-11-20）：看了 2 遍以上，每多一遍补 0.15，最多 +0.5。
        # 这是最硬的信号 —— 一部片能被反复打开，比打 5 星更能说明问题。
        if plays >= 2 and w >= 0:
            w += min(0.5, 0.15 * (plays - 1))
        if w == 0.0:
            continue
        # 时间衰减：一个月内算「现在喜欢」，三个月内打六折，更早只留四分之一。
        # 不做衰减的话，三年前看过的一批片会一直压在最新口味上。
        age = _age_days(h["played_at"])
        decay = 1.0 if age <= 30 else (0.6 if age <= 90 else 0.25)
        implicit[mid] = implicit.get(mid, 0.0) + w * decay

    # 只把**正**信号拿去学特征：负信号（点开就走）不进排行，否则某个标签
    # 只要有几部被点开就走，整类都会被拉黑 —— 那正是用户说的「越推越窄」。
    extra = [m for m, w in implicit.items() if w > 0 and m not in stars and m not in favs][:200]
    if extra:
        try:
            with amane_db() as conn:
                marks = ",".join("?" * len(extra))
                rows2 = conn.execute(
                    f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id IN ({marks})", extra
                ).fetchall()
        except sqlite3.Error as exc:
            rows2 = []
            log(f"WARN 每日推荐画像：读不到隐式片 {exc}")
        for row in rows2:
            w = min(0.8, float(implicit.get(int(row["id"]), 0.0)))
            if w <= 0:
                continue
            prof["implicit"][int(row["id"])] = round(w, 2)
            for name in _json_list(row["actors"])[:4]:
                if name:
                    prof["actors"][name] = prof["actors"].get(name, 0) + w
                    prof["actor_hits"][name] = prof["actor_hits"].get(name, 0) + 1
            for name in _json_list(row["tags"])[:6]:
                if name:
                    prof["tags"][name] = prof["tags"].get(name, 0) + w
                    prof["tag_hits"][name] = prof["tag_hits"].get(name, 0) + 1
            if row["series"]:
                prof["series"][row["series"]] = prof["series"].get(row["series"], 0) + w
                prof["series_hits"][row["series"]] = prof["series_hits"].get(row["series"], 0) + 1
            if row["studio"]:
                prof["studios"][row["studio"]] = prof["studios"].get(row["studio"], 0) + w
                prof["studio_hits"][row["studio"]] = prof["studio_hits"].get(row["studio"], 0) + 1
            year = str(row["release"] or "")[:4]
            if year.isdigit():
                era = f"{(int(year) // 10) * 10}s"
                prof["eras"][era] = prof["eras"].get(era, 0) + w
                prof["era_hits"][era] = prof["era_hits"].get(era, 0) + 1
            prefix = (row["number"] or "").split("-")[0].strip().upper()
            if prefix:
                prof["prefixes"][prefix] = prof["prefixes"].get(prefix, 0) + w
    return prof

def _daily_pool(where: str, params: tuple, order: str = "m.updated_at DESC",
                limit: int = 40) -> list[dict]:
    """一次候选查询；失败只记日志（不让首页塌掉）。"""
    try:
        with amane_db() as conn:
            return query_meta(conn, where, params, order, limit)
    except sqlite3.Error as exc:      # noqa: BLE001
        log(f"WARN 每日推荐候选查询失败 {where}: {exc}")
        return []

def _by_score(items: list[dict]) -> list[dict]:
    return sorted(items, key=lambda x: -float(x.get("score") or 0))


def _score_text(x: dict) -> str:
    """分数文案。0 分 = 库里没评分，别把「0.0 分」当理由说给用户听。"""
    try:
        s = float(x.get("score") or 0)
    except (TypeError, ValueError):
        return ""
    return f"{s:.1f} 分" if s > 0 else ""

def build_daily(limit: int = 12, day: date | None = None) -> list[dict]:
    """每日推荐：**理由先定、片子后挑**（2026-11-15 用户定 · 可扩展登记表）。

    每个 kind 的「选片条件」就是它给用户的那句话；配额来自取向权重（`daily_quotas`）。
    加新理由 = 在 `DAILY_ORDER` / `DAILY_REASONS` / 下面 `pickers` 里各加一处，主流程不动。

    硬排除：看过的不推、给过 1~2 星的不推、同一批不重复。
    顺序与集合按日期种子打散（同一天固定、跨天必换）。
    """
    d: date = day if day is not None else today_local()
    rng = random.Random(f"daily|{d.isoformat()}")
    prof = _daily_profile()
    seen: set = set(prof["seen"]) | set(prof["disliked"])
    used: set = set()
    out: list[dict] = []
    quota = daily_quotas(limit)
    today_ord: int = d.toordinal()

    # 多样性闸（2026-11-20）：同一演员最多 2 部、同一系列最多 1 部。
    # 不加的话「常看演员」那一档会把同一个人的片连着铺开（12 部里 5 部同演员），
    # 就是用户说的「越推越窄」。挑不满时由后面的 top / fresh 桶兜底。
    actor_cap = 2
    series_cap = 1
    # 番号前缀也限一道（2026-11-20 实测发现）：JMSZ-94/95/97 这种同厂同系列的片，
    # 如果 series 字段没填，series_cap 拦不住，结果 12 部里连着三部同一批货，
    # 理由还一模一样。前缀最多 2 部。
    prefix_cap = 2
    actor_hit: dict = {}
    series_hit: dict = {}
    prefix_hit: dict = {}

    def take(items: list[dict], kind: str, text_of, need: int,
             actor_cap_local: int = -1, series_cap_local: int = -1) -> int:
        acap = actor_cap if actor_cap_local < 0 else actor_cap_local
        scap = series_cap if series_cap_local < 0 else series_cap_local
        n = 0
        for x in items:
            if n >= need:
                break
            mid = x.get("id")
            if mid in used or mid in seen or not x.get("poster"):
                continue
            acts = _json_list(x.get("actors"))[:2]
            ser = str(x.get("series") or "").strip()
            pref = str(x.get("number") or "").split("-")[0].strip().upper()
            if ser and series_hit.get(ser, 0) >= scap:
                continue
            if pref and prefix_hit.get(pref, 0) >= prefix_cap:
                continue
            if acts and all(actor_hit.get(a, 0) >= acap for a in acts):
                continue
            used.add(mid)
            for a in acts:
                if a:
                    actor_hit[a] = actor_hit.get(a, 0) + 1
            if ser:
                series_hit[ser] = series_hit.get(ser, 0) + 1
            if pref:
                prefix_hit[pref] = prefix_hit.get(pref, 0) + 1
            x["reason_kind"] = kind
            x["reason_text"] = text_of(x)
            out.append(x)
            n += 1
        return n

    def rot(rows: list[dict], salt: str) -> list[dict]:
        """给候选一个**按日期**的起点：候选集合固定时，跨天也能换成不同的片。

        用字符和做散列（不能用内置 hash —— 它对字符串是每进程随机的，
        服务重启后同一份数据会算出不同的日子，那就不是「当天固定」了）。
        """
        if not rows:
            return rows
        seed = sum(ord(c) for c in salt) % 997
        start = (today_ord * 7 + seed) % len(rows)
        return rows[start:] + rows[:start]

    def p_taste(need: int) -> int:
        actors = sorted(prof["actors"].items(), key=lambda kv: (-kv[1], kv[0]))
        left = need
        for actor, _cnt in actors[:6]:
            if left <= 0:
                break
            rows = rot(_by_score(_daily_pool(DAILY_ACTOR_WHERE, (actor,))),
                       f"taste:{actor}")
            st, ss = prof["actor_seed"].get(actor, ("", 0))
            hits = prof["actor_hits"].get(actor, 0)
            # 理由按「证据强度」挑一句（2026-11-20）：
            #   明确给过高分 > 看过好几部 > 只是常出现。
            # 以前只有第一档和第三档，中间那些「看完但没打分」的片就只剩一句
            # 「常看的演员」—— 用户看着像废话。
            if st and ss >= 4:
                text_of = (lambda t, s, a: (lambda x: f"你给《{t}》{s} 星 · 同演员 {a}"))(st, ss, actor)
            elif hits >= 2:
                text_of = (lambda a, n: (lambda x: f"你看过 {a} 的 {n} 部"))(actor, hits)
            else:
                text_of = (lambda a: (lambda x: f"常看的演员 {a}"))(actor)
            left -= take(rows, "taste", text_of, left)
        return need - left

    def p_similar(need: int) -> int:
        tags = sorted(prof["tags"].items(), key=lambda kv: (-kv[1], kv[0]))
        seed_title = next(iter(prof["seeds"].values()), "")
        left = need
        for tag, _cnt in tags[:6]:
            if left <= 0:
                break
            rows = rot(_by_score(_daily_pool(DAILY_TAG_WHERE, (tag,))), f"similar:{tag}")
            hits = prof["tag_hits"].get(tag, 0)
            if hits >= 3:
                text_of = (lambda g, n: (lambda x: f"你偏好的「{g}」· 看过 {n} 部"))(tag, hits)
            else:
                text_of = (lambda t, g: (lambda x: f"《{t}》那种口味 · 同标签 {g}"))(seed_title, tag)
            left -= take(rows, "similar", text_of, left)
        return need - left

    def p_series(need: int) -> int:
        series = sorted(prof["series"].items(), key=lambda kv: (-kv[1], kv[0]))
        prefixes = sorted(prof["prefixes"].items(), key=lambda kv: (-kv[1], kv[0]))
        left = need
        for name, _cnt in series[:4]:
            if left <= 0:
                break
            rows = rot(_by_score(_daily_pool("m.series = ?", (name,))), f"series:{name}")
            hits = prof["series_hits"].get(name, 0)
            if hits >= 2:
                text_of = (lambda s, n: (lambda x: f"《{s}》系列 · 你已经收了 {n} 部"))(name, hits)
            else:
                text_of = (lambda s: (lambda x: f"《{s}》同一系列"))(name)
            left -= take(rows, "series", text_of, left)
        for pref, _cnt in prefixes[:3]:
            if left <= 0:
                break
            rows = rot(_by_score(_daily_pool("m.number LIKE ?", (f"{pref}-%",))), f"pref:{pref}")
            left -= take(rows, "series",
                         (lambda p: (lambda x: f"你常看 {p} 的片"))(pref), left)
        return need - left

    def p_studio(need: int) -> int:
        studios = sorted(prof["studios"].items(), key=lambda kv: (-kv[1], kv[0]))
        left = need
        for name, _cnt in studios[:3]:
            if left <= 0:
                break
            rows = rot(_by_score(_daily_pool("m.studio = ?", (name,))), f"studio:{name}")
            hits = prof["studio_hits"].get(name, 0)
            if hits >= 2:
                text_of = (lambda s, n: (lambda x: f"你看过 {s} 的 {n} 部"))(name, hits)
            else:
                text_of = (lambda s: (lambda x: f"你常看 {s}"))(name)
            left -= take(rows, "studio", text_of, left)
        return need - left

    def p_era(need: int) -> int:
        eras = sorted(prof["eras"].items(), key=lambda kv: (-kv[1], kv[0]))
        left = need
        for era, _cnt in eras[:2]:
            if left <= 0:
                break
            base = int(era[:4])
            rows = rot(_by_score(_daily_pool(
                "substr(m.release, 1, 4) BETWEEN ? AND ?",
                (str(base), str(base + 9)), "m.release DESC", 40)), f"era:{era}")
            hits = prof["era_hits"].get(era, 0)
            if hits >= 2:
                text_of = (lambda e, n: (lambda x: f"你 {e} 的片看过 {n} 部"))(era, hits)
            else:
                text_of = (lambda e: (lambda x: f"你偏好的 {e} 年代"))(era)
            left -= take(rows, "era", text_of, left)
        return need - left

    def p_top(need: int, strict: bool = False) -> int:
        pool = _daily_pool("", (), "m.updated_at DESC", 160)
        scored = [x for x in pool if float(x.get("score") or 0) > 0]
        if strict and not scored:
            # 整池都没有评分 = 这一档说不出「库内高分」。主配额时直接让位（由调用方
            # 转给探索），别硬凑十几条「你还没看」；兜底时才允许用它填满。
            return 0
        rows = rot(_by_score(scored or pool), "top")

        # 库里很多片没有评分（score=0）：那种情况说「库内高分 0.0」等于自曝其短。
        # 但也不能十几条都说「你还没看」—— 那看着像没写理由。退一步给个能对上号的
        # 事实：这是哪一年的片。
        def _top_text(x: dict) -> str:
            sc = _score_text(x)
            if sc:
                return f"库内高分 {sc} · 你还没看"
            year = str(x.get("release") or "")[:4]
            if year.isdigit():
                return f"{year} 年的片 · 你还没看"
            return "你还没看过的片"
        return take(rows, "top", _top_text, need)

    def p_fresh(need: int) -> int:
        cutoff = (d - timedelta(days=45)).isoformat()
        rows = rot(_by_score(_daily_pool("m.updated_at >= ?", (cutoff,), "m.updated_at DESC", 60)),
                   "fresh")

        def _fresh_text(x: dict) -> str:
            days = today_ord - _ord_of(x.get("updated_at"))
            sc = _score_text(x)
            base = f"新入库 {days} 天" if days > 0 else "今天刚入库"
            return f"{base} · {sc}" if sc else base
        return take(rows, "fresh", _fresh_text, need)

    def p_explore(need: int) -> int:
        pool = rot(_by_score(_daily_pool("", (), "m.updated_at DESC", 120)), "explore")
        known = set(prof["actors"].keys())
        strangers = [x for x in pool if not (set(x.get("actors") or []) & known)]

        def explore_text(x: dict) -> str:
            ac = x.get("actors") or []
            name = ac[0] if ac else ""
            sc = _score_text(x)
            # 没写演员的片子说「没看过的 演员」很怪，换个说法
            if name:
                return f"没看过的 {name} · {sc}" if sc else f"没看过的 {name}"
            return f"没碰过的片子 · {sc}" if sc else "没碰过的片子"

        return take(strangers, "explore", explore_text, need)

    pickers: dict = {"taste": p_taste, "similar": p_similar, "series": p_series,
                     "studio": p_studio, "era": p_era, "top": p_top,
                     "fresh": p_fresh, "explore": p_explore}

    for kind in DAILY_ORDER:
        need = int(quota.get(kind, 0))
        if need <= 0 or kind not in pickers:
            continue
        try:
            if kind == "top":
                # top 是唯一「理由可能说不出口」的档（库里没评分时）：
                # 拿不满的部分转给探索，别用「你还没看」硬填。
                got = p_top(need, strict=True)
                if got < need:
                    p_explore(need - got)
                continue
            pickers[kind](need)
        except Exception as exc:      # noqa: BLE001
            log(f"WARN 每日推荐 {kind} 桶失败（跳过）: {exc}")

    # 没凑够（新用户 / 库小 / 某桶空）：先用「库内高分」补（画像空时它就是最合理的推荐），
    # 还不够才用新入库 —— 兜底也带理由，不硬凑。
    if len(out) < limit:
        try:
            p_top(limit - len(out))
        except Exception as exc:      # noqa: BLE001
            log(f"WARN 每日推荐 top 兜底失败: {exc}")
    if len(out) < limit:
        rows = rot(_by_score(_daily_pool("m.updated_at >= ?",
                                         ((d - timedelta(days=90)).isoformat(),),
                                         "m.updated_at DESC", 80)), "fallback")
        for x in rows:
            if len(out) >= limit:
                break
            mid = x.get("id")
            if mid in used or mid in seen or not x.get("poster"):
                continue
            used.add(mid)
            x["reason_kind"] = "fresh"
            x["reason_text"] = f"新入库 {(today_ord - _ord_of(x.get('updated_at')))} 天"
            out.append(x)

    rng.shuffle(out)
    return attach_marks_auto(attach_progress(out))

def _ord_of(stamp: str | None) -> int:
    """`YYYY-MM-DD...` → 日期序号；解析不了就当今天（差 0 天）。"""
    if not stamp:
        return today_local().toordinal()
    try:
        return date.fromisoformat(str(stamp)[:10]).toordinal()
    except ValueError:
        return today_local().toordinal()


def build_banners(limit: int = 12, fresh: bool = False, day: date | None = None) -> list[dict]:
    """每日推荐横幅：`build_daily` 挑人 + 理由，这里只负责「有没有合格横图」。

    **顺序：先推荐（带理由）→ 再判横图**（2026-11-15 用户指出）。
    老实现是先划横图池再挑片，等于每天只在 60 部里转，理由也只能事后凑。

    横图是展示要求：命中 `banner_ok` 的带上 fanart 直接用；没命中的排后面兜底，
    并丢进后台按 id 补探测（`_kick_banner_warm_ids`），下一轮就命中。

    `day` 只给排查用（`/api/user/banners?day=YYYY-MM-DD`），缺省 = 北京时间今天。
    """
    cand: list[dict] = build_daily(max(limit, 12), day=day)
    with user_db() as conn:
        have: dict = {
            r["metadata_id"]: (r["url"], r["ratio"])
            for r in conn.execute("SELECT metadata_id, url, ratio FROM banner_ok WHERE url <> ''")
        }
    with_fan: list[dict] = []
    plain: list[dict] = []
    for x in cand:
        hit = have.get(x["id"])
        if hit is None:
            plain.append(x)
            continue
        x["fanart"] = hit[0]
        x["fanart_ratio"] = hit[1]
        with_fan.append(x)
    picked: list[dict] = list(with_fan[:limit])
    if fresh:
        # 下拉刷新：在这批有横图的候选里换一下顺序（不改推荐集合与理由）
        random.shuffle(picked)
    if len(picked) < limit:
        picked += plain[:limit - len(picked)]
    if plain:
        _kick_banner_warm_ids([x["id"] for x in plain[:24]])
    return picked

def cached_home(fresh: bool = False, hero_pool: str = "all",
                hero_spec: dict | None = None) -> dict:
    """库行 / 推荐 / hero 缓存 5 分钟；继续观看每次现算。

    `fresh=True`（客户端下拉刷新）**绕开这份缓存**重算一次，并把横幅重新洗一遍 ——
    「下拉只转圈不换内容」就是因为它拿的还是缓存里那份一模一样的 JSON。
    推荐位仍按当天种子（用户定的：推荐一天固定），只有横幅是每次下拉换一批。

    `hero_pool`（2026-11-14）：大图候选池。**必须进缓存 key** —— 否则用户切换池子后
    5 分钟内看到的还是上一个池的内容，会被当成"开关没生效"。
    """
    key = today_local().isoformat() + "|" + (hero_pool or "all") + "|" + \
        (json.dumps(hero_spec, sort_keys=True, ensure_ascii=False) if hero_spec else "")
    hit = _home_cache.get(key)
    now = time.time()
    if not fresh and hit and now - hit[0] < HOME_TTL:
        base = dict(hit[1])
    else:
        data = build_home(fresh=fresh, hero_pool=hero_pool, hero_spec=hero_spec)
        # 缓存里不存 hero（它每次都要现算，见函数末尾）；continue 本来就每次现算。
        base = {k: v for k, v in data.items() if k not in ("continue", "hero")}
        if fresh:
            # 强制刷新不写缓存：免得把「随机挑的一批」固化成接下来 5 分钟的首页
            _home_cache.clear()
        else:
            _home_cache.clear()
            _home_cache[key] = (now, base)
        base = dict(base)
    base["continue"] = build_continue()
    # 诊断字段（2026-11-15）：「服务器认为今天是哪天」。每日推荐按这个日期翻页，
    # 以后再有人问「为什么昨天和今天一样」，看一眼这个字段就知道是不是时区/跨天问题。
    base["home_date"] = today_local().isoformat()
    # ★ hero 不进缓存（2026-11-14 12:00 用户定）★
    # 「每次进 App 首页大图都要换新」，而这份缓存是 5 分钟的 —— 若 hero 跟着缓存走，
    # 用户连续切几次首页（甚至重开 App）看到的还是同一批。
    # 所以这里丢掉缓存里的 hero，每次现算一份（只查 160 行 + 取 6 部，开销可忽略）。
    # 每日推荐仍按当日种子固定 —— 那是用户要的语义，两者从这一版起彻底分开。
    base.pop("hero", None)
    try:
        base["hero"] = build_hero(6, fresh=True,
                                  exclude={b.get("id") for b in (base.get("banners") or [])},
                                  pool=hero_pool, spec=hero_spec)
    except Exception as exc:      # noqa: BLE001
        # 现算失败就把缓存里那份放回去（有总比空着强），但要让日志说明白
        log(f"WARN 首页 hero 现算失败，退回缓存: {exc}")
        if hit:
            base["hero"] = (hit[1] or {}).get("hero") or []
        else:
            base["hero"] = []
    base["generated_at"] = now_iso()
    return base

BACKUP_DIR = os.path.join(DATA_DIR, "backup")

BACKUP_KEEP = 3

def backup_snapshot() -> dict:
    """把五张与导入相关的表原样拍下来（含 collection id，回滚后清单归属不变）。"""
    with user_db() as conn:
        snap = {
            "taken_at": now_iso(),
            "version": VERSION,
            "favorites": [list(r) for r in conn.execute(
                "SELECT metadata_id, created_at FROM favorites")],
            "history": [list(r) for r in conn.execute(
                "SELECT metadata_id, position, duration, played_at, finished FROM history")],
            "user_ratings": [list(r) for r in conn.execute(
                "SELECT metadata_id, score, updated_at FROM user_ratings")],
            "watch_later": [list(r) for r in conn.execute(
                "SELECT metadata_id, created_at FROM watch_later")],
            "collections": [list(r) for r in conn.execute(
                "SELECT id, name, created_at FROM collections")],
            "collection_items": [list(r) for r in conn.execute(
                "SELECT collection_id, metadata_id, created_at FROM collection_items")],
        }
    return snap

def backup_write(snap: dict) -> str:
    """落盘 + 只留最近 BACKUP_KEEP 份。返回文件路径。"""
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
    except OSError as exc:
        log(f"WARN 建备份目录失败 {BACKUP_DIR}: {exc}")
        return ""
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(BACKUP_DIR, f"import-{stamp}.json")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(snap, fh, ensure_ascii=False)
    except OSError as exc:
        log(f"WARN 写备份失败 {path}: {exc}")
        return ""
    try:
        files = sorted((f for f in os.listdir(BACKUP_DIR) if f.startswith("import-")), reverse=True)
        for old in files[BACKUP_KEEP:]:
            os.remove(os.path.join(BACKUP_DIR, old))
    except OSError as exc:
        log(f"WARN 清理旧备份失败: {exc}")
    return path

def backup_latest() -> tuple[str, dict | None]:
    """最近一份导入前快照（文件名, 内容）。"""
    try:
        files = sorted((f for f in os.listdir(BACKUP_DIR) if f.startswith("import-")), reverse=True)
    except OSError:
        return "", None
    if not files:
        return "", None
    path = os.path.join(BACKUP_DIR, files[0])
    try:
        with open(path, encoding="utf-8") as fh:
            return files[0], json.load(fh)
    except (OSError, ValueError):
        return files[0], None

def backup_restore(snap: dict) -> dict:
    """把快照整表灌回去（先清空这五张表）。"""
    counts = {}
    with user_db() as conn:
        for t in ("favorites", "history", "user_ratings", "watch_later"):
            conn.execute(f"DELETE FROM {t}")
        conn.execute("DELETE FROM collection_items")
        conn.execute("DELETE FROM collections")
        conn.executemany(
            "INSERT OR REPLACE INTO favorites(metadata_id, created_at) VALUES(?,?)",
            [tuple(r) for r in (snap.get("favorites") or [])])
        counts["favorites"] = len(snap.get("favorites") or [])
        conn.executemany(
            "INSERT OR REPLACE INTO history(metadata_id, position, duration, played_at, finished) "
            "VALUES(?,?,?,?,?)",
            [tuple(r) for r in (snap.get("history") or [])])
        counts["history"] = len(snap.get("history") or [])
        conn.executemany(
            "INSERT OR REPLACE INTO user_ratings(metadata_id, score, updated_at) VALUES(?,?,?)",
            [tuple(r) for r in (snap.get("user_ratings") or [])])
        counts["ratings"] = len(snap.get("user_ratings") or [])
        conn.executemany(
            "INSERT OR REPLACE INTO watch_later(metadata_id, created_at) VALUES(?,?)",
            [tuple(r) for r in (snap.get("watch_later") or [])])
        counts["watch_later"] = len(snap.get("watch_later") or [])
        conn.executemany(
            "INSERT OR REPLACE INTO collections(id, name, created_at) VALUES(?,?,?)",
            [tuple(r) for r in (snap.get("collections") or [])])
        counts["collections"] = len(snap.get("collections") or [])
        conn.executemany(
            "INSERT OR REPLACE INTO collection_items(collection_id, metadata_id, created_at) "
            "VALUES(?,?,?)",
            [tuple(r) for r in (snap.get("collection_items") or [])])
        counts["collection_items"] = len(snap.get("collection_items") or [])
    return counts

def invalidate_item_caches() -> None:
    """改了某部片（字段 / 封面）之后调用：首页聚合与横幅池都要立刻重算。

    以前没这一步，表现是「详情页封面换了，回首页还是旧图，等 5 分钟才好」。
    2026-11-15 起横幅不再有「当日缓存」（候选每次按推荐现挑、横图命中 banner_ok），
    所以这里只需要丢掉首页聚合缓存 + 横幅候选的补图在飞集合。
    """
    _home_cache.clear()
    with _banner_warm_lock:
        _banner_id_warming.clear()

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
        "Referer": "https://www.javbus.com/",
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
    # 写完顺手检查一次上限（storage 内部有 5 分钟节流，不会每张图都扫目录）。
    # 延迟 import：storage 里要用本模块的 PLAY_DISK，顶层互相 import 会成环。
    try:
        from core import storage as _storage
        _storage.enforce_img_cap()
    except Exception as exc:          # noqa: BLE001
        log(f"WARN imgcache 淘汰检查失败（不影响取图）: {exc}")
    return data, ctype

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

    def note(self, nbytes: int) -> None:
        """外部**直接落盘**（不走 `put`）时补记用量。

        本地源那条路为了「一次读 8 块」是手写 open/os.replace 的，绕过了 `put()`；
        不补记的话 `_used` 一直是 0，`trim()` 永远不触发 —— 本地缓存就会无限涨。
        """
        if self.budget <= 0 or nbytes <= 0:
            return
        with self._lock:
            self._used += nbytes
            self._writes += 1
            need_trim = self._writes % 64 == 0 or self._used > self.budget
        if need_trim:
            self.trim()

    def trim(self) -> None:
        """按 mtime 从旧到新删到预算内。

        首块/末块（MP4 的 moov 常在尾部、头块决定首帧）**只保护「最近看的那几部」**：
        原来是无条件保护每个目录的首末块，结果短片段目录里每一块都是首末块，
        一块也删不掉 —— 实测预算 4GB、磁盘 5.5GB 还在涨（2026-11-15 用户要求按源分预算后一并修）。

        保护额度取预算的 **1/4**：本地源预算只有 128MB 时大约保护 8MB（≈ 1 部），
        网盘源 4GB 时保护 1GB（≈ 120 部），刚好覆盖「最近在看的」。
        """
        with self._lock:
            if not self._scanned:
                self._scanned = True
                self._used = self._measure()
            over = self._used - self.budget
            if over <= 0:
                return
            dirs: dict = {}          # base -> {"first": (mtime,size,path), "last": ..., "best": mtime}
            walked: list = []
            for base, _sub, files in os.walk(self.root):
                for name in files:
                    if not name.endswith(".bin"):
                        continue
                    p = os.path.join(base, name)
                    try:
                        st = os.stat(p)
                        blk = int(name[:8])
                    except (OSError, ValueError):
                        continue
                    walked.append((st.st_mtime, st.st_size, p, base, blk))
                    ent = dirs.get(base)
                    if ent is None:
                        ent = {"first": None, "last": None, "best": st.st_mtime}
                        dirs[base] = ent
                    if st.st_mtime > ent["best"]:
                        ent["best"] = st.st_mtime
                    if blk == 0:
                        ent["first"] = (st.st_mtime, st.st_size, p)
                    cur = ent["last"]
                    if cur is None or blk > cur[3]:
                        ent["last"] = (st.st_mtime, st.st_size, p, blk)
            # 按「最近看过」排序，只给前几部留首末块，且总保护量不超过预算 1/4
            prot_set: set = set()
            prot_bytes = 0
            cap = max(0, self.budget // 4)
            for base in sorted(dirs, key=lambda b: dirs[b]["best"], reverse=True):
                if prot_bytes >= cap:
                    break
                ent = dirs[base]
                for slot in ("first", "last"):
                    hit = ent.get(slot)
                    if hit is None:
                        continue
                    prot_set.add(hit[2])
                    prot_bytes += hit[1]
            walked.sort()
            removed = 0
            for _mt, size, p, base, blk in walked:
                if over <= 0 or removed >= 2000:
                    break
                if p in prot_set:
                    continue
                try:
                    os.remove(p)
                    over -= size
                    removed += 1
                    self._used = max(0, self._used - size)
                except OSError:
                    continue
            # 目录空了就删掉，否则几千个空 hash 目录也算噪声
            for base in dirs:
                try:
                    if not os.listdir(base):
                        os.rmdir(base)
                except OSError:
                    pass

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


def _storage_play_budget_mb(default: int = 4096) -> int:
    """「播放缓存」的用户上限（MB），读 `data/storage.json` 里 `play` 那一项。

    为什么不 import `core.storage`：那个模块是并行会话在写的空间管理模块，
    这里只需要一个数字。直接读它落的 json，既拿到同一份事实，
    又不会把两个模块绑死（也不会互相 import 循环）。读不到就用环境变量/默认值。
    """
    try:
        with open(os.path.join(DATA_DIR, "storage.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        if isinstance(raw, dict):
            val = raw.get("play")
            if isinstance(val, dict):
                val = val.get("mb")
            if val is not None:
                return max(0, int(val))
    except (OSError, ValueError, TypeError):
        pass
    return int(os.environ.get("AMANE_PLAY_DISK_MB", str(default)))


# 网盘/上游源：**缓存是真的能提速**（重开同一部片省 8~27 秒拉索引），预算可由用户在
# 「空间管理 → 播放缓存」里调（那个页面直接改 `PLAY_DISK.budget`，所以这里的名字不能变）。
PLAY_DISK = PlayDiskCache(os.path.join(DATA_DIR, "play-cache", "v4"),
                          _storage_play_budget_mb())

# 本地盘源：`/media` 就在 NAS 上，重读索引只要几十毫秒，缓存收益很小
# （用户 2026-11-15 01:31：「本地源的预算尽可能小就好」）。
# 仍然留一点：机械盘池随机 seek 有寻道成本，拖进度条反复跳时能省几次往返。
# 放在 `v4/_local` 而不是另起一个 v5 —— 空间管理模块把 `play-cache/v4` 当「当前版本」、
# 其它顶层目录会当成可清理的旧版本残留，塞进 v4 内部它才不会被误判。
PLAY_DISK_LOCAL = PlayDiskCache(
    os.path.join(DATA_DIR, "play-cache", "v4", "_local"),
    int(os.environ.get("AMANE_PLAY_LOCAL_MB", "128")))

def _bootstrap_name_pinyin() -> None:
    """启动后台把拼音索引建起来（空表才建）。

    为什么放后台：建表要读 amane 主库的 tags/series/actors 三张全表再逐字算读音，
    几千到几万行；放主线程会让服务晚几秒才能应答。表空着的时候拼音检索只是
    「暂时没有命中」，其余行为不受影响，所以慢一点没关系。
    """
    def run() -> None:
        try:
            if name_pinyin_count() > 0 and _stored_name_sig():
                # 表里有数据、也有上次重建时的源库签名：交给检索时的自愈钩子，
                # 启动不再白做一次全量重建。
                return
            # 空表（首次装）或老版本升级上来没签名：无条件建一次，把签名补上。
            # 不这样做的话，老库会一直「有索引但没签名 → 自愈判不出落后」。
            build_name_pinyin()
        except Exception as exc:  # noqa: BLE001
            log(f"WARN 拼音索引初始化失败: {exc}")

    threading.Thread(target=run, name="name-pinyin-init", daemon=True).start()
