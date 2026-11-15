"""路由表与 `@route` 装饰器（从 server.py 拆出）。

为什么单独成文件：`@route(...)` 被 `Handler` 的 138 个方法用，`main()` 又要遍历
`ROUTES` 去注册。它如果留在入口文件里，任何「想注册一个端点」的模块都得 import 入口 ——
包括 `core/ext.py` 里的扩展宿主，那就成了循环。

注意 `ROUTES` 是**可变全局**：谁 import 它拿到的都是同一个 list 对象，
所以各处的追加都生效（`from core.router import ROUTES` 不会复制列表）。
"""
from __future__ import annotations

import re

# 元素是 (method, compiled_regex, handler_fn)
ROUTES: list = []


def route(method: str, pattern: str):
    """把一个方法登记成端点。`pattern` 是正则片段，用 `(...)` 捕获路径参数。"""
    regex = re.compile("^" + pattern + "$")

    def deco(fn):
        ROUTES.append((method, regex, fn))
        return fn

    return deco
