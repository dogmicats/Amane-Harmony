"""空间管理：各块缓存/衍生数据的占用、上限与清理（2026-11-14 新增）。

## 为什么要有这个模块

服务端旁挂目录一度涨到 7.1 G，其中 5.9 G 是 `play-cache`。拆开看才发现问题不在"缓存太大"，
而在**没人有全局视角**：

- `PlayDiskCache` 的预算只管 `play-cache/v4`（4.0 G），可 `play-cache/` 下还躺着
  `v2`（479 M）、`v3`（131 M）和一个 1.3 G 的残留哈希目录 —— **共 1.9 G 完全在预算之外**；
- `imgcache`（954 M）**只写不删**，连上限都没有；
- 用户在设置页看不到任何一块的真实占用，只能靠 `du` 上服务器查。

所以本模块只做三件事：**量准**、**能设上限**、**能清**。

## 口径

- `used` 一律**递归统计目录下所有文件**（含历史版本子目录），报给用户的就是磁盘上真实占用的近似值。
- `cleanable=False` 的两块（写真图 / 数据库）**永不清理** —— 那是用户数据，不是缓存。
  页面上对它们只展示占用，不提供清理按钮，并说明原因。
- 上限存在 `<DATA_DIR>/storage.json`，**按块独立**；0 表示"不限"。
"""
from __future__ import annotations

import json
import os
import shutil
import time

from core.config import DATA_DIR, IMAGE_CACHE, PHOTO_DIR, USER_DB
from core.log import log

STORAGE_FILE = os.path.join(DATA_DIR, "storage.json")
PLAY_CACHE_ROOT = os.path.join(DATA_DIR, "play-cache")


def _highlights_root() -> str:
    """highlights 扩展（刷一刷打分 + 进度条预览）的缓存根目录。

    与 `extensions/public/highlights/server_ext.py:_cache_root()` **同一套优先级**：
    用户配的 `cache_dir` 我们读不到（在扩展自己的配置里），所以这里退一步：
    有 `/cache` 挂载就用它，否则用 `DATA_DIR/frames`。
    2026-11-14 实测：这块实际在 `/cache`，**349 MB / 1087 部片的 scores.json**，
    而 `/data/frames` 只剩 5.5 MB —— 也就是说之前页面上报的「截帧缓存 5.5 MB」
    完全没反映真实占用，用户看到的数字是假的。
    """
    if os.path.isdir("/cache"):
        return "/cache"
    return os.path.join(DATA_DIR, "frames")


FRAMES_DIR = _highlights_root()
BACKUP_DIR = os.path.join(DATA_DIR, "backup")

# 每块的元信息。顺序即页面上的显示顺序（按"最可能占地方"排在前面）。
KINDS: list[dict] = [
    {"key": "play", "label": "播放缓存", "path": PLAY_CACHE_ROOT, "default_mb": 4096,
     "cleanable": True, "age_days": 7,
     "desc": "看片时缓存的 4 MiB 数据块。这里的上限只针对网盘片；本地片用固定的 128 MB。"},
    {"key": "img", "label": "图片缓存", "path": IMAGE_CACHE, "default_mb": 512,
     "cleanable": True,
     "desc": "海报、剧照、演员头像的本地副本。留着翻列表不闪白；"
             "删掉会重新从网络取，慢一点但内容一致。"},
    {"key": "frames", "label": "刷一刷打分 / 预览", "path": FRAMES_DIR, "default_mb": 2048,
     "cleanable": True, "age_days": 90,
     "desc": "刷一刷要给影片打分，会把每部片截成 8×8 的雪碧图并算分（scores.json）；"
             "进度条悬停预览也用它。留着下次刷不重算；清掉后这部分片要重新扫，"
             "每部约 30–40 秒，所以只能按「多久没用过」分批清，不支持一键清空。"},
    {"key": "backup", "label": "升级备份", "path": BACKUP_DIR, "default_mb": 512,
     "cleanable": True,
     "desc": "每次覆盖升级前自动打的数据库快照，用来回滚。"
             "只保留最近几份；空间紧张时可以清，代价是放弃更早的回滚点。"},
    {"key": "photos", "label": "写真图", "path": PHOTO_DIR, "default_mb": 0,
     "cleanable": False,
     "desc": "你自己上传的图片，属于数据不是缓存，任何时候都不会被自动删除。"},
]

_DB_KIND = {"key": "db", "label": "数据库", "path": USER_DB, "default_mb": 0,
            "cleanable": False,
            "desc": "收藏、评分、观看进度都在这里。永不自动清理，请通过设置里的备份功能保存。"}


