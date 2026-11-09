# AGENTS.md — 给 AI 助手的项目约定

> 任何 agent（WorkBuddy / Claude Code / Cursor / Copilot / 其它）在修改或部署本项目前，**先读完本文件**。
> 这里写的是不可自行放宽的约束，不是建议。

## 项目是什么

独立仓库 `dogmicats/Amane-Harmony`：鸿蒙客户端（`app/`）+ 纯标准库旁挂服务（`server/`）。
上游是 `sqzw-x/amane`（GPL-3.0），本仓库是独立作品（MIT），**不含上游源码**。

## 红线（违反即停止，不要"先试试"）

1. **绝不写 Amane 本体**：`amane.db` 只读；不改 Amane 的配置、镜像、容器、Web UI；不调用会写入上游的 API。
2. **绝不把 token / 密码 / API key 回显到对话、日志、commit、Issue 或任何外部服务**。用户手动提供凭据时，立即写入权限为 600 的本地文件，不要在终端打印。
3. **不内置任何真实地址、域名、token、第三方 API key**；模板里一律用占位符。
4. **不做在线字幕搜索**：`server/subtitle_providers/registry.py` 的注册表必须保持为空，不要"顺手实现"一个 provider。
5. **字幕扫描绝不递归**：只读视频所在目录 `os.scandir`，不做 `os.walk` / `rglob`（媒体目录可能是 FUSE，递归会卡死）。
6. **发布线与自测线分开**：本仓库只管公开线（`2.1.0` 起、包名 `io.github.dogmycats.amane`）。不要引用、合并或同步自用版 `2.0.x` 的版本号、产物名或 CHANGELOG。
7. **不改版本号的派生位置**：改版本只改 `version.json`，再同步 `CHANGELOG.md`、`app/AppScope/app.json5`、`server/server.py` 的 `VERSION`。

## 部署工作流（必须按这个顺序）

1. `python tools/agentctl.py doctor --json` → 读 `missing` 列表，逐项向**用户**询问；不要猜路径或 token。
2. `python tools/agentctl.py plan --json` → 把完整计划展示给用户，**等待明确确认**。
3. `python tools/agentctl.py apply --yes` → 执行；再跑一次 `doctor --json` 自验。
4. 任一命令退出码非 0：立即停止，运行 `rollback` 并报告，**不要自行猜测修复**。

涉及容器、端口、反向代理、防火墙的操作一律两段式（plan → 人工确认 → apply）。

## 环境变量（完整表见 deploy/.env.example）

| 变量 | 含义 |
|---|---|
| `AMANE_BASE` | Amane 地址，默认 `http://127.0.0.1:8000` |
| `AMANE_DATA` | Amane 的 data 目录（需可读 `amane.db` / `token` / `image_token`） |
| `AMANE_TOKEN` | 不给则读 `{AMANE_DATA}/token` |
| `DATA_DIR` | `user.db`、图片缓存、字幕缓存的位置 |
| `MEDIA_ROOT` / `MEDIA_PATH_MAP` | 只读媒体卷与容器内路径映射，字幕功能需要 |
| `PORT` | 默认 8770 |
| `IMG_HOST_ALLOW_EXTRA` | 追加允许代理的图片主机（逗号分隔） |

## 验证命令

```sh
python tools/agentctl.py doctor --json
python tools/scan_secrets.py --path .          # 必须为 0 命中
python -m py_compile server/server.py server/subtitles.py tools/agentctl.py
curl -s http://127.0.0.1:8770/api/user/ping   # {"ok":true,...}
curl -s "http://127.0.0.1:8770/api/user/subtitles/providers"  # providers 必须为 []
```

## 代码风格

服务端只用 Python 标准库，不引入第三方依赖；路由通过模块级 `ROUTES` 列表注册，新增端点优先放在独立模块里用 `install(ROUTES, ...)` 挂载，不要膨胀 `server.py`。客户端是 ArkTS/ArkUI，所有 `player.*` 原生调用必须包 `try-catch`。
