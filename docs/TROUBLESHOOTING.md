# 故障排查

| 现象 | 检查 |
|---|---|
| `/api/user/ping` 不通 | 服务没起 / 端口不对 / 防火墙；`python server/server.py` 前台跑看日志。 |
| App 提示 token 无效 | 「设置 → 连接」里的 token 与 Amane 的 `{data}/token` 一致；反代有没有把 `?token=` 吃掉。 |
| 播放一直加载 | ① 确认 `/api/user/*` 被反代分到 8770；② 确认没让 mpv 直连 Amane（mpv-arkts 的请求头缺陷会 401）；③ 播放接口需要长 `read_timeout`。 |
| 拖动后卡顿 / 缓存上不去 | 看播放页诊断行的**缓存秒数**：贴 0 = 网络或网盘回源跟不上（确认 `AMANE_PLAY_CACHE_MB` 没被调小）；有积压还卡 = 解码跟不上（关硬解对比）；全 0 不动 = 请求没通，按上一行排查链路。音视频轨在文件里相隔很远（GB 级）的片子靠 2.3.0 的块缓存解决，确认旁挂服务已升级。 |
| 图片加载不出来 | `IMG_HOST_ALLOW_EXTRA` 是否包含图片主机；图片 URL 不要带百分号编码（ArkUI `Image()` 会二次编码）。 |
| 字幕列表为空 | `MEDIA_PATH_MAP` 是否把 amane 容器内路径映射对；媒体卷是否 `:ro` 挂进容器；字幕文件名是否与视频 stem 一致。 |
| 字幕乱码 | 服务端已做 UTF-8/GB18030/Shift-JIS/BIG5 转换；若是少见编码，先用文本工具转存成 UTF-8 再导入。 |
| 远程字幕加载失败 | 给字幕地址加 `&format=vtt` 强制转 WebVTT；ASS 特效字幕建议改用「手机导入」。 |
| 字幕扫描卡住 | 确认没有改成递归遍历；FUSE / 云盘挂载上 `os.walk` 会卡死。 |
| Docker Desktop 上连不上 Amane | 不要用 `network_mode: host`；用同一 network + 服务名，并把 `AMANE_BASE` 写成 `http://amane:8000`。 |
| 装不上 HAP | 装进手机的必须是已签名包：用 DevEco 自动签名、自己的签名工具链，或 Hokit / 小白调试助手等侧载（测载）工具完成本地调试签名；见 [BUILD_HAP.md](BUILD_HAP.md)。 |

## 拿日志

```sh
docker compose -f deploy/compose.example.yml logs -f amane-user
# 或纯 Python
VERBOSE=1 python server/server.py
```

提 Issue 时请**先删掉日志里的 token、内网地址与主机名**。
