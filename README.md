# Amane-Harmony

自建 [Amane](https://github.com/sqzw-x/amane) 媒体库的**鸿蒙原生客户端**：媒体库与分类浏览、共演检索、收藏续播、网盘源流畅播放、外挂字幕——核心体验都在手机上完成。旁挂服务只是辅助：一个纯标准库的单文件服务，负责补齐筛选、字幕与播放代理这些 Amane 本体没有的能力。

<p align="center">
  <img src="docs/screenshots/home.png" width="196" alt="首页">
  <img src="docs/screenshots/library.png" width="196" alt="媒体库">
  <img src="docs/screenshots/detail.png" width="196" alt="详情">
  <img src="docs/screenshots/actors.png" width="196" alt="演员">
</p>

> 截图来自程序生成的虚构演示库（抽象海报、假番号、假人名），不含真实媒体。

## 功能

**演员**

- 网格筛选：性别、有头像、有资料、年龄段、身高段、罩杯段、胸围段、出生地，9 种排序
- 演员详情：资料、别名、写真、作品墙（可随机洗牌）
- 共演检索：指定最多 6 位演员，或按女 / 男 / 总人数区间找片；人数可离散多选（如「1 女或 2 女」），
  还能按导演「只看 / 排除」筛选，结果卡直接显示导演名
- 剧照盲盒：随机抽该演员作品的剧照（两列瀑布流按原图比例展示），点图直达对应影片；
  「再抽一次」本地池子瞬时换一批，不用等网络

**浏览**

- 首页：海报轮播、继续观看、每日推荐（真横图横幅，按原图比例展示）、每个库一行
- 媒体库：7 种排序、5 类筛选可叠加、三列网格滚动加载
- 分类：标签 / 系列 / 制片商 / 发行商 / 导演；缩略图铺卡（标签 / 系列三列瀑布，
  导演 / 制片商一行一条 8 张长图）；可收藏、标签可隐藏（数据不动，随时恢复）；
  排序含最近更新 / 最新发布（空值沉底）与随机（翻页顺序稳定，刷新才重摇）
- 搜索：输入即搜，联想三档递进（番号 / 标题精确 → 包含 → 演员 / 系列 / 制片商扩大），
  联想行直接进详情，也可进完整结果网格

**详情**

- 出演阵容、可点标签、所属系列（同系列作品可视化 + 3 张海报横排）
- 文件 / 版本区上移到剧照之前：多版本（4K / 1080p / 分段）选完直接播，不用滚几屏
- 剧照两列瀑布流（按真实宽高比占位，竖版海报不裁切、全量铺开）与全屏浏览、评价
- 列表与详情标注无码 / 破解 / 流出 / 中字

**播放**

- mpv 内核硬解；拖拽调进度、竖直调亮度音量、双击暂停、0.75–2x 倍速、音轨字幕切换、退出记进度
- 网盘 / 冷区源播放优化：块缓存 + 并行预取，拖动回看不回源，seek 风暴型文件也能连续播放
- 悬浮玻璃控制层与底部玻璃胶囊标签栏，视频从栏下透出；播放页两侧以封面高斯模糊晕出光晕
- 播放参数内置锁定：设备上的旧配置自动重置为可用默认，不被历史调参顶掉；
  诊断行显示缓存秒数（贴 0 = 网络跟不上，有积压还卡 = 解码跟不上）
- 外挂字幕：视频同目录、手机导入、手动 URL、记住每部片的选择
- 播放器设置：缓存、硬解、渲染选项生成 `mpv.conf`

**其他**

- 收藏跨设备一致；历史显示进度与剩余时长、点击续播、左滑删除
- 内嵌 Amane 网页，刮削与入库仍在原处完成

## 安装

**1. 部署旁挂服务**

在运行 Amane 的那台机器上（或能访问同一个 data 目录的机器）：

```sh
cp deploy/.env.example .env    # 填 AMANE_DATA 与 MEDIA_PATH_MAP
docker compose -f deploy/compose.example.yml up -d
curl http://127.0.0.1:8770/api/user/ping
```

不想手写配置，就把 [docs/DEPLOY.md](docs/DEPLOY.md) 开头那段话发给 AI 助手，它会用 `tools/agentctl.py` 带你部署并验证。

**2. 装 App**

从 [Releases](../../releases) 下载 `Amane-2.3.0-unsigned.hap`，用你自己的证书签名后安装，或用 Hokit、小白调试助手等侧载工具。步骤见 [docs/BUILD_HAP.md](docs/BUILD_HAP.md)。

**3. 填连接信息**

「我的 → 连接设置」：Amane 地址 `:8000`、用户服务地址 `:8770`、API token。

## 文档

功能细节、逐项配置、排障都在 **[Wiki](https://github.com/dogmicats/Amane-Harmony/wiki)**。

仓库内另有：[部署](docs/DEPLOY.md)、[签名安装](docs/BUILD_HAP.md)、[字幕](docs/SUBTITLES.md)、[兼容性](docs/COMPATIBILITY.md)、[排障](docs/TROUBLESHOOTING.md)、[非鸿蒙设备](docs/ANDROID.md)、[AI 助手约定](AGENTS.md)。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上游 Amane 见 [CITATION.cff](CITATION.cff)。

非官方第三方项目，与上游无隶属关系；本仓库不含媒体内容、服务器地址或凭据。
