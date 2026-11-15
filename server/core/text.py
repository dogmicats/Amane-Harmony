"""检索用文本工具：归一化 + 相关性分档（从 server.py 拆出）。

为什么单独一块：这组逻辑被「影片库 / 演员 / 标签·系列·导演 / 收藏」四处共用，
而且注册成了 SQLite 标量函数（`amane_rel`），数据库层也要 import 它。
放在 server.py 里会让 core/db.py 反过来依赖入口 —— 循环。

一、关键词相关性（2.4.6.21）
各清单除了「指定筛选」，还要能直接打关键词搜。只做 LIKE 有两个问题：
全角/大小写/连字符不同就搜不到；命中之后没有「像不像」的顺序 ——
搜「三上」时「三上悠亜」和「三上理子」谁在前全看作品数。所以这里给归一化 + 分档：

    0 完全相等      normalize 之后一模一样（SPSD-014 = spsd014）
    1 前缀          名字以关键词开头
    2 词首          多词名字里任一词以关键词开头（Yui Hatano ← hatano）
    3 包含          名字里带这段
    4 子序列        字符按序出现即可（大桥未久 ← 大桥久），只对短查询开放
    None 不命中

做成 SQLite 函数而不是在 Python 里过滤：过滤（IS NOT NULL）和排序（升序）都得在
SQL 里一次完成，否则「先取一页再排」会让分页算不准；这几张表都只有几千~几万行，
全表过一次 Python 回调在可接受范围内。
"""
from __future__ import annotations

import re
import unicodedata

_SEP_RE = re.compile(
    r"[\s\-_·・./\\|,，、;；:：()（）\[\]【】「」『』!！?？'\"“”‘’+~@#&*]+")


def _norm_kw(text) -> str:
    """全角转半角 + 小写 + 去掉分隔符：`ＳＰＳＤ_014` / `spsd-014` 都归一成 `spsd014`。"""
    if not text:
        return ""
    s = unicodedata.normalize("NFKC", str(text)).lower()
    return _SEP_RE.sub("", s)


def _subseq(needle: str, hay: str) -> bool:
    """needle 的字符按顺序全部出现在 hay 里（不要求连续）。"""
    if not needle:
        return False
    it = iter(hay)
    return all(ch in it for ch in needle)


def rel_score(text, kw) -> int | None:
    """相关性档位：越小越靠前，None = 不命中。给 SQLite 用的标量函数。"""
    name = _norm_kw(text)
    key = _norm_kw(kw)
    if not key or not name:
        return None
    if name == key:
        return 0
    if name.startswith(key):
        return 1
    # 词首：日/英混排的名字常用分隔符（Yui Hatano、つぼみ・蕾），任一词开头都算
    raw = unicodedata.normalize("NFKC", str(text)).lower()
    for word in _SEP_RE.split(raw):
        if word and _norm_kw(word).startswith(key):
            return 2
    if key in name:
        return 3
    # 兜底模糊只对短查询开放：长关键词做子序列几乎必然误命中一长串无关名字
    if 2 <= len(key) <= 6 and len(name) - len(key) <= 6 and _subseq(key, name):
        return 4
    return None
