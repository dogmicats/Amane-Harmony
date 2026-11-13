# 给 AI 助手的提示词包

**第一句就是部署旁挂服务的完整入口**（同一句也置顶在 [DEPLOY.md](DEPLOY.md)）。这些提示词配合 `tools/agentctl.py` 使用（**「安装 HAP」一节除外**，它是引导式的，不涉及 CLI）。**核心原则：agent 只做调度，不做判断** —— 部署逻辑固化在 CLI 里，agent 调命令、解析 JSON、向用户确认，而不是手写 compose 或猜路径。

使用前先让 agent 读仓库根目录的 `AGENTS.md`（里面有不可放宽的红线）。

---

## 部署旁挂服务（一句话，最省事）

不想自己看部署文档时，把这一句发给 AI 助手即可（同一句也放在 [DEPLOY.md](DEPLOY.md) **最前面**，方便直接复制）：

```
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/DEPLOY.md 与 AGENTS.md，用 tools/agentctl.py 帮我在「运行 Amane 的那台机器」上部署 amane-user 旁挂服务。目标机必须与 Amane 同机，或能访问同一个 data 目录（共享卷 / 网络挂载），不是你自己所在的沙箱、临时容器或另一台无关电脑。先确认目标机在哪、以及用 Docker 还是纯 Python，再跑 doctor --json 按缺项逐个问我；AMANE_TOKEN 由我手动输入，不要回显、不要写日志；plan --json 先把完整计划给我确认，我同意后再 apply --yes，最后用 /api/user/ping 验证；任何一步失败就停下并报告，不要猜配置、不要改 Amane 本体、不要动反代和 DNS。如果你访问不到目标机，就只给我可以在目标机上执行的命令。
```

这一条走 `tools/agentctl.py`：**先 doctor 后 plan，计划经你确认才 apply**，最后验证 `/api/user/ping`。API token 由你手动输入，不要发进对话或日志；容器、端口、反代等实际变更一律先确认。下面两节是同一流程的分步版本，可按需补充细节。

## 部署（Docker）

```
你是部署助手。目标是在「运行 Amane 的那台机器」上部署 Amane-Harmony 的 amane-user 服务（Docker 方式）—— 必须与 Amane 同机，或能访问同一个 data 目录；不是你的沙箱、临时容器或无关主机。先向我确认目标机；若你无法在该机执行命令，只输出可复制的命令让我执行。
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
同上一节，同样在**目标机**上执行（不要装在 agent 自己的运行环境里）。第 3 步改用 `plan --json --mode python`，第 4 步用
`apply --yes --mode python`。不要创建容器，也不要改动 Amane 本体配置。
```

## 安装 HAP（引导式，可选）

装 App 与部署旁挂服务是两件事：先按上面几节把服务起好，才轮到 [BUILD_HAP.md](BUILD_HAP.md)。不想自己看安装文档时，可以把这一句发给 AI 助手：

```
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/BUILD_HAP.md 与 AGENTS.md，引导我把 Releases 里的 Amane-2.6.0-unsigned.hap 签名并安装到我的鸿蒙手机；先问我需要的信息，别猜配置、别代填账号密码，涉及签名和安装的操作先向我确认。
```

这一条**不走 `agentctl.py`**：HAP 安装需要在手机上点「信任此设备」、登录华为账号，agent 只能做环境检查、给可直接执行的命令、逐步引导，不能也不应代替用户输入账号密码或托管 UDID。签名与安装动作一律先向用户确认。

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
