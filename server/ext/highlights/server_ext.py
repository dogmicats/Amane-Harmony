#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开扩展：影片亮点（随机位置抽帧缩略图，点一下从那一秒起播，scope=public）。

详情页原来只有一张封面和一堆外部剧照 —— 那些图是刮削来的，和片子里到底拍了什么
没关系。「亮点」要的是**这部片自己的画面**：在片长里均匀撒 N 个点，每个点抽一帧
当缩略图，按时间升序排成一条，点哪张就从哪一秒开始播。

两个端点：

    GET /api/user/highlights/{metadata_id}?n=8&file=f123&seed=0
        → {"ok":true,"file_id":123,"duration":7102.5,"items":[{"t":412,"ms":412000,...}],
           "pending":2}
    GET /api/user/highlights/{file_id}/{ms}.jpg
        → image/jpeg（本地缓存，命中直接回字节）

几条落地的经验（都是这里踩出来的，别重新拍脑袋）：

  1. **抽帧靠 ffmpeg，容器自带的 slim 镜像没有**：默认在 PATH 里找，找不到再看
     `/data/bin/ffmpeg`（data 卷是持久化的，静态构建扔进去就一直在）；路径也能在
     highlights.json 里写死。一个都找不到就 `ok:false`，客户端整块隐藏 —— 亮点是锦上添花，
     没有 ffmpeg 不该让详情页报错。
  2. **位置要「随机但不扎堆」**：把片长切成 N 段，每段里随机取一点再排序。纯 random()
     会出现两张缩略图差 3 秒的情况，一排看过去像同一帧。
  3. **seek 一律 `-ss` 放在 `-i` 前面**（输入侧快速 seek，只读关键帧那一段），
     网盘挂载（CD2 FUSE）上比输出侧 seek 快一个数量级。mp4 的 moov 在尾部，
     头一次打开会先读索引，所以单帧超时给得比较宽（默认 14s）。
  4. **一次请求不等齐**：并发抽帧，超过预算（默认 8s）就先把已出的图返回，剩的留后台继续，
     `pending` 告诉客户端还有几张 —— 下次请求直接命中磁盘缓存，不会再跑 ffmpeg。
  5. **缓存按 (file_id, 毫秒) 落盘**，key 就是毫秒数，所以同一部片再打开是 0 次 ffmpeg。
     单文件缓存超过 cap 就清最旧的（换清晰度/重刮后不会一直涨）。