def _dir_size(path: str) -> tuple[int, int]:
    """(字节数, 文件数)。单个文件被删/权限不足时跳过，不中断统计。"""
    total = 0
    files = 0
    if os.path.isfile(path):
        try:
            return os.stat(path).st_size, 1
        except OSError:
            return 0, 0
    for base, _dirs, names in os.walk(path):
        for name in names:
            try:
                total += os.stat(os.path.join(base, name)).st_size
                files += 1
            except OSError:
                # 2026-11-14 教训：FUSE 挂载断开会抛 ENOTCONN，不能当"不存在"处理，
                # 但统计时只能跳过 —— 具体原因交给调用方看日志
                continue
    return total, files


def load_settings() -> dict:
    """读上限设置。文件不存在/损坏一律回退到空 dict（= 全用默认值）。"""
    try:
        with open(STORAGE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(cfg: dict) -> None:
    tmp = STORAGE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, STORAGE_FILE)


def budget_of(key: str) -> int:
    """该块的上限（MB）。0 = 不限。"""
    cfg = load_settings()
    for k in KINDS + [_DB_KIND]:
        if k["key"] == key:
            v = cfg.get(key)
            return int(v) if isinstance(v, (int, float)) else int(k["default_mb"])
    return 0


def set_budget(key: str, mb: int) -> dict:
    """设某块上限。返回落盘后的设置。

    播放缓存要**同时**改运行中的 `PLAY_DISK.budget`，否则要重启才生效。

    2026-11-15 起播放缓存拆成两份（agent2 的 `50cd382`）：
      * `PLAY_DISK`       → `play-cache/v4`，**网盘/上游源**，预算就是这里的 play（可调）
      * `PLAY_DISK_LOCAL` → `play-cache/v4/_local`，**本地盘源**，固定 `AMANE_PLAY_LOCAL_MB=128`，
        不开放给用户调
    所以这里的 `key == "play"` **只改网盘那份**，本地那份别跟着改 —— 它本来就是为了
    「本地盘回源本来就是秒级、缓存收益小」而设的小额度。
    """
    mb = max(0, int(mb))
    cfg = load_settings()
    cfg[key] = mb
    save_settings(cfg)
    if key == "play":
        try:
            from core import logic as _L
            _L.PLAY_DISK.budget = mb * 1024 * 1024
        except Exception as exc:          # noqa: BLE001
            log(f"WARN 播放缓存预算热更新失败（重启后生效）: {exc}")
    return cfg


def _status(used: int, budget_mb: int) -> str:
    """给客户端用的状态字：ok / near（≥85%）/ over。"""
    if budget_mb <= 0:
        return "ok"
    limit = budget_mb * 1048576
    if used > limit:
        return "over"
    if used >= limit * 0.85:
        return "near"
    return "ok"


def report() -> dict:
    """全部块的占用 + 上限 + 状态 + 全局合计。"""
    out = []
    total_used = 0
    total_files = 0
    for k in KINDS + [_DB_KIND]:
        used, files = _dir_size(k["path"])
        total_used += used
        total_files += files
        b = budget_of(k["key"])
        out.append({
            "key": k["key"],
            "label": k["label"],
            "used_mb": round(used / 1048576, 1),
            "files": files,
            "budget_mb": b,
            "status": _status(used, b),
            "cleanable": bool(k["cleanable"]),
            "desc": k["desc"],
        })
    # 老版本的播放缓存目录（v2/v3 及历史残留）：单独报出来，
    # 这是 2026-11-14 实测「7.1 G 里 1.9 G 在预算之外」的直接来源。
    stale = _stale_play_dirs()
    return {
        "ok": True,
        "kinds": out,
        "total_mb": round(total_used / 1048576, 1),
        "total_files": total_files,
        "stale_play_mb": round(stale[0] / 1048576, 1),
        "stale_play_dirs": stale[1],
        "free_mb": _free_mb(),
    }


def _free_mb() -> float:
    try:
        st = os.statvfs(DATA_DIR)          # type: ignore[attr-defined]
        return round(st.f_bavail * st.f_frsize / 1048576, 1)
    except Exception:                      # noqa: BLE001
        # Linux 才有 statvfs；Windows 开发机走这里
        try:
            return round(shutil.disk_usage(DATA_DIR).free / 1048576, 1)
        except OSError:
            return 0.0


