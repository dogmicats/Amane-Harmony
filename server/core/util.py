"""小工具：时间戳 + JSON 兜底解析（从 server.py 拆出）。

都是一行能说清的纯函数，但被几十处调用，所以单独成文件、零依赖，
免得别的模块为了用 `now_iso()` 去 import 入口。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _json_list(raw) -> list:
    if not raw:
        return []
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def _json_dict(raw) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}
