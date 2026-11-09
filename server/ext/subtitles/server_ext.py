#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：外挂字幕（scope=public）。

所有字幕来源统一收敛成一个 `subtitle_id`，客户端只需：
    SubtitleTrack.uri(<base>/api/user/subtitle/<id>?token=..., "", lang, "external")

来源：
  * local   视频同目录的外挂字幕（只读扫描，命名口径对齐上游 amane）
  * import  手机文件选择器选中的字幕，上传后落到服务端缓存
  * url     手动填写的字幕 URL，由服务端抓取后落到缓存

在线字幕搜索**不启用**：只预留接口，不实现第三方协议、不接受第三方凭据。

约束：
  * 只读媒体卷，绝不写 amane 的目录；
  * 只 os.scandir(视频所在目录)，**绝不递归**（CD2 FUSE 上 walk 会卡死）；
  * 任何缓存内容都经过扩展名白名单校验，防目录穿越；
  * 抓取外部 URL 有超时与体积上限。

不 import server.py：依赖由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
import re
import time
from datetime import datetime, timezone
from urllib.parse import urlparse
from urllib.request import Request, build_opener, ProxyHandler

A = None       # type: ignore[assignment]  # ExtensionHost 注入的 api
STORE = None   # type: ignore[assignment]  # 模块级单例，供 handler 使用

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


_SRT_TS = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})[,.:](\d{1,3})")
_SRT_CUE = re.compile(
    r"^\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})")
_ASS_TS = re.compile(r"^(\d+):(\d{2}):(\d{2})[.:](\d{2})$")
_ASS_TAG = re.compile(r"\{[^}]*\}")


def _vtt_stamp(text: str) -> str:
    """任意 SRT/ASS 时间戳 → WebVTT 的 HH:MM:SS.mmm。"""
    m = _SRT_TS.search(text.strip())
    if not m:
        return ""
    h, mi, s, ms = m.group(1), m.group(2), m.group(3), m.group(4).ljust(3, "0")[:3]
    return f"{int(h):02d}:{mi}:{s}.{ms}"


def _ass_stamp(raw: str) -> str:
    m = _ASS_TS.match(raw.strip())
    if not m:
        return _vtt_stamp(raw)
    h, mi, s, cs = m.groups()
    return f"{int(h):02d}:{mi}:{s}.{int(cs) * 10:03d}"


def _ass_to_vtt(text: str) -> str:
    """ASS/SSA → WebVTT。

    原来把 ASS 原文原样返回、却把 Content-Type 标成 text/vtt，播放器按
    WebVTT 解析 ASS 一个 cue 都认不出来，于是整段文字堆在第 0 秒。
    这里按 [Events] 的 Format 行取字段位置，只保留时间轴与文本（丢弃特效标签）。
    """
    lines = text.splitlines()
    order: list[str] = []
    cues: list[str] = []
    for line in lines:
        head = line.strip()
        if head.lower().startswith("format:") and not order:
            order = [x.strip().lower() for x in head.split(":", 1)[1].split(",")]
            continue
        if not head.lower().startswith("dialogue:"):
            continue
        body = head.split(":", 1)[1]
        if not order:
            order = ["layer", "start", "end", "style", "name",
                     "marginl", "marginr", "marginv", "effect", "text"]
        parts = body.split(",", len(order) - 1)
        if len(parts) < len(order):
            continue
        row = dict(zip(order, parts))
        start = _ass_stamp(row.get("start", ""))
        end = _ass_stamp(row.get("end", ""))
        raw = _ASS_TAG.sub("", row.get("text", ""))
        raw = raw.replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ")
        raw = raw.strip()
        if not start or not end or not raw:
            continue
        cues.append(start + " --> " + end + "\n" + raw)
    return "WEBVTT\n\n" + "\n\n".join(cues) + "\n"


