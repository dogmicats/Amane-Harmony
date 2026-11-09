# Changelog

本文件只记录**公开发布线**（`2.1.0` 起）。自用/自测线的 `2.0.x` 变更不在本仓库内。

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
