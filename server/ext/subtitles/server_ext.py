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
import difflib
import hashlib
import http.cookiejar
import io
import json
import os
import sqlite3
import re
import threading
import time
import zipfile
from datetime import datetime, timezone
import urllib.error
from urllib.parse import quote, urljoin, urlparse
from urllib.request import Request, build_opener, ProxyHandler

A = None       # type: ignore[assignment]  # ExtensionHost 注入的 api
STORE = None   # type: ignore[assignment]  # 模块级单例，供 handler 使用

SUB_EXTS = (".srt", ".ass", ".ssa", ".vtt", ".sub", ".smi")
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


def _decode_with(raw: bytes) -> tuple[str, str]:
    """字节 → (文本, 采用的编码名)（2.6.1.7）。

    顺序：BOM → UTF-16 启发式 → UTF-8 → 候选编码打分。
    之前只有 utf-8-sig + shift_jis/gb18030/big5 打分，**UTF-16 完全没处理** ——
    Windows 上的字幕工具（Subtitle Workshop / 记事本另存）默认存 UTF-16LE，
    进来会被当 latin 乱码整片丢弃，用户看到的就是「字幕一条都不显示」。
    """
    if not raw:
        return "", "empty"
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw.decode("utf-8-sig", errors="replace"), "UTF-8 BOM"
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        enc = "utf-16-le" if raw[0:1] == b"\xff" else "utf-16-be"
        try:
            return raw.decode(enc), "UTF-16LE" if enc.endswith("le") else "UTF-16BE"
        except UnicodeDecodeError:
            pass
    # 无 BOM 的 UTF-16：西文/中文交替出现大量 0x00 字节
    if len(raw) >= 8 and raw.count(b"\x00") > len(raw) // 4:
        for enc, label in (("utf-16-le", "UTF-16LE"), ("utf-16-be", "UTF-16BE")):
            try:
                t = raw.decode(enc)
            except UnicodeDecodeError:
                continue
            if _score(t) > -0.3:
                return t, label
    try:
        return raw.decode("utf-8"), "UTF-8"
    except UnicodeDecodeError:
        pass
    best, best_score, best_label = "", -100.0, ""
    for enc, label in (("gb18030", "GBK"), ("big5", "BIG5"),
                       ("shift_jis", "Shift-JIS"), ("euc-kr", "EUC-KR")):
        try:
            text = raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
        s = _score(text)
        if s > best_score:
            best, best_score, best_label = text, s, label
    if best:
        return best, best_label
    return raw.decode("utf-8", errors="replace"), "UTF-8(有损)"


def _decode(raw: bytes) -> str:
    """常见字幕编码 → str（保留旧签名，内部走 `_decode_with`）。"""
    return _decode_with(raw)[0]


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


_MICRODVD = re.compile(r"^\{(\d+)\}\{(\d+)\}(.*)$")
_SMI_SYNC = re.compile(r"<sync[^>]*start\s*=\s*\"?(\d+)\"?[^>]*>(.*?)(?=<sync|\Z)", re.I | re.S)
_HTML_TAG = re.compile(r"<[^>]+>")


def _microdvd_to_vtt(text: str) -> str:
    """MicroDVD `.sub`（`{帧}{帧}文本`）→ WebVTT。

    `{1}{1}23.976` 是约定俗成的「声明帧率」首行；没有就按 23.976 算（动画/日影最常见）。
    """
    fps = 23.976
    cues: list[str] = []
    for line in text.replace("\r\n", "\n").split("\n"):
        m = _MICRODVD.match(line.strip())
        if not m:
            continue
        start, end, body = int(m.group(1)), int(m.group(2)), m.group(3)
        if start == 1 and end == 1:
            try:
                fps = float(body.strip()) or fps
            except ValueError:
                pass
            continue
        if not body.strip():
            continue
        clean = body.replace("|", "\n").replace("{\\", "{").strip()
        clean = _ASS_TAG.sub("", clean).strip()
        if not clean:
            continue
        cues.append("%s --> %s\n%s"
                    % (_vtt_stamp_ms(start / fps * 1000), _vtt_stamp_ms(end / fps * 1000), clean))
    return "WEBVTT\n\n" + "\n\n".join(cues) + "\n" if cues else "WEBVTT\n\n"


def _smi_to_vtt(text: str) -> str:
    """SAMI `.smi` → WebVTT（只取 SYNC 块里的正文，丢掉样式/脚本）。"""
    body = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", text, flags=re.I | re.S)
    cues: list[str] = []
    for m in _SMI_SYNC.finditer(body):
        start = int(m.group(1))
        chunk = _HTML_TAG.sub("\n", m.group(2))
        chunk = re.sub(r"&nbsp;", " ", chunk)
        chunk = "\n".join(x.strip() for x in chunk.split("\n") if x.strip())
        if chunk:
            cues.append("%s --> %s\n%s" % (_vtt_stamp_ms(start),
                                           _vtt_stamp_ms(start + 2000), chunk))
    return "WEBVTT\n\n" + "\n\n".join(cues) + "\n" if cues else "WEBVTT\n\n"


def _vtt_stamp_ms(ms: float) -> str:
    total = max(0, int(ms))
    h, rem = divmod(total, 3600000)
    mi, rem = divmod(rem, 60000)
    s, milli = divmod(rem, 1000)
    return f"{h:02d}:{mi:02d}:{s:02d}.{milli:03d}"


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
    if ext == ".sub":
        # 只处理 MicroDVD（`{帧}{帧}文本`）；其它 .sub（VobSub 二进制）解不出文字
        if _MICRODVD.match(body.strip().split("\n")[0] if body.strip() else ""):
            return _microdvd_to_vtt(body)
        return _to_vtt(body, ".srt")
    if ext == ".smi":
        return _smi_to_vtt(body)

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


def _unwrap_archive(raw: bytes, name: str) -> tuple[bytes, str]:
    """下载到的是 zip（很多站把字幕打包）→ 取出里面第一个字幕文件（2.6.1.7）。

    以前拿到 zip 会当成字幕文本去解析，结果 0 条 cue、用户只看到「保存成功但没字」。
    """
    if not raw.startswith(b"PK\x03\x04"):
        return raw, name
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as zf:
            pick = ""
            for info in zf.infolist():
                if info.is_dir() or "__MACOSX" in info.filename:
                    continue
                ext = os.path.splitext(info.filename)[1].lower()
                if ext in SUB_EXTS and info.file_size > 32:
                    pick = info.filename
                    break
            if not pick:
                return raw, name
            return zf.read(pick), os.path.basename(pick)
    except (zipfile.BadZipFile, OSError):
        return raw, name


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

    def is_owned(self, item_id: int, filename: str) -> bool:
        with self.A.user_db() as conn:
            row = conn.execute(
                "SELECT 1 FROM subtitle_owned WHERE item_id = ? AND filename = ?",
                (item_id, filename)).fetchone()
        return bool(row)

    def mark_owned(self, item_id: int, filename: str, source: str, provider: str) -> None:
        with self.A.user_db() as conn:
            conn.execute(
                "INSERT INTO subtitle_owned(item_id, filename, source, provider, created_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(item_id, filename) DO UPDATE SET "
                "source = excluded.source, provider = excluded.provider, "
                "created_at = excluded.created_at",
                (item_id, filename, source, provider, _now()))

    def unmark_owned(self, item_id: int, filename: str) -> None:
        with self.A.user_db() as conn:
            conn.execute("DELETE FROM subtitle_owned WHERE item_id = ? AND filename = ?",
                         (item_id, filename))

    def owned_list(self, item_id: int) -> list[dict]:
        with self.A.user_db() as conn:
            rows = conn.execute(
                "SELECT filename, source, provider, created_at FROM subtitle_owned "
                "WHERE item_id = ? ORDER BY created_at DESC", (item_id,)).fetchall()
        return [{"filename": r[0], "source": r[1], "provider": r[2], "created_at": r[3]}
                for r in rows]

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
        # 同一份字幕只显示一次（重复显示修复）：在线字幕下载后按
        # `<视频stem>.<lang>.srt` 写回媒体目录，恰好命中 local_candidates 的
        # 「同名 + .后缀」口径，于是同一份同时出现在 同目录(local) / 已缓存(cached,
        # source=online) / 已存进片库(owned) 三处。subtitle_owned 只登记本扩展自己写的，
        # 用户自己放的同名字幕永远不在表里 —— 按文件名剔除这些，既去重又不误伤。
        owned_names = {r["filename"] for r in STORE.owned_list(fid)}
        if owned_names:
            local = [x for x in local if x.get("name") not in owned_names]
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
        raw, name = _unwrap_archive(raw, os.path.basename(name))
        item = STORE.put(name, raw, "import")
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
        raw, name = _unwrap_archive(raw, name)
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
    handler._json({"providers": [{"id": p["id"], "name": p["name"], "note": p["note"]}
                                 for p in PROVIDERS],
                   "note": "在线字幕搜索：三个来源合并去重，按语言偏好排序。"})


# --------------------------------------------------------------------- 在线搜索
#
# 三个来源（2026-11-11 用户提供）：迅雷接口 / javzimu / 字幕猫。都不需要账号。
# 只做「搜索」，不在这里写盘 —— 落盘与删除是下一步，且要动「媒体卷只读」这条老约束。
#
# 各源特点（都是实测出来的）：
#   迅雷     JSON，最稳，name 单参数就能查；返回里 .srt/.ass 混着，按扩展名筛。
#   javzimu  JSON，但要 name= 参数（不是 q/keyword），且有速率限制 —— 命中 429 时返回
#            带 retry 的错误码，不当作「没找到」。
#   字幕猫   只能搜 HTML，结果是 subs/…/<名字>.html 详情页；真正的 srt 链接在详情页里，
#            按语言分（-zh-CN / -zh-TW / -en …），要二次请求才能拿到。

SEARCH_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
SEARCH_TIMEOUT = 8.0
SEARCH_MAX_BYTES = 512 * 1024

# 出口代理：javzimu / 字幕猫 会按出口 IP 与 TLS 指纹拦截，NAS 直连是 403 / TLS EOF，
# 家宽却能过。给一个「换个出口」的开关，配置成家里那条线路的 HTTP 代理即可。
SUBTITLE_PROXY = os.environ.get("SUBTITLE_PROXY", "").strip()


def _opener_for(proxy: str):
    if not proxy:
        return _opener
    return build_opener(ProxyHandler({"http": proxy, "https": proxy}))


# javzimu 的验证码是「挑战 → 校验」两步，**必须带同一份 cookie**：
# 挑战响应里下发的那条 cookie 没回传，verify 就 403（用户看到的就是「图对了但提交 403」）。
# 所以这里用一个带 CookieJar 的会话 opener，全程复用。
_COOKIE_JAR = http.cookiejar.CookieJar()
_SESSION_OPENER = None

# javzimu 会话验证状态（2026-11-20 23:40）：验证码是会话级的，验证一次能搜几次。
# 记录进程内状态，供客户端在自动补前显示「JAV字幕可用/需验证」并给验证入口；
# 不联网探测（不浪费搜索额度），服务重启后内存清空 = 新会话需重新验证（符合站点口径）。
_JAVZIMU_STATE = {"verified": False, "remaining": 0, "verified_at": "",
                  "last_error": ""}


def _javzimu_status() -> dict:
    """返回当前会话对 javzimu 的可用性快照。need_captcha=true 时客户端应让用户验证。"""
    st = dict(_JAVZIMU_STATE)
    st["need_captcha"] = (not st["verified"]) or st["remaining"] <= 0
    st["hint"] = ("JAV字幕已验证，还能搜约 %d 次" % st["remaining"]
                  if not st["need_captcha"] else "JAV字幕需要验证码，验证后可参与自动补搜索")
    return st


def _javzimu_mark_captcha(msg: str = "") -> None:
    """搜索撞到验证码：会话 clearance 失效，通知客户端重新验证。"""
    _JAVZIMU_STATE.update(verified=False, remaining=0, last_error=msg[:160])


def _session_opener():
    global _SESSION_OPENER  # noqa: PLW0603
    if _SESSION_OPENER is None:
        handlers = [urllib.request.HTTPCookieProcessor(_COOKIE_JAR)]
        if SUBTITLE_PROXY:
            handlers.append(ProxyHandler({"http": SUBTITLE_PROXY, "https": SUBTITLE_PROXY}))
        _SESSION_OPENER = build_opener(*handlers)
    return _SESSION_OPENER


