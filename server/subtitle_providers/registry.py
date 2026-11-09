"""在线字幕源注册表。

**故意为空。** Amane-Harmony 2.1.1 不提供在线字幕搜索：
主流服务需要每个用户自己的 API key，且免费配额很紧；共享 key 既会瞬间耗尽，
也违反服务条款。这里只保留扩展点，等有合规、稳定、无需共享凭据的来源再启用。

GET /api/user/subtitles/providers 返回的就是 available() 的结果。
"""
from __future__ import annotations

from .base import SubtitleProvider

PROVIDERS: list[SubtitleProvider] = []


def register(provider: SubtitleProvider) -> None:
    """供将来启用时调用；当前版本没有任何调用点。"""
    PROVIDERS.append(provider)


def available() -> list[dict]:
    return [
        {"id": p.id, "name": p.name, "needs_credentials": p.needs_credentials}
        for p in PROVIDERS if p.enabled()
    ]
