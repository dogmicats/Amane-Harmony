import { Media, Player, PlayerConfig, PlayerState } from '@mpv-ohos/mpv-arkts';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { curves, display, window } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { httpGet } from '../common/Http';
import { GripSense, GripHand } from '../common/GripSense';
import { Store } from '../common/Store';
import { PoolParams } from '../common/PoolParams';
import { Theme } from '../common/Theme';
import { PlayerPrefs } from '../common/PlayerPrefs';
import { addLiked, removeLiked } from '../common/LikedShorts';

/**
 * 短视频流（2.6.2.1）——「刷一刷」。
 *
 * 它不是抖音那种「生成好的 mp4」，而是：服务端给「哪一部、从第几秒开始、放多久」，
 * 这里用本地 mpv 播那个时间窗口，到点自动切下一条。零转码、零存储。
 *
 * 三条设计约束（用户 21:0x 定的）：
 *   1. **竖屏模糊填充**：库里是 16:9，不裁切两侧，用封面放大模糊铺底；
 *   2. **默认静音**：右下角一个喇叭可以开声音（外放场景不吓人）；
 *   3. **只刷本地盘**：网盘 seek 一次几十秒，刷不动 —— 服务端 `/shorts` 已经过滤。
 *
 * 为什么不给每条都挂一个播放器：mpv 实例只有一个，而且切页时重建 surface
 * 经常 attach 不回来（PlayerView 里踩过）。所以视频层**固定在底层**，
 * 上面那层 Swiper 只承载文字信息，换页时只是「换片源 + 换文案」。
 */
interface ShortItem {
  meta_id: number;
  file_id: number;
  start: number;
  dur: number;
  cover: string;
  /** 首帧还没抽出来时（cover 404）的退路：影片海报。老服务端可能没有这个字段，用 ?? '' 兜。 */
  poster?: string;
  score: number;
  skin: number;
  number: string;
  title: string;
  runtime: number;
  /** 右侧栏：女优名（metadata.actors 的第一位，2.6.2.16）。 */
  actor?: string;
  /** 右侧栏头像；查不到就是空串，客户端画首字圆形兜底。 */
  actor_img?: string;
  /** 演员 id（点头像跳演员详情用；0/缺省 = 不跳）。 */
  actor_id?: number;
}

interface ShortsResp {
  ok: boolean;
  items: ShortItem[];
  pending: number;
  reason?: string;
}

/**
 * 刷一刷的**预取缓存**（2.6.2.15 复原 2.6.1.82 的「进来不该有加载态」）。
 *
 * 为什么需要它：负一屏现在是「跟手叠层」，`ShortsView` 只在拖动时才挂载。
 * 以前它是常驻页（App 启动就存在，Swiper 第 0 页），数据早就备好了，所以进来看不到
 * 「正在取片段」；改成叠层后每次进来才发请求，**首次会话必等一次冷计算**
 * （服务端要扫候选，实测 5732ms）→ 加载态又固定出现了。
 *
 * 这里在 App 启动时就把 `/api/user/shorts` 拉一次放进模块缓存：
 *   - 进负一屏直接用缓存铺首屏，**不发请求、不闪加载态**；
 *   - 缓存超过 `SHORTS_CACHE_TTL` 就在后台静默换新，仍然先给旧的（不阻塞）。
 */
let SHORTS_CACHE: ShortItem[] = [];
let SHORTS_CACHE_AT: number = 0;        // 毫秒时间戳
let SHORTS_CACHE_PENDING: number = 0;
let SHORTS_CACHE_ERR: string = '';
let SHORTS_INFLIGHT: Promise<void> | undefined = undefined;
/**
 * 这份缓存对应的「候选池条件串」（`plib=..&ptag=..` 或 `pool=all`）。
 * 用户在设置里改了范围，条件串一变就当作无缓存 —— 否则会拿旧范围的片段继续刷。
 */
let SHORTS_CACHE_KEY: string = '';

/** 清缓存（设置页改条件后调用：下一次进负一屏立即按新范围取）。 */
export function resetShortsCache(): void {
  SHORTS_CACHE = [];
  SHORTS_CACHE_AT = 0;
  SHORTS_CACHE_PENDING = 0;
  SHORTS_CACHE_ERR = '';
  SHORTS_CACHE_KEY = '';
}

/** 缓存多久算旧（到点后台换新；旧数据仍先给，保证首屏零等待）。 */
const SHORTS_CACHE_TTL: number = 120000;

/**
 * 预取 / 取新。幂等：同一时刻只有一个请求在飞，进页面时 `await` 它即可复用。
 * 错误不外抛（避免组件里多一层 try），错误文案存在 `SHORTS_CACHE_ERR`。
 */
export function prefetchShorts(): Promise<void> {
  if (SHORTS_INFLIGHT !== undefined) {
    return SHORTS_INFLIGHT;
  }
  // 条件变了（用户在设置里改了刷一刷的范围）→ 旧缓存作废，立即按新范围取
  const key: string = PoolParams.shortsQuery();
  if (key !== SHORTS_CACHE_KEY) {
    resetShortsCache();
  }
  if (SHORTS_CACHE.length > 0 && Date.now() - SHORTS_CACHE_AT < SHORTS_CACHE_TTL) {
    return Promise.resolve();
  }
  if (!Store.I.ready) {
    return Promise.resolve();
  }
  const task: Promise<void> = doFetchShorts();
  SHORTS_INFLIGHT = task;
  task.then(() => {
    SHORTS_INFLIGHT = undefined;
  }, () => {
    SHORTS_INFLIGHT = undefined;
  });
  return task;
}

async function doFetchShorts(): Promise<void> {
  try {
    // 候选范围（2026-11-14）：跟首页大图共用同一套条件拼法，见 `common/PoolParams.ets`。
    // 开关关掉时这里是 `pool=all`，行为与旧版完全一致。
    const key: string = PoolParams.shortsQuery();
    const text: string = await httpGet(
      `${Store.I.user}/api/user/shorts?limit=20&${key}`, Store.I.token);
    const data: ShortsResp = JSON.parse(text) as ShortsResp;
    const list: ShortItem[] = data.items === undefined || data.items === null ? [] : data.items;
    const pending: number = data.pending === undefined || data.pending === null ? 0 : data.pending;
    SHORTS_CACHE_PENDING = pending;
    SHORTS_CACHE_AT = Date.now();
    SHORTS_CACHE_KEY = key;
    if (list.length > 0) {
      SHORTS_CACHE = list;
      SHORTS_CACHE_ERR = '';
      console.info(`[amane] shorts prefetch ok n=${list.length} pending=${pending}`);
      return;
    }
    // 空结果也记一条：省得每次进来都重打一遍冷查询
    SHORTS_CACHE_ERR = data.reason !== undefined && data.reason.length > 0
      ? data.reason
      : (pending > 0 ? '素材正在准备，稍等一会儿再刷' : '还没有可刷的片段');
  } catch (err) {
    const e = err as BusinessError;
    const code: number = e.code === undefined || e.code === null ? -1 : Number(e.code);
    const msg: string = e.message === undefined || e.message === null ? '' : `${e.message}`;
    const brief: string = msg.length > 60 ? msg.substring(0, 60) : msg;
    SHORTS_CACHE_ERR = brief.length > 0 ? `取不到片段（${code} · ${brief}）` : `取不到片段（${code}）`;
    SHORTS_CACHE_AT = Date.now();
    console.error(`[amane] shorts prefetch: ${code} ${msg}`);
  }
}