def _browser_headers() -> dict:
    """尽量像个浏览器：CF 类防护先看 UA / Accept / Referer，再看 TLS 指纹。"""
    return {
        "User-Agent": SEARCH_UA,
        "Accept": "application/json, text/html;q=0.9, */*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }

# 语言偏好：简中 > 双语 > 繁中 > 英文 > 其它。数字越小越靠前。
LANG_RANK = (("简体", 0), ("zh-cn", 0), ("双语", 1), ("chs&eng", 1), ("繁體", 2),
             ("zh-tw", 2), ("繁体", 2), ("英文", 3), ("en", 3))


def _lang_rank(lang: str) -> int:
    low = (lang or "").lower()
    for key, rank in LANG_RANK:
        if key in low:
            return rank
    return 9


def _fetch(url: str, timeout: float = SEARCH_TIMEOUT, referer: str = "") -> bytes:
    """取一个地址。`referer` 用于绕过防盗链（2.6.1.4）。

    javzimu 的下载口是 `https://javzimu.com/api/download?cid=…`：不带 Referer 直接
    回 403（今天用户报的「能搜出来、下载 403」就是它）。带上来源站 + Origin 之后
    WAF 才认；顺手把 Cookie 一起带上（同一个 session opener）。
    """
    headers = _browser_headers()
    if referer:
        headers["Referer"] = referer
        headers["Origin"] = referer.split("/api/")[0].rstrip("/")
    req = Request(url, headers=headers)
    with _session_opener().open(req, timeout=timeout) as resp:
        return resp.read(SEARCH_MAX_BYTES)


# 各来源的「来源页」：下载直链要 Referer 才不被当盗链
SITE_REFERER = {
    "javzimu": "https://javzimu.com/",
    "xunlei": "https://api-shoulei-ssl.xunlei.com/",
}


def _warm_site(provider: str) -> None:
    """下载前先访问一次来源站首页：拿 WAF/CF 的 clearance cookie，失败不影响主流程。"""
    home = SITE_REFERER.get(provider) or ""
    if not home:
        return
    try:
        _fetch(home, timeout=min(8.0, SEARCH_TIMEOUT))
    except Exception:  # noqa: BLE001
        pass


def _item(provider: str, name: str, lang: str, ext: str, ref: dict, note: str = "") -> dict:
    """统一条目。`ref` 是「下一步怎么下载」的最小信息，原样回给客户端再由 save 用。"""
    return {
        "provider": provider,
        "name": name,
        "lang": lang,
        "ext": ext.lstrip(".") or "srt",
        "note": note,
        "rank": _lang_rank(lang),
        "ref": base64.urlsafe_b64encode(
            json.dumps(ref, ensure_ascii=False).encode("utf-8")).decode("ascii"),
    }


def _search_xunlei(q: str) -> list[dict]:
    url = "https://api-shoulei-ssl.xunlei.com/oracle/subtitle?name=" + quote(q)
    data = json.loads(_fetch(url).decode("utf-8", "replace"))
    out: list[dict] = []
    for it in (data.get("data") or [])[:24]:
        link = str(it.get("url") or "")
        ext = str(it.get("ext") or "").lower()
        if not link.startswith("http"):
            continue
        if ext not in ("srt", "ass", "ssa", "vtt"):
            ext = link.rsplit(".", 1)[-1].lower()
        if ext not in ("srt", "ass", "ssa", "vtt"):
            continue
        langs = it.get("languages") or []
        lang = "/".join(str(x) for x in langs) or "未知"
        out.append(_item("xunlei", str(it.get("simple_name") or it.get("name") or q),
                         lang, ext, {"url": link},
                         str(it.get("extra_name") or "")))
    return out


def _site_duration(it: dict) -> float:
    """从站点搜索结果里防御性抠出影片时长（秒）。

    javzimu 的结果会带影片时长（用户 2026-11-20 指出），但字段名/格式随站点版本变，
    这里把常见键和「秒数 / HH:MM:SS / MM:SS」三种格式都试一遍；解析不出返回 0，
    内容打分会走中性分支，绝不会因为字段改名就误伤打分。纯本地解析，不联网。
    """
    for key in ("duration", "movie_duration", "video_duration", "length",
                "video_length", "runtime", "seconds", "duration_sec", "time"):
        raw = it.get(key)
        if raw is None or isinstance(raw, bool):
            continue
        if isinstance(raw, (int, float)):
            val = float(raw)
            if 60 <= val <= 6 * 3600:      # 合理片长：1 分钟 ~ 6 小时
                return val
            if 1 <= val <= 6:              # 有的存分钟（如 125 存成 2.08）
                return val * 60
            continue
        text = str(raw).strip()
        m = re.fullmatch(r"(\d{1,2}):(\d{2}):(\d{2})", text)
        if m:
            return int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])
        m = re.fullmatch(r"(\d{1,3}):(\d{2})", text)
        if m:
            return int(m[1]) * 60 + int(m[2])
        m = re.fullmatch(r"(\d{3,5})", text)   # 纯秒数字符串
        if m and 60 <= int(text) <= 6 * 3600:
            return float(text)
    return 0.0


def _search_javzimu(q: str) -> list[dict]:
    url = "https://javzimu.com/api/search?name=" + quote(q)
    try:
        raw = _fetch(url)
    except urllib.error.HTTPError as exc:
        # 这个源分三种失败，别都报成「403」：验证码 / 限流 / 真被挡
        body = ""
        try:
            body = exc.read(400).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            pass
        if "captcha_required" in body or "verification required" in body.lower():
            _javzimu_mark_captcha("站点启用了搜索验证码")
            raise RuntimeError("站点启用了搜索验证码，请在字幕管理页验证一次") from exc
        if exc.code == 429:
            raise RuntimeError("javzimu 限流（429），稍后再试") from exc
        raise RuntimeError(f"javzimu 拒绝访问（{exc.code}）") from exc
    except Exception as exc:  # noqa: BLE001
        if "429" in str(exc):
            raise RuntimeError("javzimu 限流（429），稍后再试") from exc
        raise
    data = json.loads(raw.decode("utf-8", "replace"))
    out: list[dict] = []
    for it in (data.get("data") or [])[:24]:
        name = str(it.get("name") or "")
        ext = str(it.get("ext") or "srt").lower()
        cid = str(it.get("cid") or "")
        if not cid:
            continue
        # 下载口必须带搜索响应签发的 `_ts` + `_sig`（2026-11-13 实测）：
        # 只拼 cid/ext/name 一律 403 `Invalid or expired download link`，
        # 带上签名后立刻 200 拿到真 srt。签名有时效，过期就重新搜一次。
        link = ("https://javzimu.com/api/download?cid=" + quote(cid)
                + "&ext=" + quote(ext) + "&name=" + quote(name))
        ts = it.get("_ts")
        sig = it.get("_sig")
        if ts and sig:
            link += "&_ts=" + quote(str(ts)) + "&_sig=" + quote(str(sig))
        item = _item("javzimu", name or q, str(it.get("language") or ""), ext,
                     {"url": link, "ts": ts, "sig": sig})
        item["site_duration"] = _site_duration(it)   # 站点片长，打分加分项，缺则 0
        out.append(item)
    return out


ZIMUCAT_ROWS = re.compile(r'<a href="(subs/[^"]+\.html)"[^>]*>([^<]{1,120})</a>\s*(?:\(([^)]{0,60})\))?')


def _search_zimucat(q: str) -> list[dict]:
    html = _fetch("https://www.subtitlecat.com/index.php?search=" + quote(q)).decode(
        "utf-8", "replace")
    out: list[dict] = []
    for path, name, note in ZIMUCAT_ROWS.findall(html)[:20]:
        # 名字形如 SNIS-104.en，后缀即目标语言
        lang = name.rsplit(".", 1)[-1] if "." in name else ""
        out.append(_item("zimucat", name.strip(), lang, "srt",
                         {"detail": "https://www.subtitlecat.com/" + path}, note.strip()))
    return out


PROVIDERS = [
    {"id": "xunlei", "name": "迅雷", "fn": _search_xunlei, "note": "接口直连，最稳"},
    {"id": "javzimu", "name": "JAV字幕", "fn": _search_javzimu, "note": "有速率限制"},
]

# 字幕猫：实测从本机出口（VPS）被 Cloudflare 直接 reset，改请求头也过不去；
# 只有拿到一条能过 CF 的代理才谈得上用，所以默认不挂上，免得每次搜索都多一条报错。
# 有了代理就 `SUBTITLE_ZIMUCAT=1` 打开。
if os.environ.get("SUBTITLE_ZIMUCAT", "").strip() in ("1", "true", "on"):
    PROVIDERS.append({"id": "zimucat", "name": "字幕猫", "fn": _search_zimucat,
                      "note": "需二次解析详情页"})


def subtitles_search(handler, query, *_):
    """并发查三个源，合并去重后按语言偏好排序。任一源失败不影响其它源。"""
    q = (query.get("q") or [""])[0].strip()
    item_id = int((query.get("item_id") or ["0"])[0])
    if not q and item_id:
        with A.amane_db() as conn:
            row = conn.execute("SELECT number FROM metadata WHERE id = ?", (item_id,)).fetchone()
        q = (row[0] if row and row[0] else "").strip()
    if not q:
        handler._error(400, "缺少 q（或 item_id 对应的条目没有番号）")
        return

    import threading
    results: list[dict] = []
    errors: list[dict] = []
    lock = threading.Lock()

    def run(provider: dict) -> None:
        try:
            got = provider["fn"](q)
        except Exception as exc:  # noqa: BLE001 - 单个源失败不能拖垮整次搜索
            msg = str(exc)[:180]
            with lock:
                # captcha=True 时客户端会显示「验证」入口（应用内输，不用跳浏览器）
                errors.append({"provider": provider["id"], "error": msg,
                               "captcha": "验证码" in msg})
            return
        with lock:
            results.extend(got)

    threads = [threading.Thread(target=run, args=(p,), daemon=True) for p in PROVIDERS]
    for t in threads:
        t.start()
    for t in threads:
        t.join(SEARCH_TIMEOUT + 2)

    seen: dict[str, dict] = {}
    for item in results:
        key = (item["provider"], item["name"].lower())
        seen.setdefault(key, item)
    merged = sorted(seen.values(), key=lambda x: (x["rank"], x["provider"], len(x["name"])))
    # 每条在线结果带上「落盘会用哪个语言后缀」：客户端靠 (provider, lang_tag)
    # 把已下载的那份和这条结果对上号，不再显示两遍（2.5.9.1）
    for item in merged:
        item["lang_tag"] = _lang_tag(str(item.get("lang") or ""), str(item.get("name") or ""))
    handler._json({"q": q, "items": merged, "total": len(merged), "errors": errors,
                   "providers": [p["id"] for p in PROVIDERS]})


_STATS_CACHE: dict = {}


def _cue_stats(text: str, ext: str) -> dict:
    """这条字幕到底有多少条 cue + 首句是什么（2.5.9.1）。

    用户报「下完看不出是字幕烂还是字幕控件烂」—— 这里**走的就是播放器同一条
    `_to_vtt`**：cues > 0 而画面上什么都没有，说明是选没选上/渲染的问题；
    cues == 0 则说明文件本身解析不出字幕，跟控件无关。
    """
    try:
        vtt = _to_vtt(text, ext)
    except Exception:  # noqa: BLE001
        vtt = text
    cues = 0
    sample = ""
    for block in vtt.replace("\r\n", "\n").split("\n\n"):
        if "-->" not in block:
            continue
        cues += 1
        if not sample:
            for line in block.split("\n"):
                s = line.strip()
                if not s or "-->" in s or s.isdigit() or s.upper() == "WEBVTT":
                    continue
                sample = s[:48]
                break
    return {"cues": cues, "sample": sample}


def _stats_of_file(path: str) -> dict:
    """读盘上字幕算统计；按 (路径, mtime, 大小) 缓存，详情页反复开也不重解析。"""
    try:
        st = os.stat(path)
    except OSError:
        return {"cues": 0, "sample": ""}
    key = (path, int(st.st_mtime), st.st_size)
    hit = _STATS_CACHE.get(key)
    if hit is not None:
        return hit
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_SUB_BYTES)
        text, enc = _decode_with(raw)
        out = _cue_stats(text, _safe_ext(path) or ".srt")
        out["encoding"] = enc
    except (OSError, ValueError):
        out = {"cues": 0, "sample": "", "encoding": ""}
    if len(_STATS_CACHE) > 400:
        _STATS_CACHE.clear()
    _STATS_CACHE[key] = out
    return out


def _lang_tag(lang: str, name: str) -> str:
    """落盘用的语言后缀，对齐 Emby/Jellyfin 认的写法：chs / cht / eng / jpn。"""
    blob = (lang + " " + name).lower()
    if "双语" in blob or "chs&eng" in blob:
        return "chs&eng"
    if "繁體" in blob or "繁体" in blob or "zh-tw" in blob or "cht" in blob:
        return "cht"
    if "简体" in blob or "简中" in blob or "zh-cn" in blob or "chs" in blob:
        return "chs"
    if "英" in blob or "en" in blob:
        return "eng"
    if "日" in blob or "jp" in blob:
        return "jpn"
    return "und"


