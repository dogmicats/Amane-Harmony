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
import re
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
    # ---- 网盘挂载（115 等）专用策略（2.5.7.15）----
    # 这些路径上 ffprobe 冷读 8 秒都不够（实测必超时），而每个抽帧点还要单独 seek；
    # 6 并发一起怼会把挂载和带宽打满，还一个都抽不出来。所以：
    #   * 不探片长（直接用库里 runtime，避免每个请求白等 8 秒）；
    #   * 串行抽（1 个 ffmpeg 在跑）；
    #   * 单帧给足 75 秒（冷读一次就要几十秒）；
    #   * 失败的帧冷却 10 分钟再试，避免客户端轮询时每轮都重起 ffmpeg。
    "network_mounts": ["/media2"],
    "remote_workers": 1,
    "remote_frame_timeout": 75.0,
    "fail_cooldown": 600,
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
# 抽失败的帧：dst -> 失败时间戳。冷却期内不再起 ffmpeg（客户端是轮询的，
# 一个抽不出的点会被反复重试，每次都占满一个线程 + 一次网盘冷读）。
_FAILED: dict = {}
# 网盘路径的 isfile 结果缓存：115 上单次 stat 就要 0.7s，客户端每轮都请求一次
_EXISTS: dict = {}


# 本地文件系统白名单：不在这里的一律按「远程挂载」对待（走串行长超时那套）
_LOCAL_FS = {
    "ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "jfs", "reiserfs",
    "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "tmpfs", "overlay",
}

_mount_cache: dict = {"at": 0.0, "roots": [], "rows": []}
_speed_cache: dict = {}          # 挂载点 -> (测量时刻, 是否慢盘)
_SPEED_TTL = 3600.0
_SLOW_MS = 0.30                  # 读 256KB 超过 300ms 就当慢盘（本地盘通常 <20ms）


