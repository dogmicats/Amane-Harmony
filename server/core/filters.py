"""媒体筛选条件的**唯一实现**（2026-11-18 六十一改）。

## 为什么要有这个文件

「筛哪些影片」这件事，原来只写在 `api/browse.py` 的 `browse()` 方法里面。
抽卡墙（`/api/user/stills`）想「在筛选结果里抽」就只能复制一份 SQL 条件 ——
而复制就是分叉：下一版改了一边忘了另一边，症状是**列表筛对了、抽卡还是全库**，
用户看到的是「筛选和抽卡各干各的」。

所以把它抽成纯函数，browse 与 stills 都调这一个。

## 两条硬约束（改这个文件之前先读）

1. **片段只许用 `m`（metadata）别名，绝不许出现 `f`。**
   browse 的主查询是 `metadata m JOIN (SELECT DISTINCT metadata_id FROM media_files) f`，
   stills 的是 `metadata m WHERE … AND EXISTS (… media_files …)` —— 后者没有 `f`。
   原始实现里库筛选写的是 `f.metadata_id IN (…)`，搬到通用位置必须写成 `m.id IN (…)`；
   两者在 browse 里完全等价（`f` 的定义就是 `f.metadata_id = m.id`）。

2. **参数非法抛 `BadFilter`，不要自己发响应。**
   原实现直接 `return self._error(400, …)`，抽出来以后没法这么写 ——
   由调用方决定：browse 转 400 给用户，stills 钩子返回 None（退回「不支持这个 scope」）。

3. 顺序即参数顺序：`where` 列表的顺序必须与 `params` 元组的顺序严格对应。
   加条件时永远成对追加，别在中途 `where.insert()`。
"""
from __future__ import annotations

import re

import core.logic as _L

# browse.py 用的是同一招：把 core.logic 的全部名字（含 _ 开头）注入本模块，
# 这样 `norm_query` / `search_clauses` / `_DIM_FILTERS` / `EXT` 这些直接可用。
_L.export_to(globals())


class BadFilter(ValueError):
    """筛选参数非法（库 id / 时间不是整数之类）。"""


