"""cover 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class CoverMixin(object):
    @route("GET", r"/api/user/res/([0-9a-fA-F]{6,64})")
    def resource_image(self, query, name, *_) -> None:
        """代理上游资源库的图（`/api/resources/<hash>`）。

        为什么必须代理：客户端 `Store.img()` 按前缀把 `/api/resources/` 分流到上游
        amane（内网 :8000）。用户在 4G / 域名访问时那台不可达，海报整片白屏 ——
        而 `/img?` 与 `/api/user/photo/` 都在旁挂服务上，外网可达。
        """
        if not self._authed(query):
            return self._error(401, "需要 token")
        target = f"{AMANE_BASE}/api/resources/{name}"
        try:
            req = Request(target, headers={"Authorization": f"Bearer {AMANE_TOKEN}"})
            with urlopen(req, timeout=20) as resp:
                data = resp.read()
                ctype = (resp.headers.get("Content-Type")
                         or mimetypes.guess_type(name)[0] or "image/jpeg")
        except HTTPError as exc:
            return self._error(404 if exc.code == 404 else 502, f"上游返回 {exc.code}")
        except (URLError, TimeoutError, OSError) as exc:
            return self._error(502, f"抓取失败: {exc}")
        if not data:
            return self._error(404, "资源为空")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        self.wfile.write(data)

    @route("GET", r"/api/user/photo/([0-9a-f]{8,64}\.(?:jpg|png|webp|gif))")
    @route("HEAD", r"/api/user/photo/([0-9a-f]{8,64}\.(?:jpg|png|webp|gif))")
    def photo(self, query: dict, name: str) -> None:
        """写真库上传的本地图片（自家文件，不走图片白名单）。"""
        path = os.path.join(PHOTO_DIR, name)
        if not os.path.isfile(path):
            return self._error(404, "图片不存在")
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError as exc:
            return self._error(500, str(exc))
        ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(blob)

    @route("POST", r"/api/user/cover/(\d+)")
    def cover_upload(self, query, metadata_id, *_) -> None:
        """上传自定义封面 / 动图：body `{data: base64 或 data URI, ext}`。

        复用核心的 `save_photo()`（落到 DATA_DIR/photos/<sha1>.<ext>，由
        `/api/user/photo/<name>` 提供访问），**不另建第二套上传**。
        """
        mid = int(metadata_id)
        body = self._body()
        raw = str(body.get("data") or "")
        if raw.startswith("data:"):
            comma = raw.find(",")
            raw = raw[comma + 1:] if comma > 0 else raw
        try:
            blob = base64.b64decode(raw, validate=False)
        except Exception:  # noqa: BLE001
            return self._error(400, "图片数据无法解析")
        if not blob:
            return self._error(400, "空图片")
        if len(blob) > 12 * 1024 * 1024:
            return self._error(413, "图片太大（上限 12MB）")

        ext = str(body.get("ext") or "").lower().lstrip(".")
        if ext == "jpeg":
            ext = "jpg"
        if ext not in ("jpg", "png", "webp", "gif"):
            if blob[:3] == b"\xff\xd8\xff":
                ext = "jpg"
            elif blob[:8] == b"\x89PNG\r\n\x1a\n":
                ext = "png"
            elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
                ext = "webp"
            elif blob[:3] == b"GIF":
                ext = "gif"
            else:
                return self._error(400, "只支持 jpg / png / webp / gif")

        name = f"{hashlib.sha1(blob).hexdigest()}.{ext}"
        try:
            save_photo(name, blob)
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR 封面保存失败: {exc}")
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{name}"
        wide_url = make_wide_of_photo(url)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            fields = _json_dict(row["fields"]) if row else {}
            conn.execute(
                "INSERT INTO meta_override(metadata_id, fields, cover, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                "cover = excluded.cover, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (mid, json.dumps(fields, ensure_ascii=False), url, wide_url, now_iso()))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "url": url, "wide": wide_url}})

    @route("DELETE", r"/api/user/cover/(\d+)")
    def cover_delete(self, query, metadata_id, *_) -> None:
        """只恢复原封面，不动字段覆盖。"""
        mid = int(metadata_id)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            if row is None:
                return self._json({"ok": True, "data": {"id": mid, "cover": ""}})
            fields = _json_dict(row["fields"])
            if fields:
                conn.execute(
                    "UPDATE meta_override SET cover = '', updated_at = ? WHERE metadata_id = ?",
                    (now_iso(), mid))
            else:
                conn.execute("DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "cover": ""}})

    @route("POST", r"/api/user/cover/(\d+)/gif")
    def cover_gif(self, query, metadata_id, *_) -> None:
        """用这部片自己的剧照生成循环 GIF 当封面（2.5.5.5）。

        body 可选：`{count: 6, duration: 420, width: 360}`
        —— `count` 用几张图、`duration` 每帧毫秒、`width` 封面宽（高 = 宽 × 1.5）。
        """
        mid = int(metadata_id)
        body = self._body()

        def pick(key: str, default: int, lo: int, hi: int) -> int:
            try:
                value = int(body.get(key) or default)
            except (TypeError, ValueError):
                value = default
            return max(lo, min(hi, value))

        want = pick("count", 6, 2, 8)
        duration = pick("duration", 700, 200, 2000)
        width = pick("width", 320, 200, 600)

        urls = cover_gif_sources(mid, want + 3)
        if not urls:
            return self._error(422, "这部片没有可用图片（剧照和封面都取不到）")
        blob, first = build_cover_gif(urls, width=width, duration=duration, max_frames=want)
        if not blob:
            if not _has_pillow():
                return self._error(503, "服务端缺少 Pillow，GIF 功能不可用")
            return self._error(422, "图片下载失败，稍后再试")

        name = f"{hashlib.sha1(blob).hexdigest()}.gif"
        try:
            save_photo(name, blob)
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{name}"
        # 横版衍生图：模糊背景 + 完整海报，给继续观看 / 每日推荐那些 16:9 位
        wide_url = ""
        wide_blob = build_wide_jpeg(first) if first is not None else b""
        if wide_blob:
            wname = f"{hashlib.sha1(wide_blob).hexdigest()}.jpg"
            try:
                save_photo(wname, wide_blob)
                wide_url = f"/api/user/photo/{wname}"
            except Exception:  # noqa: BLE001
                wide_url = ""
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields FROM meta_override WHERE metadata_id = ?", (mid,)).fetchone()
            fields = _json_dict(row["fields"]) if row else {}
            conn.execute(
                "INSERT INTO meta_override(metadata_id, fields, cover, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                "cover = excluded.cover, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (mid, json.dumps(fields, ensure_ascii=False), url, wide_url, now_iso()))
        invalidate_item_caches()
        log(f"cover gif mid={mid} frames={want} bytes={len(blob)} wide={bool(wide_url)}")
        self._json({"ok": True, "data": {"id": mid, "url": url, "wide": wide_url,
                                         "frames": want, "bytes": len(blob)}})

    @route("POST", r"/api/user/facet-gif/([a-z]+)/(.+)")
    def facet_cover_gif(self, query, kind, key, *_) -> None:
        """用分类里几部片的海报拼一段轮播 GIF，当这个分类的封面（2.5.5.7）。

        先做「类里所含海报的轮播」：每部片取 1 张，最多 8 张。
        以后要更强的动效（抽帧、转场、文字）再加参数，端点不用换。
        """
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        if not name:
            return self._error(400, "缺少分类名")
        body = self._body()

        def pick(k: str, default: int, lo: int, hi: int) -> int:
            try:
                value = int(body.get(k) or default)
            except (TypeError, ValueError):
                value = default
            return max(lo, min(hi, value))

        want = pick("count", 6, 2, 8)
        duration = pick("duration", 900, 200, 2000)
        width = pick("width", 320, 200, 600)

        urls = cover_gif_sources_for(kind, name, want + 4)
        if not urls:
            return self._error(422, "这个分类下没有可用海报")
        blob, first = build_cover_gif(urls, width=width, duration=duration, max_frames=want)
        if not blob:
            if not _has_pillow():
                return self._error(503, "服务端缺少 Pillow，GIF 功能不可用")
            return self._error(422, "海报下载失败，稍后再试")

        fname = f"{hashlib.sha1(blob).hexdigest()}.gif"
        try:
            save_photo(fname, blob)
        except Exception as exc:  # noqa: BLE001
            return self._error(500, f"保存失败: {exc}")
        url = f"/api/user/photo/{fname}"
        # 分类封面也配一张 16:9 横版：分类详情页头部是横条（84×46），
        # 直接塞竖版动图会被裁掉大半，用户看着就是「局部截图」。
        wide_url = ""
        wide_blob = build_wide_jpeg(first) if first is not None else b""
        if wide_blob:
            wname = f"{hashlib.sha1(wide_blob).hexdigest()}.jpg"
            try:
                save_photo(wname, wide_blob)
                wide_url = f"/api/user/photo/{wname}"
            except Exception:  # noqa: BLE001
                wide_url = ""
        with user_db() as conn:
            conn.execute(
                "INSERT INTO cover_override(kind, \"key\", url, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(kind, \"key\") DO UPDATE SET "
                "url = excluded.url, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (kind, name, url, wide_url, now_iso()))
        invalidate_item_caches()
        log(f"facet gif {kind}={name} frames={want} bytes={len(blob)} wide={bool(wide_url)}")
        self._json({"ok": True, "data": {"kind": kind, "key": name, "url": url,
                                         "wide": wide_url,
                                         "frames": want, "bytes": len(blob)}})

    @route("GET", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_get(self, query, kind, key, *_) -> None:
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        covers = cover_override_both(kind, [name])
        hit = covers.get(name) or {}
        self._json({"ok": True, "data": {"kind": kind, "key": name,
                                         "url": hit.get("url", ""),
                                         "wide": hit.get("wide", "")}})

    @route("POST", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_upload(self, query, kind, key, *_) -> None:
        """换分类封面（支持 gif 动图）。body `{data: base64 或 data URI, ext}`。"""
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        if not name:
            return self._error(400, "缺少分类名")
        url, err = _save_uploaded_image(self._body())
        if err:
            return self._error(413 if "太大" in err else 400, err)
        # 相册图也生成一张 16:9：分类详情页头部是横条，竖图塞进去会被裁掉大半
        wide_url = make_wide_of_photo(url)
        with user_db() as conn:
            conn.execute(
                "INSERT INTO cover_override(kind, \"key\", url, wide, updated_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(kind, \"key\") DO UPDATE SET "
                "url = excluded.url, wide = excluded.wide, "
                "updated_at = excluded.updated_at",
                (kind, name, url, wide_url, now_iso()))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"kind": kind, "key": name, "url": url,
                                         "wide": wide_url}})

    @route("DELETE", r"/api/user/cover-any/([a-z]+)/(.+)")
    def cover_any_delete(self, query, kind, key, *_) -> None:
        """恢复成默认封面（媒体库回到海报拼贴，分类回到拼贴/首字）。"""
        if kind not in COVER_KINDS:
            return self._error(400, "不支持的分类")
        name = unquote(key).strip()
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM cover_override WHERE kind = ? AND \"key\" = ?",
                (kind, name)).rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"kind": kind, "key": name, "removed": int(removed or 0)}})
