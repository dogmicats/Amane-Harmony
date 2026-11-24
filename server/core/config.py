"""路径 / 环境 / 常量（从 server.py 拆出的第一层）。

拆这个文件的理由：`server.py` 一度 9900 行，路径与环境变量散在头部与各处，
改一个挂载点要在几千行里翻。这里只放「读环境、定路径、算常量」，
**不依赖任何业务函数**，所以谁都可以 import，不会循环引用。

★ 搬迁陷阱（2026-11-14 拆的时候踩到的）
`_upstream_conf()` 原来用 `dirname(dirname(__file__))` 找仓库根的 `config/upstream.json`。
那是以「本文件就在仓库根」为前提算的。搬到 `core/config.py` 之后多了 `core/` 一层，
**必须再加一层 dirname**，否则它会去找 `/app/config/…`（容器里根本没有这个目录），
表现为 `UPSTREAM_CONF` 永远为空 —— 而它为空时只是退回默认探测，**不会报错**，
所以这种错误能安静地活很久。
"""
from __future__ import annotations

import json
import os
import re
import sys
from urllib.request import urlopen

# 「看完」的唯一口径：客户端 PlayerPage.saveProgress 与服务端兜底都用它。
# 两处各写一个数（曾经 0.95 / 0.92）会出现「客户端显示看完、服务端没标完」的错位。
FINISH_RATIO = 0.95

# 服务端版本号。★ 必须留在这个文件里 ★
# 2.6.1.92 把业务逻辑整体搬进 core/logic.py 时，`VERSION` 作为顶层赋值被一起搬走了，
# 结果部署脚本的「落点核对」（它 sed 读 server.py 找 VERSION）读不到 → 直接中止部署。
# 那条检查是 2026-11-11 加的，专门防「传错目录导致改了没生效」，这次真的挡住了一次。
VERSION = "2.9.0"

# 本文件在 <root>/core/config.py，仓库根是上两层
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _upstream_conf() -> dict:
    """上游配置文件（`tools/upstream.py discover --write` 生成）。

    只存数据目录与地址，**不存 token** —— token 永远从上游自己的 `<data>/token` 读，
    免得仓库里/启动脚本里多一份凭据副本。
    """
    path = os.environ.get("AMANE_UPSTREAM_CONF") or os.path.join(
        ROOT_DIR, "config", "upstream.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


UPSTREAM_CONF = _upstream_conf()


def _default_data_dirs() -> list:
    """上游数据目录候选（顺序即优先级）。

    `/amane-data` 是本仓库 docker 部署的挂载点；桌面版按上游文档的约定：
    Windows `%LOCALAPPDATA%\\Amane`、macOS `~/Library/Application Support/Amane`。
    Linux 桌面版上游文档没给，按源码运行的 `./data` 和 XDG 兜底。
    """
    out = ["/amane-data"]
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        out.append(os.path.join(base, "Amane"))
    elif sys.platform == "darwin":
        out.append(os.path.expanduser("~/Library/Application Support/Amane"))
    else:
        out.append(os.path.expanduser("~/.local/share/amane"))
        out.append(os.path.join(ROOT_DIR, "data"))
    return out


def _resolve_data_dir() -> str:
    """挑一个真的存在 amane.db 的目录；都不存在就退回第一个候选（让报错清晰）。"""
    explicit = os.environ.get("AMANE_DATA") or UPSTREAM_CONF.get("data_dir")
    for cand in [explicit] + _default_data_dirs():
        if cand and os.path.isfile(os.path.join(cand, "amane.db")):
            return cand
    return explicit or _default_data_dirs()[0]


def _reachable(url: str) -> bool:
    try:
        with urlopen(url, timeout=0.6) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001 - 探测而已，任何失败都算不通
        return False


def _resolve_base() -> str:
    """上游地址：环境变量 > 配置文件 > 实测。

    桌面版只监听 `127.0.0.1:18000`，Docker 是 `8000`。写死 8000 会让 Windows 上的旁挂
    直接 502，而报错还在「图片加载失败」这种远端表象上 —— 所以这里实测一次再定。
    """
    for cand in (os.environ.get("AMANE_BASE"), UPSTREAM_CONF.get("base")):
        if cand:
            return cand.rstrip("/")
    for port in ("18000", "8000"):
        url = f"http://127.0.0.1:{port}"
        if _reachable(url + "/api/health"):
            return url
    return "http://127.0.0.1:8000"


AMANE_BASE = _resolve_base()
AMANE_DATA = _resolve_data_dir()
DATA_DIR = os.environ.get("DATA_DIR", "/data")
PHOTO_DIR = os.environ.get("PHOTO_DIR") or os.path.join(DATA_DIR, "photos")

# 可选依赖（Pillow）：只有「用剧照生成 GIF 轮播封面」用得到。
# 镜像 python:slim 没带 Pillow，装到持久卷 /data/pylibs，重启容器不丢；
# 装不上也不影响其它功能 —— 那个端点会返回「服务端缺少 Pillow」。
_PYLIB_DIR = os.path.join(DATA_DIR, "pylibs")
if os.path.isdir(_PYLIB_DIR) and _PYLIB_DIR not in sys.path:
    sys.path.insert(0, _PYLIB_DIR)

PORT = int(os.environ.get("PORT", "8770"))
PUBLIC_AMANE_URL = os.environ.get("PUBLIC_AMANE_URL", "").rstrip("/")

USER_DB = os.path.join(DATA_DIR, "user.db")
AMANE_DB = os.path.join(AMANE_DATA, "amane.db")
IMAGE_CACHE = os.path.join(DATA_DIR, "imgcache")


def save_photo(name: str, blob: bytes) -> str:
    """把上传的写真图落到 PHOTO_DIR，返回相对访问路径。"""
    if not re.fullmatch(r"[0-9a-f]{8,64}\.(?:jpg|png|webp|gif)", name):
        raise ValueError("非法的图片文件名")
    os.makedirs(PHOTO_DIR, exist_ok=True)
    path = os.path.join(PHOTO_DIR, name)
    with open(path, "wb") as fh:
        fh.write(blob)
    return f"/api/user/photo/{name}"


def _read_secret(name: str) -> str:
    env = os.environ.get(name)
    if env:
        return env.strip()
    path = os.path.join(AMANE_DATA, name.lower().replace("amane_", ""))
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


AMANE_TOKEN = _read_secret("AMANE_TOKEN")

# 本地片是否直读文件（见 play() 里的说明）。默认关，等压测达标再开。
USE_LOCAL_PLAY = os.environ.get("AMANE_PLAY_LOCAL", "1") == "1"
