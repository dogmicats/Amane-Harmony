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

import core.upgrader as _U


class UpgradeMixin(object):
    def _upgrade_files(self) -> tuple[str, str, str]:
        return (os.path.join(DATA_DIR, "auto_update.json"),
                os.path.join(DATA_DIR, "auto_update.request.json"),
                os.path.join(DATA_DIR, "auto_update.state.json"))

    @route("GET", r"/api/user/upgrade/status")
    def upgrade_status(self, query: dict, *_) -> None:
        """客户端只看这一个：装没装助手、开关开没开、上一次升级结果。

        2026-11-15 加「容器内自升级」：`supported` 现在是**两选一**都能为真 ——
        宿主装了 systemd 助手（旧方案），或者本机 `/app` 是可写卷（新方案，半自动）。
        `mode` 说明哪一种；`can_apply` 才是「能不能点那个按钮」。
        """
        _U.recover_if_needed()
        cfg_p, req_p, state_p = self._upgrade_files()
        cfg, req, state = (self._read_json_dict(p) for p in (cfg_p, req_p, state_p))
        cap = _U.capability()
        host_helper = bool(state.get("installed")) and str(state.get("mode") or "") != "inplace"
        self._json({
            "ok": True,
            "supported": bool(host_helper or cap["supported"]),
            "mode": "inplace" if cap["supported"] else ("helper" if host_helper else ""),
            "can_apply": bool(cap["supported"]),
            "persistent": bool(cap["persistent"]),
            "writable": bool(cap["writable"]),
            "reason": str(cap["reason"] or ""),
            "current": _U.VERSION,
            "enabled": bool(cfg.get("enabled")),
            "requested": str(req.get("want") or ""),
            "state": str(state.get("state") or ""),
            "from": str(state.get("from") or ""),
            "to": str(state.get("to") or ""),
            "at": str(state.get("at") or ""),
            "message": str(state.get("message") or ""),
            "checked_at": str(state.get("checked_at") or ""),
        })

    @route("POST", r"/api/user/upgrade/apply")
    def upgrade_apply(self, query: dict, *_) -> None:
        """body `{version, sha256?, url?}` —— 容器内就地升级（下载→校验→切换→重启）。

        `url` 只给自测用（默认按 `AMANE_UPGRADE_REPO` 拼 GitHub 源码包地址）；
        生产路径应当由清单给 sha256，没有校验值一律拒绝。
        """
        body = self._body() or {}
        res = _U.start(str(body.get("version") or ""),
                       str(body.get("sha256") or ""),
                       str(body.get("url") or ""))
        if not res.get("ok"):
            return self._error(400, str(res.get("error") or "升级被拒绝"))
        self._json(res)

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