def _video_targets(item_id: int) -> tuple[list[tuple[str, str]], str]:
    """该条目每个视频的 (宿主目录, 无扩展名文件名)。

    字幕必须写成 `<视频文件名>.chs.srt` —— 用番号取名会**匹配不上**同目录扫描的口径
    （`local_candidates` 认的是「与视频同名」或「同名 + .后缀」），写完播放器也看不见。
    """
    with A.amane_db() as conn:
        rows = conn.execute(
            "SELECT path FROM media_files WHERE metadata_id = ? ORDER BY id",
            (item_id,)).fetchall()
    paths = [r[0] for r in rows if r and r[0]]
    if not paths:
        return [], "amane.db 里没有该条目的文件记录"
    if not STORE.path_map:
        return [], "未配置 MEDIA_PATH_MAP，写不进媒体目录"
    out: list[tuple[str, str]] = []
    for path in paths:
        real = STORE.map_path(path)
        if not real:
            continue
        folder, filename = os.path.split(real)
        stem = os.path.splitext(filename)[0]
        if folder and stem and os.path.isdir(folder) and (folder, stem) not in out:
            out.append((folder, stem))
    if not out:
        return [], "MEDIA_PATH_MAP 没有匹配到任何视频路径"
    return out, ""


def _number_of(item_id: int) -> str:
    with A.amane_db() as conn:
        row = conn.execute("SELECT number FROM metadata WHERE id = ?", (item_id,)).fetchone()
    return (row[0] or "").strip() if row else ""


ZIMUCAT_SRT = re.compile(r'href="([^"]+\.(?:srt|ass|vtt))"', re.I)


def _zimucat_pick(detail: str) -> str:
    """字幕猫搜索结果只是详情页，真正的 srt 在里面按语言分 —— 取最靠前的中文。"""
    html = _fetch(detail).decode("utf-8", "replace")
    links = [urljoin(detail, m) for m in ZIMUCAT_SRT.findall(html)]
    if not links:
        raise RuntimeError("详情页里没有可下载的字幕文件")
    for want in ("zh-cn", "zh_cn", "chs", "zh-tw", "cht", "zh"):
        for link in links:
            if want in link.lower():
                return link
    return links[0]


def _ref_payload(token: str) -> dict:
    try:
        return json.loads(base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"非法的 ref：{exc}") from exc