不 import server.py：依赖全部由 ExtensionHost 通过 install(api) 注入。
"""
from __future__ import annotations

import json
import os
import random
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait as fwait

A = None  # type: ignore[assignment]

CFG_PATH = os.environ.get("HIGHLIGHTS_CONFIG", "/app/ext/highlights/highlights.json")

DEFAULTS: dict = {
    "enabled": True,
    # 一条亮点放几张：网盘库（CD2 挂载）每抽一帧都要先读一段远端数据，
    # 实测单帧 ~8s、并行也压不下来（带宽/分块瓶颈），6 张是「一排够看」和
    # 「首次打开别等太久」之间的折中；命中缓存后是 0 成本。
    "count": 6,
    # 抽帧点的可落范围（占片长的比例）：掐掉片头 logo 和片尾字幕
    "from_ratio": 0.05,
    "to_ratio": 0.93,
    # 缩略图宽度（高度按原比例算）。详情页那张卡是 132×74，320 宽够 2x
    "width": 320,
    # 单次请求最多等多久（**只在第一张都还没出来时**才等）。
    # 已经有图就直接回，客户端轮询才不会每次都卡这么久。
    "budget": 3.0,
    # 单帧 ffmpeg 超时（网盘挂载首次要读 moov + 一段数据）
    "frame_timeout": 25.0,
    "probe_timeout": 8.0,
    "workers": 6,
    # 空 = DATA_DIR/frames；也能写成别的持久化目录
    "cache_dir": "",
    # 单文件最多缓存多少张，超了清最旧的
    "cache_cap": 240,
    # 空 = 自动探测（PATH → /data/bin → /app/ext/highlights/bin）
    "ffmpeg": "",
    # 进度条画面预览（R08）：一张 10×12 的雪碧图盖住整片，拖进度条时显示那一格。
    # 本地库靠 `-skip_frame nokey` 十几秒出图；网盘要 demux 全片，实测不行就关这里。
    "preview_enabled": True,
    "preview_cols": 8,
    "preview_rows": 8,
    # 单格 128×72：进度条上那块预览只有 128 宽，160 是白存 —— 整张从 ~160KB 降到 ~100KB
    "preview_tile_w": 128,
    # 并行抽格数：实测 12 和 24 差不多（网盘带宽是瓶颈），12 对 NAS 更友好
    "preview_workers": 12,
    "preview_timeout": 300.0,
    # 闲时静默预生成（慢慢把库里"最近入库"的片跑一遍，用户第一次拖进度条就有画面）。
    # 单部约 100KB / 10~15 秒，串行 + 间隔，不和播放抢带宽。
    "preview_warm": True,
    # 每部之间留 2 分钟：抽一部本身要 10~15 秒、12 并发读网盘，
    # 间隔太短会和正在播放的片抢带宽。一天约 700 部，库跑完大概一周。
    "preview_warm_interval": 120,
    # 预生成总量上限（MB）：超了按最久没访问的删
    "preview_budget_mb": 2048,
}

# 正在抽的帧，避免客户端重试时同一个点跑两遍 ffmpeg
_LOCK = threading.Lock()
_INFLIGHT: set = set()


# --------------------------------------------------------------------------- #
# 配置与工具
# --------------------------------------------------------------------------- #

def load_config() -> dict:
    cfg = dict(DEFAULTS)
    try:
        with open(CFG_PATH, encoding="utf-8") as fh:
            raw = json.load(fh)
        if isinstance(raw, dict):
            cfg.update({k: v for k, v in raw.items() if not k.startswith("_")})
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as exc:
        A.log(f"WARN 读不到 {CFG_PATH}: {exc}，亮点扩展用默认配置")
    return cfg


def _one(query: dict, key: str, default: str = "") -> str:
    return (query.get(key) or [default])[0]


def _int(value, default: int, lo: int, hi: int) -> int:
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def _text(value) -> str:
    return value if isinstance(value, str) else ""


def _exe(path: str) -> str:
    return path if path and os.path.isfile(path) and os.access(path, os.X_OK) else ""


def _tool(cfg: dict, name: str) -> str:
    """找一个可执行的 ffmpeg/ffprobe：显式配置 > PATH > data/bin > 扩展自带 bin。"""
    want = _text(cfg.get("ffmpeg")).strip()
    if want:
        if os.path.basename(want) == want:      # 只写了 "ffmpeg"
            hit = shutil.which(want)
            return hit or ""
        if name == "ffmpeg":
            return _exe(want)
        # 只配了 ffmpeg 的路径时，同目录下找 ffprobe
        return _exe(os.path.join(os.path.dirname(want), name))
    hit = shutil.which(name)
    if hit:
        return hit
    for base in ("/data/bin", "/app/ext/highlights/bin"):
        hit = _exe(os.path.join(base, name))
        if hit:
            return hit
    return ""


def _cache_root(cfg: dict) -> str:
    """缩略图/预览的根目录。

    优先 `cache_dir` 配置（或客户端在「高级 → 进度条预览」里改的路径）；
    没配就优先用专门挂载的 `/cache`（部署时指向 vol1，8.6T 可用），
    没有再退回 `DATA_DIR/frames` —— 老部署不会因为加了新挂载就丢缓存。
    """
    root = _text(cfg.get("cache_dir")).strip()
    if not root:
        if os.path.isdir("/cache"):
            root = "/cache"
        else:
            root = os.path.join(os.environ.get("DATA_DIR", "/data"), "frames")
    return root


# --------------------------------------------------------------------------- #
# 文件与片长
# --------------------------------------------------------------------------- #

def _media_files(mid: int) -> list[dict]:
    with A.amane_db() as conn:
        rows = conn.execute(
            "SELECT id, path, size, duration, library_id FROM media_files "
            "WHERE metadata_id = ? ORDER BY id",
            (mid,),
        ).fetchall()
    return [{
        "id": int(r["id"]),
        "path": _text(r["path"]),
        "size": int(r["size"] or 0),
        "duration": float(r["duration"] or 0),
    } for r in rows]


def _pick(files: list[dict], want: str) -> dict | None:
    """选一个文件：指定了 fileKey（f<id>）就用它，否则挑「存在 + 最大」的那个。"""
    key = want.strip()
    if key[:1] == "f" and key[1:].isdigit():
        fid = int(key[1:])
        for f in files:
            if f["id"] == fid:
                return f
        return None
    alive = [f for f in files if f["path"] and os.path.isfile(f["path"])]
    pool = alive or files
    if not pool:
        return None
    # 最大那份通常就是正片（多版本里预览片段/分段都更小）
    return max(pool, key=lambda f: f["size"])


def _probe(ffprobe: str, path: str, cfg: dict) -> float:
    if not ffprobe:
        return 0.0
    try:
        out = subprocess.run(
            [ffprobe, "-v", "error", "-probesize", "1048576", "-analyzeduration", "500000",
             "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, timeout=float(cfg["probe_timeout"]),
        )
        return max(0.0, float(out.stdout.decode("utf-8", "replace").strip() or 0))
    except (subprocess.SubprocessError, ValueError, OSError) as exc:
        A.log(f"WARN 亮点探测片长失败 {path}: {exc}")
        return 0.0


def _runtime_seconds(meta_id: int) -> float:
    """最后兜底：metadata.runtime 是「分钟」，抽帧点差几分钟不影响观感。"""
    try:
        with A.amane_db() as conn:
            row = conn.execute("SELECT runtime FROM metadata WHERE id = ?", (meta_id,)).fetchone()
        return max(0, int(row["runtime"] or 0)) * 60.0 if row is not None else 0.0
    except Exception:  # noqa: BLE001
        return 0.0


def _duration_of(cfg: dict, file_id: int, path: str, meta_id: int) -> float:
    """拿片长：media_files.duration → ffprobe（按文件缓存）→ metadata.runtime。

    这条链是被现状逼出来的：本实例 `media_files.duration` 是**整列 NULL**
    （amane 没回填），所以每个文件第一次都要 ffprobe 一次；探到的值按文件落盘，
    之后开详情页就是读一个几十字节的 json，不再碰网盘。
    """
    stamp = os.path.join(_cache_root(cfg), str(file_id), "duration.json")
    try:
        with open(stamp, encoding="utf-8") as fh:
            cached = float((json.load(fh) or {}).get("duration") or 0)
        if cached > 0:
            return cached
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    probed = _probe(_tool(cfg, "ffprobe"), path, cfg)
    if probed > 0:
        try:
            os.makedirs(os.path.dirname(stamp), exist_ok=True)
            with open(stamp, "w", encoding="utf-8") as fh:
                json.dump({"duration": probed}, fh)
        except OSError as exc:
            A.log(f"WARN 亮点片长缓存写不进 {stamp}: {exc}")
        return probed
    return _runtime_seconds(meta_id)


# --------------------------------------------------------------------------- #
# 位置与抽帧
# --------------------------------------------------------------------------- #

def _positions(duration: float, count: int, seed: int, cfg: dict) -> list[int]:
    """把片长切 count 段，每段随机取一点，升序返回毫秒。"""
    lo = duration * float(cfg["from_ratio"])
    hi = duration * float(cfg["to_ratio"])
    if hi - lo < count:
        lo, hi = 0.0, max(duration, float(count))
    step = (hi - lo) / count
    rnd = random.Random(int(seed) & 0x7FFFFFFF)
    out: list[int] = []
    for i in range(count):
        t = lo + step * i + rnd.random() * step
        out.append(int(round(t * 1000)))
    return sorted(out)


def _frame_path(cfg: dict, file_id: int, ms: int) -> str:
    return os.path.join(_cache_root(cfg), str(file_id), f"{ms}.jpg")


def _pick_path(cfg: dict, file_id: int, ms: int) -> str:
    """用户自选的关键帧单独一张大图：亮点条只要 320 宽，剧照得能看，1280 起步。"""
    return os.path.join(_cache_root(cfg), "picks", str(file_id), f"{ms}.jpg")


def _extract(ffmpeg: str, src: str, dst: str, ms: int, cfg: dict, width: int = 0) -> bool:
    """抽一帧落盘。失败返回 False（不抛，一个点失败不影响整条）。"""
    with _LOCK:
        if os.path.isfile(dst):
            return True
        if dst in _INFLIGHT:
            return False
        _INFLIGHT.add(dst)
    tmp = dst + ".part.jpg"     # 后缀必须是 .jpg：ffmpeg 靠后缀选封装，.part 会报 Invalid argument
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        w = int(width) if width > 0 else int(cfg["width"])
        cmd = [
            ffmpeg, "-nostdin", "-loglevel", "error",
            # 探测窗口压到 1MB / 0.5s：默认 5MB 在网盘挂载上是「每个抽帧点先下 5MB」，
            # 实测 14.3s → 4.3s（IPZZ-037 冷读）。容器/封装都够用，别调更小。
            "-probesize", "1048576", "-analyzeduration", "500000",
            # 输入侧 seek：只读关键帧附近，网盘挂载上比输出侧快得多
            "-ss", f"{ms / 1000.0:.3f}", "-i", src,
            "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn",
            "-vf", f"scale={w}:-2", "-q:v", "3",
            "-y", tmp,
        ]
        res = subprocess.run(cmd, capture_output=True, timeout=float(cfg["frame_timeout"]))
        if res.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            err = res.stderr.decode("utf-8", "replace").strip().splitlines()
            A.log(f"WARN 亮点抽帧失败 {src}@{ms}ms: {err[-1] if err else res.returncode}")
            return False
        os.replace(tmp, dst)
        return True
    except (subprocess.SubprocessError, OSError) as exc:
        A.log(f"WARN 亮点抽帧异常 {src}@{ms}ms: {exc}")
        return False
    finally:
        try:
            if os.path.isfile(tmp):
                os.remove(tmp)
        except OSError:
            pass
        with _LOCK:
            _INFLIGHT.discard(dst)


def _prune(cfg: dict, file_id: int) -> None:
    """单文件缓存超 cap 就清最旧的。"""
    folder = os.path.join(_cache_root(cfg), str(file_id))
    try:
        names = [n for n in os.listdir(folder) if n.endswith(".jpg")]
    except OSError:
        return
    cap = int(cfg["cache_cap"])
    if len(names) <= cap:
        return
    paths = [os.path.join(folder, n) for n in names]
    paths.sort(key=lambda p: os.path.getmtime(p) if os.path.isfile(p) else 0)
    for p in paths[:len(paths) - cap]:
        try:
            os.remove(p)
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# 端点
# --------------------------------------------------------------------------- #

def highlights(handler, query, mid: str, *_):
    """GET /api/user/highlights/{metadata_id} —— 一条按时间排好的亮点缩略图。"""
    cfg = effective_cfg()
    if not cfg.get("enabled", True):
        return handler._json({"ok": False, "reason": "亮点扩展未启用", "items": []})

    meta_id = _int(mid, 0, 0, 10 ** 9)
    files = _media_files(meta_id)
    if not files:
        return handler._json({"ok": False, "reason": "这部片没有可读文件", "items": []})

    target = _pick(files, _one(query, "file", ""))
    if target is None:
        return handler._json({"ok": False, "reason": "指定版本不在这个条目下", "items": []})
    src = target["path"]
    if not src or not os.path.isfile(src):
        return handler._json({"ok": False, "reason": "文件不在线（网盘没挂上？）", "items": []})

    ffmpeg = _tool(cfg, "ffmpeg")
    if not ffmpeg:
        return handler._json({"ok": False, "reason": "服务端没有 ffmpeg", "items": []})

    count = _int(_one(query, "n", ""), int(cfg["count"]), 1, 16)
    duration = target["duration"] or _duration_of(cfg, target["id"], src, meta_id)
    if duration <= 0:
        return handler._json({"ok": False, "reason": "拿不到片长", "items": []})

    # seed 缺省 = 文件 id：同一部片每次打开位置固定，缩略图命中缓存；
    # 客户端要「换一批」时传个随机 seed 即可（旧图留着，回头再命中）。
    seed = _int(_one(query, "seed", ""), target["id"], 0, 2 ** 31 - 1)
    ms_list = _positions(duration, count, seed, cfg)
    _prune(cfg, target["id"])

    todo: list[tuple[int, str]] = []
    ready: list[int] = []
    for ms in ms_list:
        dst = _frame_path(cfg, target["id"], ms)
        if os.path.isfile(dst):
            ready.append(ms)
        else:
            todo.append((ms, dst))

    if todo:
        pool = ThreadPoolExecutor(max_workers=int(cfg["workers"]))
        try:
            futs = [pool.submit(_extract, ffmpeg, src, dst, ms, cfg) for ms, dst in todo]
            # 第一屏一张都还没有时才等一会儿（本地盘 3 秒内基本齐）；
            # 已经有图就直接回 —— 客户端是轮询式的，不能每轮都卡这么久。
            if not ready:
                fwait(futs, timeout=float(cfg["budget"]))
        finally:
            # 不 wait：没抽完的交给后台继续，客户端下一轮直接拿缓存
            pool.shutdown(wait=False)

    # pending 按「盘上还没有」算，不能只数本轮提交的任务：
    # 上一轮提交、现在还在抽的那些既不在 todo 里也没落盘，算漏了客户端会以为抽完了。
    items: list[dict] = []
    pending = 0
    for ms in ms_list:
        if os.path.isfile(_frame_path(cfg, target["id"], ms)):
            items.append({
                "t": round(ms / 1000.0, 1),          # 起播位置（秒，播放页直接吃）
                "ms": ms,
                "url": f"/api/user/highlights/{target['id']}/{ms}.jpg",
                "picked": False,
            })
        else:
            pending += 1

    # 用户自己截的帧（R25）：不受随机抽帧点影响，永远在条里，并标 picked
    marked: set = {it["ms"] for it in items}
    for pk in _picks(meta_id):
        if pk["ms"] in marked:
            for it in items:
                if it["ms"] == pk["ms"]:
                    it["picked"] = True
            continue
        dst = _pick_path(cfg, pk["file_id"], pk["ms"])
        if not os.path.isfile(dst):
            continue
        items.append({
            "t": round(pk["ms"] / 1000.0, 1),
            "ms": pk["ms"],
            "url": f"/api/user/highlights/pick/{pk['file_id']}/{pk['ms']}.jpg",
            "picked": True,
        })
    items.sort(key=lambda x: x["ms"])

    handler._json({
        "ok": len(items) > 0,
        "id": meta_id,
        "file_id": target["id"],
        "file_key": f"f{target['id']}",
        "duration": round(duration, 1),
        "count": count,
        "seed": seed,
        "items": items,
        # >0：还有几张在后台抽，客户端等一下再来（再来就是直接读缓存）
        "pending": pending,
        "reason": "" if items else "抽帧还没出结果",
    })


def frame(handler, query, fid: str, ms: str, *_):
    """GET /api/user/highlights/{file_id}/{ms}.jpg —— 回一张缓存好的缩略图。"""
    fid_n = _int(fid, 0, 0, 10 ** 9)
    ms_n = _int(ms, -1, -1, 10 ** 12)
    if fid_n <= 0 or ms_n < 0:
        return handler._error(400, "参数不对")
    path = _frame_path(effective_cfg(), fid_n, ms_n)
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return handler._error(404, "这张还没抽出来")
    handler.send_response(200)
    handler.send_header("Content-Type", "image/jpeg")
    handler.send_header("Content-Length", str(len(data)))
    # 同一个 (文件, 毫秒) 的图永远不变，让客户端放胆缓存
    handler.send_header("Cache-Control", "public, max-age=2592000")
    handler.end_headers()
    handler.wfile.write(data)


# --------------------------------------------------------------------------- #
# 用户自选关键帧（R25）
# --------------------------------------------------------------------------- #

# 自选帧要能当剧照 / 封面看，320 宽不够
PICK_WIDTH = 1280

SNAP_DDL = """
CREATE TABLE IF NOT EXISTS frame_picks (
    metadata_id INTEGER NOT NULL,
    file_id     INTEGER NOT NULL,
    ms          INTEGER NOT NULL,
    strong      INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    PRIMARY KEY (file_id, ms)
);
CREATE INDEX IF NOT EXISTS idx_frame_picks_meta ON frame_picks(metadata_id, ms);
"""


def _luma(ffmpeg: str, path: str) -> float:
    """读一帧的平均亮度（YAVG）。读不到返回 -1。

    「这张适不适合当剧照」只做最低限度的把关：纯黑过场、纯色闪白抽出来是废图。
    不搞构图/人脸识别 —— 自用库宁可多进一张，也别把用户主动截的丢掉。
    """
    try:
        res = subprocess.run(
            # metadata=print:file=- 把统计值写到 stdout：直接读日志的话，
            # metadata 滤镜打在 info 级别，`-v error` 会把它一起吞掉（踩过）。
            [ffmpeg, "-v", "error", "-i", path, "-vf", "signalstats,metadata=print:file=-",
             "-f", "null", "-"],
            capture_output=True, timeout=20,
        )
        for line in res.stdout.decode("utf-8", "replace").splitlines():
            if "YAVG" in line:
                return float(line.split("=")[-1].strip())
        for line in res.stderr.decode("utf-8", "replace").splitlines():
            if "YAVG" in line:
                return float(line.split("=")[-1].strip())
    except (subprocess.SubprocessError, ValueError, OSError):
        pass
    return -1.0


def _picks(mid: int) -> list[dict]:
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT file_id, ms, strong FROM frame_picks "
                "WHERE metadata_id = ? ORDER BY ms", (mid,)).fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 读关键帧失败 {mid}: {exc}")
        return []
    return [{"file_id": int(r["file_id"]), "ms": int(r["ms"]),
             "strong": int(r["strong"] or 0)} for r in rows]


def highlights_snap(handler, query, mid, *_):
    """POST /api/user/highlights/{metadata_id}/snap —— 把当前播放位置截成关键帧。

    body: ``{"t": 秒, "file_key": "f123"}``。

    一次生成，三处可用（R25）：亮点条（标「我选的」）、剧照（够清晰才进）、
    以及没有刮削封面的片子拿它当封面。所以抽的是 1280 宽的大图，不是亮点条
    那张 320 的缩略图 —— 同一毫秒会多存一份，换来「一张图三处用」。
    """
    cfg = effective_cfg()
    if not cfg.get("enabled", True):
        return handler._json({"ok": False, "reason": "亮点扩展未启用"})
    meta_id = _int(mid, 0, 0, 10 ** 9)
    body = handler._body() or {}
    try:
        t = float(body.get("t") or 0)
    except (TypeError, ValueError):
        t = 0.0
    files = _media_files(meta_id)
    if not files:
        return handler._json({"ok": False, "reason": "这部片没有可读文件"})
    want = _text(body.get("file_key")) or _one(query, "file", "")
    target = _pick(files, want)
    if target is None:
        return handler._json({"ok": False, "reason": "指定版本不在这个条目下"})
    src = target["path"]
    if not src or not os.path.isfile(src):
        return handler._json({"ok": False, "reason": "文件不在线（网盘没挂上？）"})
    ffmpeg = _tool(cfg, "ffmpeg")
    if not ffmpeg:
        return handler._json({"ok": False, "reason": "服务端没有 ffmpeg"})

    duration = target["duration"] or _duration_of(cfg, target["id"], src, meta_id)
    if duration > 0:
        t = max(0.0, min(duration - 0.5, t))
    ms = int(round(max(0.0, t) * 1000))
    dst = _pick_path(cfg, target["id"], ms)
    if not _extract(ffmpeg, src, dst, ms, cfg, PICK_WIDTH):
        return handler._json({"ok": False, "reason": "这一帧没抽出来（换个位置再试）"})

    luma = _luma(ffmpeg, dst)
    try:
        size = os.path.getsize(dst)
    except OSError:
        size = 0
    # 够格当剧照/封面：不是黑帧也不是过曝白帧，且不是纯色小图
    strong = 1 if (luma >= 25.0 and luma <= 240.0 and size >= 40000) else 0

    now = A.now_iso()
    try:
        with A.user_db() as conn:
            conn.execute(
                "INSERT INTO frame_picks(metadata_id, file_id, ms, strong, created_at) "
                "VALUES(?, ?, ?, ?, ?) ON CONFLICT(file_id, ms) "
                "DO UPDATE SET strong = excluded.strong",
                (meta_id, target["id"], ms, strong, now))
    except Exception as exc:  # noqa: BLE001
        A.log(f"ERROR 关键帧入库失败 {meta_id}: {exc}")
        return handler._json({"ok": False, "reason": "存不进数据库"})

    url = f"/api/user/highlights/pick/{target['id']}/{ms}.jpg"
    # 够格的同时进剧照：与 stills 扩展共用 user.db 的 still_likes，
    # 详情页的剧照墙 / 「喜欢的剧照」立刻就能看到这一张。
    if strong:
        try:
            with A.user_db() as conn:
                conn.execute(
                    "INSERT OR IGNORE INTO still_likes(metadata_id, url, ratio, created_at) "
                    "VALUES(?, ?, ?, ?)", (meta_id, url, 0.0, now))
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN 关键帧进剧照失败 {meta_id}: {exc}")

    handler._json({
        "ok": True,
        "id": meta_id,
        "file_key": f"f{target['id']}",
        "t": round(ms / 1000.0, 1),
        "ms": ms,
        "url": url,
        "picked": True,
        "still": bool(strong),
        "luma": round(luma, 1),
    })


def highlights_unsnap(handler, query, mid, ms, *_):
    """DELETE /api/user/highlights/{mid}/snap/{ms} —— 撤掉一张我截的帧。"""
    meta_id = _int(mid, 0, 0, 10 ** 9)
    ms_n = _int(ms, -1, -1, 10 ** 12)
    if ms_n < 0:
        return handler._error(400, "参数不对")
    try:
        with A.user_db() as conn:
            row = conn.execute(
                "SELECT file_id FROM frame_picks WHERE metadata_id = ? AND ms = ?",
                (meta_id, ms_n)).fetchone()
            conn.execute("DELETE FROM frame_picks WHERE metadata_id = ? AND ms = ?",
                         (meta_id, ms_n))
            if row is not None:
                conn.execute(
                    "DELETE FROM still_likes WHERE metadata_id = ? AND url = ?",
                    (meta_id, f"/api/user/highlights/pick/{int(row['file_id'])}/{ms_n}.jpg"))
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"撤销失败: {exc}")
    handler._json({"ok": True})


def pick_frame(handler, query, fid: str, ms: str, *_):
    """GET /api/user/highlights/pick/{file_id}/{ms}.jpg —— 自选关键帧大图。"""
    fid_n = _int(fid, 0, 0, 10 ** 9)
    ms_n = _int(ms, -1, -1, 10 ** 12)
    if fid_n <= 0 or ms_n < 0:
        return handler._error(400, "参数不对")
    path = _pick_path(effective_cfg(), fid_n, ms_n)
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return handler._error(404, "这张还没抽出来")
    handler.send_response(200)
    handler.send_header("Content-Type", "image/jpeg")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "public, max-age=2592000")
    handler.end_headers()
    handler.wfile.write(data)


# --------------------------------------------------------------------------- #
# 进度条画面预览：一张雪碧图（R08）
# --------------------------------------------------------------------------- #

_PREVIEW_INFLIGHT: set = set()
_PREVIEW_LOCK = threading.Lock()
# 换生成方式（顺序跳帧 → 并行跳读、10×12 → 8×8、160 → 128）就得 +1，
# 否则老 meta 会被直接命中，客户端拿到的格子和实际图对不上（表现为预览全黑/错位）
PREVIEW_VERSION = 3


def _preview_root(cfg: dict, file_id: int) -> str:
    return os.path.join(_cache_root(cfg), "preview", str(file_id))


def _extract_tile(ffmpeg: str, src: str, dst: str, ms: int, tw: int, th: int) -> bool:
    """给雪碧图抽一格：**统一裁成 tw×th**，否则 4:3 的片会让 tile 拼不起来。

    与 `_extract` 的区别只有滤镜：先按短边放大到盖满，再居中裁。
    """
    tmp = dst + ".part.jpg"
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        cmd = [
            ffmpeg, "-nostdin", "-loglevel", "error",
            "-probesize", "1048576", "-analyzeduration", "500000",
            "-ss", f"{ms / 1000.0:.3f}", "-i", src,
            "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn",
            "-vf", f"scale={tw}:{th}:force_original_aspect_ratio=increase,crop={tw}:{th}",
            "-q:v", "5", "-y", tmp,
        ]
        res = subprocess.run(cmd, capture_output=True, timeout=60)
        if res.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            return False
        os.replace(tmp, dst)
        return True
    except (subprocess.SubprocessError, OSError):
        return False
    finally:
        try:
            if os.path.isfile(tmp):
                os.remove(tmp)
        except OSError:
            pass


def _build_preview(cfg: dict, ffmpeg: str, src: str, file_id: int, duration: float) -> None:
    """生成进度条预览雪碧图：8×8 = 64 格，覆盖整片。

    为什么不照 Jellyfin 那样「入库时预生成」：我们入库是外部 worker 驱动的，
    塞进去要改那条链路；改成**打开播放页就后台生成**，用户第一次拖进度条时
    通常已经好了。

    生成方式对比（551 / 6529s / 网盘挂载实测）：
      * `fps + tile + -skip_frame nokey` 顺序读：**30s**（要过全片所有关键帧）
      * 并行跳读 + 事后拼接：**14s**（64 帧、12 并发）—— 快一倍，且掉帧少
    所以走后者：每个采样点单独 `-ss` 跳过去只读附近几 MB，再 tile 拼一张。
    """
    root = _preview_root(cfg, file_id)
    cols = int(cfg.get("preview_cols", 8))
    rows = int(cfg.get("preview_rows", 8))
    tw = int(cfg.get("preview_tile_w", 160))
    th = int(round(tw * 9 / 16.0))
    n = cols * rows
    step = max(2.0, duration / float(n)) if duration > 0 else 30.0
    tmpdir = os.path.join(root, "cells")
    sprite_tmp = os.path.join(root, "sprite.part.jpg")
    try:
        os.makedirs(tmpdir, exist_ok=True)
        # 清掉上一轮残留（帧数变了会有多余格子）
        for name in os.listdir(tmpdir):
            if name.endswith(".jpg"):
                try:
                    os.remove(os.path.join(tmpdir, name))
                except OSError:
                    pass

        def job(i: int) -> bool:
            ms = int(round(i * step * 1000))
            return _extract_tile(ffmpeg, src, os.path.join(tmpdir, f"{i:03d}.jpg"),
                                 ms, tw, th)

        with ThreadPoolExecutor(max_workers=min(int(cfg.get("preview_workers", 12)), n)) as pool:
            hits = list(pool.map(job, range(n)))

        # 缺格子时补一张黑图，tile 必须拿到完整 n 帧才输出
        miss = 0
        for i, ok in enumerate(hits):
            if not ok:
                miss += 1
                p = os.path.join(tmpdir, f"{i:03d}.jpg")
                try:
                    subprocess.run(
                        [ffmpeg, "-nostdin", "-loglevel", "error", "-f", "lavfi",
                         "-i", f"color=c=black:s={tw}x{th}:d=1", "-frames:v", "1",
                         "-q:v", "8", "-y", p], capture_output=True, timeout=30)
                except (subprocess.SubprocessError, OSError):
                    pass

        res = subprocess.run(
            [ffmpeg, "-nostdin", "-loglevel", "error", "-framerate", "1",
             "-i", os.path.join(tmpdir, "%03d.jpg"),
             "-vf", f"tile={cols}x{rows}:padding=0", "-frames:v", "1",
             "-q:v", "5", "-y", sprite_tmp],
            capture_output=True, timeout=120,
        )
        if res.returncode != 0 or not os.path.isfile(sprite_tmp) or os.path.getsize(sprite_tmp) == 0:
            err = res.stderr.decode("utf-8", "replace").strip().splitlines()
            A.log(f"WARN 预览图拼接失败 {src}: {err[-1] if err else res.returncode}")
            return
        os.replace(sprite_tmp, os.path.join(root, "sprite.jpg"))
        meta = {
            "ok": True,
            "v": PREVIEW_VERSION,
            "file_id": file_id,
            "cols": cols,
            "rows": rows,
            "tile_w": tw,
            # 每格代表多少秒：客户端按 t/step 算第几格
            "step": round(step, 3),
            "count": n,
            "miss": miss,
            # ★ URL 必须带版本号 ★
            # 图是原地覆盖写的（sprite.jpg），URL 不变的话 Image 组件会一直用
            # 缓存里的旧图（旧布局 10×12），客户端按新 8×8 裁 → 一片黑。
            # 带 ?v=N 换 URL 才能让缓存失效（2.4.6.17 反馈第 3 条）。
            "url": f"/api/user/preview/{file_id}/sprite.jpg?v={PREVIEW_VERSION}",
        }
        with open(os.path.join(root, "meta.json"), "w", encoding="utf-8") as fh:
            json.dump(meta, fh)
    except (subprocess.SubprocessError, OSError) as exc:
        A.log(f"WARN 预览图异常 {src}: {exc}")
    finally:
        try:
            if os.path.isfile(sprite_tmp):
                os.remove(sprite_tmp)
        except OSError:
            pass
        try:
            for name in os.listdir(tmpdir):
                os.remove(os.path.join(tmpdir, name))
        except OSError:
            pass
        with _PREVIEW_LOCK:
            _PREVIEW_INFLIGHT.discard(file_id)


# --------------------------------------------------------------------------- #
# 闲时静默预生成
# --------------------------------------------------------------------------- #

# 只在进程内起一次（扩展 reload 会重新 install，不能越起越多）
_WARM_STARTED = False


def _preview_trim(cfg: dict) -> None:
    """预生成总量超预算时，按最久没访问（mtime 最旧）的删到预算内。"""
    budget = int(cfg.get("preview_budget_mb", 2048)) * 1024 * 1024
    root = os.path.join(_cache_root(cfg), "preview")
    if budget <= 0 or not os.path.isdir(root):
        return
    entries: list = []
    total = 0
    for name in os.listdir(root):
        d = os.path.join(root, name)
        sp = os.path.join(d, "sprite.jpg")
        try:
            st = os.stat(sp)
        except OSError:
            continue
        entries.append((st.st_mtime, st.st_size, d))
        total += st.st_size
    if total <= budget:
        return
    entries.sort()
    for _mt, size, d in entries:
        if total <= budget:
            break
        try:
            shutil.rmtree(d, ignore_errors=True)
            total -= size
        except OSError:
            continue
    A.log(f"INFO 预览缓存超预算，已清理到 {total // 1048576}MB")


def _preview_warm_once(cfg: dict, ffmpeg: str) -> bool:
    """挑**一部**还没生成预览的片跑一遍；没有可做的返回 False。

    顺序：最近入库优先（`media_files.id DESC`）。这样用户新加进来的片，
    大概率在他第一次拖进度条之前就已经有图了。
    """
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id AS mid, id AS fid, path, duration "
                "FROM media_files WHERE path IS NOT NULL AND path != '' "
                "ORDER BY id DESC LIMIT 800").fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 预览预热查不到库: {exc}")
        return False
    for r in rows:
        fid = int(r["fid"])
        src = _text(r["path"])
        if not src or not os.path.isfile(src):
            continue
        root = _preview_root(cfg, fid)
        meta_file = os.path.join(root, "meta.json")
        if os.path.isfile(meta_file) and os.path.isfile(os.path.join(root, "sprite.jpg")):
            try:
                with open(meta_file, encoding="utf-8") as fh:
                    if int(json.load(fh).get("v") or 0) == PREVIEW_VERSION:
                        continue
            except (OSError, ValueError, TypeError):
                pass
        with _PREVIEW_LOCK:
            if fid in _PREVIEW_INFLIGHT:
                continue
            _PREVIEW_INFLIGHT.add(fid)
        dur = float(r["duration"] or 0)
        if dur <= 0:
            dur = _duration_of(cfg, fid, src, int(r["mid"]))
        A.log(f"INFO 预览预热 {os.path.basename(src)}")
        _build_preview(cfg, ffmpeg, src, fid, dur)
        return True
    return False


def _preview_warm_loop(interval: int) -> None:
    """后台慢跑：一部接一部，中间留间隔，别和播放抢网盘带宽。

    每轮都重读一次配置和用户偏好 —— 「高级设置」里关掉预生成要立刻生效，
    不用重启服务。
    """
    while True:
        try:
            cfg = effective_cfg()
            prefs = load_prefs()
            if not cfg.get("preview_enabled", True):
                return
            if not bool(prefs.get("warm", cfg.get("preview_warm", True))):
                time.sleep(300)
                continue
            ffmpeg = _tool(cfg, "ffmpeg")
            if not ffmpeg:
                return
            # 预算以用户设置为准（0 = 不设上限）
            cfg["preview_budget_mb"] = int(prefs.get("budget_mb",
                                                     cfg.get("preview_budget_mb", 2048)))
            _preview_trim(cfg)
            did = _preview_warm_once(cfg, ffmpeg)
            time.sleep(max(10, interval) if did else 300)
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN 预览预热异常: {exc}")
            time.sleep(120)


# --------------------------------------------------------------------------- #
# 用户可调项（客户端「高级设置 → 进度条预览」）
# --------------------------------------------------------------------------- #

PREFS_PATH = os.environ.get(
    "HIGHLIGHTS_PREFS",
    os.path.join(os.environ.get("DATA_DIR", "/data"), "preview-prefs.json"))


def load_prefs() -> dict:
    """用户在客户端改过的偏好；没写过的键不出现（回落到配置文件里的默认值）。"""
    out: dict = {}
    try:
        with open(PREFS_PATH, encoding="utf-8") as fh:
            raw = json.load(fh)
        if isinstance(raw, dict):
            out = raw
    except (OSError, ValueError):
        pass
    return out


def save_prefs(prefs: dict) -> None:
    try:
        os.makedirs(os.path.dirname(PREFS_PATH), exist_ok=True)
        tmp = PREFS_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(prefs, fh)
        os.replace(tmp, PREFS_PATH)
    except OSError as exc:
        A.log(f"WARN 写 {PREFS_PATH} 失败: {exc}")


def effective_cfg() -> dict:
    """配置文件 + 用户偏好合并后的实际配置。

    preview 相关的一切（生成 / 读取 / 清理 / 统计）都必须走这里，
    否则客户端改了缓存目录、后台还在往老地方写。
    """
    cfg = load_config()
    prefs = load_prefs()
    cd = _text(prefs.get("cache_dir")).strip()
    if cd:
        cfg["cache_dir"] = cd
    if "budget_mb" in prefs:
        try:
            cfg["preview_budget_mb"] = max(0, int(prefs.get("budget_mb") or 0))
        except (TypeError, ValueError):
            pass
    return cfg


def _preview_stats(cfg: dict) -> dict:
    """已生成的张数与占用（MB）。"""
    root = os.path.join(_cache_root(cfg), "preview")
    used = 0
    n = 0
    try:
        for name in os.listdir(root):
            sp = os.path.join(root, name, "sprite.jpg")
            try:
                used += os.stat(sp).st_size
                n += 1
            except OSError:
                continue
    except OSError:
        pass
    return {"used_mb": round(used / 1048576, 1), "count": n}


def preview_prefs_get(handler, query, *_):
    """GET /api/user/preview/settings —— 预生成开关、预算、路径、当前占用。"""
    cfg = effective_cfg()
    prefs = load_prefs()
    st = _preview_stats(cfg)
    root = _cache_root(cfg)
    handler._json({
        "ok": True,
        "enabled": bool(cfg.get("preview_enabled", True)),
        "warm": bool(prefs.get("warm", cfg.get("preview_warm", True))),
        "budget_mb": int(prefs.get("budget_mb", cfg.get("preview_budget_mb", 2048))),
        "interval": int(cfg.get("preview_warm_interval", 120)),
        "used_mb": st["used_mb"],
        "count": st["count"],
        "tile_w": int(cfg.get("preview_tile_w", 128)),
        "cache_dir": root,
        "cache_dir_set": bool(_text(prefs.get("cache_dir")).strip()),
        # 目录不存在基本就是「容器没挂载这个路径」，客户端据此提示用户
        "cache_ok": os.path.isdir(root),
        "writable": _writable(root),
    })


def _writable(path: str) -> bool:
    """这个目录能不能写（用来提前发现「改了路径但没挂载」）。"""
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, ".write-probe")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("1")
        os.remove(probe)
        return True
    except OSError:
        return False


def preview_prefs_set(handler, query, *_):
    """POST /api/user/preview/settings —— body {warm?, budget_mb?, cache_dir?}。"""
    body = handler._body() or {}
    prefs = load_prefs()
    if "warm" in body:
        prefs["warm"] = bool(body.get("warm"))
    if "budget_mb" in body:
        try:
            prefs["budget_mb"] = max(0, int(body.get("budget_mb") or 0))
        except (TypeError, ValueError):
            return handler._error(400, "budget_mb 必须是整数")
    if "cache_dir" in body:
        cd = _text(body.get("cache_dir")).strip()
        if cd and not cd.startswith("/"):
            return handler._error(400, "路径要写成容器内的绝对路径，比如 /cache")
        if cd:
            prefs["cache_dir"] = cd
        else:
            prefs.pop("cache_dir", None)
    save_prefs(prefs)
    handler._json({"ok": True})


def preview_purge(handler, query, *_):
    """POST /api/user/preview/purge —— 清空全部预览图（省空间用）。"""
    cfg = effective_cfg()
    root = os.path.join(_cache_root(cfg), "preview")
    removed = 0
    try:
        for name in os.listdir(root):
            d = os.path.join(root, name)
            shutil.rmtree(d, ignore_errors=True)
            removed += 1
    except OSError:
        pass
    handler._json({"ok": True, "removed": removed})


def preview_meta(handler, query, mid, *_):
    """GET /api/user/preview/{metadata_id} —— 进度条预览的元信息；没有就在后台生成。"""
    cfg = effective_cfg()
    if not cfg.get("preview_enabled", True):
        return handler._json({"ok": False, "reason": "预览未启用"})
    meta_id = _int(mid, 0, 0, 10 ** 9)
    files = _media_files(meta_id)
    if not files:
        return handler._json({"ok": False, "reason": "没有可读文件"})
    target = _pick(files, _one(query, "file", ""))
    if target is None:
        return handler._json({"ok": False, "reason": "指定版本不在这条下"})
    src = target["path"]
    if not src or not os.path.isfile(src):
        return handler._json({"ok": False, "reason": "文件不在线"})
    root = _preview_root(cfg, target["id"])
    meta_file = os.path.join(root, "meta.json")
    if os.path.isfile(meta_file) and os.path.isfile(os.path.join(root, "sprite.jpg")):
        try:
            with open(meta_file, encoding="utf-8") as fh:
                cached = json.load(fh)
            if int(cached.get("v") or 0) == PREVIEW_VERSION:
                # 老 meta 里的 url 没带版本号（Image 会一直命中旧缓存），这里补上
                cached["url"] = (f"/api/user/preview/{target['id']}/sprite.jpg"
                                 f"?v={PREVIEW_VERSION}")
                return handler._json(cached)
        except (OSError, ValueError, TypeError):
            pass
    ffmpeg = _tool(cfg, "ffmpeg")
    if not ffmpeg:
        return handler._json({"ok": False, "reason": "服务端没有 ffmpeg"})
    duration = target["duration"] or _duration_of(cfg, target["id"], src, meta_id)
    with _PREVIEW_LOCK:
        busy = target["id"] in _PREVIEW_INFLIGHT
        if not busy:
            _PREVIEW_INFLIGHT.add(target["id"])
    if not busy:
        threading.Thread(
            target=_build_preview, args=(cfg, ffmpeg, src, target["id"], duration),
            daemon=True, name="preview-build").start()
    handler._json({"ok": False, "pending": True, "file_id": target["id"],
                   "reason": "预览图生成中"})


def preview_sprite(handler, query, fid: str, *_):
    """GET /api/user/preview/{file_id}/sprite.jpg —— 雪碧图本体。"""
    fid_n = _int(fid, 0, 0, 10 ** 9)
    if fid_n <= 0:
        return handler._error(400, "参数不对")
    path = os.path.join(_preview_root(effective_cfg(), fid_n), "sprite.jpg")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return handler._error(404, "预览图还没好")
    handler.send_response(200)
    handler.send_header("Content-Type", "image/jpeg")
    handler.send_header("Content-Length", str(len(data)))
    # 一天就够：文件名不带 hash，全指纹靠 URL 里的 ?v=N
    handler.send_header("Cache-Control", "public, max-age=86400")
    handler.end_headers()
    handler.wfile.write(data)


def _poster_of(row) -> str:
    """metadata.poster_urls 是 JSON 数组，取第一张当封面。"""
    for key in ("poster_urls", "thumb_urls"):
        raw = row[key] if key in row.keys() else None
        try:
            urls = json.loads(raw) if isinstance(raw, str) else (raw or [])
        except (TypeError, ValueError):
            urls = []
        if isinstance(urls, list):
            for u in urls:
                if isinstance(u, str) and u.startswith("http"):
                    return u
    return ""


def highlights_picks(handler, query, *_):
    """GET /api/user/highlights/picks —— 我截过的全部关键帧（管理页用）。

    返回里带片名/番号/海报，客户端不用为每一帧再查一次详情。
    跨库不能 JOIN，先取台账再按 id 批量补。
    """
    limit = _int(_one(query, "limit", "200"), 200, 1, 500)
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, file_id, ms, strong, created_at FROM frame_picks "
                "ORDER BY created_at DESC, ms DESC LIMIT ?", (limit,)).fetchall()
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"读截帧台账失败: {exc}")
    ids = sorted({int(r["metadata_id"]) for r in rows})
    info: dict = {}
    if ids:
        ph = ",".join("?" * len(ids))
        try:
            with A.amane_db() as conn:
                for r in conn.execute(
                        f"SELECT id, number, title, poster_urls, thumb_urls FROM metadata "
                        f"WHERE id IN ({ph})", ids):
                    info[int(r["id"])] = r
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN 截帧补片名失败: {exc}")
    items = []
    for r in rows:
        mid = int(r["metadata_id"])
        f_id = int(r["file_id"])
        ms = int(r["ms"])
        base = info.get(mid)
        items.append({
            "metadata_id": mid,
            "file_id": f_id,
            "ms": ms,
            "t": round(ms / 1000.0, 1),
            "still": bool(int(r["strong"] or 0)),
            "created_at": r["created_at"] or "",
            "url": f"/api/user/highlights/pick/{f_id}/{ms}.jpg",
            "number": (base["number"] or "") if base is not None else "",
            "title": (base["title"] or "") if base is not None else "",
            "poster": _poster_of(base) if base is not None else "",
        })
    handler._json({"items": items, "total": len(items)})


def on_item_extra(mid: int) -> dict:
    """详情页补两组字段（R25）：

    * `frame_cover` —— 没刮削封面的片子拿我截的关键帧当封面；
    * `my_stills` —— **我截的帧当剧照**。刮削剧照在 `metadata.still_urls` 里，
      和用户自己截的是两套数据，客户端要把这组并到剧照墙前面，否则「提示已进剧照」
      但详情页永远看不到（2026-11-11 用户报的就是这个）。
    """
    try:
        picks = _picks(int(mid))
    except Exception:  # noqa: BLE001
        return {}
    strong = [p for p in picks if p["strong"]]
    if not strong:
        return {}
    urls = [f"/api/user/highlights/pick/{p['file_id']}/{p['ms']}.jpg" for p in strong]
    return {
        "frame_cover": urls[-1],
        "frame_cover_count": len(strong),
        "my_stills": urls,
    }


def highlight_pick_put(handler, query, mid, ms, *_):
    """PUT /api/user/highlights/{id}/snap/{ms} —— 改「这张算不算剧照」。

    body: ``{"still": true|false}``。用户自己认定，服务端不再替他判断：
    管理页上点一下就能进/出剧照墙（R25 第 9 条）。
    """
    meta_id = _int(mid, 0, 0, 10 ** 9)
    ms_n = _int(ms, -1, -1, 10 ** 12)
    if ms_n < 0:
        return handler._error(400, "参数不对")
    body = handler._body() or {}
    still = 1 if body.get("still") is True else 0
    try:
        with A.user_db() as conn:
            row = conn.execute(
                "SELECT file_id FROM frame_picks WHERE metadata_id = ? AND ms = ?",
                (meta_id, ms_n)).fetchone()
            if row is None:
                return handler._error(404, "这一帧不在台账里")
            conn.execute(
                "UPDATE frame_picks SET strong = ? WHERE metadata_id = ? AND ms = ?",
                (still, meta_id, ms_n))
            url = f"/api/user/highlights/pick/{int(row['file_id'])}/{ms_n}.jpg"
            if still:
                conn.execute(
                    "INSERT OR IGNORE INTO still_likes(metadata_id, url, ratio, created_at) "
                    "VALUES(?, ?, ?, ?)", (meta_id, url, 0.0, A.now_iso()))
            else:
                conn.execute(
                    "DELETE FROM still_likes WHERE metadata_id = ? AND url = ?",
                    (meta_id, url))
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"改剧照标记失败: {exc}")
    handler._json({"ok": True, "still": bool(still)})


ROUTES = [
    # 顺序无所谓：都用全锚点正则，pick/ 与 {id}/snap 不会互相抢
    ("POST", r"/api/user/highlights/(\d+)/snap", highlights_snap),
    ("PUT", r"/api/user/highlights/(\d+)/snap/(\d+)", highlight_pick_put),
    ("DELETE", r"/api/user/highlights/(\d+)/snap/(\d+)", highlights_unsnap),
    ("GET", r"/api/user/highlights/pick/(\d+)/(\d+)\.jpg", pick_frame),
    ("GET", r"/api/user/highlights/picks", highlights_picks),
    ("GET", r"/api/user/highlights/(\d+)/(\d+)\.jpg", frame),
    ("GET", r"/api/user/highlights/(\d+)", highlights),
    ("GET", r"/api/user/preview/(\d+)/sprite\.jpg", preview_sprite),
    # 注意顺序：settings / purge 是字面量，不会被 (\d+) 抢先匹配
    ("GET", r"/api/user/preview/settings", preview_prefs_get),
    ("POST", r"/api/user/preview/settings", preview_prefs_set),
    ("POST", r"/api/user/preview/purge", preview_purge),
    ("GET", r"/api/user/preview/(\d+)", preview_meta),
]


def install(api) -> dict:
    global A, _WARM_STARTED
    A = api
    api.add_ddl(SNAP_DDL)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("item_extra", on_item_extra)
    cfg = effective_cfg()
    # 闲时预生成：单部 ~100KB，库里 5000 部约 500MB，间隔 45s 慢跑，不进播放链路
    warm = bool(cfg.get("preview_enabled", True)) and bool(cfg.get("preview_warm", True))
    if warm and not _WARM_STARTED and _tool(cfg, "ffmpeg"):
        _WARM_STARTED = True
        threading.Thread(
            target=_preview_warm_loop,
            args=(int(cfg.get("preview_warm_interval", 45)),),
            daemon=True, name="preview-warm").start()
    return {
        "id": "highlights",
        "routes": len(ROUTES),
        "ffmpeg": os.path.basename(_tool(cfg, "ffmpeg")) or "缺失",
        "cache": _cache_root(cfg),
        "warm": warm,
    }
