"""图片代理与尺寸探测（从 server.py 拆出）。

两块东西，因为天然绑在一起：

1. **外链图片白名单 + 代理**（`public_image` / `_img_proxy` / `host_allowed`）
   —— 海报/剧照很多在外站，客户端直连会被防盗链或跨域挡住。这里只做「白名单内的
   转发 + 可选打码 token」，**不是**通用 URL 代理，所以主机必须白名单。

2. **图片尺寸探测**（`image_dims` / `_dims_get` / `_dims_put` / `_image_size`）
   —— 上游不总给尺寸，排版要宽高比。先读缓存（user.db 的 img_dims 表），命中就返回；
   没命中就发 Range 请求只拉头部几 KB 去解析，不整张下载，然后写回缓存。

依赖：config（token/缓存目录）、db（读写尺寸缓存）、log、util（时间戳）。
"""
from __future__ import annotations

import base64
import os
import sqlite3
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request

from core.config import IMAGE_CACHE, _read_secret
from core.db import user_db
from core.log import log
from core.upstream import _opener
from core.util import now_iso

# 打码 token（客户端把 token 拼在 URL 上，服务端转成请求头）
IMAGE_TOKEN = _read_secret("IMAGE_TOKEN")

# 外链图片主机白名单（防 SSRF）。默认只放通用 CDN 后缀，
# 具体海报站点由部署者按自己的刮削来源追加：
#   IMG_HOST_ALLOW_EXTRA=poster-cdn.example,image-host.example
_IMG_HOST_BASE = ["githubusercontent.com", "jsdelivr.net", "images", "cdn", "img", "static"]
IMG_HOST_ALLOW = tuple(_IMG_HOST_BASE + [
    h.strip() for h in os.environ.get("IMG_HOST_ALLOW_EXTRA", "").split(",") if h.strip()
])

# 尺寸探测只读这么多字节（够解析 PNG/GIF/JPEG 头），别整张下载
IMG_PROBE_BYTES = 64 * 1024

# 主机白名单判定缓存：同一个 host 重复出现时不必每次重新解析
_host_ok_cache: dict = {}


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
