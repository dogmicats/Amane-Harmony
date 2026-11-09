# 非鸿蒙设备（安卓 / iOS / PC）怎么办？

> 本项目目前只提供 **HarmonyOS 原生客户端**（ArkUI + mpv）。维护者本人使用鸿蒙手机，因此没有开发官方安卓版，也没有明确的时间表。
> 下面按「省事程度」列出几条路，**都不是官方支持方案**；提到的第三方工具与本项目没有关联，也不由本项目维护或背书。

## 先把方向说清楚：卓易通是反的

- **卓易通**：在鸿蒙（HarmonyOS NEXT）设备里用轻量容器跑**安卓 APK**，解决的是「鸿蒙用户装不了某些安卓 App」。
- 你需要的恰好相反：在**安卓设备**里跑**鸿蒙 HAP**。两者不是一回事，卓易通用不上。

## 0. 最省事：用上游 Amane 自带的 Web 界面

上游 [Amane](https://github.com/sqzw-x/amane) 自带 Web UI，用浏览器打开 `http://<你的 Amane 地址>:8000` 并按上游文档登录即可；任何带浏览器的设备都能用，零安装、零签名（个别自行裁剪、未带前端产物的镜像除外）。

- 能用到：上游自身的浏览、搜索与播放能力。
- 用不到：本项目额外加的收藏、观看历史、首页聚合、外挂字幕与 mpv 播放增强（这些在 `server/` 与鸿蒙客户端里）。

只想「能在手机上看」的话，先试这条。

## 1. 有没有「安卓版卓易通」能直接装 HAP？

有，但请先降低预期：**鸿易通 HOA（Harmony on Android）** — <https://github.com/harmony-on-android/HOA>，2026 年建立的实验性开源项目（Kotlin，非华为官方）。

它基于 ArkUI-X 的 Android 构建：用 ETS 虚拟机执行 HAP 里的 `modules.abc`、ACE/Skia 把 ArkUI 画到 Android `SurfaceView`，再用 `libb.so` 做 musl→bionic 桥接加载 OHOS 的 `.so`；要求 Android 11+ / arm64-v8a，能把**未改动的 HAP** 装进安卓机，还实现了 HDC 调试协议。

**但本项目目前基本跑不起来。** 按 HOA 官方 README 的支持表：

| 本项目依赖 | HOA 现状 |
|---|---|
| `@mpv-ohos/mpv-arkts`（第三方 ohpm 包 + 为 OHOS 编译的 `libmpv.so`） | 原生 `.so` 加载已验证，但播放 / 视频渲染链路与第三方 HAR 不在已验证范围；**播放最可能失败** |
| `@kit.NetworkKit` / `ArkData` / `CoreFileKit` / `ArkWeb` / `BasicServicesKit` 等系统 Kit | README 明确「大量系统 API 尚未实现，依赖未实现系统 API 的 HAP 会白屏或崩溃」 |
| 文件选择器导入字幕、偏好持久化、崩溃上报 | 权限映射与生命周期均为「部分」实现，未验证 |
| 后台 Service / 完整 Bundle Manager / 分布式能力 | 明确「不支持」 |

其它现实约束：HOA 最后一次代码推送是 2026-07；仓库**未声明开源许可证**；HDC daemon 默认 8710 端口**无认证**，仅适合本地调试。请只从项目官方仓库与可信渠道获取，不要在生产环境、或填了真实 token 的情况下试用。

结论：**想折腾可以试**（把 Release 里的 unsigned HAP 签好名，交给 HOA 的「安装 HAP」），但别指望能用，本项目也不提供 HOA 相关支持。若哪天 HOA 补齐了系统 API，欢迎在 Discussions 里回报实测结果。

## 2. 自己移植：推荐，而且比想象中简单

这里的「移植」不是改 HAP，而是**另写一个客户端，直接调本项目的 HTTP 接口**。`server/` 是纯标准库 Python 服务，约 23 个 `/api/user/*` 端点 + `/img`，与操作系统无关；安卓 / iOS / 桌面 / Web 都能接。

- 端点全集：`server/server.py` 里的 `ROUTES` 与 `server/subtitles.py` 的 `install()`；字段与依赖见 [COMPATIBILITY.md](COMPATIBILITY.md)、[SUBTITLES.md](SUBTITLES.md)、[DEPLOY.md](DEPLOY.md)。
- 播放：**优先用 `mpv-android` 的 libmpv 封装**——它和鸿蒙端是同一套播放行为，ASS/SSA 字幕、音轨切换、硬解都是现成的，请求 `<user_base>/api/user/play/<source>/<id>?token=...` 即可。ExoPlayer 也能播，但它不原生支持 ASS（要加 ffmpeg 扩展，特效仍然弱），字幕这块会明显更费劲。鸿蒙端那个 `Authorization` 被错误编码的坑只影响 `@mpv-ohos/mpv-arkts`，安卓端不受影响。
- 字幕：服务端已把四种来源统一成 `subtitle_id`，取 `<user_base>/api/user/subtitle/<id>?token=...` 即可，见 [SUBTITLES.md](SUBTITLES.md)。
- 建议：先写个能打通 `/api/user/ping` 与 `/api/user/home` 的小原型，再补播放；把端点与响应结构整理成机器可读契约（OpenAPI / JSON）能大幅降低维护成本，**欢迎提 PR 补 `docs/API.md`**。
- 社区移植版请自行命名、自行发版；本项目不合并、不背书，也不与它的版本号绑定。可以在 Discussions 里互相链接。

## 3. 由我们维护一个官方安卓版，快不快？

**不快，本质上是重写，不是改一改。** 当前客户端 25 个 ArkTS 文件 / 约 4900 行（播放页单文件 843 行），依赖 9 类 OHOS `@kit.*` 与第三方 `@mpv-ohos/mpv-arkts`。安卓是 ART + bionic，既没有这些 Kit，也没有 ArkTS 运行时 —— UI、状态管理、网络、文件选择、播放器全部得换。

| 路线 | 做法 | 能复用什么 | 评价 |
|---|---|---|---|
| A. ArkUI-X 重新出包 | 用官方跨端框架把 ArkTS 编到 Android | 部分 UI / 业务代码 | 不推荐：第三方 ohpm HAR 与原生播放组件仍需重写，还要跟着框架的 API 覆盖度踩坑 |
| B. 安卓原生重写（首选） | Kotlin/Compose + **libmpv**（mpv-android 封装） | **服务端 100% 复用**，播放与字幕行为可照搬鸿蒙端 | AI 辅助约 **3–6 天**能出「能浏览、能播、能挂字幕」的粗糙版；再加 **1–2 周**到日常可用（设置、手势、错误处理、系统版本差异、签名分发）。前提：手边有安卓真机 |
| C. Web / PWA | 在上游 Web UI 基础上接本项目接口 | 一套代码覆盖安卓 / iOS / PC | 播放格式与硬解受浏览器限制，但维护成本最低 |

> **为什么鸿蒙端像是「一下午就出来了」？** 那 25 个 ArkTS 文件 / 约 4900 行是长期迭代的结果；一下午做的是**脱敏、字幕面板（约 130 行）、改包名与版本、构建发布**，不是从零写客户端。安卓端要重写的是这 4900 行的等价物 —— 不是把当天的增量再抄一遍。从零写一个鸿蒙客户端，同样不可能是一下午。

真正的成本不在「写出来」，而在**验证与长期维护**：作者手边没有安卓真机，无法验证播放、字幕编码兼容与各种系统版本差异；多一个端就多一套构建、签名、发版与排障。因此**首发不做，也不承诺时间表**；更愿意把力气花在把 HTTP 契约写清楚上，让需要的人自己接。

## 后续真要出第二端，怎么同步更新

1. **契约先行**：把 `/api/user/*` 的路径、参数、响应结构固化成 `docs/API.md` 或 OpenAPI，CI 校验「实现 ⊇ 契约」，客户端按契约生成类型。
2. **API 版本化**：加 `X-API-Version`（或 `/api/user/v1/...` 前缀），破坏性变更只新增版本，旧客户端不被炸掉。
3. **能力协商**：`GET /api/user/capabilities` 返回已启用端点 / 字幕来源 / 服务端版本，客户端按能力显示 UI，不硬编码。
4. **功能矩阵**：README 与 CHANGELOG 逐版标注「鸿蒙端 / 其它端」各自支持到哪，避免被误读为「同步更新」。
5. **各端独立发版**：只共享契约与文档，不共享版本号、不 fork 客户端代码；社区端自行 tag、自行发 Release。

> 这也是本项目一直坚持的做法：客户端与 `server/` 之间只通过 HTTP/JSON 交互，任何平台都能接，不必等官方出第二个端。
