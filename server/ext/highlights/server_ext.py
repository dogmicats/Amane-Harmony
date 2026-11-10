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
    root = _text(cfg.get("cache_dir")).strip()
    if not root:
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


def _extract(ffmpeg: str, src: str, dst: str, ms: int, cfg: dict) -> bool:
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
        cmd = [
            ffmpeg, "-nostdin", "-loglevel", "error",
            # 探测窗口压到 1MB / 0.5s：默认 5MB 在网盘挂载上是「每个抽帧点先下 5MB」，
            # 实测 14.3s → 4.3s（IPZZ-037 冷读）。容器/封装都够用，别调更小。
            "-probesize", "1048576", "-analyzeduration", "500000",
            # 输入侧 seek：只读关键帧附近，网盘挂载上比输出侧快得多
            "-ss", f"{ms / 1000.0:.3f}", "-i", src,
            "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn",
            "-vf", f"scale={int(cfg['width'])}:-2", "-q:v", "4",
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
    cfg = load_config()
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
            })
        else:
            pending += 1

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
    path = _frame_path(load_config(), fid_n, ms_n)
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


ROUTES = [
    # 顺序无所谓：两条都用全锚点正则，frame 那条带后缀 .jpg 不会和上面撞
    ("GET", r"/api/user/highlights/(\d+)/(\d+)\.jpg", frame),
    ("GET", r"/api/user/highlights/(\d+)", highlights),
]


def install(api) -> dict:
    global A
    A = api
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    cfg = load_config()
    return {
        "id": "highlights",
        "routes": len(ROUTES),
        "ffmpeg": os.path.basename(_tool(cfg, "ffmpeg")) or "缺失",
        "cache": _cache_root(cfg),
    }