def _proc_mounts() -> list[tuple[str, str]]:
    """`/proc/mounts` 的 (挂载点, fstype) 列表，缓存 60 秒（挂载表不常变）。"""
    now = time.time()
    cached_rows = _mount_cache.get("rows") or []
    if cached_rows and now - float(_mount_cache["at"]) < 60.0:
        return cached_rows
    rows: list[tuple[str, str]] = []
    roots: list[str] = []
    try:
        with open("/proc/mounts", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 3:
                    continue
                mp = parts[1].replace("\\040", " ")
                fstype = parts[2]
                if not mp.startswith("/"):
                    continue
                rows.append((mp, fstype))
                # 「像媒体库」的根才记进来，别把 /proc /sys 也算远程
                if fstype in _LOCAL_FS or mp.count("/") > 2:
                    continue
                if fstype.startswith("fuse") or fstype in ("nfs", "nfs4", "cifs", "smbfs"):
                    roots.append(mp.rstrip("/"))
    except Exception as exc:
        A.log(f"WARN 读 /proc/mounts 失败: {exc}")
    _mount_cache["at"] = now
    _mount_cache["rows"] = rows
    _mount_cache["roots"] = roots
    return rows


def _remote_roots() -> list[str]:
    """fstype 一眼就是远程的挂载点（fuse / nfs / cifs）。"""
    _proc_mounts()
    return list(_mount_cache.get("roots") or [])


def _mount_root(path: str) -> str:
    """path 落在哪个挂载点下（取最长匹配的那个）。"""
    best = ""
    for mp, _fs in _proc_mounts():
        base = mp.rstrip("/") or "/"
        if path == base or path.startswith(base + "/"):
            if len(base) > len(best):
                best = base
    return best or "/"


def _probe_slow(path: str) -> bool:
    """实测一次「读这个文件快不快」：读 256KB 计时。

    为什么要实测：`fstype` 看不穿「NAS 上挂了云盘、再用本地目录 bind 进容器」这种
    —— 内核看来它就是 btrfs，但真实数据要跨网取。读一次最诚实。
    读不动（文件不在/无权限）一律当慢盘：宁可走保守策略，也不要在网盘上开 6 并发。
    """
    try:
        t0 = time.time()
        with open(path, "rb") as fh:
            fh.read(262144)
        return (time.time() - t0) > _SLOW_MS
    except Exception:
        return True


def _is_remote_fast(path: str, cfg: dict) -> bool:
    """只看配置 + fstype，**不做实测**。

    给「列表遍历」用：`/shorts` 一次要看几十上百个候选，如果每个都去读 256KB 测延迟，
    遇到一个没见过的慢挂载点就能把整个请求拖几十秒（实测踩过：页面一直转圈）。
    实测只留给真正要读文件的地方（抽帧）。
    """
    p = (path or "").replace("\\", "/")
    for mount in (cfg.get("network_mounts") or []):
        m = str(mount).rstrip("/")
        if m and (p == m or p.startswith(m + "/")):
            return True
    for root in _remote_roots():
        if root and (p == root or p.startswith(root + "/")):
            return True
    return False


def _is_remote(path: str, cfg: dict) -> bool:
    """这条路径要不要按「慢盘」对待（串行抽帧、长超时、不进短视频流）。

    发布版用户**什么都不用配**，判据全自动：
      1. 配置 `network_mounts` 里显式写的前缀 —— 手工强制，优先级最高（留给自己折腾用）；
      2. fstype 一眼是远程（fuse/nfs/cifs）—— 零成本，覆盖 CD2 / rclone / NFS；
      3. 否则按挂载点实测一次读延迟，结果缓存 1 小时
         —— 覆盖「网盘先挂 NAS 再 bind 进来」这种 fstype 看不出来的情况。

    这样挂载点叫什么名字、挂了几个、混不混着放，都不用告诉服务端。
    """
    p = (path or "").replace("\\", "/")
    for mount in (cfg.get("network_mounts") or []):
        m = str(mount).rstrip("/")
        if m and (p == m or p.startswith(m + "/")):
            return True
    for root in _remote_roots():
        if root and (p == root or p.startswith(root + "/")):
            return True
    # 到这里说明挂载类型看着是本地盘 —— 再实测一次，防「bind 进来的网盘」
    root = _mount_root(p)
    hit = _speed_cache.get(root)
    now = time.time()
    if hit and now - hit[0] < _SPEED_TTL:
        return bool(hit[1])
    slow = _probe_slow(p)
    _speed_cache[root] = (now, slow)
    return slow


def _remote_cfg(cfg: dict) -> dict:
    """给网盘路径用的配置副本：串行抽、单帧超时放宽。"""
    out = dict(cfg)
    out["workers"] = max(1, int(cfg.get("remote_workers", 1)))
    out["frame_timeout"] = float(cfg.get("remote_frame_timeout", 75.0))
    return out


def _file_exists(path: str, cfg: dict) -> bool:
    """带缓存的 isfile：网盘上 stat 一次 0.7s，列表轮询里不能每次都付这个钱。

    只缓存「存在」的结果（文件被删了走 ffmpeg 失败也会被兜住），缓存 5 分钟。
    """
    if not path:
        return False
    now = time.time()
    hit = _EXISTS.get(path)
    if hit is not None and now - hit < 300:
        return True
    if os.path.isfile(path):
        _EXISTS[path] = now
        return True
    return False


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

_path_map_cache: dict = {"raw": None, "pairs": []}


def _path_map_pairs(raw: str) -> list[tuple[str, str]]:
    """`/media2=/mnt/media2,/media=/mnt/media` → [(前缀, 目标)]，按前缀长度降序。

    和字幕扩展（`extensions/public/subtitles`）**共用同一个环境变量、同一套语义**，
    用户在 compose 里只配一次就够。
    """
    if _path_map_cache["raw"] == raw:
        return _path_map_cache["pairs"]
    pairs: list[tuple[str, str]] = []
    for item in raw.split(","):
        if "=" not in item:
            continue
        src, dst = item.split("=", 1)
        src, dst = src.strip().rstrip("/"), dst.strip().rstrip("/")
        if src.startswith("/") and dst:
            pairs.append((src, dst))
    pairs.sort(key=lambda p: len(p[0]), reverse=True)
    _path_map_cache["raw"] = raw
    _path_map_cache["pairs"] = pairs
    return pairs


def _readable(path: str) -> str:
    """amane 里的路径 → 这台机器上真能打开的路径（读 `MEDIA_PATH_MAP`）。

    为什么抽帧也需要它：`media_files.path` 是 **amane 容器内**的路径
    （`/media2/xxx.mp4`）。旁挂服务如果没把同一个路径挂进来，ffmpeg 直接打不开 ——
    发布版用户尤其常见（他把媒体挂在 `/mnt/media`，amane 里却显示 `/media2`）。

    与字幕的区别：字幕**写**文件，映射不上一律失败（宁可报错也不写错地方）；
    抽帧只是**读**，所以「配了但没匹配上」时先看原路径能不能用
    （很多部署两边路径本来就一致），再决定，避免无谓地全盘失败。
    """
    p = (path or "").replace("\\", "/")
    raw = os.environ.get("MEDIA_PATH_MAP", "").strip()
    if not p or not raw:
        return p
    for prefix, target in _path_map_pairs(raw):
        if p == prefix or p.startswith(prefix + "/"):
            mapped = target + p[len(prefix):]
            if os.path.exists(mapped):
                return mapped
            return p if os.path.exists(p) else mapped
    return p


def _media_files(mid: int, readable: bool = True) -> list[dict]:
    """这部片的媒体文件。

    `readable=False` 时**不做路径映射**（`_readable` 里会 `os.path.exists`）——
    批量遍历候选时必须关掉：配置了 `MEDIA_PATH_MAP` 时，这一下 stat 会落到
    `/media2` 这种 clouddrive FUSE 上，挂载点一慢就是 200ms/条，
    「只刷某一个库」200 个候选实测被拖到 45 秒（2026-11-14 23:13 实测，
    诊断日志 `files=44.4s, pick=0s, scores=0.5s`）。真正要读文件的时候再映射。
    """
    with A.amane_db() as conn:
        rows = conn.execute(
            "SELECT id, path, size, duration, library_id FROM media_files "
            "WHERE metadata_id = ? ORDER BY id",
            (mid,),
        ).fetchall()
    return [{
        "id": int(r["id"]),
        # path 给「实际去读」用（已按 MEDIA_PATH_MAP 换成这台机器能打开的路径）；
        # apath 保留 amane 里的原路径，排查「到底映射到了哪儿」时看它。
        "path": _readable(_text(r["path"])) if readable else _text(r["path"]),
        "apath": _text(r["path"]),
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
    cached, cached_src = 0.0, ""
    try:
        with open(stamp, encoding="utf-8") as fh:
            blob = json.load(fh) or {}
        cached = float(blob.get("duration") or 0)
        cached_src = str(blob.get("source") or "")
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    # 网盘挂载：ffprobe 冷读必然超时（实测 8 秒不够，探一次白等 8 秒），
    # 而且每个请求都会探一次 —— 直接用库存片长，并把结果落盘，
    # 之后开详情页就是读一个几十字节的 json。真片长留给后台预热去补。
    if _is_remote(path, cfg):
        if cached > 0:
            return cached
        fallback = _runtime_seconds(meta_id)
        _write_stamp(stamp, fallback, "runtime")
        return fallback
    if cached > 0:
        return cached
    probed = _probe(_tool(cfg, "ffprobe"), path, cfg)
    if probed > 0:
        _write_stamp(stamp, probed, "probe")
        return probed
    # 探测失败：把库存片长也当缓存落下来（标 runtime），避免每次请求都再等 8 秒。
    fallback = _runtime_seconds(meta_id)
    if fallback > 0:
        _write_stamp(stamp, fallback, "runtime")
    return fallback


def _write_stamp(stamp: str, duration: float, source: str) -> None:
    """把片长写进该文件的 duration.json（source 标明来源，便于以后重探）。"""
    if duration <= 0:
        return
    try:
        os.makedirs(os.path.dirname(stamp), exist_ok=True)
        with open(stamp, "w", encoding="utf-8") as fh:
            json.dump({"duration": duration, "source": source}, fh)
    except OSError as exc:
        A.log(f"WARN 亮点片长缓存写不进 {stamp}: {exc}")


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


# --------------------------------------------------------------------------- #
# 短视频（2.6.2.1）：不生成 mp4，只算「从第几秒开始截 10 秒」+ 一张封面
#
# 抖音式体验的关键不是「有个视频文件」，而是「秒开 + 有声音 + 有内容」。
# 本机 mpv 本来就能从任意时间点开播，所以这里只产出四样东西：
#   { file_id, start_ms, dur_ms, score, cover_ms }
# 客户端拿 /play/{id} + start 播 10 秒，到点切下一条 —— 零转码、零存储。
#
# 与「亮点条」的关系：**共用同一批帧文件**（{root}/{fid}/{ms}.jpg）。
# 亮点条只抽 6 个「每段随机」的点，这里额外抽 SCAN_POINTS 个「均匀」点打分，
# 结果落 scores.json。两套点位互不覆盖，亮点条的行为完全不变。
#
# 网盘（/media2）不扫：单帧 75 秒，24 帧要半小时。第一版只做本地盘。
# --------------------------------------------------------------------------- #

SCAN_VERSION = 2          # 打分口径变了就 +1（派生资产版本契约，见 rules/00 §C.2）
SCAN_POINTS = 24          # 没有雪碧图时的回退：全片均匀扫多少点
SCAN_POINTS_FINE = 6      # 有雪碧图时：粗筛后只精评几个点（省 75% 空间）
SHORT_DUR_MS = 10000      # 一条短视频多长（客户端可覆盖）
# 刷一刷只认**本地盘**（/media）。`/media2` 是 clouddrive 的 FUSE 挂载，
# 拖到 10 秒要等它几十秒、stat 还可能卡住（2026-11-14 实测 44 秒/请求）。
# 候选 SQL 与「选文件」两处必须用同一个前缀，别各写一份。
SHORTS_LOCAL_PREFIX = "/media/"


def _best_spread(points: list[dict], count: int, duration: float, cfg: dict) -> list[int]:
    """把片子切成 `count` 段，每段取**分数最高**的那个扫描点，返回毫秒（升序）。

    为什么不是「全局 top-N」：那样 6 张很可能全挤在同一分钟（同一场戏），
    详情页就成了「同一个画面重复 6 次」。按段取最高分 = 又好又分散。

    这也是用户 22:26 说的「反向回去优化抽帧系统」：
    扫描本来只是给短视频用的副产品，顺手就让它把亮点条变好看了，**零额外抽帧成本**。
    """
    if not points or count <= 0:
        return []
    lo = duration * float(cfg["from_ratio"])
    hi = duration * float(cfg["to_ratio"])
    span = max(1.0, hi - lo)
    buckets: dict = {}
    for p in points:
        ms = int(p.get("ms") or 0)
        if ms <= 0:
            continue
        idx = int(((ms / 1000.0) - lo) / span * count)
        idx = max(0, min(count - 1, idx))
        cur = buckets.get(idx)
        if cur is None or float(p.get("score") or 0) > float(cur.get("score") or 0):
            buckets[idx] = p
    out: list[int] = [int(buckets[i]["ms"]) for i in sorted(buckets.keys())]
    if len(out) < count:
        chosen = set(out)
        rest = sorted((p for p in points if int(p.get("ms") or 0) not in chosen),
                      key=lambda p: float(p.get("score") or 0), reverse=True)
        out += [int(p["ms"]) for p in rest[:count - len(out)]]
    return sorted(out[:count])


def _scan_points(duration: float, count: int, cfg: dict) -> list[int]:
    """均匀铺满放映区间的扫描点，**不随机**。

    和 `_positions` 的区别：那个是「每段随机取一点」（让缩略图不重复），
    这个是「固定步长」，同一部片每次算出来的分才可比、缓存才稳定。
    """
    lo = duration * float(cfg["from_ratio"])
    hi = duration * float(cfg["to_ratio"])
    if hi - lo < count * 2:
        return []
    step = (hi - lo) / count
    return [int(round((lo + step * (i + 0.5)) * 1000)) for i in range(count)]


def _scores_path(cfg: dict, file_id: int) -> str:
    return os.path.join(_cache_root(cfg), str(file_id), "scores.json")


def _read_scores(cfg: dict, file_id: int) -> dict:
    try:
        with open(_scores_path(cfg, file_id), "r", encoding="utf-8") as fh:
            blob = json.load(fh)
    except Exception:
        return {}
    if not isinstance(blob, dict) or int(blob.get("v") or 0) != SCAN_VERSION:
        return {}                      # 版本不符 = 当没算过（旧分数不可比）
    if not isinstance(blob.get("points"), list) or len(blob["points"]) < 6:
        return {}
    return blob


def _score_image(im) -> dict:
    """给一张**已经打开的** PIL 图打分（内部缩到 160×90 再算）。

    抽出来是为了让雪碧图的格子也能直接打分（用户 23:10 要的「粗筛」）：
    雪碧图 64 格已经在盘上，零抽帧成本就能先摸一遍全片哪里值得看，
    再只对选中的几个区间去抽高清 —— 比现在「全片均匀抽 24 张高清」省 70% 空间。
    """
    import math
    try:
        from PIL import ImageFilter
    except Exception:
        return {}
    try:
        im = im.convert("RGB").resize((160, 90))
    except Exception:
        return {}
    px = list(im.getdata())
    n = len(px) or 1
    skin = 0
    lum_sum = 0
    for (r, g, b) in px:
        lum_sum += (r * 299 + g * 587 + b * 114) // 1000
        mx, mn = max(r, g, b), min(r, g, b)
        if (r > 95 and g > 40 and b > 20 and mx - mn > 15
                and r > g and r > b and abs(r - g) > 12):
            skin += 1
    skin_r = skin / n
    mean_lum = lum_sum / n
    light = 1.0 - min(1.0, abs(mean_lum - 120.0) / 120.0)
    try:
        ep = list(im.convert("L").filter(ImageFilter.FIND_EDGES).getdata())
        m = sum(ep) / n
        var = sum((v - m) ** 2 for v in ep) / n
        sharp = min(1.0, (var ** 0.5) / 40.0)
    except Exception:
        sharp = 0.5
    try:
        hist = im.convert("L").histogram()
        tot = sum(hist) or 1
        ent = 0.0
        for c in hist:
            if c:
                p = c / tot
                ent -= p * math.log2(p)
        busy = min(1.0, ent / 7.5)
    except Exception:
        busy = 0.5
    return {
        "score": round(0.45 * skin_r + 0.25 * sharp + 0.20 * light + 0.10 * busy, 4),
        "skin": round(skin_r, 3), "sharp": round(sharp, 3),
        "light": round(light, 3), "busy": round(busy, 3),
    }


def _score_jpeg(path: str) -> dict:
    """给一帧打分。纯 CPU、不用模型、毫秒级。

    四个信号（先缩到 160×90 再算）：
      skin  肤色占比 —— 这类素材的主体通常在最显眼处，是最有效的单一信号
      sharp 边缘强度 —— 排除虚焦、运动模糊、糊成一片的画面
      light 亮度适中 —— 排除黑场、白场、字幕卡
      busy  灰度熵    —— 排除纯色空镜、静止背景
    """
    try:
        from PIL import Image
    except Exception:
        return {}
    try:
        im = Image.open(path)
    except Exception:
        return {}
    return _score_image(im)


def _sprite_scores(cfg: dict, file_id: int) -> list[dict]:
    """从**雪碧图**里切格打分（粗筛），一把抽出全片 64 个点的分数。

    为什么这么做（用户 23:10 同意「粗筛 + 精评」）：
    雪碧图本来就有（64 格覆盖整片，约 98KB，零额外抽帧），先在上面摸一遍，
    挑出真正值得看的几个区间，再只对那几个点抽 320 宽的高清帧做精评。
    相比「均匀抽 24 张高清」（约 240KB/部），这条路约省 70% 空间。

    粗筛的代价是格子只有 128×72，分数不精确 —— 所以它**只用来挑候选区间**，
    最终分数仍然来自高清帧。
    """
    root = _preview_root(cfg, file_id)
    sprite = os.path.join(root, "sprite.jpg")
    meta_file = os.path.join(root, "meta.json")
    if not (os.path.isfile(sprite) and os.path.isfile(meta_file)):
        return []
    try:
        with open(meta_file, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        return []
    try:
        cols = int(meta.get("cols") or cfg.get("preview_cols", 8))
        rows = int(meta.get("rows") or cfg.get("preview_rows", 8))
        step = float(meta.get("step") or 0)
    except (TypeError, ValueError):
        return []
    if cols <= 0 or rows <= 0 or step <= 0:
        return []
    try:
        from PIL import Image
    except Exception:
        return []
    out: list[dict] = []
    try:
        with Image.open(sprite) as im:
            w, h = im.size
            tw = w // cols
            th = h // rows
            if tw <= 0 or th <= 0:
                return []
            for r in range(rows):
                for c in range(cols):
                    idx = r * cols + c
                    box = (c * tw, r * th, (c + 1) * tw, (r + 1) * th)
                    sc = _score_image(im.crop(box))
                    if not sc:
                        continue
                    sc["ms"] = int(round(idx * step * 1000))
                    out.append(sc)
    except Exception:
        return []
    return out


def _ensure_scores(cfg: dict, file_id: int, src: str, duration: float,
                   ffmpeg: str, remote: bool) -> dict:
    """确保这一部算过分（幂等）。返回 blob；条件不满足返回 {}。

    只在本地盘跑：网盘一帧 75 秒，扫一轮半小时，不如不做。
    """
    cached = _read_scores(cfg, file_id)
    if cached:
        return cached
    if remote or duration <= 60:
        return {}
    # ---- 粗筛 → 精评（用户 23:10 同意）----
    # 雪碧图 64 格已经在盘上，先在上面摸一遍（零抽帧成本），
    # 再只对挑出来的几个区间抽 320 宽的高清帧做精评。
    # 相比「均匀抽 24 张高清」（约 240KB/部），这条路约 60KB/部，省 75%。
    pts: list[int] = []
    coarse = _sprite_scores(cfg, file_id)
    if coarse:
        # 用 _best_spread 而不是「全局 top-N」：后者会让 6 个点全挤在同一场戏里
        pts = _best_spread(coarse, SCAN_POINTS_FINE, duration, cfg)
    if not pts:
        # 没有雪碧图（网盘 / 还没生成）→ 回退到原来的均匀 24 点
        pts = _scan_points(duration, SCAN_POINTS, cfg)
    if not pts:
        return {}
    todo = [(ms, _frame_path(cfg, file_id, ms)) for ms in pts]
    todo = [(ms, d) for ms, d in todo if not os.path.isfile(d)]
    if todo:
        pool = ThreadPoolExecutor(max_workers=int(cfg["workers"]))
        try:
            futs = [pool.submit(_extract, ffmpeg, src, dst, ms, cfg) for ms, dst in todo]
            # 一次最多等 40 秒：本地盘 24 帧通常 30 秒内齐；没齐的留给下一轮（图会留缓存）
            fwait(futs, timeout=40.0)
        finally:
            pool.shutdown(wait=False)
    points: list[dict] = []
    for ms in pts:
        dst = _frame_path(cfg, file_id, ms)
        if not os.path.isfile(dst):
            continue
        sc = _score_jpeg(dst)
        if not sc:
            continue
        sc["ms"] = ms
        points.append(sc)
    if len(points) < 6:
        return {}
    blob = {"v": SCAN_VERSION, "duration": round(duration, 1),
            "file_id": file_id, "scanned_at": A.now_iso(), "points": points}
    try:
        os.makedirs(os.path.dirname(_scores_path(cfg, file_id)), exist_ok=True)
        with open(_scores_path(cfg, file_id), "w", encoding="utf-8") as fh:
            json.dump(blob, fh, ensure_ascii=False)
    except Exception as exc:
        A.log(f"WARN 短视频打分落盘失败 {file_id}: {exc}")
    return blob


# 候选池缓存：按「筛选条件签名」分桶（2026-11-14）。签名 = (where, params)，空 = 全库。
_cand_cache: dict = {}


PREF_TTL = 600.0                 # 偏好画像缓存 10 分钟（这些数据不会秒变）
EXPLORE_RATIO = 0.30             # 30% 的坑位留给「探索」，防止越刷越窄（用户 22:08 强调）
_pref_cache: dict = {"at": 0.0, "actors": {}, "studios": {}}


def _split_names(raw: str) -> list[str]:
    """演员字段可能是「A,B」「A、B」「A|B」——统一拆开。"""
    out: list[str] = []
    for part in re.split(r"[,、/|;；]+", raw or ""):
        s = part.strip()
        if s:
            out.append(s)
    return out


def _pref_profile() -> dict:
    """从 user.db 算「偏好画像」：演员 / 制片商 → 亲和度（0..1）。

    信号与权重（用户 22:42 提的，**全是库里现成的，不用埋点**）：
      收藏 3.0 · 评论 2.5 · 弹幕 2.0 · 看完 1.5 · 看到一半 0.6
    选出「我反复投入的片」，再把它们身上的演员/制片商累加、按最大值归一化。
    收藏/评论是主动表达，弹幕更是「在那一秒说出了想法」，所以权重给得比「看过」高。
    """
    now = time.time()
    cached = _pref_cache.get("actors") or {}
    if cached and now - float(_pref_cache["at"]) < PREF_TTL:
        return _pref_cache
    weights: dict = {}
    probes = (
        ("SELECT DISTINCT metadata_id FROM favorites", 3.0),
        ("SELECT DISTINCT metadata_id FROM user_comments", 2.5),
        ("SELECT DISTINCT metadata_id FROM annotations", 2.0),
        ("SELECT metadata_id FROM history WHERE finished = 1", 1.5),
        ("SELECT metadata_id FROM history WHERE finished = 0 AND duration > 0 "
         "AND position * 1.0 / duration >= 0.4", 0.6),
    )
    try:
        with A.user_db() as conn:
            for sql, w in probes:
                try:
                    rows = conn.execute(sql).fetchall()
                except Exception:          # 老库可能缺某张表/某列，跳过这一项
                    continue
                for r in rows:
                    mid = int(r["metadata_id"] or 0)
                    if mid > 0:
                        weights[mid] = weights.get(mid, 0.0) + w
    except Exception:
        return _pref_cache
    actors: dict = {}
    studios: dict = {}
    if weights:
        ids = ",".join(str(int(m)) for m in weights.keys())
        try:
            with A.amane_db() as conn:
                rows = conn.execute(
                    f"SELECT id, actors, studio FROM metadata WHERE id IN ({ids})").fetchall()
        except Exception:
            rows = []
        for r in rows:
            mid = int(r["id"])
            w = float(weights.get(mid, 0.0))
            if w <= 0:
                continue
            for a in _split_names(_text(r["actors"])):
                actors[a] = actors.get(a, 0.0) + w
            st = _text(r["studio"]).strip()
            if st:
                studios[st] = studios.get(st, 0.0) + w

    def norm(d: dict) -> dict:
        if not d:
            return {}
        mx = max(d.values())
        if mx <= 0:
            return {}
        return {k: round(float(v) / mx, 3) for k, v in d.items() if v > 0}

    _pref_cache["at"] = now
    _pref_cache["actors"] = norm(actors)
    _pref_cache["studios"] = norm(studios)
    return _pref_cache


def _pref_score(actors_raw: str, studio: str) -> float:
    """某部片的偏好分（0..1）：它身上有几个我偏爱的人 / 厂。

    演员取**最强的那个**而不是平均 —— 有一个心头好就足够拉高，
    平均会把「一个强偏好 + 一堆路人」稀释掉。
    """
    prof = _pref_profile()
    amap = prof.get("actors") or {}
    smap = prof.get("studios") or {}
    if not amap and not smap:
        return 0.0
    best = 0.0
    for a in _split_names(actors_raw):
        v = float(amap.get(a, 0.0))
        if v > best:
            best = v
    st = float(smap.get((studio or "").strip(), 0.0))
    return min(1.0, 0.75 * best + 0.25 * st)


def _weighted_pick(rows: list, weights: list, k: int) -> list:
    """按权重不放回抽 k 个（权重越大越容易被抽到，但不是必然）。

    用它而不是「直接 sort 取前 k」：那样每次顺序固定、同几部永远排在前面，
    用户会觉得「怎么老是这几部」（22:06 报过类似问题）。
    """
    out: list = []
    pool = [(r, max(1e-4, float(w))) for r, w in zip(rows, weights)]
    for _ in range(min(max(0, k), len(pool))):
        total = sum(w for _, w in pool)
        x = random.uniform(0.0, total)
        acc = 0.0
        for i, (r, w) in enumerate(pool):
            acc += w
            if acc >= x:
                out.append(pool.pop(i)[0])
                break
        else:
            out.append(pool.pop()[0])
    return out


def _shorts_candidates(limit: int, where: str = "", params: tuple = ()) -> list[int]:
    """候选片池：**全库本地盘**，随机打乱（**不再把弹幕片置顶**）。

    用户 22:42 问「候选池只能是 120 部吗」—— 不该。原来写的是
    `ORDER BY id DESC LIMIT 120`，取的是「最近入库的 120 部」：库里 5000 多部，
    意味着只有最近那 120 部能被刷到，老片永远不出现。现在取**全部**本地盘片并打乱。

    **性能**（用户 22:49 提的）：库里 5000 多部，如果每个 `/shorts` 请求都全表扫一遍
    再 shuffle 5000 个元素，那是白费。这里缓存 60 秒 —— 60 秒内所有请求共用同一份候选，
    顺序也固定，所以「上下滑」不会因为候选重排而错位。

    **范围过滤**（2026-11-14，Agent3）：`where/params` 由 `_pool_filter()` 生成，
    与首页大图同一套条件。按条件签名分桶缓存 —— 否则用户改了范围还会命中旧池子。

    **弹幕置顶已去掉**（用户 2026-11-14 23:34：「感觉没意义，这里应该让用户刷到的是
    没看过的推荐内容」）。原来这里会把「有弹幕的片」排到最前，实际效果是每次进来先刷同
    一部片；现在只按候选集打乱。注意：只删了**刷一刷的排序**，
    `_annotation_ms()`（详情页高光条那套）原样保留。
    """
    now = time.time()
    sig = (where, params)
    hit = _cand_cache.get(sig)
    if hit and now - float(hit[0]) < 60.0:
        return list(hit[1])[:max(1, limit)]
    # 过滤条件里引用的都是 `m.*`（见 core/logic 的 _hero_where），所以要 join metadata
    sql = ("SELECT DISTINCT mf.metadata_id FROM media_files mf "
           "JOIN metadata m ON m.id = mf.metadata_id "
           "WHERE mf.path LIKE ? AND mf.metadata_id > 0")
    if where:
        sql += f" AND ({where})"
    # 本地盘前缀作为**第一个绑定参数**，范围和它自己的参数接在后面
    args = (SHORTS_LOCAL_PREFIX + "%",) + tuple(params)
    with A.amane_db() as conn:
        rows = conn.execute(sql, args).fetchall()
    # 候选集 = 已经过「范围过滤 + 本地盘」的那批，整体打乱即可。
    # 2026-11-14 23:34 用户明确「弹幕置顶没意义，应该让用户刷到没看过的」，
    # 所以这里不再按 anno 分 head/listed —— agent3 那条「弹幕置顶必须在筛选结果之内」
    # 的修复（防止弹幕片绕过范围）随置顶一起去掉，不再是问题。
    full = [int(r["metadata_id"]) for r in rows]
    random.shuffle(full)
    _cand_cache[sig] = (now, full)
    return full[:max(1, limit)]


def _actor_names(raw: str) -> list[str]:
    """`metadata.actors` 实际存的是 **JSON 数组字符串**（`["真田沙奈"]`）。

    早期以为是「A,B」逗号串，直接 `_split_names` 会把 `["真田沙奈"` 整段当名字，
    右侧栏头像就显示成一个 `[`（2026-11-14 21:33 真机看到的就是这个）。
    这里先按 JSON 解析，失败再退回逗号/顿号拆分（历史数据两种都有）。
    """
    s = (raw or "").strip()
    if s.startswith("["):
        try:
            arr = json.loads(s)
            if isinstance(arr, list):
                return [str(x).strip() for x in arr if str(x).strip()]
        except (TypeError, ValueError):
            pass
    return _split_names(s)


def _actor_name(raw: str) -> str:
    """刷一刷右侧栏只放**第一位**演员。"""
    names = _actor_names(raw)
    return names[0] if names else ""


def _first_image(raw) -> str:
    """`actors.image_urls` 是 JSON 数组，取第一张 http 图当头头像。"""
    try:
        urls = json.loads(raw) if isinstance(raw, str) else (raw or [])
    except (TypeError, ValueError):
        urls = []
    if isinstance(urls, list):
        for u in urls:
            if isinstance(u, str) and u.startswith("http"):
                return u
    return ""


def _actor_faces(conn, names: list[str]) -> dict:
    """名字 → (演员 id, 头像 URL)。查不到就空（客户端画首字圆形兜底）。

    id 是给「点头像进演员详情页」用的；头像 URL 为空时客户端退首字圆形。
    """
    names = [n for n in names if n]
    if not names:
        return {}
    marks = ",".join("?" for _ in names)
    try:
        rows = conn.execute(
            f"SELECT id, name, image_urls FROM actors WHERE name IN ({marks})",
            tuple(names)).fetchall()
    except Exception:
        return {}
    return {_text(r["name"]): (int(r["id"]), _first_image(r["image_urls"])) for r in rows}


def _face_url(raw: str) -> str:
    """演员头像 → **旁挂代理** `/img?b=…`，由 NAS 去取；取不到时 `/img` 会 302 回原始地址。

    用户 23:26 明确：「这个链路不是应该让 amane 完成吗？跟手机连不连得上不应该有关吧？
    如果有关那就不对了。或者说，至少要做成如果上游连不上，那么用手机的网络兜底。」

    所以顺序是：
      1. 接口给 `/img?b=<原始URL>` —— 手机只跟 NAS 说话；
      2. NAS 取到就落盘缓存（`serve_image`，第二次起零网络）；
      3. NAS 也取不到（比如 NAS 自己出海被挡）→ `_image()` 回 **302 原始地址**，
         这时才轮到手机用自己的网络去试 —— agent2 这条改动就是为这个兜底。

    代理不成立（主机不在白名单）时回退原始外链，别把这张脸吞成空串。
    """
    if not raw:
        return ""
    try:
        proxied = A.public_image(raw) if A is not None else ""
    except Exception:
        proxied = ""
    return proxied if proxied else raw


def _meta_brief(ids: list[int]) -> dict:
    if not ids:
        return {}
    marks = ",".join("?" for _ in ids)
    try:
        with A.amane_db() as conn:
            rows = conn.execute(
                f"SELECT id, number, title, runtime, poster_urls, thumb_urls, actors "
                f"FROM metadata WHERE id IN ({marks})",
                tuple(ids)).fetchall()
            # 刷一刷右侧栏要「女优头像」：metadata.actors 只有名字，脸在 actors 表里
            faces = _actor_faces(conn, [_actor_name(_text(r["actors"])) for r in rows])
    except Exception:
        return {}
    # 注意：`metadata` 没有 poster 列（只有 poster_urls / thumb_urls 两个 JSON 列），
    # 别再写 `poster` —— 2026-11-14 就是这么把整段 brief 打成空表、番号标题全空的。
    out: dict = {}
    for r in rows:
        name = _actor_name(_text(r["actors"]))
        face = faces.get(name)
        actor_id = int(face[0]) if face else 0
        # 头像走**旁挂代理**（`_face_url` → `/img?b=…`）：由 NAS 去取并落盘缓存，
        # 手机只跟 NAS 说话；NAS 也取不到时 `/img` 会 302 回原始地址，手机兜底。
        actor_img = _face_url(face[1]) if face else ""
        out[int(r["id"])] = {
            "number": _text(r["number"]),
            "title": _text(r["title"]),
            "runtime": int(r["runtime"] or 0),
            "poster": _poster_of(r),
            # 2.6.2.16：右侧栏（头像 / 爱心）用；actor_id 给「点头像进演员详情」
            "actor": name,
            "actor_img": actor_img,
            "actor_id": actor_id,
        }
    return out


_anno_cache: dict = {"at": 0.0, "map": {}}


def _anno_map() -> dict:
    """mid -> (最近一条弹幕的 t_ms, file_key)，**一次查完**。

    为什么不做成「每个候选查一次」：`/shorts` 一次要看 200 个候选，
    每个都开一次 SQL 会把请求从 0.13s 拖到 1s 以上（实测）。
    弹幕不常变，缓存 60 秒足够。
    """
    now = time.time()
    cached = _anno_cache.get("map") or {}
    if cached and now - float(_anno_cache["at"]) < 60.0:
        return cached
    out: dict = {}
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT metadata_id, t_ms, file_key FROM annotations WHERE t_ms > 0"
            ).fetchall()
        for r in rows:
            mid = int(r["metadata_id"])
            ms = int(r["t_ms"] or 0)
            prev = out.get(mid)
            if prev is None or ms > int(prev[0]):
                out[mid] = (ms, _text(r["file_key"]))
    except Exception:
        return {}
    _anno_cache["at"] = now
    _anno_cache["map"] = out
    return out


def _annotation_ms(file_id: int, mid: int) -> int:
    """这部片「用户自己发的弹幕」最近落在哪一秒（毫秒）；没有就 0。

    `annotations` 表就是用户发的弹幕（注释原话：「记『这里演到哪了 / 这段好』」），
    带 `t_ms` 与 `file_key`。**这是最值钱的高光信号** —— 用户亲手在那一秒说出了想法，
    比任何画面打分都准，所以片段起点优先用它。

    `file_key` 是 `f<media_file_id>`（弹幕跟着版本走）：只在它为空、或正好是我们要播的
    那个文件时才采用，避免多版本片按别的版本的时间轴截错位置。
    """
    hit = _anno_map().get(mid)
    if not hit:
        return 0
    ms, fk = hit
    if fk and fk != f"f{file_id}":
        return 0
    return max(0, int(ms))


SHORTS_WARM_INTERVAL = 90        # 每部之间歇 90 秒（与 preview warm 同量级）


def _shorts_warm_once(cfg: dict, ffmpeg: str) -> bool:
    """扫一部「还没打过分」的本地盘片。返回是否真的干了活。

    只挑本地盘：网盘一帧几秒，扫一部要半小时，塞进后台等于把 CD2 占死。

    **预算闸门**（用户 22:49）：先看缓存用了多少，到了预算 90% 就**停下不再产生新帧**。
    不能「先扫再淘汰」—— 那样会抖动：扫到 1.8GB → 淘汰最早的 → 那些片又变成「没扫过」
    → 再扫一遍 → 无限循环，IO 永远不停，缓存永远在冷热交替。
    """
    budget = int(cfg.get("preview_budget_mb", 2048))
    if budget > 0 and _cache_used_mb(cfg) >= budget * 0.9:
        A.log(f"INFO 短视频预热暂停：缓存已用 {_cache_used_mb(cfg):.0f}MB / 预算 {budget}MB")
        return False
    for mid in _shorts_candidates(60):
        try:
            files = _media_files(mid)
            target = _pick(files, "")
            if target is None or not target["path"]:
                continue
            if _is_remote_fast(target["path"], cfg):
                continue
            if _read_scores(cfg, target["id"]):
                continue                        # 扫过了
            dur = target["duration"] or _runtime_seconds(mid)
            if dur <= 60:
                continue
            return bool(_ensure_scores(cfg, target["id"], target["path"], dur, ffmpeg, False))
        except Exception as exc:                # noqa: BLE001
            A.log(f"WARN 短视频预热 {mid}: {exc}")
    return False


def _shorts_warm_loop(interval: int) -> None:
    """闲时预热：一部接一部慢慢扫，不等用户来触发。

    为什么要它：`/shorts` 原本是「用户打开才扫一部」，新用户第一次进要对着
    「素材正在准备」干等。改成后台闲时跑，用户打开时池子里已经有东西。

    **风险控制（用户 22:26 明确要求）**：
      * **串行**（一次一部、`workers` 那套并发只用于单部内部的 24 帧）；
      * **间隔 90 秒**，不给 NAS 持续压力；
      * **只扫本地盘**，网盘完全跳过；
      * **可随时关**（客户端「刷一刷素材」开关 → `prefs.shorts_warm`），下一轮立刻生效；
      * **占空间受现有预算管**（帧文件和进度条预览共用同一份缓存，每轮先 `_preview_trim`）。
    """
    while True:
        try:
            cfg = effective_cfg()
            prefs = load_prefs()
            if not bool(prefs.get("shorts_warm", cfg.get("shorts_warm", True))):
                time.sleep(120)
                continue
            ffmpeg = _tool(cfg, "ffmpeg")
            if not ffmpeg:
                return
            # 帧文件和「进度条预览」共用同一个缓存目录，先按预算清一遍再扫，
            # 否则短视频会悄悄把用户的磁盘吃满。
            raw_budget = prefs.get("budget_mb")
            if raw_budget is None:
                raw_budget = cfg.get("preview_budget_mb", 2048)
            cfg["preview_budget_mb"] = _int(raw_budget, 2048, 0, 10 ** 6)
            try:
                _preview_trim(cfg)
                _frames_trim(cfg)
            except Exception as exc:            # noqa: BLE001
                A.log(f"WARN 短视频预热清理: {exc}")
            did = _shorts_warm_once(cfg, ffmpeg)
            time.sleep(max(20, interval) if did else 300)
        except Exception as exc:                # noqa: BLE001
            A.log(f"WARN 短视频预热异常: {exc}")
            time.sleep(120)


_scan_lock = threading.Lock()


def _kick_scan(mids: list[int]) -> None:
    """后台扫一部（不阻塞请求）。

    短视频的素材是靠「慢慢攒」的：现扫一部要抽 24 帧、约 30~40 秒，
    绝不能卡在请求里。所以每次 `/shorts` 发现有没扫过的片，就丢一个到后台扫，
    下次打开就多一条能刷的。已有线程在跑就直接跳过（同一时刻只扫一部，别抢 IO）。
    """
    if not mids or not _scan_lock.acquire(blocking=False):
        return

    def run() -> None:
        try:
            cfg = effective_cfg()
            ffmpeg = _tool(cfg, "ffmpeg")
            if not ffmpeg:
                return
            for mid in mids[:2]:
                try:
                    files = _media_files(mid)
                    target = _pick(files, "")
                    if target is None or not target["path"]:
                        continue
                    if _is_remote(target["path"], cfg):
                        continue
                    dur = target["duration"] or _duration_of(
                        cfg, target["id"], target["path"], mid)
                    if dur > 0:
                        _ensure_scores(cfg, target["id"], target["path"], dur, ffmpeg, False)
                except Exception as exc:
                    A.log(f"WARN 短视频扫描 {mid} 失败: {exc}")
        finally:
            _scan_lock.release()

    threading.Thread(target=run, daemon=True, name="shorts-scan").start()


def _pool_filter(query) -> tuple[str, tuple]:
    """把「候选池条件」翻成 amane DB 的 WHERE —— **复用首页大图那套**（core.logic）。

    参数与 `/api/user/home` 完全一致，客户端也是同一个拼法（`common/PoolParams.ets`）：
      预设：`pool=all|fav|unwatched|rated|recent`
      自由：`plib=1,2 & ptag=a,b & pactor=xx & pyear_from=2015 & pyear_to=2025
             & pmin_score=7 & pstate=any|unwatched|watched|fav|rated`
    自由条件优先于预设（与 `build_hero` 同口径）。返回 `(where, params)`，空串=全库。

    为什么要复用而不是另写一套：这两处筛的是同一批 metadata，口径一分叉，
    用户就会看到「首页大图明明按这个范围挑，刷一刷却不认」。
    """
    def one(name: str) -> str:
        return (_one(query, name, "") or "").strip()

    def many(name: str) -> list:
        raw = one(name)
        return [x.strip() for x in raw.split(",") if x.strip()] if raw else []

    pool = one("pool") or "all"
    spec: dict = {}
    if many("plib"):
        spec["libs"] = many("plib")
    if many("ptag"):
        spec["tags"] = many("ptag")
    if one("pactor"):
        spec["actor"] = one("pactor")
    if one("pyear_from"):
        spec["year_from"] = one("pyear_from")
    if one("pyear_to"):
        spec["year_to"] = one("pyear_to")
    if one("pmin_score"):
        spec["min_score"] = one("pmin_score")
    st = one("pstate")
    if st and st != "any":
        spec["state"] = st

    try:
        # `A` 是扩展 api 命名空间，里面**没有**这两个私有函数（只暴露 user_db/amane_db/log…），
        # 所以直接 import core.logic。扩展跑在服务端进程里，core 包一定在 sys.path 上。
        from core.logic import _hero_pool_where, _hero_where
        if spec:
            return _hero_where(spec)
        if pool != "all":
            return _hero_pool_where(pool)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN shorts 候选范围解析失败，退回全库: {exc}")
    return "", ()


def shorts(handler, query, *_):
    """GET /api/user/shorts?limit=20 —— 一条条「从 T 秒开始截 10 秒」的片段。

    只回**已经算过分**的片（`scores.json` 命中）；没算过的跳过并计入 pending，
    由后台 warm 慢慢补 —— 现扫一部要 30~40 秒，不能卡在请求里。

    排序按「分数 × 新鲜度」：分数高的在前，同分按 metadata_id 大的（新片）优先，
    这样刚入库的、画面有内容的会先被刷到。
    """
    cfg = effective_cfg()
    if not cfg.get("enabled", True):
        return handler._json({"ok": False, "reason": "亮点扩展未启用", "items": []})
    ffmpeg = _tool(cfg, "ffmpeg")
    if not ffmpeg:
        return handler._json({"ok": False, "reason": "服务端没有 ffmpeg", "items": []})

    limit = _int(_one(query, "limit", ""), 20, 1, 60)
    dur_ms = _int(_one(query, "dur", ""), SHORT_DUR_MS, 3000, 30000)
    # 候选范围（2026-11-14）：与首页大图同一套条件；空串 = 全库，行为与旧版一致
    where, wparams = _pool_filter(query)

    # 命中 3 分钟缓存直接回（2.6.1.81）：进负一屏不该每次都重扫候选。
    # key 里带范围签名，否则改了范围会拿到旧范围的结果。
    cached = _shorts_cached(limit, dur_ms, (where, wparams))
    if cached is not None:
        return handler._json(cached)

    mids = _shorts_candidates(600, where, wparams)
    if not mids:
        # 范围里一部都没有（例如只选了网盘库，而刷一刷只吃本地盘）——
        # 明确说出来，别让用户以为是坏了
        return handler._json({"ok": True, "items": [], "pending": 0,
                              "reason": "这个范围里没有可刷的片段（刷一刷只取本地盘）"})
    # 偏好画像（演员/制片商）——一次批量查，别每个候选查一回
    pref = _pref_profile()
    has_pref = bool(pref.get("actors") or pref.get("studios"))
    meta_info: dict = {}
    if has_pref and mids:
        try:
            ids = ",".join(str(int(m)) for m in mids[:400])
            with A.amane_db() as conn:
                for r in conn.execute(
                        f"SELECT id, actors, studio FROM metadata WHERE id IN ({ids})").fetchall():
                    meta_info[int(r["id"])] = (_text(r["actors"]), _text(r["studio"]))
        except Exception:
            meta_info = {}
    rows: list[dict] = []
    pending = 0
    miss: list[int] = []               # 没扫过分的，交给后台慢慢补
    # 候选是全库打乱的，前几十个很可能都没扫过分；多看一些才捞得到已打分的，
    # 但也不能无限看（每个候选要查一次库 + 读一次 scores.json）。200 个约 0.2 秒。
    scan_cap: int = max(limit * 3, 200)
    _t_loop = time.time()
    _t_files = 0.0
    for mid in mids:
        if len(rows) >= scan_cap:
            break
        _ta = time.time()
        # **用 amane 原路径判断本地盘，并且不做路径映射**（2026-11-14 23:1x 实测）：
        # 批量遍历时 `_readable()` 会对每条路径做 `os.path.exists`，碰上 `/media2`
        # 的 FUSE 挂载点，一条就 200ms —— 「只刷某一个库」被拖到 45 秒就是这么来的。
        # 这里只要 `/media/` 开头的（本地盘），判定完再选文件，全程不碰文件系统。
        files = [f for f in _media_files(mid, readable=False)
                 if str(f.get("apath") or "").replace("\\", "/").startswith(SHORTS_LOCAL_PREFIX)]
        _t_files += time.time() - _ta
        if not files:
            continue
        target = _pick(files, "")
        if target is None:
            continue
        # 网盘不刷：上面已按 `/media/` 前缀筛过，这里不再逐条探测（`_is_remote_fast`
        # 也只读配置/挂载表，但没必要在 200 次循环里重复）。
        blob = _read_scores(cfg, target["id"])
        total = float(blob.get("duration") or 0) if blob else 0.0
        if total <= 0:
            total = float(target["duration"] or 0)
        if total <= 0:
            total = _runtime_seconds(mid)
        # 弹幕优先**在刷一刷里关掉**（用户 2026-11-14 23:34：「感觉没意义，这里应该让用户
        # 刷到的是没看过的推荐内容」）。注意只关这一条路径 —— `_annotation_ms()` 本身保留，
        # 详情页的高光条等别处还在用，别顺手删。
        if blob:
            pts = blob.get("points") or []
            if not pts:
                continue
            best = max(pts, key=lambda p: float(p.get("score") or 0))
            start = int(best["ms"])
            score = float(best.get("score") or 0)
            scored = 1
        else:
            # 2.6.1.53（用户 22:08）：**没打分的先纯随机上场**。
            # 冷启动时如果只回「算过分」的，列表就是空的（用户 22:06 遇到的「能刷的太少」）。
            # 随机点避开片头 logo 与片尾字幕，和抽帧区间同口径。
            if total <= 60:
                miss.append(mid)
                continue
            lo = int(total * float(cfg["from_ratio"]))
            hi = int(total * float(cfg["to_ratio"]))
            start = random.randint(lo, max(lo + 1, hi - dur_ms // 1000)) * 1000
            score = 0.0
            scored = 0
            pending += 1
            miss.append(mid)
        # 末尾太近就往前挪，免得一条 10 秒的片段只剩 2 秒
        if total > 0 and start + dur_ms > total * 1000:
            start = max(0, int(total * 1000) - dur_ms - 1000)
        _actors, _studio = meta_info.get(mid, ("", ""))
        rows.append({
            "meta_id": mid,
            "file_id": target["id"],
            "start": round(start / 1000.0, 1),
            "dur": round(dur_ms / 1000.0, 1),
            "cover": f"/api/user/highlights/{target['id']}/{int(round(start / 1000.0 * 1000))}.jpg",
            "score": score,
            "skin": 0.0 if not scored else 0.0,
            "scored": scored,
            # 偏好分只在内部用来排序，不返回给客户端（用户 22:06：别把「为什么推这条」写出来）
            "pref": _pref_score(_actors, _studio) if has_pref else 0.0,
        })

    _loop_s = time.time() - _t_loop
    if _loop_s > 2.0:
        # 正常应 <1s（2026-11-14 23:2x 修掉 `_readable` 的逐条 stat 后：全库 0.9s、
        # 单库 0.26s）。超过 2s 记一笔，下次再慢能直接看出是取文件那步还是打分那步。
        A.log("shorts 候选扫描慢: %.1fs / 看 %d 候选 / 出 %d 条 | 取文件 %.1fs"
              % (_loop_s, len(mids), len(rows), _t_files))

    # 2.6.1.58：**三池、各自打乱、按「人工标注 > 画面打分 > 纯随机」排**。
    #   弹幕池：用户自己标过「这段好」的时刻，永远最先出现；
    #   打分池：算法选出的高光；
    #   随机池：还没扫到的片，保证冷启动也有得刷（也是「探索」的来源）。
    #   每池各自 shuffle，所以每次进来顺序都不同（用户 22:06「每次进来都一样」）。
    #   TODO（用户 22:08）：把收藏/评论/评分/完成度按演员·标签聚合进权重，
    #   并**固定保留一部分随机池**做探索，防止越刷越窄（算法收敛）。
    anno_rows: list[dict] = [r for r in rows if int(r.get("scored") or 0) == 2]
    scored_rows: list[dict] = [r for r in rows if int(r.get("scored") or 0) == 1]
    plain_rows: list[dict] = [r for r in rows if int(r.get("scored") or 0) == 0]
    random.shuffle(anno_rows)
    if has_pref and len(scored_rows) >= 2:
        # 偏好加权 + **防收敛**（用户 22:08 / 23:26）：
        #   70% 的坑位按「偏好 0.6 + 画面 0.4」加权随机挑；
        #   剩下 30% 从「没走偏好」的池子里随机补 —— 那是**探索位**，
        #   保证不会因为偏好把自己锁死在一个演员/一个厂里越刷越窄。
        n_explore = max(1, int(round(limit * EXPLORE_RATIO)))
        n_pref = max(1, limit - n_explore)
        weights = [0.6 * float(r.get("pref") or 0.0) + 0.4 * float(r.get("score") or 0.0)
                   for r in scored_rows]
        picked = _weighted_pick(scored_rows, weights, n_pref)
        picked_ids = set(id(r) for r in picked)
        rest = [r for r in scored_rows if id(r) not in picked_ids]
        # 剩下的坑位用「没被抽中的打分段 + 没打过分的随机段」混着补满 ——
        # 这一截就是探索区：里面既有高分但没被偏好选中的，也有完全随机的。
        # 注意**不能**只取 n_explore 条，那样总数会缩水（第一版就写成上限了，20 条变 9 条）。
        tail = rest + plain_rows
        random.shuffle(tail)
        rows = anno_rows + picked + tail
    else:
        # 还没有任何偏好信号（新用户）：三池各自打乱，纯随机
        random.shuffle(scored_rows)
        random.shuffle(plain_rows)
        rows = anno_rows + scored_rows + plain_rows
    rows = rows[:limit]
    brief = _meta_brief([r["meta_id"] for r in rows])
    for r in rows:
        info = brief.get(r["meta_id"]) or {}
        r["number"] = info.get("number", "")
        r["title"] = info.get("title", "")
        r["runtime"] = info.get("runtime", 0)
        # 铺底/占位优先用**影片海报**（一定有）；首帧可能还没抽出来（2.6.1.90）
        r["poster"] = info.get("poster", "")
        # 右侧栏：女优名 + 头像 + id（2.6.2.16，仿抖音；id 用来跳演员详情）
        r["actor"] = info.get("actor", "")
        r["actor_img"] = info.get("actor_img", "")
        r["actor_id"] = info.get("actor_id", 0)
    # 有没扫过的就丢一个到后台 —— 用户这次刷到的少，下次打开会更多
    _kick_scan(miss)
    payload = {"ok": True, "items": rows, "pending": pending, "scan_version": SCAN_VERSION}
    # 2.6.1.81（用户 00:09）：**结果缓存 3 分钟**。
    # 以前每次进负一屏都要重扫候选（`_shorts_candidates(600)` + 逐条读 scores/media），
    # 冷启动要等好几秒。缓存后同一批人在 3 分钟内再进来是瞬开；
    # 池子本身带随机（三池 shuffle），3 分钟换一批对「刷」的体感没有损失。
    with _SHORTS_LOCK:
        _SHORTS_CACHE[_shorts_key(limit, dur_ms, (where, wparams))] = (time.time(), payload)
    return handler._json(payload)


_SHORTS_CACHE: dict = {}
_SHORTS_LOCK = threading.Lock()
SHORTS_TTL = 180.0


def _shorts_key(limit: int, dur_ms: int, sig: tuple = ("", ())) -> tuple:
    return (int(limit), int(dur_ms), str(SCAN_VERSION), sig)


def _shorts_cached(limit: int, dur_ms: int, sig: tuple = ("", ())):
    """命中就返回 payload；过期返回 None。`sig` = 候选范围签名（不同范围分开缓存）。"""
    key = _shorts_key(limit, dur_ms, sig)
    with _SHORTS_LOCK:
        hit = _SHORTS_CACHE.get(key)
        if hit is not None and time.time() - hit[0] < SHORTS_TTL:
            return hit[1]
        if hit is not None:
            _SHORTS_CACHE.pop(key, None)
    return None


def _pick_path(cfg: dict, file_id: int, ms: int) -> str:
    """用户自选的关键帧单独一张大图：亮点条只要 320 宽，剧照得能看，1280 起步。"""
    return os.path.join(_cache_root(cfg), "picks", str(file_id), f"{ms}.jpg")


def _extract(ffmpeg: str, src: str, dst: str, ms: int, cfg: dict, width: int = 0) -> bool:
    """抽一帧落盘。失败返回 False（不抛，一个点失败不影响整条）。"""
    now = time.time()
    cooldown = float(cfg.get("fail_cooldown", 600) or 0)
    with _LOCK:
        if os.path.isfile(dst):
            return True
        if dst in _INFLIGHT:
            return False
        # 冷却期内的失败点直接跳过：客户端轮询会反复请求同一个点，
        # 每次都重起一次网盘冷读（几十秒），等于把服务端钉在这几个点上。
        failed_at = _FAILED.get(dst)
        if failed_at is not None and cooldown > 0 and now - failed_at < cooldown:
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
            with _LOCK:
                _FAILED[dst] = time.time()
            return False
        os.replace(tmp, dst)
        with _LOCK:
            _FAILED.pop(dst, None)
        return True
    except (subprocess.SubprocessError, OSError) as exc:
        A.log(f"WARN 亮点抽帧异常 {src}@{ms}ms: {exc}")
        with _LOCK:
            _FAILED[dst] = time.time()
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
    # 网盘上 isfile 一次 0.7s（客户端每轮都请求），走带缓存的版本
    if not src or not _file_exists(src, cfg):
        return handler._json({"ok": False, "reason": "文件不在线（网盘没挂上？）", "items": []})

    ffmpeg = _tool(cfg, "ffmpeg")
    if not ffmpeg:
        return handler._json({"ok": False, "reason": "服务端没有 ffmpeg", "items": []})

    # 网盘：串行抽 + 单帧长超时（6 并发一起怼只会一起超时）
    remote = _is_remote(src, cfg)
    run_cfg = _remote_cfg(cfg) if remote else cfg

    count = _int(_one(query, "n", ""), int(cfg["count"]), 1, 16)
    duration = target["duration"] or _duration_of(cfg, target["id"], src, meta_id)
    if duration <= 0:
        return handler._json({"ok": False, "reason": "拿不到片长", "items": []})

    # seed 缺省 = 文件 id：同一部片每次打开位置固定，缩略图命中缓存；
    # 客户端要「换一批」时传个随机 seed 即可（旧图留着，回头再命中）。
    seed = _int(_one(query, "seed", ""), target["id"], 0, 2 ** 31 - 1)
    ms_list = _positions(duration, count, seed, cfg)
    # 2.6.1.64：这部的分数已经算过 → **从扫描点里挑「每段最好看」的那几张**，
    # 而不是「每段随机取一点」。帧已经在盘上，等于零成本把详情页的剧照变好看。
    # 客户端传了 seed 表示「换一批」，那种情况仍走原来的随机逻辑。
    if _one(query, "seed", "") == "":
        _blob = _read_scores(cfg, target["id"])
        if _blob:
            _better = _best_spread(_blob.get("points") or [], count, duration, cfg)
            if len(_better) >= count:
                ms_list = _better
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
        pool = ThreadPoolExecutor(max_workers=int(run_cfg["workers"]))
        try:
            futs = [pool.submit(_extract, ffmpeg, src, dst, ms, run_cfg) for ms, dst in todo]
            # 第一屏一张都还没有时才等一会儿（本地盘 3 秒内基本齐）；
            # 已经有图就直接回 —— 客户端是轮询式的，不能每轮都卡这么久。
            # 网盘上单帧本来就要几十秒，等也等不到，直接回「正在抽」让客户端轮询。
            if not ready and not remote:
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
    # 网盘不能开 12 并发：CD2 每次 seek 都要重新拉分块，12 路一起怼只会全超时
    # （用户 23:10 要求「网盘也能有预览」）。串行 1 路，配合预热的长间隔慢慢跑。
    workers = 1 if _is_remote_fast(src, cfg) else min(int(cfg.get("preview_workers", 12)), n)
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

        with ThreadPoolExecutor(max_workers=workers) as pool:
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
_SHORTS_WARM_STARTED = False


_used_cache: dict = {"at": 0.0, "mb": 0.0}


def _cache_used_mb(cfg: dict) -> float:
    """`{cache}` 下所有东西已经占了多少 MB（雪碧图 + 各片的亮点帧）。

    为什么要单独算：`_preview_trim` 只管 `{cache}/preview/`（雪碧图），
    而亮点帧落在 `{cache}/{file_id}/*.jpg` —— 全库 5000 部 × 24 帧 × 15KB ≈ **1.8GB**，
    原来**完全不在任何预算之下**（用户 22:49 提醒的就是这个）。

    遍历上万个小文件要 1~2 秒，所以结果缓存 5 分钟：预热每 90 秒跑一次，
    拿到的数字够新，又不会每轮都白扫一遍磁盘。
    """
    now = time.time()
    if _used_cache["at"] > 0 and now - float(_used_cache["at"]) < 300.0:
        return float(_used_cache["mb"])
    root = _cache_root(cfg)
    total = 0
    try:
        for name in os.listdir(root):
            d = os.path.join(root, name)
            if not os.path.isdir(d):
                continue
            try:
                for fn in os.listdir(d):
                    try:
                        total += os.path.getsize(os.path.join(d, fn))
                    except OSError:
                        pass
            except OSError:
                continue
    except OSError:
        return 0.0
    mb = total / (1024.0 * 1024.0)
    _used_cache["at"] = now
    _used_cache["mb"] = mb
    return mb


def _frames_trim(cfg: dict) -> None:
    """亮点帧目录的总量管理：超预算就按「最久没访问」删整目录。

    和 `_preview_trim` 的分工：那个管 `preview/`（雪碧图），这个管 `{file_id}/`（帧 + 分数）。
    两个合起来才是用户看到的那个「占用上限」—— 只算一半的话，用户设 512MB，
    实际能涨到 2GB+ 还不知道。
    """
    budget = int(cfg.get("preview_budget_mb", 2048)) * 1024 * 1024
    if budget <= 0:
        return
    root = _cache_root(cfg)
    entries: list = []
    total = 0
    try:
        for name in os.listdir(root):
            d = os.path.join(root, name)
            if name == "preview" or not os.path.isdir(d):
                continue
            size = 0
            try:
                for fn in os.listdir(d):
                    try:
                        size += os.path.getsize(os.path.join(d, fn))
                    except OSError:
                        pass
                mt = os.stat(d).st_mtime
            except OSError:
                continue
            if size > 0:
                entries.append((mt, size, d))
                total += size
    except OSError:
        return
    if total <= budget:
        return
    entries.sort(key=lambda e: e[0])
    for _mt, size, d in entries:
        if total <= budget:
            break
        try:
            shutil.rmtree(d, ignore_errors=True)
            total -= size
        except OSError:
            pass


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


def _watched_mids() -> set:
    """看过 + 收藏的片（`history` ∪ `favorites`）。

    用户 23:10 定的口径：**网盘片只给这些做预览**。
    理由很实在——网盘是本项目自己折腾出来的用法（CD2 挂 115），大部分用户根本不用；
    而给网盘的每一部生成雪碧图要 3~8 分钟（64 格逐格 seek），全库铺不现实。
    但「看过/收藏」的是用户真在意的，值得花这个时间。
    """
    out: set = set()
    try:
        with A.user_db() as conn:
            rows = conn.execute(
                "SELECT DISTINCT metadata_id FROM history "
                "UNION SELECT metadata_id FROM favorites").fetchall()
        for r in rows:
            v = r[0]
            if v is not None:
                out.add(int(v))
    except Exception:
        return set()
    return out


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
                # metadata_id 可能为 NULL（孤儿文件）：下面要 int() 它，不排除会抛
                # 「int() argument must be ... not 'NoneType'」，整条预热循环每轮刷一条 WARN。
                "AND metadata_id IS NOT NULL "
                "ORDER BY id DESC LIMIT 800").fetchall()
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 预览预热查不到库: {exc}")
        return False
    watched = _watched_mids()
    for r in rows:
        fid = int(r["fid"])
        # 预热同样要走 MEDIA_PATH_MAP：发布版用户的媒体不一定挂在 amane 那个路径下
        src = _readable(_text(r["path"]))
        if not src or not os.path.isfile(src):
            continue
        # 网盘只做「看过的 / 收藏的」（用户 23:10）：每部 3~8 分钟，全库铺不现实
        if _is_remote_fast(src, cfg) and int(r["mid"]) not in watched:
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
            # 预算以用户设置为准（0 = 不设上限）。偏好里可能是 null（清空过 / 老版本写的），
            # 直接 int(None) 会让整个预热循环抛异常、每轮刷一条 WARN。
            raw_budget = prefs.get("budget_mb")
            if raw_budget is None:
                raw_budget = cfg.get("preview_budget_mb", 2048)
            cfg["preview_budget_mb"] = _int(raw_budget, 2048, 0, 10 ** 6)
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
    fs = _frames_stats(cfg)
    root = _cache_root(cfg)
    handler._json({
        "ok": True,
        "enabled": bool(cfg.get("preview_enabled", True)),
        "warm": bool(prefs.get("warm", cfg.get("preview_warm", True))),
        "shorts_warm": bool(prefs.get("shorts_warm", cfg.get("shorts_warm", True))),
        "budget_mb": int(prefs.get("budget_mb", cfg.get("preview_budget_mb", 2048))),
        "interval": int(cfg.get("preview_warm_interval", 120)),
        "used_mb": st["used_mb"],
        "count": st["count"],
        # 刷一刷/亮点帧单独报（用户 23:02：要看得见各占多少、别变成清不掉的屎山）
        "frames_mb": fs["mb"],
        "frames_count": fs["count"],
        "frames_scored": fs["scored"],
        "total_mb": round(float(st["used_mb"]) + float(fs["mb"]), 1),
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


def _frames_stats(cfg: dict) -> dict:
    """亮点帧 / 刷一刷素材的统计（和 preview 雪碧图**分开算**）。

    为什么要分开报：用户 23:02 担心「硬盘里出现十几 G 还没法清理的屎山」。
    那就必须让他看得见**每一类各占多少、各有多少部**，而不是只给一个总数 ——
    只给总数的话，用户不知道该清哪一项，也不敢清。
    """
    root = _cache_root(cfg)
    total = 0
    count = 0
    scored = 0
    try:
        for name in os.listdir(root):
            d = os.path.join(root, name)
            if name == "preview" or not os.path.isdir(d):
                continue
            size = 0
            has_score = False
            try:
                for fn in os.listdir(d):
                    try:
                        size += os.path.getsize(os.path.join(d, fn))
                    except OSError:
                        pass
                    if fn == "scores.json":
                        has_score = True
            except OSError:
                continue
            if size > 0:
                count += 1
                total += size
                if has_score:
                    scored += 1
    except OSError:
        pass
    return {"mb": round(total / 1048576.0, 1), "count": count, "scored": scored}


def preview_purge(handler, query, *_):
    """POST /api/user/preview/purge —— 清缓存（省空间用）。

    `?what=` 决定清哪一块（用户 23:02 要求「能清理」）：
      `sprite`（默认，兼容老客户端）= 只清进度条预览的雪碧图；
      `frames` = 只清亮点帧 / 刷一刷素材（连带 scores.json，那本来就是从帧算出来的）；
      `all`    = 两块都清。
    """
    cfg = effective_cfg()
    what = _one(query, "what", "sprite").strip().lower()
    if what not in ("sprite", "frames", "all"):
        what = "sprite"
    removed = 0
    if what in ("sprite", "all"):
        root = os.path.join(_cache_root(cfg), "preview")
        try:
            for name in os.listdir(root):
                d = os.path.join(root, name)
                shutil.rmtree(d, ignore_errors=True)
                removed += 1
        except OSError:
            pass
    if what in ("frames", "all"):
        root = _cache_root(cfg)
        try:
            for name in os.listdir(root):
                if name == "preview":
                    continue
                d = os.path.join(root, name)
                if not os.path.isdir(d):
                    continue
                shutil.rmtree(d, ignore_errors=True)
                removed += 1
        except OSError:
            pass
        # 目录都删了，用量缓存立刻失效，否则设置页还显示旧数字
        _used_cache["at"] = 0.0
        _cand_cache["at"] = 0.0
    handler._json({"ok": True, "removed": removed, "what": what})


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


# --------------------------------------------------------------------------- #
# 临时封面（2.6.1.50）：没有正式封面的片，拿「第三张截帧」顶上
#
# 用户口径：「无封面时用截帧；有正式封面时自动让位（上游后补 / 手动换）」。
#
# 让位**不靠删数据**：核心只在这部片的 `poster` 为空时才来要临时封面
# （见 server.py `fill_temp_covers`）。所以上游后来补了海报、或者用户手动换了
# 封面之后，`poster` 自然非空，这个端点就再也不会被请求 —— 不需要清理、也不会
# 出现「临时图盖住真封面」。
#
# 为什么是第 3 张：亮点条固定 6 个点（`_positions`，seed = 文件 id，所以每部片
# 固定），第 3 张落在片中前段，既躲开片头 logo，也不容易撞片尾字幕。
# 单独抽一份 720 宽的 `*.cover.jpg`：亮点条那份只有 320 宽，塞进详情页头图会糊。
# --------------------------------------------------------------------------- #

TEMP_COVER_DDL = """
CREATE TABLE IF NOT EXISTS temp_cover (
    metadata_id INTEGER PRIMARY KEY,
    file_id     INTEGER NOT NULL,
    ms          INTEGER NOT NULL,
    ready       INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT NOT NULL
);
"""

TEMP_COVER_INDEX = 2          # 第 3 张（0 基）
TEMP_COVER_WIDTH = 720        # 封面要撑详情页头图，320 不够
_TEMP_LOCK = threading.Lock()
_TEMP_KICKING: set = set()
_TEMP_PREPARING: set = set()


def _temp_cover_path(cfg: dict, file_id: int, ms: int) -> str:
    return os.path.join(_cache_root(cfg), str(file_id), f"{ms}.cover.jpg")


def _temp_url(mid: int) -> str:
    return f"/api/user/tempcover/{mid}.jpg"


def _temp_choice(mid: int, cfg: dict):
    """挑「第 3 张」的 (file_id, ms)。挑不出来返回 None。"""
    target = _pick(_media_files(mid), "")
    if target is None:
        return None
    src = target["path"]
    if not src or not _file_exists(src, cfg):
        return None
    duration = target["duration"] or _duration_of(cfg, target["id"], src, mid)
    if duration <= 0:
        return None
    count = max(int(cfg["count"]), TEMP_COVER_INDEX + 1)
    ms_list = _positions(duration, count, int(target["id"]), cfg)
    return int(target["id"]), int(ms_list[TEMP_COVER_INDEX])


def _temp_set(mid: int, file_id: int, ms: int, ready: int) -> None:
    with A.user_db() as conn:
        conn.execute(
            "INSERT INTO temp_cover(metadata_id, file_id, ms, ready, updated_at) "
            "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
            "file_id = excluded.file_id, ms = excluded.ms, "
            "ready = excluded.ready, updated_at = excluded.updated_at",
            (mid, file_id, ms, ready, A.now_iso()))


def _kick_temp(mid: int, file_id: int, ms: int) -> None:
    """后台抽这一帧。同一 (文件, 毫秒) 不重复起 ffmpeg。"""
    cfg = effective_cfg()
    key = (file_id, ms)
    with _TEMP_LOCK:
        if key in _TEMP_KICKING:
            return
        _TEMP_KICKING.add(key)

    def work() -> None:
        try:
            ffmpeg = _tool(cfg, "ffmpeg")
            target = next((f for f in _media_files(mid) if f["id"] == file_id), None)
            if not ffmpeg or target is None or not target["path"]:
                return
            remote = _is_remote(target["path"], cfg)
            run_cfg = _remote_cfg(cfg) if remote else cfg
            dst = _temp_cover_path(cfg, file_id, ms)
            if _extract(ffmpeg, target["path"], dst, ms, run_cfg, TEMP_COVER_WIDTH):
                _temp_set(mid, file_id, ms, 1)
                A.log(f"临时封面已生成 mid={mid} file={file_id} ms={ms}")
        except Exception as exc:  # noqa: BLE001
            A.log(f"WARN 临时封面抽帧失败 {mid}: {exc}")
        finally:
            with _TEMP_LOCK:
                _TEMP_KICKING.discard(key)

    threading.Thread(target=work, daemon=True, name=f"temp-cover-{mid}").start()


def _temp_prepare(mid: int, cfg: dict) -> None:
    """算一次「第 3 张」并写台账；帧不在盘上就让 `_kick_temp` 去抽。

    **同步调用会有一次 ffprobe**（本地盘几毫秒、冷网盘可能几秒），所以正常路径
    只在后台线程里调它（`_temp_prepare_run`），请求线程永不阻塞。
    """
    try:
        got = _temp_choice(mid, cfg)
        if got is None:
            return
        fid, ms = got
        ready = 1 if os.path.isfile(_temp_cover_path(cfg, fid, ms)) else 0
        _temp_set(mid, fid, ms, ready)
        if not ready:
            _kick_temp(mid, fid, ms)
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 临时封面挑帧失败 {mid}: {exc}")


def _temp_prepare_run(mid: int, cfg: dict) -> None:
    _temp_prepare(mid, cfg)
    with _TEMP_LOCK:
        _TEMP_PREPARING.discard(mid)


def temp_covers(ids) -> dict:
    """无正式封面的片 → 临时封面地址。返回 `{metadata_id: url}`。

    **只读表、只回盘上已经有图的 URL**。缺的那些把「算帧 + 抽帧」丢给后台线程，
    本次不回 —— 列表/详情请求绝不能为了封面去等 ffprobe/ffmpeg
    （网盘上单帧几十秒，一屏 18 张卡就把首页钉死了）。
    客户端下次重开列表就命中（本来也会重开）。
    """
    cfg = effective_cfg()
    if not cfg.get("enabled", True):
        return {}
    want = []
    for raw in (ids or []):
        try:
            mid = int(raw)
        except (TypeError, ValueError):
            continue
        if mid > 0:
            want.append(mid)
    want = want[:60]
    out: dict = {}
    if not want:
        return out

    marks = ",".join("?" * len(want))
    try:
        with A.user_db() as conn:
            rows = {int(r["metadata_id"]): r for r in conn.execute(
                f"SELECT metadata_id, file_id, ms, ready FROM temp_cover "
                f"WHERE metadata_id IN ({marks})", tuple(want)).fetchall()}
    except Exception as exc:  # noqa: BLE001
        A.log(f"WARN 临时封面读表失败: {exc}")
        return out

    todo: list = []
    for mid in want:
        row = rows.get(mid)
        if row is not None and int(row["ready"]):
            if os.path.isfile(_temp_cover_path(cfg, int(row["file_id"]), int(row["ms"]))):
                out[mid] = _temp_url(mid)
                continue
        todo.append(mid)

    # 一次最多排 8 部：后台是串行 ffmpeg，排太多只是把队列拉长
    for mid in todo[:8]:
        with _TEMP_LOCK:
            if mid in _TEMP_PREPARING:
                continue
            _TEMP_PREPARING.add(mid)
        threading.Thread(target=_temp_prepare_run, args=(mid, cfg),
                         daemon=True, name=f"temp-cover-prep-{mid}").start()
    return out


def temp_cover(handler, query, mid: str, *_):
    """GET /api/user/tempcover/{metadata_id}.jpg —— 无正式封面时顶上的截帧。"""
    cfg = effective_cfg()
    meta_id = _int(mid, 0, 0, 10 ** 9)
    if meta_id <= 0:
        return handler._error(400, "参数不对")
    try:
        with A.user_db() as conn:
            row = conn.execute(
                "SELECT file_id, ms, ready FROM temp_cover WHERE metadata_id = ?",
                (meta_id,)).fetchone()
    except Exception as exc:  # noqa: BLE001
        return handler._error(500, f"读临时封面失败: {exc}")
    if row is None or not int(row["ready"]):
        return handler._error(404, "临时封面还没抽出来")
    path = _temp_cover_path(cfg, int(row["file_id"]), int(row["ms"]))
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        _temp_set(meta_id, int(row["file_id"]), int(row["ms"]), 0)
        return handler._error(404, "临时封面不在了")
    handler.send_response(200)
    handler.send_header("Content-Type", "image/jpeg")
    handler.send_header("Content-Length", str(len(data)))
    # 文件内容对同一 (file, ms) 永远不变；真封面来了以后这个 URL 也不会再被用到
    handler.send_header("Cache-Control", "public, max-age=604800")
    handler.end_headers()
    handler.wfile.write(data)


ROUTES = [
    # 临时封面：无正式封面时的兜底（2.6.1.50）
    ("GET", r"/api/user/tempcover/(\d+)\.jpg", temp_cover),
    # 顺序无所谓：都用全锚点正则，pick/ 与 {id}/snap 不会互相抢
    ("POST", r"/api/user/highlights/(\d+)/snap", highlights_snap),
    ("PUT", r"/api/user/highlights/(\d+)/snap/(\d+)", highlight_pick_put),
    ("DELETE", r"/api/user/highlights/(\d+)/snap/(\d+)", highlights_unsnap),
    ("GET", r"/api/user/highlights/pick/(\d+)/(\d+)\.jpg", pick_frame),
    ("GET", r"/api/user/highlights/picks", highlights_picks),
    ("GET", r"/api/user/highlights/(\d+)/(\d+)\.jpg", frame),
    ("GET", r"/api/user/highlights/(\d+)", highlights),
    # 短视频流（2.6.2.1）：只回算过分的本地盘片段，不动亮点条的任何端点
    ("GET", r"/api/user/shorts", shorts),
    ("GET", r"/api/user/preview/(\d+)/sprite\.jpg", preview_sprite),
    # 注意顺序：settings / purge 是字面量，不会被 (\d+) 抢先匹配
    ("GET", r"/api/user/preview/settings", preview_prefs_get),
    ("POST", r"/api/user/preview/settings", preview_prefs_set),
    ("POST", r"/api/user/preview/purge", preview_purge),
    ("GET", r"/api/user/preview/(\d+)", preview_meta),
]


def install(api) -> dict:
    # ★ 每一轮新加的线程标志都必须列在这里 ★
    # 漏一个不会报「语法错」，而是运行到 `if not _XXX:` 时抛 UnboundLocalError，
    # 后果是**整个扩展加载失败、后台线程起不来**（2026-11-13 漏了 _SHORTS_WARM_STARTED，
    # 预热静默停了两个半小时，接口却还正常，极难发现）。
    global A, _WARM_STARTED, _SHORTS_WARM_STARTED
    A = api
    api.add_ddl(SNAP_DDL)
    api.add_ddl(TEMP_COVER_DDL)
    for method, pattern, fn in ROUTES:
        api.route(method, pattern)(fn)
    api.hook("item_extra", on_item_extra)
    # 「无封面时用截帧顶上」：由核心在 poster 为空时来要（server.py fill_temp_covers）
    api.hook("temp_covers", temp_covers)
    cfg = effective_cfg()
    # 闲时预生成：单部 ~100KB，库里 5000 部约 500MB，间隔 45s 慢跑，不进播放链路
    warm = bool(cfg.get("preview_enabled", True)) and bool(cfg.get("preview_warm", True))
    if warm and not _WARM_STARTED and _tool(cfg, "ffmpeg"):
        _WARM_STARTED = True
        threading.Thread(
            target=_preview_warm_loop,
            args=(int(cfg.get("preview_warm_interval", 45)),),
            daemon=True, name="preview-warm").start()
    # 短视频的闲时预热（2.6.1.58）：和预览预热分开一条线程，但共用同一份缓存预算。
    # 用户 22:26 要求「后台慢慢扫，不等用户来触发」，同时给了四条风险约束
    # （串行 / 间隔 / 只本地盘 / 可关），都落在 `_shorts_warm_loop` 里。
    shorts_warm = bool(cfg.get("shorts_warm", True))
    if shorts_warm and not _SHORTS_WARM_STARTED and _tool(cfg, "ffmpeg"):
        _SHORTS_WARM_STARTED = True
        threading.Thread(
            target=_shorts_warm_loop,
            args=(SHORTS_WARM_INTERVAL,),
            daemon=True, name="shorts-warm").start()
    return {
        "id": "highlights",
        "routes": len(ROUTES),
        "ffmpeg": os.path.basename(_tool(cfg, "ffmpeg")) or "缺失",
        "cache": _cache_root(cfg),
        "warm": warm,
        "shorts_warm": shorts_warm,
    }