def _stale_play_dirs() -> tuple[int, list[str]]:
    """play-cache 下除当前版本（v4）之外的目录：老版本 + 历史残留。

    约定（2026-11-15 起，别打破）：**当前版本的内容一律在 `v4/` 里面**。
    本地盘那份缓存在 `v4/_local/`，属于 v4 内部，所以这里只会看到 v2/v3 这类真正的旧版本目录。
    以后不要为了「整理目录」把 `_local` 挪到 `play-cache/` 顶层 ——
    那样它会被当成旧残留列进「可以放心清掉」，用户一点就把本地片缓存清了。
    """
    total = 0
    names: list[str] = []
    try:
        entries = os.listdir(PLAY_CACHE_ROOT)
    except OSError:
        return 0, []
    for name in entries:
        if name == "v4":
            continue
        p = os.path.join(PLAY_CACHE_ROOT, name)
        if not os.path.isdir(p):
            continue
        size, _ = _dir_size(p)
        if size > 0:
            total += size
            names.append(name)
    return total, sorted(names)


def clean(key: str, age_days: int | None = None) -> dict:
    """清空或按龄清理某块。

    `age_days`：
      - `None`  → 用该块的默认策略（`KINDS` 里的 `age_days`，没写就全清）
      - `0`     → 全清
      - `> 0`    → 只删「这么久没碰过」的整目录，其余保留

    播放缓存支持调用方指定（用户选 7 / 30 / 0），刷一刷打分固定按 90 天。
    为什么播放缓存也要能给 0：用户可能就是想立刻腾出空间，让他自己决定，
    但页面上要说明代价（重看和拖动的流畅度会退回到第一次看片）。
    """
    target = None
    for k in KINDS:
        if k["key"] == key:
            target = k
            break
    if target is None:
        return {"ok": False, "error": "没有这一块", "key": key}
    if not target["cleanable"]:
        return {"ok": False, "error": "%s 是数据不是缓存，不能自动清理" % target["label"],
                "key": key}
    days = target.get("age_days")
    if age_days is not None:
        # 只有播放缓存允许调用方改档位；其它块（刷一刷打分）守住固定龄，
        # 否则用户一键清空会在不知情的情况下把 1000+ 部片的分全删掉、重建十几小时。
        if key != "play":
            return {"ok": False, "key": key,
                    "error": "%s 只支持按 %s 天分批清理，不支持全清" % (target["label"], days)}
        days = int(age_days)

    if key == "play":
        # 播放缓存的实际结构是 play-cache/v4/<hash>/<块>.bin，
        # 所以按 hash 目录整体删 —— 只删 `v4` 这一层会把整块缓存一次抹掉。
        root = os.path.join(PLAY_CACHE_ROOT, "v4")
        if not os.path.isdir(root):
            root = PLAY_CACHE_ROOT
        if days and int(days) > 0:
            res = _clean_older(root, int(days))
            res.update({"ok": True, "key": key, "age_days": int(days), "mode": "age"})
        else:
            freed, files = _clear_dir(root)
            res = {"ok": True, "key": key, "freed_mb": round(freed / 1048576, 1),
                   "files": files, "mode": "all"}
        log(f"storage clean play({res.get('mode')}, days={days}): "
            f"释放 {res.get('freed_mb')} MB")
        return res

    if days and int(days) > 0:
        res = _clean_older(target["path"], int(days))
        res.update({"ok": True, "key": key, "age_days": int(days), "mode": "age"})
        log(f"storage clean {key}: 按 {days} 天龄删除 {res['removed']} 个目录，"
            f"释放 {res['freed_mb']} MB")
        return res
    freed, files = _clear_dir(target["path"])
    log(f"storage clean {key}: 释放 {round(freed / 1048576, 1)} MB / {files} 个文件")
    return {"ok": True, "key": key, "freed_mb": round(freed / 1048576, 1),
            "files": files, "mode": "all"}


def _clean_older(root: str, age_days: int) -> dict:
    """按「一级子目录里最新一次写入」判断年龄，整目录删掉。返回删除统计。

    刷一刷的打分/预览是 `<root>/<file_id>/...`，所以按 file_id 目录整体删 ——
    删一半文件（比如只删雪碧图留 scores.json）会让下一次扫描的判定混乱。
    """
    cutoff = time.time() - age_days * 86400
    removed = 0
    freed = 0
    kept = 0
    try:
        entries = list(os.listdir(root))
    except OSError as exc:
        return {"ok": False, "error": str(exc), "removed": 0, "freed_mb": 0}
    for name in entries:
        p = os.path.join(root, name)
        if not os.path.isdir(p):
            # 根下散落的单文件（老版本可能直接放这里）按自身 mtime 判断
            try:
                st = os.stat(p)
                if st.st_mtime < cutoff:
                    freed += st.st_size
                    os.remove(p)
                    removed += 1
                else:
                    kept += 1
            except OSError:
                continue
            continue
        size, _files = _dir_size(p)
        try:
            newest = max(
                (os.stat(os.path.join(base, n)).st_mtime
                 for base, _d, names in os.walk(p) for n in names),
                default=os.stat(p).st_mtime
            )
        except OSError:
            continue
        if newest >= cutoff:
            kept += 1
            continue
        try:
            shutil.rmtree(p)
            freed += size
            removed += 1
        except OSError:
            continue
    return {"removed": removed, "freed_mb": round(freed / 1048576, 1),
            "kept": kept, "age_days": age_days}


