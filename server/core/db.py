"""数据库连接（从 server.py 拆出）。

两个连接函数长得不像，是因为它们的约束完全不同：

  * `user_db()` —— 可写。每次用完**关闭**（原来 with 只提交不关闭，久了会堆连接和 fd）。
  * `amane_db()` —— 只读，且要能扛上游的 WAL checkpoint/重建：
    amane 会定期 checkpoint 甚至重建 WAL，重建后旧的 -shm 映射立刻失效，
    表现为 sqlite3 报 "file is not a database"。所以每次新建连接、打不开重试一次、
    还不行退回 immutable（读不到未 checkpoint 的写，但不至于 500）。

注意 `amane_db()` 里注册了 `amane_rel` 标量函数（检索相关性打分）——
扩展也走这条连接，所以注册在连接层而不是各端点自己加。
"""
from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager

from core.config import AMANE_DB, USER_DB
from core.log import log
from core.text import rel_score

# --------------------------------------------------------------------------- #
# 以下两个函数由 `tools/` 的切分脚本从 server.py 原样搬出（2026-11-14），
# 函数体一字未改 —— 拆模块只搬位置，不顺手改逻辑。
# --------------------------------------------------------------------------- #

@contextmanager
def user_db():
    """每次用完关闭：原来 with 只提交不关闭，久了会堆积连接和 fd。"""
    conn = sqlite3.connect(USER_DB, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def amane_db():
    """只读打开 amane 主库。

    amane 会定期 checkpoint 甚至重建 WAL，重建后旧的 -shm 映射立刻失效，
    表现为 sqlite3 报 "file is not a database"。所以：
      1. 每次新建连接（用完就关，不持有陈旧映射）；
      2. 打不开先重试一次；
      3. 还不行退回 immutable（读不到未 checkpoint 的写，但不至于 500）。
    """
    conn = None
    for attempt in range(2):
        try:
            conn = sqlite3.connect(f"file:{AMANE_DB}?mode=ro", uri=True, timeout=10)
            conn.row_factory = sqlite3.Row
            conn.execute("SELECT 1 FROM metadata LIMIT 1").fetchone()
            break
        except sqlite3.DatabaseError as exc:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
            if attempt == 1:
                log(f"amane.db 只读打开失败，退回 immutable: {exc}")
            else:
                time.sleep(0.05)
    if conn is None:
        conn = sqlite3.connect(f"file:{AMANE_DB}?mode=ro&immutable=1", uri=True, timeout=10)
        conn.row_factory = sqlite3.Row
    # 关键词相关性打分（清单页搜索）：扩展也走这条连接，所以在这里统一注册。
    conn.create_function("amane_rel", 2, rel_score)
    try:
        yield conn
    finally:
        conn.close()
