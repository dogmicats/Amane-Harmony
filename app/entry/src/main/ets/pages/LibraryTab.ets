import { curves } from '@kit.ArkUI';
import { BuildConfig } from '../common/BuildConfig';
import { ImmersiveGlass } from '../common/ImmersiveGlass';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { LibraryInfo } from '../common/Types';
import { BrowseGrid, TAB_SAFE } from '../view/BrowseGrid';
import { GlassIcon, GlassSearchBar } from '../view/GlassKit';

/** 媒体库 Tab：顶部一条玻璃工具条（浮在内容上）+ 浏览网格。 */

/** 顶栏高度（vp）。2026-11-17 九改起**恒为这一个高度**，不再随滚动变矮。 */
const BAR_H: number = 46;
/** 搜索浮卡的总高（42 的胶囊 + 上下各 3）—— 展开到位后就是这么多。 */
const SEARCH_ROW_H: number = 48;
/** 顶栏圆角（vp）。整条是一块悬浮玻璃，圆角 = 高度的一半才是「胶囊」。 */
const BAR_R: number = BAR_H / 2;
/** 顶栏离物理屏顶（含状态栏）的距离。 */
const BAR_TOP: number = 6;

/**
 * 第一排海报顶部钻进顶栏的深度（2026-11-17 十八改：18 → 30）。
 *
 * 这是「玻璃看着像不像玻璃」的**一半原因**，以前一直没被当回事：
 * 材质的工作是「采样底下的画面、把它的颜色模糊了再吐出来」。顶栏 46vp 高，
 * 只探进 18vp 的时候，上面 28vp 底下是页面底色（纯黑）—— 采样到黑，吐出来还是黑，
 * 屏幕上看就是「一层什么都没画的透明片」，跟参数一点关系都没有。
 * 探进 30 之后，顶栏底下 2/3 都有海报，颜色才散得开。
 *
 * 不再往大调的原因：再深就把海报顶部压得太多，点不到了（七改的教训）。
 */
const HEAD_PEEK: number = 30;
/**
 * 标题栏（`HdsNavigationTitleMode.MINI`）的高度（vp）—— **实测值，不是文档值**。
 *
 * 真机日志：顶栏内容行 30 高、起点 y=51.81，而状态栏 39 → 反推标题栏 = 39~95，
 * 即高度 56、内容在中间垂直居中（13 的内边距）。玻璃下沿那条亮线就画在
 * `topInset + 56` 上；README 里写 56，跟这里对得上，可以放心。
 */
const BAR_REGION_H: number = 56;

/**
 * 页面标题字号（2026-11-17 十改）。
 *
 * 九改是 16 —— 用户一眼看出来「有点小气，比边上胶囊的边框还矮」。
 * 它是整个页面的标题，得有标题的量级：20 加粗的字高约 27vp，
 * 和旁边那颗「库名 ▾」胶囊（12pt 字 + 5 上下内边距 ≈ 27vp）等高，看起来才是一行东西。
 */
const TITLE_SIZE: number = 20;

/**
 * 切库箭头（‹ ›）的命中宽度（2026-11-17 十改新增，十二改定稿）。
 *
 * 十一改曾把它改成 `Path` 矢量折线（9 × 16）—— 用户明确说「左右的标点符号本身是可以看的，
 * 你改过反而难看了」，所以**退回标点符号版本**，只把字号从 19 提到 20（一眼能认出是箭头，
 * 又不至于像按钮块那样挤占顶栏）。丑的是胶囊里那个「下拉」小三角，不是这两个。
 */
const ARROW_W: number = 16;

/** 顶栏内容的横向间隙（vp）。三十二改 6 → 8：拆块之后要的就是「松」。 */
const BAR_GAP: number = 8;

/** 右侧三颗小胶囊之间的间隙（vp）。比 BAR_GAP 略小，一眼能看出是「一组三颗」。 */
const RIGHT_GAP: number = 6;


