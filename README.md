# Amane-Harmony

鸿蒙原生客户端 + 旁挂服务，为自建的 [Amane](https://github.com/sqzw-x/amane) 媒体库补上手机端体验：浏览、收藏、观看历史、播放，以及**外挂字幕**。

> **非官方第三方项目**，与上游 `sqzw-x/amane` 无隶属关系，也不由上游维护。
> 本仓库**不含任何媒体内容、字幕内容、服务器地址或凭据**；所有连接信息由你首次启动时自行填写。
> 上游采用 GPL-3.0；本仓库是独立客户端与独立 HTTP 服务，通过 HTTP/SQLite 与之交互，采用 MIT。

## 它是什么 / 不是什么

| | |
|---|---|
| ✅ 是 | 一个 ArkUI + mpv 的鸿蒙 App、一个纯标准库的 Python 旁挂服务、一套部署模板 |
| ❌ 不是 | Amane 的分支 / 插件 / 修改版镜像；不改动 Amane 本体，不写入 `amane.db` |

旁挂服务 `amane-user` 提供收藏、历史、首页聚合、图片代理、播放流代理和字幕端点。它**只读** Amane 的 `amane.db`，自己的数据放在独立的 `user.db`。之所以需要播放流代理，是因为 `@mpv-ohos/mpv-arkts` 1.0.0 会把 `Authorization` 请求头错误编码导致 401；由服务端补正确的 Bearer 头回源。

## 前置条件

1. 已按[上游文档](https://sqzw-x.github.io/amane/)部署好 Amane，并知道它的 **data 目录**和 **API token**。
2. 一台与 Amane **同机 / 可共享 data 目录**的机器跑旁挂服务（Docker 或纯 Python 均可）。
3. 一部鸿蒙手机，以及下面任一种安装方式：DevEco Studio + 你自己的华为账号自动签名，或 **Hokit / 小白调试助手等提供侧载（测载）功能的工具**，详见 [docs/BUILD_HAP.md](docs/BUILD_HAP.md)。

> 暂不支持把旁挂服务部署到与 Amane 完全不同的另一台机器：它依赖直读 `amane.db`。
>
> **用的不是鸿蒙手机？** 本项目目前只有鸿蒙原生客户端；安卓 / iOS / PC 的替代方案（上游 Web UI、实验性兼容层、按 HTTP 契约自行移植）见 [docs/ANDROID.md](docs/ANDROID.md)。

## 三步上手

**① 起旁挂服务**（二选一）

```sh
# Docker
cp deploy/.env.example .env
# 编辑 .env：AMANE_DATA 指向 amane 的 data 目录，MEDIA_ROOT 指向媒体目录
docker compose -f deploy/compose.example.yml up -d

# 或纯 Python（Windows / Linux / macOS / 群晖都行，无需 Docker）
python server/server.py          # 先设置同名环境变量，见 docs/DEPLOY.md
```

验证：`curl http://<主机>:8770/api/user/ping` → `{"ok":true,...}`

**② 装 App**

> **不懂配置？** 直接把 [安装指南最前面的一句话](docs/BUILD_HAP.md) 发给你的 AI 助手，让它带你装；希望自己配置的再往下看。

从 [Releases](../../releases) 下载 `Amane-2.1.0-unsigned.hap`（未签名），按 [docs/BUILD_HAP.md](docs/BUILD_HAP.md) 完成签名与安装：可以用 DevEco Studio + 你自己的华为账号自动签名后 USB 安装，**也可以直接用 Hokit、小白调试助手等提供侧载（测载）功能的工具**，不必安装 DevEco。也可以从 `app/` 源码自行构建。无论哪种方式，装进手机的都必须是已签名包。

**③ 在「设置 → 连接」里填**

| 字段 | 填什么 |
|---|---|
| 局域网 Amane | `http://<NAS-IP>:8000` |
| 局域网用户服务 | `http://<NAS-IP>:8770` |
| 外网地址 | 可选，配了反代才填 |
| API token | Amane 的 token |

保存后即可使用。播放页的「字幕」面板支持视频旁的字幕、手机导入、手动 URL，并会记住每部片上次的选择，详见 [docs/SUBTITLES.md](docs/SUBTITLES.md)。

## 外网访问（可选）

`deploy/Caddyfile.example` 给出路径分流模板：`/api/user/*` 与 `/img` → 8770，其余 → 8000。任何反向代理 / 内网穿透都可以用，本仓库不绑定特定服务商。

> 安全提醒：播放与字幕把 token 放在 URL query 中。请只在 HTTPS 或可信内网使用，反向代理不要记录 query，并定期轮换 token。

## 目录

```
app/     鸿蒙客户端源码（ArkUI + mpv）
server/  amane-user 服务（纯标准库）+ Dockerfile + 字幕模块
deploy/  compose / .env / Caddyfile 模板与各平台启动脚本
optional/ 可选的辅助脚本
docs/    部署、构建、字幕、兼容性、排障、AI 助手提示词
tools/   脱敏自检 + agentctl（给 AI 助手用的部署 CLI）
```

## 给 AI 助手

想让 agent 帮你自动部署？先读 [AGENTS.md](AGENTS.md)，再看 [docs/PROMPTS.md](docs/PROMPTS.md)，并让 agent 通过 `tools/agentctl.py` 的 `--json` 命令操作（**不要**让它自己猜配置或手写 compose）。

**装 App 也能交给它**：把 [安装指南最前面的一句话 prompt](docs/BUILD_HAP.md) 发过去即可，不懂签名的人照着做就行；希望自己配置的往下看三种安装方式。

## 字幕来源说明

本版本**不提供在线字幕搜索**。`server/subtitle_providers/` 只有抽象接口且注册表为空，UI 也没有入口。这是刻意保留的扩展点，等有稳定、合规、无需共享密钥的字幕来源后再启用。详见 [docs/SUBTITLES.md](docs/SUBTITLES.md)。

## 许可与致谢

MIT，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上游 Amane 见 [CITATION.cff](CITATION.cff)。
