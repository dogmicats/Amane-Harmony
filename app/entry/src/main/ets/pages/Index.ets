import { common } from '@kit.AbilityKit';
import { BusinessError, batteryInfo } from '@kit.BasicServicesKit';
import { router, uiMaterial, display, window } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
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
  // ── 负一屏「跟手」图层（2026-11-14 13:15）────────────────────────────
  // 用户反馈「不跟手：一开始只出来一点，拉到中间偏右才突然弹出来」——根因是 router 转场
  // 只能等抬手才播放。现在负一屏作为**叠层**渲染在这里，手指移动时按真实位移平移，
  // 抬手再按 30% 屏宽阈值吸附开/关，进出都是连续的。
  @StorageLink('minusDx') minusDx: number = 0;
  @StorageLink('minusCmd') @Watch('onMinusCmd') minusCmd: string = '';
  @State minusOpen: boolean = false;
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
  }

  @Builder
  TabBarItem(index: number, label: string, icon: Resource) {
    Column() {
      // 选中项背后垫一团柔光（不呼吸：底栏常驻，呼吸光会一直在余光里闪）。
      // 玻璃胶囊本身不动，光只从胶囊边上溢出来一点，配合系统沉浸材质才像「亮着的灯」。
      Stack({ alignContent: Alignment.Center }) {
        if (this.currentTab === index && this.fx >= 1) {
          GlowOrb({
            color: Theme.ACCENT,
            diameter: this.fx >= 2 ? 88 : 72,
            alpha: this.fx >= 2 ? 0.30 : 0.18,
            breath: false
          })
        }
        // 选中项做成一块玻璃胶囊：半透明白底 + 0.5 高光描边，压在毛玻璃底栏上
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
      .borderRadius(16)
        // 选中胶囊也吃主题色（以前是纯白 15%）：整条底栏跟着换，视觉上才像一个整体
        .backgroundColor(this.currentTab === index ? Theme.accentAlpha(0.18) : '#00FFFFFF')
        .border({
          width: this.currentTab === index ? 0.5 : 0,
          color: Theme.accentAlpha(0.32)
        })
      }
      .width(56)
      .height(44)
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
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
    .barHeight(58)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 12,
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        // 沉浸光感加强（2026-11-14）：THIN → REGULAR，材质更"厚"，
        // 压一层更深的 materialColor('#3D') 让图标对比更稳（原来太透，白字发灰）。
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: '#3D000000'
      })
    })
    // 横滑切页交回 Tabs 原生处理（2.6.2.11 复原）：
    // 之前把它关掉、改由外层 PanGesture 分发，结果两个容器互相吃手势，右滑彻底失效。
    // Tabs 原生滑动本来就会「让位给内部横向列表」，海报行照旧横滑，不需要我们再仲裁。
    .scrollable(true)
    .animationDuration(260)
    .onChange((index: number) => {
      this.currentTab = index;
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
                router.pushUrl({ url: 'pages/SettingsPage' });
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

      // 负一屏叠层（跟手）：只有「拖动中」或「已打开」才挂载，避免常驻初始化播放器。
      if (this.minusOpen || this.minusDx > 0) {
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
      animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = this.minusW;
      });
    } else if (cmd === 'close') {
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = 0;
      });
      setTimeout(() => {
        if (this.minusDx <= 0) {
          this.minusOpen = false;
          this.applyOrientation(false);
        }
      }, 240);
    } else if (cmd === 'cancel') {
      animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = 0;
      });
      setTimeout(() => {
        if (this.minusDx <= 0) {
          this.minusOpen = false;
          this.applyOrientation(false);
        }
      }, 200);
    } else if (cmd === 'stay') {
      animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.minusDx = this.minusW;
      });
    }
    AppStorage.setOrCreate<string>('minusCmd', '');
  }
}
