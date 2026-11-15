"""容器内自升级（半自动）：下载 → 校验 → 解包 → 原子切换 → 退出重启。

为什么是「半自动」而不是「全自动」：用户点一下，服务端自己干活；但**不重建容器**
（容器没有 docker 权限，也不该拿 docker.sock）。升级的对象是挂进容器的 `/app` 目录：
换掉里面的代码、进程退出，由 `restart: unless-stopped` 把容器拉起来 ——
和 Emby 容器版点「更新」后自升二进制是一个思路，区别是它换二进制、我们换整个 app 目录。

三条硬约束（改之前先想清楚）：

1. `/app` 必须是**可写卷**。只读挂载（我们自己的 dev 容器就是 `:ro`）时直接不允许升级，
   `status.supported=false` 并把原因写回去，客户端回退手动步骤 —— 不要「看起来能点、点了失败」。
2. 只要 sha256 拿不到就不升。宁可不动，也不装来路不明的代码。
3. 切换前必须 `py_compile` 整套通过；切换失败/校验失败一律回滚到 `app.prev`。
   半路被 kill 也要能恢复：切换前写 `.upgrading` 标记，启动时看到标记就自检/回滚。
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request

from core.config import DATA_DIR, ROOT_DIR, VERSION
from core.log import log

APP_DIR = os.environ.get("AMANE_APP_DIR", os.path.join(DATA_DIR, "app"))
APP_NEW = os.environ.get("AMANE_APP_NEW", os.path.join(DATA_DIR, "app.new"))
APP_PREV = os.environ.get("AMANE_APP_PREV", os.path.join(DATA_DIR, "app.prev"))
STATE_PATH = os.path.join(DATA_DIR, "auto_update.state.json")
MARKER = os.path.join(APP_DIR, ".upgrading")
PENDING = os.path.join(APP_DIR, ".pending")
TRIES = os.path.join(DATA_DIR, "auto_update.boot_tries")

# 公版仓库与源码包里的服务端目录。容器内升级只吃「源码包」这一种来源：
# 镜像重建做不到（没有 docker），二进制差异包维护成本又太高。
REPO = os.environ.get("AMANE_UPGRADE_REPO", "dogmicats/Amane-Harmony")
SUBDIR = os.environ.get("AMANE_UPGRADE_SUBDIR", "server")
# 服务端入口文件名。**别写死 main.py** —— 这个项目的入口是 `server.py`
# （2026-11-15 演练时踩到：写死 main.py 导致「包里没有 main.py」的假失败）。
ENTRY = os.environ.get("AMANE_UPGRADE_ENTRY", "server.py")
TAG_URL = "https://github.com/{repo}/archive/refs/tags/v{ver}.tar.gz"
MAX_BYTES = int(os.environ.get("AMANE_UPGRADE_MAX_MB", "80")) * 1024 * 1024

_lock = threading.Lock()
_busy = {"on": False}


def _json_read(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        return raw if isinstance(raw, dict) else {}
    except (OSError, ValueError):
        return {}


def _json_write(path: str, data: dict) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError as exc:
        log(f"WARN 写 {path} 失败: {exc}")


def state() -> dict:
    return _json_read(STATE_PATH)


def write_state(st: str, message: str = "", frm: str = "", to: str = "") -> None:
    _json_write(STATE_PATH, {
        "installed": True,
        "state": st,
        "message": message,
        "from": frm or VERSION,
        "to": to,
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "checked_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": "inplace",
    })


def _writable(path: str) -> bool:
    try:
        probe = os.path.join(path, ".write-probe")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("1")
        os.remove(probe)
        return True
    except OSError:
        return False


def capability() -> dict:
    """这台机器能不能「在容器内自己升级」。

    现在**不再要求挂卷**：升级写进 `<DATA_DIR>/app`，而 `/data` 是每个部署本来就有的卷。
    所以对绝大多数部署 `supported=true`、`persistent=true`；只有 `/data` 不可写才不支持。
    """
    data = os.path.dirname(APP_DIR.rstrip("/")) or DATA_DIR
    rw = _writable(data)
    reason = "" if rw else f"{data} 不可写，无法存放升级后的代码"
    return {
        "supported": rw,
        "persistent": rw,
        "writable": rw,
        "mounted": rw,
        "app_dir": APP_DIR,
        "repo": REPO,
        "reason": reason,
    }


def candidate_is_newer(cand: str) -> bool:
    """`<DATA_DIR>/app` 里的版本是不是比镜像里的新（防止旧代码盖回去）。"""
    try:
        text = ""
        path = os.path.join(cand, "core", "config.py")
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("VERSION"):
                    text = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break
        other = _ver_tuple(text)
        mine = _ver_tuple(VERSION)
        if not other:
            return False
        return other > mine
    except OSError:
        return False


def boot_guard(cand: str) -> str:
    """启动自检：上次换了代码但没起起来 → 记一次；连续两次就回滚到 app.prev。

    返回值：`ok`（可以继续用 cand）/ `rollback`（已回滚，继续用镜像代码）。
    """
    pend = os.path.join(cand, ".pending")
    if not os.path.isfile(pend):
        return "ok"
    tries = 0
    try:
        with open(TRIES, encoding="utf-8") as fh:
            tries = int((fh.read() or "0").strip() or "0")
    except (OSError, ValueError):
        tries = 0
    tries += 1
    if tries < 2:
        try:
            with open(TRIES, "w", encoding="utf-8") as fh:
                fh.write(str(tries))
        except OSError:
            pass
        log(f"boot guard: 上次换代码后没起起来（第 {tries} 次），再试一次")
        return "ok"
    # 连续两次没起来：把这份代码挪开，回到上一份
    log("boot guard: 连续两次没起起来，回滚")
    bad = cand.rstrip("/") + ".bad-" + time.strftime("%Y%m%d-%H%M%S")
    try:
        os.rename(cand, bad)
        if os.path.isdir(APP_PREV):
            os.rename(APP_PREV, cand)
        write_state("failed", f"新版本起不来，已回滚（坏代码留在 {bad}）", VERSION, "")
    except OSError as exc:
        log(f"boot guard 回滚失败: {exc}")
    try:
        with open(TRIES, "w", encoding="utf-8") as fh:
            fh.write("0")
    except OSError:
        pass
    return "rollback"


def boot_ok() -> None:
    """服务真正起来了：清掉 pending 与失败计数，下次重启不再当成崩溃。"""
    for path in (PENDING, TRIES):
        try:
            if os.path.isfile(path):
                os.remove(path)
        except OSError:
            pass


def _ver_tuple(v: str) -> tuple:
    out = []
    for part in v.split("."):
        if not part.isdigit():
            return ()
        out.append(int(part))
    return tuple(out)


def _valid_target(want: str) -> str:
    want = (want or "").strip().lstrip("v")
    tv = _ver_tuple(want)
    if not tv or len(tv) != 3:
        return "版本号要写成 X.Y.Z"
    cur = _ver_tuple(VERSION)
    if cur and tv[0] != cur[0]:
        return f"只支持同一主版本内升级（当前 {VERSION}）"
    if cur and tv <= cur:
        return f"目标版本 {want} 不比当前 {VERSION} 新"
    return ""


def _download(url: str, dst: str, sha256: str) -> None:
    h = hashlib.sha256()
    total = 0
    req = urllib.request.Request(url, headers={"User-Agent": "amane-upgrader"})
    with urllib.request.urlopen(req, timeout=60) as resp, open(dst, "wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BYTES:
                raise RuntimeError(f"包超过 {MAX_BYTES // 1048576}MB，停下")
            h.update(chunk)
            fh.write(chunk)
    got = h.hexdigest()
    if sha256 and got.lower() != sha256.strip().lower():
        raise RuntimeError(f"sha256 不匹配（期望 {sha256[:12]}…，实际 {got[:12]}…）")


def _extract(pkg: str, into: str) -> str:
    """解包并把源码包里的 `server/` 内容当成新的 app 根。返回该目录。"""
    shutil.rmtree(into, ignore_errors=True)
    os.makedirs(into, exist_ok=True)
    with tarfile.open(pkg, "r:*") as tf:
        members = tf.getmembers()
        for m in members:
            name = m.name.replace("\\", "/")
            # 防目录穿越：只接受相对路径，且不允许 ..
            if name.startswith("/") or ".." in name.split("/"):
                raise RuntimeError(f"包里有可疑路径: {m.name}")
        tf.extractall(into, members=members)
    # 源码包顶层是 `<repo>-<ver>/`，服务端在 `<repo>-<ver>/server/`
    roots = [d for d in os.listdir(into) if os.path.isdir(os.path.join(into, d))]
    root = os.path.join(into, roots[0]) if len(roots) == 1 else into
    app_root = os.path.join(root, SUBDIR) if SUBDIR else root
    if not os.path.isfile(os.path.join(app_root, ENTRY)):
        raise RuntimeError(f"包里没有 {SUBDIR}/{ENTRY}，不像服务端源码包")
    return app_root


def _py_compile(root: str) -> None:
    """整套语法检查。别用 compileall 的静默模式：要拿到第一个错误就停。"""
    bad = []
    for base, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".py"):
                continue
            path = os.path.join(base, name)
            with open(path, "rb") as fh:
                src = fh.read()
            try:
                compile(src, path, "exec")
            except SyntaxError as exc:
                bad.append(f"{os.path.relpath(path, root)}:{exc.lineno} {exc.msg}")
                if len(bad) >= 3:
                    break
        if len(bad) >= 3:
            break
    if bad:
        raise RuntimeError("新版本语法检查没过：" + "; ".join(bad))


def _move_contents(src: str, dst: str, skip: tuple = ()) -> None:
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        if name in skip:
            continue
        shutil.move(os.path.join(src, name), os.path.join(dst, name))


def _snapshot_image_code() -> None:
    """第一次升级时 `app.prev` 还是空的：把**镜像里的代码**（当前正在跑的这份）存进去，
    这样「新版本起不来」也有东西可回滚。
    """
    if os.path.isdir(APP_PREV) and os.listdir(APP_PREV):
        return
    try:
        shutil.rmtree(APP_PREV, ignore_errors=True)
        shutil.copytree(ROOT_DIR, APP_PREV, ignore=shutil.ignore_patterns(
            "__pycache__", "*.pyc", "app", "app.prev", "app.new"))
        log(f"upgrade: 已把镜像代码快照到 {APP_PREV}")
    except OSError as exc:
        log(f"WARN 快照镜像代码失败: {exc}")


def _has_code(d: str) -> bool:
    """目录里有没有真代码（标记文件不算，否则空目录会被当成「有代码」）。"""
    if not os.path.isdir(d):
        return False
    return any(n not in (".upgrading", ".pending") for n in os.listdir(d))


def _swap(new_root: str) -> None:
    """把新代码换进 `<DATA_DIR>/app`。先标记再动，半路崩了启动时能 recovery。"""
    os.makedirs(APP_DIR, exist_ok=True)
    with open(MARKER, "w", encoding="utf-8") as fh:
        fh.write(str(int(time.time())))
    if _has_code(APP_DIR):
        # 已经有一份在跑（多次升级）：它才是「上一版」
        shutil.rmtree(APP_PREV, ignore_errors=True)
        _move_contents(APP_DIR, APP_PREV, skip=(".upgrading", ".pending"))
    else:
        # 第一次升级：`app.prev` 放**镜像里的代码**，新版本起不来也能回去
        _snapshot_image_code()
    _move_contents(new_root, APP_DIR, skip=(".upgrading", ".pending"))
    if not os.path.isfile(os.path.join(APP_DIR, ENTRY)):
        raise RuntimeError(f"切换后 {APP_DIR} 里没有 {ENTRY}")
    # .pending 留着：下次启动如果它还在，说明这份代码没起起来（见 boot_guard）
    with open(PENDING, "w", encoding="utf-8") as fh:
        fh.write(str(int(time.time())))
    try:
        os.remove(MARKER)
    except OSError:
        pass


def _rollback() -> str:
    if not os.path.isdir(APP_PREV):
        return "没有 app.prev 可回滚"
    _move_contents(APP_DIR, os.path.join(APP_PREV, "_failed"), skip=(".upgrading",))
    _move_contents(APP_PREV, APP_DIR)
    try:
        os.remove(MARKER)
    except OSError:
        pass
    return "已回滚到升级前的代码"


def recover_if_needed() -> str:
    """启动自检：上次切换没走完（`.upgrading` 还在 / 代码不完整）就回滚。"""
    if not os.path.isfile(MARKER):
        return ""
    has_main = os.path.isfile(os.path.join(APP_DIR, ENTRY))
    if has_main:
        try:
            os.remove(MARKER)
        except OSError:
            pass
        return "上次升级已切换完成，清掉标记"
    msg = _rollback()
    log(f"upgrade recovery: {msg}")
    write_state("failed", "上次升级没走完，" + msg, VERSION, "")
    return msg


def _run(ver: str, url: str, sha256: str, delay_restart: bool) -> None:
    frm = VERSION
    tmpdir = tempfile.mkdtemp(prefix="amane-up-")
    pkg = os.path.join(tmpdir, "pkg.tar.gz")
    try:
        write_state("downloading", f"正在下载 {ver}", frm, ver)
        _download(url, pkg, sha256)
        write_state("verifying", "校验并解包", frm, ver)
        new_root = _extract(pkg, APP_NEW)
        _py_compile(new_root)
        write_state("switching", "正在替换代码", frm, ver)
        _swap(new_root)
        write_state("restarting", "代码已替换，正在重启服务", frm, ver)
        log(f"upgrade inplace: {frm} -> {ver} 完成，准备退出让容器重启")
    except Exception as exc:  # noqa: BLE001
        log(f"upgrade inplace failed: {exc}")
        back = ""
        if os.path.isfile(MARKER):
            back = _rollback()
        write_state("failed", f"{exc}{('；' + back) if back else ''}", frm, ver)
        with _lock:
            _busy["on"] = False
        return
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        shutil.rmtree(APP_NEW, ignore_errors=True)

    if delay_restart:
        # 先让 HTTP 响应回得去，再退出；容器靠 restart 策略被拉起来
        time.sleep(1.5)
        os._exit(0)


def _preflight(url: str) -> str:
    """受理前先确认包在不在。2026-11-15 实测：版本号写错（1.4.99 不存在）时
    接口照样「已受理」，几秒后才在下载阶段 404 —— 用户看到的是「点了没反应」。
    这里用 HEAD 探一下：明确 4xx 就直接拒绝；网络问题不拦（交给下载阶段报更准确的原因）。
    """
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "amane-upgrader"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            if getattr(resp, "status", 200) >= 400:
                return f"目标版本的包不存在（HTTP {resp.status}）"
    except urllib.error.HTTPError as exc:
        return f"目标版本的包不存在（HTTP {exc.code}）"
    except Exception:  # noqa: BLE001
        pass
    return ""


def start(ver: str, sha256: str = "", url: str = "") -> dict:
    """入口：校验 → 起后台线程。立刻返回，升级在后台跑。

    sha256 的处理（2026-11-15，和 Emby 的做法对齐）：
      - 清单给了校验值 → 必须匹配，否则不升；
      - 清单没给 → 走**来源白名单**（只认 GitHub 官方域名），靠 TLS 保证完整；
        白名单之外一律拒绝。宁可不动，也不去拉来路不明的代码。
    """
    want = (ver or "").strip().lstrip("v")
    err = _valid_target(want)
    if err:
        return {"ok": False, "error": err}
    cap = capability()
    if not cap["supported"]:
        return {"ok": False, "error": cap["reason"] or "这台机器不支持容器内升级"}
    if not sha256:
        probe = (url or TAG_URL.format(repo=REPO, ver=want)).lower()
        if not probe.startswith(("https://github.com/", "https://objects.githubusercontent.com/")):
            return {"ok": False, "error": "没有校验值，且下载地址不在白名单（只认 GitHub）"}
    with _lock:
        if _busy["on"]:
            return {"ok": True, "accepted": False, "message": "正在升级，稍等"}
        _busy["on"] = True
    link = url or TAG_URL.format(repo=REPO, ver=want)
    bad = _preflight(link)
    if bad:
        with _lock:
            _busy["on"] = False
        return {"ok": False, "error": bad}
    t = threading.Thread(target=_run, args=(want, link, sha256, True),
                         name="amane-upgrade", daemon=True)
    t.start()
    return {"ok": True, "accepted": True, "version": want, "from": VERSION,
            "persistent": cap["persistent"]}
