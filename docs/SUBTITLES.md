# 外挂字幕

播放页的「字幕」面板支持四种来源：视频同目录、手机导入、手动 URL、在线搜索。所有来源最终都会变成服务端的一个 `subtitle_id`，客户端只加载一个地址，因此不同来源对 App 完全同构。

## 1. 视频同目录的字幕（local）

命名口径与上游 Amane 一致：同目录下，文件名等于视频 stem，或以 `<stem>.` 开头（如 `movie.srt`、`movie.zh.ass`、`movie.ja.srt`），扩展名 `.srt / .ass / .ssa / .vtt / .sub`。服务端按语言后缀猜一个标签（`.zh/.chs/.cn` → chi，`.jp/.ja` → jpn，`.en` → eng）仅供展示。

前提：给旁挂服务挂上**只读媒体卷**并配置 `MEDIA_PATH_MAP`（见 [DEPLOY.md](DEPLOY.md)）。不配也能用其它三种来源。

> 只 `os.scandir` 视频所在目录，**不递归**。云盘 FUSE 挂载上递归遍历会卡死，这是刻意的限制。

### 同目录字幕不显示？按这个顺序查

面板会在「外挂字幕」下方直接显示服务端给的原因，对照着看最快：

| 面板提示 | 原因 | 怎么修 |
|---|---|---|
| 未配置 MEDIA_PATH_MAP | 服务不知道 amane 的 `/media2/...` 对应本机哪里 | 配 `MEDIA_PATH_MAP=/media2=/mnt/media2`：左边是 amane 容器内前缀，右边是本服务能看到的路径 |
| MEDIA_PATH_MAP 没有匹配到任何视频路径 | 前缀写错（漏尾、大小写、多空格） | 进 amane 容器 `ls /media2` 确认前缀；多项用逗号分隔，每项 `源=目标` |
| … 不存在 | 映射后的路径在旁挂服务里看不到 | compose 加只读卷 `- /your/media:/mnt/media2:ro`，再 `docker exec` 进容器 `ls /mnt/media2` 确认 |
| … 不可读（Permission denied） | 容器内用户没有读权限 | 检查宿主机目录权限；必要时调整容器用户或 `chmod o+r` |
| 同目录没有与视频同名的字幕 | 命名不符合规则 | 必须是 `<视频名>.srt` 或 `<视频名>.<语言>.srt`；`xxx.zh-CN.ass`、`xxx.chs.srt` 都行，`字幕.srt` 不行 |
| 面板里没有字幕入口 / 提示 404 | 旁挂服务版本偏旧（没有字幕端点） | 升级旁挂服务：`curl .../api/user/subtitles/providers` 应返回源列表（`xunlei`、`javzimu` 等），而不是 404 |

> `MEDIA_ROOT` 只是 compose 挂载卷的宿主路径占位，**不参与字幕路径解析**；真正生效的是 `MEDIA_PATH_MAP`。不配它也能用手机导入和手动 URL，只是看不到同目录字幕。

## 2. 手机文件选择器导入（import）

面板里点「手机导入」→ 系统文件选择器（只筛 `.srt / .ass / .ssa / .vtt / .sub`）→ App 读字节后上传到服务端缓存，返回 `subtitle_id`。一个字幕通常几十 KB，上传后服务端做编码转换并缓存，**换手机 / 重装 App 也不会丢**（只要 `DATA_DIR` 还在）。

如果选择器里看不到某个字幕文件：确认它在系统「文件管理」里可见、扩展名在上述列表内（`.txt` 改名为 `.srt` 后需要重新进一次选择器）。

## 3. 手动字幕 URL（url）

面板里填一个 http(s) 字幕地址，服务端抓取（12s 超时、2 MiB 上限）后落到同一份缓存。适合你自己搭的字幕服务或直链。

## 4. 在线搜索（online）

面板里点「在线搜索」，服务端按**番号**并发查几个公开源，合并去重后按语言偏好排序。任一源超时或报错都不影响其它源，失败原因会单独列出来。

