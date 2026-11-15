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
  <strong>发现下一部好片，<br>留住每一次精彩。</strong><br>
  想找谁就认真找，没主意就刷一刷；看对眼的，从详情看到精彩，再留给下一次重逢。
</p>

<p align="center"><sub>共演检索 · 随机抽卡 · 丰富详情 · 记录回看</sub></p>

<p align="center"><sub><strong>2.7.2</strong>　刷一刷的手感修好了 · 服务端能在 App 里一键升级<br><strong>这一版要手动更新一次</strong>：服务端重新部署、手机装新包，之后才走半自动。</sub></p>

> 把自己的 Amane 媒体库带到 HarmonyOS。沿着演员与共演找片，让随机剧照带来惊喜；打开详情了解阵容、选择版本，再把精彩画面、评分和观看记录留下来。2.7.0 让首页往右滑就能翻自己的片段，首页范围也能自己组合；2.7.2 把刷一刷的手感修了，并让服务端以后能在 App 里升级。

> [!IMPORTANT]
> **升到 2.7.2 这一步必须手动做一次。** 服务端按「快速开始」重新部署一遍、手机装一次新包；
> 装好之后「检查更新」里就会出现「升级服务器」按钮，以后**服务端**的更新在 App 里点一下就行
> （手机端仍需下载安装包自己装 —— 鸿蒙不允许应用商店外自动安装）。
> 旧版本没有这套逻辑，**不能**指望它自己升上来。

> 截图取自作者自建媒体库；封面、横幅与剧照已打码，演员头像保留原样。

<p align="center"><sub>面向已有 Amane 媒体库的 HarmonyOS NEXT 手机用户，需部署旁挂服务并自行签名安装。<br><strong>客户端与旁挂服务请一并手动升级到 2.7.2</strong>（这一版是最后一次「两边都要手动」的更新）。<a href="docs/START.md">从零开始</a> · <a href="../../releases">下载</a></sub></p>

## 有趣的功能

<table>
  <tr>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/cast-finder.png" width="210"><br>
      <strong>① 共演检索</strong>
    </td>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/gacha.png" width="210"><br>
      <strong>② 抽卡</strong>
    </td>
    <td width="33%" align="center" valign="top">
      <img src="docs/screenshots/facets.png" width="210"><br>
      <strong>③ 分类体系</strong>
    </td>
  </tr>
</table>

① **共演检索**　想看导演 × 演员的合作、想看某几个人同台（男女、女女、男男都行）、还是就想找人多的大场面？一个筛选器全包：最多 6 位演员，「1 女 + 2 男」这种配比也能直接指定。<br><strong>离散人数多选 · 导演可包含可排除</strong>

② **抽卡**　片荒、列表翻到麻木的时候别选了——整屏随机剧照瀑布流，看上哪张看哪张；从媒体库到收藏、从演员的全部作品到搜索结果，任意清单都能抽。<br><strong>不满意随时重抽 · 全站清单通用</strong>

③ **分类体系**　Emby 连一个能翻的演员墙都没有——想看某个人的全部作品，得进设置翻 metadata 里的 people 文件夹自己导出来。标签管理更是混乱的鸡肋功能。这里演员、标签、系列、制片厂、导演都是能直接翻的墙，视图多变，保你好看。<br><strong>多类入口 · 优化布局 · 横幅生成 · 可隐藏、可收藏</strong>

<p><img src="docs/screenshots/highlights-crop.png" width="460"></p>

④ **亮点**　自动生成带时间点的本片画面，点哪张从哪秒开始播。观看时随手截的帧，也能插进亮点。

**截帧与回看**　后台管理列着你所有的截图，点一下直接空降你最爱的场景，再也不用盯着剧照拉进度条。

⑤ **播放体验**　用腻了旧 Emby 式播放器的古早操作逻辑？这里换成 B 站客户端那套：详情页原地起播，小窗 / 全屏 / 横屏随手切，退出记着进度；倍速、手势、亮度音量都在手边。<br><strong>原地起播 · 三态窗口 · 记住进度</strong>

⑥ **弹幕与评价**　对整部片想锐评？看到一半想说点啥？评价留给整部片，弹幕留给那个瞬间；发过的都能回头查看、管理，点一下就回到详情页。<br><strong>飞行弹幕 · 样式可调 · 评价管理</strong>

<p><img src="docs/screenshots/detail-age-crop.png" width="460"></p>

⑦ **出演年龄**　演员行标着出演本片时的岁数，点一下岁数就翻同龄的片，结果还能按女优 / 男优年龄排序。那年，她多大？

