"""空间管理端点（2026-11-14 新增）。

三个动作，对应设置页上的三种交互：

- `GET  /api/user/storage`        看：每块占多少、上限多少、状态（ok/near/over）、能不能清
- `PUT  /api/user/storage`        设：给某一块单独设上限（0 = 不限）
- `POST /api/user/storage/clean`  清：清空某一块，或清掉播放缓存里的老版本目录

清单在 `core/storage.py`，这里只做 HTTP 包装（读 body / 校验 / 落盘 / 回显）。
"""
from __future__ import annotations

import core.logic as _L
import core.storage as storage

_L.export_to(globals())


class StorageMixin(object):

    @route("GET", r"/api/user/storage")
    def storage_report(self, query: dict, *_) -> None:
        """设置页进入时拉一次：全部块的占用 + 上限 + 状态。"""
        try:
            self._json(storage.report())
        except Exception as exc:      # noqa: BLE001
            self._error(500, f"统计空间失败：{exc}")

    @route("PUT", r"/api/user/storage")
    def storage_set(self, query: dict, *_) -> None:
        """设某一块的上限。body: {"key": "play", "mb": 2048}，mb=0 表示不限。"""
        body = self._body()
        key = str(body.get("key") or "").strip()
        if not key:
            return self._error(400, "缺少 key")
        known = {k["key"] for k in storage.KINDS + [storage._DB_KIND]}
        if key not in known:
            return self._error(400, f"没有这一块：{key}")
        # 数据库/写真图没有"上限"概念（是数据不是缓存）—— 明确拒绝，而不是静默忽略
        if key in ("db", "photos"):
            return self._error(409, "这一块是用户数据，不设上限也不会自动清理")
        try:
            mb = int(body.get("mb"))
        except (TypeError, ValueError):
            return self._error(400, "mb 必须是整数（0 表示不限）")
        if mb < 0:
            return self._error(400, "mb 不能是负数")
        if mb > 1024 * 200:
            return self._error(400, "上限过大（最大 204800 MB）")
        try:
            cfg = storage.set_budget(key, mb)
        except OSError as exc:
            return self._error(500, f"保存设置失败：{exc}")
        self._json({"ok": True, "key": key, "mb": mb, "settings": cfg,
                    "report": storage.report()})

    @route("POST", r"/api/user/storage/clean")
    def storage_clean(self, query: dict, *_) -> None:
        """清一块。body: {"key": "...", "age_days": 7}。

        `key`：
          - `play`      播放缓存（支持 age_days：7 / 30 / 0=全清）
          - `img`       图片缓存
          - `frames`    刷一刷打分/预览（固定按 90 天分批，不接受 age_days）
          - `backup`    升级备份
          - `stale-play` 清 play-cache 下的老版本目录
        `age_days`（可选，只对 play 生效）：
          - 7    清 7 天没碰过的（默认档，痛感最低）
          - 30   清 30 天没碰过的
          - 0    全清（空间立刻归零，代价是重看和拖动退化到"第一次看"）
        """
        body = self._body()
        key = str(body.get("key") or "").strip()
        age = body.get("age_days")
        try:
            # -1 视同"没传"（客户端用 class 序列化，不传时会带默认 -1）
            age_days = None if age is None or age == "" or int(age) < 0 else int(age)
        except (TypeError, ValueError):
            return self._error(400, "age_days 必须是整数（7 / 30 / 0）")
        if key == "stale-play":
            res = storage.clean_stale_play()
        elif key:
            res = storage.clean(key, age_days)
        else:
            return self._error(400, "缺少 key")
        if not res.get("ok"):
            return self._error(409, str(res.get("error") or "清理失败"))
        # 清完直接把最新统计带回去，客户端不用再拉一次
        res["report"] = storage.report()
        self._json(res)
