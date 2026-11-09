# 给 AI 助手的提示词包

这些提示词配合 `tools/agentctl.py` 使用。**核心原则：agent 只做调度，不做判断** —— 部署逻辑固化在 CLI 里，agent 调命令、解析 JSON、向用户确认，而不是手写 compose 或猜路径。

使用前先让 agent 读仓库根目录的 `AGENTS.md`（里面有不可放宽的红线）。

---

## 部署（Docker）

```
你是部署助手，在这台机器上部署 Amane-Harmony 的 amane-user 服务（Docker 方式）。
1. 先读 AGENTS.md 与 docs/DEPLOY.md，遵守其中红线。
2. 运行 `python tools/agentctl.py doctor --json`。按 missing 列表逐项向我询问：
   AMANE_DATA 路径、AMANE_TOKEN 由我手动输入，禁止回显、禁止写入日志或对话。
3. 运行 `python tools/agentctl.py plan --json`，把完整计划展示给我，等我明确确认。
4. 确认后运行 `python tools/agentctl.py apply --yes`，再跑一次 doctor --json 与
   /api/user/ping，把结果回报给我。
5. 任一命令非 0 退出码立即停止，执行 rollback 并报告，不要自行猜测修复。
```

## 部署（纯 Python，非 Docker）

```
同上一节，但第 3 步改用 `plan --json --mode python`，第 4 步用
`apply --yes --mode python`。不要创建容器，也不要改动 Amane 本体配置。
```

## 配置外网反代

```
读 docs/DEPLOY.md 与 deploy/Caddyfile.example。向我确认域名与证书邮箱后，
生成一份不含任何真实值的配置草稿给我看；我确认后才写入文件。
不要重启我的反向代理，也不要修改 DNS。验证用 `caddy validate`。
```

## 升级

```
运行 `python tools/agentctl.py status --json`，告诉我当前版本与 DATA_DIR。
确认 user.db 已备份后，执行 `upgrade --json`。升级后跑 doctor --json 与 /api/user/ping。
不要删除 data/ 目录，不要改动字幕缓存。
```

## 诊断播放 / 字幕问题

```
按 docs/TROUBLESHOOTING.md 的顺序逐项检查，每步把命令与结论告诉我。
读日志时先过滤掉 token 与主机名再展示。不要自行修改 Amane 的容器或配置。
```

---

## 为什么提示词这么短

因为判据都在 CLI 里：`doctor --json` 返回结构化的 `missing` / `ok`，`plan --json` 给出可审阅的改动清单，`apply` 幂等且可 `rollback`。让 LLM 自由发挥去拼 YAML 或猜路径，才是部署漂移与凭据泄露的主要来源。