<p><img src="docs/screenshots/prefix.png" width="460"></p>

⑧ **元数据价值最大化**　同一批元数据能干的活不少：系列按属性筛、制片厂按番号前缀连着翻、演员按年龄和身材当索引。想找的很好找，不知道看什么让抽卡推，看对眼的就一路看下去。<br><strong>系列属性 · 番号前缀 · 一路翻片</strong>

⑨ **打分**　1–5 星，配菜、有意思、对味、反复、社保——JAV 也有自己的从夯到拉：一眼看出这部片在你心里什么位置，顺手还能留句锐评。

<p><img src="docs/screenshots/stats-crop.png" width="520"></p>

⑩ **观看统计**　看过不少，回头却只记得几张海报？把这台设备记录的观看次数、时长、趋势和偏好放到一起，看看最近把时间花在了哪里。记录还少时会提醒「还在积累」，不用把空白当成结论。<br><strong>观看概览 · 趋势回看 · 偏好榜</strong>

<p><img src="docs/screenshots/tier-board.png" width="460"></p>

⑪ **从夯到拉**　打过的星，值得排出来看看。把个人评分生成五档座次图，筛一筛想放在一起比较的作品，再把这一刻的选择保存下来。以后口味变了，重新生成就是另一张记录。<br><strong>五档座次 · 条件筛选 · 导出图片</strong>

<p><img src="docs/screenshots/search-alias-crop.png" width="460"></p>

⑫ **搜索认俗称**　名字记得住，写法却不一定记得准。拼音首字母、繁简写法和俗称一起帮你找；还没对应上的叫法，可以加入自己的别名，下次想起它时，用熟悉的名字继续找。<br><strong>拼音首字母 · 写法归一 · 别名维护</strong>

<a id="shorts"></a>

<p><img src="docs/screenshots/shorts-main.png" width="460"></p>

⑬ **刷一刷**　列表翻累了？首页往右一滑，看看自己的片库里还有什么没留意。一条一个片段，合口味就点个心，回头去「我的喜爱」接着看。<br><strong>右滑开刷 · 片段翻看 · 喜爱回看</strong>

<sub>面向符合条件的本地盘影片；点心只记在这台手机上，和正片收藏分开。</sub>

<p><img src="docs/screenshots/liked-list.png" width="460"></p>

<sub>「我的喜爱」存的是你点过心的片段，点一条就能回到那个位置。</sub>

<a id="home-scope"></a>

<p><img src="docs/screenshots/home-scope.png" width="460"></p>

⑭ **首页自己挑**　刚打开就想看看没看过的，还是专挑自己收藏的？把库、观看状态、年份、标签和演员条件组合好，首页按这个范围换一批。<br><strong>范围自己定 · 下拉换一批</strong>

<p><img src="docs/screenshots/backup.png" width="460"></p>

⑮ **备份与恢复**　攒了那么久的收藏、评分和清单，搬家也想带着走。先看匹配结果，再挑要导的记录。<br><strong>导入先预览 · 按类挑记录</strong>

<sub>支持的类别以界面为准：收藏、评分、历史、稍后再看与清单；按番号匹配，没对上的记录要自己看一眼。</sub>

## 完善的基础功能

<table>
  <tr>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/home.png" width="120"><br><strong>首页</strong><br><sub>想放啥放啥</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/library-250.png" width="120"><br><strong>媒体库</strong><br><sub>7 种排序 · 抽卡</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/actors.png" width="120"><br><strong>演员</strong><br><sub>身材 · 年龄 · 收藏</sub></td>
    <td width="25%" align="center" valign="top"><img src="docs/screenshots/detail.png" width="120"><br><strong>详情</strong><br><sub>一切信息 · 大众点评</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/detail-stills.png" width="120"><br><strong>剧照</strong><br><sub>喜欢就收起来</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/filter-sheet.png" width="120"><br><strong>筛选</strong><br><sub>想怎么筛就怎么筛</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/search.png" width="120"><br><strong>搜索</strong><br><sub>联想 · 别名 · 拼音繁体</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/player-settings.png" width="120"><br><strong>播放器</strong><br><sub>内置 mpv · 倍速 · 手势</sub></td>
  </tr>
</table>

<sub>演员墙按身材和年龄挑：从娇小到丰满、从人妻到 JK，总有一款对味；想挑奶狗或大叔也不是不行。</sub>

