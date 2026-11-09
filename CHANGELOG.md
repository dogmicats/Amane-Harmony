# Changelog

本文件只记录**公开发布线**（`2.1.0` 起）。自用/自测线的 `2.0.x` 变更不在本仓库内。

## 未发布（文档）

- 修正一句话 prompt 里「本机」的歧义：部署目标是**运行 Amane 的那台机器**（或能访问同一个 data 目录的机器），不是 AI 助手所在的沙箱 / 临时容器 / 无关主机；并要求 agent 访问不到目标机时只输出可复制命令。同步 `docs/DEPLOY.md`（新增「部署在哪台机器上」）、`docs/PROMPTS.md`、`AGENTS.md`（部署工作流第 0 步）、`README.md`、`llms.txt`、`tools/agentctl.py` 文案、Release 说明。
- 补充 HAP 安装的**侧载（测载）**方式：除 DevEco Studio 外，也可用 Hokit、小白调试助手及其它提供同类功能的工具；同步更新 `README.md`、`llms.txt`、`TROUBLESHOOTING.md` 与 Release 说明。HAP 产物不变。
- 把「给 AI 助手的一句话 prompt」**主入口改到 `docs/DEPLOY.md` 开头**（部署旁挂服务才是主要安装步骤）：不懂配置的人可直接交给 agent 用 `tools/agentctl.py` 部署并验证 `/api/user/ping`，希望自己配置的往下看两种部署路径；`README.md`、`docs/PROMPTS.md`、`llms.txt`、Release 说明同步。`docs/BUILD_HAP.md` 的显眼区块缩为一行引导，装 App 的提示词保留在 `docs/PROMPTS.md`，不再把「装 App」误当成部署主流程。
- 新增 `docs/ANDROID.md`：澄清卓易通方向相反、实验性项目 HOA 的能力边界与本项目为何跑不起来、按 `server/` HTTP 契约自行移植的做法、官方安卓版工作量评估与跨端同步策略；`README.md`、`AGENTS.md`、`llms.txt` 同步。

## [2.1.0] - 2026-11-09

首个公开发布版本。

### 新增

- 鸿蒙原生客户端（ArkUI + mpv）：浏览、收藏、观看历史、播放。
- 旁挂服务 `amane-user`：收藏/历史/首页聚合/图片代理/播放流代理，纯标准库。
- 外挂字幕四种来源：视频同目录字幕、手机文件选择器导入、手动字幕 URL、记住每部片上次的选择。
- 字幕编码自动转换（UTF-8 / GB18030 / Shift-JIS / BIG5）与 WebVTT 兼容输出。
- `subtitle_providers` 抽象接口（**注册表为空，在线字幕源未启用**）。
- GHCR 镜像、compose / Caddy 模板、Windows / Linux / macOS 直跑脚本。
- `tools/agentctl.py`：给 AI 助手用的 `doctor / plan / apply / status / rollback` JSON CLI。
- `AGENTS.md`、`llms.txt`、`docs/PROMPTS.md`：AI Native 部署契约。

### 安全

- 发布版不含任何服务器地址、token、内网 IP、个人域名、签名材料或第三方 key。
- 与自用/自测线使用不同 bundleName，两个包可同机共存、数据隔离。
