"""browse 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L
from core.filters import BadFilter, build_media_where

_L.export_to(globals())


class BrowseMixin(object):
    @route("GET", r"/api/user/browse")
    def browse(self, query, *_) -> None:
        def arg(name: str, default: str = "") -> str:
            return (query.get(name) or [default])[0].strip()

        try:
            limit = min(120, max(1, int(arg("limit", "40"))))
            offset = max(0, int(arg("offset", "0")))
        except ValueError:
            return self._error(400, "limit/offset 必须是整数")

        search = arg("q")
        # 检索归一化（2.5.1）：先繁转简，后面拆词 / 排序 / 匹配统一用归一化后的词。
        # 只影响查询侧：库里的数据一个字节都不改，关掉功能也不会留下脏数据。
        search_norm = norm_query(search)

        sort = arg("sort", "recent").lower()
        # 扩展可以提供核心 SORTS 里没有的排序键（数据落在 user.db 时跨库不能 JOIN，
        # 由扩展给出分档 CASE 表达式）。求值型钩子：不认识这个 sort 就返回 None。
        ext_sort = EXT.call_hook("browse_sort", sort)
        if sort not in SORTS and not ext_sort:
            sort = "recent"
            ext_sort = None
        column, default_dir = SORTS.get(sort, ("m.id", "desc"))
        want_dir = (ext_sort or {}).get("dir") or default_dir
        direction = arg("order", want_dir).lower()
        if direction not in ("asc", "desc"):
            direction = want_dir
        # 出演年龄看哪个性别：默认女优，male 显式切男优。排序与区间筛选共用这一个。
        age_gender = cast_age_gender_of(arg("cast_age_gender"))
        if sort == "random":
            order = "RANDOM()"
        elif ext_sort and ext_sort.get("expr"):
            order = f"{ext_sort['expr']} {direction.upper()}, m.id DESC"
        elif sort == "cast_age":
            # 升序比「该性别里最年轻的那位」，降序比「该性别里最年长的那位」。
            # 约 29% 影片没有可算岁数的演员：NULL 在 SQLite 的 ASC 里排最前，
            # 会把一堆「查不出年龄」的片顶到首页。先按 IS NULL 沉底，再按岁数排。
            key = CAST_AGE_SORT_SQL[age_gender][direction]
            order = f"({key} IS NULL), {key} {direction.upper()}, m.id DESC"
        else:
            # 次级键保证分页稳定（同分/同日期不会在翻页时重复或漏项）
            order = f"{column} {direction.upper()}, m.id DESC"

        # 有搜索词时相关性优先（2.4.6.21）：番号全等 / 去连字符全等 > 番号前缀 >
        # 标题包含 > 系列包含 > 演员等其它命中。用户选的排序退成次级键 ——
        # 否则搜「IPZZ-932」时最像的那部会被「最近更新」埋到第一页之外。
        rel_params: tuple = ()
        if search:
            # 排序用归一化后的词：繁体输入（癡女）也要让标题里写「痴女」的那部排前面，
            # 否则「命中靠 t2s、排序靠原文」会排出一堆不相关的。
            kw_esc = re.sub(r"([%_\\])", r"\\\1", search_norm)
            order = (
                "CASE WHEN UPPER(m.number) = UPPER(?) THEN 0 "
                "WHEN REPLACE(UPPER(m.number), '-', '') = REPLACE(UPPER(?), '-', '') THEN 0 "
                "WHEN UPPER(m.number) LIKE UPPER(?) ESCAPE '\\' THEN 1 "
                "WHEN m.title LIKE ? ESCAPE '\\' THEN 2 "
                "WHEN m.series LIKE ? ESCAPE '\\' THEN 3 "
                "ELSE 4 END ASC, " + order
            )
            rel_params = (
                search_norm, search_norm, kw_esc + "%",
                "%" + kw_esc + "%", "%" + kw_esc + "%"
            )

        # ★ 六十一改：筛选条件搬进 core/filters.py（抽卡墙要共用同一份，
        # 复制就是分叉）。这里只负责「拿到片段 → 拼 clause → 查库」。
        try:
            where, params, fctx = build_media_where(arg, query)
        except BadFilter as exc:
            return self._error(400, str(exc))
        # filters 不知道谁还要用这些（排序相关性 / 回显 / 覆盖层补齐），所以它把它们交回来。
        groups = fctx["groups"]
        tokens = fctx["tokens"]
        qmode = fctx["qmode"]

        clause = " AND ".join(where)
        with amane_db() as conn:
            # 相关性档位的占位符在 ORDER BY 里（SQL 尾部），所以只给取页的那条加；
            # count_meta 的 SQL 没有 ORDER BY，用它会把参数数量对不上。
            items = query_meta(conn, clause, params + rel_params, order, limit, offset)
            attach_marks(conn, items)
            total = count_meta(conn, clause, params)

        # 覆盖层命中的片（2.5.5.25）：SQL 查的是 amane 库的原始字段，
        # 用户把系列改成「11」之后，搜「11」在库里是搜不到那部片的。
        # 只在第一页补一次，按 id 去重，最多 20 部。
        if search and tokens and offset == 0:
            try:
                extra = [i for i in override_ids_matching(tokens)
                         if i not in {it["id"] for it in items}][:20]
            except Exception as exc:  # noqa: BLE001
                extra = []
                log(f"WARN 覆盖层搜索失败: {exc}")
            if extra:
                items.extend(fetch_by_ids(extra))
                total += len(extra)
        self._json({
            "items": attach_progress(items),
            "total": total,
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": direction,
            "cast_age_gender": age_gender,
            # 回显「这次按什么语义搜的」：客户端据此判断还要不要退到 or
            "qmode": "or" if (qmode == "or" and len(groups) > 1) else "and",
            # 归一化后的词（繁转简之后）。客户端拿它做「已放宽」提示的对比，
            # 也方便排查「我明明搜的是这个」。原词在请求里，不用再回。
            "q_norm": search_norm if search else "",
        })
        # 严格搜索（qmode=and）几乎没结果 → 记进「待办」。
        # 客户端放宽那次（qmode=or）结果会变多，记下来就是假账，所以只认 and。
        if search and qmode != "or":
            record_search_miss(search, search_norm, total)
