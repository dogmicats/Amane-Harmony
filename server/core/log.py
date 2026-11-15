"""日志输出（从 server.py 拆出）。

为什么单独一个文件：`log()` 被几乎所有模块用（db 打「只读打开失败」、扩展宿主打「加载失败」、
各端点打请求日志），放在 `server.py` 里会让每个拆出去的文件都要反向 import 入口，
那就成了循环依赖。这里是全局最底层，谁都可以依赖它，它不依赖任何人。
"""
from __future__ import annotations

import sys
import threading
from datetime import datetime

_lock = threading.Lock()


def log(msg: str) -> None:
    with _lock:
        sys.stdout.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        sys.stdout.flush()
