import { common } from '@kit.AbilityKit';
import { BusinessError, batteryInfo } from '@kit.BasicServicesKit';
import { router, uiMaterial, display, window, curves } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { NavBarWatch } from '../common/NavBarWatch';
import { uploadCrashLog } from '../common/CrashReporter';
import { HomeTab } from './HomeTab';
import { LibraryTab } from './LibraryTab';
import { FavoritesTab } from './FavoritesTab';
import { ProfileTab } from './ProfileTab';
import { BuildConfig } from '../common/BuildConfig';
import { UpdateWatch } from '../common/UpdateWatch';
import { ActorsTab } from '../ext/actors/ActorsTab';
import { FacetsTab } from '../ext/facets/FacetsTab';
import { ShortsView, prefetchShorts } from '../view/ShortsView';
import { GlowOrb, ParticleField, setFxLow } from '../view/Fx';

@Entry
@Component
struct Index {
  @State booting: boolean = true;
  @State bootText: string = '正在连接服务器…';
  @State failMsg: string = '';
  @State currentTab: number = 0;
  /** 底栏玻璃不透明度（0–1）：外观页的滑杆写这个键，这里重建材质。 */
  @StorageProp('amaneTabBarAlpha') tabBarAlpha: number = 0;
  /** 全屏落地后只强制重排一次（见 `readInsets`）。 */
  private layoutRefreshed: boolean = false;
  // ── 底栏「按压光斑」（2026-11-16 用户点名要 hosplayer 那种）────────────────
  /** 正在被按住的那个 tab（-1 = 没有）；只有它内部会画出光斑。 */
  @State pressTab: number = -1;
  /** 光斑直径（vp）：按住越久越大，30 → 96。 */
  @State pressR: number = 0;
  /** 光斑不透明度：按下 0.62，抬手淡出到 0。 */
  @State pressA: number = 0;
  private pressTimer: number = -1;
  /** 还没填服务器地址（启动第一秒就能判出来，见 boot()）。 */
  @State needSetup: boolean = false;
  /** 最近一次按下的屏幕 Y（px）与时刻：用来判断这次翻页是不是「上半屏起手」的横滑。 */
  private swipeDownY: number = -1;
  private swipeDownAt: number = 0;
  // ── 负一屏「跟手」图层（2026-11-14 13:15）────────────────────────────
  // 用户反馈「不跟手：一开始只出来一点，拉到中间偏右才突然弹出来」——根因是 router 转场
  // 只能等抬手才播放。现在负一屏作为**叠层**渲染在这里，手指移动时按真实位移平移，
  // 抬手再按 30% 屏宽阈值吸附开/关，进出都是连续的。
  @StorageLink('minusDx') minusDx: number = 0;
  @StorageLink('minusCmd') @Watch('onMinusCmd') minusCmd: string = '';
  @State minusOpen: boolean = false;
  /** 底栏是否收起（`common/NavBarWatch` 按各 Tab 的滚动方向写这里）。 */
  // 键必须是**字面量**：@StorageProp 的参数在编译期求值，写成 `NavBarWatch.KEY`
  // 不会建立订阅（真机上表现为「状态变了但界面不动」）。
  @StorageProp('nav_bar_hidden') navHidden: boolean = false;
  /** 正在播「收回」补间：这段时间里叠层要保持挂载，否则动画没地方跑。 */
  @State minusClosing: boolean = false;
  /** 最近一次「吸附打开」的时间：跟着那一下 Up 别把它判成收合（见 trackMinus ②）。 */
  private minusOpenedAt: number = 0;
  @State minusW: number = 390;
  /** 负一屏内部左滑退出的采样（**屏幕坐标**）。 */
  private mX0: number = -1;
  private mY0: number = 0;
  private mX1: number = 0;
  private mY1: number = 0;
  /** 这次手势有没有采到起点（多指 / 被内层吃掉时为 false，抬手时按当前露出比例兜底判定）。 */
  private mTracked: boolean = false;
  @State homeRefresh: number = 0;
  /** 只驱动「静默换一批推荐」（不动骨架屏）。 */
  @State homeResume: number = 0;
  @State favRefresh: number = 0;
  @State libRefresh: number = 0;
  @State actorsRefresh: number = 0;
  @State facetsRefresh: number = 0;
  /**
   * 主题版本号（2.5.2）：设置页换色时 +1。
   *
   * `Theme.ACCENT` 是静态字段，子组件不会因为它变了就重绘（颜色都是 build 时读走的）。
   * 所以这里靠「if/else 换分支」把整棵 Tab 树销毁重建一次 —— 换主题是一次性的低频操作，
   * 重建几十毫秒，比让 30 多个组件各自订阅状态要省心得多，也不会漏掉任何一处颜色。
   */
  @StorageProp('amaneThemeEpoch') themeEpoch: number = 0;
  /** 沉浸光效强度（0 关 / 1 轻 / 2 强），见 `view/Fx.ets`。 */
  @StorageProp('amaneFx') fx: number = 2;
  private tabs: TabsController = new TabsController();
  /**
   * 负一屏是 `MinusLayer` 跟手叠层（不再由 Swiper 承载，也不用 router 独立页）——
   * Swiper 会把横向手势全吃掉，导致「右滑进负一屏」失效。
   * 所以这里不需要 SwiperController / pagerIndex，只需要窗口对象来锁竖屏。
   */
  /** 主窗口（负一屏要单独锁竖屏，拿它改方向；拿不到就退回全局自动旋转）。 */
  private win: window.Window | undefined = undefined;
  /** 每次页面重新可见 +1；负一屏据此重绑 surface（从详情页回来画面不冻）。 */
  @State resumeTick: number = 0;
  // 「我的」永远固定在最后：扩展开关会把前面的 Tab 数量改掉，
  // 用写死的 index 判断会把「我的」和 extension Tab 混在一起。
  private readonly actorIndex: number = 3;
  private readonly facetIndex: number = BuildConfig.ENABLE_ACTORS ? 4 : 3;
  private readonly profileIndex: number = 3
    + (BuildConfig.ENABLE_ACTORS ? 1 : 0)
    + (BuildConfig.ENABLE_FACETS ? 1 : 0);

