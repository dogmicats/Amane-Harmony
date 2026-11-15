"""访问上游 amane 的唯一出口（从 server.py 拆出）。

统一的 base 地址、token、超时与错误包装都在这里。任何新代码请求上游都走这两个函数，
不要自己拼 urlopen —— 否则 token 与超时口径会各写一套。
"""
from __future__ import annotations

import json
from urllib.parse import quote, urlencode
from urllib.request import ProxyHandler, Request, build_opener

from core.config import AMANE_BASE, AMANE_TOKEN
from core.log import log

# 显式空 ProxyHandler：本机若有全局代理（Windows 上很常见），
# urlopen 会走系统代理去打 127.0.0.1 的上游 —— 结果就是「上游没响应」。
_opener = build_opener(ProxyHandler({}))

def amane_get(path: str, params: dict | None = None, timeout: int = 12) -> dict:
    """带 Bearer 向 amane 上游请求 JSON；供需要代理上游数据的扩展复用。"""
    from urllib.parse import urlencode
    url = AMANE_BASE + path
    if params:
        clean = {k: v for k, v in params.items() if v is not None and v != ""}
        url += "?" + urlencode(clean, doseq=True)
    req = Request(url, headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
    with _opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def amane_post(path: str, payload: dict | None = None, timeout: int = 12) -> dict:
    """带 Bearer 向上游提交 JSON（POST）；空响应体返回 {}。

    写上游只能走这条路：扩展没有凭据访问面，核心也不希望每个扩展自己读 token 文件。
    """
    body = json.dumps(payload or {}, ensure_ascii=False).encode("utf-8")
    req = Request(AMANE_BASE + path, data=body, method="POST", headers={
        "Authorization": f"Bearer {AMANE_TOKEN}",
        "Content-Type": "application/json",
    })
    with _opener.open(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw.strip() else {}
