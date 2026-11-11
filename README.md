<p align="center">
  <img src="assets/hero-banner.png" alt="Amane-Harmony" width="100%">
</p>

<p align="center">
  <a href="https://github.com/dogmicats/Amane-Harmony/releases"><img alt="Releases" src="https://img.shields.io/github/v/release/dogmicats/Amane-Harmony?style=flat-square&color=8b5cf6"></a>
  <img alt="HarmonyOS" src="https://img.shields.io/badge/HarmonyOS-native-536dfe?style=flat-square">
  <img alt="ArkTS" src="https://img.shields.io/badge/ArkTS-client-8b5cf6?style=flat-square">
  <img alt="mpv" src="https://img.shields.io/badge/Player-mpv-7c3aed?style=flat-square">
  <img alt="Python" src="https://img.shields.io/badge/Sidecar-Python-3776ab?style=flat-square">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/dogmicats/Amane-Harmony?style=flat-square"></a>
</p>

<p align="center">
  <strong>把 Amane 媒体库带到 HarmonyOS。</strong><br>
  原生媒体库浏览、演员 / 共演检索、收藏续播与 mpv 播放；<br>
  轻量 Python 旁挂服务补齐扩展 API、字幕与播放代理。
</p>

> 截图取自作者自建媒体库；封面、横幅与剧照已打码，演员头像保留原样。

## 部分有趣功能展示，其他功能，等你来发现

<table>
  <tr>
    <td width="170" valign="top"><img src="docs/screenshots/cast-finder.png" width="150"></td>
    <td valign="top">
      <strong>① 共演检索</strong><br>
      <sub>最多 6 位演员同台；女 / 男人数离散多选（「1 女」和「2 女」同时要）；导演可只看、也可整片排除，结果卡直接标导演名。</sub>
    </td>
  </tr>
  <tr>
    <td width="170" valign="top"><img src="docs/screenshots/gacha.png" width="150"></td>
    <td valign="top">
      <strong>② 抽卡</strong><br>
      <sub>一键把列表换成当前范围的随机剧照，改筛选即重抽，点图进详情。媒体库、收藏、分类墙、共演结果都能开，演员页的「盲盒」是同一个入口。</sub>
    </td>
  </tr>
  <tr>
    <td width="170" valign="top"><img src="docs/screenshots/facets.png" width="150"></td>
    <td valign="top">
      <strong>③ 分类体系</strong><br>
      <sub>标签、系列、制片商、发行商、导演五类都是能直接翻的入口；可收藏、可隐藏，导演与厂牌一行一条长图，靠作品认人。</sub>
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <img src="docs/screenshots/highlights.png" width="100%"><br>
      <strong>④ 亮点</strong><br>
      <sub>详情页给 6 张<em>本片</em>画面，右下角标时间，点哪张就从哪秒开始播；抽帧一次永久缓存，抽不到自动隐藏。</sub>
    </td>
  </tr>
</table>

## 其他功能

<table>
  <tr>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/home.png" width="120"><br><strong>首页</strong><br><sub>轮播、继续观看、每日推荐</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/library.png" width="120"><br><strong>媒体库</strong><br><sub>7 种排序、5 类叠加筛选</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/actors.png" width="120"><br><strong>演员</strong><br><sub>9 种排序、身材段筛选</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/detail.png" width="120"><br><strong>详情</strong><br><sub>版本前置、系列卡、标记</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/detail-stills.png" width="120"><br><strong>剧照</strong><br><sub>两列瀑布流、全屏浏览</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/blindbox.png" width="120"><br><strong>盲盒</strong><br><sub>抽卡的演员入口</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/search.png" width="120"><br><strong>搜索</strong><br><sub>三档联想、别名、历史</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/player-settings.png" width="120"><br><strong>播放器</strong><br><sub>结构化参数生成 mpv.conf</sub></td>
  </tr>
</table>

## 播放链路

<p align="center"><img src="assets/architecture.png" width="100%" alt="系统架构"></p>

- **块缓存**：读过的块留在内存（默认 320MB），拖动回看不回源。
- **并行预取**：提前读后续分段，网盘与冷区的首包更快。
- **mpv 硬解**：左右拖进度、竖直调亮度音量、0.75–2x 倍速、音轨字幕切换、退出记进度。
- **悬浮玻璃控制层**：视频从栏下透出，播放页两侧用封面晕出光晕。
- **参数锁定**：旧配置自动重置；诊断行看缓存秒数，一眼分清网络还是解码。
- **外挂字幕**：同目录 / 手机导入 / URL / 记住选择，四种编码自动转 WebVTT。

## 快速开始

| 01 · 部署旁挂服务 | 02 · 安装客户端 | 03 · 连接媒体库 |
|---|---|---|
| 在运行 Amane 的机器上 `cp deploy/.env.example .env` 填好 `AMANE_DATA` 与 `MEDIA_PATH_MAP`，`docker compose -f deploy/compose.example.yml up -d` | 从 [Releases](../../releases) 下载 HAP，用你自己的证书签名后安装，或用 Hokit 等侧载工具 | 「我的 → 连接设置」填 Amane 地址 `:8000`、用户服务地址 `:8770` 与 API token |

详细步骤见 [部署指南](docs/DEPLOY.md) 与 [签名安装](docs/BUILD_HAP.md)；不想手写配置，就把部署指南开头那段话发给 AI 助手，它会用 `tools/agentctl.py` 带你部署并验证。

## 文档

功能细节、逐项配置、排障都在 **[Wiki](https://github.com/dogmicats/Amane-Harmony/wiki)**。

仓库内另有：[部署](docs/DEPLOY.md) · [签名安装](docs/BUILD_HAP.md) · [字幕](docs/SUBTITLES.md) · [兼容性](docs/COMPATIBILITY.md) · [排障](docs/TROUBLESHOOTING.md) · [非鸿蒙设备](docs/ANDROID.md) · [README 设计规范](docs/DESIGN.md) · [AI 助手约定](AGENTS.md)。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上游 Amane 见 [CITATION.cff](CITATION.cff)。

非官方第三方项目，与上游无隶属关系；本仓库不含媒体内容、服务器地址或凭据。