def _persist_online(item_id: int, provider: str, lang: str, name: str,
                    raw: bytes, ext: str, text: str, encoding: str) -> dict:
    """把已解码的字幕落缓存 + 写媒体目录 + 登记 owned + 记版本。

    save（单条手动）与 auto（一键自动选优）共用这一条落库链，避免两处行为漂移。
    返回给客户端的结果体（不含打分字段，调用方自行补充）。
    """
    # 先入缓存：失败了也能立刻播，且给了客户端一个统一的 subtitle_id
    # 名字用**解包后的文件名**：zip 里是 .ass 时，落缓存也必须按 .ass 记录，
    # 否则 /api/user/subtitle/<id> 会拿 SRT 的解析器去转 ASS（一条 cue 都没有）。
    item = STORE.put(f"{provider}-{name}", raw, "online")
    STORE.link(item_id, item["id"])

    number = _number_of(item_id) or "subtitle"
    tag = _lang_tag(lang, name)
    targets, reason = _video_targets(item_id)
    written: list[str] = []
    for folder, stem in targets:
        base = stem or number
        target = os.path.join(folder, f"{base}.{tag}{ext}")
        # 绝不覆盖已有文件：不是我们写的那就顺延编号
        if os.path.exists(target) and not STORE.is_owned(item_id, os.path.basename(target)):
            for i in range(2, 10):
                alt = os.path.join(folder, f"{base}.{tag}-{i}{ext}")
                if not os.path.exists(alt):
                    target = alt
                    break
        try:
            with open(target, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
        except OSError as exc:
            A.log(f"WARN subtitles 写入 {target} 失败: {exc}")
            continue
        STORE.mark_owned(item_id, os.path.basename(target), "online", provider)
        written.append(os.path.basename(target))
        # 版本历史：这次下载记一条 added，供「字幕管理 → 来源/版本」回溯与恢复
        _version_log(item_id, os.path.basename(target), "online", provider,
                     item["id"], "added")

    stats = _cue_stats(text, ext)
    return {
        "kind": "library" if written else "cache",
        "files": written,
        "reason": "" if written else (reason or "媒体目录不可写"),
        "subtitle_id": item["id"],
        "lang": tag,
        "name": item["name"],
        "cues": stats["cues"],
        "sample": stats["sample"],
        "encoding": encoding,
    }


def subtitles_save(handler, query, *_):
    """把一条在线字幕落到资源库（视频同目录），并登记成「旁挂写的」。

    为什么写库而不是存手机：换设备/重装还在、Emby 也认、再开就是本地字幕。
    写不进去（卷只读、FUSE 异常）就回落到缓存 —— 照样能看，只是不跨设备。
    """
    body = handler._body()
    try:
        item_id = int(body.get("item_id") or 0)
    except (TypeError, ValueError):
        item_id = 0
    if not item_id:
        handler._error(422, "item_id 必填")
        return
    provider = str(body.get("provider") or "")
    lang = str(body.get("lang") or "")
    name = str(body.get("name") or "subtitle.srt")
    try:
        ref = _ref_payload(str(body.get("ref") or ""))
    except ValueError as exc:
        handler._error(400, str(exc))
        return

    link = ref.get("url") or ""
    referer = SITE_REFERER.get(provider) or ""
    try:
        if not link and ref.get("detail"):
            link = _zimucat_pick(str(ref["detail"]))
            referer = str(ref["detail"])
        if not link:
            handler._error(400, "这条结果没有可下载地址")
            return
        # 先热一次站点拿 cookie，再带 Referer 取直链（防盗链否则 403）
        _warm_site(provider)
        raw = _fetch(str(link), timeout=FETCH_TIMEOUT, referer=referer)
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            body = ""
            try:
                body = exc.read(200).decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                pass
            if "expired" in body.lower() or "invalid" in body.lower():
                handler._error(502, f"{provider} 的下载链接已过期（有时效），重新搜一次再下")
            else:
                handler._error(502, f"{provider} 拒绝下载（403）：站点侧又加了新门槛，"
                                    "把这句提示发我；先用另一个来源")
        elif exc.code == 429:
            handler._error(502, f"{provider} 限流（429），过几分钟再试")
        else:
            handler._error(502, f"下载失败: HTTP {exc.code}")
        return
    except Exception as exc:  # noqa: BLE001
        handler._error(502, f"下载失败: {exc}")
        return
    if len(raw) > MAX_SUB_BYTES:
        handler._error(413, "字幕文件超过 2 MiB")
        return

    raw, name = _unwrap_archive(raw, name)
    ext = _safe_ext(name) or _safe_ext(str(link)) or ".srt"
    text, encoding = _decode_with(raw)
    if not text.strip():
        handler._error(422, "字幕内容为空或编码无法识别")
        return

    result = _persist_online(item_id, provider, lang, name, raw, ext, text, encoding)
    result["ok"] = True
    handler._json(result)


def subtitles_owned(handler, query, *_):
    """已下载到库里的（只列旁挂自己写的），带存在性，供「删除不合适的字幕」。"""
    item_id = int((query.get("item_id") or ["0"])[0])
    if not item_id:
        handler._error(422, "item_id 必填")
        return
    rows = STORE.owned_list(item_id)
    targets, reason = _video_targets(item_id)
    for row in rows:
        found = ""
        for folder, _ in targets:
            cand = os.path.join(folder, row["filename"])
            if os.path.isfile(cand):
                found = cand
                break
        row["exists"] = bool(found)
        # 语言后缀（`ABC-123.chs.srt` → chs）：客户端用它把「在线结果」和「已下载」
        # 对上号，避免同一条字幕出现两遍（2.5.9.1）
        base = row["filename"]
        parts = base.split(".")
        row["lang"] = parts[-2] if len(parts) >= 3 else ""
        stats = _stats_of_file(found) if found else {"cues": 0, "sample": "", "encoding": ""}
        row["cues"] = stats["cues"]
        row["sample"] = stats["sample"]
        row["encoding"] = stats.get("encoding", "")
    handler._json({"item_id": item_id, "items": rows, "dirs": len(targets), "hint": reason})


def subtitles_owned_delete(handler, query, *_):
    """删一条「旁挂写的」字幕。双重校验：登记过 + 路径仍在这条视频的目录内。"""
    item_id = int((query.get("item_id") or ["0"])[0])
    filename = os.path.basename((query.get("name") or [""])[0].strip())
    if not item_id or not filename:
        handler._error(422, "item_id 与 name 必填")
        return
    if not STORE.is_owned(item_id, filename):
        handler._error(403, "这条字幕不是旁挂下载的，不删（避免误删你自己放的字幕）")
        return
    targets, _ = _video_targets(item_id)
    removed = 0
    for folder, _stem in targets:
        target = os.path.join(folder, filename)
        if os.path.dirname(os.path.abspath(target)) != os.path.abspath(folder):
            continue
        try:
            if os.path.isfile(target):
                os.remove(target)
                removed += 1
        except OSError as exc:
            A.log(f"WARN subtitles 删除 {target} 失败: {exc}")
    STORE.unmark_owned(item_id, filename)
    # 版本历史：记一条「移除」，让「恢复」有据可查
    _version_log(item_id, filename, "", "", "", "removed")
    handler._json({"ok": True, "removed": removed, "name": filename})


# ===================================================================== #
# 字幕自动化管理中心：全库健康检查 + 搜索队列 + 版本管理                    #
# --------------------------------------------------------------------- #
# 设计约束（与项目字幕规则一致，别改）：
#   * 在线源只在用户**主动点搜索/确认**时触发，扫描与入队阶段绝不联网；
#   * 不内置任何第三方账号 / API Key，来源沿用现有 PROVIDERS；
#   * 不绕过验证码（验证码走已有 captcha 端点，用户自己输）；
#   * 内嵌字幕算「已有字幕」跳过（用户 2026-11-20 定的口径），因为读不到它的语言轨；
#   * 全库扫描只 scandir 视频同目录、按目录缓存一次，绝不递归（CD2 FUSE 会卡死）。
# 三张新表独立存在，不动 subtitle_owned / subtitle_item 的结构，老库平滑升级。
# ===================================================================== #

_HEALTH_TTL = 86400          # 健康快照缓存 24h；用户可点「重新扫描」强制刷新
_HEALTH_WARM_INTERVAL = 300  # 常驻增量预热间隔 5min（只扫变化的片，成本极低）
_CN_TAGS = ("chs", "sc", "cn", "zh", "cht", "tc", "chi", "简", "繁", "中")

# ---- 健康扫描状态（预热 + 进度可见）---------------------------------- #
# ThreadingHTTPServer 单进程多线程，模块级字典可跨请求共享。用锁保护读写。
# 只存内存、不落库：扫描是短时任务，进程重启后快照还在表里，状态丢失无所谓。
_scan_state: dict = {"scanning": False, "done": 0, "total": 0,
                     "started_at": "", "finished_at": "", "error": "",
                     "mode": "incremental", "reused": 0, "rescanned": 0}
_scan_lock = threading.Lock()
_warmed_once = False          # install 后只预热一次，避免每次调用都起线程
_scan_force_after = False     # 扫描期间收到全量请求 → 扫完后补一次全量


def _scan_status() -> dict:
    """给客户端的扫描状态快照（复制一份，避免调用方改到内部字典）。"""
    with _scan_lock:
        return dict(_scan_state)


def _scan_tick(done: int, total: int) -> None:
    with _scan_lock:
        if _scan_state["scanning"]:
            _scan_state["done"] = done
            _scan_state["total"] = total


def _scan_end(error: str = "") -> None:
    with _scan_lock:
        _scan_state.update(scanning=False, error=error, finished_at=_now())
        if not error:
            _scan_state["done"] = _scan_state["total"]


def _kick_scan(force: bool = False) -> bool:
    """起一次后台扫描（若已在扫则返回 False，不重复起线程）。

    force=False 增量（默认）：只重扫签名变化的片；force=True 全量重扫。
    已在扫描时：若来的是全量请求，标记「扫完再全量补一次」，不丢用户意图。
    """
    global _scan_force_after
    with _scan_lock:
        if _scan_state["scanning"]:
            if force:
                _scan_force_after = True
            return False
        _scan_state.update(scanning=True, done=0, total=0,
                           started_at=_now(), finished_at="", error="")
        want_force = force or _scan_force_after
        _scan_force_after = False
    t = threading.Thread(target=_scan_worker, args=(want_force,),
                         name="subtitle-health-warm", daemon=True)
    t.start()
    return True


def _scan_worker(force: bool = False) -> None:
    """后台跑一次扫描，进度写进 _scan_state，扫完更新快照表。"""
    global _scan_force_after
    try:
        stat = _scan_health(progress=_scan_tick, force=force)
        with _scan_lock:
            _scan_state["mode"] = stat.get("mode", "incremental")
            _scan_state["reused"] = stat.get("reused", 0)
            _scan_state["rescanned"] = stat.get("rescanned", 0)
        _scan_end()
    except Exception as exc:  # noqa: BLE001 - 后台线程异常不能冒到请求线程
        _scan_end(error=str(exc)[:200])
        A.log(f"WARN 字幕健康后台扫描失败: {exc}")
    # 扫描期间来过全量请求：接着补一次全量（增量这次可能沿用了旧行）
    with _scan_lock:
        pending = _scan_force_after
        _scan_force_after = False
    if pending:
        _kick_scan(force=True)


def _snapshot_stale() -> bool:
    """快照是否缺失或过期（决定 warm 线程要不要扫）。"""
    with A.user_db() as conn:
        row = conn.execute(
            "SELECT checked_at, COUNT(*) FROM subtitle_health").fetchone()
    if not row or not row[1]:
        return True
    return (time.time() - _parse_iso(str(row[0] or ""))) > _HEALTH_TTL

_FOREIGN_TAGS = ("eng", "en", "jpn", "jp", "ja", "kor", "ko")
_QUEUE_STATES = ("queued", "matched", "confirmed", "skipped", "failed")


def _version_log(item_id: int, filename: str, source: str, provider: str,
                 sid: str, action: str) -> None:
    """记一条字幕来源/版本变更。失败不影响主操作（历史是辅助，不能拖垮下载）。"""
    try:
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO subtitle_version(item_id, filename, source, provider, "
                "sid, action, created_at) VALUES(?,?,?,?,?,?,?)",
                (item_id, filename, source, provider, sid, action, _now()))
    except sqlite3.Error as exc:
        A.log(f"WARN subtitle_version 记录失败: {exc}")


def _norm_name(text: str) -> str:
    """番号/文件名归一：去掉非字母数字、转小写，用于匹配打分。"""
    return re.sub(r"[^a-z0-9]", "", str(text or "").lower())


def _match_confidence(number: str, title: str, cand: dict) -> tuple[int, list[str]]:
    """给一条在线候选打「和这部片的匹配度」(0-100) + 理由。纯本地计算，不联网。

    三个维度（用户 2026-11-20 要求：番号、语言、文件名）：
      - 番号：候选文件名含该片番号（归一后），权重最高 60
      - 语言：中文字幕候选 +30（这正是健康检查要补的），外语 +8
      - 文件名：候选名与片名的公共片段/相似度，最高 +10
    低于 40 分只允许展示、不允许一键确认（客户端据此置灰，防误下）。
    """
    score = 0
    reasons: list[str] = []
    cname = str(cand.get("name") or "")
    chash = _norm_name(cname)
    num = _norm_name(number)
    if num and num in chash:
        score += 60
        reasons.append(f"番号匹配 {number}")
    elif num and len(num) >= 6 and _norm_name(title):
        # 番号去掉前缀数字段再比一次（ABC-123 vs abc123 已覆盖，这里兜 Japanese 多段号）
        head = re.sub(r"[^a-z0-9]", "", str(number or "").lower())
        if head and head[:5] in chash:
            score += 40
            reasons.append("番号前缀近似")

    lang_blob = (str(cand.get("lang") or "") + " " + cname).lower()
    if any(tag in lang_blob for tag in _CN_TAGS):
        score += 30
        reasons.append("中文字幕")
    elif any(tag in lang_blob for tag in _FOREIGN_TAGS):
        score += 8
        reasons.append("外文字幕")
    else:
        reasons.append("语言未标注")

    tnorm = _norm_name(title)
    if tnorm and chash:
        ratio = difflib.SequenceMatcher(None, tnorm[:80], chash[:80]).ratio()
        if ratio >= 0.5:
            score += 10
            reasons.append(f"文件名相似 {int(ratio * 100)}%")
    return min(100, score), reasons


# ------------------------------------------------------------- 内容级打分（2026-11-20）
# 用户要「更高级的打分」：既然下载后能读到字幕正文，就用正文里的硬证据判断
# 「这条字幕是不是这部片的片」，而不是只靠文件名/番号猜。三个来源：
#   1) 字幕覆盖时长（最后一条 cue 的结束时间） vs 影片时长（metadata.runtime）
#   2) 中文字符密度 —— 目标是补中文字幕，纯英文/乱码直接掉分
#   3) cue 密度 + 解码健康度 —— 区分真字幕与空壳/垃圾文件
# javzimu 若返回了影片时长，作为加分项参与第 1 项；没有就走中性分，不误伤。
# 全部纯本地计算，不联网、不绕验证码。

_VTT_END_TS = re.compile(r"-->\s*(\d{2}):(\d{2}):(\d{2})\.(\d{3})")
# 逐条 cue 的起止时间（2026-11-20 评分改造）：旧版只取「最后一条 cue 的结束时间」，
# 字幕只有前 10 分钟、末尾插两条假 cue 也会被当成全覆盖。这里要拿到每条区间。
_VTT_TS_LINE = re.compile(
    r"(\d{1,3}):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*"
    r"(\d{1,3}):(\d{2}):(\d{2})[.,](\d{1,3})")
_CJK_CHAR = re.compile(r"[\u4e00-\u9fff]")
_KANA_CHAR = re.compile(r"[\u3040-\u30ff]")


def _film_seconds(item_id: int) -> float:
    """影片时长（秒）。metadata.runtime 是分钟；库里没有就返回 0（时长维度走中性分）。"""
    try:
        with A.amane_db() as conn:
            row = conn.execute(
                "SELECT runtime FROM metadata WHERE id = ?", (item_id,)).fetchone()
        if row and row[0]:
            sec = float(row[0]) * 60.0
            if sec > 0:
                return sec
    except (sqlite3.Error, TypeError, ValueError):
        pass
    return 0.0


def _timeline(text: str, ext: str, film_sec: float = 0.0) -> dict:
    """逐条 cue 的时间轴画像（2026-11-20 评分改造 v2）。

    返回：
      * first/last  —— 首条开始、末条结束（秒）
      * coverage    —— 净覆盖秒数（区间合并后求和），只作 detail 展示，不再硬判
      * span        —— last - first，字幕活跃跨度
      * gaps / max_gap —— 相邻 cue 空档
      * cn_cue_ratio—— 含中文的 cue 占比（逐条判）
      * cues        —— cue 条数
      * seg_hits    —— 把全片均分 10 段，有几个段内有 cue（0-10）。
                       这是覆盖广度的核心判据：台词少但贯穿全片的字幕每段都有
                       一两条 → 高分；只做开头一段 → 低分。比净覆盖率鲁棒，
                       不会因台词稀疏（净覆盖天然低）误伤。
      * seg_empty_run —— 最长连续空段数，识别"中间整段缺失"这种真缺漏。
    film_sec<=0 时分段字段为 0（缺时长数据，调用方走中性分支）。
    """
    try:
        vtt = _to_vtt(text, ext)
    except Exception:  # noqa: BLE001
        vtt = text
    spans: list[tuple[float, float]] = []
    cn_cues = 0
    for block in vtt.replace("\r\n", "\n").split("\n\n"):
        m = _VTT_TS_LINE.search(block)
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000.0
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000.0
        if end < start or end <= 0:
            continue
        spans.append((start, end))
        body = block.split("\n", 1)[1] if "\n" in block else ""
        if _cn_ratio(body) >= 0.15:
            cn_cues += 1
    if not spans:
        return {"first": 0.0, "last": 0.0, "coverage": 0.0, "span": 0.0,
                "max_gap": 0.0, "gaps": [], "cn_cue_ratio": 0.0, "cues": 0,
                "seg_hits": 0, "seg_empty_run": 0}
    spans.sort()
    merged: list[list[float]] = [[spans[0][0], spans[0][1]]]
    gaps: list[float] = []
    for start, end in spans[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            gaps.append(start - merged[-1][1])
            merged.append([start, end])
    coverage = sum(e - s for s, e in merged)
    last = max(e for _, e in spans)
    # 分段覆盖：按全片时长切 10 段，cue 覆盖到哪段就点亮哪段。
    seg_hits = 0
    seg_empty_run = 0
    if film_sec > 0:
        buckets = [False] * 10
        for s, e in spans:
            lo = min(9, max(0, int(s / film_sec * 10)))
            hi = min(9, max(0, int(e / film_sec * 10)))
            for b in range(lo, hi + 1):
                buckets[b] = True
        seg_hits = sum(1 for x in buckets if x)
        run = best = 0
        for x in buckets:
            run = 0 if x else run + 1
            best = max(best, run)
        seg_empty_run = best
    return {
        "first": spans[0][0], "last": last, "coverage": coverage,
        "span": last - spans[0][0], "max_gap": max(gaps) if gaps else 0.0,
        "gaps": gaps, "cn_cue_ratio": cn_cues / len(spans), "cues": len(spans),
        "seg_hits": seg_hits, "seg_empty_run": seg_empty_run,
    }


def _cn_ratio(text: str) -> float:
    """中文字幕倾向：汉字数 / (中文字+假名+字母)。日文假名多会压低这个比值。"""
    han = len(_CJK_CHAR.findall(text))
    kana = len(_KANA_CHAR.findall(text))
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    denom = han + kana + latin
    return han / denom if denom else 0.0


def _content_score(text: str, ext: str, film_sec: float,
                   site_duration: float = 0.0) -> tuple[int, list[str], dict]:
    """给字幕正文打「是不是这部片的完整中文好字幕」分（0-100）。纯本地。

    2026-11-20 评分改造 v2（用户两条反馈）：
      * 「时长只看覆盖率太粗暴，台词少的片是天然短板」——改用**分段覆盖**：
        把全片切 10 段，看有几段有 cue。台词稀疏但贯穿全片的字幕每段都有一两条，
        照样拿高分；只在开头密集、末尾插假 cue 的，只点亮少数段，露馅。
        同时 cue 条数不再因为「少」重扣——台词少不是字幕的错。
      * 「全中文但缺漏多也糟糕」「中文密度不准」——中文看逐条 cue 占比；
        真缺漏看**连续空段**（连续 >=3 段即 30% 片长完全无字幕）才封顶，
        而不是「单段空档 >25%」（台词稀疏的片 cue 间隔天然大，会被误伤）。
    site_duration（javzimu 站点片长）与本地片长互证：一致加分、矛盾扣分。
    """
    score = 0
    reasons: list[str] = []
    detail: dict = {}
    tl = _timeline(text, ext, film_sec)
    cues = tl["cues"]
    detail.update({
        "coverage": round(tl["coverage"], 1),   # 净覆盖秒数（仅展示，不硬判）
        "span": round(tl["span"], 1),
        "film": round(film_sec, 1),
        "site_duration": round(site_duration, 1),
        "cues": cues,
        "max_gap": round(tl["max_gap"], 1),
        "cn_cue_ratio": round(tl["cn_cue_ratio"], 3),
        "seg_hits": tl["seg_hits"],
        "seg_empty_run": tl["seg_empty_run"],
    })

    # ① 分段覆盖（满分 40）——台词少但贯穿全片 == 完整字幕，不按净覆盖率一刀切
    if film_sec > 0 and tl["seg_hits"] > 0:
        seg_ratio = tl["seg_hits"] / 10
        detail["seg_ratio"] = round(seg_ratio, 3)
        if seg_ratio >= 0.8:
            score += 40
            reasons.append(f"贯穿全片（{tl['seg_hits']}/10 时间段有字幕）")
        elif seg_ratio >= 0.6:
            score += 32
            reasons.append(f"覆盖较广（{tl['seg_hits']}/10 时间段）")
        elif seg_ratio >= 0.4:
            score += 22
            reasons.append(f"覆盖约半片（{tl['seg_hits']}/10 时间段）")
        elif seg_ratio >= 0.2:
            score += 10
            reasons.append(f"覆盖偏少（{tl['seg_hits']}/10 时间段）")
        else:
            score -= 3
            reasons.append("字幕只集中在开头少数片段")
        # 站点片长互证（javzimu 给时长时）：两边都认同一个片长更可信
        if site_duration > 0:
            site_diff = abs(site_duration - film_sec) / film_sec
            detail["duration_diff"] = round(site_diff, 3)
            if site_diff <= 0.05:
                score += 6
                reasons.append("站点片长与本地一致")
            elif site_diff > 0.25:
                score -= 8
                reasons.append("站点片长与本地不符")
    elif cues > 0:
        # 有字幕但缺时长数据（老库 runtime 空）：按活跃跨度给中性偏上的分，不误伤
        score += 20
        reasons.append("缺片长数据，未按时长判分")
    else:
        score -= 10
        reasons.append("解析不出字幕条目")

    # ② 中文密度（满分 25）——逐条 cue 判定，防止"全篇少量中文拉高比例"
    cue_cn = tl["cn_cue_ratio"]
    text_cn = _cn_ratio(text)
    detail["cn_ratio"] = round(text_cn, 3)
    if cue_cn >= 0.80:
        score += 25
        reasons.append(f"几乎每条都是中文（{int(cue_cn * 100)}% 条含中文）")
    elif cue_cn >= 0.60:
        score += 20
        reasons.append(f"中文为主（{int(cue_cn * 100)}% 条含中文）")
    elif cue_cn >= 0.40:
        score += 12
        reasons.append(f"约四成条目含中文（{int(cue_cn * 100)}%）")
    elif cue_cn >= 0.15:
        score += 6
        reasons.append(f"少量中文条目（{int(cue_cn * 100)}%）")
    else:
        reasons.append("绝大多数条目无中文")
        if text_cn >= 0.15:
            reasons.append(f"全文汉字占比 {int(text_cn * 100)}%，但集中在少数条目")

    # ③ cue 密度（满分 20）——只奖励"解析得到足量条目"，不再因条数少重扣：
    #    台词稀疏的片 cue 天然少，① 的分段覆盖已证明它是否完整，这里不重复惩罚。
    if cues > 0:
        per_min = cues / (film_sec / 60.0) if film_sec > 0 else 0.0
        detail["cues_per_min"] = round(per_min, 2)
        if per_min >= 2 or film_sec <= 0:
            score += 20
            reasons.append(f"字幕条目充足（{cues} 条）")
        elif per_min >= 0.5:
            score += 16
            reasons.append(f"条目偏少（{cues} 条），可能台词稀疏")
        else:
            score += 12
            reasons.append(f"条目稀少（{cues} 条）")
    else:
        score -= 10
        reasons.append("解析不出字幕条目")

    # ④ 解码健康度（满分 15）——乱码/半角片假名直接掉分
    quality = _score(text)
    detail["quality"] = round(quality, 3)
    if quality >= 0.5:
        score += 15
        reasons.append("解码正常")
    elif quality >= 0:
        score += 10
    elif quality >= -0.3:
        score += 4
        reasons.append("解码质量偏低")
    else:
        score -= 10
        reasons.append("疑似乱码")

    # ⑤ 真缺漏硬伤（用户 2026-11-20 修正）：连续 >=3 段（30% 片长）完全无 cue
    #    才封顶。旧的「单段空档>25%」会误伤台词稀疏片（cue 间隔天然大），
    #    连续空段才算"整段没翻译"，即使全中文也不当完整字幕选。
    if film_sec > 0 and tl["seg_empty_run"] >= 3:
        cap = 45
        if score > cap:
            score = cap
        reasons.append(f"连续 {tl['seg_empty_run']} 个时间段无字幕，判为缺漏字幕")

    return max(0, min(100, score)), reasons, detail


def _combined_score(number: str, title: str, cand: dict, text: str,
                    ext: str, film_sec: float) -> tuple[int, int, int, list[str], dict]:
    """元数据分 + 内容分 → 综合分。内容证据占 6 成，元数据占 4 成。"""
    meta, meta_reasons = _match_confidence(number, title, cand)
    site_dur = float(cand.get("site_duration") or 0)
    content, content_reasons, detail = _content_score(text, ext, film_sec, site_dur)
    combined = int(round(meta * 0.4 + content * 0.6))
    return combined, meta, content, meta_reasons + content_reasons, detail


def _all_cn_files() -> dict[tuple[int, str], str]:
    """已确认为中文的旁挂文件 → (item_id, filename) 集合。供全库扫描判重用。

    口径：owned 表里 source=online 且文件名带中文语言后缀（下载时按 _lang_tag 命名），
    或缓存里 lang=chi（_lang_of 判出来的）。用户自己放的 .chs.srt 也算「已有中文字幕」
    —— 这正是本次扫描要回答的问题，名字对就行，不追究是谁放的。
    """
    out: dict[tuple[int, str], str] = {}
    with A.user_db() as conn:
        for row in conn.execute(
                "SELECT item_id, filename, source, provider FROM subtitle_owned"):
            iid, fname = row[0], row[1]
            low = str(fname).lower()
            if any(tag in low for tag in _CN_TAGS):
                out[(iid, fname)] = "library"
    idx = STORE._index()
    with A.user_db() as conn:
        for row in conn.execute("SELECT subtitle_id, item_id FROM subtitle_item"):
            sid, iid = row[0], row[1]
            meta = idx.get(sid)
            if meta and meta.get("lang") == "chi":
                # 缓存没有「对应哪个库内文件」的信息，用 subtitle_id 作 key 的占位
                out[(iid, sid)] = "cache"
    return out


def _meta_sig(iid: int, mfiles: list, cn_files: dict) -> str:
    """算一部片的字幕状态签名 —— 三个信号都不 scandir，成本极低。

    照雪碧图「sprite.jpg 存在即命中」：签名没变就说明这部片的字幕状态没变，
    可以直接沿用旧结果，不必再走昂贵的 scandir。签名覆盖三类变化：
      ① 媒体文件映射目录的 mtime_ns / ino —— 用户往同目录放/删字幕会变；
      ② media_files 的内嵌/外挂标记 —— 上游重新入库会变；
      ③ owned / 缓存里的中文标记 —— 本系统自动下载或清缓存会变。
    stat 读不到目录（FUSE 抖动）时签名带 ERR，该片每次都重扫（保守，宁可多扫不漏报）。
    """
    parts: list[str] = []
    # ② DB 标记（内嵌/外挂），逐文件
    for f in mfiles:
        parts.append(f"m:{int(f[2] or 0)}:{int(f[3] or 0)}")
    # ① 目录 stat（纯元数据读取，比 scandir 枚举轻得多）；按目录去重
    dirs: set[str] = set()
    if STORE.path_map:
        for f in mfiles:
            real = STORE.map_path(str(f[1] or ""))
            if real:
                dirs.add(os.path.dirname(real))
    for folder in sorted(dirs):
        try:
            st = os.stat(folder)
            parts.append(f"d:{folder}:{st.st_mtime_ns}:{st.st_ino}")
        except OSError:
            parts.append(f"d:{folder}:ERR")
    # ③ owned / cache 中文标记
    lib = any(k[0] == iid and v == "library" for k, v in cn_files.items())
    cac = any(k[0] == iid and v == "cache" for k, v in cn_files.items())
    parts.append(f"cn:{int(lib)}:{int(cac)}")
    return "|".join(parts)


def _classify_meta(mfiles: list, dir_cache: dict, cn_files: dict,
                   iid: int) -> tuple[str, set[str], list[str]]:
    """判定一部片的字幕状态。返回 (status, langs, detail_parts)。

    dir_cache 跨片复用同目录的 scandir 结果；增量模式下只有签名变化的片会走到这里。
    """
    status = "none"
    langs: set[str] = set()
    detail_parts: list[str] = []

    # 1) 内嵌字幕：有就当「已有字幕」跳过（用户定的口径，语言未知不动它）
    if any((f[2] or 0) or (f[3] or 0) for f in mfiles):
        status = "embedded"
        langs.add("embedded")
        detail_parts.append("文件标记有内嵌/外挂字幕（语言未知）")

    # 2) 同目录外挂：按文件名后缀判语言（.chs / .eng ...）
    ext_cn = False
    ext_foreign = False
    if STORE.path_map:
        for f in mfiles:
            real = STORE.map_path(str(f[1] or ""))
            if not real:
                continue
            folder, stem = os.path.split(real)
            base = os.path.splitext(stem)[0]
            if not folder or base == "":
                continue
            if folder not in dir_cache:
                try:
                    with os.scandir(folder) as it:
                        dir_cache[folder] = [e.name for e in it
                                             if e.is_file()
                                             and os.path.splitext(e.name)[1].lower() in SUB_EXTS]
                except OSError:
                    dir_cache[folder] = []
            for name in dir_cache[folder]:
                nstem = os.path.splitext(name)[0]
                if nstem != base and not nstem.startswith(base + "."):
                    continue
                lang = _lang_of(name)
                low = name.lower()
                if lang == "chi" or any(t in low.split(".") for t in _CN_TAGS):
                    ext_cn = True
                    langs.add("chi")
                elif lang in ("jpn", "eng", "kor"):
                    ext_foreign = True
                    langs.add(lang)

    # 3) 旁挂自己下载的 + 缓存里挂在这部片的中文
    lib_cn = any(k[0] == iid and v == "library" for k, v in cn_files.items())
    cache_cn = any(k[0] == iid and v == "cache" for k, v in cn_files.items())

    if ext_cn or lib_cn or cache_cn:
        status = "cn"
        detail_parts.append("已有中文字幕")
    elif status == "none":
        if ext_foreign:
            status = "foreign"
            detail_parts.append("只有外文字幕")
        else:
            status = "none"
            detail_parts.append("未发现字幕")
    return status, langs, detail_parts


def _scan_health(progress=None, force: bool = False) -> dict:
    """扫全库字幕状态写 subtitle_health 快照。只读媒体卷，不联网。

    force=False（默认，增量）：按签名沿用状态未变的片，只为变化的片做 scandir ——
      照雪碧图「存在即命中」，首次预热全库、之后增量管理，避免每次 7805 部全扫。
    force=True（全量）：忽略签名重扫全部，供「强制全量」和老库升级（无签名表）时用。

    progress(done, total) 可选：后台扫描时回报进度给 _scan_state。
    """
    with A.amane_db() as conn:
        metas = conn.execute(
            "SELECT id, number, title FROM metadata ORDER BY id").fetchall()
        files = conn.execute(
            "SELECT metadata_id, path, has_subtitle_in_name, has_external_subtitle "
            "FROM media_files ORDER BY metadata_id, id").fetchall()
    by_meta: dict[int, list[sqlite3.Row]] = {}
    for f in files:
        by_meta.setdefault(f[0], []).append(f)

    cn_files = _all_cn_files()

    # 增量：读旧签名 + 旧结果行；老库没签名表就当全量重扫。
    old_sigs: dict[int, str] = {}
    old_rows: dict[int, tuple] = {}
    if not force:
        try:
            with A.user_db() as conn:
                for r in conn.execute("SELECT metadata_id, sig FROM subtitle_health_sig"):
                    old_sigs[int(r[0])] = str(r[1] or "")
                for r in conn.execute(
                        "SELECT metadata_id, number, title, status, langs, detail, checked_at "
                        "FROM subtitle_health"):
                    old_rows[int(r[0])] = tuple(r)
        except Exception:  # noqa: BLE001 - 表还没建（老库）→ 全量重扫
            old_sigs, old_rows = {}, {}

    counts = {"cn": 0, "foreign": 0, "none": 0, "embedded": 0}
    rows: list[tuple] = []
    sig_rows: list[tuple] = []
    reused = 0
    rescanned = 0
    dir_cache: dict[str, list[str]] = {}
    now = _now()
    total_metas = len(metas)
    if progress:
        progress(0, total_metas)

    for idx, m in enumerate(metas, 1):
        # 每 10 部报一次进度，避免频繁加锁；最后一部必报，保证能到 100%
        if progress and (idx % 10 == 0 or idx == total_metas):
            progress(idx, total_metas)
        iid, number, title = m[0], str(m[1] or ""), str(m[2] or "")
        mfiles = by_meta.get(iid, [])
        sig = _meta_sig(iid, mfiles, cn_files)

        # 签名命中 → 沿用旧行（只刷 checked_at 表示本次核对过），跳过 scandir
        if (not force and iid in old_sigs and old_sigs[iid] == sig
                and iid in old_rows):
            r = old_rows[iid]
            st = str(r[3] or "none")
            counts[st] = counts.get(st, 0) + 1
            rows.append((r[0], r[1], r[2], r[3], r[4], r[5], now))
            reused += 1
        else:
            status, langs, detail_parts = _classify_meta(mfiles, dir_cache, cn_files, iid)
            counts[status] += 1
            rows.append((iid, number, title, status,
                         json.dumps(sorted(langs), ensure_ascii=False),
                         "；".join(detail_parts), now))
            rescanned += 1
        sig_rows.append((iid, sig, now))

    with A.user_db() as conn:
        conn.execute("DELETE FROM subtitle_health")
        conn.executemany(
            "INSERT INTO subtitle_health(metadata_id, number, title, status, "
            "langs, detail, checked_at) VALUES(?,?,?,?,?,?,?)", rows)
        # 签名表写失败（老库缺表 / DDL 时序）不能拖垮主 health 表：
        # 主结果已经落库，签名缺失只意味着下一轮再全量一次，不影响用户看到结果。
        try:
            conn.execute("DELETE FROM subtitle_health_sig")
            conn.executemany(
                "INSERT INTO subtitle_health_sig(metadata_id, sig, checked_at) VALUES(?,?,?)",
                sig_rows)
        except sqlite3.OperationalError:
            pass
    return {"scanned": len(rows), "counts": counts, "checked_at": now,
            "dirs": len(dir_cache), "reused": reused, "rescanned": rescanned,
            "mode": "full" if force else "incremental"}


def _health_rows(limit: int = 0, offset: int = 0) -> tuple[list[dict], dict]:
    """读健康快照（是否过期由 meta.stale 告诉客户端，重扫由端点控制）。

    性能修复（2026-11-20）：全库约 7805 部，旧版把 **所有** item 一次性塞进 JSON，
    客户端 ForEach 全量 inflate 数万节点 → 慢且 OOM 闪退。改为分页：
      * limit <= 0 → 不限（仅内部/兼容用，端点默认给正数）；
      * limit > 0  → 只取该页 [offset, offset+limit)；
      * counts 始终基于**全库**单独 COUNT，不受分页影响，统计卡数字仍准确；
      * 按状态优先级排序（none→foreign→cn→embedded），让可操作的缺字幕片排前面。
    meta 额外带 total(全库数)/returned(本页条数)，供客户端「加载更多」判断是否到尾。
    """
    with A.user_db() as conn:
        row = conn.execute(
            "SELECT checked_at, COUNT(*) FROM subtitle_health").fetchone()
        total_health = row[1] if row else 0
        checked_at = (row[0] if row else "") or ""
        # 全库按状态统计（独立于本页，避免分页后统计卡数字变小）
        counts: dict[str, int] = {}
        if total_health:
            for st, n in conn.execute(
                    "SELECT status, COUNT(*) FROM subtitle_health GROUP BY status"):
                counts[st] = n
        out: list[dict] = []
        if total_health:
            sql = (
                "SELECT h.metadata_id, h.number, h.title, h.status, h.langs, h.detail, "
                "h.checked_at, "
                "CASE WHEN q.metadata_id IS NULL THEN '' ELSE q.state END AS qstate "
                "FROM subtitle_health h LEFT JOIN subtitle_search_queue q "
                "ON q.metadata_id = h.metadata_id "
                # 搜索失败/跳过的片沉底（用户 2026-11-20：保不齐就是没字幕，
                # 别让它永久占着首批位置挡住待处理片）。不删除，以后有字幕仍会被扫到。
                "ORDER BY CASE WHEN q.state IN ('failed','skipped') THEN 1 ELSE 0 END, "
                "CASE h.status WHEN 'none' THEN 0 WHEN 'foreign' THEN 1 "
                "WHEN 'cn' THEN 2 ELSE 3 END, h.metadata_id"
            )
            args: tuple = ()
            if limit > 0:
                sql += " LIMIT ? OFFSET ?"
                args = (limit, max(0, offset))
            rows = conn.execute(sql, args).fetchall()
            out = [{
                "metadata_id": r[0], "number": r[1], "title": r[2], "status": r[3],
                "langs": json.loads(r[4] or "[]"), "detail": r[5],
                "checked_at": r[6], "queue_state": r[7],
            } for r in rows]
    stale = (time.time() - _parse_iso(checked_at)) > _HEALTH_TTL if checked_at else True
    return out, {"scanned": total_health, "counts": counts, "checked_at": checked_at,
                 "stale": stale, "total": total_health, "returned": len(out)}


def _parse_iso(text: str) -> float:
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0.0


def _queue_rows() -> list[dict]:
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT metadata_id, number, state, lang, candidates, chosen, "
            "source, version, note, created_at, updated_at "
            "FROM subtitle_search_queue ORDER BY created_at DESC").fetchall()
    out: list[dict] = []
    for r in rows:
        try:
            cands = json.loads(r[4] or "[]")
        except (ValueError, TypeError):
            cands = []
        try:
            chosen = json.loads(r[5] or "null")
        except (ValueError, TypeError):
            chosen = None
        out.append({
            "metadata_id": r[0], "number": r[1], "state": r[2], "lang": r[3],
            "candidates": cands, "chosen": chosen, "source": r[6],
            "version": r[7], "note": r[8], "created_at": r[9], "updated_at": r[10],
        })
    return out


def subtitles_health(handler, query, *_):
    """全库健康快照（不联网）。?refresh=1 异步触发一次扫描，立即返回当前状态。

    扫描改后台线程（照雪碧图 warm 模式）：端点不再同步等 scandir 扫完，
    而是立刻回当前快照 + scanning 进度，客户端据此显示「正在扫描 x/y」并轮询。
    """
    refresh_raw = str((query.get("refresh") or [""])[0] or "").lower()
    force = refresh_raw in ("full", "all")       # ?refresh=full 强制全量重扫
    refresh = force or refresh_raw in ("1", "true", "yes")
    started = False
    if refresh:
        started = _kick_scan(force=force)        # 已在扫则不重复起，全量请求会排到本次之后
    else:
        # 进页面读快照：若缺失/过期且当前没在扫，顺手起一次后台扫描。
        # 这样即使 boot 预热那次错过，用户第一次点进来看见的也是「扫描中→很快有结果」，
        # 而不是永远空着等手动点。与雪碧图「进详情页就触发预热」同一思路。
        try:
            status_now = _scan_status()
            # 上次扫描报错就不再自动 kick（避免失败时每次轮询都重扫）；
            # 用户手动点「重新扫描」走 refresh 分支仍可重试。
            if _snapshot_stale() and not status_now["error"]:
                started = _kick_scan()
        except Exception:  # noqa: BLE001 - 探测失败当不 stale，不影响读快照
            pass
    # 分页：默认首批 500，上限 2000。客户端分批「加载更多」，避免一次 inflate 全库。
    # limit<=0 当作默认；非数字也退回默认，防御脏参数。
    try:
        limit = int(str((query.get("limit") or [""])[0] or ""))
    except (TypeError, ValueError):
        limit = 0
    if limit <= 0 or limit > 2000:
        limit = 500
    try:
        offset = int(str((query.get("offset") or [""])[0] or ""))
    except (TypeError, ValueError):
        offset = 0
    if offset < 0:
        offset = 0
    items, meta = _health_rows(limit=limit, offset=offset)
    status = _scan_status()
    meta["scanning"] = status["scanning"]
    meta["scan_done"] = status["done"]
    meta["scan_total"] = status["total"]
    meta["scan_error"] = status["error"]
    # 增量管理：让客户端看到「上次是增量还是全量、重扫几部、沿用几部」
    meta["scan_mode"] = status.get("mode", "incremental")
    meta["scan_reused"] = status.get("reused", 0)
    meta["scan_rescanned"] = status.get("rescanned", 0)
    handler._json({"items": items, "meta": meta, "started": started,
                   "states": list(_QUEUE_STATES),
                   "hint": "内嵌字幕按「已有」跳过；只有「无字幕」与「只有外文字幕」可入队"})


def subtitles_queue(handler, query, *_):
    """搜索队列列表。按 state 过滤。"""
    state = (query.get("state") or [""])[0]
    rows = _queue_rows()
    if state:
        rows = [r for r in rows if r["state"] == state]
    counts: dict[str, int] = {}
    for r in _queue_rows():
        counts[r["state"]] = counts.get(r["state"], 0) + 1
    handler._json({"items": rows, "counts": counts})


def subtitles_queue_add(handler, query, *_):
    """批量把缺字幕的片加入搜索队列。只接受 none / foreign，且不联网。"""
    body = handler._body()
    ids = body.get("ids") or []
    lang = str(body.get("lang") or "chs")
    if not isinstance(ids, list) or not ids:
        handler._error(422, "ids 必须是非空数组")
        return
    clean: list[int] = []
    for v in ids[:500]:                 # 一次最多 500，防误操作把整库塞进去
        try:
            iv = int(v)
        except (TypeError, ValueError):
            continue
        if iv > 0 and iv not in clean:
            clean.append(iv)
    with A.user_db() as conn:
        health = {r[0]: r[1] for r in conn.execute(
            "SELECT metadata_id, status FROM subtitle_health")}
    added: list[int] = []
    skipped: list[dict] = []
    for iid in clean:
        st = health.get(iid)
        if st not in ("none", "foreign"):
            skipped.append({"metadata_id": iid, "reason": f"状态 {st or '未扫描'}，不入队"})
            continue
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO subtitle_search_queue(metadata_id, number, state, lang, "
                "candidates, chosen, source, version, note, created_at, updated_at) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(metadata_id) DO UPDATE SET "
                "lang=excluded.lang, updated_at=excluded.updated_at",
                (iid, "", "queued", lang, "[]", "null", "", "", "", _now(), _now()))
        added.append(iid)
    handler._json({"ok": True, "added": added, "skipped": skipped,
                   "added_count": len(added)})


def subtitles_queue_set(handler, query, *_):
    """改队列项状态（skip / requeue / remove），纯本地操作。"""
    body = handler._body()
    try:
        iid = int(body.get("metadata_id") or 0)
    except (TypeError, ValueError):
        iid = 0
    action = str(body.get("action") or "")
    if not iid or action not in ("skip", "requeue", "remove", "fail"):
        handler._error(422, "metadata_id 与合法 action 必填")
        return
    with A.user_db() as conn:
        if action == "remove":
            conn.execute("DELETE FROM subtitle_search_queue WHERE metadata_id=?", (iid,))
        else:
            state = {"skip": "skipped", "requeue": "queued", "fail": "failed"}[action]
            conn.execute(
                "UPDATE subtitle_search_queue SET state=?, updated_at=? WHERE metadata_id=?",
                (state, _now(), iid))
    handler._json({"ok": True, "metadata_id": iid, "action": action})


def subtitles_queue_clear_dead(handler, query, *_):
    """清掉队列里所有 failed/skipped 项（用户 2026-11-20：搜不到就是没字幕，
    别让它们永久占位）。只删这两种终态，queued/matched/confirmed 一律保留。
    删除队列项不影响已落库的字幕，健康快照下次增量扫描照常重新发现。"""
    body = handler._body()
    states = body.get("states") or ["failed", "skipped"]
    if not isinstance(states, list) or not states:
        states = ["failed", "skipped"]
    allowed = {"failed": "failed", "skipped": "skipped"}
    wanted = [allowed[s] for s in states if isinstance(s, str) and s in allowed]
    if not wanted:
        wanted = ["failed", "skipped"]
    marks = ",".join("?" for _ in wanted)
    with A.user_db() as conn:
        cur = conn.execute(
            f"DELETE FROM subtitle_search_queue WHERE state IN ({marks})", tuple(wanted))
        removed = cur.rowcount if cur.rowcount is not None else 0
    handler._json({"ok": True, "removed": int(removed)})


def subtitles_queue_match(handler, query, *_):
    """把已缓存的在线搜索结果按番号/语言/文件名算置信度。不联网。

    在线搜索本身仍走既有 /subtitles/search（用户主动点、沿用 PROVIDERS、不绕验证码），
    这一步只做本地打分，方便批量队列统一排序与确认。
    """
    body = handler._body()
    try:
        iid = int(body.get("metadata_id") or 0)
    except (TypeError, ValueError):
        iid = 0
    items = body.get("items")
    if not iid or not isinstance(items, list):
        handler._error(422, "metadata_id 与 items 必填")
        return
    with A.amane_db() as conn:
        row = conn.execute("SELECT number, title FROM metadata WHERE id=?", (iid,)).fetchone()
    number = str(row[0] or "") if row else ""
    title = str(row[1] or "") if row else ""
    ranked: list[dict] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        conf, reasons = _match_confidence(number, title, it)
        ranked.append({**it, "confidence": conf, "reasons": reasons})
    ranked.sort(key=lambda x: (-int(x.get("confidence") or 0),
                               str(x.get("provider") or "")))
    with A.user_db() as conn:
        conn.execute(
            "UPDATE subtitle_search_queue SET candidates=?, state=?, updated_at=? "
            "WHERE metadata_id=?",
            (json.dumps(ranked, ensure_ascii=False),
             "matched" if ranked else "queued", _now(), iid))
    handler._json({"ok": True, "metadata_id": iid, "number": number,
                   "candidates": ranked})


def subtitles_queue_confirm(handler, query, *_):
    """用户确认某候选后下载（复用 save 的落盘逻辑），记版本，标记队列。

    这里**只在用户点确认后**由客户端调用；服务端不会自动下载任何在线字幕。
    直接复用 subtitles_save 的核心：临时伪造 body？—— 不，抽一个共用落盘函数更干净，
    但 save 里的网络细节多，改成客户端先调 /save 成功后调本端点只记「已确认」。
    """
    body = handler._body()
    try:
        iid = int(body.get("metadata_id") or 0)
    except (TypeError, ValueError):
        iid = 0
    if not iid:
        handler._error(422, "metadata_id 必填")
        return
    chosen = body.get("chosen") if isinstance(body.get("chosen"), dict) else None
    version = str(body.get("version") or _now())
    provider = str((chosen or {}).get("provider") or "")
    name = str((chosen or {}).get("name") or "")
    with A.user_db() as conn:
        conn.execute(
            "UPDATE subtitle_search_queue SET state='confirmed', chosen=?, "
            "source=?, version=?, updated_at=? WHERE metadata_id=?",
            (json.dumps(chosen, ensure_ascii=False) if chosen else "null",
             provider, version, _now(), iid))
    _version_log(iid, name, "online", provider, "", "added")
    handler._json({"ok": True, "metadata_id": iid, "state": "confirmed"})


def _auto_core(iid: int, per_source: int, min_score: int, prefer_lang: str,
               dry_run: bool) -> dict:
    """自动补的核心计算（搜两源→临时下载→打分→落库），返回结果 dict。

    与 handler 解耦：由后台任务线程 _auto_task_worker 调用，进度/结果由任务层写表。
    守住三条底线：用户主动触发、不内置账号/Key、遇 429/验证码跳过该源不绕过。
    打分 = 元数据×0.4 + 内容证据×0.6；最高分 < min_score 不写盘。
    """
    with A.amane_db() as conn:
        row = conn.execute(
            "SELECT number, title, runtime FROM metadata WHERE id=?", (iid,)).fetchone()
    number = str(row[0] or "") if row else ""
    title = str(row[1] or "") if row else ""
    film_sec = 0.0
    if row and row[2]:
        try:
            film_sec = float(row[2]) * 60.0
        except (TypeError, ValueError):
            film_sec = 0.0
    if not number:
        return {"ok": False, "reason": "该条目没有番号，无法自动搜索",
                "chosen": None, "source_status": [], "errors": []}

    import threading

    # ① 并发搜索两个源（与 /subtitles/search 同一条链，不绕验证码）
    found: list[dict] = []
    errors: list[dict] = []
    # 逐源状态（2026-11-20）：用户问「javzimu 没让我输验证码，是没搜吗」——
    # 这里如实记每个源搜到几条 / 为什么失败。结果页展示，不再让用户猜。
    source_status: list[dict] = []
    lock = threading.Lock()

    def run(provider: dict) -> None:
        try:
            got = provider["fn"](number)
        except Exception as exc:  # noqa: BLE001 - 单源失败不拖垮整次任务
            msg = str(exc)[:160]
            captcha = "验证码" in msg or "captcha" in msg.lower()
            limited = "429" in msg or "限流" in msg
            with lock:
                errors.append({"provider": provider["id"], "kind": "search", "error": msg,
                               "captcha": captcha, "rate_limited": limited})
                source_status.append({"provider": provider["id"],
                                      "name": provider["name"], "found": 0,
                                      "ok": False, "error": msg,
                                      "captcha": captcha, "rate_limited": limited})
            return
        with lock:
            found.extend(got[:per_source])
            source_status.append({"provider": provider["id"],
                                  "name": provider["name"], "found": len(got),
                                  "ok": True, "error": ""})

    threads = [threading.Thread(target=run, args=(p,), daemon=True) for p in PROVIDERS]
    for t in threads:
        t.start()
    for t in threads:
        t.join(SEARCH_TIMEOUT + 2)

    # JAV字幕因验证码被挡的明确信号（2026-11-20 23:40）：不再静默跳过。
    # 客户端据此引导用户「验证一次后重试」，而不是误以为 JAV 没这个字幕。
    jav_hint = ""
    if any(s.get("provider") == "javzimu" and s.get("captcha")
           for s in source_status):
        jav_hint = "JAV字幕需验证码：本次已跳过该源；请先验证一次再重试，以纳入 JAV 候选"

    if not found:
        reason = ("只有 JAV字幕因验证码被挡，迅雷也没搜到"
                  if jav_hint else "两个来源都没有搜到候选")
        return {"ok": False, "reason": reason,
                "errors": errors, "source_status": source_status,
                "javzimu_hint": jav_hint, "tried": 0, "chosen": None}

    # 语言偏好：用户在队列里选了中文就把中文候选排前（同分时的优先顺序）
    if prefer_lang:
        for it in found:
            blob = (str(it.get("lang") or "") + " " + str(it.get("name") or "")).lower()
            it["_prefer"] = 1 if prefer_lang.lower() in blob else 0
    else:
        for it in found:
            it["_prefer"] = 0

    # ② 逐条临时下到内存并打分（串行，控制对站点的压力；只下前 N 条）
    evaluated: list[dict] = []
    for cand in found:
        provider = str(cand.get("provider") or "")
        name = str(cand.get("name") or "subtitle.srt")
        lang = str(cand.get("lang") or "")
        try:
            ref = _ref_payload(str(cand.get("ref") or ""))
        except ValueError as exc:
            with lock:
                errors.append({"provider": provider, "kind": "ref", "name": name,
                               "error": str(exc)[:160]})
            continue
        link = ref.get("url") or ""
        referer = SITE_REFERER.get(provider) or ""
        try:
            if not link and ref.get("detail"):
                link = _zimucat_pick(str(ref["detail"]))
                referer = str(ref["detail"])
            if not link:
                raise RuntimeError("这条候选没有下载地址")
            _warm_site(provider)
            raw = _fetch(str(link), timeout=FETCH_TIMEOUT, referer=referer)
            if len(raw) > MAX_SUB_BYTES:
                raise RuntimeError("字幕超过 2 MiB，跳过")
            raw, real_name = _unwrap_archive(raw, name)
            ext = _safe_ext(real_name) or _safe_ext(str(link)) or ".srt"
            text, encoding = _decode_with(raw)
            if not text.strip():
                raise RuntimeError("解码后内容为空")
        except urllib.error.HTTPError as exc:
            code = exc.code
            msg = f"下载 HTTP {code}"
            if code == 429 or "限流" in msg:
                msg = "限流（429），本源本轮跳过"
            with lock:
                errors.append({"provider": provider, "kind": "download", "name": name,
                               "error": msg, "rate_limited": code == 429})
            continue
        except Exception as exc:  # noqa: BLE001
            with lock:
                errors.append({"provider": provider, "kind": "download", "name": name,
                               "error": str(exc)[:160]})
            continue

        combined, meta, content, reasons, detail = _combined_score(
            number, title, cand, text, ext, film_sec)
        evaluated.append({
            "provider": provider, "name": real_name, "lang": lang,
            "ref": cand.get("ref") or "", "combo": combined, "meta": meta,
            "content": content, "reasons": reasons, "detail": detail,
            "prefer": int(cand.get("_prefer") or 0), "encoding": encoding,
            "raw": raw, "ext": ext, "text": text,
        })

    if not evaluated:
        return {"ok": False, "reason": "候选全部下载失败",
                "errors": errors, "source_status": source_status,
                "tried": len(found), "chosen": None}

    # ③ 选最优：综合分优先，同分看语言偏好，再同分看内容分
    evaluated.sort(key=lambda x: (-x["combo"], -x["prefer"], -x["content"]))
    best = evaluated[0]
    ranked = [{
        "provider": e["provider"], "name": e["name"], "lang": e["lang"],
        "score": e["combo"], "meta": e["meta"], "content": e["content"],
        "reasons": e["reasons"], "detail": e["detail"],
    } for e in evaluated]

    if best["combo"] < min_score:
        return {"ok": False, "reason": f"最高分 {best['combo']} 低于阈值 {min_score}，"
                "为避免下错片没有落库", "tried": len(found),
                "best": ranked[0], "ranked": ranked, "errors": errors,
                "source_status": source_status, "chosen": None}

    chosen_info = {
        "provider": best["provider"], "name": best["name"], "lang": best["lang"],
        "score": best["combo"], "meta": best["meta"], "content": best["content"],
        "reasons": best["reasons"], "detail": best["detail"],
    }

    if dry_run:
        return {"ok": True, "dry_run": True, "tried": len(found),
                "chosen": chosen_info, "ranked": ranked, "errors": errors,
                "source_status": source_status}

    # ④ 落库 + 推本地媒体目录（复用 save 的同一条链）
    result = _persist_online(iid, best["provider"], best["lang"], best["name"],
                             best["raw"], best["ext"], best["text"], best["encoding"])
    result.update({
        "ok": True, "auto": True, "tried": len(found),
        "score": best["combo"], "meta": best["meta"], "content": best["content"],
        "reasons": best["reasons"], "detail": best["detail"],
        "ranked": ranked, "errors": errors, "chosen": chosen_info,
        "source_status": source_status,
    })
    # 队列若在，标记为已确认（自动完成，无需用户再点确认）
    try:
        with A.user_db() as conn:
            conn.execute(
                "UPDATE subtitle_search_queue SET state='confirmed', chosen=?, source=?, "
                "version=?, updated_at=? WHERE metadata_id=?",
                (json.dumps(chosen_info, ensure_ascii=False), best["provider"],
                 _now(), _now(), iid))
    except sqlite3.Error as exc:  # noqa: F841 - 队列不存在也不影响落库
        A.log(f"WARN 自动获取更新队列失败: {exc}")
    return result


# ---- 自动补任务（持久化 + 进度可见，2026-11-20 23:40）----------------- #
# 用户反馈：原 auto 是同步长任务，退出页面就看不到进度、结果只在内存、进程重启全丢。
# 改为任务表持久化：提交即返回 task_id，后台线程跑，进度/结果写表，重启标记 interrupted。
_AUTO_TASKS: dict[int, dict] = {}   # 任务参数缓存（进程内；结果落表，重启读表补状态）
_AUTO_LOCK = threading.Lock()
_AUTO_STOP: set[int] = set()        # 用户取消的任务 id


def _auto_task_worker(task_id: int, params: dict) -> None:
    """后台跑一个自动补任务（单部或批量），每部完成即写回进度与结果到任务表。"""
    item_ids: list[int] = params.get("item_ids", [])
    results: list[dict] = []
    ok_count = 0
    total = len(item_ids)
    try:
        _auto_task_update(task_id, state="running", total=total, done=0)
        for idx, iid in enumerate(item_ids):
            if task_id in _AUTO_STOP:
                break
            try:
                res = _auto_core(iid, params.get("per_source", 3),
                                 params.get("min_score", 60),
                                 params.get("lang", ""), False)
            except Exception as exc:  # noqa: BLE001 - 单部失败不拖垮整批
                res = {"ok": False, "reason": f"执行异常：{str(exc)[:160]}",
                       "chosen": None, "errors": [], "source_status": []}
            label = _auto_label(iid)
            results.append({
                "item_id": iid, "number": label.get("number", ""),
                "title": label.get("title", ""), "result": res,
            })
            if res.get("ok") and res.get("chosen"):
                ok_count += 1
            _auto_task_update(task_id, done=idx + 1, ok_count=ok_count,
                              results=results)
        state = "cancelled" if task_id in _AUTO_STOP else "done"
        _auto_task_update(task_id, state=state, finished_at=_now())
        # 用户要「补完实时更新库」：任务结束后触发一次健康增量重扫，
        # 签名机制会自动发现刚落库的字幕，客户端下次读快照即最新状态。
        if ok_count > 0 and not _scan_status()["scanning"]:
            _kick_scan(force=False)
    except Exception as exc:  # noqa: BLE001 - 后台线程异常不能冒到请求线程
        _auto_task_update(task_id, state="failed", error=str(exc)[:200],
                          finished_at=_now())
        A.log(f"WARN 自动补后台任务 {task_id} 失败: {exc}")
    finally:
        with _AUTO_LOCK:
            _AUTO_TASKS.pop(task_id, None)
            _AUTO_STOP.discard(task_id)


def _auto_label(iid: int) -> dict:
    """从 metadata 取番号/标题，给任务结果里的每部片贴标签。"""
    try:
        with A.amane_db() as conn:
            row = conn.execute(
                "SELECT number, title FROM metadata WHERE id=?", (iid,)).fetchone()
        if row:
            return {"number": str(row[0] or ""), "title": str(row[1] or "")}
    except sqlite3.Error:
        pass
    return {"number": "", "title": f"#{iid}"}


def _auto_task_insert(state: str, scope: str, total: int, note: str = "") -> int:
    with A.user_db() as conn:
        cur = conn.execute(
            "INSERT INTO subtitle_auto_task "
            "(state, scope, total, done, ok_count, results, note, created_at, updated_at) "
            "VALUES(?,?,?,0,0,'[]',?,?,?)",
            (state, scope, total, note, _now(), _now()))
        return int(cur.lastrowid)


def _auto_task_update(task_id: int, **fields) -> None:
    """增量更新任务字段；results 传 list 时 JSON 序列化。"""
    if not fields:
        return
    if "results" in fields and isinstance(fields["results"], list):
        fields["results"] = json.dumps(fields["results"], ensure_ascii=False)
    fields["updated_at"] = _now()
    sets = ", ".join(f"{k}=?" for k in fields)
    try:
        with A.user_db() as conn:
            conn.execute(f"UPDATE subtitle_auto_task SET {sets} WHERE id=?",
                         (*fields.values(), task_id))
    except sqlite3.Error as exc:
        A.log(f"WARN 自动补任务 {task_id} 写进度失败: {exc}")


def subtitles_auto(handler, query, *_):
    """提交自动补任务：校验后立即返回 task_id，实际工作在后台线程跑。

    单部 = item_id；批量 = item_ids 数组。提交后客户端不再阻塞、不再自动跳结果页，
    用 task_id 轮询进度；退出页面/重启服务任务仍在，进度可从任务表恢复。
    """
    body = handler._body()
    ids_raw = body.get("item_ids")
    if isinstance(ids_raw, list) and ids_raw:
        item_ids: list[int] = []
        for x in ids_raw[:200]:          # 单次批量上限 200，防误操作拉爆
            try:
                iid = int(x)
            except (TypeError, ValueError):
                continue
            if iid > 0 and iid not in item_ids:
                item_ids.append(iid)
    else:
        try:
            iid = int(body.get("item_id") or 0)
        except (TypeError, ValueError):
            iid = 0
        item_ids = [iid] if iid else []
    if not item_ids:
        handler._error(422, "item_id 或 item_ids 必填")
        return
    try:
        per_source = max(1, min(5, int(body.get("per_source") or 3)))
    except (TypeError, ValueError):
        per_source = 3
    try:
        min_score = max(0, min(100, int(body.get("min_score") or 60)))
    except (TypeError, ValueError):
        min_score = 60
    prefer_lang = str(body.get("lang") or "")

    scope = "batch" if len(item_ids) > 1 else "single"
    task_id = _auto_task_insert("queued", scope, len(item_ids),
                                "已提交，等待执行")
    params = {"item_ids": item_ids, "per_source": per_source,
              "min_score": min_score, "lang": prefer_lang}
    with _AUTO_LOCK:
        _AUTO_TASKS[task_id] = params
    t = threading.Thread(target=_auto_task_worker, args=(task_id, params),
                         name=f"subtitle-auto-{task_id}", daemon=True)
    t.start()
    handler._json({"ok": True, "task_id": task_id, "state": "queued",
                   "total": len(item_ids),
                   "hint": "任务已提交，可在任务中心查看进度；退出页面不会中断"})


def subtitles_auto_tasks(handler, query, *_):
    """任务列表：含进行中与历史，进度/结果都在，退出页面重进照样看得到。"""
    try:
        limit = max(1, min(200, int((query.get("limit") or ["50"])[0])))
    except (ValueError, TypeError):
        limit = 50
    with A.user_db() as conn:
        rows = conn.execute(
            "SELECT id, state, scope, total, done, ok_count, note, error, "
            "created_at, updated_at, finished_at FROM subtitle_auto_task "
            "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    items = [{
        "id": r[0], "state": r[1], "scope": r[2], "total": r[3], "done": r[4],
        "ok_count": r[5], "note": r[6] or "", "error": r[7] or "",
        "created_at": r[8], "updated_at": r[9], "finished_at": r[10] or "",
    } for r in rows]
    active = sum(1 for x in items if x["state"] in ("queued", "running"))
    handler._json({"items": items, "active": active})


