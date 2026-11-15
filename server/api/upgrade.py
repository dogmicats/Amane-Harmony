"""upgrade 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class UpgradeMixin(object):
    def _upgrade_files(self) -> tuple[str, str, str]:
        return (os.path.join(DATA_DIR, "auto_update.json"),
                os.path.join(DATA_DIR, "auto_update.request.json"),
                os.path.join(DATA_DIR, "auto_update.state.json"))

    @route("GET", r"/api/user/upgrade/status")
    def upgrade_status(self, query: dict, *_) -> None:
        """客户端只看这一个：装没装助手、开关开没开、上一次升级结果。"""
        cfg_p, req_p, state_p = self._upgrade_files()
        cfg, req, state = (self._read_json_dict(p) for p in (cfg_p, req_p, state_p))
        self._json({
            "ok": True,
            # 没有状态文件 = 宿主机没装 auto-update.sh
            "supported": bool(state.get("installed")),
            "enabled": bool(cfg.get("enabled")),
            "requested": str(req.get("want") or ""),
            "state": str(state.get("state") or ""),
            "from": str(state.get("from") or ""),
            "to": str(state.get("to") or ""),
            "at": str(state.get("at") or ""),
            "message": str(state.get("message") or ""),
            "checked_at": str(state.get("checked_at") or ""),
        })

    @route("PUT", r"/api/user/upgrade/auto")
    def upgrade_auto(self, query: dict, *_) -> None:
        """开 / 关自动升级。关掉只是不再「自动」，手动「立即升级」仍然可用。"""
        cfg_p, _req_p, state_p = self._upgrade_files()
        state = self._read_json_dict(state_p)
        if not state.get("installed"):
            return self._error(409, "这台机器还没装自动升级助手")
        body = self._body()
        enabled = bool(body.get("enabled"))
        payload = {"enabled": enabled, "updated_at": now_iso()}
        try:
            self._write_json_dict(cfg_p, payload)
        except OSError as exc:
            return self._error(500, f"写开关失败：{exc}")
        self._json({"ok": True, **payload})

    @route("PUT", r"/api/user/upgrade/request")
    def upgrade_request(self, query: dict, *_) -> None:
        """「现在升级」：只写一个请求文件，真正干活的是宿主机定时器（≤1 分钟内）。"""
        _cfg_p, req_p, state_p = self._upgrade_files()
        state = self._read_json_dict(state_p)
        if not state.get("installed"):
            return self._error(409, "这台机器还没装自动升级助手")
        if str(state.get("state") or "") == "upgrading":
            return self._json({"ok": True, "accepted": False,
                               "state": "upgrading", "message": "正在升级，稍等"})
        body = self._body()
        want = str(body.get("version") or "").strip()[:32]
        payload = {"want": want, "at": now_iso()}
        try:
            self._write_json_dict(req_p, payload)
        except OSError as exc:
            return self._error(500, f"写请求失败：{exc}")
        self._json({"ok": True, "accepted": True, **payload})
