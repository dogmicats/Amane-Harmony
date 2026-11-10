# README 视觉设计规范

> 面向本仓库所有会话与贡献者。**改 README、换截图、做配图之前先读本文件。**
> 目标：README 是产品主页，第一屏讲清「这是什么 + 三个亮点」，其余交给截图和 Wiki。

## 1. 风格

- GitHub 原生主题：正文颜色一律交给 GitHub（Light / Dark 都成立），**不要**用内联 CSS 改页面底色。
- 强调色只出现在图片里：背景 `#0A0A16`，紫 `#8B5CF6`，蓝 `#536DFE`。
- 字体、字号、行距不手写——用 Markdown 语义层级（`##` 一级分区，`**粗体**` 做卡片标题）。

## 2. 页面结构（顺序固定）

1. **Hero**：`assets/hero-banner.png`，1600×650，左侧品牌与一句话价值，右侧三张真实界面。
2. **Badges**：Releases / HarmonyOS / ArkTS / mpv / Python / License，六个以内。
3. **一句话定位 + 截图声明**：客户端做什么、旁挂服务补什么；紧跟一行「截图取自作者自建库，封面、横幅与剧照已打码」。
4. **界面预览**：4 张（首页 / 媒体库 / 演员 / 详情），一行放完。
5. **核心能力**：3 张卡片（媒体库与分类、演员与共演、详情与续播），每张 = 一张截图 + 一句功能 + 一句细节。
6. **播放链路**：`assets/architecture.png` + 3–4 条短句（块缓存、并行预取、硬解、旁挂服务）。
7. **快速开始**：三步表格（部署服务 / 安装客户端 / 连接媒体库），细节链去 `docs/`。
8. **文档**：Wiki 在前，仓库内文档一列排完。
9. **许可**：MIT + 非官方声明。

## 3. 图片策略（2026-11-10 起）

**不再使用抽象占位海报或 AI 生成的假 UI。** 界面截图必须来自真实运行的程序。

| 画面内容 | 处理方式 |
|---|---|
| 演员列表、演员详情、头像、演员名与资料 | **真实截图**，不打码 |
| 封面 / 海报、横幅、剧照、系列与分类缩略图 | **真实截图 + 打码**（像素化马赛克，长边约 26 格） |
| 数字、番号、标记、标题、标签等 UI 文字 | 保留真实值 |

做法：客户端连真实媒体库，所有图片请求走一个本地像素化代理（除演员头像外的图片统一缩到极小再放大回去），代理之后的截图不需要再后期修图；**不要**逐张手画矩形遮挡，容易漏、也对不上圆角。

生成 Hero 与配图时，只允许拼接真实截图 + 真实 App 图标，禁止用 AI 生成界面。

## 4. 截图清单

| 文件 | 用途 |
|---|---|
| `docs/screenshots/home.png` | Hero、界面预览、核心能力 |
| `docs/screenshots/library.png` | 界面预览、核心能力 |
| `docs/screenshots/actors.png` | 界面预览、Hero |
| `docs/screenshots/detail.png` | 界面预览、核心能力、Hero |
| `docs/screenshots/cast-finder.png` | 核心能力（共演检索） |
| `docs/screenshots/search.png` | 其他能力一栏 |
| `docs/screenshots/facets.png` | 其他能力一栏（导演 = 一行一条长图版式） |
| `docs/screenshots/actor-detail.png` | 其他能力一栏 |
| `docs/screenshots/player-settings.png` | 其他能力一栏 |
| `docs/screenshots/library-filter.png` · `facet-media.png` · `detail-stills.png` · `favorites.png` | Wiki |

规格：720×1507 PNG，状态栏已裁掉，宽度统一；新增截图沿用同一尺寸，别混入不同比例。

## 5. 实现约束

- 只用 GitHub 原生 Markdown / HTML：`<p align="center">`、`<table>`、`<img width>`、`<details>`。不要外部 CSS / JS。
- 表格只用来排截图与短卡片，**不要**用表格承载长正文。
- 手机截图一行 3–4 张；不要一屏塞 6 张。窄屏下不能出现横向滚动。
- 正文文字不进图片（Hero 的标题除外），否则 Light / Dark 主题下会失衡。
- 不夸大功能：文案只描述代码里真实存在的行为，新增能力先合代码再上图。

## 6. 验收

- 首屏不滚动就能看懂：这是 HarmonyOS 原生 Amane 客户端，以及两三项最核心的价值。
- 每张截图都能对应到 README 里的一句话；没有「图里有、文中无」的功能暗示。
- 封面全部已打码，演员头像清晰；没有任何真实地址、token 或凭据入镜。
- GitHub Light / Dark、桌面 / 手机宽度下均无溢出。
