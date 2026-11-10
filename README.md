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

自建 [Amane](https://github.com/sqzw-x/amane) 媒体库的**鸿蒙原生客户端**，媒体库与分类浏览、共演检索、收藏续播、外挂字幕都在手机上完成；附带辅助用的旁挂服务：一个纯标准库的单文件服务，负责补齐筛选、字幕与播放代理这些 Amane 本体没有的能力。

> 截图取自作者自建媒体库，代表界面与真实数据；封面、横幅与剧照已统一打码处理。

## 四件别处没有的

通用客户端（Emby / Jellyfin 官方 App、Findroid、Streamyfin 这一类）把「播放 + 下载 + 投屏」做得很熟，但它们面对的是电影和剧集：一条元数据就是一部片。这个库不是那样组织的，所以下面四件事只能自己做。

<table>
  <tr>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/cast-finder.png" width="150"><br>
      <strong>共演检索：按人数和导演找片</strong><br>
      <sub>指定最多 6 位演员同台；女 / 男人数可离散多选（「1 女」和「2 女」同时要）；导演能「只看这几位」也能整片排除，结果卡直接标导演名。别处只有「这个演员的作品」，没有这种组合条件。</sub>
    </td>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/gacha.png" width="150"><br>
      <strong>抽卡：把列表换成这一范围的随机剧照</strong><br>
      <sub>媒体库、收藏、分类影片墙、共演结果都能开；抽的范围就是当前筛出来的那批，改条件立刻重抽，点图直接进详情。别处的随机只能随机「影片」，随不到「画面」。</sub>
    </td>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/blindbox.png" width="150"><br>
      <strong>剧照盲盒：按演员洗牌</strong><br>
      <sub>挑一位演员，随机抽她作品里的剧照铺成两列瀑布流，点图直达对应影片；「再抽一次」在本地池里瞬时换一批，不用等网络。通用客户端没有这种「翻着看」的入口。</sub>
    </td>
  </tr>
</table>

<table>
  <tr>
    <td width="100%" valign="top">
      <img src="docs/screenshots/highlights.png" width="100%"><br>
      <strong>亮点：点哪张，从哪一秒开始播</strong><br>
      <sub>详情页给 6 张<em>这部片自己的</em>画面（从视频按时间均匀抽帧），右下角标着时间，点哪张就从那一秒起播；网盘库首次现场抽帧后永久缓存，抽不到（没装 ffmpeg 等）就整块隐藏。Jellyfin 的 trickplay 只作用于进度条拖动预览，而且要在库里预生成，不在详情页。</sub>
    </td>
  </tr>
</table>

## 其余能力

<table>
  <tr>
    <td width="25%" valign="top">
      <img src="docs/screenshots/home.png" width="120"><br>
      <strong>首页</strong><br>
      <sub>海报轮播、继续观看、每日推荐、每个库一行。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/library.png" width="120"><br>
      <strong>媒体库</strong><br>
      <sub>7 种排序、5 类可叠加筛选，工具栏显示生效条数；三列网格滚动加载。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/facets.png" width="120"><br>
      <strong>分类</strong><br>
      <sub>标签 / 系列 / 制片商 / 发行商 / 导演；可收藏、可隐藏恢复；导演与厂牌一行一条长图。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/actors.png" width="120"><br>
      <strong>演员</strong><br>
      <sub>9 种排序，按性别、有头像、年龄段、身高 / 罩杯 / 胸围段筛选。</sub>
    </td>
  </tr>
  <tr>
    <td width="25%" valign="top">
      <img src="docs/screenshots/detail.png" width="120"><br>
      <strong>详情</strong><br>
      <sub>版本选择前置、所属系列卡、可点标签、出演阵容；标注无码 / 破解 / 流出 / 中字。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/detail-stills.png" width="120"><br>
      <strong>剧照</strong><br>
      <sub>两列瀑布流，按真实宽高比占位、全量铺开，可全屏浏览。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/search.png" width="120"><br>
      <strong>搜索</strong><br>
      <sub>输入即联想三档，支持演员别名；历史搜索存服务端，留最近 30 条。</sub>
    </td>
    <td width="25%" valign="top">
      <img src="docs/screenshots/player-settings.png" width="120"><br>
      <strong>播放器设置</strong><br>
      <sub>缓存、硬解、渲染、拖动响应做成结构化选项，生成 `mpv.conf`。</sub>
    </td>
  </tr>
</table>

## 为网盘与冷区资源优化的播放链路

<p align="center"><img src="assets/architecture.png" width="100%" alt="系统架构"></p>

- **块缓存**：读过的数据块按 1MiB 缓存在内存（LRU，默认 320MB），拖动回看不再回源。
- **并行预取**：后台提前读后续分段，冷区首字节等待被多个块摊掉。
- **mpv 内核硬解**：左右拖进度、竖直调亮度 / 音量、双击暂停、0.75–2x 倍速、音轨字幕切换，退出记进度。
- **播放界面**：悬浮玻璃控制层，视频从栏下透出；播放页两侧用封面高斯模糊晕出光晕；底部标签栏同款玻璃胶囊。
- **参数锁定**：设备上的旧配置自动重置为可用默认，不被历史调参顶掉；诊断行显示缓存秒数 —— 贴 0 是网络跟不上，有积压还卡是解码跟不上。
- **外挂字幕**：视频同目录、手机文件导入、手动 URL、记住每部片的选择；UTF-8 / GB18030 / Shift-JIS / BIG5 自动识别转 WebVTT，同目录扫描只读不递归。

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
