"""misc 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class MiscMixin(object):
    @route("GET", r"/api/user/update/manifest")
    def update_manifest(self, query, *_) -> None:
        """把部署者准备的一份更新清单原样交给客户端。

        客户端默认按 GitHub 的 Release asset / 仓库镜像找清单；这个端点是**私有部署**
        的兜底：不联网、或想让客户端只听自己服务器的，把 update.json 放到
        `data/update.json`（或用 `UPDATE_MANIFEST` 指到别处）即可。
        没有这份文件就回 404 —— 客户端把它记成「这个源没有」，不影响其他源。
        """
        path = os.environ.get("UPDATE_MANIFEST", os.path.join(DATA_DIR, "update.json"))
        if not os.path.isfile(path):
            return self._error(404, "未配置更新清单（把 update.json 放到 data/ 目录）")
        try:
            with open(path, "rb") as fh:
                payload = json.loads(fh.read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"更新清单读不出来：{exc}")
        if not isinstance(payload, dict) or "client" not in payload:
            return self._error(500, "更新清单格式不对：缺 client 段")
        return self._json(payload)

    @route("GET", r"/api/user/extensions")
    def extensions(self, query, *_) -> None:
        """客户端据此决定要不要显示私有扩展的 UI。"""
        self._json({"items": EXT.loaded, "version": VERSION})

    @route("POST", r"/api/user/crash")
    def crash_report(self, query, *_) -> None:
        body = self._body()
        text = str(body.get("text") or "")[:20000]
        if text:
            try:
                os.makedirs(DATA_DIR, exist_ok=True)
                with open(os.path.join(DATA_DIR, "crash-reports.log"), "a", encoding="utf-8") as fh:
                    fh.write(f"\n===== {now_iso()} =====\n{text}\n")
            except OSError as exc:
                return self._error(500, str(exc))
        self._json({"ok": True, "bytes": len(text)})