def subtitles_auto_task(handler, query, *_):
    """单个任务详情（含每部结果）。客户端轮询这个看进度与最终结果。"""
    try:
        task_id = int((query.get("id") or ["0"])[0])
    except (ValueError, TypeError):
        task_id = 0
    with A.user_db() as conn:
        row = conn.execute(
            "SELECT id, state, scope, total, done, ok_count, results, note, error, "
            "created_at, updated_at, finished_at FROM subtitle_auto_task WHERE id=?",
            (task_id,)).fetchone()
    if not row:
        handler._error(404, "任务不存在")
        return
    try:
        results = json.loads(row[6] or "[]")
    except (ValueError, TypeError):
        results = []
    handler._json({
        "id": row[0], "state": row[1], "scope": row[2], "total": row[3],
        "done": row[4], "ok_count": row[5], "results": results,
        "note": row[7] or "", "error": row[8] or "",
        "created_at": row[9], "updated_at": row[10], "finished_at": row[11] or "",
    })


def subtitles_auto_task_cancel(handler, query, *_):
    """取消任务：仅对排队/运行中有效。后台线程下一步检测到停止标记即停。"""
    body = handler._body()
    try:
        task_id = int(body.get("task_id") or 0)
    except (TypeError, ValueError):
        task_id = 0
    with A.user_db() as conn:
        row = conn.execute("SELECT state FROM subtitle_auto_task WHERE id=?",
                           (task_id,)).fetchone()
    if not row:
        handler._error(404, "任务不存在")
        return
    if row[0] not in ("queued", "running"):
        handler._json({"ok": False, "reason": "任务已结束，无需取消"})
        return
    _AUTO_STOP.add(task_id)
    _auto_task_update(task_id, state="cancelled", note="用户已取消", finished_at=_now())
    handler._json({"ok": True, "task_id": task_id, "state": "cancelled"})