@Component
export struct ShortsView {
  /** 退出（由外层 Swiper 或页面壳决定怎么退）。 */
  onClose: () => void = () => {};
  /** 页面重新可见时由 Index 自增：用来重绑 surface（从详情页回来不冻）。 */
  @Prop @Watch('onResumeTick') resumeTick: number = 0;
  @State items: ShortItem[] = [];
  @State idx: number = 0;
  @State err: string = '';
  @State loading: boolean = true;
  @State muted: boolean = true;
  @State ratio: number = 0;          // 当前片段播到哪（0..1）
  /** 这一条**片段内**已播秒数（0..dur）。进度条上写的就是它 —— 不是原片的时间轴。 */
  @State clipPos: number = 0;
  /** 正在拖进度条：期间不让 250ms 的 tick 把滑块拽回去。 */
  @State scrub: boolean = false;
  @State scrubRatio: number = 0;
  /** 刚 seek 完的「保护期」：mpv 的 position 要几百毫秒才跟上，期间别用旧值覆盖进度。 */
  private seekHoldUntil: number = 0;
  /** 自愈节流：播放器被销毁而视图还活着时，最多每 1.5 秒重建一次。 */
  private healAt: number = 0;
  /** 双击点赞的「点亮」动效（0 = 不显示）。 */
  @State burstAlpha: number = 0;
  @State burstScale: number = 0.45;
  @State aspect: number = 16 / 9;    // 视频宽高比（拿到 videoParams 后更新）
  @State pending: number = 0;
  /**
   * 刷一刷的「喜欢」（2.6.2.16，仿抖音右侧爱心）。
   * **和影片收藏分开**：收藏是服务端 favorites（详情页那颗红心），这里只存本地偏好
   * `shorts_likes`（meta_id 逗号串），两边互不影响。
   */
  @State likes: string[] = [];
  /** 头像加载失败的条目（meta_id），这些退回首字圆形。 */
  @State badFaces: string[] = [];
  /** 右滑关闭时的跟手位移（负一屏手感，2.6.1.68）。 */
  @State dragX: number = 0;
  /** 首帧图 404 的条目（`file@start`），渲染时改用 poster。 */
  @State badStills: string[] = [];
  /** 已经**真的加载成功**的图 URL：没成功之前不画，避免出现破图小图标。 */
  @State okImages: string[] = [];
  private player: Player | undefined = undefined;
  private xc: XComponentController = new XComponentController();
  private swiper: SwiperController = new SwiperController();
  private tickId: number = -1;
  private win: window.Window | undefined = undefined;
  private openedKey: string = '';
  /**
   * 本次 `open()` 的时间戳（毫秒）。
   * mpv 换源后 `state.position` 还会**短暂沿用上一条的进度**（PlayerView 里也踩过：
   * seek 后要几帧到一秒才跟上），这段窗口里的 position 不能用来判「播完」。
   */
  private openedAt: number = 0;
  /**
   * 本条片段**已经显示过的最大进度**（片段内相对秒）。
   *
   * 治「进度条先跑到 2 秒、再退回 0 重新走」（2026-11-16 22:48 用户报）：
   * 起播 3 秒内用墙钟兜底（mpv 的 position 还没从起点跟上），第 3 秒一到
   * 切回 position —— 而那时 position 还在 0 附近，于是进度条**倒回 0** 再慢慢爬。
   * 现在只允许前进：`relShown` 低于已显示的最大值就取最大值。
   * 切条 / 用户 seek 时重置（否则往回拖进度条拖不动）。
   */
  private shownMax: number = 0;
  /**
   * 本条片段累计「真的在播」的墙钟秒数（暂停 / 缓冲时不计）。
   *
   * 为什么要单独累计而不是用 `now - openedAt`：mpv 换源后 `position` 从 0 慢慢爬，
   * 只信 position 进度条会卡住（2026-11-16 用户：卡在 2 秒处）；但直接用开始时刻算墙钟，
   * 暂停 10 秒再播时进度条会一口气跳 10 秒。所以只在 `playing && !buffering` 时累加。
   */
  private wallBase: number = 0;
  /** 上一次 tick 的时刻（0 = 不在计时：暂停/缓冲中）。 */
  private lastTick: number = 0;
  /** 正在程序化翻页（播完自动切）：期间别再触发第二次。 */
  private advancing: boolean = false;
  /** 加载态是否该显示（延迟 260ms，避免缓存命中时闪一下）。 */
  @State loadingVisible: boolean = false;
  /**
   * 视频上下留白处铺什么（2.6.2.19）。
   *   1 = 模糊海报底（默认）  0 = 纯黑边
   * 设置 → 刷一刷 里的开关写本机偏好 `shorts_poster_bg`，这里用 AppStorage 单向同步，
   * 改完回刷一刷**立即生效**，不用重启 App。
   */
  @StorageProp('shortsPosterBg') posterBg: number = 1;
  /** 适感握持：左手握持时把右侧那一列挪到左边（系统判不出来就 false）。 */
  @State leftHanded: boolean = false;
  private gripToken: number = -1;

  aboutToAppear(): void {
    this.likes = Store.I.prefString('shorts_likes', '')
      .split(',')
      .filter((k: string) => k.length > 0);
    // 适感握持（2026-11-16）：左手握着就把头像/喜爱/静音这一列挪到左边，
    // 右手就在右边。系统判不出来（老机器/没权限）就保持原来的右侧。
    this.gripToken = GripSense.get().subscribe((h: GripHand) => {
      const left: boolean = h === GripHand.LEFT;
      if (left !== this.leftHanded) {
        // 官方示例用的弹性曲线（curves.interpolatingSpring(0,1,170,17)），
        // 比线性缓动更像「滑过去」而不是「跳过去」。
        animateTo({ curve: curves.interpolatingSpring(0, 1, 170, 17) }, () => {
          this.leftHanded = left;
        });
      }
    });
    this.initPlayer();
    setTimeout(() => {
      this.loadingVisible = true;
    }, 260);
    this.load();
  }

  aboutToDisappear(): void {
    GripSense.get().unsubscribe(this.gripToken);
    this.gripToken = -1;
    this.teardown();
  }

