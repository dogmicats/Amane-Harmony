# 构建与安装 HAP

> **先部署旁挂服务**：客户端连接的是 `amane-user`，部署才是主要安装步骤。不懂配置就把 [部署指南最前面的一句话](DEPLOY.md) 发给你的 AI 助手，想自己配置看 [部署指南](DEPLOY.md)。
> 装 App 也可以让 AI 助手引导（提示词见 [docs/PROMPTS.md](PROMPTS.md)），但签名与安装仍需本人操作。

Releases 里提供的是 **unsigned（未签名）HAP**。鸿蒙设备不能直接安装未签名包，也不存在能给任意设备用的「通用签名」——调试证书带 UDID 白名单，换台设备就装不上。因此**无论用哪种方式，最终装到手机上的都必须是用你自己的证书签过名的包**。

区别只在于「谁来签名、谁来装」：

| 方式 | 谁来签名 | 适合 |
|---|---|---|
| 一：DevEco Studio | DevEco 用你的华为账号自动签名 | 愿意装 IDE、想从源码构建 |
| 二：命令行构建 + 自己的签名工具链 | 你自己的签名工具链 | 已有签名材料、要自动化 |
| 三：侧载工具 | 工具在本地完成调试签名，或引导你签名 | 不想装 DevEco，只想把 Releases 里的 HAP 装上 |

> 本项目不会收集任何人的 UDID，也不分发签名证书。
> 「侧载」(sideload) 指不经应用市场、由使用者自行安装 HAP；部分工具与社区也叫**测载**、调试安装。

## 准备

- 从 [Releases](../../releases) 下载 `Amane-2.5.0-unsigned.hap`，或按方式二从 `app/` 源码自行构建
- 一台开启「开发者模式 + USB 调试」的鸿蒙手机 + 数据线（部分侧载工具支持无线连接，以工具文档为准）
- 方式一/二另需：[DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 SDK，API 版本见 `app/build-profile.json5`）与一个华为开发者账号（个人账号即可）
- 方式三另需：任选一个提供侧载功能的工具（见下）

## 方式一：DevEco Studio（推荐）

1. 克隆本仓库，用 DevEco Studio 打开 **`app/` 目录**（不是仓库根目录）。
2. 等待 `ohpm install` 依赖同步完成（需要网络，会拉取 `@mpv-ohos/mpv-arkts`）。
3. `File → Project Structure → Signing Configs`，登录你的华为账号，勾选 **Automatically generate signature**。DevEco 会按 `app.json5` 里的 bundleName `io.github.dogmycats.amane` 生成调试证书与 Profile。
4. 连接手机，`Run` 选择你的设备，或 `Build → Build Hap(s)/APP(s) → Build Hap(s)` 后在 `entry/build/default/outputs/default/` 取包，用 `hdc install` 安装。
5. 首次打开 App，到「设置 → 连接」填 Amane 地址、用户服务地址与 token。

## 方式二：命令行构建

`app/build.cmd` 会调用 `hvigorw` 产出 `entry-default-unsigned.hap`（仍然需要自行签名）：

```bat
set DEVECO_HOME=C:\Path\To\DevEco Studio
cd app
build.cmd
```

签好名后用 `hdc install` 安装，或把已签名的包交给方式三的侧载工具安装。

## 方式三：用侧载工具安装（无需 DevEco Studio）

不想装 DevEco Studio 也可以直接用提供**侧载 / 测载 / 调试安装**能力的第三方工具，例如：

- **Hokit**
- **小白调试助手**
- 以及其它提供同类「HAP 本地签名 + 安装」能力的软件

一般流程（具体菜单以各工具文档为准）：

1. 手机开启「开发者模式 + USB 调试」，用数据线连接电脑并信任此设备。
2. 在工具里选择下载好的 `Amane-2.5.0-unsigned.hap`。
3. 工具在本地完成调试签名（或提示你先用自己的证书签名）后推送安装。**若工具只接受已签名包**，请先用方式一或方式二签名再交给它安装。
4. 装完打开 App，到「设置 → 连接」填地址与 token。

几点说明：

- 这些工具与本项目**没有关联**，也不由本项目维护或背书；请从官方 / 可信渠道获取，按工具自己的文档操作。
- 部分工具会要求登录华为账号、读取设备 UDID 或开启额外调试权限。**不要把账号密码、UDID 交给来路不明的工具**；本项目从不收集这些信息。
- 工具生成的调试证书通常有有效期与设备白名单，换手机或证书过期后需要重新安装。
- 工具报「未签名 / 签名不匹配」通常意味着它不做本地签名，先用方式一或方式二签好名再装。

## 常见问题

- **装不上 / 提示签名不匹配**：确认用的是你自己的证书，且 bundleName 与 Profile 一致；侧载工具报这个错时先自行签名，见方式三。
- **侧载工具连不上手机**：确认已开启 USB 调试并授权此电脑、数据线支持传输数据、工具支持当前 HarmonyOS 版本；仍不行改用方式一。
- **和旧版共存**：本仓库的 bundleName 与自用/自测版不同，两个包可以在同一台手机共存；但旧包不会自动升级成新版，需要重新安装一次。
- **模拟器**：x86_64 模拟器装不了 mpv 依赖，请用真机。
- **图片加载失败**：检查 `IMG_HOST_ALLOW_EXTRA` 是否包含你的图片主机。
- **播放一直转圈**：多数是 token 没填或反代没做 `/api/user/*` 分流，见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