def subtitles_versions(handler, query, *_):
    """来源与版本历史，供「替换 / 恢复」查看与回溯。"""
    try:
        iid = int((query.get("item_id") or ["0"])[0])
    except (ValueError, TypeError):
        iid = 0
    with A.user_db() as conn:
        if iid:
            rows = conn.execute(
                "SELECT id, item_id, filename, source, provider, sid, action, created_at "
                "FROM subtitle_version WHERE item_id=? ORDER BY id DESC", (iid,)).fetchall()
        else:
            rows = conn.execute(
                "SELECT id, item_id, filename, source, provider, sid, action, created_at "
                "FROM subtitle_version ORDER BY id DESC LIMIT 200").fetchall()
    handler._json({"items": [{
        "id": r[0], "item_id": r[1], "filename": r[2], "source": r[3],
        "provider": r[4], "sid": r[5], "action": r[6], "created_at": r[7],
    } for r in rows]})


def _captcha_proxied(path: str, body: dict | None = None) -> dict:
    """转一手 javzimu 的验证码：挑战是 SVG（data URI），校验是 POST。"""
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = _browser_headers()
    if data:
        headers["Content-Type"] = "application/json"
        headers["Origin"] = "https://javzimu.com"
    req = Request("https://javzimu.com" + path, data=data, headers=headers)
    with _session_opener().open(req, timeout=12) as resp:
        return json.loads(resp.read(30000).decode("utf-8", "replace"))


