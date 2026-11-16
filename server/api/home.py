"""home 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class HomeMixin(object):
    @route("GET", r"/api/user/home")
    def home(self, query, *_) -> None:
        fresh = (query.get("fresh") or ["0"])[0] in ("1", "true", "yes")
        # 大图候选池（2026-11-14 用户要求可自由选择）：
        #   老预设 `pool=all|fav|unwatched|rated|recent`
        #   自由条件：plib=1,2 & ptag=a,b & pactor=xx & pyear_from=2015 & pyear_to=2025
        #            & pmin_score=7 & pstate=any|unwatched|watched|fav|rated
        pool = (query.get("pool") or ["all"])[0]

        def one(name: str) -> str:
            return (query.get(name) or [""])[0].strip()

        def many(name: str) -> list:
            raw = one(name)
            return [x.strip() for x in raw.split(",") if x.strip()] if raw else []

        spec: dict = {}
        if many("plib"):
            spec["libs"] = many("plib")
        if many("ptag"):
            spec["tags"] = many("ptag")
        if one("pactor"):
            spec["actor"] = one("pactor")
        if one("pyear_from"):
            spec["year_from"] = one("pyear_from")
        if one("pyear_to"):
            spec["year_to"] = one("pyear_to")
        if one("pmin_score"):
            spec["min_score"] = one("pmin_score")
        if one("pstate") and one("pstate") != "any":
            spec["state"] = one("pstate")
        self._json(cached_home(fresh=fresh, hero_pool=pool, hero_spec=spec or None))

    @route("GET", r"/api/user/config")
    def client_config(self, query, *_) -> None:
        """客户端启动时拿一次：图片 token、播放源 id、库列表。"""
        source = "nas.local"
        try:
            req = Request(f"{AMANE_BASE}/api/playback/sources",
                          headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
            with _opener.open(req, timeout=8) as resp:
                data = json.load(resp)
            items = data.get("items") or []
            if items:
                source = items[0].get("source_id") or source
        except Exception as exc:  # noqa: BLE001
            log(f"读播放源失败，回退 {source}: {exc}")
        self._json({
            "version": VERSION,
            "image_token": IMAGE_TOKEN,
            "playback_source": source,
            "libraries": libraries(),
            "public_amane_url": PUBLIC_AMANE_URL,
            "generated_at": now_iso(),
        })

    @route("GET", r"/api/user/recommend")
    def recommend(self, query, *_) -> None:
        limit = int((query.get("limit") or ["20"])[0])
        self._json({"items": build_recommend(limit)})

    @route("GET", r"/api/user/daily")
    def daily_prefs(self, query, *_) -> None:
        """每日推荐的「取向」（2026-11-15）。

        只回三个取向 + 一句模糊说明 —— **不返回每个理由桶的配额**：
        理由类别会持续新增、比例也会跟着变，把它写死在界面上会天天过时；
        用户只要表达「更懂我 / 均衡 / 多惊喜」就够了。
        """
        self._json({
            "preset": daily_preset(),
            # 排障用：画像有多少料（客户端不显示）。taste/similar 全靠它，
            # 全是 0 就说明「没评过分 / 没收藏过」，推荐会落到 top / fresh / explore。
            "profile": {"seeds": len(_daily_profile()["seeds"]),
                        "actors": len(_daily_profile()["actors"]),
                        "tags": len(_daily_profile()["tags"])},
            "presets": [
                {"key": "taste", "label": "更懂我",
                 "desc": "多一点你熟悉的口味"},
                {"key": "balanced", "label": "均衡",
                 "desc": "老口味和新发现各来一些"},
                {"key": "explore", "label": "多惊喜",
                 "desc": "多推你还没碰过的"},
            ],
        })

    @route("PUT", r"/api/user/daily")
    def daily_set(self, query, *_) -> None:
        body = self._body()
        name = str(body.get("preset") or "").strip()
        try:
            set_daily_preset(name)
        except ValueError as exc:
            return self._error(400, str(exc))
        except OSError as exc:
            return self._error(500, f"保存失败：{exc}")
        # 换取向要让首页立刻重算（不然 5 分钟缓存里还是旧配方）
        invalidate_item_caches()
        self._json({"ok": True, "preset": name})

    @route("GET", r"/api/user/banners")
    def banners(self, query, *_) -> None:
        """每日推荐横幅（只含真横图 + 真实比例）；给调试/客户端刷新留一个独立入口。

        `?day=YYYY-MM-DD`（2026-11-15）：看「某一天会推什么」，用来核对跨天有没有换新。
        缺省 = 北京时间今天。
        """
        try:
            limit = max(1, min(int((query.get("limit") or ["12"])[0]), 24))
        except ValueError:
            limit = 12
        day = _day_of((query.get("day") or [""])[0])
        self._json({"day": day.isoformat(), "items": build_banners(limit, day=day)})

    @route("GET", r"/api/user/libraries")
    def libs(self, query, *_) -> None:
        self._json({"items": libraries()})

    @route("GET", r"/api/user/upstream")
    def upstream_info(self, query, *_) -> None:
        """旁挂看到的「上游是谁、什么版本、缺什么能力」。

        平台差异（Windows 桌面 18000 / macOS 数据目录 / Docker /data）由启动时探测解决，
        但探测结果必须能当场看见 —— 否则又回到「表象在客户端、原因在端口」的老路。
        `refresh=1` 强制重查，其余 60 秒缓存。
        """
        caps = upstream_caps(refresh=(query.get("refresh") or [""])[0] in ("1", "true"))
        self._json(caps)
