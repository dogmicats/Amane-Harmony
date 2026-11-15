"""stream 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class StreamMixin(object):
    @route("GET", r"/api/user/stream-choice")
    def stream_choice_get(self, query: dict, *_) -> None:
        """该条目上次选的可播版本（2.6.1.14）。没有就回空 key，客户端按老逻辑走。"""
        try:
            mid = int((query.get("item_id") or ["0"])[0])
        except (TypeError, ValueError):
            mid = 0
        if not mid:
            return self._error(422, "item_id 必填")
        with user_db() as conn:
            row = conn.execute(
                "SELECT file_key, updated_at FROM stream_choice WHERE metadata_id = ?",
                (mid,)).fetchone()
        self._json({"item_id": mid,
                    "file_key": str(row["file_key"]) if row else "",
                    "updated_at": str(row["updated_at"]) if row else ""})

    @route("PUT", r"/api/user/stream-choice")
    def stream_choice_put(self, query: dict, *_) -> None:
        """记住「这部片默认播哪个文件」。file_key 传空表示清掉（回到让上游挑）。"""
        body = self._body()
        try:
            mid = int(body.get("item_id") or 0)
        except (TypeError, ValueError):
            mid = 0
        if not mid:
            return self._error(422, "item_id 必填")
        key = str(body.get("file_key") or "").strip()[:64]
        with user_db() as conn:
            if not key:
                conn.execute("DELETE FROM stream_choice WHERE metadata_id = ?", (mid,))
            else:
                conn.execute(
                    "INSERT INTO stream_choice(metadata_id, file_key, updated_at) "
                    "VALUES(?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                    "file_key = excluded.file_key, updated_at = excluded.updated_at",
                    (mid, key, now_iso()))
        self._json({"ok": True, "item_id": mid, "file_key": key})

    @route("GET", r"/api/user/trailer/(\d+)")
    @route("HEAD", r"/api/user/trailer/(\d+)")
    def trailer(self, query: dict, mid: str) -> None:
        head_only: bool = self.command == "HEAD"
        try:
            idx = int((query.get("i") or ["0"])[0] or 0)
        except ValueError:
            idx = 0
        urls = trailer_urls(int(mid))
        if not urls:
            return self._error(404, "这个条目没有预告片")
        if idx < 0 or idx >= len(urls):
            idx = 0
        url = urls[idx]
        if url.startswith("/api/resources/"):
            upstream = f"{AMANE_BASE}{url}"
            req_headers: dict[str, str] = {"Authorization": f"Bearer {AMANE_TOKEN}"}
        elif url.startswith("http://") or url.startswith("https://"):
            upstream = url
            req_headers = {}
        else:
            return self._error(404, "预告片地址不可用")
        for name in ("Range", "If-Range", "If-Modified-Since", "If-None-Match"):
            val = self.headers.get(name)
            if val:
                req_headers[name] = val

        session_key = f"trailer/{mid}/{idx}"
        session: dict = {"ev": threading.Event(), "idle": 0.0, "sent": 0}
        log(f"trailer {mid}#{idx} "
            f"{'local' if url.startswith('/api/resources/') else 'remote'} "
            f"range={self.headers.get('Range', '-')} "
            f"ua={(self.headers.get('User-Agent') or '')[:32]}")
        try:
            self.connection.settimeout(60)
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if not head_only:
            now = time.time()
            with self._stream_lock:
                alive: list = []
                for old in self._stream_sessions.get(session_key, []):
                    if old["idle"] > 0 and now - old["idle"] > self.PLAY_STALL_DROP:
                        old["ev"].set()
                    else:
                        alive.append(old)
                alive.append(session)
                self._stream_sessions[session_key] = alive

        started_at = time.time()
        reason = "eof"
        try:
            reason = self._play_passthrough(upstream, req_headers, head_only, session, session_key)
        except HTTPError as exc:
            # 上游 404/403（源站下架、外链过期）也要如实回给播放页，别让 mpv 卡在「缓冲中」
            try:
                body = exc.read()
                self.send_response(exc.code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            self.close_connection = True
            reason = f"http:{exc.code}"
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as exc:
            reason = type(exc).__name__
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            log(f"trailer {upstream} failed: {exc}\n{traceback.format_exc()}")
            self.close_connection = True
            reason = "error"
        finally:
            if not head_only:
                spent = max(time.time() - started_at, 1e-6)
                log(f"trailer {session_key} end {session['sent'] / 1048576:.2f}MB "
                    f"in {spent:.1f}s ({reason})")
            with self._stream_lock:
                left = [s for s in self._stream_sessions.get(session_key, []) if s is not session]
                if left:
                    self._stream_sessions[session_key] = left
                else:
                    self._stream_sessions.pop(session_key, None)