_IMG_ENFORCE_AT = {"t": 0.0}
IMG_ENFORCE_INTERVAL = 300      # 秒：最多 5 分钟扫一次目录，避免每张图都走一遍


def enforce_img_cap(force: bool = False) -> dict:
    """图片缓存**真正**的超限淘汰：按 mtime 从旧到新删到上限的 85%。

    为什么需要它：2026-11-14 实测服务端 imgcache 已经 **954 MB**，而这块在
    这次改动之前**根本没有上限、也没有任何清理**（`serve_image()` 只写不删）。
    页面上写「上限 512 MB」却不真删，等于骗人 —— 所以落成真淘汰。

    节流：默认 5 分钟最多跑一次（每取一张图都扫 8000 个文件是不可接受的）。
    调用点：`core/logic.serve_image()` 写盘之后，用 `force=False`。
    """
    now = time.time()
    if not force and now - _IMG_ENFORCE_AT["t"] < IMG_ENFORCE_INTERVAL:
        return {"ok": True, "skipped": True}
    _IMG_ENFORCE_AT["t"] = now
    budget = budget_of("img")
    if budget <= 0:
        return {"ok": True, "skipped": True, "reason": "未设上限"}
    used, _files = _dir_size(IMAGE_CACHE)
    limit = budget * 1048576
    if used <= limit:
        return {"ok": True, "used_mb": round(used / 1048576, 1), "removed": 0}
    target = int(limit * 0.85)
    entries: list[tuple[float, str, int]] = []
    for base, _dirs, names in os.walk(IMAGE_CACHE):
        for name in names:
            p = os.path.join(base, name)
            try:
                st = os.stat(p)
                entries.append((st.st_mtime, p, st.st_size))
            except OSError:
                continue
    entries.sort()                       # 最久没碰的排前面
    removed = 0
    freed = 0
    for _mtime, p, size in entries:
        if used <= target:
            break
        try:
            os.remove(p)
            used -= size
            freed += size
            removed += 1
        except OSError:
            continue
    log(f"imgcache 超限淘汰：删 {removed} 个文件，释放 {round(freed / 1048576, 1)} MB"
        f"（{round(limit / 1048576)} MB 上限）")
    return {"ok": True, "removed": removed, "freed_mb": round(freed / 1048576, 1),
            "used_mb": round(used / 1048576, 1)}


def clean_stale_play() -> dict:
    """清掉 play-cache 下的老版本目录（v2/v3/历史残留）。当前版本 v4 不动。"""
    total = 0
    removed: list[str] = []
    try:
        entries = list(os.listdir(PLAY_CACHE_ROOT))
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
    for name in entries:
        if name == "v4":
            continue
        p = os.path.join(PLAY_CACHE_ROOT, name)
        if not os.path.isdir(p):
            continue
        size, _ = _dir_size(p)
        try:
            shutil.rmtree(p)
            total += size
            removed.append(name)
        except OSError as exc:
            log(f"WARN 删除 play-cache/{name} 失败: {exc}")
    log(f"storage clean stale-play: 释放 {round(total / 1048576, 1)} MB（{len(removed)} 个目录）")
    return {"ok": True, "freed_mb": round(total / 1048576, 1), "removed": removed}


def _clear_dir(path: str) -> tuple[int, int]:
    """清空目录内容（保留目录本身）。返回 (释放字节, 文件数)。"""
    total = 0
    files = 0
    if not os.path.isdir(path):
        return 0, 0
    for base, dirs, names in os.walk(path, topdown=False):
        for name in names:
            p = os.path.join(base, name)
            try:
                total += os.stat(p).st_size
                os.remove(p)
                files += 1
            except OSError:
                continue
        for d in dirs:
            try:
                os.rmdir(os.path.join(base, d))
            except OSError:
                pass
    return total, files