def build_media_where(arg, query: dict | None = None) -> tuple[list[str], tuple, dict]:
    """把一批筛选参数翻译成 `WHERE` 片段。

    `arg(name, default='') -> str` 是取参数的方式：browse 与 stills 的 query 都是
    `dict[str, list[str]]`，所以两边各传自己的小包装，本函数不关心来源。
    `query` 是**原始参数字典**，只给扩展的 `browse_where` 钩子用（它们自己按需取）。

    返回 `(where 片段列表, 参数元组, 上下文)`。上下文里是**只有调用方还要用**的东西：
      · `search` / `search_norm` / `tokens` —— browse 拿去做相关性排序与覆盖层补齐
      · `groups` —— browse 回显 qmode 用
      · `age_gender` —— browse 排序与回显用
    """
    qd: dict = query if isinstance(query, dict) else {}
    search = arg("q")
    # 检索归一化（2.5.1）：先繁转简，后面拆词 / 排序 / 匹配统一用归一化后的词。
    # 只影响查询侧：库里的数据一个字节都不改，关掉功能也不会留下脏数据。
    search_norm = norm_query(search)
    # q 与 qmode 是「词之间」的关系：and（默认，全部词都要命中）/ or（任一词命中即可）。
    # 客户端在结果过少时自己退到 or，服务端不替它决定（避免搜索结果忽多忽少）。
    qmode = arg("qmode", "and").lower()
    tokens = [x for x in re.split(r"[\s\-_/]+", search_norm) if x][:6]
    groups: list[tuple[str, tuple]] = []
    # 出演年龄看哪个性别：默认女优，male 显式切男优。排序与区间筛选共用这一个。
    age_gender = cast_age_gender_of(arg("cast_age_gender"))

    where: list[str] = []
    params: tuple = ()

    # 媒体库筛选：`library_id=3`（单选，老客户端）或 `libs=1,2`（多选，2026-11-15）。
    # 多选的语义是**同时出现在每个所选库里**（AND），不是「任一」——
    # 用户原话「筛选同时出现在哪些媒体库的内容」，所以每加一个库结果只会更少。
    lib_ids: list[int] = []
    libs_raw = arg("libs")
    if libs_raw:
        for part in libs_raw.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                lib_ids.append(int(part))
            except ValueError:
                raise BadFilter("libs 里的库 id 必须是整数")
    elif arg("library_id"):
        try:
            lib_ids.append(int(arg("library_id")))
        except ValueError:
            raise BadFilter("library_id 必须是整数")

    if lib_ids:
        for lid in lib_ids:
            where.append("m.id IN (SELECT metadata_id FROM media_files WHERE library_id = ?)")
            params = (*params, lid)

    # 按分类**名字**筛（2.5.5.16）：自建分类（覆盖层里新起的系列 / 标签）没有 id，
    # 只能按名字查。把「库里本来属于这个名字的」和「被改到这个名字下的」并成一条，
    # 这样自建分类和原分类走同一个 browse —— 关键词 / 评分 / 收藏 / 排序全部等价。
    facet_kind = arg("facet_kind").lower()
    facet_name = arg("facet_name")
    if facet_name and facet_kind in ("series", "tag", "studio", "actor"):
        over_ids = override_ids_for(facet_kind, facet_name)
        if facet_kind in ("series", "studio"):
            cond = "m.%s = ?" % facet_kind
            fparams: list = [facet_name]
        elif facet_kind == "actor":
            cond = "m.actors LIKE ?"
            fparams = [f"%{facet_name}%"]
        else:
            cond = ("m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                    "JOIN tags t ON t.id = mt.tag_id WHERE t.name = ?)")
            fparams = [facet_name]
        if over_ids:
            marks = ",".join("?" * len(over_ids))
            cond = f"({cond} OR m.id IN ({marks}))"
            fparams = fparams + over_ids
        where.append(cond)
        params = (*params, *fparams)

    if search:
        # 模糊搜索：按空格 / 连字符拆词，每个词都要命中（AND）。
        # number 额外去掉连字符再比一次，这样 "ipzz932" 能搜到 "IPZZ-932"，
        # "ipzz 932" 拆成两个词也照样命中。
        # 再叠一层 amane_rel：全角输入（ｉｐｚｚ－９３２）、大小写、少打一个连字符
        # 都能命中 —— LIKE 只认字面，归一化得交给这个标量函数。
        # 只对番号做：标题是长日文，逐行归一化+子序列会让搜索从 40ms 涨到 400ms，
        # 而中文标题本来就是全角，LIKE 已经能命中。
        #
        # 2.5.1 起每个词还有三条额外通路（都只改**查询侧**，不动库里的数据）：
        #   ① 繁体转简体（癡女 → 痴女）；
        #   ② 标签名子查询（原来只搜 number/title/actors/series，标签词根本搜不到）；
        #   ③ 拼音首字母 / 全拼（scg → 搜查官，ntr → 牛头人）。
        for tok in tokens:
            like = f"%{tok}%"
            # 番号相关的三条只在「这个词可能是番号」时才加。
            # 判据用归一化后的形状：NFKC 之后全是 ASCII 字母数字（`ｉｐｚｚ－９３２`
            # 归一成 `ipzz932` 也算）。纯中文词根本不可能出现在番号里，加上去纯亏：
            # 实测 browse?q=痴女 从 163ms 降到 65ms（P50，NAS 本地）。
            nkw = _norm_kw(tok)
            numish = bool(nkw) and all(ch.isascii() and ch.isalnum() for ch in nkw)
            num_conds: list[str] = []
            num_vals: list = []
            if numish:
                num_conds = [
                    "m.number LIKE ?",
                    "REPLACE(m.number, '-', '') LIKE ?",
                    "amane_rel(m.number, ?) IS NOT NULL",
                ]
                num_vals = [like, like, tok]
            conds = num_conds + [
                "m.title LIKE ?",
                "m.actors LIKE ?",
                "m.series LIKE ?",
            ]
            vals: list = num_vals + [like, like, like]
            if has_cjk(tok):
                # 标签名不会出现在 metadata 的任何一个文本列里，只能走关联表。
                # 只对含中文的词加：番号/英文字母词走标签匹配纯属浪费（那几万行
                # 关联表扫一遍要十几毫秒，而英文词基本不可能命中中文标签名）。
                conds.append(
                    "m.id IN (SELECT mt.metadata_id FROM metadata_tags mt "
                    "JOIN tags t ON t.id = mt.tag_id WHERE t.name LIKE ?)")
                vals.append(like)
            for cond, cond_params in search_clauses(tok):
                conds.append(cond)
                vals.extend(cond_params)
            groups.append(("(" + " OR ".join(conds) + ")", tuple(vals)))
        # 词与词之间默认 AND（保持原有语义）；qmode=or 时放宽成「命中任一词即可」，
        # 由客户端在「结果太少」时自己决定要不要退这一步 —— 服务端只提供能力。
        if qmode == "or" and len(groups) > 1:
            where.append("(" + " OR ".join(g[0] for g in groups) + ")")
            params = (*params, *[v for g in groups for v in g[1]])
        else:
            for cond, cond_params in groups:
                where.append(cond)
                params = (*params, *cond_params)

    # 马赛克：CRACKED / LEAKED / NONE（原版无标记）
    mosaic = arg("mosaic").upper()
    if mosaic:
        wanted = [v for v in mosaic.split(",") if v in ("CRACKED", "LEAKED", "NONE")]
        if wanted:
            parts: list[str] = []
            for value in wanted:
                if value == "NONE":
                    parts.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                 "AND x.mosaic IS NOT NULL AND x.mosaic != '')")
                else:
                    parts.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                                 "AND x.mosaic = ?)")
                    params = (*params, value)
            where.append("(" + " OR ".join(parts) + ")")

    ctype = arg("ctype").upper()
    if ctype:
        values = [v for v in ctype.split(",") if v]
        if values:
            marks = ",".join("?" * len(values))
            where.append(f"UPPER(m.content_type) IN ({marks})")
            params = (*params, *values)

    # 字幕：1 有（内嵌或外挂），0 无
    sub = arg("sub")
    if sub == "1":
        where.append("EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                     "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")
    elif sub == "0":
        where.append("NOT EXISTS (SELECT 1 FROM media_files x WHERE x.metadata_id = m.id "
                     "AND (x.has_subtitle_in_name = 1 OR x.has_external_subtitle = 1))")

    # 多版本（2.5.7.7）：1 = 只看有 2 个以上文件的，0 = 只看单文件的，留空 = 全部。
    # 口径与 versions_of() 同一句 SQL（media_files 行数），现算不缓存 ——
    # 文件管理里删掉一个版本 / 脚本新入库一个文件，下次刷新就变。
    multi = arg("multi")
    if multi == "1":
        where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) >= 2")
    elif multi == "0":
        where.append("(SELECT COUNT(*) FROM media_files x WHERE x.metadata_id = m.id) = 1")

    year_from = arg("year_from")
    year_to = arg("year_to")
    if year_from.isdigit():
        where.append("substr(m.release, 1, 4) >= ?")
        params = (*params, year_from)
    if year_to.isdigit():
        where.append("substr(m.release, 1, 4) <= ?")
        params = (*params, year_to)

    min_score = arg("min_score")
    if min_score:
        try:
            where.append("CAST(json_extract(m.scores, '$.javdb') AS REAL) >= ?")
            params = (*params, float(min_score))
        except ValueError:
            pass

    # 出演时岁数：上游没有这个字段，用 发行日 − 演员生日 在只读库里现算周岁。
    # 只看 age_gender 指定的那个性别（默认女优），任一位该性别演员落在区间即命中；
    # 没生日 / 性别 UNKNOWN 的演员天然不参与（扩展 actors 的 /item/{id}/cast
    # 用同一口径展示，口径见那里的 _age_of()）。
    age_min = arg("cast_age_min")
    age_max = arg("cast_age_max")
    if age_min.isdigit() or age_max.isdigit():
        # 下限与 _age_of() / cast_age_sql() 一致收到 18：低于 18 的岁数一律不参与。
        lo = int(age_min) if age_min.isdigit() else 18
        hi = int(age_max) if age_max.isdigit() else 90
        lo, hi = max(18, min(lo, 90)), max(18, min(hi, 90))
        if lo > hi:
            lo, hi = hi, lo
        where.append(
            "EXISTS (SELECT 1 FROM metadata_actors ca "
            "JOIN actors cab ON cab.id = ca.actor_id "
            "WHERE ca.metadata_id = m.id AND cab.gender = ? "
            "AND substr(cab.birthday, 1, 10) GLOB "
            "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
            "AND substr(m.release, 1, 10) GLOB "
            "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' "
            "AND (CAST(strftime('%Y', substr(m.release, 1, 10)) AS INTEGER) "
            "- CAST(strftime('%Y', substr(cab.birthday, 1, 10)) AS INTEGER) "
            "- (CASE WHEN strftime('%m-%d', substr(m.release, 1, 10)) "
            "< strftime('%m-%d', substr(cab.birthday, 1, 10)) THEN 1 ELSE 0 END)) "
            "BETWEEN ? AND ?)")
        params = (*params, _CAST_AGE_LABEL[age_gender], lo, hi)

    # 维度过滤（标签 / 导演 / 演员 / 系列 / 制片商 / 发行商），口径见 _DIM_FILTERS。
    for dim, dim_sql in _DIM_FILTERS.items():
        raw = arg(dim)
        if not raw:
            continue
        vals = [x.strip() for x in raw.split(",") if x.strip().isdigit()][:12]
        if not vals:
            continue
        if "{marks}" in dim_sql:
            where.append(dim_sql.format(marks=",".join("?" * len(vals)), n=len(vals)))
            params = (*params, *[int(x) for x in vals])
        else:
            # 标量维度（系列/制片商/发行商）只有一个名字位，多值只取第一个
            where.append(dim_sql)
            params = (*params, int(vals[0]))

    # 扩展可以追加筛选条件：核心不感知具体语义，只提供 where/params 拼接点。
    # 逐个钩子取结果再累加，不能用 EXT.call()——它按 dict 合并，多个扩展
    # 同时返回 clauses 时后一个会把前一个覆盖掉（收藏夹 + 评分并存时必踩）。
    # 钩子的入参是**原始 query**（它们自己按需取 state / myrating / collection…），
    # 所以这里不能只传 `arg`，得让调用方把 query 一起带进来。
    for fn in EXT.hooks.get("browse_where", []):
        try:
            out = fn(qd) or {}
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR 扩展 hook browse_where: {exc}")
            continue
        for extra in out.get("clauses", []):
            if isinstance(extra, (tuple, list)) and len(extra) == 2:
                where.append(str(extra[0]))
                params = (*params, *tuple(extra[1]))

    return where, params, {
        "search": search,
        "search_norm": search_norm,
        "tokens": tokens,
        "groups": groups,
        "age_gender": age_gender,
        "qmode": qmode,
    }