@Component
export struct LibraryTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  /**
   * 当前生效的顶栏材质档位（0 无 / 1 弱 / 2 强 / 3 极限）。
   * 由 `ImmersiveGlass` 解析设备算力与用户偏好后写进 AppStorage，
   * 这里用 `@StorageProp` 订阅 —— 用户在外观设置里改一下，回到这页立刻换材质。
   *
   * 默认值 3 → 2（2026-11-17 十八改）：3 是 `ULTRA_THIN`，最薄的一档，
   * 配纯黑底的时候几乎完全隐形；万一 AppStorage 还没被 `ImmersiveGlass.init()` 写进去
   * （首帧早于 Index 的 aboutToAppear），就会拿这个默认值去建材质。
   * 用 2（THIN）当默认，最差情况也是一块看得见的玻璃。
   */
  @StorageProp('amaneGlass') glassLevel: number = 2;
  @State libs: LibraryInfo[] = Store.I.libraries;
  /**
   * 选中的库。空数组 = 全部（2026-11-15 用户要求多选：
   * 「让用户可以筛选同时出现在哪些媒体库的内容」，所以多选是 AND，不是并集）。
   */
  @State activeIds: number[] = [];
  /**
   * 上半屏横滑（2026-11-15）：Index 在 `onContentWillChange` 里拦下这次翻页，
   * 把「哪个页面该往哪走」写进这个 AppStorage 键 —— 形如 `lib|1|时间戳`。
   */
  @StorageProp('inPageSwipe') @Watch('onInPageSwipe') inPageSwipe: string = '';
  private lastSwipe: string = '';
  /**
   * 抽卡开关的唯一真相（2026-11-17 上提）：`@Link` 传给 BrowseGrid。
   * 之前两边各存一份，媒体库这边一改就触发重渲染、子组件状态回退，抽卡退不回来。
   */
  @State gachaOn: boolean = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
  /** 排序 / 筛选面板开关：顶栏那两个按钮驱动，面板本身还在 BrowseGrid 里弹。 */
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  /**
   * 顶栏上的两个「状态型」按钮（2026-11-17 七改）。
   *
   * 抽卡/筛选/排序这类按钮不该只写死两个字：
   *  - `filterOn`：有没有生效的筛选项（BrowseGrid 每次重载前报上来）；
   *  - `sortText` / `sortCustom`：当前排序依据，改过才显示（默认排序仍写「排序」）。
   */
  @State filterOn: boolean = false;
  @State filterCount: number = 0;
  @State sortText: string = '';
  @State sortCustom: boolean = false;
  /**
   * 顶栏搜索的关键词（2026-11-18 三十八改）。
   *
   * 真相放在这一层：顶栏的 `GlassSearchBar` 与 `BrowseGrid` 的 `keyword` 都读它。
   * 之所以不直接用 BrowseGrid 的 `keyword`，是因为顶栏在父组件里，
   * 子组件的 `@State` 父级读不到；这里下发给 `externalKeyword`，子组件用 `@Watch` 接。
   */
  @State keyword: string = '';
  /**
   * 顶栏搜索是否展开（2026-11-18 三十八改·二，六十改改成**浮层**）。
   *
   * 历史：三十八改·二把搜索放在标题栏第二行，标题栏高度 +48 —— 真机上「一展开整页内容
   * 就往下跳 48vp」，用户说「确实有点生硬」。所以六十改不再占标题栏高度，
   * 改成**压在内容上的一张浮卡**：标题栏恒 46，内容一帧都不动，卡从标题栏下沿抽出来。
   */
  @State searchOpen: boolean = false;
  /**
   * 搜索浮卡的展开进度 **0 → 1**（六十改）。
   *
   * 为什么另开一个数而不是直接用 `searchOpen`：条件渲染（`if`）只会「有」和「没有」两帧，
   * 中间没有任何可补间的量，这就是生硬的来源。这个数是唯一的动画驱动量，同时喂给
   * 高度 / 透明度 / 位移 / 横向缩放四条属性 —— 一个 animateTo 就能让它们同一节奏收放。
   */
  @State searchT: number = 0;
  /**
   * 网格的滚动控制器（2026-11-17）。
   * 两个用途：抽卡水墙/网格共用同一个实例；顶栏紧凑化的判断要读它的**绝对偏移**。
   */
  private gridSc: Scroller = new Scroller();
  /**
   * 导航栈（2026-11-17 十九改）。
   *
   * 媒体库是 Tab 的根页，栈里只有它自己 —— 建栈不是为了跳转，而是因为
   * **系统沉浸材质只承认两个落点：Navigation / NavDestination 的标题栏，
   * 以及 barPosition=End 的底部 TabBar**。官方原文：
   *
   *   「其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中 barPosition 为
   *     BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感效果不生效。」
   *
   * 我们之前把 `systemMaterial` 挂在自己 `Stack` 里的一个 `Column` 上 ——
   * 那是「其他区域」，**一片像素都不会有**。这就是为什么调了十几版都没效果，
   * 跟设备算力、跟参数全都无关。
   */
  private navStack: NavPathStack = new NavPathStack();
  /**
   * 顶栏 / 标题 / 右侧入口组的**实测宽度**（2026-11-17 七改）。
   *
   * 用户报「库名一长就把抽卡顶出屏幕」：Row 的子组件默认按内容宽度摆，
   * 总宽超了就直接溢出，右边那颗按钮就跑到屏幕外。
   * 九改去掉搜索入口后空间宽松了，但这套「量一次真实宽度」的算法保留 ——
   * 库名长短不可控，靠 flex 分配仍然是碰运气。
   */
  @State barW: number = 0;
  @State titleW: number = 0;
  @State actsW: number = 0;

  aboutToAppear(): void {
    this.libs = Store.I.libraries;
    // 诊断（2026-11-17 三十改）：顶栏材质挂在标题栏的胶囊上，判据见 Index 那条日志。
    // 三十一改加上 mode / level：出 THIN 对照包时要能从日志确认「档位真的换了」，
    // 不能靠肉眼看截图像不像（实测两档在这块屏上肉眼几乎分不出）。
    console.info(`[amane] topbar glass mode=${ImmersiveGlass.mode()} level=${this.glassLevel} ` +
      `${ImmersiveGlass.deviceLabel()}`);
  }

  onRefresh(): void {
    this.libs = Store.I.libraries;
  }

  /**
   * 点库 chip：切换这一个库的选中状态。
   * 点「全部」= 清空；再点已选中的最后一个也回到「全部」——
   * 否则会出现「一个都不选但看起来选了库」的歧义态。
   */
  private toggleLibrary(id: number): void {
    if (id <= 0) {
      this.activeIds = [];
      return;
    }
    const next: number[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.activeIds.length; i++) {
      const v: number = this.activeIds[i];
      if (v === id) {
        hit = true;
      } else {
        next.push(v);
      }
    }
    if (!hit) {
      next.push(id);
    }
    this.activeIds = next;
  }

  private isActive(id: number): boolean {
    if (id <= 0) {
      return this.activeIds.length === 0;
    }
    return this.activeIds.indexOf(id) >= 0;
  }

  /** Index 拦下翻页后发来的「切库」指令。 */
  onInPageSwipe(): void {
    const raw: string = this.inPageSwipe;
    if (raw.length === 0 || raw === this.lastSwipe) {
      return;
    }
    this.lastSwipe = raw;
    const parts: string[] = raw.split('|');
    if (parts.length < 2 || parts[0] !== 'lib') {
      return;
    }
    const dir: number = Number(parts[1]);
    if (dir === 1 || dir === -1) {
      this.swipeLibrary(dir);
    }
  }

  /**
   * 上半屏横滑 = 切库（2026-11-15）。多选时以「最后选中的那个库」为锚点往前后走，
   * 滑完回到单选 —— 滑动本质是「翻看下一个库」，不是继续加选。
   */
  private swipeLibrary(dir: number): void {
    const ids: number[] = this.libOrder();
    let at: number = ids.indexOf(this.anchorId());
    if (at < 0) {
      at = 0;
    }
    const next: number = at + dir;
    if (next < 0 || next >= ids.length) {
      return;
    }
    const target: number = ids[next];
    this.activeIds = target > 0 ? [target] : [];
  }

  /** 切库序列：`全部` 打头，后面按 Store 里的库顺序。 */
  private libOrder(): number[] {
    const ids: number[] = [0];
    for (let i = 0; i < this.libs.length; i++) {
      ids.push(this.libs[i].id);
    }
    return ids;
  }

  /** 滑动锚点：最后选中的那个库（没选 = 「全部」）。 */
  private anchorId(): number {
    return this.activeIds.length > 0 ? this.activeIds[this.activeIds.length - 1] : 0;
  }

  /**
   * 这个方向还能不能切（2026-11-17 十改）。
   * 顶栏那对 ‹ › 靠它决定「亮着可点」还是「到头了、压暗」——
   * 只做摆设的箭头会让人以为坏了，所以到边界必须看得出不可用。
   */
  private canSwipe(dir: number): boolean {
    const ids: number[] = this.libOrder();
    const at: number = ids.indexOf(this.anchorId());
    const next: number = at + dir;
    return at >= 0 && next >= 0 && next < ids.length;
  }

  // ------------------------------------------------------------------
  // 顶栏（2026-11-17 九改：恒为完整形态，滚动不再变矮/隐藏）
  // ------------------------------------------------------------------

  // ------------------------------------------------------------------
  // 顶栏
  // ------------------------------------------------------------------

  /** 是否挂着系统沉浸材质（否则走自绘兜底）。 */
  private glassOn(): boolean {
    return this.glassLevel > 0;
  }

  /**
   * 打开排序 / 筛选抽屉（2026-11-17 三十一改）。
   *
   * 抽屉自己带 `.transition()`（见 `ListSheets`），但**状态变更必须包在 animateTo 里**
   * 它才会真的动。曲线是官方 Spatialization 那颗弹簧，收尾带一点回弹。
   */
  private openSheet(which: string): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 288, 30) }, () => {
      if (which === 'sort') {
        this.showSort = true;
      } else {
        this.showFilter = true;
      }
    });
  }

  /**
   * 「库名 ▾」这颗胶囊最多能占多宽（2026-11-17 七改，九/十改调整）。
   *
   * = 顶栏宽 − 两块玻璃的内边距（12+8 与 6+6 = 32，再留 2 余量 → 34）
   *   − 标题实测宽 − 右侧入口组实测宽 − 两颗切库箭头 − 三处 6vp 间距 − 4 安全余量。
   * 第一帧还没量到时给 120（正常长度都装得下，量到后立刻收紧）。
   *
   * 下限 56：再窄就只剩省略号了，不如让它至少显示「全部」两个字。
   * 上限 150（原 96）：九改把「搜索」从这里拿掉，腾出来的位置就该给库名 ——
   * 用户的原话是「媒体库选择项很容易就变成省略号」，那就别让它那么容易省略。
   *
   * 十改加了切库箭头（2 × 16）＋标题从 16 涨到 20（宽 ≈ +12），
   * 两笔都从「库名可用宽度」里扣，所以右边一排仍然不会被顶出屏幕。
   */
  private nameChipMax(): number {
    if (this.barW <= 0) {
      return 120;
    }
    // 三十四改：`- 28` → 左边距压到 4 之后的 `- 16`（4 + 12）。
    const room: number = this.barW - 16 - this.titleW - this.actsW
      - ARROW_W * 2 - BAR_GAP * 3 - 4;
    if (room < 56) {
      return 56;
    }
    if (room > 150) {
      return 150;
    }
    return room;
  }

  @Builder
  Chip(id: number, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.isActive(id) ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.isActive(id) ? Theme.ACCENT_INK : Theme.TEXT_DIM)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.isActive(id) ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
      .borderRadius(Theme.R_PILL)
      .border({ width: 1, color: this.isActive(id) ? Theme.inkAlpha(0.50) : Theme.STROKE })
      .onClick(() => {
        this.toggleLibrary(id);
      })
  }

  /**
   * 顶栏的**内容行**（2026-11-17 十五改抽出，十七改定型）。
   *
   * 只画控件，**一点玻璃都不画** —— 玻璃由 `TopBar` 那个节点的系统材质提供。
   *
   * 左右内边距 14 / 10：玻璃自身的边（屏幕左右各 16）由 `TopBar` 外面的容器给，
   * 这里给的是「文字离玻璃边沿」的距离。右边小一点，因为那颗「抽卡」是实心胶囊，
   * 自带内边距，再给 14 会显得往里缩。
   *
   * 宽度预算 `barW` 量在**去掉内边距的内层** —— 否则可用宽度会多算 24vp，
   * 库名一长就把右边三个按钮顶出屏幕。
   */
  @Builder
  BarRow() {
    Row() {
      this.LeftGlass()
      // 中间的缝留给「贴边」：左块贴左、右三颗贴右，放大镜挂在右三颗左边。
      Blank()
      this.SearchTrigger()
      this.RightPills()
    }
    .width('100%')
    // ★ 2026-11-17 二十改：这里**必须是固定高度**，不能用 `height('100%')`。
    //
    // `title()` 传 CustomBuilder 时，标题栏的高度是「由内容测量出来的」——
    // 内容写 `100%` 就成了「我占父的 100%，父的高度由我决定」的循环依赖，
    // 系统拿到 0：**整条标题栏一个像素都不画**（用户看到的就是「整个标题栏都消失了」）。
    // 给死 46，标题栏就有 46 可量；`NavigationTitleMode.Mini` 的 56 里它会垂直居中。
    .height(BAR_H)
    // 左边 4 / 右边 12（2026-11-17 三十四改：左边距从 16 压到 4，胶囊尽可能贴左；
    // 三十五改把 4 从外层容器挪到这里 —— 外层要留给通栏的海报光晕）。
    .padding({ left: 4, right: 12 })
    .onAreaChange((o: Area, n: Area) => {
      this.barW = parseFloat(`${n.width}`);
      // 诊断（二十一改）：标题栏内容行到底落在屏幕的哪一行。
      // `globalPosition` 是相对窗口的绝对位置 —— 判断「有没有跟状态栏堆叠」看它，
      // 不要再靠截图目测。状态栏高度 = `amaneTopInset`，行的 y 必须 ≥ 它。
      console.info(`[amane] barRow y=${n.globalPosition.y} h=${n.height} w=${n.width}`);
    })
  }

  /**
   * 搜索触发器（2026-11-18 三十八改·二，六十改加**开关语义**）：第一行右侧那颗 42 见方的放大镜。
   *
   * 它**不展开**，只负责把浮卡拉出来 / 收回去 —— 第一行左右都被占死（左块要放库名、
   * 右三颗不可收缩），横向长不开。真正的输入框在浮层里，整宽。
   *
   * 六十改两件事：
   *   1. 展开态再点一次 = 收起（用户明确要求，和浮层里那颗放大镜同一语义）；
   *   2. 展开时它自己上主题色 —— 一颗「按下去变亮、再按变暗」的按钮，
   *      比任何额外的指示器都直接，而且不新增控件。
   */
  @Builder
  SearchTrigger() {
    GlassIcon({
      icon: $r('app.media.ic_search'),
      iconSize: 18,
      boxW: 42,
      boxH: 42,
      radius: 21,
      mat: true,
      tint: this.searchOpen ? Theme.accentAlpha(0.30) : '',
      onTap: () => {
        if (this.searchOpen) {
          this.closeSearch();
        } else {
          this.openSearch();
        }
      }
    })
      .margin({ right: RIGHT_GAP })
      // 上色是状态变化，给 160ms 过渡，别让它「啪」一下跳色
      .animation({ duration: 160, curve: Curve.EaseOut })
  }

  /**
   * 搜索浮卡（2026-11-18 六十改：从「标题栏第二行」改成「压在内容上的浮层」）。
   *
   * ── 为什么要浮层 ──────────────────────────────────────────────
   * 三十八改·二的写法是让标题栏高度 +48、第二行真占位。真机一展开，**整页内容往下跳 48vp**
   * ——用户的原话是「确实有点生硬」。那个跳不是曲线能救的：它跳的是布局，不是属性，
   * 无论给多好的弹簧，内容位移仍然是「瞬间发生」。
   * 所以改成：标题栏恒 46，这一层用 `.position()` 脱离布局流压在内容顶上，
   * 高度从 0 长到 48。**内容一帧都不动**，动的是这张卡。
   *
   * ── 空间动效的三条（一个 `searchT` 驱动，同一节奏）─────────────
   *   高度     0 → 48      纵向「抽出来」（这是形变主体）
   *   缩放 x   0.97 → 1    横向从略窄撑到满宽（形变收尾，别让它是「一块板」）
   *   位移 y  -10 → 0      从标题栏底下「降下来」，起点藏在玻璃后面
   *   透明度   0 → 1       边缘不硬切，尤其收起时不会看见一条黑边
   * 收起走反向、时长更短（220 vs 320）—— 「收」比「开」要快，这是手感上的普遍共识：
   * 用户想撤的时候，多等 100ms 就会被感知成卡。
   *
   * ── 为什么 `mat: false` ────────────────────────────────────────
   * 沉浸材质的落点只有标题栏和底部 TabBar（见 `GlassKit` 文件头，真机实测过两次）。
   * 这里是内容区，挂 `systemMaterial` 等于什么都没画；所以走兜底配方
   * `backgroundBlurStyle(COMPONENT_THICK)` + 12% 白 + 发丝亮边，和抽卡墙那颗置顶按钮同款。
   */
  @Builder
  SearchLayer() {
    Column() {
      Row() {
        GlassSearchBar({
          placeholder: '搜索番号 / 标题 / 演员 / 系列',
          // 与触发器同规格（42/21/18）：展开瞬间两者在视觉上是「同一颗」
          boxH: 42,
          rowH: 42,
          radius: 21,
          iconSize: 18,
          // 内容区没有沉浸材质，传 true 会变成一张全透明的空片
          mat: false,
          // 用父层的状态驱动展开态：这样点 ✕ / 点放大镜收起之后，
          // 下次展开时组件能重新自己开（`forceOpen` 真值变化才会触发内部 watch）
          forceOpen: this.searchOpen,
          onCommit: (kw: string) => {
            if (kw === this.keyword) {
              return;
            }
            this.keyword = kw;
          },
          // 浮层里那颗放大镜 / ✕ 收起 → 父层同步收回这张卡
          onClosed: () => {
            this.closeSearch();
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height(SEARCH_ROW_H)
      .padding({ left: 4, right: 12, top: 3, bottom: 3 })
    }
    .width('100%')
    .height(SEARCH_ROW_H * this.searchT)
    .clip(true)
    .opacity(this.searchT)
    .translate({ y: -10 * (1 - this.searchT) })
    .scale({ x: 0.97 + 0.03 * this.searchT, y: 1, centerX: '50%', centerY: 0 })
    // 压在标题栏正下方：y 用同一套算式，标题栏改了这里跟着改
    .position({ x: 0, y: this.topInset + BAR_H })
    .zIndex(10)
    // 收着的时候高度是 0，但子节点还在 —— 不关命中会让它挡掉顶上那一条海报的点击
    .hitTestBehavior(this.searchOpen ? HitTestMode.Default : HitTestMode.None)
  }

  /** 展开（六十改：唯一的入口，动画与状态一起改）。 */
  private openSearch(): void {
    if (this.searchOpen) {
      return;
    }
    this.searchOpen = true;
    this.getUIContext().animateTo(
      { duration: 320, curve: curves.interpolatingSpring(0, 1, 300, 26) }, () => {
        this.searchT = 1;
      });
  }

  /** 收起（比展开快；顺手清关键词，与 ✕ 的语义保持一致）。 */
  private closeSearch(): void {
    if (!this.searchOpen) {
      return;
    }
    this.searchOpen = false;
    // 收起就把条件撤掉：不然列表停在「只剩几条」的状态，用户会以为数据少了
    if (this.keyword.length > 0) {
      this.keyword = '';
    }
    this.getUIContext().animateTo(
      { duration: 220, curve: curves.interpolatingSpring(0, 1, 320, 34) }, () => {
        this.searchT = 0;
      });
  }

  /**
   * **左块玻璃**（2026-11-17 三十一改：整条拆成左右两块）。
   *
   * 用户问「这个标题栏能否拆成左右两块」—— 能，而且比整条更好：`systemMaterial` 的粒度
   * 本来就是**组件**（三十改已经用一个真机对照证明过），所以两块玻璃 = 两个各带材质的 Row，
   * 中间留一道 `Blank()` 的空隙，底下滚过去的画面从缝里直接透出来。
   *
   * 拆开之后两块各自量各自的内容宽度：
   *   · 左块装标题 + 切库箭头 + 库名胶囊，**可收缩**（`flexShrink(1)`）—— 库名长了先牺牲它；
   *   · 右块装排序/筛选/抽卡，**不可收缩**（`flexShrink(0)`）—— 这三颗是固定功能，
   *     被挤出去等于功能消失（七改踩过）。
   *
   * 内边距 12 / 8：玻璃边沿本身要留一点「玻璃厚度」，文字不能贴着圆角走。
   */
  @Builder
  LeftGlass() {
    Row({ space: BAR_GAP }) {
      Text('媒体库')
        .fontSize(TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
        // 标题是定宽内容（三个字），不参与收缩 —— 要收的是库名那一段
        .flexShrink(0)
        // 深底玻璃上文字再加一层极轻的投影，边缘不发虚
        .textShadow({ radius: 4, color: '#66000000', offsetX: 0, offsetY: 1 })
        .onAreaChange((o: Area, n: Area) => {
          this.titleW = parseFloat(`${n.width}`);
        })

      Row({ space: 0 }) {
        this.LibArrow(-1)
        this.LibChip()
        this.LibArrow(1)
      }
      .flexShrink(1)
      .constraintSize({ maxWidth: this.nameChipMax() + ARROW_W * 2 })
    }
    .height(BAR_H)
    .padding({ left: 12, right: 10 })
    .borderRadius(BAR_R)
    // ★ 2026-11-18 三十六改：**退回系统材质** ★
    //
    // 三十四改把这里换成 `backdropBlur + 垫色 + EdgeLight`，真机上翻车了：
    // 标题栏背后是页面底色（首屏让位后没有内容可采样），虚化采不到东西，
    // 只剩那层垫色 → 用户看到的是「莫名其妙一整块不透明阴影」。
    //
    // 结论（用户原话）：「我要的光晕是沉浸光感里官方给的边缘光……如果做不了就不要硬做。」
    // 光感只能由系统材质自己产生（`materialFilter` 的折射 + 边缘高光 + `lightEffect`
    // 打到下层），自绘的描边/渐变永远只是**画在玻璃上面的一圈线**，不是光。
    // 所以这里回到官方入口，一块一块都挂 `systemMaterial`。
    .systemMaterial(ImmersiveGlass.materialFor(this.glassLevel))
    .clip(true)
    .flexShrink(1)
  }

  /**
   * **右侧三颗独立小胶囊**（2026-11-17 三十二改：整块右玻璃取消）。
   *
   * 用户看完三十一改说「两个块靠太近、太紧凑，右边三个还可以再拆成三个单独的小胶囊」。
   * 那就拆到底：这三颗不再共用一个底座，各自是一层玻璃，中间留 `RIGHT_GAP`。
   * 好处是顶栏从「两条长条」变成「一块 + 三颗」，疏密拉开了；代价是没有底座兜着，
   * 三颗的材质必须**不着色**（着色就是三块灰砖，见 `pressMaterial` 注释）。
   */
  @Builder
  RightPills() {
    Row({ space: RIGHT_GAP }) {
      this.SortBtn()
      this.FilterBtn()
      if (BuildConfig.ENABLE_GACHA) {
        this.GachaBtn()
      }
    }
    .flexShrink(0)
    .onAreaChange((o: Area, n: Area) => {
      this.actsW = parseFloat(`${n.width}`);
    })
  }

  /**
   * 「当前库 ▾」胶囊（2026-11-17 七改成形，十改抽成独立 builder）。
   *
   * 九改起**一直在**：用户明确说「下拉不应该把已选择的媒体库隐藏」，
   * 所以滚动时不再让它让位（顶栏也从 46 → 34 的变矮里退回来了）。
   *
   * 宽度吃 `nameChipMax()`，两侧箭头各吃 ARROW_W —— 这一组的总宽上限由父 Row 管。
   */
  @Builder
  LibChip() {
    // ★ 2026-11-18 三十七改：**把外框整个去掉，只留字** ★
    //
    // 用户原话：「媒体库边上那个『全部』不能用玻璃框起来，玻璃叠玻璃很奇怪，
    //            直接把字放在那里就好了。」
    //
    // 对。它本来就长在左边那块玻璃里，再给它套一层带材质的圆角 —— 就是玻璃叠玻璃，
    // 交界处会有两道边缘高光互相打架，看着脏。现在这里没有任何背景 / 边框 / 材质，
    // 只有文字本身；可读性靠 Medium 字重 + 暗投影，点击热区靠 padding 撑一点。
    Text(this.libLabel())
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 上限按「顶栏实测剩余宽度」算（见 nameChipMax）：长库名到这儿才省略号收尾，
      // 右边的排序/筛选/抽卡永远不会被顶出屏幕。
      .constraintSize({ maxWidth: this.nameChipMax() - 14 })
      .flexShrink(1)
      .padding({ left: 4, right: 4, top: 6, bottom: 6 })
      // 亮色海报压上来时，白字要有自己的暗边（三十一改）
      .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
      .bindMenu(this.LibMenu)
  }

  /**
   * 切库箭头（2026-11-17 十改新增，十二改定稿）。
   *
   * 为什么要有它：上半屏横滑能切库，这件事在界面上以前**完全看不出来** ——
   * 用户的原话是「可以在选择库的这个范围里体现一下」。
   *
   * 形态迭代过一轮：十改用 `Text('‹')` 字号 19；十一改改成 `Path` 折线；
   * 用户看过之后说「左右的标点符号本身是可以看的，你改过反而难看了」——
   * 说明标点形态没问题，**丑的是胶囊里那个「下拉」小三角**（见 `LibChip`）。
   * 所以这里退回标点，只把字号提到 20，并保留到边界的压暗与停手。
   *
   * `dir` 只传常量 -1 / 1，状态判断全在 `canSwipe()` 里读 `this`，所以不会踩
   * 「@Builder 传值不跟状态刷新」那个坑（抽卡按钮就是被它坑过一次）。
   */
  @Builder
  LibArrow(dir: number) {
    Text(dir < 0 ? '‹' : '›')
      .fontSize(20)
      .fontColor(this.canSwipe(dir) ? '#D9FFFFFF' : '#3DFFFFFF')
      .textAlign(TextAlign.Center)
      .width(ARROW_W)
      .height(30)
      .flexShrink(0)
      // ★ 2026-11-18 三十八改：向上提 2.5vp —— 让箭头的**墨迹**中心跟「全部」的文字中心对齐 ★
      //
      // 用户原话：「『全部』边上的半书名号没有跟它对齐，很奇怪。」
      //
      // 真机截图量像素（1320 宽 ≈ 3.25 px/vp）：
      //   「全部」13fp 墨迹 y 186~225，中心 206；
      //   「‹」「›」20fp 墨迹 y 199~229，中心 214 —— 两个都偏低 8px ≈ 2.5vp，且左右一致。
      //
      // 不是排版写错了，是字形本身的性质：文字以 baseline 定位，汉字铺满字身框，
      // 而「‹」在 em 框里只占中间那一小段（≈0.28em 高）。盒子按行盒居中之后，
      // 墨迹就会整体沉下去半个字高 —— 字号越大越明显（这也是它当初从 13 提到 20 才暴露的原因）。
      //
      // 修法：只挪墨迹、不改盒子 —— 命中区仍是 16×30，点击手感不变。
      .translate({ y: -2.5 })
      // 极轻的投影：底下正好滚过亮色海报时，箭头不能糊进背景
      .textShadow({ radius: 3, color: '#59000000', offsetX: 0, offsetY: 1 })
      .onClick(() => {
        if (this.canSwipe(dir)) {
          this.swipeLibrary(dir);
        }
      })
  }

  /**
   * 排序按钮（2026-11-17 七改）。
   *
   * 不再只写「排序」两个字：用户选过排序，这里就显示当前依据（评分 / 最新 / 女优年龄…），
   * 并点亮成淡主题色，一眼看出「现在不是默认排序」。
   *
   * 宽度：排序名有 2/3/4 个字（「评分」/「最近看」/「女优年龄」），所以不写死宽度，
   * 只给上限 74（4 个字 + 内边距刚好），超出就省略号 —— 顶栏的库名胶囊会自动把空间让出来
   * （它的上限是「剩多少能用多少」，见 nameChipMax）。
   *
   * 十改把内边距 8 → 7、上限 84 → 74：标题涨到 20 号、又多了两颗切库箭头，
   * 这两笔开销得从别处匀出来，而 4 个字（52vp）+ 14 内边距本来就不到 74。
   */
  @Builder
  SortBtn() {
    Text(this.sortCustom ? this.sortText : '排序')
      .fontSize(13)
      // 三十一改：**一律 Medium**。用户原话「这几个字纯白又细，亮背景容易看不清」——
      // 光靠加粗不够，配合下面的深色薄底 + 投影才稳。
      .fontWeight(FontWeight.Medium)
      .fontColor(this.sortCustom ? Theme.ACCENT_INK : '#FFFFFF')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 74 })
      .textAlign(TextAlign.Center)
      .padding({ left: 9, right: 9, top: 7, bottom: 7 })
      .borderRadius(16)
      // 2026-11-18 三十六改：官方材质（interactive + lightEffect）。
      // 选中态走材质的 `materialColor` —— 材质生效后 `backgroundColor` 会被系统复位成透明，
      // 拿背景色表达「开着」在这条路上是无效的。
      .systemMaterial(ImmersiveGlass.pressMaterial(this.glassLevel,
        this.sortCustom ? Theme.accentAlpha(0.22) : undefined))
      .clip(true)
      .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
      .onClick(() => {
        this.openSheet('sort');
      })
  }

  /**
   * 筛选按钮（2026-11-17 七改）：**有生效的筛选项**时才点亮。
   *
   * 状态来自 BrowseGrid 的 `onFilterChange`（每次重载前报一次筛选项个数），
   * 而不是「面板开着没有」—— 面板关了但条件还在，按钮也应该亮着。
   */
  @Builder
  FilterBtn() {
    Row({ space: 4 }) {
      Text('筛选')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.filterOn ? Theme.ACCENT_INK : '#FFFFFF')
        .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
      if (this.filterCount > 0) {
        Text(`${this.filterCount}`)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.ON_ACCENT)
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 16 })
          .height(16)
          .padding({ left: 4, right: 4 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(8)
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 9, right: this.filterCount > 0 ? 7 : 9, top: 7, bottom: 7 })
    .borderRadius(16)
    .systemMaterial(ImmersiveGlass.pressMaterial(this.glassLevel,
      this.filterOn ? Theme.accentAlpha(0.22) : undefined))
    .clip(true)
    .onClick(() => {
      this.openSheet('filter');
    })
  }

  /**
   * 抽卡按钮单独写（2026-11-17）：不在外面算好 active 再传进来。
   * @Builder 的参数是按值传的，状态变化时不一定重算，表现为「进了抽卡但按钮不高亮」。
   * 这里直接读 `this.gachaOn`，走正常的 @State 追踪。
   *
   * 2026-11-17 七改两处：
   * 1. **固定宽度**：「抽卡」两个字变「抽卡中」三个字时，按钮会自己变宽，
   *    旁边一排全被推着走，长库名时直接把按钮挤出屏幕。固定宽度 + 文字居中，
   *    两种状态下占位一样，界面不会跳。
   * 2. **高亮不再整块涂主题色**：实心色块会把刚做出来的玻璃光感盖死（用户原话「把光感都顶掉了」）。
   *    改成「淡主题色底 + 一圈主题色描边 + 主题色字」，玻璃和亮边都还在，但一眼能看出是开着的。
   */
  @Builder
  GachaBtn() {
    Text(this.gachaOn ? '抽卡中' : '抽卡')
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.gachaOn ? Theme.ACCENT_INK : '#FFFFFF')
      .textAlign(TextAlign.Center)
      // 三十四改：54 → 58，并且 `maxLines(1)`。
      // 「抽卡中」三个字 13fp Medium 实测约 39vp，54 减去左右各 8 的内边距只剩 38 ——
      // 差 1vp 就换行了（用户报「变成抽卡中以后会分行」）。宽度仍写死，切开关时布局不跳。
      .width(58)
      .maxLines(1)
      .padding({ left: 4, right: 4, top: 7, bottom: 7 })
      .borderRadius(16)
      .systemMaterial(ImmersiveGlass.pressMaterial(this.glassLevel,
        this.gachaOn ? Theme.accentAlpha(0.22) : undefined))
      .clip(true)
      // 开着状态**不要**再叠 `.shadow`：材质自带边缘高光，再加投影会在按钮外面
      // 多出一圈漂着的圆弧（三十四改真机踩过）。
      .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
      .onClick(() => {
        this.gachaOn = !this.gachaOn;
      })
  }

  /** 当前选库的一句话说法（顶栏上显示的那几个字）。 */
  private libLabel(): string {
    if (this.activeIds.length === 0) {
      return '全部';
    }
    if (this.activeIds.length === 1) {
      for (let i = 0; i < this.libs.length; i++) {
        if (this.libs[i].id === this.activeIds[0]) {
          return this.libs[i].name;
        }
      }
      return '1 个库';
    }
    return `${this.activeIds.length} 个库`;
  }

  /** 点「库名 ▾」弹出来的浮层：还是原来那排 chips，只是从常驻改成按需展开。 */
  @Builder
  LibMenu() {
    Column({ space: 8 }) {
      Text('按库浏览（可多选）')
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      Scroll() {
        Column({ space: 8 }) {
          this.Chip(0, '全部')
          ForEach(this.libs, (lib: LibraryInfo) => {
            this.Chip(lib.id, lib.name)
          }, (lib: LibraryInfo) => `menu-${lib.id}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .constraintSize({ maxHeight: 260 })
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width(200)
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
    .border({ width: 1, color: Theme.STROKE })
  }

  build() {
    // ── 2026-11-17 二十改：照官方 Spatialization 示例，改用 **HdsNavigation 标题栏** ──
    //
    // 十九改用原生 `Navigation.title(builder, { systemMaterial })`，真机上整条标题栏直接
    // 消失了（CustomBuilder 的 `height('100%')` 和标题栏高度互相依赖，系统量出 0）。
    // 二十改不再自己拼这条路，而是**逐行复刻官方示例**
    // （HarmonyOS_Samples/Spatialization → `products/entry/.../pages/MainPage.ets`）：
    //
    //   HdsNavigation(stack) { 内容 }
    //     .titleBar({
    //       style: {
    //         scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: GRADIENT_BLUR },
    //         systemMaterialEffect: { materialType: ADAPTIVE, materialLevel: ADAPTIVE }
    //       }
    //     })
    //     .bindToScrollable([scroller])        ← 少了这一行，材质永远停在「未滚动」态
    //     .titleMode(HdsNavigationTitleMode.MINI)
    //
    // 三件事各自的作用（官方示例里一个都不能少）：
    //   · `systemMaterialEffect` —— 玻璃本体：材质由系统画，含底色 / 边 / 阴影 / 折射；
    //   · `scrollEffectOpts`     —— 光效：滚动时标题栏由「半透明」渐变到「模糊 + 边缘光晕」，
    //                               `IMMERSIVE_GRADIENT_BLUR` 是其中最沉浸的一档（6.1.0(23)）；
    //   · `bindToScrollable`     —— 把网格的滚动偏移喂给标题栏，上面那条光效才有进度可算。
    //
    // 内容行仍是 `BarRow()`，经 `content.stackBuilder` 放进标题栏，一个控件都没改。
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
          BrowseGrid({
            libraryIds: this.activeIds,
            refreshKey: this.refreshKey,
            tabInset: TAB_SAFE,
            leanMode: true,
            // 顶栏搜索的关键词（三十八改）：顶栏在父层，子组件的 @State 读不到，
            // 所以从这里下发，BrowseGrid 用 @Watch 接住并重载。
            externalKeyword: this.keyword,
          // 抽卡时水墙要自己顶到状态栏后面（见 GachaWall 的 padNow）
          gachaTopPad: this.topInset + BAR_H + 4,
          gridScroller: this.gridSc,
          // ★ 三十五改：首屏让位 ★
          // 三十四改之前是 0（第一排海报从屏幕最顶端开始，整条玻璃压在海报上），
          // 用户说「默认顶到最上面也不是很好」—— 现在静止时第一排完整落在标题栏下方，
          // 一滚动这段留白就跟着内容滚走，海报钻进标题栏底下给玻璃采样。
          headerTopPad: this.topInset + BAR_H + 4,
          gachaOn: $gachaOn,
          showSort: $showSort,
          showFilter: $showFilter,
          onFilterChange: (n: number) => {
            this.filterCount = n;
            this.filterOn = n > 0;
          },
          onSortChange: (label: string, isDefault: boolean) => {
            this.sortText = label;
            this.sortCustom = !isDefault;
          }
        })
          .width('100%')
          .height('100%')

        // ★ 六十改：搜索浮卡 ★
        // 压在最上层（`zIndex(10)` 在 builder 里），用 `position` 钉在标题栏下沿 ——
        // 它不参与 Stack 的布局流，所以展开/收起时下面的网格**一帧都不动**。
        this.SearchLayer()

        // 玻璃边框交给材质自己画（2026-11-17 三十改）：
        // 真机上 ImmersiveMaterial 生效后胶囊自带边缘高光与阴影，我们之前自绘的那条
        // 1vp 亮线 + 8vp 渐隐影子反而压在胶囊中间（位置按老的 56vp 标题栏算的），已删。
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
      // 诊断：内容区（网格）到底从屏幕哪一行开始 —— 它必须贴着玻璃下沿
      .onAreaChange((o: Area, n: Area) => {
        console.info(`[amane] content y=${n.globalPosition.y} h=${n.height}`);
      })
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    // ★ 标题栏层叠在内容之上：海报从它底下穿过去，胶囊才有颜色可采样。
    //   STANDARD 会把内容整体推下去（实测 content y=46），玻璃背后就是纯黑。
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  /**
   * 标题栏配置（2026-11-17 三十改）。
   *
   * 写成**有明确返回类型的方法**，不是内联对象字面量：`title(value, options?)` 的 value 是
   * `ResourceStr | CustomBuilder | NavigationCommonTitle | NavigationCustomTitle` 联合类型，
   * 内联 `{ builder, height }` 在联合类型下推不出目标类型，ArkTS 直接报
   * `arkts-no-untyped-obj-literals`（前一版编译就是这么挂的）。
   */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleGlass()
      },
      // 标题栏高度 = 状态栏 + 46：状态栏那一段是玻璃的沉浸区，内容行落在它下面。
      // 六十改：**恒为这个值**，不再随搜索展开 +48 —— 搜索改成压在内容上的浮卡
      //（`SearchLayer`），标题栏一长一短会让整页内容跟着跳，那正是「生硬」的来源。
      height: BAR_H + this.topInset
    };
  }

  /**
   * 顶栏玻璃胶囊（2026-11-17 三十改）—— **材质挂在这一层**。
   *
   * 官方《沉浸光感常见问题》原文：
   *   「位于 Navigation 标题栏中的 Column 开启沉浸光感正常生效；位于 Navigation 内容区中的
   *     Column 组件，因其不处于 Navigation 标题栏或底部 TabBar 中，不生效沉浸光感效果。」
   * 它给的示例是：标题栏 builder **内部**的一个 50×50 胶囊自己调
   *   `.systemMaterial(new uiMaterial.ImmersiveMaterial({ style: THIN }))`
   *
   * 所以 `systemMaterial` 的粒度是**组件**，不是「整条标题栏」。真机三次对照：
   *   塞进 `NavigationTitleOptions.systemMaterial` → 无效（海报完全清晰）；
   *   挂在 `Navigation` 组件上                     → 无效；
   *   挂在标题栏 builder 里的一个容器上           → 生效（就是这一版）。
   * 底栏一次就成，正因为它 `barFloatingStyle` 那条 bar 本身就是一个组件。
   *
   * 三十一改：材质从「整条一个容器」下移到**左右两块玻璃**（`LeftGlass` / `RightGlass`），
   * 这里只当一个「让出状态栏」的空壳，**不能再挂材质** —— 挂了就又变成一整条通栏，
   * 中间的缝会被这块底层玻璃填满，等于没拆。
   */
  @Builder
  TitleGlass() {
    Column() {
      this.BarRow()
      // 六十改：搜索那一行**不在标题栏里了**，搬去内容层的浮卡 `SearchLayer()`。
      // 留在这里的话，标题栏高度必须跟着变，整页内容就会跳（用户说的「生硬」）。
    }
    .width('100%')
    .height('100%')
    // 只让出状态栏：玻璃必须落在系统状态栏下面，不然跟时间/电量堆在一起
    .padding({ top: this.topInset })
  }
}