#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""amane-user 字幕模块（纯标准库）。

设计目标：**所有字幕来源统一收敛成一个 subtitle_id**，客户端只需
    SubtitleTrack.uri(<base>/api/user/subtitle/<id>?token=..., "", lang, "external")
不必知道字幕来自哪里。当前支持的来源：

  * local   视频同目录的外挂字幕（只读扫描，命名口径对齐上游 amane）
  * import  手机文件选择器选中的字幕，上传后落到服务端缓存
  * url     手动填写的字幕 URL，由服务端抓取后落到缓存

在线字幕搜索**暂不启用**：subtitle_providers/registry.py 的注册表为空，
本模块只预留接口，不实现任何第三方协议、不接受任何第三方凭据。

约束：
  * 只读媒体卷，绝不写 amane 的目录；
  * 只 os.scandir(视频所在目录)，**绝不递归**（CD2 FUSE 上 walk 会卡死）；
  * 任何缓存内容都经过路径白名单校验，防目录穿越；
  * 抓取外部 URL 有超时与体积上限。
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from urllib.parse import urlparse
from urllib.request import Request, build_opener, ProxyHandler

SUB_EXTS = (".srt", ".ass", ".ssa", ".vtt", ".sub")
MAX_SUB_BYTES = 2 * 1024 * 1024
FETCH_TIMEOUT = 12
_opener = build_opener(ProxyHandler({}))


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _score(text: str) -> float:
    """给解码结果打分，用来区分中文 GBK 与日文 Shift-JIS。

    Shift-JIS 会把 GBK 中文字节解成大量半角片假名（U+FF61..U+FF9F），
    这是很可靠的「解错了」信号；正确的日文字幕则含平假名/片假名。
    """
    if not text:
        return -99.0
    score = 0
    for ch in text:
        o = ord(ch)
        if 0x3040 <= o <= 0x30FF:          # 平假名 / 片假名
            score += 3
        elif 0x4E00 <= o <= 0x9FFF:        # CJK 统一汉字
            score += 1
        elif 0xFF61 <= o <= 0xFF9F:        # 半角片假名：乱码标志
            score -= 6
        elif o == 0xFFFD or 0xE000 <= o <= 0xF8FF:
            score -= 8
        elif o < 0x20 and ch not in "\r\n\t":
            score -= 8
    return score / len(text)


def _decode(raw: bytes) -> str:
    """常见字幕编码 → str。UTF-8 优先；否则对候选编码打分取最优。"""
    try:
        return raw.decode("utf-8-sig")
    except (UnicodeDecodeError, LookupError):
        pass
    best, best_score = "", -100.0
    for enc in ("shift_jis", "gb18030", "big5"):
        try:
            text = raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
        s = _score(text)
        if s > best_score:
            best, best_score = text, s
    return best if best else raw.decode("utf-8", errors="replace")


def _to_vtt(text: str, ext: str) -> str:
    """SRT → WebVTT（mpv-arkts 的远程字幕示例用的是 WebVTT，做一层兼容兜底）。
    ASS/SSA 保留原样，避免丢特效。"""
    if ext not in (".srt", ".sub"):
        return text
    body = text.replace("\r\n", "\n").replace("\r", "\n")
    body = re.sub(r"(?m)^\s*\d+\s*\n(?=\d{2}:\d{2}:\d{2}[,.])", "", body)
    body = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", body)
    return "WEBVTT\n\n" + body.lstrip("\n")


def _safe_ext(name: str) -> str:
    ext = os.path.splitext(name)[1].lower()
    return ext if ext in SUB_EXTS else ".srt"


def _lang_of(name: str) -> str:
    """从文件名后缀猜语言标签，仅用于 UI 展示。"""
    low = name.lower()
    for tag, lang in ((".zh", "chi"), (".chs", "chi"), (".sc", "chi"), (".cn", "chi"),
                      (".cht", "chi"), (".tc", "chi"), (".jp", "jpn"), (".ja", "jpn"),
                      (".en", "eng"), (".ko", "kor")):
        if tag in low:
            return lang
    return ""


