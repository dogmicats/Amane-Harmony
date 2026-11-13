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
import http.cookiejar
import io
import json
import os
import sqlite3
import re
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
            raise RuntimeError("站点启用了搜索验证码，暂不可用") from exc
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
        out.append(_item("javzimu", name or q, str(it.get("language") or ""), ext,
                         {"url": link, "ts": ts, "sig": sig}))
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

    stats = _cue_stats(text, ext)
    handler._json({
        "ok": True,
        # library = 已写进视频目录；cache = 卷不可写，只有缓存
        "kind": "library" if written else "cache",
        "files": written,
        "reason": "" if written else (reason or "媒体目录不可写"),
        "subtitle_id": item["id"],
        "lang": tag,
        "name": item["name"],
        # 解析统计 + 实际采用的编码：客户端据此告诉用户「这条字幕能不能解析出来」
        # 以及「它是 GBK 还是 UTF-16」，把「字幕烂」和「字幕控件不显示」分开
        "cues": stats["cues"],
        "sample": stats["sample"],
        "encoding": encoding,
    })


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
    handler._json({"ok": True, "removed": removed, "name": filename})


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
    handler._json({"ok": bool(data.get("success")),
                   "remaining": int(data.get("remaining") or 0)})


ROUTES = [
    ("GET", r"/api/user/subtitles/search", subtitles_search),
    ("GET", r"/api/user/subtitles/captcha", subtitles_captcha_challenge),
    ("POST", r"/api/user/subtitles/captcha", subtitles_captcha_verify),
    ("POST", r"/api/user/subtitles/save", subtitles_save),
    ("GET", r"/api/user/subtitles/owned", subtitles_owned),
    ("DELETE", r"/api/user/subtitles/owned", subtitles_owned_delete),
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
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.log(f"扩展 subtitles 已启用（{len(ROUTES)} 个端点）")
    return {"id": "subtitles", "enabled": True, "scope": "public"}