def stills_extra(scope: str, query: dict):
    """stills 扩展的「附加筛选」钩子：让抽卡和列表页用**同一套**条件。

    注册名是 `stills_extra`（不是 `stills_where`）—— 那个名字已经被 actors 扩展拿去
    回答「`scope=cast` 是什么」，`call_hook` 只取第一个非 None 的结果，两个语义挤在
    一个钩子里会互相遮蔽。

    只对 `library` / `all` 生效：其余内置 scope（tag / actor / series…）在各自页面上
    本来就没有这套筛选栏，客户端也不会传这些参数，没必要多跑一遍（还要开 user.db）。

    返回 None = 没有附加条件，stills 那边的 SQL 一个字符都不变。
    """
    if scope not in ("library", "all"):
        return None

    def arg(name: str, default: str = "") -> str:
        return (query.get(name) or [default])[0].strip()

    try:
        where, params, _ctx = build_media_where(arg, query)
    except BadFilter as exc:
        log(f"WARN stills 附加筛选参数非法: {exc}")
        return None
    if not where:
        return None
    return {"where": " AND ".join(where), "args": list(params)}


# ── 注册 ─────────────────────────────────────────────────────────────────
# 为什么写在这里而不是 `server.py` 的 main() 里（2026-11-18）：`server.py` 正被另一条线
# 改（升级器死循环那件事），少碰一个共用文件就少一次合并冲突 —— 今天上午刚被
# 「三个 agent 同时改同一批文件」教育过一遍。
#
# 放在模块底部注册是安全的：`EXT` 是模块级单例，`hook()` 只是往 dict 的 list 里 append，
# 与 `EXT.load()` 谁先谁后无关（`call_hook` 在请求到来时才遍历）。
# `browse.py` 在服务端启动时被 import（它要注册 `/api/user/browse` 路由），
# 所以这条注册一定发生在 bind 端口之前。
from core.ext import EXT as _EXT  # noqa: E402

_EXT.hook("stills_extra", stills_extra)