def subtitles_captcha_challenge(handler, query, *_):
    """把验证码图取回来交给客户端显示 —— 用户在我们的界面里输一次，不用开浏览器。"""
    try:
        data = _captcha_proxied("/api/captcha/challenge")
    except Exception as exc:  # noqa: BLE001
        handler._error(502, f"取验证码失败: {exc}")
        return
    handler._json({"captchaId": str(data.get("captchaId") or ""),
                   "image": str(data.get("image") or "")})


def subtitles_captcha_verify(handler, query, *_):
    body = handler._body()
    captcha_id = str(body.get("captchaId") or "").strip()
    answer = str(body.get("answer") or "").strip()
    if not captcha_id or not answer:
        handler._error(422, "captchaId 与 answer 必填")
        return
    try:
        data = _captcha_proxied("/api/captcha/verify",
                                {"captchaId": captcha_id, "answer": answer})
    except Exception as exc:  # noqa: BLE001
        handler._error(502, f"验证失败: {exc}")
        return
    success = bool(data.get("success"))
    remaining = int(data.get("remaining") or 0)
    if success:
        # 验证通过后 CookieJar 里有了 clearance，同一进程内 javzimu 搜索即可用；
        # 记下状态给自动补任务与客户端状态条读（搜索函数不再静默跳过该源）。
        _JAVZIMU_STATE.update(verified=True, remaining=remaining,
                              verified_at=_now(), last_error="")
    handler._json({"ok": success, "remaining": remaining})


