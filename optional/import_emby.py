#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""可选：把收藏同步成 Emby 星标。

本文件是通用化示例，所有路径与账号都来自环境变量，不含任何真实值。
不在默认部署流程里，可不用。
"""
from __future__ import annotations

import json
import os
import urllib.request

EMBY_URL = os.environ.get("EMBY_URL", "http://127.0.0.1:8096")
EMBY_TOKEN = os.environ.get("EMBY_TOKEN", "")
EMBY_USER = os.environ.get("EMBY_USER", "")
# 形如 "/media=/mnt/media,/media2=/mnt/media2"，按最长前缀匹配
PATH_MAP = [
    tuple(item.split("=", 1))
    for item in os.environ.get("EMBY_PATH_MAP", "").split(",")
    if "=" in item
]


def map_path(path: str) -> str:
    for src, dst in sorted(PATH_MAP, key=lambda p: len(p[0]), reverse=True):
        if path.startswith(src):
            return dst + path[len(src):]
    return path


def main() -> None:
    if not EMBY_TOKEN:
        raise SystemExit("请设置 EMBY_TOKEN（本脚本不会把 token 写进日志）")
    req = urllib.request.Request(
        f"{EMBY_URL.rstrip('/')}/Users?api_key={EMBY_TOKEN}",
        headers={"X-Emby-Token": EMBY_TOKEN},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        users = json.load(resp)
    print(f"可用账号 {len(users)} 个；EMBY_USER={EMBY_USER or '(未设置)'}")
    print("PATH_MAP 条目：", len(PATH_MAP))


if __name__ == "__main__":
    main()
