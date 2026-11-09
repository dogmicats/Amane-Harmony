# 构建与安装 HAP

Releases 里提供的是 **unsigned（未签名）HAP**。鸿蒙不允许安装未签名包，也不存在"通用签名"能给任意设备用；调试证书带 UDID 白名单，换台设备就装不上。因此请用**你自己的华为账号**自动签名。

> 本项目不会收集任何人的 UDID，也不分发签名证书。

## 准备

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 SDK，API 版本见 `app/build-profile.json5`）
- 一个华为开发者账号（个人账号即可）
- 一台开启「开发者模式 + USB 调试」的鸿蒙手机
- 数据线

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

签名与安装仍需 DevEco Studio 的自动签名流程，或你自己的正式签名工具链。

## 常见问题

- **装不上 / 提示签名不匹配**：确认用的是你自己的证书，且 bundleName 与 Profile 一致。
- **和旧版共存**：本仓库的 bundleName 与自用/自测版不同，两个包可以在同一台手机共存；但旧包不会自动升级成新版，需要重新安装一次。
- **模拟器**：x86_64 模拟器装不了 mpv 依赖，请用真机。
- **图片加载失败**：检查 `IMG_HOST_ALLOW_EXTRA` 是否包含你的图片主机。
- **播放一直转圈**：多数是 token 没填或反代没做 `/api/user/*` 分流，见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