| 源 | 状态 | 说明 |
|---|---|---|
| 迅雷 | 默认启用 | 接口直连，最稳；一条搜索通常就能拿到 srt / ass |
| JAV字幕 | 默认启用 | 有速率限制；站点要求验证时，App 里会弹出验证入口，输一次即可 |
| 字幕猫 | 默认关闭 | 出口被 Cloudflare 拦，要能过 CF 的线路才可用；`SUBTITLE_ZIMUCAT=1` 打开，且需二次解析详情页 |

点一条结果就下载并切过去。落盘规则：

- 媒体卷**可写**时写进视频同目录（`<视频名>.<语言>.srt`），换设备、重装 App、用 Emby 看都还在；不覆盖你自己放的同名字幕，重名自动顺延 `-2`。
- 媒体卷只读（默认 compose 就是 `:ro`）时落到服务端字幕缓存：当前这台服务能播，但不会写到影片旁边，也不跨实例同步。
- 下载链接有时效。隔太久再点会报「链接已过期」，重新搜一次即可。

**搜不到 / 报错**：先确认这条影片有番号（在线源按番号查）；`403` 多为站点加了新门槛，`429` 是限流，过几分钟再试；服务端出口被挡（403 / TLS EOF）时，可以在**目标机**上用 `SUBTITLE_PROXY=http://你的代理:端口` 换个出口。

## 5. 记住选择（choice）

选过一次字幕后，`user.db` 的 `subtitle_choice` 表记下 `item_id → subtitle_id`，下次播放同一部片自动套用。可在面板里改成「不使用字幕」。

## 编码与格式

- 自动识别 UTF-8（含 BOM）、UTF-16LE / UTF-16BE（含无 BOM）、GBK / GB18030、BIG5、Shift-JIS、EUC-KR，统一转成 UTF-8 再返回。
- ASS / SSA 保留原样（特效不丢）。
- SRT 可以转成 WebVTT：给字幕地址加 `&format=vtt`。`mpv-arkts` 的远程字幕示例用的是 WebVTT；如果你的设备加载远程 SRT 有问题，就用这个参数。
- mpv 自身支持远程字幕，字幕**不需要落盘到手机**。

## 给维护者：加一个在线源要满足什么

`server/ext/subtitles/server_ext.py` 的 `PROVIDERS` 就是全部在线源，客户端只认 `/api/user/subtitles/search` 返回的 `items`，加源不用改 App。

- **不需要账号、不需要 key**：不许内置或共享任何第三方凭据，也不许要求用户去某个站注册。
- **人来点，程序不绕**：搜索由用户在面板里触发；站点要验证码就把验证入口交回用户，不做自动识别或绕过。
- **自己兜住失败**：必须走 `SEARCH_TIMEOUT` / `SEARCH_MAX_BYTES`，抛错只影响自己这一路；不稳定的源挂在 `SUBTITLE_*` 开关后面，不能让默认搜索每次都多一条报错。
- **尊重站点限制**：带速率限制的源就接受 429，不重试轰炸。

规则原文见 [AGENTS.md](../AGENTS.md) 红线第 4 条。

## 端点速查

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/user/subtitles?item_id=` | 列出本地候选、已缓存字幕、上次选择 |
| GET | `/api/user/subtitles/local?item_id=&name=` | 把同目录字幕读进缓存 |
| POST | `/api/user/subtitles/import` | 上传手机选中的字幕（base64） |
| POST | `/api/user/subtitles/url` | 抓取手动 URL |
| GET | `/api/user/subtitle/<id>?token=` | 给 mpv 的字幕流 |
| GET/PUT | `/api/user/subtitles/choice` | 读取 / 记住选择 |
| GET | `/api/user/subtitles/providers` | 在线源列表（id / name / note） |
| GET | `/api/user/subtitles/search?q=&item_id=` | 在线搜索；给 `item_id` 时用它的番号 |
| GET | `/api/user/subtitles/captcha` | 取站点验证码（图 + id），给用户在 App 内输 |
| POST | `/api/user/subtitles/captcha` | 提交验证码 |
| POST | `/api/user/subtitles/save` | 把一条在线结果落盘 / 落缓存 |
| GET / DELETE | `/api/user/subtitles/owned` | 列出 / 删除旁挂自己写进影片目录的字幕 |
