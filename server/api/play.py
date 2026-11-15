"""play 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class PlayMixin(object):
    @route("GET", r"/api/user/streams/([^/]+)/(\d+)")
    def streams(self, query: dict, source: str, mid: str) -> None:
        """列出该条目在这个播放源上的所有流，并补上本地文件信息。

        一个元数据下挂多个版本（不同分辨率、正片/分段、网盘与本地各一份）是常态。
        amane 的流 key 形如 `f<media_file_id>`，用它回查 media_files 就能给出
        「文件名 / 分辨率 / 体积 / 时长 / 字幕 / 所在库」，客户端据此让用户选版本。
        `available` 是**浏览器口径**（WMV 之类会被标 false），但客户端用 mpv，
        所以不可用项照样返回、只排在后面，由用户自己决定。
        """
        source = source[:64]
        try:
            data = amane_get(f"/api/playback/{source}/{int(mid)}/streams")
        except Exception as exc:  # noqa: BLE001
            return self._error(502, f"上游播放源不可用: {exc}")
        items = [x for x in (data.get("items") or []) if isinstance(x, dict)]

        ids: list[int] = []
        for it in items:
            key = str(it.get("key") or "")
            if key[:1] == "f" and key[1:].isdigit():
                ids.append(int(key[1:]))
        info: dict[int, sqlite3.Row] = {}
        libs: dict[int, str] = {}
        if ids:
            ph = ",".join("?" * len(ids))
            with amane_db() as conn:
                for r in conn.execute(
                    "SELECT id, path, size, duration, definition, library_id, "
                    "has_subtitle_in_name, has_external_subtitle FROM media_files "
                    f"WHERE id IN ({ph})",
                    ids,
                ):
                    info[r["id"]] = r
                for r in conn.execute("SELECT id, name FROM libraries"):
                    libs[r["id"]] = r["name"] or ""

        out: list[dict] = []
        for it in items:
            key = str(it.get("key") or "")
            fid = int(key[1:]) if key[:1] == "f" and key[1:].isdigit() else 0
            row = info.get(fid)
            name = str(it.get("name") or "")
            # 上游 name 形如「本机文件 · XXX.mkv」，去掉前缀只留文件名
            base = name.split(" · ")[-1].split("/")[-1] or name
            try:
                size = int(row["size"] or 0) if row is not None else 0
            except (TypeError, ValueError):
                size = 0
            try:
                duration = round(float(row["duration"] or 0), 1) if row is not None else 0
            except (TypeError, ValueError):
                duration = 0
            out.append({
                "key": key,
                "file_id": fid,
                "name": base,
                "size": size,
                "duration": duration,
                "definition": (row["definition"] or "") if row is not None else "",
                "has_subtitle": bool(
                    row is not None and (row["has_subtitle_in_name"] or row["has_external_subtitle"])
                ),
                "library": libs.get(row["library_id"], "") if row is not None else "",
                "content_type": str(it.get("content_type") or ""),
                "available": bool(it.get("available")),
                "detail": str(it.get("detail") or ""),
            })
        out.sort(key=lambda x: (0 if x["available"] else 1, -x["size"]))
        self._json({"items": out, "source": source, "metadata_id": int(mid)})

    def _client_gone(self) -> bool:
        """非阻塞探测客户端是否已经断开（seek 后播放器会丢掉旧连接）。"""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if not readable:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except (OSError, ValueError):
            return True

    def _play_cache_get(self, ck: str):
        with self._play_lock:
            data = self._play_blocks.get(ck)
            if data is None:
                return None
            self._play_blocks.move_to_end(ck)
            return data

    def _play_cache_put(self, ck: str, data: bytes) -> None:
        if not data:
            return
        with self._play_lock:
            if ck in self._play_blocks:
                return
            self._play_blocks[ck] = data
            self._play_stat["bytes"] += len(data)
            while self._play_stat["bytes"] > self.PLAY_CACHE_BYTES and self._play_blocks:
                _, old = self._play_blocks.popitem(last=False)
                self._play_stat["bytes"] -= len(old)

    def _play_disk_get(self, upstream: str, blk: int):
        """先内存、再磁盘。磁盘命中同时塞回内存，后面几块连读就更快。"""
        data = PLAY_DISK.get(upstream, blk)
        if data is None:
            return None
        key = f"{upstream}#{blk}"
        self._play_cache_put(key, data)
        return data

    def _play_disk_put(self, upstream: str, blk: int, data: bytes) -> None:
        # 落盘在独立线程：1MiB 写到 NAS 盘上十几毫秒，别占着服务线程
        if not data or PLAY_DISK.budget <= 0:
            return
        try:
            threading.Thread(target=PLAY_DISK.put, args=(upstream, blk, data),
                             daemon=True, name="play-disk").start()
        except RuntimeError:
            pass

    def _play_job_for(self, upstream: str, ck: str, blk: int):
        """取（或启动）一块的下载任务；已缓存则立刻是完成状态。"""
        key = f"{ck}#{blk}"
        cached = self._play_cache_get(key)
        if cached is None:
            cached = self._play_disk_get(upstream, blk)
        if cached is not None:
            job = _PlayJob()
            job.data = bytearray(cached)
            job.done = True
            return key, job
        with self._play_lock:
            job = self._play_jobs.get(key)
            if job is not None:
                return key, job
            if len(self._play_jobs) >= self.PLAY_MAX_JOBS:
                return key, None
            job = _PlayJob()
            self._play_jobs[key] = job

        def run() -> None:
            headers = {"Authorization": f"Bearer {AMANE_TOKEN}",
                       "Range": f"bytes={blk * self.PLAY_BLOCK}-"
                                f"{blk * self.PLAY_BLOCK + self.PLAY_BLOCK - 1}"}
            try:
                with _opener.open(Request(upstream, headers=headers), timeout=120) as resp:
                    if resp.status not in (200, 206):
                        job.failed = True
                    elif resp.status == 200 and blk > 0:
                        # 上游没认 Range，回的是**整个文件**。把开头 1MB 当成第 blk 块，
                        # 缓存就被污染 → 一拖进度条 mpv 读到垃圾字节，会不停重开连接
                        # （「从头播没事，一拖就卡」就是这么来的）。宁可这块失败，也不写缓存。
                        job.failed = True
                        log(f"play block {blk} upstream ignored Range (200), not cached")
                    else:
                        read_once = getattr(resp, "read1", None) or resp.read
                        while len(job.data) < self.PLAY_BLOCK:
                            # 上游万一不认 Range（回 200 整文件），这里也必须停在块大小，
                            # 否则会把整个 8GB 读进内存
                            part = read_once(min(65536, self.PLAY_BLOCK - len(job.data)))
                            if not part:
                                break
                            with job.cv:
                                job.data += part
                                job.cv.notify_all()
            except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
                job.failed = True
                log(f"play block {blk} failed: {exc}")
            finally:
                with job.cv:
                    job.done = True
                    job.cv.notify_all()
                with self._play_lock:
                    self._play_jobs.pop(key, None)
                if job.data and not job.failed:
                    self._play_cache_put(key, bytes(job.data))
                    # 落盘：下一次（哪怕服务重启后）直接命中，不用再回源。
                    # 只存**完整**的块 —— 半块写进磁盘，下次读回来会比预期短，
                    # `_play_serve_blocks` 会当成文件尾直接收工（画面就断了）。
                    if len(job.data) >= self.PLAY_BLOCK:
                        self._play_disk_put(upstream, blk, bytes(job.data))

        try:
            threading.Thread(target=run, daemon=True, name="play-block").start()
        except RuntimeError:
            with self._play_lock:
                self._play_jobs.pop(key, None)
            return key, None
        return key, job

    def _play_fetch(self, upstream: str, start: int, size: int):
        """同步取一段（任务数到上限时的兜底）。"""
        if size <= 0:
            return None
        headers = {"Authorization": f"Bearer {AMANE_TOKEN}",
                   "Range": f"bytes={start}-{start + size - 1}"}
        try:
            with _opener.open(Request(upstream, headers=headers), timeout=120) as resp:
                if resp.status not in (200, 206):
                    return None
                if resp.status == 200 and start > 0:
                    log(f"play fetch {start}+{size}: upstream ignored Range (200)")
                    return None
                buf = bytearray()
                while len(buf) < size:
                    part = resp.read(min(65536, size - len(buf)))
                    if not part:
                        break
                    buf += part
                return bytes(buf) if buf else None
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
            log(f"play fetch {start}+{size} failed: {exc}")
            return None

    def _play_prefetch(self, upstream: str, ck: str, blocks: list) -> None:
        """并行预取后续块（每个块一个任务，任务表里有去重与总量上限）。"""
        for blk in blocks:
            self._play_job_for(upstream, ck, blk)

    def _meta_disk_path(self) -> str:
        return os.path.join(DATA_DIR, "play-meta.json")

    def _meta_disk_load(self) -> None:
        if self._meta_disk_ready["loaded"]:
            return
        with self._meta_disk_lock:
            if self._meta_disk_ready["loaded"]:
                return
            try:
                with open(self._meta_disk_path(), encoding="utf-8") as fh:
                    data = json.load(fh)
                now = time.time()
                # 文件大小不会变，给 7 天；过期只是多重探一次，不会出错
                for k, v in (data or {}).items():
                    if isinstance(v, dict) and now - float(v.get("at") or 0) < 7 * 86400:
                        self._play_meta[k] = v
                log(f"play meta loaded: {len(self._play_meta)} files")
            except (OSError, ValueError, TypeError):
                pass
            self._meta_disk_ready["loaded"] = True

    def _meta_disk_save(self) -> None:
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
            tmp = f"{self._meta_disk_path()}.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self._play_meta, fh)
            os.replace(tmp, self._meta_disk_path())
        except (OSError, ValueError, TypeError) as exc:
            log(f"play meta save failed: {exc}")

    def _play_meta_for(self, upstream: str, ck: str):
        """拿总长度 / 类型（内存 + 磁盘两层缓存，只探 1 个字节）。"""
        self._meta_disk_load()
        now = time.time()
        with self._play_lock:
            meta = self._play_meta.get(ck)
            if meta is not None and now - meta["at"] < 7 * 86400:
                return meta
        headers = {"Authorization": f"Bearer {AMANE_TOKEN}", "Range": "bytes=0-0"}
        try:
            with _opener.open(Request(upstream, headers=headers), timeout=60) as resp:
                total = 0
                cr = resp.headers.get("Content-Range") or ""
                m = re.search(r"/(\d+)\s*$", cr)
                if m:
                    total = int(m.group(1))
                elif resp.status == 200:
                    total = int(resp.headers.get("Content-Length") or 0)
                if total <= 0:
                    return None
                meta = {
                    "total": total,
                    "ctype": resp.headers.get("Content-Type") or "video/mp4",
                    "etag": resp.headers.get("ETag") or "",
                    "lm": resp.headers.get("Last-Modified") or "",
                    "cc": resp.headers.get("Cache-Control") or "",
                    "at": time.time(),
                }
        except (HTTPError, URLError, TimeoutError, OSError, ValueError):
            return None
        with self._play_lock:
            self._play_meta[ck] = meta
        # 落盘不挡这次请求
        try:
            threading.Thread(target=self._meta_disk_save, daemon=True,
                             name="play-meta").start()
        except RuntimeError:
            pass
        return meta

    def _play_wait_writable(self, session: dict, session_key: str) -> bool:
        """等 socket 可写；返回 False = 客户端已经走了。"""
        while True:
            try:
                _, ready, _ = select.select([], [self.connection], [], 2.0)
            except (OSError, ValueError):
                ready = []
            if ready:
                if session["idle"] > 0:
                    session["idle"] = 0.0
                return True
            if session["idle"] <= 0:
                session["idle"] = time.time()
            if self._client_gone():
                log(f"play {session_key} client gone, abort upstream")
                return False

    def _play_write(self, session: dict, session_key: str, data: bytes) -> str:
        """写一块给客户端；返回结束原因，空串表示继续。"""
        if not self._play_wait_writable(session, session_key):
            return "client-gone"
        try:
            self.wfile.write(data)
        except Exception as exc:  # noqa: BLE001
            log(f"play {session_key} client write failed after "
                f"{session['sent'] / 1048576:.2f}MB: {exc}")
            return f"client:{type(exc).__name__}"
        session["sent"] += len(data)
        return ""

    def _play_serve_blocks(self, upstream: str, ck: str, start: int, limit: int,
                           session: dict, session_key: str, total: int) -> str:
        """按块服务 [start, limit)：块内数据边下边发，不等整块。"""
        pos = start
        counter = 0
        while pos < limit:
            if session["ev"].is_set():
                return "stalled"
            blk = pos // self.PLAY_BLOCK
            off = pos - blk * self.PLAY_BLOCK
            need = min(self.PLAY_BLOCK - off, limit - pos)
            # 磁盘已缓存 → 直接按需读文件写 socket（省掉整块 memcpy 与任务表开销）
            dpath = PLAY_DISK._path(upstream, blk)
            if PLAY_DISK.budget > 0 and os.path.isfile(dpath):
                try:
                    with open(dpath, "rb") as fh:
                        fh.seek(off)
                        left = need
                        while left > 0:
                            # 1MiB 一片：每片一次 select + 一次 write，小片段会把
                            # 每条请求的开销摊到 CPU 上（这类文件 20 条请求/秒）
                            chunk = fh.read(min(1048576, left))
                            if not chunk:
                                break
                            reason = self._play_write(session, session_key, chunk)
                            if reason:
                                return reason
                            left -= len(chunk)
                        if left == 0:
                            pos += need
                            counter += need
                            continue
                except OSError as exc:
                    log(f"play disk read {dpath}: {exc}")
                # 读失败/不足 → 落回下面按任务取

            key, job = self._play_job_for(upstream, ck, blk)
            if job is None:
                # 并发任务到上限：同步取一块兜底，保证还能播
                blob = self._play_fetch(upstream, blk * self.PLAY_BLOCK, self.PLAY_BLOCK)
                if not blob:
                    return "fetch-failed"
                self._play_cache_put(key, blob)
                self._play_disk_put(upstream, blk, blob)
                piece = blob[off:off + need]
                reason = self._play_write(session, session_key, piece)
                if reason:
                    return reason
                pos += len(piece)
                counter += len(piece)
                continue

            got = 0
            while got < need:
                with job.cv:
                    while len(job.data) <= off + got and not job.done:
                        job.cv.wait(0.4)
                    avail = min(len(job.data) - (off + got), need - got)
                    piece = bytes(job.data[off + got:off + got + avail]) if avail > 0 else b""
                if not piece:
                    break
                reason = self._play_write(session, session_key, piece)
                if reason:
                    return reason
                got += len(piece)
                counter += len(piece)
                if counter >= 1048576:
                    counter = 0
                    if self._client_gone():
                        log(f"play {session_key} client gone, abort upstream")
                        return "client-gone"
            if got < need:
                # 这块比预期短（文件尾或上游错误），收工
                return "eof" if job.done and not job.failed else "block-short"
            pos += need
            # 播放点前面始终备着几块，CD2 的冷启动延迟被并行摊掉
            last = (total - 1) // self.PLAY_BLOCK
            if blk == last and job.data and not job.failed:
                # 最后一块通常不足 1MiB（文件尾），`run()` 那边按「完整块」判断会跳过它，
                # 但 MP4 的 moov 恰恰躺在这一块里 —— 显式存一次，下次打开就秒开
                self._play_disk_put(upstream, blk, bytes(job.data))
            # 只有「接着上一块」才算顺序读，才值得预读。跳着读（解复用器来回找音轨/视频轨）
            # 时预读全是废料，还会把任务池占满，把用户真正要的块挤到后面。
            prev_blk = self._play_seq.get(session_key, -2)
            self._play_seq[session_key] = blk
            if prev_blk == -2:
                # 每条 session 的**第一次**请求：把落点往后 8 块 + 文件头 4 块一次性拉下来
                # （头块里通常是索引，解复用器每次开流都要读）。只做一次，不按请求重复做。
                warm: list = list(range(blk, min(blk + 8, last + 1)))
                warm += [b for b in range(0, min(4, last + 1))]
                # 2.6.1.84：**尾部两块也要并行拉**。
                # MP4 的 moov 常常在文件尾，解复用器开局必须读它；而原来的 warm 只覆盖
                # 「播放点往后 8 块 + 头 4 块」，尾块要等它亲自来要才现取 —— 网盘源这一块
                # 实测 8~27 秒（2026-11-14 00:0x，SDEN-001 27.1s / JUX-888 22.2s），
                # 首帧就被这一下卡死。提前并行拉，这段等待就和头块重叠掉了。
                warm += [b for b in range(max(0, last - 1), last + 1)]
                self._play_prefetch(upstream, ck, warm)
            # 同一片区域内的连续读（含「还停在同一块」和「刚进下一块」）都算顺序，
            # 这时预读才有用；跨区域跳（音轨↔视频轨）不预读，免得占满任务池。
            if prev_blk == -2 or (blk - prev_blk) in (0, 1):
                self._play_prefetch(upstream, ck,
                                    [b for b in range(blk + 1, min(blk + 1 + self.PLAY_READAHEAD,
                                                                   last + 1))])
        return "done"

    def _play_passthrough(self, upstream: str, req_headers: dict, head_only: bool,
                          session: dict, session_key: str) -> str:
        """兜底：拿不到元信息（或 HEAD）时按原样透传。"""
        resp = _opener.open(Request(upstream, headers=req_headers), timeout=180)
        try:
            self.send_response(resp.status)
            for name in self.PLAY_HOP_HEADERS:
                val = resp.headers.get(name)
                if val:
                    self.send_header(name, val)
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if head_only or resp.status not in (200, 206):
                return "head" if head_only else f"status:{resp.status}"
            read_once = getattr(resp, "read1", None) or resp.read
            counter = 0
            while True:
                if session["ev"].is_set():
                    return "stalled"
                try:
                    chunk = read_once(65536)
                except Exception as exc:  # noqa: BLE001
                    return f"upstream:{type(exc).__name__}"
                if not chunk:
                    return "upstream-eof"
                reason = self._play_write(session, session_key, chunk)
                if reason:
                    return reason
                counter += len(chunk)
                if counter >= 1048576:
                    counter = 0
                    if self._client_gone():
                        log(f"play {session_key} client gone, abort upstream")
                        return "client-gone"
        finally:
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass

    def _local_path_for(self, key: str) -> str:
        """把 `?key=f<文件id>` 翻译成容器里能直接打开的文件路径。

        上游 amane 的库里就存着绝对路径（`media_files.path`），而我们本来就能只读它的 SQLite，
        容器又挂着 `/media`、`/media2`。所以本地片不必再绕一圈上游 HTTP：
        直接开文件、seek、发字节 —— 少一整跳，也没有 token 参与。
        """
        if not key.startswith("f"):
            return ""
        try:
            fid = int(key[1:])
        except ValueError:
            return ""
        try:
            with amane_db() as conn:
                row = conn.execute(
                    "SELECT path FROM media_files WHERE id = ?", (fid,)).fetchone()
        except Exception as exc:  # noqa: BLE001
            log(f"WARN play 查文件路径失败 {fid}: {exc}")
            return ""
        path = str((row["path"] if row else "") or "")
        if not path or not os.path.isfile(path):
            return ""
        return path

    def _play_pumped(self, path: str, head_only: bool) -> str:
        """顺序读泵版：Range 请求只从缓冲取，底层只有一个顺序读盘线程。"""
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        with _PUMP_LOCK:
            pumps = [x for x in _PLAY_PUMPS.get(path, []) if not x.dead]
            pump = None
            best = None
            for cand in pumps:
                with cand.lock:
                    head = cand.head
                dist = abs(head - (start // self.PLAY_BLOCK))
                if dist <= 256 and (best is None or dist < best):
                    best = dist
                    pump = cand
            if pump is None:
                # 没有热区靠近：能复用最远的那个就复用（改道），否则新建，最多 3 个
                if len(pumps) >= 3:
                    pump = pumps[0]
                else:
                    pump = PlayPump(path, self.PLAY_BLOCK)
                    pumps.append(pump)
                _PLAY_PUMPS[path] = pumps

        pos = start
        sent = 0
        try:
            while pos <= end:
                blk = pos // self.PLAY_BLOCK
                off = pos - blk * self.PLAY_BLOCK
                want = min(self.PLAY_BLOCK - off, end - pos + 1)
                blob = pump.get(blk)
                if blob is None:
                    return "pump-miss"
                piece = bytes(blob[off:off + want])
                if piece:
                    self.wfile.write(piece)
                    sent += len(piece)
                pos += want
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    def _play_local_sendfile(self, path: str, head_only: bool) -> str:
        """用 os.sendfile 零拷贝直发本地文件。

        播放器这类「每秒几十条 Range」的访问模式，真正的成本是**每条请求的用户态拷贝**：
        读进 bytes 再 write 出去，几十次/秒就把 CPU 和延迟吃满了。
        Emby 那类软件 Direct Play 之所以顺，靠的就是内核 sendfile + 页缓存：
        协议解析在用户态，数据搬运全在内核，单条请求通常 1–3ms。
        """
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return "range-416"
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        try:
            out_fd = self.connection.fileno()
        except (OSError, ValueError):
            return "no-fd"
        sent = 0
        try:
            with open(path, "rb") as fh:
                in_fd = fh.fileno()
                # 让内核提前把接下来这一段读进页缓存（Emby 之类顺滑，靠的就是页缓存命中）。
                # 只影响缓存预读，不占额外磁盘。
                try:
                    os.posix_fadvise(in_fd, start, 32 * 1024 * 1024,
                                     os.POSIX_FADV_WILLNEED)
                except (AttributeError, OSError):
                    pass
                offset = start
                left = end - start + 1
                while left > 0:
                    n = min(left, 4 * 1024 * 1024)
                    try:
                        moved = os.sendfile(out_fd, in_fd, offset, n)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if moved == 0:
                        break
                    offset += moved
                    sent += moved
                    left -= moved
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    def _play_local_file(self, path: str, head_only: bool) -> str:
        """直接读本地文件，**并复用块缓存**（块落在容器本地盘，随机跳读才不会每次都打到 NAS）。"""
        try:
            size = os.path.getsize(path)
        except OSError as exc:
            return f"stat-failed:{exc}"
        start = 0
        end = size - 1
        status = 200
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            status = 206
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return "range-416"
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return "head"

        ck = f"local:{path}"
        pos = start
        sent = 0
        try:
            with open(path, "rb") as src:
                while pos <= end:
                    blk = pos // self.PLAY_BLOCK
                    off = pos - blk * self.PLAY_BLOCK
                    want = min(self.PLAY_BLOCK - off, end - pos + 1)
                    mkey = f"{ck}#{blk}"
                    blob = self._play_cache_get(mkey)
                    if blob is None:
                        dpath = PLAY_DISK_LOCAL._path(ck, blk)
                        if os.path.isfile(dpath):
                            try:
                                with open(dpath, "rb") as fh:
                                    blob = fh.read()
                            except OSError:
                                blob = None
                        if blob is None:
                            # 一次读 8 个块（32MiB）：网络盘上随机读的代价主要在「每次 seek 的
                            # 往返」，一次多读一点能把后面十几次跳读都变成命中。
                            src.seek(blk * self.PLAY_BLOCK)
                            bulk = src.read(self.PLAY_BLOCK * 8)
                            if not bulk:
                                break
                            for i in range(0, (len(bulk) + self.PLAY_BLOCK - 1) // self.PLAY_BLOCK):
                                part = bulk[i * self.PLAY_BLOCK:(i + 1) * self.PLAY_BLOCK]
                                if not part:
                                    break
                                dp = PLAY_DISK_LOCAL._path(ck, blk + i)
                                try:
                                    os.makedirs(os.path.dirname(dp), exist_ok=True)
                                    tmpf = dp + ".tmp"
                                    with open(tmpf, "wb") as fh:
                                        fh.write(part)
                                    os.replace(tmpf, dp)
                                    # 手写落盘绕过了 put()，这里补记用量，否则本地缓存不会触发 trim
                                    PLAY_DISK_LOCAL.note(len(part))
                                except OSError:
                                    pass
                            blob = bulk[:self.PLAY_BLOCK]
                            if not blob:
                                break
                            try:
                                os.makedirs(os.path.dirname(dpath), exist_ok=True)
                                tmp = dpath + ".tmp"
                                with open(tmp, "wb") as fh:
                                    fh.write(blob)
                                os.replace(tmp, dpath)
                                PLAY_DISK_LOCAL.note(len(blob))
                            except OSError:
                                pass
                        self._play_cache_put(mkey, blob)
                    piece = bytes(blob[off:off + want])
                    if piece:
                        self.wfile.write(piece)
                        sent += len(piece)
                    pos += want
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            return f"client:{type(exc).__name__}"
        return f"done {sent / 1048576:.2f}MB"

    @route("GET", r"/api/user/play/([^/]+)/(\d+)")
    @route("HEAD", r"/api/user/play/([^/]+)/(\d+)")
    def play(self, query: dict, source: str, mid: str) -> None:
        head_only: bool = self.command == "HEAD"
        # ?key=f<文件id> 指定版本；不带 key 时仍交给上游自己挑一条
        key = (query.get("key") or [""])[0]
        suffix = ""
        if re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", key):
            suffix = f"/streams/{key}"
        # 本地片：库里就有绝对路径，直接读文件，比再走一圈上游 HTTP 快得多
        # 默认本地直发（sendfile 零拷贝，单请求 9–15ms）；?local=0 强制回上游代理做 A/B。
        local_mode = (query.get("local") or ["1"])[0]
        if source == "nas.local" and key and local_mode != "0":
            local_p = self._local_path_for(key)
            if local_p:
                return self._play_local_sendfile(local_p, self.command == "HEAD")

        want_pump = (query.get("pump") or ["0"])[0] == "1"
        if source == "nas.local" and key and want_pump:
            local_p = self._local_path_for(key)
            if local_p:
                return self._play_pumped(local_p, self.command == "HEAD")

        # 本地直读目前**默认关闭**：本机压测里它反而更慢（0.82–0.84x vs 走上游 0.98x），
        # 说明这条路径的块缓存命中还有问题，先留开关（AMANE_PLAY_LOCAL=1 可开）待排查。
        if source == "nas.local" and key and USE_LOCAL_PLAY:
            local = self._local_path_for(key)
            if local:
                started_local = time.time()
                reason_local = "?"
                try:
                    self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except OSError:
                    pass
                reason_local = self._play_local_file(local, self.command == "HEAD")
                spent_local = max(time.time() - started_local, 1e-6)
                log(f"play local {os.path.basename(local)} range={self.headers.get('Range', '-')} "
                    f"-> {reason_local} in {spent_local:.2f}s")
                return

        upstream: str = f"{AMANE_BASE}/api/playback/{source}/{mid}{suffix}"
        req_headers: dict[str, str] = {"Authorization": f"Bearer {AMANE_TOKEN}"}
        for name in ("Range", "If-Range", "If-Modified-Since", "If-None-Match"):
            val = self.headers.get(name)
            if val:
                req_headers[name] = val

        client_ip = (self.client_address[0] if self.client_address else "?")
        log(f"play {source}/{mid}{suffix} from={client_ip} "
            f"range={self.headers.get('Range', '-')} ua={(self.headers.get('User-Agent') or '')[:40]}")
        # 写超时给宽一点：正常播放时 mpv 缓存满了会短时间不读，几十秒不读是正常的，
        # 这时**不能**判死（否则播放器看到 EOF 就重连，缓存永远建不满）。
        try:
            self.connection.settimeout(60)
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

        session_key = f"{source}/{mid}{suffix}"
        session: dict = {"ev": threading.Event(), "idle": 0.0, "sent": 0}
        if not head_only:
            now = time.time()
            with self._stream_lock:
                alive: list = []
                for old in self._stream_sessions.get(session_key, []):
                    # 只掐「很久没读写」的旧流：那是客户端真的走了的僵尸。
                    # 正常在跑的连接（比如 mp4 读尾部索引那一路）一律留着。
                    if old["idle"] > 0 and now - old["idle"] > self.PLAY_STALL_DROP:
                        old["ev"].set()
                        log(f"play {session_key} drop stalled stream "
                            f"(idle {now - old['idle']:.1f}s)")
                    else:
                        alive.append(old)
                alive.append(session)
                self._stream_sessions[session_key] = alive

        started_at = time.time()
        reason = "eof"
        try:
            meta = None if head_only else self._play_meta_for(upstream, upstream)
            if meta is None:
                reason = self._play_passthrough(upstream, req_headers, head_only,
                                                session, session_key)
                return

            total: int = meta["total"]
            start = 0
            end = total - 1
            status = 200
            m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
            if m:
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), total - 1)
                status = 206
                if start >= total or end < start:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{total}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            limit = end + 1
            self.send_response(status)
            self.send_header("Content-Type", meta["ctype"])
            self.send_header("Content-Length", str(limit - start))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Accept-Ranges", "bytes")
            for field, header in (("etag", "ETag"), ("lm", "Last-Modified"), ("cc", "Cache-Control")):
                if meta[field]:
                    self.send_header(header, meta[field])
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if head_only:
                reason = "head"
                return

            # 起播先把「头」和「尾」两块拉下来（后台线程，不挡这一帧）：
            # MP4 的 moov 大多在文件末尾，每开一次都要读它；不预热的话每次进片
            # 都得等 CD2 冷启动，用户看到的就是「每次进去都重新缓存一会儿」。
            # 预热策略分两种（2026-11-12 实测：拖到中间后 mpv 缓存长期 0.0–0.2s，
            # 每 4 秒播完就重缓冲，说明「跳到的那一点之后」没有提前拉）：
            #   · 从头起播 → 预热头块 + 尾块（MP4 的 moov 常在尾部）
            #   · 拖到中间 → 从落点开始连拉 8 块，让 mpv 一起来就有十几秒余量
            if start < self.PLAY_BLOCK * 2 and len(self._play_jobs) < self.PLAY_MAX_JOBS // 2:
                last_blk = (total - 1) // self.PLAY_BLOCK
                warm: list = [0]
                if last_blk > 0:
                    warm.append(last_blk)
                if last_blk > 1:
                    warm.append(last_blk - 1)
                try:
                    self._play_prefetch(upstream, upstream, warm)
                except (RuntimeError, OSError, ValueError):
                    pass

            reason = self._play_serve_blocks(upstream, upstream, start, limit,
                                             session, session_key, total)
        except HTTPError as exc:
            # 上游 4xx/5xx：把状态码和响应体透传，别让客户端误以为流已建立
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
            log(f"play {upstream} failed: {exc}\n{traceback.format_exc()}")
            self.close_connection = True
            reason = "error"
        finally:
            if not head_only:
                spent = max(time.time() - started_at, 1e-6)
                log(f"play {session_key} end {session['sent'] / 1048576:.2f}MB "
                    f"in {spent:.1f}s = {session['sent'] / 1048576 / spent:.2f}MB/s "
                    f"({reason})")
            with self._stream_lock:
                left = [s for s in self._stream_sessions.get(session_key, []) if s is not session]
                if left:
                    self._stream_sessions[session_key] = left
                else:
                    self._stream_sessions.pop(session_key, None)

    @route("GET", r"/api/user/playcache")
    def playcache_stats(self, query, *_) -> None:
        """两份缓存分开报（用户 2026-11-15 01:31：本地片只配很小的固定额度，网盘片才由用户分配）。

        `used_mb / budget_mb` 保持**网盘那份**的含义不变（老客户端读这两个字段，
        显示的是"你给网盘片分配了多少"），另外给 `local_*` 两个字段。
        """
        out = PLAY_DISK.stats()
        loc = PLAY_DISK_LOCAL.stats()
        out["remote_used_mb"] = out.get("used_mb", 0)
        out["remote_budget_mb"] = out.get("budget_mb", 0)
        out["local_used_mb"] = loc.get("used_mb", 0)
        out["local_budget_mb"] = loc.get("budget_mb", 0)
        self._json(out)

    @route("POST", r"/api/user/playcache/settings")
    def playcache_settings(self, query, *_) -> None:
        """body `{remote_mb: 0|512|1024|2048|4096|8192}` —— 只调**网盘片**那份的额度。

        本地片那份是固定的小额度（`AMANE_PLAY_LOCAL_MB`，默认 128MB），不开放给用户：
        它就在 NAS 本地盘上，缓存收益很小，给多少都不影响体验，留着只会白占盘。
        """
        body = self._body() or {}
        try:
            mb = int(body.get("remote_mb"))
        except (TypeError, ValueError):
            return self._error(400, "remote_mb 必须是整数（0 表示关闭）")
        if mb < 0 or mb > 65536:
            return self._error(400, "remote_mb 超出范围（0~65536）")
        saved = False
        # 空间管理模块（另一个模块）以 data/storage.json 的 play 项为事实源；
        # 它在的话走它的 set_budget，顺便把运行中的预算一起改掉，保证两处口径不打架。
        try:
            from core import storage as _S          # type: ignore[import-not-found]
            _S.set_budget("play", mb)
            saved = True
        except Exception:                            # noqa: BLE001  模块还没合并进来
            saved = False
        if not saved:
            try:
                path = os.path.join(DATA_DIR, "storage.json")
                cur: dict = {}
                if os.path.isfile(path):
                    with open(path, encoding="utf-8") as fh:
                        raw = json.load(fh)
                    if isinstance(raw, dict):
                        cur = raw
                prev = cur.get("play")
                if isinstance(prev, dict):
                    prev["mb"] = mb
                else:
                    cur["play"] = {"mb": mb}
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(cur, fh)
                os.replace(tmp, path)
            except OSError as exc:
                return self._error(500, f"写 storage.json 失败: {exc}")
            PLAY_DISK.budget = mb * 1024 * 1024
            PLAY_DISK.trim()
        self._json({"ok": True, "remote_mb": mb})

    @route("POST", r"/api/user/playcache/clear")
    def playcache_clear(self, query, *_) -> None:
        a = PLAY_DISK.clear()
        b = PLAY_DISK_LOCAL.clear()
        self._json({"ok": True, "remote_removed": a.get("removed", 0),
                    "local_removed": b.get("removed", 0)})