想看的先放进**稍后再看**，喜欢的分进自己的**清单**；这次没看完，下次接着看。

<sub>多清单 · 稍后再看 · 自建标签与系列 · 手机编辑信息 · 8 套主题 · 列数可调 · 首页编排 · 空间管理 · 检查更新 · 设置分块 · 全矢量图标 · 导出日志</sub>

## 播放链路

<details>
<summary>想看看它怎么播得顺？展开看播放链路</summary>

<p align="center"><img src="assets/architecture.png" width="100%" alt="系统架构"></p>

- **块缓存**：读过的块留在内存（默认 320MB），拖动回看不回源。
- **并行预取**：提前读后续分段，网盘与冷区的首包更快。
- **mpv 硬解**：左右拖进度、竖直调亮度音量、0.75–2x 倍速、音轨字幕切换、退出记进度。
- **悬浮玻璃控制层**：视频从栏下透出，播放页两侧用封面晕出光晕。
- **参数锁定**：旧配置自动重置；诊断行看缓存秒数，一眼分清网络还是解码。

</details>

- **外挂字幕**：同目录 / 手机导入 / URL / 在线搜索，记住每部片的选择；多种常见编码自动转 WebVTT。

## 快速开始

**完全不懂怎么装？看 [从零开始（傻瓜版）](docs/START.md)** —— 每一步都写了「做什么 / 看到什么算成功 / 不对怎么办」，装服务、签名装 App、连库、以后怎么更新都在里面。

已经知道自己在干什么的，按三步走：

1. **部署旁挂服务**　在运行 Amane 的机器上 `cp deploy/.env.example .env`，填好 `AMANE_DATA` 与 `MEDIA_PATH_MAP`，再 `docker compose -f deploy/compose.example.yml up -d`。
2. **安装客户端**　从 [Releases](../../releases) 下载 HAP，用你自己的证书签名后安装，或交给 Hokit 这类侧载工具。
3. **连接媒体库**　「我的 → 连接设置」填 Amane 地址 `:8000`、用户服务地址 `:8770` 与 API token。

详细步骤见 [部署指南](docs/DEPLOY.md) 与 [签名安装](docs/BUILD_HAP.md)；不想手写配置，就把部署指南开头那段话发给 AI 助手，它会用 `tools/agentctl.py` 带你部署并验证。

### 2.7.2 之后怎么更新

**这一次（升到 2.7.2）还是老办法**：服务端按上面三步重新部署一遍、手机装一次新包。原因是升级逻辑本身就在这一版里，
旧服务端不认识它。

**从 2.7.3 起就省事了**：

1. 手机打开「我的 → 检查更新」，服务端有新版本时会出现**「升级服务器」**按钮，点一下自己下载、校验、切换、重启，全程有进度条。
2. 升级包落在服务端的数据卷 `<数据目录>/app`，**原来的 compose 不用改**，重建容器也不会把升级冲掉；升级失败或连续两次起不来自动退回上一版。
3. **手机端仍然要下载安装包自己装**——鸿蒙不允许应用商店外自动安装，这条改不了。

前提两条：服务端能访问 `github.com`（下载升级包）；服务的数据目录可写（默认挂载就是可写，除非你自己改成了 `:ro`）。

## 文档

功能细节、逐项配置、排障都在 **[Wiki](https://github.com/dogmicats/Amane-Harmony/wiki)**。

- 第一次装：[部署指南](docs/DEPLOY.md) · [签名安装](docs/BUILD_HAP.md)
- 已经有旧版：[升级服务端](docs/UPGRADE.md)（含一段可以直接发给 AI 助手的提示词）
- 使用与排错：[字幕](docs/SUBTITLES.md) · [兼容性](docs/COMPATIBILITY.md) · [排障](docs/TROUBLESHOOTING.md) · [非鸿蒙设备](docs/ANDROID.md)
- 维护与贡献：[README 设计规范](docs/DESIGN.md) · [AI 助手约定](AGENTS.md)

## 交流

- **[讨论群](https://t.me/+uYKKwB9LtjMxYTY9)** —— 装不上、用着别扭、想加什么功能，都在这儿说
- **[更新频道](https://t.me/+iEyg1f5Q_6UxYjY1)** —— 只发版本更新，不闲聊

版本发布后会自动往更新频道推一条（标题 + 本次更新摘要 + Release 链接）。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上游 Amane 见 [CITATION.cff](CITATION.cff)。

非官方第三方项目，与上游无隶属关系；本仓库不含媒体内容、服务器地址或凭据。
