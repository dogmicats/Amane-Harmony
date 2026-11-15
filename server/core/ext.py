"""扩展宿主（从 server.py 拆出）。

扩展是「往一个已经跑起来的服务里塞新端点」的机制：每个 `ext/<id>/server_ext.py`
暴露 `install(api)`，拿到宿主给的 `api` 对象后自己 `api.route(...)` / `api.add_ddl(...)`
/ `api.hook(...)`。宿主只负责按清单加载、隔离失败（一个扩展炸了不能拖垮整个服务）。

★ 依赖提示（2026-11-14 事故复盘）★
这个类**不是自包含的**：它给扩展下发的 `api` 上挂着 user_db/amane_db/now_iso/
image_dims/public_image/amane_get/amane_post/route 一堆能力。所以拆它的前提是
**先把那些拆出去并在这里 import**，否则就是 `NameError` + 容器起不来
（`py_compile` 抓不到，语法是对的）。`tools/check_names.py` 就是为这个场景写的。
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import traceback
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from core.config import PHOTO_DIR, save_photo

from core.db import amane_db, user_db
from core.image import image_dims, public_image
from core.log import log
from core.router import route
from core.text import rel_score
from core.upstream import amane_get, amane_post
from core.util import now_iso

EXTENSIONS_MANIFEST = os.environ.get("EXTENSIONS_MANIFEST", "/app/extensions.json")

class ExtensionHost:
    """极薄的插件壳：路由 / 建表 / 钩子三件事，扩展自己注册，核心不感知具体功能。"""

    def __init__(self) -> None:
        self.loaded: list[dict] = []
        self.ddl: list[str] = []
        self.init_fns: list = []
        self.hooks: dict[str, list] = {}

    def route(self, method: str, pattern: str):
        return route(method, pattern)  # route 在本文件后面定义，load() 运行时才引用

    def add_ddl(self, sql: str) -> None:
        self.ddl.append(sql)

    def add_init(self, fn) -> None:
        self.init_fns.append(fn)

    def hook(self, name: str, fn) -> None:
        self.hooks.setdefault(name, []).append(fn)

    def call(self, name: str, *args) -> dict:
        """跑一组钩子并合并结果；单个扩展出错不影响核心流程。"""
        merged: dict = {}
        for fn in self.hooks.get(name, []):
            try:
                out = fn(*args)
                if isinstance(out, dict):
                    merged.update(out)
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook {name}: {exc}")
        return merged

    def call_hook(self, name: str, *args):
        """求值型钩子：返回**第一个**非 None 的结果。

        与 call() 的区别是语义：call() 是「往同一份响应里各加各的字段」（dict 合并），
        这里是「这个问题归谁回答」（比如 stills 问「scope=cast 的筛选片段长什么样」）——
        需要拿到单个值，也必须能区分「不管我事（None）」和「管了但没结果（空 dict）」。
        """
        for fn in self.hooks.get(name, []):
            try:
                out = fn(*args)
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 扩展 hook {name}: {exc}")
                continue
            if out is not None:
                return out
        return None

    def load(self) -> None:
        import importlib.util
        from types import SimpleNamespace
        try:
            with open(EXTENSIONS_MANIFEST, encoding="utf-8") as fh:
                manifest = json.load(fh)
        except (OSError, ValueError) as exc:
            log(f"扩展清单读不到 {EXTENSIONS_MANIFEST}: {exc}；以无扩展模式启动")
            return
        api = SimpleNamespace(
            route=self.route, add_ddl=self.add_ddl, add_init=self.add_init,
            hook=self.hook, call_hook=self.call_hook,
            # `call` / `hooks` 是给「扩展自己的列表接口」用的：有些端点（cast/find、
            # facets/*/media）不走核心 browse，但要和 browse 同一套筛选口径，
            # 只能自己遍历 browse_where 钩子、再调 marks_extra 补字段。
            call=self.call, hooks=self.hooks,
            user_db=user_db, amane_db=amane_db, log=log, now_iso=now_iso,
            # 清单页搜索的统一相关性口径：核心已在 amane_db() 连接上注册
            # `amane_rel(name, kw)`，这里再给一份 Python 实现供扩展兜底
            rel_score=rel_score,
            os=os, json=json, datetime=datetime, timedelta=timedelta, timezone=timezone,
            # 通用上游能力：扩展不必自己读凭据文件 / 拼图片代理 URL
            amane_get=amane_get, amane_post=amane_post, public_image=public_image,
            # 通用图片能力：量宽高（img_dims 缓存 + 只取头部 128KB）
            image_dims=image_dims,
            # 上传类扩展要把文件落盘，统一走核心，别各写一套路径规则
            save_photo=save_photo, photo_dir=PHOTO_DIR,
        )
        base = os.path.dirname(EXTENSIONS_MANIFEST)
        for item in manifest.get("extensions", []):
            rel = item.get("entry")
            if not rel:
                continue
            path = os.path.join(base, rel)
            if not os.path.isfile(path):
                log(f"WARN 扩展 {item.get('id')} 入口不存在: {path}")
                continue
            try:
                spec = importlib.util.spec_from_file_location(f"amane_ext_{item['id']}", path)
                mod = importlib.util.module_from_spec(spec)
                sys.modules[spec.name] = mod
                spec.loader.exec_module(mod)
                self.loaded.append(mod.install(api) or {"id": item["id"]})
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR 加载扩展 {item.get('id')} 失败: {exc}\n{traceback.format_exc()}")
        log(f"扩展加载完成：{[x.get('id') for x in self.loaded] or '无'}")


EXT = ExtensionHost()
