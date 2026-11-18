import { common } from '@kit.AbilityKit';
import { BusinessError, batteryInfo } from '@kit.BasicServicesKit';
import { router, uiMaterial, display, window, curves, UIContext } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { ImmersiveGlass } from '../common/ImmersiveGlass';
import { EdgeLight } from '../common/EdgeLight';
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
  /**
   * 顶栏 / 底栏小胶囊共用的材质档位（0 无 / 1 弱 / 2 强 / 3 极限）。
   *
   * 四十改：底栏的**选中高亮**也改成系统材质了，档位跟顶栏那四块玻璃同一来源 ——
   * 用户在外观设置里换一档，两条栏一起变，不会出现「顶上薄、底下厚」。
   */
  @StorageProp('amaneGlass') glassLevel: number = 2;
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
  // ── 底栏「切换流光」（2026-11-17 三十三改）──────────────────────────────
  /**
   * 高光起点相对「当前选中项」的横向偏移（vp）。
   *
   * 切换时先把它设成 `(上一个 - 当前) × 一格`，让光**在新位置出生在旧位置上**，
   * 下一帧用 `animateTo` 归零 —— 看上去就是一束光从旧 tab 滑到新 tab。
   * 整个底栏任何时刻只有一束光，不存在两块交叉淡化。
   *
   * 为什么必须用显式 `animateTo` 而不是节点上的隐式 `.animation()`：
   * 实测隐式动画对**刚刚创建**的节点不生效（节点第一次出值就是终值），
   * 光的位移会在一帧内跳完，等于没动。
   */
  @State travel: number = 0;
  /** 流光尾的偏移。和 `travel` 同源，但补间更慢 —— 自动慢半拍，就拖出了一道光尾。 */
  @State travelTail: number = 0;
  /** 这次切换要不要在光出生时起跑（见 `startFlow`）。 */
  private flowArmed: boolean = false;
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
    // 顶栏材质档位（2026-11-17 五改）：查设备算力 → 解析出档位 → 写 AppStorage。
    // 必须在第一次 build 之前跑完，否则媒体库顶栏会先按默认档渲染一帧再跳档。
    ImmersiveGlass.init();
    // 现场判据（2026-11-17 二十八改）：底栏材质到底有没有被系统接受，先看这一行。
    // supported=false 时 `tabBarMaterial()` 会返回 undefined，底栏退回「无材质的透明条」。
    console.info(`[amane] tabbar material supported=${ImmersiveGlass.supported} ` +
      `level=${ImmersiveGlass.deviceLevel} ${ImmersiveGlass.appStateLabel()}`);
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
   * 方向：全局锁竖屏（2026-11-18 用户：「先禁止除了播放器以外的所有横屏」）。
   *
   * 以前负一屏打开锁竖屏、收起恢复 AUTO_ROTATION；现在除播放页外的界面都没按横屏调过，
   * 所以收起后也锁竖屏，不再放开。全局默认见 EntryAbility（PORTRAIT）。
   *
   * 播放中一律跳过：播放器由 PlayerView 自己切 LANDSCAPE/AUTO/PORTRAIT，
   * 首页若在播放期间被调一次（负一屏在播放页底下收起时会走到），
   * 会把系统方向重判一次 → 手上观看角度被判成竖就翻转（2026-11-17 修的横屏翻竖屏）。
   *
   * open 参数保留（调用点传 minusOpen），只是现在开和关都锁 PORTRAIT。
   */
  private applyOrientation(open: boolean): void {
    const w = this.win;
    if (w === undefined) {
      return;
    }
    const playing: boolean | undefined = AppStorage.get<boolean>('playerActive');
    if (playing === true) {
      console.info('[amane] orientation: 播放中，跳过首页的方向设置');
      return;
    }
    // 非播放页一律竖屏；open 现在是历史参数（0=主页收起 / 1=负一屏打开），只记进日志便于排查。
    console.info(`[amane] orientation: lock portrait (minusOpen=${open})`);
    w.setPreferredOrientation(window.Orientation.PORTRAIT).catch((err: BusinessError) => {
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
        // ① 流光尾（最底层）：**一圈在消散的光环**，不是一块色斑（三十四改）。
        //    径向渐变从中心透明 → 0.7 处才有颜色 → 边缘归零：中心一个像素都不画，
        //    所以它不会把高亮中间糊住，跑动时看起来就是「一圈光甩在后面」。
        //    补间比主光慢一倍，天然落后半拍，不需要第二个状态去驱动。
        if (this.currentTab === index) {
          Column()
            .width(96)
            .height(46)
            .borderRadius(23)
            .radialGradient({
              center: ['50%', '50%'],
              radius: '50%',
              colors: [
                [Theme.accentAlpha(0.0), 0],
                [Theme.accentAlpha(0.10), 0.55],
                [Theme.accentAlpha(0.18), 0.82],
                [Theme.accentAlpha(0.0), 1]
              ]
            })
            .translate({ x: this.travelTail })
            .hitTestBehavior(HitTestMode.None)
        }
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
        // ② 高光本体（柔光 + 玻璃胶囊）：**整组跟着 `travel` 一起滑**
        //
        // ★ 切换流光（2026-11-17 三十三改，替换掉原来的「果冻」）★
        // 原来的做法是每个 item 各常驻一个胶囊、靠 `opacity` 交叉淡化 —— 两团半透明
        // 叠在一起，看上去只是「旧的暗下去、新的亮起来」，没有位移，所以不像光在跑。
        // 现在整个底栏**任何时刻只有一束光**：切到哪一项，光就在那一项里重新出生，
        // 出生位置 = 上一项的位置（`travel`），下一帧归零，位移交给隐式动画补间。
        // 配合 300ms 的弹簧 + 那条慢半拍的流光尾，读起来就是「高光从这一页流到下一页」。
        if (this.currentTab === index) {
          Stack({ alignContent: Alignment.Center }) {
            // ★ 2026-11-18 四十改：高亮本体从「自绘边缘光」换成**系统沉浸材质** ★
            //
            // 用户：「底栏高亮也换成系统材质。」
            //
            // 之前是一块 10% 主题色底 + `EdgeLight` 自绘光圈 —— 顶栏四块已经是官方的
            // `systemMaterial`（材质自己画底色/边/折射/光），底栏这束还是自绘的，两条栏
            // 就还是两套语言：一条有折射，一条只有一圈渐变线。
            //
            // 为什么这里能用材质：底栏是 `Tabs(barPosition: End)` 的 TabBar，
            // 正是官方列出的第二个落点（第一个是 Navigation 标题栏）。顶栏那四块挂在
            // 标题栏 builder 里、效果出得来，就是这个原因；同理挂在 tabBar builder 里也成立。
            //
            // 选中色走材质的 `materialColor`（不是 backgroundColor）：材质一生效，系统会把
            // backgroundColor 复位成透明 —— 靠底色表达选中在这条路上一律无效。
            if (this.barSpotMaterial() !== undefined) {
              Column()
                .width(56)
                .height(44)
                .borderRadius(16)
                .systemMaterial(this.barSpotMaterial())
                // 材质是方的矩形，圆角要靠 clip 裁出来
                .clip(true)
            } else {
              // 兜底（档位=无 / 设备不支持材质）：退回「淡主题色底 + 自绘边缘光」，
              // 否则这一档下底栏会变成「选中项什么都没有」。
              Column()
                .width(56)
                .height(44)
                .borderRadius(16)
                .backgroundColor(Theme.accentAlpha(0.10))
              // ★ 边缘光（三十四改）★ 和顶栏那几块玻璃用的是**同一个组件**：
              //   外圈一道头发丝亮边 → 紧贴一道暗线 → 4vp 内衬微光 → 中心零。
              EdgeLight({
                radius: 16,
                tint: Theme.ACCENT,
                level: 1,
                ring: 0.52,
                bloom: 0.12,
                bloomW: 3,
                sheen: 0.22
              })
            }
          }
          .width(56)
          .height(44)
          .translate({ x: this.travel })
          .hitTestBehavior(HitTestMode.None)
          // 高光刚一出生就起跑：此刻它的当前值还是 `travel`（旧 tab 的位置），
          // 下面这个 animateTo 把它补间到 0，于是光从旧位置滑到新位置。
          .onAppear(() => {
            this.startFlow();
          })
        }

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

  /**
   * 起跑：把高光从「旧 tab 的位置」补间回自身位置（2026-11-17 三十三改）。
   *
   * 由高光节点的 `onAppear` 调用 —— **不能**用固定延时的 `setTimeout`：
   * 节点什么时候渲染出来是不确定的，赌早了（光还没出生）`travel` 已经归零，
   * 屏幕上就只剩「凭空出现在目标位置」，也就是原来那个"没有流过去"的观感。
   *
   * 两条 animateTo 同源不同时长：主线 340 的弹簧，光尾 300 弹簧但质量更小 → 慢半拍，
   * 视觉上就是主光在前面跑、身后拖一道淡淡的余光。
   */
  private startFlow(): void {
    if (!this.flowArmed) {
      return;
    }
    this.flowArmed = false;
    const ui: UIContext = this.getUIContext();
    // 三十四改：高光从「实心色块」变成「一圈边缘光」，动画也要跟着换脾气。
    //
    // 色块可以弹（重心在整块面积上，弹一下像果冻）；一圈光弹就不对了 —— 光没有质量，
    // 它应该**滑过去然后停住**。所以主线把阻尼提到接近临界（30，约为 0.93 阻尼比），
    // 刚度 260（周期 ≈ 390ms）：几乎没有回弹，落地就静。
    ui.animateTo({ curve: curves.interpolatingSpring(0, 1, 260, 30) }, () => {
      this.travel = 0;
    });
    // 光尾质量给到 1.8、刚度 190：周期 ≈ 610ms，比主线慢一截，落后约 150ms 才跟上。
    // 它本来就比主光更宽更淡，慢这一点刚好读成「一道余光甩在身后」，而不是第二个高光。
    ui.animateTo({ curve: curves.interpolatingSpring(0, 1.8, 190, 34) }, () => {
      this.travelTail = 0;
    });
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
      systemMaterial: this.tabBarMaterial()
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
      // ★ 上 3 : 下 2（2026-11-18 四十九改）★
      // 原来是「五五开」。但媒体库/收藏这两页的标题栏已经是**两行**（各 100vp 上下），
      // 连同状态栏一共吃掉屏幕上部很大一截；再说手指起手一般在画面中间偏上，
      // 按一半分，很多人习惯性落在下缘就被判成「换页」。往下放到六成，
      // 上半屏（页内切换）覆盖到常看区域，底下的海报区仍然归 Tabs 换页。
      const split: number = px2vp(display.getDefaultDisplaySync().height) * 0.6;
      if (this.swipeDownY >= split) {
        return true;                     // 下 2/5 起手 = 原来的换页，放行
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
      const prev: number = this.currentTab;
      // ★ 切换流光（三十三改）：先把光的出生点摆到**上一个** tab 的位置，
      //   下一帧归零 —— 位移由节点上的隐式动画补间，看上去就是光从旧页流到新页。
      //   必须分两帧：同一帧里设完又归零，框架只会看到最终值 0，什么都不会动。
      if (prev !== index) {
        const dx: number = (prev - index) * this.tabCenterStep();
        this.travel = dx;
        this.travelTail = dx;
        // 真正的补间交给 `startFlow()`：它在高光节点**出现的那一刻**触发，
        // 不靠固定延时去赌「节点有没有渲染完」（赌早=光还没出生就归零，等于没动）。
        this.flowArmed = true;
      }
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
   * 底栏的**系统沉浸材质**（2026-11-17 二十八改：照官方 `FloatingTabBarStyle.systemMaterial` 写）。
   *
   * 为什么这次能成而顶栏不能：
   * 官方《开启沉浸光感》原文只有两个位置吃材质 —— Navigation/NavDestination 的**标题栏**，
   * 以及「横向 Tabs 中 barPosition 为 **BarPosition.End** 的底部 TabBar」。我们这条底栏
   * 正好是后者，`barFloatingStyle({ systemMaterial })` 是官方给的入口，**没有自绘**。
   *
   * 四件事决定了「玻璃」还是「磨砂塑料」：
   *   1. `style`：官方建议**悬浮控件用 THIN / ULTRA_THIN**。之前这里是 REGULAR，
   *      常规厚度 + 圆角胶囊，屏幕上就是一坨糊掉的深色块。
   *   2. `materialColor`：官方注释「纯色必须半透明，**否则会完全阻挡材质滤镜**」。
   *      这里由外观页的滑杆给，**默认 0 = 全透明 = 材质原样呈现**。之前默认 0.24 的黑，
   *      等于在滤镜上又盖了一层墨，颜色永远透不上来 —— 这就是「只是变暗」的根。
   *   3. `colorInvert`：材质薄到 THIN 以下时，系统会让子树里文字/图标自动取背景反色。
   *      玻璃扫过亮海报时字自己变深，这是「有块玻璃压在上面」最直接的观感来源。
   *   4. `lightEffect`：光感交互反馈（按压时光晕沿材质散开）。官方说它对**所有算力档**生效，
   *      是静态材质之外唯一能加「光」的官方开关。
   *
   * 材质对象带 GPU 资源，按不透明度百分比缓存 —— 滑杆每动一格就是一个新对象，
   * 不缓存的话拖动时会一直 new。
   */
  private tabBarMats: Map<number, uiMaterial.ImmersiveMaterial> = new Map();

  private tabBarMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    // 设备不支持就别挂：返回 undefined 等于不设材质，底栏退回 `barBackgroundColor` 那条
    if (!ImmersiveGlass.supported) {
      return undefined;
    }
    const pct: number = Math.round(this.tabBarAlpha * 100);
    const hit: uiMaterial.ImmersiveMaterial | undefined = this.tabBarMats.get(pct);
    if (hit !== undefined) {
      return hit;
    }
    const made: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: this.tabBarMaterialColor(),
      // 只有 THIN / ULTRA_THIN 才可能被系统判定为「可以反色」，REGULAR 开始一律不生效
      colorInvert: true,
      applyShadow: true,
      // 按压时材质本身轻微形变 —— 玻璃被手指压下去的那一下
      interactive: true,
      // 光感反馈：手指落在底栏上，光沿着材质散开一圈（不是我们自绘的那个白点）
      lightEffect: { color: Color.White }
    });
    this.tabBarMats.set(pct, made);
    return made;
  }

  /**
   * 底栏**选中高亮**用的材质（2026-11-18 四十改）。
   *
   * 和顶栏那三颗小胶囊**完全同一个入口**（`ImmersiveGlass.pressMaterial`）：
   * `ULTRA_THIN` + 可交互 + 边缘流光 + 不投影，只把着色换成主题色 —— 于是两条栏
   * 是同一套玻璃，选中态就是「同一块玻璃被点亮了一下」。
   *
   * 着色 30% 主题色：比原来那层 10% 底色重，因为材质自己会把颜色打散一部分
   * （模糊 + 折射），真机上不加到这个量就看不出「选中」。
   * 对象按 `档位|颜色` 缓存在 `pressMaterial` 里，这里每帧调也不会 new。
   */
  private barSpotMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    return ImmersiveGlass.pressMaterial(this.glassLevel, Theme.accentAlpha(0.30));
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
