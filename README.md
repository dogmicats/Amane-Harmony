<p align="center">
  <img src="assets/hero-banner.jpg" alt="Amane-Harmony" width="100%">
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

## 有趣的功能

<table>
  <tr>
    <td width="33%" valign="top">
      <img src="docs/screenshots/cast-finder.png" width="210"><br>
      <strong>① 共演检索</strong><br>
      <sub>想看导演 × 演员的合作、想看某几个人同台（男女、女女、男男都行）、还是就想找人多的大场面？一个筛选器全包：最多 6 位演员，「1 女 + 2 男」这种配比也能直接指定。<br><strong>离散人数多选 · 导演可包含可排除</strong></sub>
    </td>
    <td width="33%" valign="top">
      <img src="docs/screenshots/gacha.png" width="210"><br>
      <strong>② 抽卡</strong><br>
      <sub>片荒、列表翻到麻木的时候别选了——整屏随机剧照瀑布流，看上哪张看哪张；从媒体库到收藏、从演员的全部作品到搜索结果，任意清单都能抽。<br><strong>不满意随时重抽 · 全站清单通用</strong></sub>
    </td>
    <td width="33%" valign="top">
      <img src="docs/screenshots/facets.png" width="210"><br>
      <strong>③ 分类体系</strong><br>
      <sub>Emby 连一个能翻的演员墙都没有——想看某个人的全部作品，得进设置翻 metadata 里的 people 文件夹自己导出来。标签管理更是混乱的鸡肋功能。这里演员、标签、系列、制片厂、导演都是能直接翻的墙，视图多变，保你好看。<br><strong>多类入口 · 优化布局 · 横幅生成 · 可隐藏、可收藏</strong></sub>
    </td>
  </tr>
</table>

<p><img src="docs/screenshots/frame-picks.png" width="460"></p>

④ **亮点**　自动生成带时间点的本片画面，点哪张从哪秒开始播；观看时随手截的帧也能插进亮点。后台管理列着你所有的截图，点一下直接空降你最爱的场景，再也不用盯着剧照拉进度条。

⑤ **播放体验**　用腻了旧 Emby 式播放器的古早操作逻辑？这里换成 B 站客户端那套：详情页原地起播，小窗 / 全屏 / 横屏随手切，退出记着进度；倍速、手势、亮度音量都在手边。<br><strong>原地起播 · 三态窗口 · 记住进度</strong>

⑥ **弹幕与评价**　对整部片想锐评？看到一半想说点啥？增加了弹幕与评价功能。连接 Amane 的评价数据库，你的评价也能提交；看到一半还可以随时发送弹幕，锐评场景。飞行式滚动、样式可调，支持后台查看并管理所有你自己的弹幕和评价，点击一键跳转详情页。

<p><img src="docs/screenshots/cast-age-wide.png" width="100%"></p>

⑦ **出演年龄**　演员行标着出演本片时的岁数，点一下岁数就翻同龄的片，结果还能按女优 / 男优年龄排序。那年，她多大？

<p><img src="docs/screenshots/prefix.png" width="460"></p>

⑧ **元数据价值最大化**　同一批元数据能干的活不少：系列按属性筛、制片厂按番号前缀连着翻、演员按年龄和身材当索引。想找的很好找，不知道看什么让抽卡推，看对眼的就一路看下去。<br><strong>系列属性 · 番号前缀 · 一路翻片</strong>

⑨ **打分**　1–5 星，配菜、有意思、对味、反复、社保——JAV 也有自己的从夯到拉：一眼看出这部片在你心里什么位置，顺手还能留句锐评。

## 完善的基础功能

<table>
  <tr>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/home.png" width="120"><br><strong>首页</strong><br><sub>想放啥放啥 · 继续观看 · 每日推荐</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/library-250.png" width="120"><br><strong>媒体库</strong><br><sub>7 种排序 · 5 类筛选 · 抽卡</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/actors.png" width="120"><br><strong>演员</strong><br><sub>身材 · 年龄 · 收藏</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/detail.png" width="120"><br><strong>详情</strong><br><sub>一切信息 · 大众点评 · 相似影片</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/detail-stills.png" width="120"><br><strong>剧照</strong><br><sub>瀑布流 · 标记喜爱 · 尽收眼底</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/filter-sheet.png" width="120"><br><strong>筛选</strong><br><sub>想怎么筛就怎么筛</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/search.png" width="120"><br><strong>搜索</strong><br><sub>三档联想 · 别名 · 历史</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/player-settings.png" width="120"><br><strong>播放器</strong><br><sub>内置 mpv · 倍速 · 手势 · 小窗</sub></td>
  </tr>
</table>

<sub>演员墙按身材和年龄挑：从娇小到丰满、从人妻到 JK，总有一款对味；想挑奶狗或大叔也不是不行。</sub>

<sub>多清单 · 稍后再看 · 统一列表版式 · 设置分块 · 全矢量图标 · 横竖屏切换不抖动</sub>

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