def _to_vtt(text: str, ext: str) -> str:
    r"""任意字幕 → WebVTT。

    关键点：WebVTT **每个 cue 之间必须有一个空行**。原来用
    ``^\s*\d+\s*\n`` 删序号，``\s*`` 会连前导空行一起吃掉，结果所有 cue
    连成一片，播放器把它们当成一个整块 —— 所有文字都堆在第 0 秒。
    改成逐行解析：序号行丢弃、时间轴行开新块、块与块之间固定空一行。
    """
    body = text.replace("\r\n", "\n").replace("\r", "\n")
    if ext in (".ass", ".ssa"):
        return _ass_to_vtt(body)

    cues: list[str] = []
    cur: list[str] | None = None
    for line in body.split("\n"):
        m = _SRT_CUE.match(line)
        if m:
            if cur:
                cues.append("\n".join(cur))
            cur = [_vtt_stamp(m.group(1)) + " --> " + _vtt_stamp(m.group(2))]
            continue
        if cur is None:
            continue
        stripped = line.strip()
        if not stripped:
            cues.append("\n".join(cur))
            cur = None
            continue
        if stripped.isdigit() and len(cur) == 1:
            continue
        cur.append(line.rstrip())
    if cur:
        cues.append("\n".join(cur))

    cleaned = [c for c in cues if c.strip()]
    return "WEBVTT\n\n" + "\n\n".join(cleaned) + "\n"


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
    """字幕缓存 + 选择记录。缓存落在 DATA_DIR，选择记录写入核心的 user.db。"""

    def __init__(self, api, media_path_map: str):
        self.A = api
        data_dir = os.environ.get("DATA_DIR", "/data")
        self.root = os.environ.get("SUBTITLE_CACHE") or os.path.join(data_dir, "subtitles")
        os.makedirs(self.root, exist_ok=True)
        self.path_map = self._parse_map(media_path_map)

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

    def map_path(self, container_path: str) -> str:
        """amane 容器内路径 → 目标机上可读路径。纯 Python 直跑、没有映射时原样返回。"""
        if not self.path_map:
            return container_path
        for prefix, target in self.path_map:
            if container_path == prefix or container_path.startswith(prefix + "/"):
                return target + container_path[len(prefix):]
        return ""

    # -- 缓存索引 ------------------------------------------------------- #

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
        meta = self._index().get(sid)
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

    def link(self, item_id: int, sid: str) -> None:
        """把一条字幕挂到某部片上（缓存本身按内容哈希全局去重）。"""
        if item_id <= 0 or not sid:
            return
        with self.A.user_db() as conn:
            conn.execute(
                "INSERT INTO subtitle_item(subtitle_id, item_id, created_at) VALUES(?,?,?) "
                "ON CONFLICT(subtitle_id, item_id) DO NOTHING",
                (sid, item_id, _now()))

    def list_for_item(self, item_id: int) -> list[dict]:
        """只返回挂在这部片上的字幕；没有关联就返回空，绝不回落到全局列表。"""
        if item_id <= 0:
            return []
        with self.A.user_db() as conn:
            rows = conn.execute(
                "SELECT subtitle_id FROM subtitle_item WHERE item_id = ? "
                "ORDER BY created_at DESC", (item_id,)).fetchall()
        idx = self._index()
        out: list[dict] = []
        for row in rows:
            sid = row["subtitle_id"] if isinstance(row, sqlite3.Row) else row[0]
            meta = idx.get(sid)
            if meta:
                out.append({"id": sid, **meta})
        return out

    # -- 选择记录（核心 user.db） ---------------------------------------- #

    def choice(self, item_id: int) -> dict | None:
        with self.A.user_db() as conn:
            row = conn.execute(
                "SELECT subtitle_id, updated_at FROM subtitle_choice WHERE item_id = ?",
                (item_id,)).fetchone()
        if not row:
            return None
        meta = self.describe(row[0])
        return {"item_id": item_id, "subtitle_id": row[0],
                "updated_at": row[1], "detail": meta}

    def set_choice(self, item_id: int, sid: str) -> None:
        with self.A.user_db() as conn:
            conn.execute(
                "INSERT INTO subtitle_choice(item_id, subtitle_id, updated_at) VALUES(?,?,?) "
                "ON CONFLICT(item_id) DO UPDATE SET subtitle_id=excluded.subtitle_id, "
                "updated_at=excluded.updated_at", (item_id, sid, _now()))

    # -- 同目录扫描 ------------------------------------------------------ #

    def local_candidates(self, item_id: int) -> tuple[list[dict], str]:
        """列出视频同目录的外挂字幕。只 scandir 同目录，不递归。

        返回 (候选列表, 说明)。候选为空时说明里给出原因（没配映射 / 目录不可读 /
        没有同名文件），客户端会直接显示，避免"面板空着但不知道为什么"。
        一个条目可能有多个文件（不同清晰度），逐个尝试并合并去重。
        """
        with self.A.amane_db() as conn:
            rows = conn.execute(
                "SELECT path FROM media_files WHERE metadata_id = ? ORDER BY id",
                (item_id,)).fetchall()
        paths = [row[0] for row in rows if row and row[0]]
        if not paths:
            return [], "amane.db 里没有该条目的文件记录"
        if not self.path_map:
            return [], ("未配置 MEDIA_PATH_MAP，服务读不到媒体目录；"
                        "例如 MEDIA_PATH_MAP=/media2=/mnt/media2")

        found: dict[str, dict] = {}
        checked: list[str] = []
        mapped = False
        for path in paths:
            real = self.map_path(path)
            if not real:
                checked.append(f"{path} 没有匹配的前缀")
                continue
            mapped = True
            if not os.path.isfile(real):
                # 只回显 amane 内路径，不把宿主机绝对路径发给客户端
                checked.append(f"{path} 映射后不存在")
                continue
            folder, stem = os.path.split(real)
            base = os.path.splitext(stem)[0]
            try:
                with os.scandir(folder) as it:
                    entries = [e for e in it if e.is_file()]
            except OSError as exc:
                checked.append(f"{path} 所在目录不可读（{exc.strerror or exc}）")
                continue
            for entry in entries:
                ext = os.path.splitext(entry.name)[1].lower()
                if ext not in SUB_EXTS:
                    continue
                name_stem = os.path.splitext(entry.name)[0]
                if name_stem != base and not name_stem.startswith(base + "."):
                    continue
                try:
                    size = entry.stat().st_size
                except OSError:
                    continue
                if size > MAX_SUB_BYTES:
                    continue
                found[entry.path] = {"name": entry.name, "size": size,
                                     "lang": _lang_of(entry.name), "path": entry.path}
        if found:
            return sorted(found.values(), key=lambda x: x["name"]), ""
        if not mapped:
            return [], "MEDIA_PATH_MAP 没有匹配到任何视频路径，检查前缀是否写对"
        hint = "同目录没有与视频同名的字幕（.srt / .ass / .ssa / .vtt / .sub）"
        detail = "；".join(checked[:2])
        return [], hint + ("：" + detail if detail else "")

    def load_local(self, item_id: int, name: str) -> dict:
        """把同目录字幕读进缓存，返回统一的 subtitle_id。"""
        candidates, hint = self.local_candidates(item_id)
        for cand in candidates:
            if cand["name"] == name:
                with open(cand["path"], "rb") as fh:
                    raw = fh.read()
                item = self.put(name, raw, "local")
                self.link(item_id, item["id"])
                return item
        raise ValueError(hint or "字幕不存在或不属于该视频")


