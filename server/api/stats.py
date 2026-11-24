"""stats 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class StatsMixin(object):
    @route("GET", r"/api/user/stats")
    def stats(self, query, *_) -> None:
        with user_db() as conn:
            fav = conn.execute("SELECT COUNT(*) FROM favorites").fetchone()[0]
            hist = conn.execute("SELECT COUNT(*) FROM history").fetchone()[0]
            done = conn.execute("SELECT COUNT(*) FROM history WHERE finished = 1").fetchone()[0]
        with amane_db() as conn:
            total = conn.execute("SELECT COUNT(DISTINCT metadata_id) FROM media_files").fetchone()[0]
        self._json({"favorites": fav, "history": hist, "finished": done, "library_items": total})

    @route("POST", r"/api/user/stats/sample")
    def stats_sample(self, query, *_) -> None:
        """上报一个播放位置采样（只追加）。老客户端不发这个，由 history 顺带采。"""
        body = self._body()
        try:
            mid = int(body.get("metadata_id"))
        except (TypeError, ValueError):
            return self._error(422, "metadata_id 必填")
        try:
            position = max(0.0, float(body.get("position") or 0))
            duration = max(0.0, float(body.get("duration") or 0))
        except (TypeError, ValueError):
            return self._error(422, "position / duration 必须是数字")
        src = str(body.get("src") or "app")[:16]
        local_date, local_hour = _local_parts(body)
        with user_db() as conn:
            sid = add_sample(conn, mid, position, duration, local_date, local_hour, src)
            total = conn.execute("SELECT COUNT(*) FROM play_progress").fetchone()[0]
        self._json({"ok": True, "id": sid, "samples": total, "local_date": local_date,
                    "local_hour": local_hour})

    @route("GET", r"/api/user/stats/overview")
    def stats_overview(self, query, *_) -> None:
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        where = " WHERE 1=1" + dw + sw
        args = dargs + sargs
        with user_db() as conn:
            films = conn.execute(
                f"SELECT COUNT(DISTINCT metadata_id) FROM stats_daily{where}", args).fetchone()[0]
            total = conn.execute(
                f"SELECT COALESCE(SUM(secs), 0) FROM stats_daily{where}", args).fetchone()[0]
            samples = conn.execute(
                f"SELECT COALESCE(SUM(samples), 0) FROM stats_daily{where}", args).fetchone()[0]
            finished = conn.execute(
                f"SELECT COUNT(DISTINCT metadata_id) FROM stats_daily{where} AND finished = 1",
                args).fetchone()[0]
            days = [r[0] for r in conn.execute(
                f"SELECT date FROM stats_daily{where} GROUP BY date HAVING SUM(secs) > 0 "
                "ORDER BY date", args).fetchall()]
            span = conn.execute(
                f"SELECT MIN(date), MAX(date) FROM stats_daily{where}", args).fetchone()
            # 可用范围不受筛选影响：页面上「你的数据从哪到哪」要用它，否则一筛就自相矛盾
            avail = conn.execute(
                f"SELECT MIN(date), MAX(date) FROM stats_daily WHERE 1=1{sw}", sargs).fetchone()

        # 连续天数：按「有观看秒数的自然日」连成串。当前连续只在最后一天是今天/昨天时才算，
        # 否则「连续 3 天」会一直是三个月前的数字，看着像 bug。
        longest = 0
        run = 0
        last_day = None
        for raw in days:
            try:
                cur = date.fromisoformat(raw)
            except ValueError:
                continue
            run = run + 1 if (last_day and (cur - last_day).days == 1) else 1
            longest = max(longest, run)
            last_day = cur
        streak = 0
        if last_day and (date.today() - last_day).days <= 1:
            streak = run

        quality = stats_quality()
        data = {
            "films": films,
            "seconds": round(float(total)),
            "hours": round(float(total) / 3600, 1),
            "days": len(days),
            "streak": streak,
            "longest_streak": longest,
            "finished": finished,
            "from": span[0] if span else None,
            "to": span[1] if span else None,
            "available_from": avail[0] if avail else None,
            "available_to": avail[1] if avail else None,
            "samples": int(samples),
            # 两个口径各有多少条采样（测试版切口径时要用它显示「测试数据 24 条」）
            "scope_samples": {"real": int(quality.get("real", 0)),
                              "test": int(quality.get("test", 0))},
            "suspicious": -1,
            "dropped": -1,
        }
        # 质量指标只有「不加筛选」时才说得清（拖动/丢弃是全局计数，不按日存）
        if not start and not end and scope == "real":
            data["samples"] = int(quality.get("samples", 0))
            data["suspicious"] = int(quality.get("jump", 0)) + int(quality.get("rewind", 0))
            data["dropped"] = int(quality.get("dropped", 0)) + int(quality.get("unknown", 0))

        self._json(stats_env(films > 0, stats_confidence(films, len(days)), data,
                             "这个范围内还没有观看记录", range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/trend")
    def stats_trend(self, query, *_) -> None:
        ensure_stats()
        try:
            weeks = int((query.get("weeks") or ["12"])[0])
        except ValueError:
            weeks = 12
        weeks = max(4, min(weeks, 53))
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT date, metadata_id, secs, finished FROM stats_daily WHERE 1=1{dw}{sw}",
                dargs + sargs).fetchall()

        by_week: dict = {}
        for r in rows:
            try:
                day = date.fromisoformat(r["date"])
            except ValueError:
                continue
            week = day - timedelta(days=day.weekday())     # 周一为一周之始
            slot = by_week.setdefault(week, {"secs": 0.0, "started": set(), "finished": set()})
            slot["secs"] += float(r["secs"] or 0)
            slot["started"].add(r["metadata_id"])
            if r["finished"]:
                slot["finished"].add(r["metadata_id"])

        today = date.today()
        cur = today - timedelta(days=today.weekday())

        def week_of(raw: str):
            try:
                d = date.fromisoformat(raw)
            except ValueError:
                return None
            return d - timedelta(days=d.weekday())

        # 窗口：给了范围就按范围，没给就看最近 N 周（有更早数据时前扩，最多一年）
        last = week_of(end) if end else cur
        first = week_of(start) if start else None
        if last is None:
            last = cur
        if first is None:
            first = last - timedelta(weeks=weeks - 1)
            if by_week:
                first = min(first, min(by_week))
        if (last - first).days > 364:
            first = last - timedelta(weeks=52)
        if last < first:
            first, last = last, first

        items = []
        films_all: set = set()
        week = first
        while week <= last:
            slot = by_week.get(week)
            started = len(slot["started"]) if slot else 0
            done = len(slot["finished"]) if slot else 0
            secs = round(slot["secs"]) if slot else 0
            items.append({
                "week": f"{week.isocalendar()[0]}-W{week.isocalendar()[1]:02d}",
                "from": week.isoformat(),
                "to": (week + timedelta(days=6)).isoformat(),
                "films": started,
                "finished": done,
                "rate": round(done / started, 3) if started else 0.0,
                "seconds": secs,
                "hours": round(secs / 3600, 1),
            })
            if slot:
                films_all |= slot["started"]
            week += timedelta(days=7)

        data = {"weeks": items, "weeks_count": len(items), "films": len(films_all)}
        self._json(stats_env(len(films_all) > 0, stats_confidence(len(films_all), len(by_week)),
                             data, "这个范围内还没有足够的记录画趋势",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/when")
    def stats_when(self, query, *_) -> None:
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("local_date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT local_date, local_hour, secs, samples FROM stats_hour WHERE 1=1{dw}{sw}",
                dargs + sargs).fetchall()
        hours = [0.0] * 24
        hour_samples = [0] * 24
        weekdays = [0.0] * 7
        day_samples = [0] * 7
        unknown = 0
        for r in rows:
            hour = int(r["local_hour"])
            if 0 <= hour < 24:
                hours[hour] += float(r["secs"] or 0)
                hour_samples[hour] += int(r["samples"] or 0)
            else:
                unknown += int(r["samples"] or 0)   # 客户端没报本地时间，只能估算
            try:
                wd = date.fromisoformat(r["local_date"]).weekday()
            except ValueError:
                continue
            weekdays[wd] += float(r["secs"] or 0)
            day_samples[wd] += int(r["samples"] or 0)

        def top_index(values: list) -> int:
            best = -1
            for i, v in enumerate(values):
                if v > 0 and (best < 0 or v > values[best]):
                    best = i
            return best

        total = sum(hours)
        data = {
            "hours": [round(v) for v in hours],
            "hours_samples": hour_samples,
            "weekdays": [round(v) for v in weekdays],
            "weekday_samples": day_samples,
            "peak_hour": top_index(hours),
            "peak_weekday": top_index(weekdays),
            "unknown_samples": unknown,
        }
        # 时段分布的样本量口径和「部数」不同：这里看「有秒数的格子数 + 总时长」，
        # 少于 1 小时的样本画出来的柱子全是噪声。
        cells = sum(1 for v in hours if v > 0)
        conf = "full" if (total >= 3600 and cells >= 6) else ("sparse" if total > 0 else "estimate")
        self._json(stats_env(total >= 60, conf, data, "这个范围内还没有足够的记录看时段",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/heat")
    def stats_heat(self, query, *_) -> None:
        """0–100% 热度条。`mid` 缺省 = 全库平均（metadata_id=0 那份合计）。"""
        ensure_stats()
        raw = (query.get("mid") or [""])[0]
        mid = int(raw) if raw.isdigit() else 0
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("local_date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT bucket, SUM(secs) AS secs FROM stats_heat "
                f"WHERE metadata_id = ?{dw}{sw} GROUP BY bucket",
                [mid] + dargs + sargs).fetchall()
        secs = [0.0] * STATS_HEAT_BUCKETS
        for r in rows:
            bucket = int(r["bucket"])
            if 0 <= bucket < STATS_HEAT_BUCKETS:
                secs[bucket] = float(r["secs"] or 0)
        peak = max(secs) if secs else 0.0
        total = sum(secs)
        buckets = [round(v / peak, 3) if peak > 0 else 0.0 for v in secs]
        data = {
            "mid": mid or None,
            "buckets": buckets,               # 0..1，客户端直接乘以条宽
            "secs": [round(v) for v in secs],
            "total_secs": round(total),
            "peak_bucket": (secs.index(peak) if peak > 0 else -1),
            "bucket_pct": 100 / STATS_HEAT_BUCKETS,
        }
        # 少于 1 分钟样本的热度条没有意义，宁可显示「还在积累」
        self._json(stats_env(total >= 60, "full" if total >= 900 else "sparse", data,
                             "这个范围内这部片的观看位置还在积累",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/calendar")
    def stats_calendar(self, query, *_) -> None:
        """观影日历（365 格热力图）：按自然日聚合。

        只回**有观看的日子**（`secs > 0`），空格由客户端补 —— 一年 365 条空行白白占
        几十 KB，客户端本来就要按格子铺一遍。

        `days` 默认 371（53 周 × 7），上限 731（两年，明细保留期）。
        """
        ensure_stats()
        try:
            span = int((query.get("days") or ["371"])[0])
        except ValueError:
            span = 371
        span = max(31, min(731, span))
        scope = stats_scope(query)
        sw, sargs = stats_scope_sql("scope", scope)
        end = date.today()
        start = end - timedelta(days=span - 1)
        with user_db() as conn:
            rows = conn.execute(
                "SELECT date, COALESCE(SUM(secs), 0) AS secs, "
                "COUNT(DISTINCT metadata_id) AS films "
                f"FROM stats_daily WHERE date >= ? AND date <= ?{sw} "
                "GROUP BY date ORDER BY date",
                [start.isoformat(), end.isoformat()] + sargs).fetchall()

        days = []
        best = None
        longest = 0
        run = 0
        prev = None
        for r in rows:
            secs = float(r["secs"] or 0)
            if secs <= 0:
                continue
            item = {"d": r["date"], "s": round(secs), "f": int(r["films"] or 0)}
            days.append(item)
            if best is None or item["s"] > best["s"]:
                best = item
            try:
                cur = date.fromisoformat(r["date"])
            except ValueError:
                cur = None
            if cur is not None:
                run = run + 1 if (prev and (cur - prev).days == 1) else 1
                longest = max(longest, run)
                prev = cur

        films = max([d["f"] for d in days], default=0)
        self._json(stats_env(
            bool(days), stats_confidence(films, len(days)),
            {"days": days, "from": start.isoformat(), "to": end.isoformat(),
             "window": span, "active_days": len(days), "best": best,
             "max_streak": longest},
            "这段时间还没有观看记录",
            range_=(start.isoformat(), end.isoformat()), scope=scope))

    @route("GET", r"/api/user/stats/annual")
    def stats_annual(self, query, *_) -> None:
        """年度报告：一年的总量 / 12 个月 / 12 个时段 / 最忙一天 / 榜单。

        一次回完所有屏需要的数 —— 年报是「一路往下翻」的，每屏发一个请求会在
        翻页时一卡一卡（而且用户很可能在地铁里翻）。
        """
        ensure_stats()
        raw = (query.get("year") or [""])[0]
        year = int(raw) if raw.isdigit() else date.today().year
        if year < 2000 or year > 2100:
            return self._error(422, "year 不合法")
        scope = stats_scope(query)
        start = f"{year}-01-01"
        end = f"{year}-12-31"
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        where = " WHERE 1=1" + dw + sw
        hw, hargs = stats_range_sql("local_date", start, end)
        with user_db() as conn:
            films = conn.execute(
                f"SELECT COUNT(DISTINCT metadata_id) FROM stats_daily{where}",
                dargs + sargs).fetchone()[0]
            total = conn.execute(
                f"SELECT COALESCE(SUM(secs), 0) FROM stats_daily{where}",
                dargs + sargs).fetchone()[0]
            months = [0.0] * 12
            for r in conn.execute(
                    "SELECT substr(date, 6, 2) AS m, COALESCE(SUM(secs), 0) AS s "
                    f"FROM stats_daily{where} GROUP BY m", dargs + sargs):
                try:
                    idx = int(r["m"]) - 1
                except (TypeError, ValueError):
                    continue
                if 0 <= idx < 12:
                    months[idx] = float(r["s"] or 0)
            dayrows = conn.execute(
                "SELECT date, COALESCE(SUM(secs), 0) AS s, "
                "COUNT(DISTINCT metadata_id) AS f, MAX(finished) AS fin "
                f"FROM stats_daily{where} GROUP BY date ORDER BY date",
                dargs + sargs).fetchall()
            per = conn.execute(
                "SELECT metadata_id, COALESCE(SUM(secs), 0) AS s, "
                f"COUNT(*) AS d FROM stats_daily{where} GROUP BY metadata_id",
                dargs + sargs).fetchall()
            hours = [0.0] * 24
            for r in conn.execute(
                    "SELECT local_hour AS h, COALESCE(SUM(secs), 0) AS s "
                    f"FROM stats_hour WHERE 1=1{hw}{sw} GROUP BY h",
                    hargs + sargs):
                try:
                    hour = int(r["h"])
                except (TypeError, ValueError):
                    continue
                if 0 <= hour < 24:
                    hours[hour] = float(r["s"] or 0)

        # 排名先按秒数，平局再看天数（和「偏好榜」同一口径，两页数字才对得上）
        ranked = sorted(
            [(int(r["metadata_id"]), float(r["s"] or 0), int(r["d"] or 0)) for r in per],
            key=lambda t: (t[1], t[2]), reverse=True)
        film_secs = {mid: secs for mid, secs, _ in ranked}
        names: dict = {}
        if ranked:
            ids = [mid for mid, _, _ in ranked]
            with amane_db() as conn2:
                for i in range(0, len(ids), 400):
                    chunk = ids[i:i + 400]
                    marks = ",".join("?" * len(chunk))
                    for row in conn2.execute(
                            f"SELECT id, number, title FROM metadata WHERE id IN ({marks})",
                            chunk):
                        names[int(row["id"])] = (str(row["number"] or ""),
                                                 str(row["title"] or ""))

        top_films = []
        for mid, secs, _ in ranked[:8]:
            number, title = names.get(mid, ("", ""))
            top_films.append({"id": mid, "number": number, "title": title,
                              "seconds": round(secs)})

        active = [(r["date"], float(r["s"] or 0), int(r["f"] or 0), int(r["fin"] or 0))
                  for r in dayrows if float(r["s"] or 0) > 0]
        best = None
        if active:
            bd, bs, bf, _ = max(active, key=lambda t: t[1])
            best = {"d": bd, "s": round(bs), "f": bf}
        longest = 0
        run = 0
        prev = None
        for d, _s, _f, _fin in active:
            try:
                cur = date.fromisoformat(d)
            except ValueError:
                continue
            run = run + 1 if (prev and (cur - prev).days == 1) else 1
            longest = max(longest, run)
            prev = cur
        finished = sum(1 for t in active if t[3])

        data = {
            "year": year,
            "films": int(films),
            "seconds": round(float(total)),
            "hours": round(float(total) / 3600, 1),
            "days": len(active),
            "finished_days": finished,
            "months": [round(v) for v in months],
            # 24 个小时桶各多少秒（第二屏「你几点看」用）；名字不叫 hours，
            # 上面那个 hours 是总时长，同名会把总量覆盖掉
            "hour_secs": [round(v) for v in hours],
            "best": best,
            "max_streak": longest,
            "from": active[0][0] if active else None,
            "to": active[-1][0] if active else None,
            "top_films": top_films,
            "top_actors": stats_top_items("actor", film_secs, 5),
            "top_tags": stats_top_items("tag", film_secs, 5),
        }
        self._json(stats_env(
            bool(active), stats_confidence(int(films), len(active)), data,
            f"{year} 年还没有观看记录", range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/top")
    def stats_top(self, query, *_) -> None:
        ensure_stats()
        kind = (query.get("kind") or ["actor"])[0]
        if kind not in ("actor", "tag", "studio"):
            return self._error(422, "kind 只能是 actor / tag / studio")
        try:
            limit = int((query.get("limit") or ["10"])[0])
        except ValueError:
            limit = 10
        limit = max(1, min(limit, 50))
        start, end = stats_range(query)
        scope = stats_scope(query)
        dw, dargs = stats_range_sql("date", start, end)
        sw, sargs = stats_scope_sql("scope", scope)
        with user_db() as conn:
            rows = conn.execute(
                f"SELECT metadata_id, SUM(secs) AS secs FROM stats_daily WHERE 1=1{dw}{sw} "
                "GROUP BY metadata_id", dargs + sargs).fetchall()
        film_secs = {r["metadata_id"]: float(r["secs"] or 0) for r in rows}
        # 标签榜与标签列表同一口径：隐藏过的不出现在榜里
        hidden = hidden_facet_ids("tag") if kind == "tag" else set()
        items = stats_top_items(kind, film_secs, limit, hidden)
        data = {"kind": kind, "items": items, "films": len(film_secs),
                "hidden_tags": len(hidden) if kind == "tag" else 0}
        self._json(stats_env(bool(items), stats_confidence(len(film_secs), len(film_secs)),
                             data, "这个范围内还没有足够记录排榜",
                             range_=(start, end), scope=scope))

    @route("POST", r"/api/user/stats/rebuild")
    def stats_rebuild(self, query, *_) -> None:
        """整批重算（幂等）。改口径后由客户端或运维手动触发，平时读端点会自己判断。"""
        quality = rebuild_stats()
        self._json({"ok": True, "version": STATS_VERSION, "data": quality})

    @route("POST", r"/api/user/stats/purge")
    def stats_purge(self, query, *_) -> None:
        """清除某个时段的采样（可只清测试数据）。清完立刻重算，页面刷新就少一块。

        **真数据必须同时给 from 与 to** —— 只允许「清掉某段」，不允许一键抹平全部，
        否则一次误触就把几年的记录清零，而且采样是只追加的、删了就回不来。
        """
        body = self._body()
        start = str(body.get("from") or "")[:10]
        end = str(body.get("to") or "")[:10]
        scope = str(body.get("scope") or "test").lower()
        if scope not in ("test", "real", "all"):
            scope = "test"
        ok_date = lambda v: bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", v or ""))  # noqa: E731
        if start and not ok_date(start):
            start = ""
        if end and not ok_date(end):
            end = ""
        if scope in ("real", "all") and not (ok_date(start) and ok_date(end)):
            return self._error(422, "清除真实数据必须同时给 from 与 to（只允许清一段，防误删）")

        sql = "DELETE FROM play_progress WHERE 1=1"
        args: list = []
        if start:
            sql += " AND local_date >= ?"
            args.append(start)
        if end:
            sql += " AND local_date <= ?"
            args.append(end)
        if scope == "test":
            sql += " AND lower(src) = 'test'"
        elif scope == "real":
            sql += " AND lower(src) != 'test'"
        with user_db() as conn:
            removed = conn.execute(sql, args).rowcount
        quality = rebuild_stats()
        log(f"统计清除 scope={scope} {start or '-'}~{end or '-'} rows={removed}")
        self._json({"ok": True, "removed": removed, "version": STATS_VERSION,
                    "data": quality})

    @route("POST", r"/api/user/stats/testdata")
    def stats_testdata(self, query, *_) -> None:
        """生成一批模拟采样（`src=test`），只喂「测试数据」口径。

        为什么要有：验收要看图、看榜、看热度条，真数据不够就什么都验不出来；而模拟
        数据一旦混进真实口径，数字就永远说不清。所以两边**物理分开**：这里只写
        `src=test`，清也只清这一类，真实口径一条都不碰。
        """
        body = self._body()
        try:
            films = max(1, min(int(body.get("films") or 6), 20))
            days = max(1, min(int(body.get("days") or 28), 180))
        except (TypeError, ValueError):
            films, days = 6, 28

        with user_db() as conn:
            dropped = conn.execute(
                "DELETE FROM play_progress WHERE lower(src) = 'test'").rowcount
        with amane_db() as conn:
            rows = conn.execute(
                "SELECT id, COALESCE(NULLIF(runtime, 0), 120) AS runtime FROM metadata "
                "ORDER BY RANDOM() LIMIT ?", (films,)).fetchall()
        if not rows:
            return self._error(409, "库里没有影片，先生成不了测试数据")

        today = date.today()
        inserted = 0
        with user_db() as conn:
            for idx, row in enumerate(rows):
                mid = int(row["id"])
                dur = float(row["runtime"]) * 60.0        # runtime 的单位是分钟
                # 每部片落在不同的日子与时段，这样趋势/时段/热度三张图才有形状；
                # 三分之一「看完」（99%），其余看到一半 —— 完成率折线才有起伏。
                offset = (idx * days) // max(len(rows), 1)
                day = today - timedelta(days=offset)
                hour = 20 + (idx % 4)
                target = 0.99 if idx % 3 == 0 else 0.5
                step = max(30.0, dur * target / 6.0)
                pos = 0.0
                for _ in range(6):
                    pos = min(dur, pos + step)
                    add_sample(conn, mid, pos, dur, day.strftime("%Y-%m-%d"),
                               min(hour, 23), "test")
                    inserted += 1
        quality = rebuild_stats()
        log(f"测试数据 scope=test films={len(rows)} samples={inserted} 清旧={dropped}")
        self._json({"ok": True, "films": len(rows), "samples": inserted,
                    "removed": dropped, "version": STATS_VERSION, "data": quality})

    @route("GET", r"/api/user/stats/tag-hygiene")
    def stats_tag_hygiene(self, query, *_) -> None:
        """「这些标签该不该隐藏」的候选清单（只给字面与覆盖率判据，不猜语义）。"""
        try:
            limit = int((query.get("limit") or ["12"])[0])
        except ValueError:
            limit = 12
        limit = max(1, min(limit, 50))
        items = tag_hygiene_candidates(limit)
        data = {"items": items, "hidden": len(hidden_facet_ids("tag"))}
        self._json({"ok": True, "version": STATS_VERSION, "data": data})

    @route("GET", r"/api/user/stats/dropoff")
    def stats_dropoff(self, query, *_) -> None:
        """弃片榜：按演员/标签算「打开却没看完」的比例。

        口径：打开 = 累计观看 ≥60s；弃片 = 末次采样在 7 天前且最好完成率 <95%；
        样本 <5 的实体不进榜（否则「1 投 1 弃」这种人会排第一，榜单就没有说服力）。
        """
        ensure_stats()
        kind = (query.get("kind") or ["actor"])[0]
        if kind not in ("actor", "tag"):
            return self._error(422, "kind 只能是 actor / tag")
        try:
            limit = int((query.get("limit") or ["10"])[0])
        except ValueError:
            limit = 10
        limit = max(1, min(limit, 50))
        start, end = stats_range(query)
        scope = stats_scope(query)
        # 测试口径放宽门槛：模拟数据本来就只有几部，卡 5 会让整块永远空，
        # 验收时看不出「逻辑对不对」。真实口径仍按策划的 5。
        min_sample = 2 if scope == "test" else STATS_MIN_SAMPLE
        cutoff = (date.today() - timedelta(days=STATS_DROP_DAYS)).isoformat()
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)

        opened = {mid: f for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS}
        dropped = {mid for mid, f in opened.items()
                   if f["last"] <= cutoff and f["ratio"] < FINISH_RATIO}
        ent = stats_entity_of(kind, opened.keys())
        agg: dict = {}
        for mid in opened:
            for name, nid in ent.get(mid, []):
                slot = agg.setdefault((name, nid), {"name": name, "id": nid,
                                                    "opened": 0, "dropped": 0})
                slot["opened"] += 1
                if mid in dropped:
                    slot["dropped"] += 1
        items = []
        for v in agg.values():
            if v["opened"] < min_sample:
                continue
            items.append({"name": v["name"], "id": v["id"], "opened": v["opened"],
                          "dropped": v["dropped"],
                          "rate": round(v["dropped"] / v["opened"], 3)})
        items.sort(key=lambda v: (-v["rate"], -v["opened"], v["name"]))
        conf = "full" if len(opened) >= 10 else ("sparse" if opened else "estimate")
        data = {"kind": kind, "items": items[:limit], "opened": len(opened),
                "dropped": len(dropped), "cutoff": cutoff,
                "min_sample": min_sample}
        self._json(stats_env(bool(items), conf, data,
                             "样本还不够，先多看几部（同类至少要 5 部）",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/dropcurve")
    def stats_dropcurve(self, query, *_) -> None:
        """开头流失曲线：每部片看到最远的位置落进 10 个桶，再看「有多少部能撑到第 N 桶」。

        `reached[i]` 是**累计**比例（看到 ≥10%×(i+1) 的片子占比），所以最后一项接近完成率，
        而不是在 0 处最高 —— 后者是直方图，读者会读错方向。
        """
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)
        opened = [f for f in films.values() if f["secs"] >= STATS_OPEN_SECS]
        buckets = [0] * 10
        for f in opened:
            buckets[min(9, max(0, int(f["ratio"] * 10)))] += 1
        total = len(opened)
        reached = []
        for i in range(10):
            reached.append(round(sum(buckets[i:]) / total, 3) if total else 0.0)

        avg_secs = 0.0
        mids = [mid for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS]
        if mids:
            total_min, counted = 0.0, 0
            with amane_db() as conn:
                for i in range(0, len(mids), 400):
                    chunk = mids[i:i + 400]
                    marks = ",".join("?" * len(chunk))
                    row = conn.execute(
                        f"SELECT SUM(runtime), COUNT(*) FROM metadata "
                        f"WHERE id IN ({marks}) AND runtime > 0", chunk).fetchone()
                    if row and row[0]:
                        total_min += float(row[0])
                        counted += int(row[1] or 0)
            if counted:
                avg_secs = total_min / counted * 60.0

        data = {"buckets": buckets, "reached": reached, "films": total,
                "avg_runtime_secs": round(avg_secs)}
        conf = "full" if total >= 10 else ("sparse" if total else "estimate")
        self._json(stats_env(total > 0, conf, data, "还没有打开的片子",
                             range_=(start, end), scope=scope))

    @route("GET", r"/api/user/stats/idle")
    def stats_idle(self, query, *_) -> None:
        """吃灰清单 + 冷落演员 / 冷落厂牌。"""
        ensure_stats()
        try:
            days = int((query.get("days") or ["30"])[0])
        except ValueError:
            days = 30
        days = max(1, min(days, 3650))
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
        with user_db() as conn:
            fav = conn.execute(
                "SELECT metadata_id, created_at FROM favorites").fetchall()
            films = stats_films(conn, "", "", "real")
        fav_ids = [int(r["metadata_id"]) for r in fav]
        fav_at = {int(r["metadata_id"]): str(r["created_at"]) for r in fav}
        idle = [mid for mid in fav_ids
                if fav_at[mid] <= cutoff and mid not in films]

        # 冷落演员 / 厂牌：收藏了他的片，却一部都没打开
        fav_ent = stats_entity_of("actor", fav_ids)
        opened_actor = {nid for pairs in stats_entity_of("actor", list(films)).values()
                        for _n, nid in pairs}
        cold_actor: dict = {}
        for mid in fav_ids:
            for name, nid in fav_ent.get(mid, []):
                if nid in opened_actor:
                    continue
                slot = cold_actor.setdefault(nid, {"id": nid, "name": name, "films": 0})
                slot["films"] += 1
        cold_studio: dict = {}
        if fav_ids:
            with amane_db() as conn:
                for i in range(0, len(fav_ids), 400):
                    chunk = fav_ids[i:i + 400]
                    marks = ",".join("?" * len(chunk))
                    for row in conn.execute(
                            f"SELECT id, studio FROM metadata WHERE id IN ({marks}) "
                            "AND studio IS NOT NULL AND studio != ''", chunk):
                        mid = int(row["id"])
                        if mid in films:
                            continue
                        name = str(row["studio"])
                        slot = cold_studio.setdefault(name, {"name": name, "films": 0})
                        slot["films"] += 1

        metas = titles_of(idle[:50])
        items = []
        for mid in idle[:50]:
            m = metas.get(mid)
            if not m:
                continue
            items.append({"id": mid, "number": m["number"], "title": m["title"],
                          "fav_at": fav_at.get(mid, "")})

        data = {
            "items": items,
            "total": len(idle),
            "days": days,
            "cold_actors": sorted(cold_actor.values(),
                                  key=lambda v: (-v["films"], v["name"]))[:10],
            "cold_studios": sorted(cold_studio.values(),
                                   key=lambda v: (-v["films"], v["name"]))[:10],
        }
        self._json(stats_env(bool(fav_ids), "full" if fav_ids else "estimate", data,
                             "还没有收藏，先收几部"))

    @route("GET", r"/api/user/stats/funnel")
    def stats_funnel(self, query, *_) -> None:
        """收藏转化漏斗：收藏 → 打开 → 看完（只看窗口内新增的收藏）。"""
        ensure_stats()
        try:
            days = int((query.get("days") or ["90"])[0])
        except ValueError:
            days = 90
        days = max(1, min(days, 3650))
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
        with user_db() as conn:
            fav = conn.execute(
                "SELECT metadata_id FROM favorites WHERE created_at >= ?", (cutoff,)).fetchall()
            films = stats_films(conn, "", "", "real")
        mids = [int(r["metadata_id"]) for r in fav]
        opened = [m for m in mids
                  if m in films and films[m]["secs"] >= STATS_OPEN_SECS]
        finished = [m for m in opened if films[m]["ratio"] >= FINISH_RATIO]
        total = len(mids)
        data = {
            "favorited": total,
            "opened": len(opened),
            "finished": len(finished),
            "open_rate": round(len(opened) / total, 3) if total else 0.0,
            "finish_rate": round(len(finished) / len(opened), 3) if opened else 0.0,
            "overall": round(len(finished) / total, 3) if total else 0.0,
            "days": days,
            "cutoff": cutoff,
        }
        conf = "full" if total >= 10 else ("sparse" if total else "estimate")
        self._json(stats_env(total > 0, conf, data, "这段时间没有新增收藏"))

    @route("GET", r"/api/user/stats/conflict")
    def stats_conflict(self, query, *_) -> None:
        """评分冲突三件事：高分低完成 / 没打分却反复看 / 与上游评分的差异。"""
        ensure_stats()
        start, end = stats_range(query)
        scope = stats_scope(query)
        with user_db() as conn:
            films = stats_films(conn, start, end, scope)
            ratios = stats_day_ratios(conn, scope)
            try:
                rows = conn.execute("SELECT metadata_id, score FROM user_ratings").fetchall()
            except sqlite3.Error:
                rows = []          # ratings 扩展没开：当作一条都没打分
        mine = {int(r["metadata_id"]): int(r["score"]) for r in rows}
        opened = {mid: f for mid, f in films.items() if f["secs"] >= STATS_OPEN_SECS}

        high_low = []
        for mid, f in opened.items():
            score = mine.get(mid, 0)
            if score >= 4 and f["ratio"] < 0.3:
                high_low.append({"id": mid, "score": score,
                                 "ratio": round(f["ratio"], 3),
                                 "secs": round(f["secs"])})
        high_low.sort(key=lambda v: (v["ratio"], -v["score"]))

        repeats = []
        for mid in opened:
            if mine.get(mid, 0) > 0:
                continue
            n = stats_replays(ratios.get(mid, []))
            if n >= 2:
                repeats.append({"id": mid, "replays": n, "secs": round(opened[mid]["secs"])})
        repeats.sort(key=lambda v: (-v["replays"], -v["secs"]))

        # 与上游评分的差异：两边同为 5 分制，直接相减。
        # 上游 vote 来自 titles_of() → metadata.scores（如 {"giga": 3.0, "javdb": 4.2}），
        # 本就是 5 分制；我打的 1..5 星也是 5 分制。旧版误把我的星 ×2 当 10 分制去减，
        # 差值虚高一倍（例：我 5 星、上游 4.2 → 旧算出 +5.8，实际应 +0.8）。
        head = [mid for mid in mine if mid in films][:200]
        metas = titles_of(head)
        diffs = []
        for mid in head:
            up = metas.get(mid, {}).get("vote", 0.0)
            if up <= 0:
                continue
            diffs.append(mine[mid] - up)
        vs = {"count": len(diffs), "mean_diff": 0.0, "harsh": 0.0, "gap": 0.0}
        if diffs:
            vs["mean_diff"] = round(sum(diffs) / len(diffs), 2)
            vs["harsh"] = round(sum(1 for d in diffs if d < 0) / len(diffs), 3)
            # 5 分制下「差一颗星以上」算明显分歧（旧版 10 分制用的是 1.5 分）
            vs["gap"] = round(sum(1 for d in diffs if abs(d) > 1.0) / len(diffs), 3)

        # 补标题：`metas` 之前只为「打过分的片」取过，冲突榜里没打分的那些会拿到空标题
        wanted = [it["id"] for it in high_low[:8]] + [it["id"] for it in repeats[:8]]
        missing = [i for i in wanted if i not in metas]
        if missing:
            metas.update(titles_of(missing))

        for bucket in (high_low, repeats):
            for it in bucket:
                m = metas.get(it["id"], {})
                it["number"] = m.get("number", "")
                it["title"] = m.get("title", "")

        data = {"high_low": high_low[:8], "repeats": repeats[:8], "vs_upstream": vs,
                "opened": len(opened)}
        conf = "full" if len(opened) >= 10 else ("sparse" if opened else "estimate")
        self._json(stats_env(bool(opened), conf, data, "还没有足够的观看记录",
                             range_=(start, end), scope=scope))
