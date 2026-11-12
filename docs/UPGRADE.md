# 升级 amane-user（旁挂服务）

> 客户端里点「检查更新」时，如果提示服务端也有新版，就是照这一页做。
> **升级不会动你的库、收藏、观看记录** —— 那些都在 `data/` 目录里，本页所有步骤都不碰它。

## 最快上手：把这句话发给你的 AI 助手

**不确定自己是 `build` 还是 `image`、也不想读下面的分支？整段复制给你的 AI 助手**
（WorkBuddy / Claude Code / Cursor / Copilot 等）：

```text
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/UPGRADE.md 帮我把 amane-user 旁挂服务升级到最新版。
三步走，每步先告诉我你要执行的命令、等我确认后再执行：
1) 先判断这台机器当初是怎么装的：deploy/compose.yml 里是 `build:` 还是 `image:`，并读当前 /api/user/ping 的 version 告诉我起点版本；
2) 备份：把 data/ 整个复制成 data.bak-<日期>（这是我唯一不可再生的东西，不许跳过、不许只备份部分）；
3) 升级：build 方式执行 git pull 然后 docker compose -f deploy/compose.yml up -d --build；image 方式先把 compose 里的 tag 改成新版本号再 docker compose pull && up -d。
完成后轮询 http://127.0.0.1:8770/api/user/ping 直到 ok=true，把返回的 version 报给我，确认它变了；如果 3 分钟内没起来或 version 没变，用 data.bak-<日期> 还原并把容器重建回去，然后把错误原样贴给我。
约束：不要动 data/ 里的任何文件、不要改 compose 的结构、不要碰反向代理和 DNS、不要回显任何 token；任何一步失败就停下报告，不要猜、不要重试超过两次。如果你访问不到这台机器，就只把命令给我，我自己执行。
```

**它做不了的**：打开手机的「检查更新」—— 升级完要你自己回 App 里点一次「重新检查」。
**仍要你自己判断的**：这次升级值不值得（看 Release 说明），以及是否接受短暂中断（容器重建期间 10–30 秒不可用）。

## 你是哪种装法

| compose 里写的 | 怎么升 | 说明 |
|---|---|---|
| `build: ../server`（**默认**） | `git pull` → `docker compose -f deploy/compose.yml up -d --build` | 跟着官方仓库走，永远能升到最新 |
| `image: ghcr.io/dogmicats/amane-user:x.y.z` | 改 tag → `docker compose pull && up -d` | 镜像由打 tag 时自动构建；没推送成功时回退到 build 方式 |

不确定就 `grep -n "build:\|image:" deploy/compose.yml` 看一眼。

## 什么时候不用 Docker

如果你是用纯 Python 跑的（`python server.py`）：

```bash
cd Amane-Harmony && git pull
# 停掉旧进程，再按原来的方式启动（环境变量与 data 目录不变）
python server/server.py
```

`server.py` 只用标准库，**不需要 pip install**，所以「升级」就是换代码 + 重启。注意重启前同样备份一次 `data/`。

## 验证升级成功

```bash
curl -s http://127.0.0.1:8770/api/user/ping
```

返回里的 `version` 应该是新版本号。**只有这一步过了才算升级完成**，容器 `Up` 不算。

## 出问题怎么退回去

```bash
docker compose -f deploy/compose.yml down
mv data data.failed-$(date +%Y%m%d)
mv data.bak-20261112 data          # 换成你备份的那个名字
docker compose -f deploy/compose.yml up -d --build
```

`data/` 里是收藏、历史、评分、你改过的片名 —— **换回去就回到升级前**，影片文件和库本身不受影响。

## 为什么不自动升级

服务端在**你自己的机器上**，客户端碰不到它：

- 客户端只能读到 `/api/user/ping` 的版本号，然后告诉你「有新版」；
- 真正的升级要在那台机器上执行（拉代码、重建容器），客户端没有也不该有这个权限。

所以「自动」的部分只到「发现新版 + 给出步骤」，最后一步永远由你（或你的 AI 助手）执行。