# --------------------------------------------------------------------- 路由
def subtitles_list(handler, query, *_):
    fid = int((query.get("item_id") or ["0"])[0])
    local: list[dict] = []
    hint = "缺少 item_id"
    if fid:
        local, hint = STORE.local_candidates(fid)
    for item in local:
        item.pop("path", None)  # 绝不把服务器本地路径发给客户端
    handler._json({"local": local, "cached": STORE.list_for_item(fid),
                   "choice": STORE.choice(fid) if fid else None,
                   "providers": [], "hint": hint})


def subtitles_local(handler, query, *_):
    fid = int((query.get("item_id") or ["0"])[0])
    name = (query.get("name") or [""])[0]
    try:
        handler._json(STORE.load_local(fid, name))
    except (ValueError, OSError) as exc:
        handler._error(400, str(exc))


def subtitles_import(handler, query, *_):
    body = handler._body()
    item_id = int(body.get("item_id") or 0)
    name = str(body.get("filename") or "subtitle.srt")
    raw_b64 = str(body.get("content") or "")
    try:
        raw = base64.b64decode(raw_b64, validate=True)
    except Exception as exc:  # noqa: BLE001
        handler._error(400, f"base64 解码失败: {exc}")
        return
    if not raw:
        handler._error(400, "空文件")
        return
    try:
        item = STORE.put(os.path.basename(name), raw, "import")
        STORE.link(item_id, item["id"])
        handler._json(item)
    except ValueError as exc:
        handler._error(400, str(exc))


