"""在线字幕源的抽象接口（预留，未启用）。

设计约束（将来真要实现时也必须遵守）：
  * 不内置任何共享 API key：凭据只能由使用者自己填，存本地、不回显；
  * 所有请求经服务端代理，客户端不接触第三方协议；
  * 结果永久缓存，避免消耗免费配额；
  * provider 失败要隔离，不能影响本地/导入/手动 URL 三种来源。
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SearchContext:
    """匹配字幕用的上下文，全部来自本地，不含任何凭据。"""
    title: str = ""
    number: str = ""
    filename: str = ""
    oshash: str = ""
    year: str = ""
    lang: str = "chi"


@dataclass
class SubtitleResult:
    provider: str
    result_id: str
    name: str
    lang: str = ""
    fmt: str = ""
    downloads: int = 0
    hash_match: bool = False
    extra: dict = field(default_factory=dict)


class SubtitleProvider:
    """所有在线字幕源必须实现这两个方法。"""
    id: str = ""
    name: str = ""
    needs_credentials: bool = True

    def enabled(self) -> bool:
        raise NotImplementedError

    def search(self, ctx: SearchContext) -> list[SubtitleResult]:
        raise NotImplementedError

    def fetch(self, result: SubtitleResult) -> tuple[bytes, str]:
        """返回 (字幕原始字节, 文件名)。"""
        raise NotImplementedError
