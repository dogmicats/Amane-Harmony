"""cast 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class CastMixin(object):
    @route("POST", r"/api/user/cast/token")
    def cast_token_create(self, query, *_) -> None:
        body = self._body()
        try:
            hours = int(body.get("hours") or 12)
        except (TypeError, ValueError):
            hours = 12
        hours = max(1, min(72, hours))
        token = os.urandom(16).hex()
        now = datetime.now(timezone.utc)
        created = now.isoformat(timespec="seconds")
        expires = (now + timedelta(hours=hours)).isoformat(timespec="seconds")
        with user_db() as conn:
            # 顺手清掉过期的，别让表无限长
            conn.execute("DELETE FROM cast_token WHERE expires_at < ?", (created,))
            conn.execute(
                "INSERT INTO cast_token(token, created_at, expires_at) VALUES(?,?,?)",
                (token, created, expires))
        host = str(self.headers.get("Host") or "")
        self._json({"ok": True, "data": {"token": token, "created_at": created,
                                         "expires_at": expires, "ttl_hours": hours,
                                         "base": f"http://{host}" if host else ""}})

    @route("GET", r"/api/user/cast/token")
    def cast_token_list(self, query, *_) -> None:
        with user_db() as conn:
            rows = conn.execute(
                "SELECT token, created_at, expires_at FROM cast_token "
                "ORDER BY created_at DESC").fetchall()
        items = [{"token": str(r["token"]), "created_at": str(r["created_at"]),
                  "expires_at": str(r["expires_at"])} for r in rows]
        self._json({"ok": True, "data": {"items": items}})

    @route("DELETE", r"/api/user/cast/token/([0-9a-f]{32})")
    def cast_token_delete(self, query, token, *_) -> None:
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM cast_token WHERE token = ?", (token,)).rowcount
        _CAST_HIT.pop(token, None)
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})

    @route("POST", r"/api/user/cast/link")
    def cast_link(self, query, *_) -> None:
        """给电视/盒子准备好一整套只读地址（2.5.6）。

        body：`{mid, source?, key?, hours?}`。返回的每个 URL 都已经带好 `ct`，
        前端（还没做）只要把 `url` 丢给电视即可；字幕与封面也一并给好，
        免得电视那边再拿主 token。
        """
        body = self._body()
        try:
            mid = int(body.get("mid") or 0)
        except (TypeError, ValueError):
            mid = 0
        if mid <= 0:
            return self._error(422, "mid 必填")
        source = str(body.get("source") or "nas.local")[:32]
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", source):
            return self._error(422, "source 不合法")
        key = str(body.get("key") or "")
        if key and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", key):
            return self._error(422, "key 不合法")

        with amane_db() as conn:
            rows = conn.execute(
                f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (mid,)).fetchall()
        if not rows:
            return self._error(404, "条目不存在")
        item = item_of(rows[0])
        apply_overrides([item])

        # 复用一把还没过期的钥匙；没有就现发一把（默认 12 小时）
        token = ""
        now = datetime.now(timezone.utc)
        created = now.isoformat(timespec="seconds")
        with user_db() as conn:
            row = conn.execute(
                "SELECT token FROM cast_token WHERE expires_at > ? "
                "ORDER BY created_at DESC LIMIT 1", (created,)).fetchone()
            if row is not None:
                token = str(row["token"])
        if not token:
            try:
                hours = int(body.get("hours") or 12)
            except (TypeError, ValueError):
                hours = 12
            hours = max(1, min(72, hours))
            token = os.urandom(16).hex()
            expires = (now + timedelta(hours=hours)).isoformat(timespec="seconds")
            with user_db() as conn:
                conn.execute("DELETE FROM cast_token WHERE expires_at < ?", (created,))
                conn.execute(
                    "INSERT INTO cast_token(token, created_at, expires_at) VALUES(?,?,?)",
                    (token, created, expires))
        with user_db() as conn:
            row = conn.execute(
                "SELECT expires_at FROM cast_token WHERE token = ?", (token,)).fetchone()
        expires_at = str(row["expires_at"]) if row is not None else ""

        host = str(self.headers.get("Host") or "")
        base = f"http://{host}" if host else ""
        play = f"{base}/api/user/play/{source}/{mid}?ct={token}"
        if key:
            play += f"&key={quote(key)}"
        self._json({"ok": True, "data": {
            "mid": mid,
            "number": item.get("number") or "",
            "title": item.get("title") or "",
            "source": source,
            "key": key,
            "token": token,
            "expires_at": expires_at,
            "base": base,
            "url": play,
            "cover_url": f"{base}/api/user/cast/cover/{mid}?ct={token}",
            "subtitles_url": f"{base}/api/user/subtitles?item_id={mid}&ct={token}",
            "subtitle_url_tpl": f"{base}/api/user/subtitle/{{id}}?ct={token}",
            "hint": "把 url 交给电视即可；字幕从 subtitles_url 里取 id，按 subtitle_url_tpl 拼",
        }})

    @route("GET", r"/api/user/cast/cover/(\d+)")
    def cast_cover(self, query, metadata_id, *_) -> None:
        """电视用的封面：本服务代取，电视不需要任何 token 就能看到图。"""
        mid = int(metadata_id)
        with amane_db() as conn:
            rows = conn.execute(
                f"SELECT {META_COLUMNS} FROM metadata m WHERE m.id = ?", (mid,)).fetchall()
        if not rows:
            return self._error(404, "条目不存在")
        item = item_of(rows[0])
        apply_overrides([item])
        poster = str(item.get("poster") or "")
        if not poster:
            return self._error(404, "这部片没有封面")
        try:
            blob, ctype = cast_cover_bytes(poster)
        except Exception as exc:  # noqa: BLE001
            log(f"WARN 投屏封面取图失败 {mid} {poster}: {exc}")
            return self._error(502, f"取封面失败: {exc}")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        self.wfile.write(blob)