  onPageHide(): void {
    // 去详情页 / 别的页面：**只暂停，不销毁播放器**（2.6.1.68）。
    // 以前这里 teardown()，回来以后没有重建路径 → 回来就卡死。
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        p.pause();
      } catch (err) {
        console.info(`[amane] shorts pause: ${JSON.stringify(err)}`);
      }
    }
  }

  /**
   * 头像加载失败的黑名单**只保留一次失败**，下次进来重试。
   *
   * 用户 23:24 报：「SSNI-021 / DLDSS-545 明明有头像，负一屏只显示文字」。
   * 根因有两条：代理链路（已改成 NAS 代取 + 302 回源），以及这里 ——
   * 原来的 `badFaces` 一旦写进去就整场会话不再试，`onError` 只要赶上一次网络抖动
   * （手机刚启动、切网、NAS 短暂 502），这条就永远只剩首字。
   */
  private retryFaces(): void {
    if (this.badFaces.length > 0) {
      this.badFaces = [];
    }
  }

  /**
   * 负一屏只认「右滑返回」（2.6.1.79）。
   * 系统返回（含左边缘侧滑）在这一页一律吃掉 —— 左滑进来、再左滑回去，方向上是错的。
   */
  onBackPress(): boolean {
    return true;
  }

  /**
   * 组件形态下页面生命周期不会回调，所以由 Index 的 onPageShow 自增 `resumeTick`
   * 通知这里：从详情页回来时重绑 surface + 继续播（2.6.1.82）。
   */
  onResumeTick(): void {
    this.retryFaces();
    if (this.player === undefined) {
      this.initPlayer();
      this.openedKey = '';
      if (this.items.length > 0) {
        this.openAt(this.idx);
      }
      return;
    }
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        p.native.attachSurface(this.xc.getXComponentSurfaceId());
      } catch (err) {
        console.info(`[amane] shorts reattach: ${JSON.stringify(err)}`);
      }
      try {
        p.play();
      } catch (err) {
        console.info(`[amane] shorts resume: ${JSON.stringify(err)}`);
      }
    }
  }

  onPageShow(): void {
    this.retryFaces();
    if (this.player === undefined) {
      this.initPlayer();
      this.openedKey = '';
      if (this.items.length > 0) {
        this.openAt(this.idx);
      }
      return;
    }
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      // 从详情页返回时 surface 已经失效：进度条还在走、画面却冻住（用户 23:56 报的就是这个）。
      // 必须**重新绑定一次 surface**，再继续播。
      try {
        p.native.attachSurface(this.xc.getXComponentSurfaceId());
      } catch (err) {
        console.info(`[amane] shorts reattach: ${JSON.stringify(err)}`);
      }
      try {
        p.play();
      } catch (err) {
        console.info(`[amane] shorts resume: ${JSON.stringify(err)}`);
      }
    }
  }

  private enterFullscreen(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext)
      .then((w: window.Window) => {
        this.win = w;
        w.setWindowLayoutFullScreen(true);
        w.setWindowSystemBarEnable([]);
        w.setPreferredOrientation(window.Orientation.PORTRAIT);
        w.setWindowKeepScreenOn(true).catch(() => {});
      })
      .catch((err: BusinessError) => {
        console.info(`[amane] shorts fullscreen: ${err.code}`);
      });
  }

  private initPlayer(): void {
    try {
      // 重建前先收掉旧 tick（自愈路径可能重复调用，否则每建一次就多一个定时器）
      if (this.tickId >= 0) {
        clearInterval(this.tickId);
        this.tickId = -1;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const tuning = PlayerPrefs.apply(ctx);
      PlayerPrefs.dir(ctx);
      this.player = new Player(new PlayerConfig({
        configDir: PlayerPrefs.dir(ctx),
        // 刷一刷**强制软解**（2026-11-14 用户定）：片段来源杂（.avi/Xvid/DivX/老压制），
        // 硬解对这些格式经常直接黑屏 —— 画面出不来比慢更糟。这里只影响刷一刷自己的实例，
        // 不动 PlayerPage 的冻结参数。
        hwdec: false,
        vo: 'gpu-next',
        osc: false,
        osd: false
      }));
      this.tickId = setInterval(() => {
        this.syncState();
      }, 250);
    } catch (err) {
      const e = err as BusinessError;
      this.err = `播放内核没装好：${e.message}`;
      console.error(`[amane] shorts init: ${e.code} ${e.message}`);
    }
  }

  /**
   * 铺一页数据：**随机起点**用「旋转列表」实现，而不是跳页。
   *
   * 2.6.2.15 修的坑：以前算完 `start` 只调 `swiper.changeIndex(start)`，但那一刻 Swiper
   * 还没构建（`items` 刚赋值、页面还没渲染），异常被 catch 吞掉 → Swiper 永远停在
   * **第 0 页**，所以「第一个片段永远一样」（真机三次进出都是 THP-78）。
   *
   * 不再跟 Swiper 的 `index` 较劲（那套和滑动会互相抢），改成把列表**从随机处切开再接回**：
   * 第 0 页天然就是随机那一条，翻页仍是完整 20 条，只是起点不同。
   */
  private applyItems(list: ShortItem[]): void {
    let ordered: ShortItem[] = list;
    if (list.length > 1) {
      const start: number = Math.floor(Math.random() * list.length);
      ordered = list.slice(start).concat(list.slice(0, start));
    }
    this.items = ordered;
    this.pending = SHORTS_CACHE_PENDING;
    this.loading = false;
    this.idx = 0;
    this.openAt(0);
  }

  private async load(): Promise<void> {
    if (!Store.I.ready) {
      this.loading = false;
      this.err = '还没连上服务器';
      return;
    }
    // ① 预取缓存命中：直接用，**不发请求**（这是「进来不闪加载态」的关键）
    if (SHORTS_CACHE.length > 0) {
      // 验收判据：真机 `hilog -x | grep 'shorts cache'` 应看到 hit（hit 才不会闪加载态）
      console.info(`[amane] shorts cache hit n=${SHORTS_CACHE.length} age=${Date.now() - SHORTS_CACHE_AT}ms`);
      this.applyItems(SHORTS_CACHE);
      if (Date.now() - SHORTS_CACHE_AT >= SHORTS_CACHE_TTL) {
        // 旧了就在后台静默换新，不阻塞、不改当前这一屏
        prefetchShorts();
      }
      return;
    }
    // ② 没有缓存：等预取（可能就是启动时那次，复用它而不是再打一遍冷查询）
    console.info('[amane] shorts cache miss');
    try {
      await prefetchShorts();
      if (SHORTS_CACHE.length > 0) {
        this.applyItems(SHORTS_CACHE);
        return;
      }
      this.loading = false;
      this.pending = SHORTS_CACHE_PENDING;
      this.err = SHORTS_CACHE_ERR.length > 0 ? SHORTS_CACHE_ERR : '还没有可刷的片段';
    } catch (err) {
      const e = err as BusinessError;
      this.loading = false;
      // 调试期必须带出真实原因：只写「取不到片段」等于把线索吞了
      const code: number = e.code === undefined || e.code === null ? -1 : Number(e.code);
      const msg: string = e.message === undefined || e.message === null ? '' : `${e.message}`;
      const brief: string = msg.length > 60 ? msg.substring(0, 60) : msg;
      this.err = brief.length > 0 ? `取不到片段（${code} · ${brief}）` : `取不到片段（${code}）`;
      console.error(`[amane] shorts load: ${code} ${msg}`);
    }
  }

  private cur(): ShortItem | undefined {
    return this.idx >= 0 && this.idx < this.items.length ? this.items[this.idx] : undefined;
  }

  // ---- 右侧栏（仿抖音，2.6.2.16）----
  // 注意：这些方法都**按条目传参**，不再读 this.cur()。
  // 因为右侧栏已经放进每一页（InfoLayer）里，刷动时要跟着那一页走（2026-11-14 21:50 用户要求），
  // 读 this.cur() 会在翻页动画期间取到"新的当前条"，导致两页的按钮内容不一致。

  private actorNameOf(it: ShortItem): string {
    const n: string = it.actor === undefined || it.actor === null ? '' : it.actor;
    return n;
  }

  /** 头像地址：绝对 http 直接给，服务端相对路径才拼 token。 */
  private actorImgOf(it: ShortItem): string {
    const raw: string = it.actor_img === undefined || it.actor_img === null ? '' : it.actor_img;
    if (raw.length === 0) {
      return '';
    }
    return raw.startsWith('http') ? raw : Store.I.img(raw);
  }

  private actorInitialOf(it: ShortItem): string {
    const n: string = this.actorNameOf(it);
    return n.length > 0 ? n.substring(0, 1) : '·';
  }

  /** 右侧栏的左上角坐标（vp）：右下角对齐，列宽 56、列高约 168、右边距 10、底部留 150。 */
  private colX(): number {
    // 适感握持（2026-11-16）：左手握持时整列镜像到左边距 10vp，
    // 右手/判不出来就是原来的右边距。位置变了用动画过渡，别让拇指下的按钮突然跳。
    return this.leftHanded ? 10 : this.screenW() - 66;
  }

  private colY(): number {
    // 底部要**避开信息块**（番号/标题/进度条约占底部 220vp）：
    // -318 时实测静音键压到标题上（布局树：列底 2473px vs 标题顶 2290px），故再上提 62vp。
    return this.screenH() - 380;
  }

  private screenW(): number {
    try {
      return px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
      return 390;
    }
  }

  private screenH(): number {
    try {
      return px2vp(display.getDefaultDisplaySync().height);
    } catch (e) {
      return 844;
    }
  }

  private liked(it: ShortItem): boolean {
    return this.likes.indexOf(`${it.meta_id}`) >= 0;
  }

  private toggleLike(it: ShortItem): void {
    const key: string = `${it.meta_id}`;
    const on: boolean = this.likes.indexOf(key) < 0;
    if (on) {
      this.likes = this.likes.concat([key]);
    } else {
      this.likes = this.likes.filter((k: string) => k !== key);
    }
    Store.I.prefSetString('shorts_likes', this.likes.join(','));
    // 「我的喜爱」列表的数据源：连**片段起点**一起记，点进去能回到那一秒。
    // 注意这和正片收藏（服务端 favorites）完全无关，用户 23:53 要求表达上分开。
    if (on) {
      addLiked({
        id: it.meta_id,
        number: it.number,
        title: it.title,
        poster: it.poster === undefined || it.poster === null ? '' : it.poster,
        start: it.start,
        dur: it.dur,
        actor: it.actor === undefined || it.actor === null ? '' : it.actor,
        actorImg: it.actor_img === undefined || it.actor_img === null ? '' : it.actor_img,
        at: Date.now()
      });
    } else {
      removeLiked(it.meta_id);
    }
  }

  /** 点头像 → 演员详情页（要有 actor_id；没有就只当装饰，别跳错人）。 */
  private openActor(it: ShortItem): void {
    const id: number = it.actor_id === undefined || it.actor_id === null ? 0 : it.actor_id;
    if (id <= 0) {
      return;
    }
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        p.pause();
      } catch (err) {
        console.info(`[amane] shorts pause before actor: ${JSON.stringify(err)}`);
      }
    }
    router.pushUrl({
      url: 'ext/actors/ActorDetailPage',
      params: { id: id, name: this.actorNameOf(it) }
    }).catch((err: BusinessError) => {
      console.error(`[amane] shorts -> actor: ${err.code} ${err.message}`);
    });
  }

  /**
   * 视频层的宽高比。
   *
   * 拿到 mpv 的 `videoParams` 后用真实比例，拿不到就按 16:9 兜底 ——
   * 这一条**不是装饰**：XComponent 必须比屏幕矮一点，上下才能露出模糊背景
   * （SURFACE 不透明，铺满就把背景整块盖死）。
   */
  private videoAspect(): number {
    const a: number = this.aspect;
    return a > 0.4 && a < 3.5 ? a : 16 / 9;
  }

  private openAt(i: number): void {
    const it: ShortItem | undefined = i >= 0 && i < this.items.length ? this.items[i] : undefined;
    const p: Player | undefined = this.player;
    if (it === undefined || p === undefined) {
      return;
    }
    // 同一个片段的同一秒只开一次（Swiper 的 onChange 与 index 变化都会进来）
    const key: string = `${it.file_id}@${it.start}`;
    if (this.openedKey === key) {
      return;
    }
    this.openedKey = key;
    this.openedAt = Date.now();
    this.ratio = 0;
    // 换条：进度条从头开始，单调兜底的基准也要归零（否则新片段会顶着上一条的进度）
    this.shownMax = 0;
    this.wallBase = 0;
    this.lastTick = 0;
    // 判据日志：`hilog -x | grep 'shorts open'` 能核对「显示的那页」和「实际开的片」是否一致
    console.info(`[amane] shorts open idx=${i} n=${it.number} start=${it.start} dur=${it.dur}`);
    try {
      const url: string = Store.I.playSource(it.meta_id, '');
      // 换条必须**先停**再开（2.6.1.68）：同一个 Player 连续 open 时，
      // 上一条的 VO 还在画旧帧 —— 表现就是「只有 UI 动了、画面原地刷新」。
      try {
        p.stop();
      } catch (stopErr) {
        console.info(`[amane] shorts stop: ${JSON.stringify(stopErr)}`);
      }
      p.open(new Media(url, { start: it.start }));
      // 横板片**按原比例**显示，上下留模糊底图（用户 2026-11-13 23:56：
      // 「说好了不能拉伸裁剪」）。所以这里不用 panscan 裁切，保持 keepaspect。
      // open 之后明确拉一把播放，避免沿用上一段落下的暂停态
      try {
        p.play();
      } catch (playErr) {
        console.info(`[amane] shorts play: ${JSON.stringify(playErr)}`);
      }
      this.applyMute();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] shorts open: ${e.code} ${e.message}`);
    }
  }

  private applyMute(): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      p.native.setProperty('volume', this.muted ? 0 : 100);
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] shorts volume: ${e.code}`);
    }
  }

  private syncState(): void {
    const p: Player | undefined = this.player;
    const it: ShortItem | undefined = this.cur();
    if (p === undefined || it === undefined) {
      // 自愈（2026-11-15 用户报「进度条永远 0:00/0:10、拖不动点不动」）：
      // 只要播放器被 teardown 掉（离开再回来、页面壳重排）而视图还活着，syncState 与
      // seekClip 都会静默 return —— 表现就是时间永远 0:00、Slider 怎么点都没反应。
      // 这里节流重建一次：正常路径上 player 不会为空，所以这段平时不会触发。
      if (p === undefined && it !== undefined && Date.now() - this.healAt > 1500) {
        this.healAt = Date.now();
        console.info('[amane] shorts heal（播放器为空，重建后重开当前条）');
        this.initPlayer();
        this.openAt(this.idx);
      }
      return;
    }
    try {
      // 显式类型（2026-11-14）：ArkTS 不允许隐式 any，`const st = p.state` 会编译失败
      const st: PlayerState | undefined = p.state;
      if (st === undefined || st === null) {
        return;
      }
      const span: number = it.dur > 0 ? it.dur : 10;
      const rel: number = st.position - it.start;
      // 播放墙钟：只在「真的在播且没在缓冲」时累计（暂停不计，否则恢复播放会一次跳一大截）。
      // seek 刚落下后的保护期也停表：那时 wallBase 已压到目标位置，若继续累加，
      // 保护期一过进度条会比实际快 1 秒多（position 才刚到位）。
      const nowMs: number = Date.now();
      const inHold: boolean = nowMs < this.seekHoldUntil;
      if (st.playing && !st.buffering && !inHold) {
        if (this.lastTick > 0) {
          this.wallBase += (nowMs - this.lastTick) / 1000;
        }
        this.lastTick = nowMs;
      } else {
        this.lastTick = 0;
      }
      if (this.scrub) {
        // 拖进度条时用用户手的位置，别被 tick 拽回去（松手后 mpv 要几百毫秒才跟上）
        this.ratio = this.scrubRatio;
      } else if (Date.now() < this.seekHoldUntil) {
        // 刚点/拖完进度条：这个窗口里的 position 还是 seek 之前的旧值，
        // 拿它算 ratio 会让滑块「跳一下又弹回去」（真机 23:44 实测），保持乐观值不动。
      } else {
        let relShown: number = Math.max(0, Math.min(span, rel));
        // 墙钟兜底（2026-11-15 立、2026-11-16 改成「持续顶」）：
        // mpv 换源后 `state.position` 要从 0 慢慢爬上来（画面已经在动、position 还停在 start），
        // 只信 position 就是「片段都播了一会了条才动」。
        // 原来只顶 3 秒，第 3 秒切回 position 时它多半还没追上 —— 于是条从 3 秒**倒回 0**
        // （用户报的「跑两秒退回 0」）；改成单调前进后又变成**卡在 2 秒**等 position 追上来。
        // 现在改成：只要 position 落后实际播放墙钟，就一直用墙钟顶着（不设 3 秒天花板）；
        // 墙钟只在 playing && !buffering 时累计，所以暂停/缓冲时条不会假走。
        const wall: number = Math.min(span, this.wallBase);
        if (relShown < wall - 0.35) {
          relShown = wall;
        }
        // 兜底：无论如何不许回退（回退由 seek 造成，seek 会重置 shownMax / wallBase）
        if (relShown < this.shownMax) {
          relShown = this.shownMax;
        } else {
          this.shownMax = relShown;
        }
        this.ratio = Math.max(0, Math.min(1, relShown / span));
        this.clipPos = relShown;
      }
      // 真实画面比例：有了就套上，上下留白才是「模糊填充」而不是黑边
      // 不声明中间变量：`VideoParams` 不从包根导出，靠 `st.videoParams` 的声明类型推导
      if (st.videoParams !== undefined && st.videoParams !== null
        && st.videoParams.w > 0 && st.videoParams.h > 0) {
        const a: number = st.videoParams.w / st.videoParams.h;
        if (a > 0.4 && a < 3.5 && Math.abs(a - this.aspect) > 0.01) {
          this.aspect = a;
        }
      }
      // 播过片段尾部就自动切下一条 —— 但必须排除两种情况，否则会「连跳」：
      //   ① 刚 `open()` 的 1.5 秒内：`position` 还是上一条的进度（mpv 换源要几帧~1 秒才跟上），
      //      拿旧值算 rel 会当场满足「播完」→ 一条接一条地跳；
      //      用户翻回去时又立刻被拽回来，看着就是死循环（2026-11-14 20:47 反馈）。
      //   ② rel 远大于 span：那是旧值/异常值，不是"刚好播完"；
      //      正常播完时 rel 只会比 span 多出不到一个 tick（250ms）。
      if (this.advancing || Date.now() - this.openedAt < 1500) {
        return;
      }
      if (rel >= span && rel <= span + 3) {
        console.info(`[amane] shorts finish idx=${this.idx} n=${it.number} rel=${rel.toFixed(1)} span=${span}`);
        this.go(1);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] shorts state: ${e.code}`);
    }
  }

  /**
   * 程序化翻页（播完自动切下一条）。
   *
   * 2.6.2.15 修死循环：以前在这里**先 `openAt(next)`、再 `showNext()`** ——
   * 同一帧里 `stop() + open()` 会和 Swiper 的翻页动画抢时序，新片源**根本没打开**：
   * 实测 `position` 冻在上一条的结尾（1971.9），`rel` 变成 673（> span），
   * 于是下一次 tick 又判「播完」→ 再跳一条……用户翻回去也会被立刻顶回来，看着就是死循环。
   * 手动滑动一直正常，因为它的 `open` 发生在 `onChange`（动画结束之后）。
   * 所以这里**不自己 open**，只推 Swiper，让 `onChange` 走和手滑完全相同的路径。
   */
  private go(delta: number): void {
    if (this.items.length === 0 || this.advancing) {
      return;
    }
    const next: number = Math.max(0, Math.min(this.items.length - 1, this.idx + delta));
    if (next === this.idx) {
      return;
    }
    this.advancing = true;
    if (delta > 0) {
      this.swiper.showNext();
    } else {
      this.swiper.showPrevious();
    }
    // 兜底：万一 onChange 没来（动画被打断/已经在边界），补一次；正常情况 onChange 已把 idx 改掉。
    setTimeout(() => {
      this.advancing = false;
      if (this.idx !== next) {
        console.info(`[amane] shorts go fallback idx=${this.idx} -> ${next}`);
        this.idx = next;
        this.openAt(next);
      }
    }, 520);
  }

  private close(): void {
    this.teardown();
    this.onClose();
  }

  private teardown(): void {
    console.info('[amane] shorts teardown（离开负一屏，释放播放器）');
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
    const p: Player | undefined = this.player;
    this.player = undefined;
    if (p !== undefined) {
      try {
        p.stop();
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] shorts stop: ${e.code}`);
      }
      // **只 stop 不够**（用户 23:53：退回主页后声音还在放）。mpv 的 stop 只是停下当前
      // 播放，解码/音频输出线程还活着；`destroy()` 才是真正释放。PlayerView / FloatPlayerCard
      // 销毁播放器时用的也是 destroy（见那两处的调用）。
      try {
        p.destroy();
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] shorts destroy: ${e.code}`);
      }
    }
    if (this.win !== undefined) {
      try {
        this.win.setWindowKeepScreenOn(false);
        this.win.setWindowLayoutFullScreen(false);
        this.win.setWindowSystemBarEnable(['status', 'navigation']);
        this.win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] shorts exit: ${e.code}`);
      }
      this.win = undefined;
    }
  }

  /** 模糊铺底的封面：视频没起来之前它就是背景，起来了也当上下留白的填充。 */
  /**
   * 视频层（2.6.1.72）：**放进 Swiper 当前页里**，划动时画面跟着手指一起走。
   *
   * 只有一个解码器，所以「下一条」用 `cover`（就是这条片段起始时刻的首帧）当占位 ——
   * 松手切页、`open()` 一到位就是同一帧继续播，观感上等于「切过来直接放」。
   */
  @Builder
  VideoLayer() {
    Column() {
      XComponent({ id: 'amane_shorts', type: XComponentType.SURFACE, controller: this.xc })
        .onLoad(() => {
          const p: Player | undefined = this.player;
          if (p === undefined) {
            return;
          }
          try {
            p.native.attachSurface(this.xc.getXComponentSurfaceId());
            if (this.items.length > 0 && this.openedKey.length === 0) {
              this.openAt(this.idx);
            }
          } catch (err) {
            const e = err as BusinessError;
            console.error(`[amane] shorts surface: ${e.code} ${e.message}`);
          }
        })
        .width('100%')
        .aspectRatio(this.videoAspect())
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 这里**保持 None**：这一层只要盖住画面、不参与命中。
    // 2026-11-14 23:41 试过改成 Transparent + onClick 来收双击 —— 结果整个负一屏
    // 的点击全哑了（连「看详情」都点不动，退出负一屏后点击又正常）。
    // 双击改成在 InfoLayer 的 Stack 上用 onTouch 自己判（见那里的注释）。
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 铺底/占位用哪张图（2.6.1.89）：**优先影片海报**（一定存在），
   * 没有海报才退回片段首帧（可能 404）。
   */
  private stillOf(it: ShortItem): string {
    const poster: string = it.poster === undefined || it.poster === null ? '' : it.poster;
    if (poster.length > 0) {
      return poster;
    }
    const key: string = `${it.file_id}@${it.start}`;
    if (this.badStills.indexOf(key) < 0 && it.cover.length > 0) {
      return it.cover;
    }
    return '';
  }

  /** 非当前页的占位：片段首帧原图；首帧还没抽出来（404）就退到海报，**不留黑屏**。 */
  @Builder
  StillLayer(it: ShortItem) {
    Column() {
      Stack() {
        // 兜底底色：渐变而不是纯黑，图没加载出来也不像坏掉
        Column()
          .width('100%')
          .aspectRatio(this.videoAspect())
          .linearGradient({
            angle: 135,
            colors: [['#1A1A1F', 0], ['#2A2118', 1]]
          })
        // 拿不到图就**不渲染 Image**（渲染空串会留一个破图小图标），只留渐变底
        // 并且：**加载成功后才显示**（opacity 0→1），失败就永远不画 —— 彻底消掉破图占位
        if (this.stillOf(it).length > 0) {
          Image(Store.I.img(this.stillOf(it)))
            .width('100%')
            .aspectRatio(this.videoAspect())
            .objectFit(ImageFit.Contain)
            .opacity(this.okImages.indexOf(this.stillOf(it)) >= 0 ? 1 : 0)
            .onComplete(() => {
              const url: string = this.stillOf(it);
              if (url.length > 0 && this.okImages.indexOf(url) < 0) {
                this.okImages = this.okImages.concat([url]);
              }
            })
            .onError(() => {
              // cover 404（抽帧还没跑完）→ 记下来，别再试；**不动 items 本身**
              const key: string = `${it.file_id}@${it.start}`;
              if (this.badStills.indexOf(key) < 0) {
                this.badStills = this.badStills.concat([key]);
              }
            })
        }
      }
      .width('100%')
      .aspectRatio(this.videoAspect())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 一页的铺底（2.6.2.19 从「根层钉死」搬进每一页）。
   *
   * 用户 22:09：「不管我怎么滑动，海报背景一直是同一张，逻辑上有问题」。
   * 原来这块画在**根 Stack** 上、取的是 `items[idx]` —— 索引要等 Swiper 的 onChange
   * 才更新，所以划动过程中背景永远停在上一条（或第一条）不动，看着像一张贴纸。
   * 现在它成为每一页自己的底层，跟着这一页一起被刷走。
   *
   * `posterBg === 0`（设置里选「纯黑边」）时只铺黑，连那次全屏模糊都不做。
   */
  @Builder
  Backdrop(it: ShortItem) {
    if (this.posterBg === 0) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
    } else {
      // 底色先铺一层暖灰渐变：cover 404 时也不会是一片纯黑（2.6.1.88）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#141419', 0], ['#2B231A', 0.55], ['#141419', 1]]
        })
      if (this.stillOf(it).length > 0 && this.badStills.indexOf(`bg:${it.meta_id}`) < 0) {
        Image(Store.I.img(this.stillOf(it)))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(48)
          .scale({ x: 1.25, y: 1.25 })
          .opacity(this.okImages.indexOf(`bg:${this.stillOf(it)}`) >= 0 ? 0.55 : 0)
          .onComplete(() => {
            const url: string = `bg:${this.stillOf(it)}`;
            if (this.okImages.indexOf(url) < 0) {
              this.okImages = this.okImages.concat([url]);
            }
          })
          .onError(() => {
            // 底图也加载失败时**别再画**（否则左上角会留一个破图小图标），只保留渐变底
            const key: string = `bg:${it.meta_id}`;
            if (this.badStills.indexOf(key) < 0) {
              this.badStills = this.badStills.concat([key]);
            }
          })
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
    }
  }

  /** 每条的信息层：番号、标题、进度。文字层不吃手势，滑动交给 Swiper。 */
  @Builder
  InfoLayer(it: ShortItem, i: number) {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 0) 本页自己的模糊海报底（2.6.2.19）：跟着这一页一起被刷走。
      //    以前画在根 Stack 上取 items[idx]，划动时索引还没动 → 背景永远是同一张。
      this.Backdrop(it)
      // 当前页放视频（跟手划走），其它页放首帧占位；页面底层是海报 → 上下留白处露出它
      if (i === this.idx) {
        this.VideoLayer()
      } else {
        this.StillLayer(it)
      }
      // 底部压一层渐变，保证文字在亮画面上也看得清（不挡画面中间，2.6.1.81）
      Column()
        .width('100%')
        .height(220)
        .align(Alignment.BottomStart)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#CC000000', 1]]
        })
        .hitTestBehavior(HitTestMode.None)
      Column({ space: 8 }) {
        // 番号兼作「去详情」的入口（用户 22:06：看中了的片段要能跳详情页）
        Row({ space: 8 }) {
          Text(it.number)
            .fontSize(13)
            .fontColor(Theme.GOLD)
            .fontWeight(FontWeight.Medium)
          Text('看详情 ›')
            .fontSize(11)
            .fontColor('#E6FFFFFF')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('#4D000000')
            .borderRadius(10)
            .onClick(() => {
              this.gotoDetail(it.meta_id);
            })
        }
        .width('100%')
        Text(it.title.length > 0 ? it.title : it.number)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.gotoDetail(it.meta_id);
          })
        Text('这一段从 ' + this.clock(it.start) + ' 开始')
          .fontSize(11)
          .fontColor('#99FFFFFF')
          .width('100%')
        this.ClipBar(it, i)
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 34 })
      .alignItems(HorizontalAlign.Start)
      .align(Alignment.BottomStart)

      // 右侧栏（头像 / 爱心 / 静音）**放在每一页里面**：
      // 这样上下刷的时候它跟着画面一起位移，而不是像贴纸一样原地刷新
      // （2026-11-14 21:50 用户要求：「这三个 UI 要跟着视频一起跑」）。
      // 定位仍是「只占自己那块」的右下角锚定，别用全屏包装层（那样会吃掉点击）。
      Column({ space: 18 }) {
        this.AvatarCell(it)
        this.LikeCell(it)
        this.MuteCell()
      }
      .width(56)
      .alignItems(HorizontalAlign.Center)
      // 用**显式坐标**（不用 markAnchor/translate）：后者会同时挪动绘制与命中区，
      // 在 Swiper 页里实测点不到（2026-11-14 21:57：点头像没反应，但同页的「看详情」能点）。
      .position({ x: this.colX(), y: this.colY() })

      // 双击点赞的「点亮」动效：一颗大爱心从 0.45 弹到 1.18 再淡出（用户 23:32 要求）。
      // 放在最上层但不吃手势（hitTestBehavior None），否则中间的「点两下」会被它挡掉。
      if (i === this.idx && this.burstAlpha > 0) {
        Row() {
          Image($r('app.media.ic_s_heart_on'))
            .width(120)
            .height(120)
            .objectFit(ImageFit.Contain)
            .scale({ x: this.burstScale, y: this.burstScale })
            .opacity(this.burstAlpha)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    // 双击画面 = 点赞。**不挂 onClick / TapGesture**：这一层是 Swiper 的一页，
    // 给它加可命中节点会把整页的点击吞掉（2026-11-14 23:41 实测：「看详情」也点不动了）。
    // 改成只听 onTouch —— 不参与命中测试，向下传递不受影响；
    // 判定：单次按下→抬起 < 260ms 且位移 < 12vp 记一次「点」，两次点间隔 < 300ms = 双击。
    .onTouch((e: TouchEvent) => {
      if (i !== this.idx) {
        return;
      }
      if (e.type === TouchType.Down) {
        this.tapDownAt = Date.now();
        const t: TouchObject = e.touches[0];
        this.tapDownX = t.x;
        this.tapDownY = t.y;
        return;
      }
      if (e.type === TouchType.Up) {
        const dt: number = Date.now() - this.tapDownAt;
        const t: TouchObject = e.changedTouches.length > 0 ? e.changedTouches[0] : e.touches[0];
        const moved: number = Math.abs(t.x - this.tapDownX) + Math.abs(t.y - this.tapDownY);
        if (dt < 260 && moved < 12) {
          this.onStageTap(it);
        }
      }
    })
  }

  private gotoDetail(mid: number): void {
    // **不要 teardown**（2.6.1.82）：组件还活着，销毁播放器回来就没 surface 了 → 直接崩。
    // 只暂停；回来由 Index 的 resumeTick 重绑 surface 并继续播。
    const it: ShortItem | undefined = this.cur();
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        p.pause();
      } catch (err) {
        console.info(`[amane] shorts pause before detail: ${JSON.stringify(err)}`);
      }
    }
    router.pushUrl({
      url: 'pages/DetailPage',
      params: { id: mid, position: it === undefined ? 0 : it.start }
    }).catch((err: BusinessError) => {
      console.error(`[amane] shorts -> detail: ${err.code} ${err.message}`);
    });
  }

  private clock(sec: number): string {
    const s: number = Math.max(0, Math.floor(sec));
    const h: number = Math.floor(s / 3600);
    const m: number = Math.floor((s % 3600) / 60);
    const ss: number = s % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const sss: string = ss < 10 ? `0${ss}` : `${ss}`;
    return h > 0 ? `${h}:${mm}:${sss}` : `${m}:${sss}`;
  }

  /** 这一条**片段**的进度条（0..dur 秒），点/拖都能跳 —— 用户 23:32 反馈原来的只是一条装饰线。 */
  @Builder
  ClipBar(it: ShortItem, i: number) {
    Column({ space: 4 }) {
      Row() {
        Text(this.clock(this.clipPos) + ' / ' + this.clock(this.spanOf(it)))
          .fontSize(11)
          .fontColor('#E6FFFFFF')
        Blank()
        // 原片时间轴只作为「这段出自哪儿」的线索，进度本身按片段算
        Text('原片 ' + this.clock(it.start))
          .fontSize(10)
          .fontColor('#80FFFFFF')
      }
      .width('100%')

      Slider({
        value: (i === this.idx ? (this.scrub ? this.scrubRatio : this.ratio) : 0) * 100,
        min: 0,
        max: 100,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .height(22)
        .trackThickness(3)
        .selectedColor(Theme.GOLD)
        .trackColor('#4DFFFFFF')
        .blockColor('#FFFFFF')
        .blockSize({ width: 10, height: 10 })
        .enabled(i === this.idx)
        .onChange((v: number, mode: SliderChangeMode) => {
          if (i !== this.idx) {
            return;
          }
          if (mode === SliderChangeMode.Begin) {
            this.scrub = true;
            this.scrubRatio = v / 100;
          } else if (mode === SliderChangeMode.Moving) {
            this.scrubRatio = v / 100;
          } else {
            // End / Click：松手才真正 seek，拖动过程中不发命令
            this.scrub = false;
            // **用当前条（this.cur()）算落点，不要用 builder 形参 `it`**（2026-11-15 修）：
            // @Builder 的参数是**按值**传的，翻页后这一份可能还是上一条的 start，
            // seek 到「上一条的起点 + 百分比」就会落在当前片段之外 —— 实测表现为
            // 进度条一直 0:00 / 0:10、点了也像没反应（position 被打到负区间被夹回 0）。
            const live: ShortItem | undefined = this.cur();
            this.seekClip(live === undefined ? it : live, v / 100);
          }
        })
    }
    .width('100%')
    // 横向拖动要留给进度条自己，别被 Swiper 的翻页吃掉
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down || e.type === TouchType.Move) {
        e.stopPropagation();
      }
    })
  }

  /** 片段时长（服务端给 dur，缺省 10 秒）。 */
  private spanOf(it: ShortItem): number {
    return it.dur > 0 ? it.dur : 10;
  }

  /** 跳到片段内的 p（0..1）。落点是 `原片起点 + p×片段长度`。 */
  private seekClip(it: ShortItem, p: number): void {
    const span: number = this.spanOf(it);
    const r: number = Math.max(0, Math.min(1, p));
    // 先落 UI，再发 seek：mpv 的 position 要几百毫秒才跟上，否则滑块会先弹回去一下
    this.ratio = r;
    this.clipPos = r * span;
    // seek 是唯一允许「进度条往回走」的操作：把单调兜底的基准压到目标位置，
    // 否则上面 feedState 的 shownMax 会把往回拖的动作挡住（拖不动）。
    this.shownMax = r * span;
    // 墙钟也从这个位置重新起算，否则 seek 之后进度条会被旧墙钟一把推回原处
    this.wallBase = r * span;
    this.lastTick = 0;
    const pl: Player | undefined = this.player;
    if (pl === undefined) {
      return;
    }
    try {
      const target: number = Math.max(0, it.start + r * span);
      pl.seek(target);
      pl.play();
      // 1.2 秒内不采信 position：seek 之后 mpv 的 state.position 要几帧到一秒才跟上来，
      // 这段窗口里的旧值会把刚拖好的进度条打回 0（真机 23:44 就是这么「跳完又回去」的）。
      this.seekHoldUntil = Date.now() + 1200;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] shorts clip seek: ${e.code}`);
    }
  }

  /** 双击检测用：上一次「点」的时刻 / 这次按下的时间与坐标。 */
  private lastTapAt: number = 0;
  private tapDownAt: number = 0;
  private tapDownX: number = 0;
  private tapDownY: number = 0;

  /** 画面上的单击/双击（双击 = 点赞）。 */
  private onStageTap(it: ShortItem): void {
    const now: number = Date.now();
    // 窗口 420ms：真机双击通常 150~250ms，给到 420 才不容易「点了没反应」；
    // 再长就会把两次独立单击误判成双击（用户自己滑着看时容易碰到）。
    if (now - this.lastTapAt < 420) {
      this.lastTapAt = 0;
      console.info(`[amane] shorts double like ${it.number}`);
      this.doubleLike(it);
      return;
    }
    this.lastTapAt = now;
  }

  /** 双击点赞：已赞就只放动效（不像点赞按钮那样取消）。 */
  private doubleLike(it: ShortItem): void {
    const key: string = `${it.meta_id}`;
    if (this.likes.indexOf(key) < 0) {
      this.toggleLike(it);
    }
    this.popHeart();
  }

  /** 爱心「点亮」动效：0.45 → 1.0 → 1.18（回落）→ 1.4 淡出。 */
  private popHeart(): void {
    this.burstScale = 0.45;
    this.burstAlpha = 0;
    animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
      this.burstAlpha = 0.95;
      this.burstScale = 1;
    });
    animateTo({ duration: 300, delay: 140, curve: Curve.Friction }, () => {
      this.burstScale = 1.18;
    });
    setTimeout(() => {
      animateTo({ duration: 220, curve: Curve.EaseIn }, () => {
        this.burstAlpha = 0;
        this.burstScale = 1.4;
      });
    }, 470);
  }

  /** 女优头像：有图用图，没图（或图挂了）画首字圆形，永不留破图。点一下进演员详情。 */
  @Builder
  AvatarCell(it: ShortItem) {
    Stack() {
      if (this.actorImgOf(it).length > 0 && this.badFaces.indexOf(`${it.meta_id}`) < 0) {
        Image(this.actorImgOf(it))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .onError(() => {
            const key: string = `${it.meta_id}`;
            if (this.badFaces.indexOf(key) < 0) {
              this.badFaces = this.badFaces.concat([key]);
            }
          })
      } else {
        Text(this.actorInitialOf(it))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .width(50)
    .height(50)
    .borderRadius(25)
    .backgroundColor('#40FFFFFF')
    .border({ width: 1.5, color: '#CCFFFFFF' })
    .clip(true)
    .onClick(() => {
      this.openActor(it);
    })
  }

  /** 爱心：喜欢是实心玫红，没喜欢是白描边（抖音那套手感）。 */
  @Builder
  LikeCell(it: ShortItem) {
    Column() {
      Image(this.liked(it) ? $r('app.media.ic_s_heart_on') : $r('app.media.ic_s_heart'))
        .width(30)
        .height(30)
        .objectFit(ImageFit.Contain)
        // 点亮时弹一下（用户 23:32 要动效）：1 → 1.15 用带摩擦的回弹，别用线性
        .scale({ x: this.liked(it) ? 1.15 : 1, y: this.liked(it) ? 1.15 : 1 })
        .animation({ duration: 240, curve: Curve.Friction })
    }
    .width(46)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.toggleLike(it);
    })
  }

  /** 静音开关：矢量喇叭（原来那个 emoji 用户说不好看）。 */
  @Builder
  MuteCell() {
    Column() {
      Image(this.muted ? $r('app.media.ic_s_vol_off') : $r('app.media.ic_s_vol'))
        .width(20)
        .height(20)
        .objectFit(ImageFit.Contain)
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#33000000')
    .onClick(() => {
      this.muted = !this.muted;
      this.applyMute();
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1) 根层只留一块黑底兜底（空态 / 首帧还没画时用它）。
      //    模糊海报底已经**下放到每一页**（见 InfoLayer → Backdrop）：跟着手指一起刷走。
      Column().width('100%').height('100%').backgroundColor('#000000')

      // 2) 视频层已挪进 Swiper 的当前页（见 InfoLayer → VideoLayer），
      //    这样划动时画面跟着手指走；这里不再钉一层。

      // 3) 文字层：Swiper 承载上下滑
      if (this.items.length > 0) {
        Swiper(this.swiper) {
          ForEach(this.items, (it: ShortItem, i: number) => {
            this.InfoLayer(it, i)
          }, (it: ShortItem, i: number) => `sh-${it.file_id}-${i}`)
        }
        .vertical(true)
        .indicator(false)
        .loop(false)
        // 用户 22:06「偶有触发突然划几下」：一次手势只走一页，别让惯性连翻。
        .cachedCount(1)
        .duration(260)
        .curve(Curve.EaseOut)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          console.info(`[amane] shorts onChange index=${index} idx=${this.idx}`);
          // 换一条就把「头像失败」的清掉重试（见 retryFaces）：一次抖动不该让这位演员
          // 在这一整场会话里都只剩首字。
          this.retryFaces();
          if (index !== this.idx) {
            this.idx = index;
            this.openAt(index);
          }
        })
      }

      // 4) 右侧栏（仿抖音，2.6.2.16）：女优头像 / 爱心 / 静音。
      //    用户 21:20：「顶部'刷一刷'几个字不好看，静音图标也不好看」——
      //    顶部那行字整块撤掉，emoji 静音键也换成矢量图标，统一收进这一列。
      //    定位仍用「全屏 Column + End/End」（Stack 里给子节点 .align 不生效，踩过）。
      //    右侧栏不在这里 —— 它已经挪进每一页的 InfoLayer 里了（跟着画面一起刷，见下方注释）。

      // 6) 空态 / 错误态 / 加载态
      // 加载态**延迟 260ms 才出现**（2.6.1.82）：服务端加了缓存后通常几十毫秒就回来，
      // 一进来就闪一下「正在取片段」很脏 —— 超过 260ms 才说明真的在等。
      if (this.loading && this.loadingVisible) {
        Column({ space: 10 }) {
          LoadingProgress().width(30).height(30).color(Theme.ACCENT)
          Text('正在取片段').fontSize(12).fontColor('#99FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('暂时没得刷').fontSize(15).fontColor('#FFFFFF')
          Text(this.err).fontSize(12).fontColor('#99FFFFFF').textAlign(TextAlign.Center)
          if (this.pending > 0) {
            Text(`后台正在准备 ${this.pending} 部片的素材`)
              .fontSize(11).fontColor(Theme.TEXT_FAINT)
          }
          Text('返回')
            .fontSize(13)
            .fontColor(Theme.GOLD)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor('#33FFFFFF')
            .onClick(() => {
              this.close();
            })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 30, right: 30 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 适感握持兜底（2026-11-16）：系统不给握持手时，靠「手指常落在哪一侧」推断。
    // 这里是整页最外层，任何一点触摸都会经过，取样最全。
    .onTouch((ev: TouchEvent) => {
      if (ev.type === TouchType.Down && ev.touches.length === 1) {
        let w: number = 0;
        try {
          w = display.getDefaultDisplaySync().width;
        } catch (e) {
          w = 0;
        }
        GripSense.get().noteTouch(ev.touches[0].screenX, w);
      }
    })
    // 负一屏手感（2.6.1.68）：**右滑跟手**，滑过 96vp 才真的关。
    // 以前直接 router.back()，播的是系统「退出页面」动画，看着像退出 App 而不是回到隔壁一屏。
  }
}