  aboutToAppear(): void {
    // 负一屏跟手层要用屏宽（vp）算位移上限
    try {
      this.minusW = px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
      this.minusW = 390;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      Store.I.init(context);
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] init: ${err.code} ${err.message}`);
    }
    // 后台静默检测新版（2026-11-14）：延迟 4 秒跑，失败不出声；有更新会在「我的」右上角出红点。
    // 放在 Store.init 之后：检测要用服务端地址和 token。
    UpdateWatch.ensureStarted();
    // 主题色 / 列数要赶在第一次 build 之前生效；放在 try 外面，
    // 万一上面读偏好抛错，这里仍会按默认值把 AppStorage 铺好（不至于白屏）。
    Personalize.init();
    // 刷一刷留白铺什么（2.6.2.19）：本机偏好 → AppStorage，ShortsView 用 @StorageProp 读。
    // 放在第一次 build 之前铺好，进来才不用先闪一下海报再变黑。
    AppStorage.setOrCreate<number>('shortsPosterBg',
      Store.I.prefString('shorts_poster_bg', '1') === '0' ? 0 : 1);
    this.applyPowerBudget();
    this.boot();
    // 负一屏要单独锁竖屏，先把窗口拿到（拿不到就退化成全局自动旋转，不影响其他页面）
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      this.win = w;
      this.applyOrientation(this.minusOpen);
      // 真全屏：让内容画到状态栏/导航条后面（2026-11-16 用户对照 hosplayer 提的）。
      // 只在主界面开 —— 进二级页面时 `onPageHide` 会关掉，那些页面的标题栏没有让位逻辑。
      this.applyFullScreen(true);
      this.readInsets(w);
    }).catch((err: BusinessError) => {
      console.info(`[amane] orientation window: ${err.code} ${err.message}`);
    });
  }

  /**
   * 负一屏锁竖屏、退出后恢复全局自动旋转（2026-11-15 用户：「负一屏不应该有横屏效果」）。
   *
   * 为什么锁：负一屏是 9:16 竖版短视频的版式（画面 + 底部信息层 + 右侧操作列），
   * 转成横屏只会把画面压成中间一条、信息层错位。
   * 首页/媒体库那些是竖排列表，本来就能横过来用，所以只锁负一屏打开的那段时间。
   *
   * 跟手叠层下没有「翻到第几页」这个概念，判据是 `minusOpen`：
   * 叠层一吸附打开就锁竖屏，收回去就放开（拖动途中不切，避免边拖边转的诡异观感）。
   */
  private applyOrientation(open: boolean): void {
    const w = this.win;
    if (w === undefined) {
      return;
    }
    const want: window.Orientation = open
      ? window.Orientation.PORTRAIT
      : window.Orientation.AUTO_ROTATION;
    w.setPreferredOrientation(want).catch((err: BusinessError) => {
      console.info(`[amane] orientation: ${err.code} ${err.message}`);
    });
  }

  /**
   * 光效预算（2.6.1.18）：电量 ≤ 20% 时把粒子整体停住。
   *
   * 粒子是唯一 25fps 持续重绘的东西；光晕走的是系统动画，不占这条循环。
   * 低电量时用户要的是续航，不是浮尘 —— 所以这里直接降档，不做「问一下」。
   * 读不到电量（模拟器 / 权限异常）就按正常处理，绝不因为读不到而永久降档。
   */
  private applyPowerBudget(): void {
    let low: boolean = false;
    try {
      const soc: number = batteryInfo.batterySOC;
      low = soc >= 0 && soc <= 20;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] battery read: ${e.code}`);
    }
    setFxLow(low);
  }

  private async boot(): Promise<void> {
    // 第一步只读本地偏好（同步、微秒级）：一个地址都没填的人，转圈等连接失败毫无意义，
    // 直接送他去「服务器连接」子页（2026-11-16 用户要求）。
    if (!Store.I.configured()) {
      this.booting = false;
      this.needSetup = true;
      this.failMsg = '';
      router.pushUrl({ url: 'pages/SettingsConnectionPage' });
      return;
    }
    this.needSetup = false;
    this.booting = true;
    this.failMsg = '';
    this.bootText = Store.I.mode === 'auto' ? '正在探测局域网…' : '正在连接…';
    try {
      await Store.I.resolve();
      this.bootText = Store.I.onWan ? '正在连接外网…' : '正在读取媒体库…';
      try {
        await this.connect();
      } catch (error) {
        // 自动模式下探活可能误判（比如刚换了网段），局域网拉不到数据就退到外网再试一次
        if (Store.I.mode === 'auto' && !Store.I.onWan && Store.I.wanAmane.length > 0) {
          console.info('[amane] lan failed, fallback to wan');
          this.bootText = '局域网连不上，改用外网…';
          Store.I.useWan();
          await this.connect();
        } else {
          throw error as Error;
        }
      }
      this.booting = false;
      this.refreshTabs();
      // 刷一刷预取（2.6.2.15）：负一屏是「跟手叠层」，拖动时才挂载 ShortsView，
      // 不预取的话首次进来要等一次冷查询（5.7s）→ 固定闪「正在取片段」。
      // **必须放在 connect() 之后**：`Store.I.ready` 要等 loadConfig 回来才为 true，
      // 提前调会直接空跑（`prefetchShorts` 见 !ready 就返回）。
      prefetchShorts();
      // 连接就绪后静默回传上次的崩溃栈；失败会保留本地文件，不影响启动
      const ctx = getContext(this) as common.UIAbilityContext;
      uploadCrashLog(ctx).catch(() => {});
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] boot failed: ${err.code} ${err.message}`);
      this.booting = false;
      this.failMsg = `已尝试 ${Store.I.onWan ? '外网' : '局域网'} 地址：${Store.I.user}`;
    }
  }

  private async connect(): Promise<void> {
    await Store.I.loadConfig();
    await Store.I.loadFavIds();
  }

  private refreshTabs(): void {
    this.homeRefresh++;
    this.libRefresh++;
    this.favRefresh++;
    this.actorsRefresh++;
    this.facetsRefresh++;
  }

  onPageShow(): void {
    // 回到主界面：恢复真全屏（二级页面在 onPageHide 里关掉了）
    this.applyFullScreen(true);
    // 从「服务器连接」页返回：如果刚填好地址，立刻重连（不用用户再点一次重试）
    if (this.needSetup && Store.I.configured()) {
      this.needSetup = false;
      this.boot();
      return;
    }
    // 从详情页返回时，负一屏里的播放器 surface 已经失效 —— 用一个自增 tick 通知它重绑
    this.resumeTick++;
    // 回到前台：按当前电量重新决定要不要给粒子降档（省电模式下可能已经掉到 20% 以下）
    this.applyPowerBudget();
    // 从播放页 / 详情页返回：首页的「继续观看」和收藏状态可能变了
    if (!this.booting && this.failMsg.length === 0) {
      this.homeRefresh++;
      // 从详情页 / 播放页回来：推荐也换一批（只在首页时才做，免得在别的 tab 空跑）
      if (this.currentTab === 0) {
        this.homeResume++;
      }
      this.favRefresh++;
      // 详情页把本地文件夹删了：媒体库 / 搜索里那张卡要跟着消失
      if (Store.I.itemRemoved) {
        Store.I.itemRemoved = false;
        this.libRefresh++;
      }
      // 改过元数据 / 换过封面：媒体库与标签列表都得重拉，否则还是旧图旧名
      if (Store.I.coverDirty) {
        Store.I.coverDirty = false;
        this.libRefresh++;
        this.facetsRefresh++;
      }
      // 分类页里改了收藏 / 隐藏才重拉标签列表：无条件重拉会把滚动位置也一起清掉
      if (Store.I.facetDirty) {
        Store.I.facetDirty = false;
        this.facetsRefresh++;
      }
    }
  }

  /** App 不可见（锁屏 / 切到别的应用）：粒子立即停，不做后台重绘。 */
  onPageHide(): void {
    setFxLow(true);
    // 进二级页面：关掉真全屏（那些页面的标题栏没有让位状态栏的逻辑）
    this.applyFullScreen(false);
  }

  @Builder
  TabBarItem(index: number, label: string, icon: Resource) {
    Column() {
      // 选中项背后垫一团柔光（不呼吸：底栏常驻，呼吸光会一直在余光里闪）。
      // 玻璃胶囊本身不动，光只从胶囊边上溢出来一点，配合系统沉浸材质才像「亮着的灯」。
      Stack({ alignContent: Alignment.Center }) {
        // ★ 按压光斑（2026-11-16 用户点名要 hosplayer 那种）★
        // 手指按住某个 tab 时，底栏内部长出一团**纯白**圆形光，按得越久越大；
        // 抬手后在 220ms 内淡出。画在选中柔光**下面**，所以切换时是"从手指下透出来"，
        // 而不是盖住图标。`hitTestBehavior(None)` 避免它自己吃掉点击。
        if (this.pressTab === index) {
          Column()
            .width(this.pressR)
            .height(this.pressR)
            .borderRadius(this.pressR / 2)
            .radialGradient({
              center: ['50%', '50%'],
              radius: '50%',
              colors: [
                ['#FFFFFFFF', 0],
                ['#B3FFFFFF', 0.42],
                ['#40FFFFFF', 0.72],
                ['#00FFFFFF', 1]
              ]
            })
            .opacity(this.pressA)
            .hitTestBehavior(HitTestMode.None)
        }
        if (this.currentTab === index && this.fx >= 1) {
          GlowOrb({
            color: Theme.ACCENT,
            diameter: this.fx >= 2 ? 88 : 72,
            alpha: this.fx >= 2 ? 0.30 : 0.18,
            breath: false
          })
        }
        // 选中项做成一块玻璃胶囊：半透明白底 + 0.5 高光描边，压在毛玻璃底栏上。
        //
        // ★ 果冻滑动（2026-11-16 用户：高亮切换不要"消失+出现"，要像果冻滑过去）★
        // 做法：每个 item 都**常驻**一个胶囊，位置按 `(currentTab - index)` 偏移
        // （偏移量 = 相邻 tab 的中心距），不透明度只在 delta=0 时为 1。
        // 切换时旧项偏移一格并淡出、新项从一格外滑回 + 淡入 —— 两段动画叠在一起，
        // 看上去就是一个胶囊滑过去；配上 spring 曲线就是"果冻"。
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(56)
            .height(44)
            .borderRadius(16)
            .backgroundColor(Theme.accentAlpha(0.18))
            .border({ width: 0.5, color: Theme.accentAlpha(0.32) })
            .translate({ x: this.tabSlideDx(index) })
            // 只靠位移 + 淡入淡出，**不再缩放**（2026-11-16 用户：边缘太明显、像"弹消失再弹出来"，
            // 缩放是那个"弹"的来源）。两段叠加时看起来是一块底色在滑，不是两个框在闪。
            .opacity(this.tabSlideOn(index) ? 1 : 0)
            .animation({
              duration: 300,
              curve: curves.interpolatingSpring(0.72, 1, 340, 26)
            })
            .hitTestBehavior(HitTestMode.None)

          Column({ space: 3 }) {
            Image(icon)
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
              // 未选中也要看得清：原来用 TEXT_FAINT(#6C6C78) 在深底上几乎糊成一团，
              // 提到接近白的灰（选中才用紫色）
              .fillColor(this.currentTab === index ? Theme.ACCENT : Theme.TAB_IDLE)
            Text(label)
              .fontSize(10)
              .fontColor(this.currentTab === index ? Theme.TEXT : Theme.TAB_IDLE)
          }
          .width(56)
          .height(44)
          .justifyContent(FlexAlign.Center)
        }
        .width(56)
        .height(44)
      }
      .width(56)
      .height(44)
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
    // 只观测按下/抬手，不消费事件 —— Tabs 自己的点击照常触发
    .onTouch((ev: TouchEvent) => {
      if (ev.type === TouchType.Down) {
        this.startPressGlow(index);
      } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
        this.endPressGlow();
      }
    })
  }

  /** 按住底栏某一项：光斑从 40vp 长到 150vp，按下时间越长越大（hosplayer 那种）。 */
  private startPressGlow(index: number): void {
    this.stopPressGlowTimer();
    this.pressTab = index;
    this.pressR = 40;
    this.pressA = 0.38;
    animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
      this.pressA = 0.62;
    });
    this.pressTimer = setInterval(() => {
      if (this.pressR < 150) {
        this.pressR = Math.min(150, this.pressR + 4.5);
      }
    }, 50);
  }

  /** 抬手/离开：光斑淡出后复位。 */
  private endPressGlow(): void {
    this.stopPressGlowTimer();
    if (this.pressTab < 0) {
      return;
    }
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.pressA = 0;
    });
    setTimeout(() => {
      // 期间若又按下了别的 tab，别把它清掉
      if (this.pressA <= 0.001) {
        this.pressTab = -1;
        this.pressR = 0;
      }
    }, 240);
  }

  private stopPressGlowTimer(): void {
    if (this.pressTimer >= 0) {
      clearInterval(this.pressTimer);
      this.pressTimer = -1;
    }
  }

  /**
   * 果冻滑动：这个 item 的胶囊相对自己位置的横向偏移（vp）。
   *
   * `currentTab - index` 是"隔了几格"，乘上相邻 tab 的中心距就是一格的距离。
   * 只取 ±1（更远的不画），这样切换时旧胶囊滑出一格、新胶囊从一格外滑回来。
   */
  private tabSlideDx(index: number): number {
    const delta: number = this.currentTab - index;
    const step: number = this.tabCenterStep();
    if (delta === 0) {
      return 0;
    }
    return delta > 0 ? step : -step;
  }

  /** 这一项的胶囊要不要显示（只有当前项；相邻项在动画过程中会短暂可见）。 */
  private tabSlideOn(index: number): boolean {
    return this.currentTab === index;
  }

  /**
   * 相邻 tab 的中心距（vp）：底栏左右各留 16（`barSideMargin`），剩下均分给 5~6 个 item。
   * 屏宽取 vp，tab 数按当前构建实际可见的那几个算。
   */
  private tabCenterStep(): number {
    let w: number = 390;
    try {
      w = px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
      w = 390;
    }
    const visible: number = BuildConfig.ENABLE_ACTORS && BuildConfig.ENABLE_FACETS ? 6 : 5;
    return (w - 32) / visible;
  }

  /**
   * 整棵 Tab 树。单独抽成 Builder 是为了换主题时能一口气重建：
   * `build()` 里用 `themeEpoch` 的奇偶切换 if/else 分支，分支一换子树就销毁重建，
   * 静态读走的 `Theme.ACCENT` 才会全部按新颜色重新画。
   */
  @Builder
  TabsRoot() {
    // 首页 ⇄ 负一屏（2026-11-14 复原版）：**不再用 Swiper 包住 Tabs**。
    // 2.6.2.3~.8 试过「Swiper 内嵌 Tabs」，两种容器都要独占横滑，怎么调都是一边废掉；
    // 更糟的是 Swiper 自己会吃掉横向手势（实测右滑、左滑都到不了外层的
    // priorityGesture，连首页自己的手势也收不到）。
    // 现在的分工：
    //   Tabs        → 原生横滑切页（首页 → 媒体库 → 收藏 …），这是它本来就擅长的
    //   负一屏       → 跟手叠层 `MinusLayer`，右滑由首页手势触发（minusDx 实时位移）
    // 两者互不争抢：右滑在首页没有「上一页」可去，Tabs 不会消费它。
    Tabs({ barPosition: BarPosition.End, controller: this.tabs, index: this.currentTab }) {
      TabContent() {
        HomeTab({ refreshKey: this.homeRefresh, resumeKey: this.homeResume })
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home')))
      .backgroundColor(Theme.BG)

      TabContent() {
        LibraryTab({ refreshKey: this.libRefresh })
      }
      .tabBar(this.TabBarItem(1, '媒体库', $r('app.media.ic_tab_lib')))
      .backgroundColor(Theme.BG)

      TabContent() {
        FavoritesTab({ refreshKey: this.favRefresh })
      }
      .tabBar(this.TabBarItem(2, '收藏', $r('app.media.ic_tab_fav')))
      .backgroundColor(Theme.BG)

      // 公开扩展 actors：演员网格。关掉 ENABLE_ACTORS 时后面的 Tab index 会自动前移
      if (BuildConfig.ENABLE_ACTORS) {
        TabContent() {
          ActorsTab({ refreshKey: this.actorsRefresh })
        }
        .tabBar(this.TabBarItem(this.actorIndex, '演员', $r('app.media.ic_tab_actor')))
        .backgroundColor(Theme.BG)
      }

      // 公开扩展 facets：标签 / 系列 / 制片商 分类浏览
      if (BuildConfig.ENABLE_FACETS) {
        TabContent() {
          FacetsTab({ refreshKey: this.facetsRefresh })
        }
        .tabBar(this.TabBarItem(this.facetIndex, '标签', $r('app.media.ic_tab_tag')))
        .backgroundColor(Theme.BG)
      }

      TabContent() {
        ProfileTab({ refreshKey: this.homeRefresh })
      }
      .tabBar(this.TabBarItem(this.profileIndex, '我的', $r('app.media.ic_tab_me')))
      .backgroundColor(Theme.BG)
    }
    // 悬浮玻璃功能栏：内容从栏下穿过，材质交给系统沉浸光感（TabBar 是官方
    // 明确支持 systemMaterial 的位置），带圆角胶囊、随系统深浅色/算力自适应。
    // 收起（2026-11-15）：高度 → 0、左右外边距 → 接近半屏、底部外边距 → 0，三个属性一起补间，
    // 视觉上就是「整条被横向收紧、再吸进屏幕底下」，而不是单纯往下塌。
    .barHeight(this.navHidden ? 0 : 58)
    .barOverlap(true)
    // 真全屏：让 Tabs 自己铺到状态栏/手势条底下（2026-11-16 用户报"演员/媒体库/标签页底部一条黑边"）。
    // `setWindowLayoutFullScreen(true)` 只管**窗口**，ArkUI 仍按安全区给页面让位，
    // 所以页面区比屏幕短一截 —— Grid 视口到不了底，底栏下面那一条就露背景。
    // 这里从容器层撑开，六个 Tab 一次到位。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      // 收起（agent3）与真全屏让位（agent2）同时成立：收起时整条横向收紧吸进屏底，
      // 展开时按手势条实际高度上抬（读不到高度就退回 12）。
      barSideMargin: this.navHidden ? 215 : 16,
      barBottomMargin: this.navHidden ? 0 : this.barBottomGap(),
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        // 不透明度由「设置 → 外观」里的滑杆决定（2026-11-16 用户要的可调接口），
        // 默认 0.24 = 原来的 #3D000000，所以不调的人看到的效果和以前完全一样。
        materialColor: this.tabBarMaterialColor()
      })
    })
    .animation({ duration: 260, curve: Curve.Friction })
    // 横滑切页交回 Tabs 原生处理（2.6.2.11 复原）：
    // 之前把它关掉、改由外层 PanGesture 分发，结果两个容器互相吃手势，右滑彻底失效。
    // Tabs 原生滑动本来就会「让位给内部横向列表」，海报行照旧横滑，不需要我们再仲裁。
    .scrollable(true)
    .animationDuration(260)
    // ★ 上半屏横滑 = 页内切换（2026-11-15 用户要求）★
    // 为什么用 onContentWillChange 而不是"在上半屏盖一层 PanGesture"：
    // 23:18 真机实测**压不过** Tabs 的原生横滑 —— 上半屏左滑直接跳到「收藏」，库没换。
    // 这个钩子是 Tabs 自己给的「将要翻页」回调，**返回 false 就能取消这次翻页**，
    // 不用跟它抢手势，也不用关掉 scrollable（关掉就会重演 2.6.2.11 的右滑失效）。
    .onTouch((ev: TouchEvent) => {
      if (ev.type === TouchType.Down && ev.touches.length === 1) {
        this.swipeDownY = ev.touches[0].screenY;
        this.swipeDownAt = Date.now();
      }
    })
    .onContentWillChange((currentIndex: number, comingIndex: number) => {
      // 1500ms 内没有「手指按下」= 不是用户横滑（点 tab / changeIndex / 恢复状态）
      if (this.swipeDownAt <= 0 || Date.now() - this.swipeDownAt > 1500) {
        return true;
      }
      const half: number = px2vp(display.getDefaultDisplaySync().height) / 2;
      if (this.swipeDownY >= half) {
        return true;                     // 下半屏起手 = 原来的换页，放行
      }
      const key: string = this.tabKey(currentIndex);
      if (key.length === 0) {
        return true;                     // 这页没有页内切换对象：不拦
      }
      this.swipeDownAt = 0;
      const dir: number = comingIndex > currentIndex ? 1 : -1;
      AppStorage.setOrCreate<string>('inPageSwipe', `${key}|${dir}|${Date.now()}`);
      return false;                      // 取消翻页，页面自己切
    })
    .onChange((index: number) => {
      this.currentTab = index;
      // 换 tab 一律把底栏放出来：新页面的滚动位置是新的，留着收起会显得「导航不见了」
      NavBarWatch.reset();
      if (index === 0) {
        this.homeRefresh++;
        // 每次切回首页都换一批推荐（静默替换，不闪骨架）
        this.homeResume++;
      } else if (index === 1) {
        this.libRefresh++;
      } else if (index === 2) {
        this.favRefresh++;
      } else if (index === this.actorIndex) {
        this.actorsRefresh++;
      } else if (index === this.facetIndex) {
        this.facetsRefresh++;
      }
    })
  }

  build() {
    Stack() {
      if (this.booting) {
        // 冷启动这几秒里屏幕只有一行字，最容易显得「卡住了」。
        // 一团呼吸的主色光 + 一层慢速浮尘，让等待像在等放映机亮起来。
        Stack({ alignContent: Alignment.Center }) {
          if (this.fx >= 1) {
            GlowOrb({ color: Theme.ACCENT, diameter: this.fx >= 2 ? 420 : 320, alpha: 0.26, breath: true, period: 3600 })
          }
          if (this.fx >= 2) {
            ParticleField({ count: 18, color: '#FFFFFF', alpha: 0.30, drift: 0.6 })
          }
          Column({ space: 14 }) {
            Text('Amane')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Theme.ACCENT)
            Text(this.bootText)
              .fontSize(12)
              .fontColor(Theme.TEXT_FAINT)
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
      } else if (this.needSetup) {
        // 没填地址（从设置页退回来还没填）：给个明确的入口，别再转圈
        Column({ space: 14 }) {
          Text('还没设置服务器')
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text('填好地址才能读取媒体库')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
          Button('去设置')
            .height(40)
            .padding({ left: 24, right: 24 })
            .backgroundColor(Theme.ACCENT)
            .fontColor('#FFFFFF')
            .fontSize(14)
            .margin({ top: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsConnectionPage' });
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failMsg.length > 0) {
        Column({ space: 14 }) {
          Text('连不上服务器')
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(this.failMsg)
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 40, right: 40 })
          Row({ space: 12 }) {
            Button('重试')
              .height(40)
              .padding({ left: 24, right: 24 })
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(14)
              .onClick(() => {
                this.boot();
              })
            Button('设置地址')
              .height(40)
              .padding({ left: 24, right: 24 })
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(14)
              .onClick(() => {
                // 直接进「服务器连接」子页（2026-11-16 用户要求）：
                // 连不上的下一步永远是改地址，不该先让他在设置总菜单里找一层。
                router.pushUrl({ url: 'pages/SettingsConnectionPage' });
              })
          }
          .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.themeEpoch % 2 === 0) {
        // 换主题后走到 else 分支：子树整体重建，颜色才会全部换成新的
        this.TabsRoot()
      } else {
        this.TabsRoot()
      }

      // 负一屏叠层（跟手）：只有「拖动中」「已打开」或「正在收回」才挂载，
      // 避免常驻初始化播放器；`minusClosing` 是为了让收回动画有地方播完 ——
      // 少了它，位移归零的那一帧整层就被卸载，看起来像负一屏「闪一下消失」。
      if (this.minusOpen || this.minusDx > 0 || this.minusClosing) {
        this.MinusLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  /** 负一屏图层：按 `minusDx` 实时平移（0 = 完全收起，minusW = 完全展开）。 */
  @Builder
  MinusLayer() {
    Column() {
      ShortsView({
        resumeTick: this.resumeTick,
        onClose: () => {
          AppStorage.setOrCreate<string>('minusCmd', 'close');
        }
      })
    }
    .width('100%')
    .height('100%')
    .translate({ x: this.minusDx - this.minusW })
    .onTouch((ev: TouchEvent) => {
      this.trackMinus(ev);
    })
  }

  /**
   * 底栏玻璃的 `#AARRGGBB`：把 0–1 的不透明度换成两位十六进制。
   *
   * 单独写成方法是为了让 `materialColor` 跟着 `tabBarAlpha` 变 —— 外观页拖动滑杆时
   * 底栏立刻变深变浅，不用重启。
   */
  private tabBarMaterialColor(): string {
    let a: number = Math.round(this.tabBarAlpha * 255);
    if (a < 0) {
      a = 0;
    } else if (a > 255) {
      a = 255;
    }
    const hex: string = a.toString(16).toUpperCase().padStart(2, '0');
    return `#${hex}000000`;
  }

  /**
   * 真全屏开关：把窗口内容铺到状态栏/导航条底下（对照 hosplayer 的效果）。
   *
   * 只在**主界面**开：六个 Tab 的顶栏都按 `Theme.topInset()` 让位，
   * 列表还能从状态栏下面穿过去；二级页面（详情 / 设置 / 搜索…）没有那套让位，
   * 一进就关掉，免得标题栏被时钟压住 —— 这也是 `onPageHide/onPageShow` 里一开一关的原因。
   */
  private applyFullScreen(on: boolean): void {
    const w = this.win;
    if (w === undefined) {
      return;
    }
    w.setWindowLayoutFullScreen(on).catch((err: BusinessError) => {
      console.info(`[amane] fullscreen: ${err.code} ${err.message}`);
    });
  }

  /** 读状态栏 / 导航条高度（vp），铺进 AppStorage 给 `Theme.topInset()` 用。 */
  private readInsets(w: window.Window): void {
    try {
      const sys: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('amaneTopInset', px2vp(sys.topRect.height));
      AppStorage.setOrCreate<number>('amaneNavInset', px2vp(nav.bottomRect.height));
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] insets: ${e.code} ${e.message}`);
    }
    // ★ 真全屏是**异步生效**的（`setWindowLayoutFullScreen` 返回 Promise）★
    // 首帧往往已经按「非全屏」的高度排过一次，于是 Grid 的视口短了一截：
    // 底部那一条不渲染，手指轻轻一滑才重排、内容"闪现"到底（2026-11-16 用户在演员/媒体库/标签页报的）。
    // 这里等它落地后**强制重建一次 Tab 树**（`themeEpoch` 奇偶切换），把高度一次性刷新到位。
    // —— 实际根因不是时序：旋转屏幕（=强制重排）后黑边仍在，说明页面区高度真的短了，
    //    由各页根容器的 `expandSafeArea` 撑开（见 ActorsTab / FacetsTab / LibraryTab / FavoritesTab / HomeTab）。
    // 这次重建保留着无害（一次性），只是不再是主要修复手段。
    if (!this.layoutRefreshed) {
      this.layoutRefreshed = true;
      setTimeout(() => {
        AppStorage.setOrCreate<number>('amaneThemeEpoch', this.themeEpoch + 2);
      }, 120);
    }
  }

  /** 底栏离底距离：原来的 12 再让开手势条，免得压在上面。 */
  private barBottomGap(): number {
    return 12 + Theme.navInset();
  }

  /**
   * 这个 Tab 支不支持「上半屏横滑切页内内容」。
   *
   * 只有真的能在页内切换的页面返回 key；返回空串 = 不拦横滑，让它照常翻页。
   * （演员页、我的、首页暂时都没有页内切换对象。）
   */
  private tabKey(index: number): string {
    if (index === 1) {
      return 'lib';                       // 媒体库：切库
    }
    if (index === 2) {
      return 'fav';                       // 收藏：切影片/剧照/演员…
    }
    if (BuildConfig.ENABLE_FACETS && index === this.facetIndex) {
      return 'facet';                     // 标签：切标签/系列/导演/制片商
    }
    return '';
  }

  /**
   * 负一屏内部左滑 → 跟手退出。
   *
   * 2.6.2.15 修「有时候要滑两次才退，第一次只是把它拉回原样」：
   *   ① 坐标改用 `screenX/screenY` —— 原来用 `touches[0].x`（**组件局部**），
   *      而这一层本身正被 `translate` 平移，局部坐标会把位移吃掉一部分，dx 偏小；
   *   ② 抬手判定不再只认「滑过屏宽 28%」—— 短促一划（>48vp 且明显偏横）也算数，
   *      否则快速一划被判成 `stay`，动画把页面**补回全开**，看着就像"又被拉出来"；
   *   ③ 没采到起点（多指 / 被内层吃掉）也不能什么都不做，按当前露出比例兜底。
   */
  private trackMinus(ev: TouchEvent): void {
    if (ev.type === TouchType.Down) {
      if (ev.touches.length === 1) {
        this.mX0 = ev.touches[0].screenX;
        this.mY0 = ev.touches[0].screenY;
        this.mX1 = this.mX0;
        this.mY1 = this.mY0;
        this.mTracked = true;
      } else {
        this.mTracked = false;
      }
      return;
    }
    if (ev.type === TouchType.Move) {
      if (ev.touches.length === 1 && this.mTracked) {
        this.mX1 = ev.touches[0].screenX;
        this.mY1 = ev.touches[0].screenY;
        const dx: number = this.mX1 - this.mX0;
        const dy: number = this.mY1 - this.mY0;
        if (dx < 0 && Math.abs(dx) > Math.abs(dy) * 1.2) {
          this.minusDx = Math.max(0, this.minusW + dx);
        }
      }
      return;
    }
    // 抬手（含 Cancel）：先算好两个判据再决定，**一定要给一个结论**，
    // 否则这一划什么都不发生，用户就得再划一次。
    const dx: number = this.mTracked ? this.mX1 - this.mX0 : 0;
    const dy: number = this.mTracked ? this.mY1 - this.mY0 : 0;
    const tracked: boolean = this.mTracked;
    this.mX0 = -1;
    this.mTracked = false;
    if (!tracked) {
      // 没采到起点。三种情况要分开：
      //   ① 这一层**还没打开**（正被手指拉出来的那一下）—— Up 可能落到刚挂载的叠层上，
      //      此时 minusDx 只是"拉到一半"，按位置判会把它**当场收回去**，
      //      表现就是"右滑没反应/时好时坏"（2026-11-14 22:00 实测）。这种一律不参与判定，
      //      交给 HomeTab 在那一下 Up 里决定开/弹回。
      //   ② **刚被 open 吸附上**（2026-11-15 复现）：HomeTab 用「滑过 30% 就开」判定，
      //      这里用「露出 60% 才留」判定 —— 一次 30%~60% 的滑动会先 open、再被这句判成 close，
      //      负一屏当场缩回去（真机日志：open 到 teardown 只隔 183ms）。open 之后 500ms 内的
      //      这一下 Up 属于"开屏那一划本身"，不参与收合判定，让吸附动画走完。
      //   ③ 已经打开（多指或被内层吃掉 Down）：按露出比例兜底，别让这一划白划。
      if (!this.minusOpen) {
        return;
      }
      if (Date.now() - this.minusOpenedAt < 500) {
        return;
      }
      AppStorage.setOrCreate<string>('minusCmd',
        this.minusDx < this.minusW * 0.6 ? 'close' : 'stay');
      return;
    }
    const flick: boolean = dx < -48 && Math.abs(dx) > Math.abs(dy) * 1.2;
    const dragged: boolean = this.minusDx < this.minusW * 0.6;
    // 2026-11-16：**还没打开**时，这一划的结论归 HomeTab（它可能判成「拉得不够 → 弹回」）。
    // 这里再补一个 close/stay 会和 HomeTab 的 cancel 打架：两个 animateTo 抢同一个位移，
    // 后一个从「已经归零」的位置起跑 = 零帧归位，观感是「瞬间弹回 + 负一屏闪一下」。
    if (!this.minusOpen) {
      return;
    }
    AppStorage.setOrCreate<string>('minusCmd', flick || dragged ? 'close' : 'stay');
  }

  /** 抬手 / 外部命令：吸附开或关（带补间，位移是连续的，不会「突然弹出」）。 */
  onMinusCmd(): void {
    const cmd: string = this.minusCmd;
    if (cmd.length === 0) {
      return;
    }
      if (cmd === 'open') {
        this.minusOpen = true;
        this.minusOpenedAt = Date.now();
        // 叠层吸附打开 = 用户已经在看负一屏，这时才锁竖屏（拖动途中不切）
        this.applyOrientation(true);
        // 负一屏是另一套全屏画面，底栏收起状态不该带过去
        NavBarWatch.reset();
      animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = this.minusW;
      });
    } else if (cmd === 'close') {
      this.minusClosing = true;
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = 0;
      });
      setTimeout(() => {
        if (this.minusDx <= 0) {
          this.minusOpen = false;
          this.minusClosing = false;
          this.applyOrientation(false);
          // 回到首页：底栏一定在（别留在负一屏收起的那个状态）
          NavBarWatch.reset();
        }
      }, 240);
    } else if (cmd === 'cancel') {
      this.minusClosing = true;
      animateTo({ duration: 190, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = 0;
      });
      setTimeout(() => {
        if (this.minusDx <= 0) {
          this.minusOpen = false;
          this.minusClosing = false;
          this.applyOrientation(false);
          NavBarWatch.reset();
        }
      }, 210);
    } else if (cmd === 'stay') {
      animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = this.minusW;
      });
    }
    AppStorage.setOrCreate<string>('minusCmd', '');
  }
}