def subtitles_url(handler, query, *_):
    body = handler._body()
    item_id = int(body.get("item_id") or 0)
    url = str(body.get("url") or "")
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        handler._error(400, "只接受 http(s) URL")
        return
    try:
        req = Request(url, headers={"User-Agent": "Amane-Harmony"})
        with _opener.open(req, timeout=FETCH_TIMEOUT) as resp:
            raw = resp.read(MAX_SUB_BYTES + 1)
    except Exception as exc:  # noqa: BLE001
        handler._error(502, f"抓取失败: {exc}")
        return
    if len(raw) > MAX_SUB_BYTES:
        handler._error(413, "字幕文件超过 2 MiB")
        return
    name = os.path.basename(parsed.path) or "subtitle.srt"
    try:
        item = STORE.put(name, raw, "url")
        STORE.link(item_id, item["id"])
        handler._json(item)
    except ValueError as exc:
        handler._error(400, str(exc))


def subtitle_stream(handler, query, sid, *_):
    as_vtt = (query.get("format") or [""])[0] == "vtt"
    got = STORE.get(sid, as_vtt=as_vtt)
    if got is None:
        handler._error(404, "字幕不存在")
        return
    text, ctype = got
    body = text.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "public, max-age=86400")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def choice_get(handler, query, *_):
    fid = int((query.get("item_id") or ["0"])[0])
    handler._json(STORE.choice(fid) or {})


def choice_put(handler, query, *_):
    body = handler._body()
    fid = int(body.get("item_id") or 0)
    sid = str(body.get("subtitle_id") or "")
    if not fid or not STORE.describe(sid):
        handler._error(400, "item_id / subtitle_id 无效")
        return
    STORE.set_choice(fid, sid)
    handler._json({"ok": True})


def providers_list(handler, query, *_):
    # 预留接口：注册表为空，意味着不实现也不启用任何在线字幕源。
    handler._json({"providers": [],
                   "note": "在线字幕源为预留扩展点，当前未启用，也不接受任何第三方凭据。"})


ROUTES = [
    ("GET", r"/api/user/subtitles", subtitles_list),
    ("GET", r"/api/user/subtitles/local", subtitles_local),
    ("POST", r"/api/user/subtitles/import", subtitles_import),
    ("POST", r"/api/user/subtitles/url", subtitles_url),
    ("GET", r"/api/user/subtitle/([0-9a-f]{24})", subtitle_stream),
    ("HEAD", r"/api/user/subtitle/([0-9a-f]{24})", subtitle_stream),
    ("GET", r"/api/user/subtitles/choice", choice_get),
    ("PUT", r"/api/user/subtitles/choice", choice_put),
    ("GET", r"/api/user/subtitles/providers", providers_list),
]


def install(api) -> dict:
    global A, STORE  # noqa: PLW0603
    A = api
    STORE = SubtitleStore(api, os.environ.get("MEDIA_PATH_MAP", ""))
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_choice ("
        " item_id INTEGER PRIMARY KEY,"
        " subtitle_id TEXT NOT NULL,"
        " updated_at TEXT NOT NULL);")
    # 字幕缓存按内容哈希全局去重，所以要单独记录「这条字幕属于哪些影片」
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_item ("
        " subtitle_id TEXT NOT NULL,"
        " item_id INTEGER NOT NULL,"
        " created_at TEXT NOT NULL,"
        " PRIMARY KEY(subtitle_id, item_id));")
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 subtitles 已启用（{len(ROUTES)} 个端点）")
    return {"id": "subtitles", "enabled": True, "scope": "public"}