def subtitles_javzimu_status(handler, query, *_):
    """JAV字幕会话状态：客户端在自动补前判断是否要先让用户验证。"""
    handler._json(_javzimu_status())


ROUTES = [
    ("GET", r"/api/user/subtitles/search", subtitles_search),
    ("GET", r"/api/user/subtitles/captcha", subtitles_captcha_challenge),
    ("POST", r"/api/user/subtitles/captcha", subtitles_captcha_verify),
    ("GET", r"/api/user/subtitles/javzimu/status", subtitles_javzimu_status),
    ("POST", r"/api/user/subtitles/save", subtitles_save),
    ("POST", r"/api/user/subtitles/auto", subtitles_auto),
    ("GET", r"/api/user/subtitles/auto/tasks", subtitles_auto_tasks),
    ("GET", r"/api/user/subtitles/auto/task", subtitles_auto_task),
    ("POST", r"/api/user/subtitles/auto/task/cancel", subtitles_auto_task_cancel),
    ("GET", r"/api/user/subtitles/owned", subtitles_owned),
    ("DELETE", r"/api/user/subtitles/owned", subtitles_owned_delete),
    ("GET", r"/api/user/subtitles/health", subtitles_health),
    ("GET", r"/api/user/subtitles/queue", subtitles_queue),
    ("POST", r"/api/user/subtitles/queue/add", subtitles_queue_add),
    ("POST", r"/api/user/subtitles/queue/set", subtitles_queue_set),
    ("POST", r"/api/user/subtitles/queue/clear-dead", subtitles_queue_clear_dead),
    ("POST", r"/api/user/subtitles/queue/match", subtitles_queue_match),
    ("POST", r"/api/user/subtitles/queue/confirm", subtitles_queue_confirm),
    ("GET", r"/api/user/subtitles/versions", subtitles_versions),
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
    # 只登记「旁挂自己下载写进库的」字幕：删除接口只认这张表，
    # 用户自己放的同名字幕永远不进这里，也就永远删不到。
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_owned ("
        " item_id INTEGER NOT NULL,"
        " filename TEXT NOT NULL,"
        " source TEXT NOT NULL,"
        " provider TEXT NOT NULL,"
        " created_at TEXT NOT NULL,"
        " PRIMARY KEY(item_id, filename));")
    # 字幕自动化管理中心：三张独立表，老库平滑升级，不动上面任何既有表结构
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_health ("
        " metadata_id INTEGER PRIMARY KEY,"
        " number TEXT, title TEXT, status TEXT,"
        " langs TEXT, detail TEXT, checked_at TEXT);")
    # 增量签名表：每部片一个签名，签名未变就沿用上一轮健康结果（跳过昂贵 scandir）。
    # 独立于 subtitle_health，老库平滑升级（表不存在 → _scan_health 当全量重扫一次）。
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_health_sig ("
        " metadata_id INTEGER PRIMARY KEY,"
        " sig TEXT NOT NULL, checked_at TEXT);")
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_search_queue ("
        " metadata_id INTEGER PRIMARY KEY,"
        " number TEXT, state TEXT, lang TEXT,"
        " candidates TEXT, chosen TEXT, source TEXT, version TEXT, note TEXT,"
        " created_at TEXT, updated_at TEXT);")
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_version ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " item_id INTEGER NOT NULL, filename TEXT, source TEXT, provider TEXT,"
        " sid TEXT, action TEXT, created_at TEXT);")
    # 自动补任务表（2026-11-20 23:40）：提交即返回，后台跑，进度/结果落表。
    # 退出页面重进、甚至服务重启都能看到任务状态——不再是「退出就没了」。
    api.add_ddl(
        "CREATE TABLE IF NOT EXISTS subtitle_auto_task ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " state TEXT NOT NULL, scope TEXT, total INTEGER DEFAULT 0,"
        " done INTEGER DEFAULT 0, ok_count INTEGER DEFAULT 0,"
        " results TEXT, note TEXT, error TEXT,"
        " created_at TEXT, updated_at TEXT, finished_at TEXT);")
    # 重启恢复：上次进程里还在跑/排队的任务，重启后线程没了 → 标 interrupted，
    # 不假装「进行中」骗用户；已完成/取消/失败的原样保留供回看。
    try:
        with A.user_db() as conn:
            conn.execute(
                "UPDATE subtitle_auto_task SET state='interrupted', "
                "note='服务重启，任务已中断（可重新提交）', updated_at=? "
                "WHERE state IN ('queued','running')", (_now(),))
    except sqlite3.Error:
        pass
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 subtitles 已启用（{len(ROUTES)} 个端点）")

    # 预热（照雪碧图 warm 常驻模式）：服务起来后延迟几秒扫一次，
    # 之后每 5 分钟做一次增量保鲜 —— 只有签名变化的片才 scandir，成本极低。
    # 这样用户第一次进「字幕管理」就有结果，之后手工放字幕/自动下载也能被逐步发现。
    # 写的是 subtitle_health / subtitle_health_sig 两张固定行数表（每部片一行，
    # DELETE 后重写），行数 = metadata 数，不产生增长文件，无需额外清理策略。
    def _warm_loop() -> None:
        global _warmed_once
        time.sleep(3)                        # 让主服务先把表/索引建完
        if _warmed_once:
            return
        _warmed_once = True
        first = True
        while True:
            try:
                # 首轮：快照缺失才全量（老库无签名表）；已有快照就走增量。
                # 之后每轮都做增量保鲜：增量只 stat + 签名比对，仅变化的片 scandir，
                # 成本远低于全量，不用 TTL 门控（否则新鲜快照永远等不到增量发现新字幕）。
                force = first and _snapshot_stale()
                if not _scan_status()["scanning"]:
                    _kick_scan(force=force)
                first = False
            except Exception as exc:  # noqa: BLE001 - 预热失败不影响扩展启用
                api.log(f"扩展 subtitles 后台预热跳过: {exc}")
            time.sleep(_HEALTH_WARM_INTERVAL)

    threading.Thread(target=_warm_loop, name="subtitle-health-warm-loop", daemon=True).start()
    return {"id": "subtitles", "enabled": True, "scope": "public"}
