# 部署 amane-user

> **这是本项目的主要安装步骤**：先部署 `amane-user` 旁挂服务，客户端连的就是它。不懂配置 → 看下一节的一句话；想自己配置 → 直接往下翻环境变量表。

## 最快上手：把这句话发给你的 AI 助手

**不想逐项看环境变量、也不确定该用 Docker 还是纯 Python？把下面这一句整段复制给你的 AI 助手**（WorkBuddy / DeepSeek Harness / Claude Code / Cursor / Copilot 等），它会读本仓库文档、用 `tools/agentctl.py` 按可验证的契约带你把旁挂服务部署好：

```text
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/DEPLOY.md 与 AGENTS.md，用 tools/agentctl.py 帮我在「运行 Amane 的那台机器」上部署 amane-user 旁挂服务。目标机必须与 Amane 同机，或能访问同一个 data 目录（共享卷 / 网络挂载），不是你自己所在的沙箱、临时容器或另一台无关电脑。先确认目标机在哪、以及用 Docker 还是纯 Python，再跑 doctor --json 按缺项逐个问我；AMANE_TOKEN 由我手动输入，不要回显、不要写日志；plan --json 先把完整计划给我确认，我同意后再 apply --yes，最后用 /api/user/ping 验证；任何一步失败就停下并报告，不要猜配置、不要改 Amane 本体、不要动反代和 DNS。如果你访问不到目标机，就只给我可以在目标机上执行的命令。
```

**部署在哪台机器上？** 必须是**运行 Amane 的那台机器**，或能访问同一个 data 目录（共享卷 / NFS / SMB 挂载）的机器 —— 它要能读到 `amane.db`、`token`、`image_token`。**不要装在** AI 助手自己的沙箱、临时容器或另一台无关电脑上：那样即使 `/api/user/ping` 返回 200，列表、收藏和播放也会是空的，因为读不到库。

AI 助手能帮你：读懂环境变量表、判断该走 Docker 还是纯 Python、检查 Amane 的 data 目录与媒体路径映射（`MEDIA_PATH_MAP`）、生成 `.env`、执行 `doctor / plan / apply`、验证 `/api/user/ping`、失败时回滚。

**仍要你自己动手的**：提供 Amane 的 data 目录与 API token（**不要让助手代填，也不要发进对话或日志**）、确认部署计划、批准容器 / 端口 / 反代等实际变更。token 只写进**目标机**上的 `.env`。

> **想自己配置、或要看完整的环境变量与两条部署路径 → 继续往下看。**

---

`server/server.py` 只用 Python 标准库（3.9+），**不需要 pip install**。它必须与 Amane **同机或共享同一个 data 目录**，因为要直读 `amane.db`。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `AMANE_BASE` | `http://127.0.0.1:8000` | Amane 地址。Docker 里用服务名（如 `http://amane:8000`）。 |
| `AMANE_DATA` | `/amane-data` | Amane 的 data 目录，需可读 `amane.db`、`token`、`image_token`。 |
| `AMANE_TOKEN` | 读 `{AMANE_DATA}/token` | 显式指定也行。 |
| `IMAGE_TOKEN` | 读 `{AMANE_DATA}/image_token` | 图片代理鉴权。 |
| `DATA_DIR` | `/data` | `user.db`、图片缓存、字幕缓存。 |
| `PORT` | `8770` | 监听端口。 |
| `MEDIA_ROOT` | — | compose 挂载卷的宿主路径占位（挂到 `/mnt/media`），**不参与字幕路径解析**。 |
| `MEDIA_PATH_MAP` | 空 | `容器内路径=目标机路径`，逗号分隔，如 `/media2=/mnt/media2,/media=/mnt/media`。**必须最长前缀匹配**，构建器已按前缀长度排序。 |
| `IMG_HOST_ALLOW_EXTRA` | 空 | 追加允许代理的图片主机。 |
| `SUBTITLE_CACHE` | `{DATA_DIR}/subtitles` | 字幕缓存目录。 |
| `PUBLIC_AMANE_URL` | 空 | 写进图片 URL 的对外地址，可选。 |

> 路径映射怎么填：看 Amane 容器里 `media_files.path` 的前缀（如 `/media2/jav/xxx`），把它映射成旁挂服务能看到的位置。若纯 Python 直跑且与 Amane 看到的是同一套路径，`MEDIA_PATH_MAP` 留空即可。

### 两个容易看懵的变量

**`IMAGE_TOKEN`：图片代理的“钥匙”**

