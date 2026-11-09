# 部署 amane-user

> **这是本项目的主要安装步骤**：先部署 `amane-user` 旁挂服务，客户端连的就是它。不懂配置 → 看下一节的一句话；想自己配置 → 直接往下翻环境变量表。

## 最快上手：把这句话发给你的 AI 助手

**不想逐项看环境变量、也不确定该用 Docker 还是纯 Python？把下面这一句整段复制给你的 AI 助手**（WorkBuddy / DeepSeek Harness/Claude Code / Cursor / Copilot 等），它会读本仓库文档、用 `tools/agentctl.py` 按可验证的契约带你把旁挂服务部署好：

```text
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/DEPLOY.md 与 AGENTS.md，用 tools/agentctl.py 帮我在本机部署 amane-user 旁挂服务：先读文档和红线，跑 doctor --json 后按缺项逐个问我；AMANE_TOKEN 由我手动输入，不要回显、不要写日志；plan --json 先把完整计划给我确认，我同意后再 apply --yes，最后用 /api/user/ping 验证；任何一步失败就停下并报告，不要猜配置、不要改 Amane 本体、不要动反代和 DNS。
```

AI 助手能帮你：读懂环境变量表、判断该走 Docker 还是纯 Python、检查 Amane 的 data 目录与媒体路径映射（`MEDIA_PATH_MAP`）、生成 `.env`、执行 `doctor / plan / apply`、验证 `/api/user/ping`、失败时回滚。

**仍要你自己动手的**：提供 Amane 的 data 目录与 API token（**不要让助手代填，也不要发进对话或日志**）、确认部署计划、批准容器 / 端口 / 反代等实际变更。token 只写进你本机的 `.env`。

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
| `MEDIA_ROOT` | — | 只读媒体目录（字幕功能需要）。 |
| `MEDIA_PATH_MAP` | 空 | `容器内路径=本机路径`，逗号分隔，如 `/media2=/mnt/media2,/media=/mnt/media`。**必须最长前缀匹配**，构建器已按前缀长度排序。 |
| `IMG_HOST_ALLOW_EXTRA` | 空 | 追加允许代理的图片主机。 |
| `SUBTITLE_CACHE` | `{DATA_DIR}/subtitles` | 字幕缓存目录。 |
| `PUBLIC_AMANE_URL` | 空 | 写进图片 URL 的对外地址，可选。 |

> 路径映射怎么填：看 Amane 容器里 `media_files.path` 的前缀（如 `/media2/jav/xxx`），把它映射成旁挂服务能看到的位置。若纯 Python 直跑且与 Amane 看到的是同一套路径，`MEDIA_PATH_MAP` 留空即可。

## 方案 A：Docker Compose（推荐）

```sh
cp deploy/.env.example .env
$EDITOR .env
docker compose -f deploy/compose.example.yml up -d
docker compose -f deploy/compose.example.yml logs -f
```

模板用同一个 docker network + 服务名互访，**不用 `network_mode: host`**（该模式在 Docker Desktop for Windows / macOS 上不生效）。Amane 的 data 与媒体目录以 `:ro` 挂载。

也可以用 GHCR 上的预构建镜像：`image: ghcr.io/dogmicats/amane-user:2.1.0`，把 compose 里的 `build:` 换成 `image:` 即可。镜像由 `publish-image.yml` 在打 tag 时构建。

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
# {"ok":true,"version":"2.1.0",...}
```

## 外网反代（可选）

见 `deploy/Caddyfile.example`：把 `/api/user/*` 和 `/img` 分到 8770，其余到 8000，并给播放留长超时。Nginx / Traefik / frp / Cloudflare Tunnel 同理，本仓库不绑定具体方案。

**安全**：只在 HTTPS / 内网使用，反代不要记录 query（token 在 URL 里），并定期轮换 token。

## 媒体目录是 FUSE / 云盘挂载时

字幕扫描**只列出视频所在目录**，不递归、不做全库 walk —— CD2 / rclone 这类 FUSE 挂载上递归遍历可能长时间卡死。这也是为什么字幕功能要求显式配置 `MEDIA_PATH_MAP`，而不是让服务自己去找文件。
