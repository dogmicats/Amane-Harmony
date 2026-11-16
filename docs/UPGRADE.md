# 升级 amane-user（旁挂服务）

> **2.7.2 起，服务端可以在 App 里点一下升级**：「我的 → 检查更新」出现「升级服务器」按钮，
> 点了就自己下载、校验、切换、重启，全程有进度。**只有低于 2.7.2 的服务端还得手动升级一次**
> —— 升级逻辑本身在 2.7.2 里，旧服务端不认识它。
>
> 本页剩下的内容是**手动升级**（低于 2.7.2 时要用一次；也是自升级不可用时的兜底）。
> **升级不会动你的库、收藏、观看记录** —— 那些都在 `data/` 目录里，本页所有步骤都不碰它。

## 先看这条：什么时候还需要手动

| 情况 | 怎么办 |
|---|---|
| 你现在是 **2.7.2 或更新** | 不用看这页：App 里点「升级服务器」即可 |
| 你现在是 **2.7.0 或更早** | 手动升到 2.7.2 或以上（本页），之后就能用 App 内升级 |
| App 里「升级服务器」显示**不支持** | 你的 `data/` 是只读挂载；改回可写，或继续手动 |
| 服务端**连不上 github.com** | 下载不了升级包，手动升（或给代理） |
| 自升级失败并已自动回滚 | 手动升一次，把日志贴给作者 |

## 手动升级（本版适用）

下面对应三种装法，选你那种。

## 最快上手：把这句话发给你的 AI 助手

**不确定自己是 `build` 还是 `image`、也不想读下面的分支？整段复制给你的 AI 助手**
（WorkBuddy / Claude Code / Cursor / Copilot 等）：

```text
请按 https://github.com/dogmicats/Amane-Harmony/blob/main/docs/UPGRADE.md 帮我把 amane-user 旁挂服务升级到最新版。
三步走，每步先告诉我你要执行的命令、等我确认后再执行：
1) 先判断这台机器当初是怎么装的：deploy/compose.example.yml 里是 `build:` 还是 `image:`，并读当前 /api/user/ping 的 version 告诉我起点版本；
2) 备份：把 data/ 整个复制成 data.bak-<日期>（这是我唯一不可再生的东西，不许跳过、不许只备份部分）；
3) 升级：build 方式执行 git pull 然后 docker compose -f deploy/compose.example.yml up -d --build；image 方式先把 compose 里的 tag 改成新版本号再 docker compose pull && up -d。
完成后轮询 http://127.0.0.1:8770/api/user/ping 直到 ok=true，把返回的 version 报给我，确认它变了；如果 3 分钟内没起来或 version 没变，用 data.bak-<日期> 还原并把容器重建回去，然后把错误原样贴给我。
约束：不要动 data/ 里的任何文件、不要改 compose 的结构、不要碰反向代理和 DNS、不要回显任何 token；任何一步失败就停下报告，不要猜、不要重试超过两次。如果你访问不到这台机器，就只把命令给我，我自己执行。
```

**它做不了的**：打开手机的「检查更新」—— 升级完要你自己回 App 里点一次「重新检查」。
**仍要你自己判断的**：这次升级值不值得（看 Release 说明），以及是否接受短暂中断（容器重建期间 10–30 秒不可用）。

> **两件「更新」的可自动化程度从来就不一样：**
> 服务端现在（2.7.2 起）在 App 里点一下就升，连助手都不用；
> 手机 App 装包这一步要过侧载工具（Hokit / 小白调试助手 / DevEco），
> 这些工具没有可供外部程序调用的安装接口，**只能由人点**。
> 所以：服务端交给 App，手机自己动手 —— 这两句仍是同一套流程的两半。

## 你是哪种装法

| compose 里写的 | 怎么升 | 说明 |
|---|---|---|
| `build: ../server`（**默认**） | `git pull` → `docker compose -f deploy/compose.example.yml up -d --build` | 跟着官方仓库走，永远能升到最新 |
| `image: ghcr.io/dogmicats/amane-user:x.y.z` | 改 tag → `docker compose pull && up -d` | 镜像由打 tag 时自动构建；没推送成功时回退到 build 方式 |

不确定就 `grep -n "build:\|image:" deploy/compose.example.yml` 看一眼。

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
docker compose -f deploy/compose.example.yml down
mv data data.failed-$(date +%Y%m%d)
mv data.bak-20261112 data          # 换成你备份的那个名字
docker compose -f deploy/compose.example.yml up -d --build
```

`data/` 里是收藏、历史、评分、你改过的片名 —— **换回去就回到升级前**，影片文件和库本身不受影响。

## 现在是谁在升

分阶段说清楚，别混：

- **升到 2.7.2**：你自己动手（本页）。因为「能自己升」这段逻辑是这一版才有的，
  旧服务端里没有，它不会自己爬上来。
- **2.7.2 → 之后的版本**：服务端你在 App 里点「升级服务器」就行。它在容器里下载
  GitHub 上的对应版本、校验 sha256、解包到数据目录、整套 `py_compile` 过后原子切换，
  然后进程退出由 `restart: unless-stopped` 拉起来；失败或连续两次起不来自动回滚上一版。
- **手机 App**：无论哪版都只能人装。侧载工具（Hokit、小白调试助手、DevEco）都不对外提供
  「帮我装这个包」的接口，鸿蒙也不允许 App 自己装自己。App 这边只能做到「下载好、校验完、存到你手机上」。

**结果是：服务端从这一版起可以半自动（点一下 + 它自己干活），手机端永远要你点一下装包。**