Amane 的封面、演员图是要鉴权的，而手机上的 `<Image>` 组件**没法带自定义请求头**。所以本服务提供 `/img` 代理：App 只向本服务要图，本服务带上 Amane 的 `image_token` 去回源。

- 通常不用手填：不给 `IMAGE_TOKEN` 时，服务自己读 `{AMANE_DATA}/image_token`。
- 它让图片 URL 只带一张“仅能看图”的票据（`/img?b=...&t=...`），**不会把你的主 API token 写进每个图片地址**（那会出现在日志、截图、浏览器历史里）。
- 报 `图片 token 无效`：说明它和 Amane 的 `image_token` 不一致，或 App 缓存的配置过期了 —— 重新保存一次设置即可。

**`IMG_HOST_ALLOW_EXTRA`：允许代理哪些网站的图片**

`/img` 是“你给地址、我替你下载”的端点，不限制的话任何人都能拿它当免费代理去刷别人的站、甚至探测你内网。所以只代理**白名单内**的主机。

- 默认包含 `githubusercontent.com` 和 `images` / `cdn` / `img` / `static` 这类通用关键字。
- 你的图床不在里面 → 封面空白、服务日志出现 `host not allowed` → 加进去：`IMG_HOST_ALLOW_EXTRA=jdbstatic.com,dmm.co.jp,your-cdn.example`（逗号分隔，**只写域名**，不要带 `https://`）。
- 匹配规则：与白名单项相同、是其子域，或 host 中包含该项（`cdn` 这类通用词就是靠这个生效）。所以**只填你信任的域名，别填 `com` 这种过短的关键字**。

> 一句话区分：`IMAGE_TOKEN` 解决“我拿什么去 Amane 取图”，`IMG_HOST_ALLOW_EXTRA` 解决“我允许替用户去哪些站取图”。

## 方案 A：Docker Compose（推荐）

```sh
cp deploy/.env.example .env
$EDITOR .env
docker compose -f deploy/compose.example.yml up -d
docker compose -f deploy/compose.example.yml logs -f
```

模板用同一个 docker network + 服务名互访，**不用 `network_mode: host`**（该模式在 Docker Desktop for Windows / macOS 上不生效）。Amane 的 data 与媒体目录以 `:ro` 挂载。

也可以用 GHCR 上的预构建镜像：`image: ghcr.io/dogmicats/amane-user:2.5.0`，把 compose 里的 `build:` 换成 `image:` 即可。镜像由 `publish-image.yml` 在打 tag 时构建。

## 方案 B：纯 Python（不用 Docker）

Windows / Linux / macOS / 群晖 / 任何有 Python 的机器都行：

```sh
# Linux / macOS
export AMANE_DATA=/path/to/amane/data
export AMANE_BASE=http://127.0.0.1:8000
export MEDIA_PATH_MAP=/media2=/mnt/media2,/media=/mnt/media
python3 server/server.py
```
```powershell
# Windows PowerShell
$env:AMANE_DATA = "D:\amane\data"
$env:AMANE_BASE = "http://127.0.0.1:8000"
python server\server.py
```

`deploy/run.sh` / `run.cmd` / `run.ps1` 是对应的启动脚本，`deploy/systemd/amane-user.service` 是 Linux 常驻示例。

如果 Amane 本体跑在 Docker 里，记得把它的 data 目录映射出来（`-v /host/amane-data:/app/data` 之类），否则同机也读不到。

## 验证

```sh
curl http://127.0.0.1:8770/api/user/ping
# {"ok":true,"version":"2.5.0",...}
```

## 外网反代（可选）

见 `deploy/Caddyfile.example`：把 `/api/user/*` 和 `/img` 分到 8770，其余到 8000，并给播放留长超时。Nginx / Traefik / frp / Cloudflare Tunnel 同理，本仓库不绑定具体方案。

**安全**：只在 HTTPS / 内网使用，反代不要记录 query（token 在 URL 里），并定期轮换 token。

## 媒体目录是 FUSE / 云盘挂载时

字幕扫描**只列出视频所在目录**，不递归、不做全库 walk —— CD2 / rclone 这类 FUSE 挂载上递归遍历可能长时间卡死。这也是为什么字幕功能要求显式配置 `MEDIA_PATH_MAP`，而不是让服务自己去找文件。

播放代理默认把读过的数据块缓存进内存（LRU，上限 320MB，可用 `AMANE_PLAY_CACHE_MB` 调整）：拖动回看、seek 风暴型文件不再反复回源网盘冷区。内存紧张的机器可以调低；纯本地盘部署影响不大。