class SubtitleStore:
    """字幕缓存 + 选择记录，落在 DATA_DIR（user.db 同目录）。"""

    def __init__(self, data_dir: str, amane_db: str, media_path_map: str):
        self.root = os.environ.get("SUBTITLE_CACHE") or os.path.join(data_dir, "subtitles")
        os.makedirs(self.root, exist_ok=True)
        self.user_db = os.path.join(data_dir, "user.db")
        self.amane_db = amane_db
        self.path_map = self._parse_map(media_path_map)
        self._init_db()

    @staticmethod
    def _parse_map(raw: str) -> list[tuple[str, str]]:
        """'/media2=/mnt/media2,/media=/mnt/media' → 按前缀长度降序（最长前缀匹配）。"""
        pairs: list[tuple[str, str]] = []
        for item in raw.split(","):
            if "=" not in item:
                continue
            src, dst = item.split("=", 1)
            src, dst = src.strip().rstrip("/"), dst.strip().rstrip("/")
            if src.startswith("/") and dst:
                pairs.append((src, dst))
        return sorted(pairs, key=lambda p: len(p[0]), reverse=True)

    def _init_db(self) -> None:
        with sqlite3.connect(self.user_db, timeout=10) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS subtitle_choice ("
                " item_id INTEGER PRIMARY KEY,"
                " subtitle_id TEXT NOT NULL,"
                " updated_at TEXT NOT NULL)")
            conn.commit()

    def map_path(self, container_path: str) -> str:
        """amane 容器内路径 → 目标机上可读路径。纯 Python 直跑、没有映射时原样返回。"""
        if not self.path_map:
            return container_path
        for prefix, target in self.path_map:
            if container_path == prefix or container_path.startswith(prefix + "/"):
                return target + container_path[len(prefix):]
        return ""

    def _index_path(self) -> str:
        return os.path.join(self.root, "index.json")

    def _index(self) -> dict:
        try:
            with open(self._index_path(), encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    def _save_index(self, idx: dict) -> None:
        tmp = self._index_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(idx, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, self._index_path())

    def put(self, name: str, raw: bytes, source: str) -> dict:
        if len(raw) > MAX_SUB_BYTES:
            raise ValueError("字幕文件超过 2 MiB")
        ext = _safe_ext(name)
        text = _decode(raw)
        sid = hashlib.sha256(raw).hexdigest()[:24]
        idx = self._index()
        idx[sid] = {"name": name, "ext": ext, "source": source,
                    "lang": _lang_of(name), "size": len(raw), "created_at": _now()}
        with open(os.path.join(self.root, sid + ext), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        self._save_index(idx)
        return {"id": sid, **idx[sid]}

    def get(self, sid: str, as_vtt: bool = False) -> tuple[str, str] | None:
        if not re.fullmatch(r"[0-9a-f]{24}", sid or ""):
            return None
        idx = self._index()
        meta = idx.get(sid)
        if not meta:
            return None
        path = os.path.join(self.root, sid + meta["ext"])
        if not os.path.isfile(path):
            return None
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if as_vtt:
            return _to_vtt(text, meta["ext"]), "text/vtt; charset=utf-8"
        ctype = "text/vtt" if meta["ext"] == ".vtt" else (
            "text/x-ssa" if meta["ext"] in (".ass", ".ssa") else "text/plain")
        return text, ctype + "; charset=utf-8"

    def describe(self, sid: str) -> dict | None:
        meta = self._index().get(sid)
        return {"id": sid, **meta} if meta else None

    def list_all(self) -> list[dict]:
        return [{"id": k, **v} for k, v in self._index().items()]

    def choice(self, item_id: int) -> dict | None:
        with sqlite3.connect(self.user_db, timeout=10) as conn:
            row = conn.execute(
                "SELECT subtitle_id, updated_at FROM subtitle_choice WHERE item_id = ?",
                (item_id,)).fetchone()
        if not row:
            return None
        meta = self.describe(row[0])
        return {"item_id": item_id, "subtitle_id": row[0],
                "updated_at": row[1], "detail": meta}

    def set_choice(self, item_id: int, sid: str) -> None:
        with sqlite3.connect(self.user_db, timeout=10) as conn:
            conn.execute(
                "INSERT INTO subtitle_choice(item_id, subtitle_id, updated_at) VALUES(?,?,?) "
                "ON CONFLICT(item_id) DO UPDATE SET subtitle_id=excluded.subtitle_id, "
                "updated_at=excluded.updated_at", (item_id, sid, _now()))
            conn.commit()

    def local_candidates(self, item_id: int) -> list[dict]:
        """列出视频同目录的外挂字幕。只 scandir 同目录，不递归。"""
        with sqlite3.connect(f"file:{self.amane_db}?mode=ro", uri=True, timeout=10) as conn:
            row = conn.execute("SELECT path FROM media_files WHERE metadata_id = ? ORDER BY id LIMIT 1", (item_id,)).fetchone()
        if not row or not row[0]:
            return []
        real = self.map_path(row[0])
        if not real or not os.path.isfile(real):
            return []
        folder, stem = os.path.split(real)
        base = os.path.splitext(stem)[0]
        out: list[dict] = []
        try:
            with os.scandir(folder) as it:
                entries = [e for e in it if e.is_file()]
        except OSError:
            return []
        for entry in entries:
            ext = os.path.splitext(entry.name)[1].lower()
            if ext not in SUB_EXTS:
                continue
            name_stem = os.path.splitext(entry.name)[0]
            if name_stem != base and not name_stem.startswith(base + "."):
                continue
            try:
                if entry.stat().st_size > MAX_SUB_BYTES:
                    continue
            except OSError:
                continue
            out.append({"name": entry.name, "size": entry.stat().st_size,
                        "lang": _lang_of(entry.name), "path": entry.path})
        return sorted(out, key=lambda x: x["name"])

    def load_local(self, item_id: int, name: str) -> dict:
        """把同目录字幕读进缓存，返回统一的 subtitle_id。"""
        for cand in self.local_candidates(item_id):
            if cand["name"] == name:
                with open(cand["path"], "rb") as fh:
                    raw = fh.read()
                return self.put(name, raw, "local")
        raise ValueError("字幕不存在或不属于该视频")


def install(routes: list, amane_db: str, data_dir: str, media_path_map: str) -> None:
    """把字幕路由挂到 amane-user 的 ROUTES（不修改 Handler 类）。"""
    store = SubtitleStore(data_dir, amane_db, media_path_map)

    def ok(self, payload: dict) -> None:
        self._json(payload)

    def fail(self, status: int, msg: str) -> None:
        self._error(status, msg)

    def subtitles_list(self, query: dict) -> None:
        fid = int((query.get("item_id") or ["0"])[0])
        local = store.local_candidates(fid) if fid else []
        for item in local:
            item.pop("path", None)  # 绝不把服务器本地路径发给客户端
        ok(self, {"local": local, "cached": store.list_all(),
                  "choice": store.choice(fid) if fid else None,
                  "providers": []})

    def subtitles_local(self, query: dict) -> None:
        fid = int((query.get("item_id") or ["0"])[0])
        name = (query.get("name") or [""])[0]
        try:
            ok(self, store.load_local(fid, name))
        except (ValueError, OSError) as exc:
            fail(self, 400, str(exc))

    def subtitles_import(self, query: dict) -> None:
        body = self._body()
        name = str(body.get("filename") or "subtitle.srt")
        raw_b64 = str(body.get("content") or "")
        try:
            raw = base64.b64decode(raw_b64, validate=True)
        except (ValueError, Exception) as exc:  # noqa: BLE001
            fail(self, 400, f"base64 解码失败: {exc}")
            return
        if not raw:
            fail(self, 400, "空文件")
            return
        try:
            ok(self, store.put(os.path.basename(name), raw, "import"))
        except ValueError as exc:
            fail(self, 400, str(exc))

    def subtitles_url(self, query: dict) -> None:
        body = self._body()
        url = str(body.get("url") or "")
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            fail(self, 400, "只接受 http(s) URL")
            return
        try:
            req = Request(url, headers={"User-Agent": "Amane-Harmony/2.1.0"})
            with _opener.open(req, timeout=FETCH_TIMEOUT) as resp:
                raw = resp.read(MAX_SUB_BYTES + 1)
        except Exception as exc:  # noqa: BLE001
            fail(self, 502, f"抓取失败: {exc}")
            return
        if len(raw) > MAX_SUB_BYTES:
            fail(self, 413, "字幕文件超过 2 MiB")
            return
        name = os.path.basename(parsed.path) or "subtitle.srt"
        try:
            ok(self, store.put(name, raw, "url"))
        except ValueError as exc:
            fail(self, 400, str(exc))

    def subtitle_stream(self, query: dict, sid: str) -> None:
        as_vtt = (query.get("format") or [""])[0] == "vtt"
        got = store.get(sid, as_vtt=as_vtt)
        if got is None:
            fail(self, 404, "字幕不存在")
            return
        text, ctype = got
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def choice_get(self, query: dict) -> None:
        fid = int((query.get("item_id") or ["0"])[0])
        ok(self, store.choice(fid) or {})

    def choice_put(self, query: dict) -> None:
        body = self._body()
        fid = int(body.get("item_id") or 0)
        sid = str(body.get("subtitle_id") or "")
        if not fid or not store.describe(sid):
            fail(self, 400, "item_id / subtitle_id 无效")
            return
        store.set_choice(fid, sid)
        ok(self, {"ok": True})

    def providers_list(self, query: dict) -> None:
        # 预留接口：注册表为空，意味着不实现也不启用任何在线字幕源。
        from subtitle_providers.registry import available
        ok(self, {"providers": available(),
                  "note": "在线字幕源为预留扩展点，当前未启用，也不接受任何第三方凭据。"})

    def add(method: str, pattern: str, fn) -> None:
        routes.append((method, re.compile("^" + pattern + "$"), fn))

    add("GET", r"/api/user/subtitles", subtitles_list)
    add("GET", r"/api/user/subtitles/local", subtitles_local)
    add("POST", r"/api/user/subtitles/import", subtitles_import)
    add("POST", r"/api/user/subtitles/url", subtitles_url)
    add("GET", r"/api/user/subtitle/([0-9a-f]{24})", subtitle_stream)
    add("HEAD", r"/api/user/subtitle/([0-9a-f]{24})", subtitle_stream)
    add("GET", r"/api/user/subtitles/choice", choice_get)
    add("PUT", r"/api/user/subtitles/choice", choice_put)
    add("GET", r"/api/user/subtitles/providers", providers_list)
