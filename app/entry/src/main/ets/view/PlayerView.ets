import { router, window, PiPWindow } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { sensor } from '@kit.SensorServiceKit';
import { AudioTrack, Media, Player, PlayerConfig, SubtitleTrack , PlayerState} from '@mpv-ohos/mpv-arkts';
import { httpGet, httpGetCached, httpPost, httpPut } from '../common/Http';
import { savePickLocal } from '../common/FrameStore';
import { Gallery } from '../common/Gallery';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { AppLog } from '../common/AppLog';
import { DetailParams, PlayerParams } from '../common/Types';
import { clock } from '../common/Util';
import { inPartGroup, partGroupKeys, partNoOf, partsHint } from '../common/Parts';
import { common } from '@kit.AbilityKit';
import { SubtitleClient, SubtitleItem, LocalCandidate, SubtitleChoice,
  dedupSubtitles, subSourceLabel } from '../common/Subtitles';
import { PlayerPrefs, PlayerTuning } from '../common/PlayerPrefs';
import { RATE_LABELS, rateFilm } from '../ext/ratings/RatingStars';
import { PipHub } from '../common/PipHub';
import { SubStyle, SubStyleSpec, SUB_SIZE_OPTS, SUB_OUTLINE_OPTS, SUB_POS_OPTS, SUB_BG_OPTS, SubOpt } from '../common/SubStyle';
import { BackgroundPlay } from '../common/BackgroundPlay';
import { BackAudio } from '../common/BackAudio';
import { PlayHandoff, PlaySession } from '../common/PlaySession';
import { PlayerChrome } from '../view/PlayerChrome';


const SPEEDS: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];

/** 「看完」的唯一口径，必须与服务端 server.py 的 FINISH_RATIO 一致（都是 0.95）。 */
const FINISH_RATIO: number = 0.95;

/** 截帧接口的返回（服务端 highlights/snap）。 */
interface SnapResult {
  ok: boolean;
  t: number;
  ms: number;
  url: string;
  picked: boolean;
  still: boolean;
  reason: string;
}

/** 版本（一个条目下的多个文件/清晰度）。 */
interface VerItem {
  key: string;
  name: string;
  size: number;
  definition: string;
  duration: number;
  available: boolean;
}

/** 同系列的其它片（选集面板第二个 tab）。 */
interface SibItem {
  id: number;
  number: string;
  title: string;
  poster: string;
  actors: string[];
  current: boolean;
}

/** 一条播放器弹幕（某个时间点的一句话）。 */
interface AnnoItem {
  id: number;
  t_ms: number;
  body: string;
}

/** 正在飞的弹幕（B 站式：从右往左，按轨道排）。 */
interface DanmuLive {
  id: number;
  text: string;
  track: number;
  /** 左边缘当前 x（vp）——只为「挑轨道」时算占用，渲染交给动画。 */
  x: number;
  /** 估算宽度。 */
  w: number;
  /** 起飞时刻（ms）与全程时长（ms），到期回收。 */
  born: number;
  dur: number;
  /** 起点 / 终点 x（vp）。 */
  from: number;
  to: number;
  /** 所在轨道的 y（vp）。 */
  top: number;
  size: number;
}

/**
 * 单条弹幕：进来自带一段线性动画，由**系统渲染线程**驱动。
 *
 * 之前是父组件每 100ms 改一次 x、再把 x 塞进 ForEach 的 key 逼它重建 ——
 * 10fps 的位移 + 每条 10 次/秒的组件重建，看着就是一跳一跳、还掉帧（用户第 5 条）。
 * 现在只在「该发一条新弹幕」时创建一次组件，之后整段飞行交给 animateTo 的
 * Linear 补间（等价于 canvas 逐帧绘制，但跑在渲染线程上，60fps 不占 JS 线程）。
 */
@ComponentV2
struct DanmuItem {
  @Param item: DanmuLive = {
    id: 0, text: '', track: 0, x: 0, w: 0, born: 0, dur: 0, from: 0, to: 0, top: 0, size: 16
  };
  @Param alpha: number = 0.9;
  @Local dx: number = 0;

  aboutToAppear(): void {
    this.dx = 0;
    // 等首帧挂上去之后再启动补间，否则动画会从 translate 0 开始、整条弹幕闪一下
    setTimeout(() => {
      animateTo({
        duration: this.item.dur,
        curve: Curve.Linear,
        iterations: 1,
        playMode: PlayMode.Normal
      }, () => {
        this.dx = this.item.to - this.item.from;
      });
    }, 16);
  }

  build() {
    Text(this.item.text)
      .fontSize(this.item.size)
      .fontColor('#FFFFFF')
      .opacity(this.alpha)
      .textShadow({ radius: 2, color: '#B3000000', offsetX: 0, offsetY: 1 })
      .maxLines(1)
      .position({ x: this.item.from, y: this.item.top })
      .translate({ x: this.dx })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 原生播放页：mpv 内核（硬解 + 内嵌字幕/音轨），自绘控制层。
 * 手势：左右拖 = 找进度，竖直拖 = 左亮度 / 右音量，双击 = 播放暂停。
 *
 * 所有 player.* 都是原生调用，内核线程异常时会抛，全部包 try-catch 否则整页闪退。
 */
@ComponentV2
export struct PlayerView {
  /** 宿主传入：哪一条、哪个文件、从哪一秒开始。组件化后不再读 router 参数。 */
  @Param metaIdParam: number = 0;
  @Param numberParam: string = '';
  @Param titleParam: string = '';
  @Param keyParam: string = '';
  @Param nameParam: string = '';
  @Param posParam: number = 0;
  /** auto（跟设置）/ portrait（页内 16:9）/ portraitFull / landscape。 */
  @Param modeParam: string = 'auto';
  /** 是否整页宿主（播放页）：true 才允许一直收系统栏、锁横屏。 */
  @Param pageHost: boolean = false;
  /** 首帧出来之前盖在海报上，避免「黑一下再出画面」。 */
  @Param posterParam: string = '';
  /** 是否已经开播：false 时只挂 surface 不出声（详情页顶部那张「海报」状态）。 */
  @Param autoplay: boolean = true;
  /** 首次横屏转回竖屏时请求宿主高亮评分区（第 3 条：不弹窗）。 */
  @Event onAskRate: () => void = () => {};
  @Event onExited: () => void = () => {};
  /** 形态变了就通知宿主（宿主据此决定返回键行为：先退全屏还是直接退出）。 */
  @Event onModeChange: (mode: string) => void = (mode: string) => {};

  /**
   * 宿主请求「退出全屏」：每次自增一下。
   *
   * 返回键在组件外面（页面级），只能由宿主拦截；宿主拦截后把信号发回来，
   * 组件自己把横屏/全屏收回页内 16:9（用户第 4 条）。
   */
  @Param exitSignal: number = 0;

  @Monitor('exitSignal')
  private onExitSignal(): void {
    if (this.viewMode === 'portrait' && this.orientIntent === 'portrait') {
      return;
    }
    this.exitToPortrait();
  }

  @Monitor('viewMode')
  private onViewMode(): void {
    // 形态一变，轨道高度/字号全变，正在飞的弹幕会错位 —— 直接清空重来
    this.live = [];
    this.onModeChange(this.viewMode);
  }

  /**
   * 播放中保持屏幕常亮（用户 2.6.1.4：「播放状态下会自动息屏，没有保护」）。
   *
   * 系统按「休眠时间」息屏，片子放着看的时候屏幕一灭，画面和声音一起断。
   * 走窗口级 `setWindowKeepScreenOn`，不申请 `RUNNING_LOCK` 权限，也不用另管生命周期。
   * 只在**真正播放**时亮：暂停往往意味着人走开了，这时还亮着纯耗电（碰一下屏幕就回来）。
   */
  @Monitor('playing')
  private onPlayingChange(): void {
    this.applyKeepScreenOn();
  }

  /**
   * 诊断（2.6.1.68）：「点字幕，菜单闪一下就消失」到底是谁关的。
   *
   * 以前只有 350ms 抬手守卫这一道防线，日志里看不出是哪条路径把 showPanel 置回 false，
   * 所以每轮都只能猜。现在开关面板都留一条带「距打开多少毫秒」的记录：
   * 若是 <350ms 自己关的，说明守卫没拦住；若是几百毫秒之后，说明是别的代码在收面板。
   */
  @Monitor('showPanel')
  private onPanelVisibilityChange(): void {
    const since: number = this.panelOpenedAt > 0 ? Date.now() - this.panelOpenedAt : -1;
    AppLog.mark('subpanel', `showPanel=${this.showPanel} kind=${this.panelKind} sinceOpen=${since}ms`);
  }

  @Monitor('subStyleOpen')
  private onSubStyleVisibilityChange(): void {
    AppLog.mark('substyle', `面板 ${this.subStyleOpen ? '开' : '关'} size=${this.subSizePct} outline=${this.subOutlineW} pos=${this.subPosPct} bg=${this.subBgMode}`);
  }

  private player: Player | undefined = undefined;
  private metaId: number = 0;
  private metaNumber: string = '';
  private metaTitle: string = '';
  private fileKey: string = '';
  private fileName: string = '';
  private startPos: number = 0;
  private tickId: number = -1;
  private saveId: number = -1;
  private lastSavedPos: number = 0;
  /** 是否已经真正开流（详情页顶部先只显示海报）。 */
  private started: boolean = false;
  /** 看过一小段才值得提示打分（避免一进来转个屏就弹）。 */
  private watchedEnough(): boolean {
    return this.pos > 45 || (this.duration > 0 && this.pos > this.duration * 0.1);
  }
  /** 是否已经出过一帧画面（之前盖着海报，避免黑屏一闪）。 */
  @Local firstFrame: boolean = false;
  private completed: boolean = false;
  private subTracks: SubtitleTrack[] = [];
  private audioTracks: AudioTrack[] = [];
  private panKind: string = '';
  /** 竖滑按在哪半边：'left' 亮度 / 'right' 音量（提示里要显示对的图）。 */
  private panSide: string = '';
  private panBase: number = 0;
  private panStartPos: number = 0;
  /** 亮度手势防抖与还原标记：退出播放页时还原为系统自动亮度（-1）。 */
  private brightnessTouched: boolean = false;
  private lastBrightVal: number = -1;
  private lastBrightAt: number = 0;
  /** 画中画尺寸与播放态同步标记。 */
  private pipSized: boolean = false;
  private lastPipPlaying: boolean = false;
  private lockUiTimer: number = -1;
  private win: window.Window | undefined = undefined;
  /** 上一次已知的窗口横竖：只在跨过横竖分界时重绑 surface，旋转中途的连续尺寸变化不重复重建。 */
  private lastWinPortrait: boolean = false;
  /** 方向意图设定时刻：只在设定后的短窗口内补发方向请求，避免长期与系统拉锯。 */
  private intentAt: number = 0;
  /** 上一次补发方向请求的时刻（节流用）。 */
  private lastNudgeAt: number = 0;
  /** 当前是否已向系统要了「屏幕常亮」：避免同一状态重复调用。 */
  private keepOn: boolean = false;
  /**
   * 方向意图 —— **用户意图优先，不是重力优先**。
   *
   *  - `auto`      跟随重力（默认：手机横过来进全屏、竖回去回 16:9）
   *  - `portrait`  锁竖屏（用户按返回 / 点退出全屏之后）
   *  - `landscape` 锁横屏（用户点全屏按钮之后）
   *
   * 之前是「完全听重力」：按返回回竖屏后，手机还横着拿，重力立刻又把它转回去；
   * 点全屏转到横屏后，手一竖又弹回来 —— 用户会觉得按键根本没生效（2.4.6.18 反馈第 4 条）。
   * 现在改成只有用户主动操作才改变意图，`windowSizeChange` 在非 auto 时完全不碰方向。
   */
  private orientIntent: string = 'auto';
  /** 锁定期间的重力监听：**用户真的转动了手机**才交还重力（不是靠计时）。 */
  private gravityOn: boolean = false;
  /** 当前物理方向（竖=true），由重力传感器持续维护。 */
  private physicalPortrait: boolean = false;
  private physicalKnown: boolean = false;
  /** 锁定那一刻的物理方向：一旦与它不同，说明用户转了手机。 */
  private anchorPortrait: boolean = false;
  /** 锚点是否已经对齐过（第一帧重力数据到达时对齐一次）。 */
  private anchorValid: boolean = false;
  /** 传感器拿不到时的兜底（正常情况下用不到）。 */
  private lockTimer: number = -1;
  /** 「检测到用户转了手机」之后等一小会儿再交还重力，避免转到一半就被旋转打断。 */
  private releaseTimer: number = -1;

  @Local surfaceReady: boolean = false;
  @Local pos: number = 0;
  @Local duration: number = 0;
  @Local playing: boolean = false;
  @Local buffering: boolean = false;
  @Local bitrate: number = 0;
  @Local bufPct: number = 0;
  /** mpv 真正缓存了多少秒画面（demuxer-cache-duration）。卡顿时看这个最直接：
   *  在 0 附近跳＝网络跟不上；稳定在几秒以上还卡＝解码/渲染的问题。 */
  @Local cacheSec: number = 0;
  @Local bandwidthWarn: boolean = false;
  @Local speed: number = 1.0;
  @Local showControls: boolean = true;
  @Local volume: number = 100;
  @Local bright: number = 0.5;
  @Local seekPreview: number = -1;
  @Local seekCancel: boolean = false;
  @Local hudKind: string = '';
  @Local tempSpeedActive: boolean = false;
  @Local screenLocked: boolean = false;
  @Local lockUiShown: boolean = false;
  @Local aspectMode: string = 'fit';
  @Local subDelay: number = 0;
  @Local currentAudioIndex: number = 0;
  @Local annoColorIdx: number = 0;
  /** 是否显示「缓存中」全屏遮罩：只有真的卡住（>0.4s）才显示。 */
  @Local showBufferOverlay: boolean = false;
  /** 起播时刻：开头这几秒的 buffering 是正常起播，不算「卡住」（用户第 4 条）。 */
  private openAt: number = 0;
  /** surface attach 成功的时刻：`attach → 首帧` 这一段才是 mpv 真正等数据 + 解码的时间。 */
  private attachAt: number = 0;
  private bufferSince: number = -1;
  private lastSeekAt: number = 0;
  /** 长按临时倍速前的固定档位（R11）。 */
  private speedBeforeTemp: number = 1.0;
  /** 长按加速到多少倍（设置项，默认 3.0）。 */
  @Local tempSpeedValue: number = 3.0;
  /** 快进/快退一次跳多少秒（设置页可配，默认 10）。 */
  @Local seekStep: number = 10;
  /** 截帧请求正在飞：按钮连点会重复抽同一帧，挡一下。 */
  @Local snapBusy: boolean = false;
  /** 选集面板（R12）：版本切换 + 同系列其它片，带海报和演员。 */
  @Local showPicker: boolean = false;
  @Local pickerTab: string = 'version';
  @Local versions: VerItem[] = [];
  @Local siblings: SibItem[] = [];
  @Local sibName: string = '';
  @Local pickerLoading: boolean = false;
  /** 批注（R23）：到时间点就滚过一条，写批注时暂停不打断。 */
  @Local annotations: AnnoItem[] = [];
  @Local annoNow: string = '';
  @Local showAnnoInput: boolean = false;
  @Local annoDraft: string = '';
  @Local annoBusy: boolean = false;
  /** 正在飞的弹幕（B 站式，100ms 推进一次）。 */
  @Local live: DanmuLive[] = [];
  private danmuOn: boolean = true;
  private danmuSize: number = 16;
  private danmuSpeedVp: number = 90;
  private danmuTracks: number = 6;
  private danmuAlpha: number = 0.9;
  /** 已经发过的弹幕 id：同一条不重复飞。 */
  private shownIds: number[] = [];
  private danmuTimer: number = -1;
  private lastDanmuTick: number = 0;
  /**
   * 弹幕自己的时钟（秒）。
   *
   * 不用 `pos` 直接判点：mpv 一进缓冲 pos 就停，弹幕也跟着停，用户根本分不清
   * 是视频卡了还是弹幕卡了。这里只要「在播」就按真实时间往前走（用户第 7 条），
   * 缓冲结束后再平滑追回播放位置。
   */
  private danmuClock: number = 0;
  /** 上一帧的弹幕时钟：判断「这一帧越过了哪些弹幕」。 */
  private lastDanmuClock: number = 0;
  /** 进度条画面预览（R08）：一张雪碧图，拖动时按时间取其中一格。 */
  @Local prevOk: boolean = false;
  @Local prevUrl: string = '';
  @Local prevCols: number = 8;
  @Local prevRows: number = 8;
  @Local prevStep: number = 30;
  @Local prevCount: number = 64;
  /** 每格像素尺寸（服务端 tile_w / tile_w*9/16）。写死 128×72 会和 160×90 对不上，
   *  屏幕上就是「一格里有四个小画面」。 */
  private prevTries: number = 0;
  /**
   * 三态播放窗口（2026-11-11 二次改造）：
   *  - `portrait`     播放器**固定在顶部**（16:9）+ 下方一块**可拖动**的详情抽屉
   *  - `portraitFull` 竖屏全屏（进度条单独一行）
   *  - `landscape`    横屏全屏
   */
  @Local viewMode: string = 'portrait';
  /** 设备当前是否竖着：只有 portrait 模式才按 16:9 定高。 */
  @Local devicePortrait: boolean = false;
  @Local vpW: number = 360;
  @Local vpH: number = 780;
  /** surface 尺寸去抖定时器（尺寸每帧在变时别每帧重绑）。 */
  private sizeTimer: number = -1;
  /** 屏灭巡检（2.6.1.37）：后台期间每 600ms 看一眼屏幕，锁屏就停播。 */
  private bgWatch: number = -1;
  /** 小窗正在启动中（2.6.1.41）：窗口可见性回调会连发，没这个标记会重复 startPiP → 1300013。 */
  private pipStarting: boolean = false;
  private pipPreparing: boolean = false;
  private pipEpoch: number = 0;
  private pipRestoring: boolean = false;
  private pipAutoArmed: boolean = false;
  private pipState: PiPWindow.PiPState = PiPWindow.PiPState.STOPPED;
  private disposed: boolean = false;
  private windowVisible: boolean = true;
  private visibilityListener: ((visible: boolean) => void) | undefined = undefined;
  /** XComponent 的「代」：换一代 = 重建组件 = 一块新 surface（形态切换时用）。 */
  @Local surfaceGen: number = 0;
  /** 上次重建 surface 的时刻（节流用，避免自激重建）。 */
  private lastRebindAt: number = 0;
  /** 重力自动切换：关掉后播放页永远横屏全屏。 */
  private autorotate: boolean = true;
  @Local detailPlot: string = '';
  @Local detailActors: string[] = [];
  @Local detailTags: string[] = [];
  @Local detailSeries: string = '';
  /**
   * 自建 surface（R18）：`PlayerSurface` 不暴露 XComponentController，
   * 而画中画必须用 controller 绑定。所以这里自己开 XComponent，
   * onLoad 拿 surfaceId 交给 mpv，同一个 controller 再喂给 PiPWindow。
   */
  private xc: XComponentController = new XComponentController();
  private pipCtrl: PiPWindow.PiPController | undefined = undefined;
  /** 本页在 PipHub 里的身份（同一页复用同一个 id）。 */
  private pipOwner: string = `pp-${Date.now()}`;
  @Local pipActive: boolean = false;
  /** 回桌面出系统小窗（设置项）。默认关：2026-11-13 21:14 用户定，与设置页一致。 */
  private pipAuto: boolean = false;
  /** 切后台继续出声（设置项）。默认关；与小窗二选一（小窗优先）。 */
  private bgPlay: boolean = false;
  @Local errorText: string = '';
  /** 我的评分（0 = 没打），看完时就地弹一张打分卡。 */
  @Local myRating: number = 0;
  @Local showRateCard: boolean = false;
  private ratePrompted: boolean = false;
  private rateBusy: boolean = false;
  @Local showPanel: boolean = false;
  @Local panelKind: string = 'subs';
  /** 字幕样式面板（2.6.1.55）：四个维度的当前值，改一下就写偏好 + 重设 mpv。 */
  @Local subStyleOpen: boolean = false;
  /** 样式面板打开时刻（「样式」是面板里的第二层，单独算抬手守卫）。 */
  private subStyleOpenedAt: number = 0;
  @Local subSizePct: number = 100;
  @Local subOutlineW: number = 3;
  @Local subPosPct: number = 100;
  @Local subBgMode: number = 0;
  /**
   * 面板打开时刻（毫秒）。打开面板的那一次点击，**抬手**会落到刚插进来的第一行上，
   * 直接触发 pickSub/pickAudio → 面板刚开就关，观感就是「点字幕闪退」。
   * PlayerPage（竖屏/独立播放页）2.5.5.7 就加了这道 350ms 守卫，横屏这个 PlayerView 一直漏着
   * （2.6.1.5 补上，用户报的「横屏字幕又闪退」就是它）。
   */
  private panelOpenedAt: number = 0;
  /**
   * 2.6.1.68：「抬手落到刚插进来的面板上」的**精确**判据。
   *
   * 时间窗（350ms）只能挡住手快的情况；按住 0.6 秒再松手照样会误触。真正的特征是
   * **面板只收到了 Up、没收到 Down** —— 按下的那一刻面板还不存在。所以给面板容器
   * 挂一层 onTouch 记录 Down，点击处理里要求「这次点击的 Down 确实落在面板上」。
   * 两套判据同时保留：Down 判据管精确，时间窗管兜底。
   */
  private subPanelDown: boolean = false;
  private stylePanelDown: boolean = false;
  @Local subLabels: string[] = [];
  @Local audioLabels: string[] = [];
  @Local hint: string = '';
  @Local volumeHint: number = -1;
  @Local localSubs: LocalCandidate[] = [];
  @Local extSubs: SubtitleItem[] = [];
  @Local currentSubId: string = '';
  @Local currentSubIndex: number = -1;
  @Local subChosen: boolean = false;
  /** 已经尝试过「恢复上次选的字幕」。 */
  private subRestored: boolean = false;
  @Local currentLocalName: string = '';
  @Local subUrlInput: string = '';
  @Local subBusy: boolean = false;
  @Local subHint: string = '';

  aboutToAppear(): void {
    this.disposed = false;
    // 全局小窗要「此刻在放什么」：由本页自己解释状态，别人别猜（2.6.2.1）
    PlaySession.exporter = () => this.buildSession();
    this.metaId = this.metaIdParam;
    this.metaNumber = this.numberParam;
    this.metaTitle = this.titleParam;
    this.fileKey = this.keyParam;
    this.fileName = this.nameParam;
    this.startPos = this.posParam > 5 ? this.posParam : 0;
    const hostMode: string = this.modeParam;
    // 快进/快退步长：设置页存的是字符串，越界一律回 10 秒
    const step: number = Number(Store.I.prefString('player_seek_step', '10'));
    this.seekStep = step >= 5 && step <= 60 ? Math.trunc(step) : 10;
    // 重力自动切换（默认开）：关了播放页永远横屏
    this.autorotate = Store.I.prefString('player_autorotate', '1') !== '0';
    // 形态：宿主给了就用宿主的（详情页里 = portrait，页内 16:9），
    // 否则按设置里的「播放方式」决定。
    if (hostMode === 'portrait' || hostMode === 'portraitFull' || hostMode === 'landscape') {
      this.viewMode = hostMode;
    } else {
      this.viewMode = Store.I.prefString('player_jump_mode', 'portrait') === 'landscape'
        ? 'landscape' : 'portrait';
      if (Store.I.prefString('player_open_mode', 'bili') === 'emby') {
        this.viewMode = 'landscape';
      }
    }
    // 自动小窗 / 后台出声：**默认都关**（2026-11-13 21:14 用户定）。
    // 两者都要用户主动去「播放设置」里开；默认按 Home 就正常退到桌面（播放暂停）。
    this.pipAuto = Store.I.prefString('player_pip_auto', '0') !== '0';
    this.bgPlay = Store.I.prefString('player_bg_play', '0') !== '0';
    const ts: number = Number(Store.I.prefString('player_temp_speed', '3'));
    this.tempSpeedValue = ts >= 1.5 && ts <= 5 ? ts : 3;
    // 字幕样式：面板里的选中态从这里来（真值在偏好里，mpv 那边由 applySubStyle 写）
    this.subSizePct = SubStyle.size();
    this.subOutlineW = SubStyle.outline();
    this.subPosPct = SubStyle.pos();
    this.subBgMode = SubStyle.bg();
    try {
      // configDir 让 mpv 读沙箱里的 mpv.conf（缓存 / demuxer / gpu 等参数都在那儿调）；
      // hwdec 走构造参数，因为配置文件里的 hwdec 会被它覆盖。
      const ctx = getContext(this) as common.UIAbilityContext;
      // apply() 会读结构化设置，必要时按当前版本重生成 mpv.conf；
      // hwdec 只能走构造参数（配置文件里的 hwdec 会被它覆盖）。
      const tuning = PlayerPrefs.apply(ctx);
      PlayerPrefs.dir(ctx);
      this.player = new Player(new PlayerConfig({
        configDir: PlayerPrefs.dir(ctx),
        hwdec: tuning.hwdec,
        vo: 'gpu-next',
        osc: false,
        osd: false,
        // 内核就绪后回读一遍真正生效的缓存参数：mpv.conf 有没有被读到、
        // 有没有被别的版本写脏，一看日志就知道（用户报「设置没生效」时全靠这行）。
        onReady: () => {
          this.verifyTuning(tuning);
        }
      }));
      this.surfaceReady = true;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] player init: ${e.code} ${e.message}`);
      this.errorText = `播放内核没装好：${e.message}`;
      return;
    }
    // 进播放页 = 开始一次新的播放：别处开着的小窗先关掉（第 5 条）
    PipHub.stopOthers(this.pipOwner);
    this.enterFullscreen();
    if (this.autoplay) {
      this.started = true;
      this.openMedia();
    }
    this.loadDanmuConf();
    this.lastDanmuTick = Date.now();
    this.danmuTimer = setInterval(() => {
      this.tickDanmu();
    }, 100);
    this.loadPreview();
    this.loadMyRating();
    // 常驻维护「当前物理方向」：锁方向时靠它判断用户有没有转动手机
    this.startGravity();
    // 初次形态同步给宿主（@Monitor 只在「变化」时触发，初始值不会触发）
    this.onModeChange(this.viewMode);
    this.tickId = setInterval(() => {
      this.syncState();
    }, 300);
    this.saveId = setInterval(() => {
      this.saveProgress(false);
    }, 10000);
  }

  /** 导出「此刻在放什么」，交给浮窗/播放页接着放（2.6.2.1）。 */
  private buildSession(): PlayHandoff {
    let pos: number = this.pos;
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        const st: PlayerState | undefined = p.state;
        if (st !== undefined && st !== null && st.position > 0) {
          pos = st.position;
        }
      } catch (err) {
        console.info(`[amane] session pos: ${JSON.stringify(err)}`);
      }
    }
    const h: PlayHandoff = {
      mid: this.metaId,
      number: this.metaNumber,
      title: this.metaTitle,
      fileKey: this.fileKey,
      fileName: this.fileName,
      pos: pos,
      speed: this.speed,
      subId: this.currentSubId,
      localSub: this.currentLocalName,
      audioIndex: this.currentSubIndex >= 0 ? this.currentSubIndex : -1,
      compact: true
    };
    return h;
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.win !== undefined && this.visibilityListener !== undefined) {
      this.win.off('windowVisibilityChange', this.visibilityListener);
      this.visibilityListener = undefined;
    }
    this.stopGravity();
    if (this.lockTimer >= 0) {
      clearTimeout(this.lockTimer);
      this.lockTimer = -1;
    }
    if (this.releaseTimer >= 0) {
      clearTimeout(this.releaseTimer);
      this.releaseTimer = -1;
    }
    if (this.lockUiTimer >= 0) {
      clearTimeout(this.lockUiTimer);
      this.lockUiTimer = -1;
    }
    // 手势调过亮度：退出播放器时还原为系统自动亮度（-1），避免退出后手机屏幕一直卡在旧亮度
    if (this.brightnessTouched && this.win !== undefined) {
      this.win.setWindowBrightness(-1).catch((err: BusinessError) => {
        console.info(`[amane] reset brightness: ${err.code} ${err.message}`);
      });
      this.brightnessTouched = false;
    }
    // 页面走了 mpv 也销毁了，小窗留着只会黑屏
    this.stopPip();
    this.clearScreenWatch();
    // 播放器没了就别再占着后台长时任务（否则通知栏一直挂着「正在播放」）
    BackgroundPlay.stop(getContext(this) as common.UIAbilityContext);
    if (this.sizeTimer >= 0) {
      clearTimeout(this.sizeTimer);
      this.sizeTimer = -1;
    }
    if (this.danmuTimer >= 0) {
      clearInterval(this.danmuTimer);
      this.danmuTimer = -1;
    }
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
    if (this.saveId >= 0) {
      clearInterval(this.saveId);
      this.saveId = -1;
    }
    this.saveProgress(true);
    this.surfaceReady = false;
    try {
      if (this.player !== undefined) {
        this.player.destroy();
        this.player = undefined;
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] player destroy: ${e.code} ${e.message}`);
    }
    this.exitFullscreen();
  }

  private enterFullscreen(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      if (this.disposed) {
        return;
      }
      this.win = win;
      const props: window.WindowProperties = win.getWindowProperties();
      this.vpW = px2vp(props.windowRect.width);
      this.vpH = px2vp(props.windowRect.height);
      this.lastWinPortrait = this.vpH >= this.vpW;
      if (props.brightness >= 0 && props.brightness <= 1) {
        this.bright = props.brightness;
      }
      // 窗口到手时可能已经在播（playing 先变、win 后到），补一次常亮申请
      this.applyKeepScreenOn();
      // 只有在「整页播放器」或「已经是全屏形态」时才没收系统栏、才允许转屏。
      // 嵌在详情页顶部时（portrait）动窗口系统栏会把整个详情页搞成全屏，页面就残了。
      if (this.pageHost && !this.autorotate) {
        this.viewMode = 'landscape';
      }
      // ★ 手机本来就是横的（先横屏、再点播放）★
      // 宿主传过来的 modeParam 是死值 'portrait'，照它渲染就是「16:9 小窗 + 顶端留一条
      // 状态栏」，看着像没进全屏（2.4.6.18 反馈第 3 条）。这里按**当前窗口方向**纠正一次。
      if (this.autorotate && this.vpW > this.vpH && this.viewMode === 'portrait') {
        this.viewMode = 'landscape';
      }
      this.applyWindowMode();
      // 挂载过程中转屏的那次事件可能丢了（监听还没注册），拿到窗口后再对一次
      this.syncModeWithWindow();
      setTimeout(() => {
        this.syncModeWithWindow();
      }, 600);
      win.on('windowSizeChange', (size: window.Size) => {
        if (this.disposed) {
          return;
        }
        const oldMode: string = this.viewMode;
        this.vpW = px2vp(size.width);
        this.vpH = px2vp(size.height);
        const isP: boolean = size.height > size.width;
        const crossed: boolean = isP !== this.lastWinPortrait;
        this.devicePortrait = isP;
        this.lastWinPortrait = isP;
        if (this.pageHost && this.orientIntent === 'auto') {
          // 整页播放器形态由自己定（横屏），窗口尺寸变化只用于重排，不参与判定，
          // 否则会和 applyWindowMode 里的方向设置互相触发。
          return;
        }
        // 用户锁过方向就完全不听重力（按了全屏就横着、按了返回就竖着）
        if (this.orientIntent !== 'auto') {
          // ★ 但「不听重力」不等于「不管窗口真的转了」★
          // 锁着横屏时窗口从竖转到横，surface 还按竖屏的 viewport 渲染 ——
          // 表现就是「竖屏点全屏后画面乱飘」（2.6.1 反馈第 1 条）。
          // 形态归意图管，尺寸变了该重建就重建；只在跨横竖分界时做一次。
          if (crossed) {
            AppLog.mark('shape', `locked ${this.orientIntent}: window ${isP ? 'P' : 'L'} → rebind`);
            this.rebindSurface(true);
          }
          // 意图是横的、窗口还竖着（或反之）→ 补一次方向请求（自带节流与时间窗）
          this.nudgeOrientation(isP);
          return;
        }
        if (!this.autorotate) {
          return;
        }
        if (isP) {
          // 转回竖屏：从横屏回来就回默认「顶部」形态
          if (this.viewMode === 'landscape') {
            this.viewMode = 'portrait';
          }
        } else if (this.viewMode !== 'landscape') {
          this.viewMode = 'landscape';
        }
        // 横竖屏切换后重绑 surface 并重绘一帧，否则画面会按旧 viewport 拉伸/乱飞
        if (oldMode !== this.viewMode) {
          AppLog.mark('shape', `viewMode ${oldMode} -> ${this.viewMode} (win ${Math.round(size.width)}x${Math.round(size.height)})`);
          this.applyWindowMode();
          this.rebindSurface(true);
          // 第一次「从横屏转回竖屏」时提示打分（第 3 条）。
          // 转回来正好能看到详情页中间的评分区，所以不弹窗，交给宿主高亮那一块。
          if (oldMode === 'landscape' && this.viewMode === 'portrait'
            && !this.ratePrompted && this.myRating === 0 && this.watchedEnough()) {
            this.ratePrompted = true;
            this.onAskRate();
          }
        }
      });
      // 自动 PiP 由系统在退后台时拉起，不能在窗口已经不可见后再手动 start。
      this.visibilityListener = (visible: boolean) => {
        if (this.disposed) {
          return;
        }
        this.windowVisible = visible;
        if (!visible) {
          // 锁屏 / 息屏 = 退出（2.6.1.37 用户定）：不申请长时任务，直接把播放停住。
          // 先切桌面、再按电源键的情况由下面那个 600ms 的巡检接住。
          if (BackAudio.screenOff()) {
            this.pauseForScreenOff();
            BackgroundPlay.stop(getContext(this) as common.UIAbilityContext);
            return;
          }
          // 长时任务 + AVSession：**自动小窗待命时不要申请** —— 小窗自己持有音频，
          // 再挂一路后台长时任务，两边会互相抢焦点（2026-11-13 21:14 用户指出的冲突）。
          // 小窗关着（开关没开 / 页面没准备好）才走纯后台出声这条。
          if (!PipHub.autoArmed && this.bgPlay && this.playing) {
            BackgroundPlay.start(getContext(this) as common.UIAbilityContext);
          }
          if (this.playing) {
            this.watchScreenOff();
          }
        } else {
          this.clearScreenWatch();
          BackgroundPlay.stop(getContext(this) as common.UIAbilityContext);
          this.preparePip();
        }
      };
      win.on('windowVisibilityChange', this.visibilityListener);
    }).catch((error: BusinessError) => {
      console.error(`[amane] fullscreen: ${error.code} ${error.message}`);
    });
  }

  /** 按当前形态 + 用户意图决定「要不要收系统栏 / 要不要锁方向」。 */
  private applyWindowMode(): void {
    const w: window.Window | undefined = this.win;
    if (w === undefined) {
      return;
    }
    // 锁了方向（用户点了全屏/退出全屏）就必须是沉浸式，否则顶端会留一条状态栏
    const immersive: boolean = this.pageHost || this.viewMode !== 'portrait'
      || this.orientIntent !== 'auto';
    try {
      w.setWindowLayoutFullScreen(immersive);
      w.setWindowSystemBarEnable(immersive ? [] : ['status', 'navigation']);
      if (this.orientIntent === 'portrait') {
        w.setPreferredOrientation(window.Orientation.PORTRAIT);
      } else if (this.orientIntent === 'landscape') {
        w.setPreferredOrientation(window.Orientation.LANDSCAPE);
      } else if (this.viewMode === 'landscape') {
        // 详情页里的播放器跟着重力走（auto）：不锁死，否则「竖不回来」。
        // 2026-11-17 修「横屏播着播着突然变竖屏」：锁定 20 秒到期后 intent 变回 auto，
        // 这里若直接交还 AUTO_ROTATION，系统就按当时握持角度重判一次 —— 躺着/斜着拿
        // 就会翻回竖屏。所以只有在**传感器确认手机已经是竖的**时才交还重力。
        const phonePortrait: boolean = this.physicalKnown && this.physicalPortrait;
        w.setPreferredOrientation(this.pageHost || !phonePortrait
          ? window.Orientation.LANDSCAPE
          : window.Orientation.AUTO_ROTATION);
      } else if (this.pageHost) {
        // 整页播放器不在这里碰方向：进页/退页由 PlayerPage.enterFullscreen /
        // exitFullscreen 负责。这里一旦插手，就会跟 windowSizeChange 拉锯（横竖来回切、
        // 每秒重建 surface），或者在手势返回后把详情页窗口又掰回横屏。
      } else {
        w.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
      }
    } catch (err) {
      console.error(`[amane] window mode: ${JSON.stringify(err)}`);
    }
  }

  /** 按当前播放状态向窗口要 / 放「屏幕常亮」。窗口还没拿到时静默跳过，拿到后会补一次。 */
  private applyKeepScreenOn(): void {
    const w: window.Window | undefined = this.win;
    if (w === undefined) {
      return;
    }
    const want: boolean = this.playing;
    if (want === this.keepOn) {
      return;
    }
    this.keepOn = want;
    w.setWindowKeepScreenOn(want).catch((err: BusinessError) => {
      console.info(`[amane] keep screen on: ${err.code} ${err.message}`);
    });
  }

  /**
   * 意图锁着方向、但窗口没转到目标方向时，补一次方向请求。
   *
   * 为什么需要：手势返回 / 点退出全屏那一刻，系统正在播退场动画，
   * `setPreferredOrientation(PORTRAIT)` 会被吞掉；而 `orientIntent` 一锁，
   * `windowSizeChange` 之后一律 return，再没有人去要第二次 —— 于是停在
   * 「横屏窗口 + 竖屏版式」（2.6.1 反馈第 2 条）。
   *
   * 两道刹车，避免和系统拉锯（2.5.5.10 的「画面乱飞」就是这么来的）：
   * 只在**意图设定后 2 秒内**补，且两次之间至少隔 400ms。
   */
  private nudgeOrientation(winPortrait: boolean): void {
    if (this.orientIntent === 'auto') {
      return;
    }
    const wantPortrait: boolean = this.orientIntent === 'portrait';
    if (winPortrait === wantPortrait) {
      return;
    }
    const now: number = Date.now();
    // 只在意图设定后 1.2 秒内补，两次之间至少隔 700ms ——
    // 原来 2 秒 / 400ms 会在转场期间连发四五个方向请求，和系统转屏打架（跳来跳去）。
    if (now - this.intentAt > 1200 || now - this.lastNudgeAt < 700) {
      return;
    }
    this.lastNudgeAt = now;
    AppLog.mark('shape', `nudge ${this.orientIntent} (window ${winPortrait ? 'P' : 'L'})`);
    this.forceOrientation(wantPortrait
      ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
  }

  /** 窗口此刻是不是竖的：读真实窗口矩形，不看缓存值。 */
  private winPortraitNow(): boolean {
    if (this.win !== undefined) {
      try {
        const r: window.Rect = this.win.getWindowProperties().windowRect;
        return r.height >= r.width;
      } catch (err) {
        // 读不到就退回缓存值
      }
    }
    return this.vpH >= this.vpW;
  }

  /**
   * 转完 500ms 后如果窗口还没到目标方向，补一次（**只补一次，不循环**）。
   *
   * `nudgeOrientation` 挂在 `windowSizeChange` 上，靠尺寸变化驱动；可窗口原地不动
   * （手势返回被吞、系统根本没转）时那个事件永远不会来，所以这里再放一个定时兜底。
   */
  private retryOrientation(wantPortrait: boolean): void {
    setTimeout(() => {
      if (this.orientIntent === 'auto' || this.winPortraitNow() === wantPortrait) {
        return;
      }
      AppLog.mark('shape', `retry orient → ${wantPortrait ? 'P' : 'L'}`);
      this.forceOrientation(wantPortrait
        ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
    }, 500);
  }

  /**
   * 退出全屏回竖屏 16:9。
   *
   * 方向锁定**不是按时间解锁**，而是等「用户把手机转过去」（见 lockIntent）：
   * 手机还横着拿就一直竖着，你把手机竖起来的那一刻才交还重力；
   * 之后横过去就是全屏，完全跟着手走（2.4.6.22 反馈）。
   */
  private exitToPortrait(): void {
    this.viewMode = 'portrait';
    this.lockIntent('portrait');
    this.forceOrientation(window.Orientation.PORTRAIT);
    this.applyWindowMode();
    this.rebindSurface(true);
    this.retryOrientation(true);
    this.toast('已退出全屏；转正手机后跟随重力');
  }

  /**
   * 把方向锁到 `kind`，直到**物理方向变化**才交还重力。
   *
   * 为什么必须锁：点全屏时手机可能还竖着，立刻 `AUTO_ROTATION` 会被系统按竖屏转回去，
   * 看起来就是「点了没反应」。所以要先把窗口按住，等用户真把手机转过去。
   * 传感器拿不到时 20 秒兜底，绝不永久锁。
   */
  private lockIntent(kind: string): void {
    this.orientIntent = kind;
    this.intentAt = Date.now();
    // 锚点 = 现在的物理方向；还不知道就等第一帧重力数据来对齐
    this.anchorPortrait = this.physicalPortrait;
    this.anchorValid = this.physicalKnown;
    if (this.lockTimer >= 0) {
      clearTimeout(this.lockTimer);
    }
    this.lockTimer = setTimeout(() => {
      this.lockTimer = -1;
      this.releaseIntent();
    }, 20000);
    this.startGravity();
  }

  /** 交还重力：之后横竖完全由手机方向决定。 */
  private releaseIntent(): void {
    if (this.lockTimer >= 0) {
      clearTimeout(this.lockTimer);
      this.lockTimer = -1;
    }
    if (this.releaseTimer >= 0) {
      clearTimeout(this.releaseTimer);
      this.releaseTimer = -1;
    }
    if (this.orientIntent === 'auto') {
      return;
    }
    this.orientIntent = 'auto';
    this.applyWindowMode();
  }

  /**
   * 「用户转了手机」→ **等一下再交还重力**（400ms）。
   *
   * 立刻交会出问题：手还在转、传感器先一步报告新方向，系统就在半路开始旋转，
   * 画面会突一下再回弹。等 400ms 让手机落到目标姿态，这时交还，旋转幅度约等于 0，
   * 看起来就是「顺手接过去」。
   * 等待期间如果方向又转回原来的样子（只是晃了一下），这次就不交了。
   */
  private scheduleRelease(): void {
    if (this.releaseTimer >= 0) {
      return;
    }
    this.releaseTimer = setTimeout(() => {
      this.releaseTimer = -1;
      if (this.orientIntent === 'auto') {
        return;
      }
      if (this.physicalKnown && this.physicalPortrait !== this.anchorPortrait) {
        this.releaseIntent();
      }
    }, 400);
  }

  /** 常驻监听（播放期间），只在「锁着」的时候用来判断方向是否被用户改变。 */
  private startGravity(): void {
    if (this.gravityOn) {
      return;
    }
    try {
      sensor.on(sensor.SensorId.GRAVITY, this.onGravity);
      this.gravityOn = true;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] gravity off: ${e.code} ${e.message}`);
    }
  }

  private stopGravity(): void {
    if (!this.gravityOn) {
      return;
    }
    this.gravityOn = false;
    try {
      sensor.off(sensor.SensorId.GRAVITY, this.onGravity);
    } catch (err) {
      console.info('[amane] gravity off failed');
    }
  }

  /**
   * 重力回调：维护「当前物理方向」；锁着的时候一旦方向变了就交还重力。
   *
   * 阈值 3.0：手机平放在桌上时 x/y 都很小（重力全在 z 上），此时方向不可判，
   * 直接忽略 —— 上一版就是在这里把「平放」误判成竖屏，一锁定就立刻解锁。
   *
   * 注意：**界面自身的旋转不会改变重力数据**，所以这里不需要「冷却时间」。
   * 第一帧只用来对齐锚点，之后的任何变化都算用户真的转了手机。
   */
  private onGravity = (data: sensor.GravityResponse): void => {
    const ax: number = Math.abs(data.x);
    const ay: number = Math.abs(data.y);
    if (Math.max(ax, ay) < 3.0) {
      return;
    }
    const nowPortrait: boolean = ay > ax;
    this.physicalPortrait = nowPortrait;
    this.physicalKnown = true;
    if (this.orientIntent === 'auto') {
      return;
    }
    // 刚点过「全屏 / 缩小」的 1.2 秒里：系统正在播转场、窗口在转，
    // 这段时间的传感器抖动不能当成「用户把手机转过去了」，否则会立刻交还重力，
    // 和刚发出去的方向请求互相拉扯 —— 表现就是界面跳来跳去（2.6.1.32 修老 bug）。
    // 这段窗口里只把锚点对齐到当前物理方向，不做任何释放判断。
    if (Date.now() - this.intentAt < 1200) {
      this.anchorPortrait = nowPortrait;
      this.anchorValid = true;
      if (this.releaseTimer >= 0) {
        clearTimeout(this.releaseTimer);
        this.releaseTimer = -1;
      }
      return;
    }
    if (!this.anchorValid) {
      this.anchorPortrait = nowPortrait;
      this.anchorValid = true;
      return;
    }
    if (nowPortrait !== this.anchorPortrait) {
      // 转了手机：不立刻交还，等手停下来（scheduleRelease 里 400ms）
      this.scheduleRelease();
    } else if (this.releaseTimer >= 0) {
      // 又转回去了（只是晃了一下）：取消这次交还
      clearTimeout(this.releaseTimer);
      this.releaseTimer = -1;
    }
  };

  /**
   * 让 viewMode 跟窗口实际方向对齐。
   *
   * 用户第 5 条：竖屏加载时转横屏，偶尔会「竖屏 UI 被横过来」——
   * 那次 `windowSizeChange` 发生在 `getLastWindow().then` 注册监听**之前**，事件丢了。
   * 所以在拿到窗口后、以及随后 600ms 各对一次。
   */
  private syncModeWithWindow(): void {
    if (this.orientIntent !== 'auto') {
      return;
    }
    if (this.vpW <= 0 || this.vpH <= 0) {
      return;
    }
    const isP: boolean = this.vpH >= this.vpW;
    this.devicePortrait = isP;
    const want: string = isP ? 'portrait' : 'landscape';
    if (!this.pageHost && this.viewMode !== want) {
      this.viewMode = want;
      this.applyWindowMode();
      this.rebindSurface(true);
    }
  }

  private exitFullscreen(): void {
    if (this.win === undefined) {
      return;
    }
    // 播放器销毁 = 离开播放器上下文，宿主页（详情/播放页）都是没按横屏调过版式的普通页，
    // 退出后锁回竖屏（2026-11-18 用户：「先禁止除了播放器以外的所有横屏」）。
    // 旧版这里交还 AUTO_ROTATION，前提是「整个 App 全局跟重力转」，那个前提已经取消
    // （EntryAbility 现在默认 PORTRAIT）。整页播放器 PlayerPage.exitFullscreen 也是锁
    // PORTRAIT，这里对齐它。注意：这只管播放器**销毁后**；播放中的横竖屏仍由
    // applyWindowMode（orientIntent / viewMode）决定，那套逻辑没动，播放器例外保留。
    this.win.setPreferredOrientation(window.Orientation.PORTRAIT);
    this.win.setWindowLayoutFullScreen(false);
    this.win.setWindowSystemBarEnable(['status', 'navigation']);
    // 退出播放：把常亮还回去，否则这一页关了屏幕还一直亮着
    this.keepOn = false;
    this.win.setWindowKeepScreenOn(false).catch((err: BusinessError) => {
      console.info(`[amane] keep screen off: ${err.code} ${err.message}`);
    });
  }

  /** 宿主（详情页）点了播放：从这里开始真正开流。 */
  startPlay(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.openAt = Date.now();
    this.openMedia();
  }

  private async openMedia(): Promise<void> {
    if (this.player === undefined) {
      return;
    }
    // ★ 分段计时（2.6.1.81）★
    // 之前只有一个「first frame in 1.52s」的总数，看到数字也不知道慢在哪一步 ——
    // 上一轮「起播优先」就是因此误判成「已经是 mpv 缓存策略的问题」。
    // 现在把开流前那段也拆开：lan 探测 / 取 fileKey / player.open 各多少毫秒，
    // 剩下的一大截才是 mpv 真正等数据 + 解码的时间。
    const t0: number = Date.now();
    this.openAt = t0;
    // 被判成外网但此刻局域网可达时，先把地址切回内网再开流
    await Store.I.preferLanForPlay();
    const t1: number = Date.now();
    // 先定下「到底播哪个文件」：弹幕、进度、截帧都要跟着它走
    await this.ensureFileKey();
    const t2: number = Date.now();
    try {
      // token 已经在 URL 的 query 里，不要再走 httpHeaders：
      // mpv-arkts 会把头名编码坏（%65%authorization），反而触发 401。
      // 有离线缓存就播本地（file://），没有才走代理 —— 见 Store.playSource
      const src: string = Store.I.playSource(this.metaId, this.fileKey);
      const media: Media = new Media(src, {
        start: this.startPos
      });
      this.player.stream.error.listen((message: string) => {
        this.errorText = message.length > 0 ? message : '播放失败';
      });
      this.player.open(media);
      const t3: number = Date.now();
      AppLog.mark('startup',
        `prepare lan=${t1 - t0}ms fileKey=${t2 - t1}ms open=${t3 - t2}ms src=${src.startsWith('file://') ? 'local' : 'net'} key=${this.fileKey.length > 0 ? 'yes' : 'no'}`);
      this.pos = this.startPos;
      this.danmuClock = this.startPos;
      this.lastDanmuClock = this.startPos - 0.01;
      // 恢复上次选的字幕（2.6.1.7）；mpv 偶尔忽略过早的 sub-add，1.5 秒后补一次
      this.restoreSubChoice();
      setTimeout(() => {
        if (!this.subChosen) {
          this.subRestored = false;
          this.restoreSubChoice();
        }
      }, 1500);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] open: ${e.code} ${e.message}`);
      this.errorText = `打不开这个文件：${e.message}`;
    }
    // 弹幕按「这个文件」拉：换版本 / 换集不串（第 9 条）
    this.loadAnnotations();
  }

  /**
   * 解析出真正在播的文件 key。
   *
   * 从详情页进来时 fileKey 常常是空的（让服务端自己挑一条）。空 key 有二害：
   * 弹幕会跟该片所有文件混在一起、缓存与进度也没法按文件区分。这里先问一次
   * streams，取第一条可用的当默认版本，后续 openMedia 就带着它走。
   */
  private async ensureFileKey(): Promise<void> {
    if (this.fileKey.length > 0 || this.metaId <= 0) {
      return;
    }
    try {
      const url: string =
        `${Store.I.user}/api/user/streams/${Store.I.playbackSource}/${this.metaId}`;
      // ★ 2.6.1.84：这里必须走缓存 ★
      // 真机分段计时（00:02）暴露过一条 1197ms 的 fileKey 查询 —— 那 1.2 秒完全在
      // 用户点下播放之后、mpv 开流之前白等。文件列表在几分钟内不会变，缓存 10 分钟；
      // 同一部片再打开直接命中（实测 1197ms → 0ms，首帧 2.19s → 1.20s）。
      const text: string = await httpGetCached(url, Store.I.token, 600000);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items;
      if (!Array.isArray(raw) || raw.length === 0) {
        return;
      }
      const it = raw[0] as VerItem;
      const key: string = String(it.key);
      if (key.length > 0) {
        this.fileKey = key;
        if (this.fileName.length === 0) {
          this.fileName = String(it.name);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] resolve file key: ${e.code} ${e.message}`);
    }
  }

  private syncState(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      const st: PlayerState | undefined = this.player.state;
      if (st === undefined || st === null) {
        return;
      }
      // 2.6.1.43：seek 后 1.5 秒内**不用轮询值覆盖本地位置**。
      // mpv 的 `state.position` 在 seek 后要几帧到一秒才跟上（网络流更久），
      // 期间这一段 300ms 轮询会把刚设好的 pos 覆盖回旧值 ——
      // 表现就是用户报的「点进度条能跳转，但滑块又弹回开头」。
      const nowMs: number = Date.now();
      if (nowMs - this.lastSeekAt > 1500) {
        this.pos = st.position;
      } else if (Math.abs(st.position - this.pos) < 1.5) {
        // mpv 已经跟到目标附近，提前解除保护
        this.lastSeekAt = 0;
        this.pos = st.position;
      }
      this.duration = st.duration;
      this.playing = st.playing;
      this.buffering = st.buffering;
      this.refreshBufferOverlay();
      this.bitrate = st.videoBitrate > 0 ? st.videoBitrate : 0;
      this.bandwidthWarn = Store.I.onWan && this.bitrate > 10000000;
      this.bufPct = st.bufferingPercentage >= 0 ? st.bufferingPercentage : 0;
      // 缓存秒数只有 mpv 属性里给得准（PlayerState.buffer 语义含糊）
      try {
        const sec: number = this.player.native.getProperty('demuxer-cache-duration');
        this.cacheSec = sec > 0 && sec < 600 ? sec : 0;
      } catch (e) {
        this.cacheSec = 0;
      }
      this.speed = st.speed;
      // 出过一帧就撤掉海报层
      if (!this.firstFrame) {
        const vp0 = st.videoParams;
        if (vp0 !== undefined && vp0.dw > 0) {
          this.firstFrame = true;
          // 首帧耗时：排查「起播慢」时看这一行就够（2.6.1.57）
          if (this.openAt > 0) {
            const total: number = (Date.now() - this.openAt) / 1000;
            // attach→首帧 = mpv 等首字节 + 解封装 + 解码；这段才是「起播慢」的真正战场
            const afterAttach: number = this.attachAt > 0
              ? (Date.now() - this.attachAt) / 1000 : -1;
            AppLog.mark('startup',
              `first frame in ${total.toFixed(2)}s（attach→frame ${afterAttach >= 0 ? afterAttach.toFixed(2) : '?'}s）`);
            this.openAt = 0;
          }
          this.preparePip();
          if (this.pipCtrl !== undefined && !this.pipSized && vp0.dh > 0) {
            this.pipSized = true;
            try {
              this.pipCtrl.updateContentSize(Math.round(vp0.dw), Math.round(vp0.dh));
            } catch (e) {
              console.info(`[amane] pip contentSize: ${JSON.stringify(e)}`);
            }
          }
        }
      } else if (this.pipCtrl !== undefined && !this.pipSized) {
        const vp1 = st.videoParams;
        if (vp1 !== undefined && vp1.dw > 0 && vp1.dh > 0) {
          this.pipSized = true;
          try {
            this.pipCtrl.updateContentSize(Math.round(vp1.dw), Math.round(vp1.dh));
          } catch (e) {
            console.info(`[amane] pip contentSize: ${JSON.stringify(e)}`);
          }
        }
      }
      if (this.pipCtrl !== undefined && this.playing !== this.lastPipPlaying) {
        this.lastPipPlaying = this.playing;
        try {
          this.pipCtrl.updatePiPControlStatus(
            PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
            this.playing ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE
          );
        } catch (e) {
          console.info(`[amane] pip status: ${JSON.stringify(e)}`);
        }
      }
      if (st.eof && !this.completed) {
        this.completed = true;
        this.saveProgress(true);
      }
      this.updatePipAutoStart();
      // 打分提示不再在这里弹（第 3 条）：改成「第一次从横屏转回竖屏」时
      // 让详情页高亮它自己的评分区，不打断播放。
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] sync: ${e.code} ${e.message}`);
    }
  }

  /**
   * 「缓存中」遮罩去抖。
   *
   * mpv 只要暂停等数据就置 paused-for-cache，哪怕只有几十毫秒；
   * 拖动进度条又必然触发一次（要重新定位、重新预读），于是每拖一次
   * 就闪一次全屏加载——用户看到的就是「百分百触发缓存中」。
   *
   * 规则：
   * - 刚 seek 完的 1.5 秒内，短暂 buffering 属于正常，不弹遮罩；
   * - 任何 buffering 必须持续 0.45 秒以上才认为是真的卡住。
   * （syncState 每 300ms 采样一次，更短的抖动根本采不到。）
   */
  private refreshBufferOverlay(): void {
    const now: number = Date.now();
    if (!this.buffering) {
      if (this.bufferSince >= 0) {
        AppLog.mark('buffer', `end after ${((now - this.bufferSince) / 1000).toFixed(2)}s at ${this.pos.toFixed(1)}s`);
      }
      this.bufferSince = -1;
      this.showBufferOverlay = false;
      return;
    }
    // 起播 3 秒内的 buffering 一律不算卡：mpv 起播本来就要先攒够 cache-pause-wait，
    // 之前每次进片都闪一下「缓存中」，看着就像「每次都重新缓存」
    if (this.openAt > 0 && now - this.openAt < 3000) {
      if (this.bufferSince < 0) {
        AppLog.mark('buffer', `warmup at ${this.pos.toFixed(1)}s cache=${this.cacheSec.toFixed(1)}s`);
      }
      this.bufferSince = -1;
      this.showBufferOverlay = false;
      return;
    }
    if (this.bufferSince < 0) {
      this.bufferSince = now;
      AppLog.mark('buffer', `start at ${this.pos.toFixed(1)}s cache=${this.cacheSec.toFixed(1)}s`);
    }
    const elapsed: number = now - this.bufferSince;
    const afterSeek: boolean = now - this.lastSeekAt < 1500;
    const want: boolean = elapsed >= (afterSeek ? 1200 : 450);
    if (want && !this.showBufferOverlay) {
      AppLog.mark('buffer', `STALL ${(elapsed / 1000).toFixed(1)}s at ${this.pos.toFixed(1)}s cache=${this.cacheSec.toFixed(1)}s`);
    }
    this.showBufferOverlay = want;
  }

  private saveProgress(force: boolean): void {
    if (this.duration <= 0 || this.metaId <= 0) {
      return;
    }
    if (!force && Math.abs(this.pos - this.lastSavedPos) < 5) {
      return;
    }
    this.lastSavedPos = this.pos;
    const body: string = JSON.stringify({
      metadata_id: this.metaId,
      position: this.pos,
      duration: this.duration,
      finished: this.completed || this.pos >= this.duration * FINISH_RATIO
    });
    httpPost(`${Store.I.user}/api/user/history`, Store.I.token, body).catch((error: BusinessError) => {
      console.error(`[amane] save progress: ${error.code} ${error.message}`);
    });
  }

  private togglePlay(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      this.player.playOrPause();
      this.playing = !this.playing;
      this.updatePipAutoStart();
      // 音频会话只在「需要它」时建：后台出声或自动小窗（2026-11-13 21:14 两个开关默认关）。
      // 两个都关时按 Home 就该安静停下，不必向外声明「我在放媒体」——
      // 否则系统会留一张媒体卡片，用户以为还能后台播。
      // 会话要在**前台开始播放时**建（进后台再建，系统已经判过「没有会话」，焦点不还给你）。
      if (this.bgPlay || this.pipAuto) {
        BackAudio.setPlaying(this.playing);
        if (this.playing) {
          BackAudio.ensure(getContext(this) as common.UIAbilityContext, '');
        }
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] play/pause: ${e.code} ${e.message}`);
    }
  }

  private seekTo(seconds: number): void {
    if (this.player === undefined) {
      return;
    }
    const target: number = Math.max(0, Math.min(this.duration, seconds));
    try {
      // 先标记再 seek：mpv 会在几毫秒内进入 paused-for-cache，
      // 采样恰好落在这一段时按「正常重缓冲」处理，不弹遮罩。
      this.lastSeekAt = Date.now();
      AppLog.mark('seek', `-> ${target.toFixed(1)}s (dur ${this.duration.toFixed(0)}s, from ${this.pos.toFixed(1)}s)`);
      this.bufferSince = -1;
      this.showBufferOverlay = false;
      this.player.seek(target);
      this.pos = target;
      // 跳转后清空弹幕与「已发过」记录，否则往回拖会整片不冒
      this.shownIds = [];
      this.live = [];
      this.danmuClock = target;
      this.lastDanmuClock = target - 0.01;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] seek: ${e.code} ${e.message}`);
    }
  }

  /** 快进快退（R13）：夹在 0..duration 之间，走同一条 seekTo 以复用缓冲判定。 */
  private seekBy(delta: number): void {
    if (this.duration <= 0) {
      return;
    }
    const target: number = Math.max(0, Math.min(this.duration, this.pos + delta));
    this.seekTo(target);
  }

  /** 长按临时倍速（R11）：按下 3x，松手回到长按前的固定档，不改用户选的档位。 */
  private tempSpeed(on: boolean): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      if (on) {
        if (!this.tempSpeedActive && this.speed < this.tempSpeedValue) {
          this.speedBeforeTemp = this.speed;
          p.setSpeed(this.tempSpeedValue);
          this.speed = this.tempSpeedValue;
          this.tempSpeedActive = true;
        }
      } else if (this.tempSpeedActive || this.speed > this.tempSpeedValue - 0.001) {
        const back: number = this.speedBeforeTemp > 0 ? this.speedBeforeTemp : 1.0;
        p.setSpeed(back);
        this.speed = back;
        this.tempSpeedActive = false;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.tempSpeedActive = false;
      console.error(`[amane] temp speed: ${e.code} ${e.message}`);
    }
  }

  /** 画面比例：适应（fit）/ 铺满（fill）/ 16:9。只调显示比例，不动锁定解码参数。 */
  private applyAspectMode(mode: string): void {
    this.aspectMode = mode;
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      const lib = p.native;
      if (mode === 'fill') {
        lib.command(['set', 'video-aspect-override', '-1']);
        lib.command(['set', 'panscan', '1']);
        this.toast('画面 · 铺满');
      } else if (mode === '16:9') {
        lib.command(['set', 'panscan', '0']);
        lib.command(['set', 'video-aspect-override', '16:9']);
        this.toast('画面 · 16:9');
      } else {
        lib.command(['set', 'panscan', '0']);
        lib.command(['set', 'video-aspect-override', '-1']);
        this.toast('画面 · 适应');
      }
    } catch (err) {
      console.error(`[amane] aspect mode: ${JSON.stringify(err)}`);
    }
  }

  /** 全屏锁屏：防误触（锁屏后仅保留左侧玻璃解锁键，禁用手势与其他控件）。 */
  private toggleScreenLock(): void {
    this.screenLocked = !this.screenLocked;
    if (this.screenLocked) {
      this.showControls = false;
      this.showPanel = false;
      this.showPicker = false;
      this.subStyleOpen = false;
      this.flashLockUi();
      this.toast('已锁定屏幕');
    } else {
      this.lockUiShown = false;
      if (this.lockUiTimer >= 0) {
        clearTimeout(this.lockUiTimer);
        this.lockUiTimer = -1;
      }
      this.showControls = true;
      this.toast('已解锁屏幕');
    }
  }

  private flashLockUi(): void {
    this.lockUiShown = true;
    if (this.lockUiTimer >= 0) {
      clearTimeout(this.lockUiTimer);
    }
    this.lockUiTimer = setTimeout(() => {
      this.lockUiShown = false;
      this.lockUiTimer = -1;
    }, 3000);
  }

  /** 读取当前窗口真实亮度作为手势基线（-1 表示跟随系统自动亮度）。 */
  private readCurrentBrightness(): number {
    if (this.win !== undefined) {
      try {
        const b: number = this.win.getWindowProperties().brightness;
        if (b >= 0 && b <= 1) {
          this.bright = b;
          return b;
        }
      } catch (err) {
        console.info(`[amane] read brightness: ${JSON.stringify(err)}`);
      }
    }
    return this.bright;
  }

  /** 节流下发窗口亮度，避免 60~120Hz 手势帧堆积 IPC 导致跳变/卡顿。 */
  private setBrightnessThrottled(val: number, force: boolean = false): void {
    const clamped: number = Math.max(0.02, Math.min(1.0, val));
    this.bright = clamped;
    this.brightnessTouched = true;
    const now: number = Date.now();
    if (!force && this.lastBrightVal >= 0
      && Math.abs(clamped - this.lastBrightVal) < 0.015
      && now - this.lastBrightAt < 28) {
      return;
    }
    this.lastBrightVal = clamped;
    this.lastBrightAt = now;
    if (this.win !== undefined) {
      this.win.setWindowBrightness(clamped).catch((err: BusinessError) => {
        console.error(`[amane] brightness: ${err.code} ${err.message}`);
      });
    }
  }

  /** 字幕时间偏移（sub-delay）：-0.5s / +0.5s / 归零，实时生效不打断播放。 */
  private adjustSubDelay(delta: number, reset: boolean = false): void {
    const next: number = reset
      ? 0 : Math.max(-30, Math.min(30, Math.round((this.subDelay + delta) * 10) / 10));
    this.subDelay = next;
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    const lib = p.native;
    try {
      lib.command(['set', 'sub-delay', `${next}`]);
    } catch (err) {
      try {
        lib.setProperty('sub-delay', next);
      } catch (err2) {
        console.error(`[amane] sub delay: ${JSON.stringify(err2)}`);
      }
    }
  }
  /** 直接选一个倍速档位（顶栏胶囊的下拉菜单走这里）。 */
  private applySpeed(v: number): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      p.setSpeed(v);
      this.speed = v;
      this.toast(`倍速 ${v}x`);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] speed: ${e.code} ${e.message}`);
    }
  }

  /**
   * 截取当前帧（R25）：服务端按这一秒抽一张 1280 宽的大图。
   * 用途三合一 —— 进亮点条并标「我选的」、够清晰的同时进剧照、没刮削封面的片子也能用它。
   * 客户端不做截图：mpv 的截图接口要另开 surface，而且抽帧管线服务端已经有了。
   */
  private async snapFrame(): Promise<void> {
    if (this.metaId <= 0 || this.snapBusy) {
      return;
    }
    this.snapBusy = true;
    this.toast('截取中…');
    try {
      const body: string = JSON.stringify({
        t: Math.round(this.pos * 10) / 10,
        file_key: this.fileKey
      });
      const text: string = await httpPost(
        `${Store.I.user}/api/user/highlights/${this.metaId}/snap`, Store.I.token, body);
      const r: SnapResult = JSON.parse(text) as SnapResult;
      if (r.ok === true) {
        this.toast(r.still ? '已存为亮点 + 剧照' : '已存为亮点');
        // 「截帧自动存到相册」（用户第 10 条）：开了就下载 + 直接发起写相册。
        // 系统会弹一次「保存到相册」确认（普通应用拿不到 WRITE_IMAGEVIDEO，
        // showAssetsCreationDialog 是唯一合规路径），确认后进系统相册。
        if (Store.I.prefString('frame_save_local', '0') === '1') {
          const ctx = getContext(this) as common.UIAbilityContext;
          const title: string = `${this.metaNumber.length > 0 ? this.metaNumber : 'Amane'}_${r.ms}`;
          savePickLocal(Store.I.img(r.url), Store.I.token, this.metaId, r.ms)
            .then((path: string) => Gallery.saveImage(ctx, path, title))
            .then((ok: boolean) => {
              if (ok) {
                this.toast('已存到相册');
              }
            })
            .catch((err: BusinessError) => {
              console.error(`[amane] save pick: ${err.code} ${err.message}`);
            });
        }
      } else {
        this.toast(r.reason.length > 0 ? r.reason : '截取失败');
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] snap: ${e.code} ${e.message}`);
      this.toast('截取失败');
    }
    this.snapBusy = false;
  }

  /**
   * 进度条预览（R08）：服务端第一次要现生成（本地库十几秒），所以这里做成
   * 「拉不到就隔 6 秒再来」，最多 8 次；生不出来就一直保持无预览，不影响播放。
   */
  private async loadPreview(): Promise<void> {
    if (this.metaId <= 0 || this.prevOk) {
      return;
    }
    try {
      const url: string = `${Store.I.user}/api/user/preview/${this.metaId}` +
        (this.fileKey.length > 0 ? `?file=${this.fileKey}` : '');
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      if (obj.ok === true) {
        this.prevCols = Math.trunc(Number(obj.cols) || 8);
        this.prevRows = Math.trunc(Number(obj.rows) || 8);
        this.prevStep = Number(obj.step) || 30;
        this.prevCount = Math.trunc(Number(obj.count) || (this.prevCols * this.prevRows));
        this.prevUrl = String(obj.url);
        this.prevOk = this.prevUrl.length > 0;
        return;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] preview: ${e.code} ${e.message}`);
    }
    if (this.prevTries < 8) {
      this.prevTries = this.prevTries + 1;
      setTimeout(() => {
        this.loadPreview();
      }, 6000);
    }
  }

  /** 竖屏详情：只拉一次本片的简介/演员/标签（横屏不显示，就不用拉）。 */
  private async loadDetail(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/item/${this.metaId}`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.detailPlot = String(obj.plot === undefined || obj.plot === null ? '' : obj.plot);
      this.detailSeries = String(obj.series === undefined || obj.series === null ? '' : obj.series);
      const actors: string[] = [];
      const rawA = obj.actors;
      if (Array.isArray(rawA)) {
        for (let i = 0; i < rawA.length; i++) {
          actors.push(String(rawA[i]));
        }
      }
      this.detailActors = actors;
      const tags: string[] = [];
      const rawT = obj.tags;
      if (Array.isArray(rawT)) {
        for (let i = 0; i < rawT.length; i++) {
          tags.push(String(rawT[i]));
        }
      }
      this.detailTags = tags;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] detail: ${e.code} ${e.message}`);
    }
  }

  /**
   * 拖动位置 → 雪碧图第几格（列优先）。
   *
   * ★ 不按「整片时长 / 格数」自己算，直接用服务端给的 step ★
   *   服务端 64 格是按 `duration/64` 均匀取样的，两个值必须来自同一处，
   *   否则会整片错位（表现为「预览全是黑/对不上时间」）。
   */
  private previewCell(): number[] {
    const idx: number = Math.max(0, Math.min(this.prevCount - 1,
      Math.floor(this.seekPreview / Math.max(1, this.prevStep))));
    return [idx % this.prevCols, Math.floor(idx / this.prevCols)];
  }

  /** 预览每格固定显示 128×72（16:9），雪碧图按 cols×rows 等比铺开。 */
  private previewX(): number {
    return -this.previewCell()[0] * 128;
  }

  private previewY(): number {
    return -this.previewCell()[1] * 72;
  }

  /** 弹幕样式配置（设置 → 播放器 → 弹幕）。 */
  private loadDanmuConf(): void {
    this.danmuOn = Store.I.prefString('danmu_on', '1') === '1';
    const size: number = Number(Store.I.prefString('danmu_size', '16'));
    this.danmuSize = size >= 12 && size <= 24 ? size : 16;
    const sp: number = Number(Store.I.prefString('danmu_speed', '90'));
    this.danmuSpeedVp = sp >= 40 && sp <= 200 ? sp : 90;
    const tr: number = Number(Store.I.prefString('danmu_tracks', '6'));
    this.danmuTracks = tr >= 3 && tr <= 10 ? Math.trunc(tr) : 6;
    const al: number = Number(Store.I.prefString('danmu_alpha', '0.9'));
    this.danmuAlpha = al >= 0.3 && al <= 1 ? al : 0.9;
  }

  /** 粗略估宽：中文按字号、ASCII 按 0.55 字号。只用来判断何时飞出屏幕。 */
  private estWidth(text: string): number {
    let w: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      w += code > 255 ? this.danmuSize : this.danmuSize * 0.55;
    }
    return w + 16;
  }


  /**
   * 弹幕调度（100ms 一次）：只做「起飞 / 回收」，位移交给组件自己的线性动画。
   *
   * 每条弹幕的飞行时长 = (屏宽 + 文字宽) / 速度，跟设置里的「速度」联动；
   * 轨道占用按**时间反推**当前位置判断（不依赖每帧改状态）。
   */
  private tickDanmu(): void {
    const now: number = Date.now();
    const dt: number = this.lastDanmuTick > 0 ? (now - this.lastDanmuTick) / 1000 : 0.1;
    this.lastDanmuTick = now;
    if (!this.danmuOn || this.annotations.length === 0) {
      if (this.live.length > 0) {
        this.live = [];
      }
      return;
    }
    // 只要在播，弹幕时钟就往前走 —— 缓冲时也不停
    if (this.playing) {
      this.danmuClock += dt;
    }
    // 不缓冲时平滑追回播放位置（避免长期漂移）
    if (!this.buffering) {
      const gap: number = this.danmuClock - this.pos;
      if (Math.abs(gap) > 2) {
        this.danmuClock -= (gap > 0 ? 1 : -1) * Math.min(Math.abs(gap), dt * 1.5);
      }
    }
    // ① 回收：已经飞完的
    if (this.live.length > 0) {
      let dirty: boolean = false;
      const keep: DanmuLive[] = [];
      for (let i = 0; i < this.live.length; i++) {
        const d: DanmuLive = this.live[i];
        if (now - d.born < d.dur + 400) {
          keep.push(d);
        } else {
          dirty = true;
        }
      }
      if (dirty) {
        this.live = keep;
      }
    }
    // ② 新弹幕：弹幕时钟**越过**它的时间点就发。
    // 用「上一帧时钟 → 这一帧时钟」这个区间判断，比 `at <= clock < at+0.5` 稳：
    // 掉帧、卡一下、缓存恢复后一次跨过好几秒，窗口式判断会整片漏掉。
    const from: number = this.lastDanmuClock;
    this.lastDanmuClock = this.danmuClock;
    let added: DanmuLive[] = [];
    const size: number = this.viewMode === 'portrait' ? this.danmuSize * 0.8 : this.danmuSize;
    const base: number = this.danmuTop();
    const line: number = this.danmuLine();
    for (let i = 0; i < this.annotations.length; i++) {
      const a: AnnoItem = this.annotations[i];
      const at: number = a.t_ms / 1000.0;
      if (this.shownIds.indexOf(a.id) >= 0) {
        continue;
      }
      if (at > from && at <= this.danmuClock) {
        this.shownIds.push(a.id);
        const w: number = this.estWidth(a.body);
        const track: number = this.pickTrack(now);
        const startX: number = this.vpW + 8;
        const endX: number = -w - 16;
        const dur: number = Math.max(2400,
          Math.round((startX - endX) / Math.max(40, this.danmuSpeedVp) * 1000));
        added.push({
          // 同一条弹幕可能被「跳转 → 回来」重复命中，key 里带时间戳保证唯一
          id: a.id * 1000 + (now % 1000),
          text: a.body,
          track: track,
          x: startX,
          w: w,
          born: now,
          dur: dur,
          from: startX,
          to: endX,
          top: base + track * line,
          size: size
        });
      }
    }
    if (added.length > 0) {
      this.live = this.live.concat(added);
    }
  }

  /** 按「现在这一刻」各轨道的占用情况挑一条（时间反推位置，不改任何状态）。 */
  private pickTrack(now: number): number {
    const tracks: number = this.danmuTrackCount();
    const safe: number = this.vpW * 0.55;
    for (let t = 0; t < tracks; t++) {
      let busy: boolean = false;
      for (let i = 0; i < this.live.length; i++) {
        const d: DanmuLive = this.live[i];
        if (d.track !== t) {
          continue;
        }
        const p: number = Math.min(1, Math.max(0, (now - d.born) / d.dur));
        const x: number = d.from + (d.to - d.from) * p;
        if (x + d.w > safe) {
          busy = true;
          break;
        }
      }
      if (!busy) {
        return t;
      }
    }
    // 全忙：随机丢一条轨道（叠一点总比不显示好）
    return Math.floor(Math.random() * tracks);
  }

  /** 拉这部片**这个文件**的全部弹幕（换版本/换集就换一批，不串）。 */
  private async loadAnnotations(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const suffix: string = this.fileKey.length > 0
        ? `?file=${encodeURIComponent(this.fileKey)}` : '';
      const text: string = await httpGet(
        `${Store.I.user}/api/user/annotations/${this.metaId}${suffix}`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items;
      const out: AnnoItem[] = [];
      if (Array.isArray(raw)) {
        for (let i = 0; i < raw.length; i++) {
          const it = raw[i] as AnnoItem;
          out.push({
            id: Math.trunc(Number(it.id) || 0),
            t_ms: Math.trunc(Number(it.t_ms) || 0),
            body: String(it.body)
          });
        }
      }
      this.annotations = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] annotations: ${e.code} ${e.message}`);
    }
  }

  /** 当前时间点该不该出一条批注：落在 [t, t+4s] 里，取最近的一条。 */
  private annoFor(pos: number): string {
    let best: string = '';
    let bestGap: number = 999.0;
    for (let i = 0; i < this.annotations.length; i++) {
      const t: number = this.annotations[i].t_ms / 1000.0;
      const gap: number = pos - t;
      if (gap >= 0 && gap <= 4.0 && gap < bestGap) {
        bestGap = gap;
        best = this.annotations[i].body;
      }
    }
    return best;
  }

  private openAnnoInput(): void {
    this.showAnnoInput = true;
    this.showPicker = false;
    this.showPanel = false;
    this.annoDraft = '';
  }

  private async addAnnotation(): Promise<void> {
    const text: string = this.annoDraft.trim();
    if (text.length === 0 || this.annoBusy) {
      return;
    }
    this.annoBusy = true;
    try {
      const body: string = JSON.stringify({
        t: Math.round(this.pos * 10) / 10,
        body: text,
        file_key: this.fileKey
      });
      await httpPost(`${Store.I.user}/api/user/annotations/${this.metaId}`, Store.I.token, body);
      this.showAnnoInput = false;
      this.annoDraft = '';
      await this.loadAnnotations();
      this.toast('弹幕已发出');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] add anno: ${e.code} ${e.message}`);
      this.toast('弹幕发送失败');
    }
    this.annoBusy = false;
  }

  /**
   * 嵌入式详情页要求换版本：直接换当前播放的文件，不叠新页面。
   */
  private switchFile(fileKey: string, fileName: string): void {
    if (fileKey.length > 0 && fileKey === this.fileKey) {
      return;
    }
    // 小窗还开着就换片/换版本：先把小窗收掉，不然两个画面抢同一个 surface
    if (this.pipActive) {
      this.stopPip();
      this.onPipClosed();
    }
    this.saveProgress(true);
    this.fileKey = fileKey;
    this.fileName = fileName;
    this.startPos = this.pos;
    this.versions = [];
    this.openMedia();
    this.toast('已切换版本');
  }

  /** 打开选集面板：两个 tab 一起拉，切 tab 不再等网络。 */
  private openPicker(): void {
    this.showPicker = true;
    this.showPanel = false;
    this.loadVersions();
    this.loadSiblings();
  }

  private async loadVersions(): Promise<void> {
    if (this.versions.length > 0 || this.metaId <= 0) {
      return;
    }
    this.pickerLoading = true;
    try {
      const url: string = `${Store.I.user}/api/user/streams/${Store.I.playbackSource}/${this.metaId}`;
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items;
      const out: VerItem[] = [];
      if (Array.isArray(raw)) {
        for (let i = 0; i < raw.length; i++) {
          const it = raw[i] as VerItem;
          out.push({
            key: String(it.key),
            name: String(it.name),
            size: Number(it.size) || 0,
            definition: String(it.definition),
            duration: Number(it.duration) || 0,
            available: it.available === true
          });
        }
      }
      this.versions = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] versions: ${e.code} ${e.message}`);
    }
    this.pickerLoading = false;
  }

  /** 版本列表里的分段组键（见 `common/Parts.ets`）：同目录同前缀、至少两段才算。 */
  private versionPartKeys(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.versions.length; i++) {
      names.push(this.versions[i].name);
    }
    return partGroupKeys(names);
  }

  /**
   * 版本 tab 拆成两块：**版本**（不同画质 / 来源）与**分集**（同一部被切开的 cd1/cd2）。
   *
   * 之前它们平铺在一个列表里 —— 用户看到「3 个版本」，实际是 1 版 + 3 段
   * （2026-11-13 反馈：「多版本和分集堆在一起」）。判定保守，见 `common/Parts.ets`。
   */
  private versionOnly(): VerItem[] {
    const keys: string[] = this.versionPartKeys();
    const out: VerItem[] = [];
    for (let i = 0; i < this.versions.length; i++) {
      if (!inPartGroup(this.versions[i].name, keys)) {
        out.push(this.versions[i]);
      }
    }
    return out;
  }

  private partOnly(): VerItem[] {
    const keys: string[] = this.versionPartKeys();
    const out: VerItem[] = [];
    for (let i = 0; i < this.versions.length; i++) {
      if (inPartGroup(this.versions[i].name, keys)) {
        out.push(this.versions[i]);
      }
    }
    out.sort((a: VerItem, b: VerItem) => partNoOf(a.name) - partNoOf(b.name));
    return out;
  }

  /** 选集面板里的一行：版本与分集共用同一套渲染，只有分组标题不同。 */
  @Builder
  VerRow(v: VerItem) {
    Row({ space: 10 }) {
      if (v.key === this.fileKey) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(12)
          .fontColor([Theme.ACCENT_INK])
      }
      Column({ space: 4 }) {
        Text(v.name)
          .fontSize(12)
          .fontWeight(v.key === this.fileKey ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(v.key === this.fileKey ? Theme.TEXT : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 6 }) {
          if (v.definition.length > 0) {
            Text(v.definition)
              .fontSize(9)
              .fontColor(v.key === this.fileKey ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(v.key === this.fileKey ? Theme.accentAlpha(0.18) : '#1FFFFFFF')
              .borderRadius(6)
          }
          Text(`${Math.round(v.size / 1048576)} MB`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .fontFeature('"tnum" 1')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (v.key === this.fileKey) {
        Text('当前')
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.accentAlpha(0.20))
          .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
          .borderRadius(9)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(12)
    .backgroundColor(v.key === this.fileKey ? Theme.accentAlpha(0.16) : '#00000000')
    .border({
      width: v.key === this.fileKey ? 0.75 : 0,
      color: Theme.accentAlpha(0.48)
    })
    .onClick(() => {
      this.pickVersion(v);
    })
  }

  private async loadSiblings(): Promise<void> {
    if (this.siblings.length > 0 || this.metaId <= 0) {
      return;
    }
    try {
      const url: string = `${Store.I.user}/api/user/item/${this.metaId}/siblings?limit=40`;
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items;
      const out: SibItem[] = [];
      if (Array.isArray(raw)) {
        for (let i = 0; i < raw.length; i++) {
          const it = raw[i] as SibItem;
          const names: string[] = [];
          if (Array.isArray(it.actors)) {
            for (let k = 0; k < it.actors.length; k++) {
              names.push(String(it.actors[k]));
            }
          }
          out.push({
            id: Number(it.id) || 0,
            number: String(it.number),
            title: String(it.title),
            poster: String(it.poster),
            actors: names,
            current: it.current === true
          });
        }
      }
      this.sibName = String(obj.name === undefined || obj.name === null ? '' : obj.name);
      this.siblings = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] siblings: ${e.code} ${e.message}`);
    }
  }

  /** 换版本：保持当前位置重新开流（不重建页面，进度也不丢）。 */
  private pickVersion(v: VerItem): void {
    if (v.key === this.fileKey) {
      this.showPicker = false;
      return;
    }
    this.saveProgress(true);
    this.fileKey = v.key;
    this.fileName = v.name;
    this.startPos = this.pos;
    this.showPicker = false;
    this.versions = [];
    this.openMedia();
  }

  /** 换到同系列的另一部片：整页重开最稳（等于从详情页点进来）。 */
  private pickSibling(s: SibItem): void {
    if (s.current || s.id <= 0) {
      return;
    }
    this.saveProgress(true);
    this.showPicker = false;
    const p: PlayerParams = {
      id: s.id,
      number: s.number,
      title: s.title,
      position: 0,
      fileKey: '',
      fileName: ''
    };
    router.replaceUrl({ url: 'pages/PlayerHostPage', params: p }).catch((err: BusinessError) => {
      console.error(`[amane] swap sibling: ${err.code} ${err.message}`);
    });
  }

  /**
   * 进入画中画（R18，A 方案）。2026-11-11 二次改造（用户第 6 条）：
   *
   * 不再 `minimize()` 回桌面。用户要的是「小窗浮着，我继续在应用里逛」：
   *  - 播放区原地换成占位符（正在画中画播放 + 两个操作）；
   *  - 详情抽屉、其它页面照常用；
   *  - 关掉小窗（X）只是关掉，**不跳页**；
   *  - 只有点小窗右上角「回到应用/全屏」才回到播放页，并按设置里的默认形态继续播。
   */
  /**
   * 后台期间的屏灭巡检（2.6.1.37）。
   *
   * 为什么不直接用 `display.on('change')`：那个回调要带 Display 参数、还要在
   * struct 里管住 this 绑定，改播放器风险大；600ms 轮一次只在「已经在后台」时才跑，
   * 开销可以忽略，逻辑也不会因为回调签名变化而失效。
   */
  private watchScreenOff(): void {
    this.clearScreenWatch();
    this.bgWatch = setInterval(() => {
      if (!BackAudio.screenOff()) {
        return;
      }
      this.pauseForScreenOff();
      BackgroundPlay.stop(getContext(this) as common.UIAbilityContext);
      this.clearScreenWatch();
    }, 600);
  }

  private clearScreenWatch(): void {
    if (this.bgWatch >= 0) {
      clearInterval(this.bgWatch);
      this.bgWatch = -1;
    }
  }

  /** 锁屏就停：只在真的在播时切换，别把已经暂停的片切回播放。 */
  private pauseForScreenOff(): void {
    if (this.playing) {
      this.togglePlay();
    }
    this.stopPip();
  }

  /** 前台 surface 就绪后注册；Home 自动启动交给系统选择正确时机。 */
  private async preparePip(): Promise<void> {
    if (this.disposed || !this.windowVisible || !this.surfaceReady
      || this.pipCtrl !== undefined || this.pipPreparing || !PiPWindow.isPiPEnabled()) {
      return;
    }
    const epoch: number = this.pipEpoch;
    this.pipPreparing = true;
    try {
      if (this.xc.getXComponentSurfaceId().length === 0) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      let cw: number = 1280;
      let ch: number = 720;
      const p: Player | undefined = this.player;
      if (p !== undefined) {
        const vp = p.state.videoParams;
        if (vp !== undefined && vp.dw > 0 && vp.dh > 0) {
          cw = Math.round(vp.dw);
          ch = Math.round(vp.dh);
        }
      }
      const config: PiPWindow.PiPConfiguration = {
        context: ctx,
        componentController: this.xc,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: cw,
        contentHeight: ch
      };
      const ctrl: PiPWindow.PiPController = await PiPWindow.create(config);
      // create 返回时页面或 surface 可能已经换代，旧 controller 不得注册自动启动。
      if (this.disposed || epoch !== this.pipEpoch) {
        ctrl.setAutoStartEnabled(false);
        return;
      }
      this.pipCtrl = ctrl;
      ctrl.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        if (this.disposed || this.pipCtrl !== ctrl) {
          return;
        }
        console.info(`[amane] pip state ${state}: ${reason}`);
        this.pipState = state;
        if (state === PiPWindow.PiPState.ABOUT_TO_START) {
          this.pipStarting = true;
        } else if (state === PiPWindow.PiPState.STARTED) {
          this.pipStarting = false;
          this.pipActive = true;
          PipHub.claim(this.pipOwner, () => {
            this.stopPip();
            this.onPipClosed();
          });
          if (BackAudio.screenOff()) {
            this.pauseForScreenOff();
          }
        } else if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
          // 等 STOPPED 归还 surface 后再改方向，避免转屏重建抢走 PiP 的 surface。
          this.pipRestoring = true;
        } else if (state === PiPWindow.PiPState.STOPPED) {
          const restoring: boolean = this.pipRestoring;
          this.pipRestoring = false;
          this.pipStarting = false;
          this.pipActive = false;
          PipHub.release(this.pipOwner);
          if (restoring) {
            this.restoreFromPip();
          } else {
            this.onPipClosed();
          }
        } else if (state === PiPWindow.PiPState.ERROR) {
          this.pipStarting = false;
          this.pipActive = false;
          this.pipRestoring = false;
          PipHub.autoArmed = false;
          PipHub.release(this.pipOwner);
          // 小窗起不来时别让声音一起没：退回纯后台出声（用户开了那个开关的话）
          if (!this.windowVisible && this.bgPlay && this.playing) {
            BackgroundPlay.start(getContext(this) as common.UIAbilityContext);
          }
        }
      });
      ctrl.on('controlEvent', (event: PiPWindow.ControlEventParam) => {
        if (this.disposed || this.pipCtrl !== ctrl || BackAudio.screenOff()) {
          return;
        }
        if (event.controlType === PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE
          && event.status !== undefined
          && (event.status === PiPWindow.PiPControlStatus.PLAY) !== this.playing) {
          this.togglePlay();
        }
      });
      this.updatePipAutoStart();
      console.info('[amane] pip prepared');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] pip prepare: ${e.code} ${e.message}`);
    } finally {
      if (epoch === this.pipEpoch) {
        this.pipPreparing = false;
      }
    }
  }

  private updatePipAutoStart(): void {
    const ctrl: PiPWindow.PiPController | undefined = this.pipCtrl;
    if (ctrl === undefined) {
      return;
    }
    const enable: boolean = !this.disposed && this.pipAuto && this.playing && this.firstFrame;
    // 让「后台出声」那条路知道小窗要接管音频了（见 PipHub.autoArmed 的注释）。
    PipHub.autoArmed = enable;
    if (enable === this.pipAutoArmed) {
      return;
    }
    try {
      ctrl.setAutoStartEnabled(enable);
      this.pipAutoArmed = enable;
      console.info(`[amane] pip auto: ${enable}`);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pip auto: ${e.code} ${e.message}`);
    }
  }

  private async startPip(): Promise<void> {
    if (this.disposed || !this.windowVisible || this.pipActive || this.pipStarting || this.pipPreparing) {
      return;
    }
    const epoch: number = this.pipEpoch;
    this.pipStarting = true;
    try {
      if (!PiPWindow.isPiPEnabled()) {
        this.toast('这台设备不支持画中画');
        return;
      }
      await this.preparePip();
      const ctrl: PiPWindow.PiPController | undefined = this.pipCtrl;
      if (ctrl === undefined || epoch !== this.pipEpoch || this.disposed || !this.windowVisible
        || this.pipActive || this.pipState === PiPWindow.PiPState.ABOUT_TO_START) {
        return;
      }
      await ctrl.startPiP();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pip: ${e.code} ${e.message}`);
    } finally {
      if (epoch === this.pipEpoch && this.pipState !== PiPWindow.PiPState.ABOUT_TO_START) {
        this.pipStarting = false;
      }
    }
  }

  /** 小窗被关掉：留在当前页面，播放停住（没有画面了，继续放声音只会让人困惑）。 */
  private onPipClosed(): void {
    this.pipActive = false;
    PipHub.release(this.pipOwner);
    try {
      if (this.player !== undefined && this.playing) {
        this.player.playOrPause();
        this.playing = false;
        BackAudio.setPlaying(false);
        this.updatePipAutoStart();
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pause after pip: ${e.code} ${e.message}`);
    }
    this.clearScreenWatch();
    BackgroundPlay.stop(getContext(this) as common.UIAbilityContext);
  }

  /** 小窗「回到应用」：回到播放页，按设置里的默认形态继续播。 */
  private restoreFromPip(): void {
    if (this.pipCtrl !== undefined && this.pipActive) {
      this.pipRestoring = true;
      this.pipCtrl.stopPiP().catch((err: BusinessError) => {
        this.pipRestoring = false;
        console.error(`[amane] restore pip: ${err.code} ${err.message}`);
      });
      return;
    }
    this.pipActive = false;
    PipHub.release(this.pipOwner);
    this.showControls = true;
    const wantLandscape: boolean =
      Store.I.prefString('player_jump_mode', 'portrait') === 'landscape';
    this.viewMode = wantLandscape ? 'landscape' : 'portrait';
    this.forceOrientation(wantLandscape
      ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
    // 用户可能已经翻到别的页面：把播放页翻回来（它已经在栈里，不会重建）。
    // 只有整页宿主（Emby）才有「单独的播放页」可翻；B 站模式下播放器就在当前页。
    if (this.pageHost) {
      try {
        router.back({ url: 'pages/PlayerHostPage' });
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] already on player: ${e.code}`);
      }
    }
    if (!this.playing) {
      this.togglePlay();
    }
  }

  private stopPip(): void {
    const c: PiPWindow.PiPController | undefined = this.pipCtrl;
    const running: boolean = this.pipActive || this.pipStarting;
    this.pipEpoch++;
    this.pipPreparing = false;
    this.pipCtrl = undefined;
    this.pipActive = false;
    this.pipStarting = false;
    this.pipRestoring = false;
    this.pipAutoArmed = false;
    this.pipSized = false;
    this.lastPipPlaying = false;
    this.pipState = PiPWindow.PiPState.STOPPED;
    PipHub.autoArmed = false;
    PipHub.release(this.pipOwner);
    if (c === undefined) {
      return;
    }
    try {
      c.setAutoStartEnabled(false);
      c.off('stateChange');
      c.off('controlEvent');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] release pip: ${e.code} ${e.message}`);
    }
    if (!running) {
      return;
    }
    c.stopPiP().catch((err: BusinessError) => {
      console.error(`[amane] stop pip: ${err.code} ${err.message}`);
    });
  }

  /**
   * 三态切换（R15 改）：
   *   portrait（顶部 16:9）→ 点全屏 → portraitFull（竖屏全屏）
   *   portraitFull → 点退出 → portrait
   *   landscape（横屏）→ 点退出 → 回竖屏顶部
   */
  /**
   * 竖屏顶部形态下播放器的高度：按宽度 16:9 定（用户第 2 条要求）。
   * 横屏全屏时直接用整屏高。
   */
  private videoH(): number {
    if (this.viewMode !== 'portrait') {
      return this.vpH;
    }
    return Math.min(this.vpW * 9 / 16, this.vpH);
  }

  /**
   * 抽屉上拉之后视频**收缩**到的高度。
   *
   * 参考 PiliPlus：竖屏时视频钉在顶部，往上拖详情页，视频跟着缩小而不是被盖住 ——
   * 盖住等于不让人看了。缩到 42%（约 85vp）就停，再小就只剩一条黑边。
   */
  private minVideoH(): number {
    return this.videoH();
  }

  /** 当前视频框高度（拖动时实时变）。 */
  private videoBoxH(): number {
    return this.videoH();
  }

  /** 视频框宽度：保持 16:9，缩小时左右留黑边居中。 */
  private videoBoxW(): number {
    return this.vpW;
  }

  /** 是否已经缩小（此时收起完整控件，只留一个「点一下展开」的提示）。 */
  private shrunken(): boolean {
    return false;
  }

  /** 抽屉最多上拉多少：视频缩到 minVideoH 为止。 */
  private maxLift(): number {
    return 0;
  }

  private sheetH(): number {
    return 0;
  }

  /** 点抓手 / 点收缩后的画面：在「原尺寸 / 最小」之间切换。 */
  private toggleSheet(): void {
  }

  /** 弹幕的起始高度与行距：竖屏那块只有 200vp，按全屏的 58vp 起会飞出画面。 */
  private danmuTop(): number {
    return this.viewMode === 'portrait' ? 34 : 58;
  }

  private danmuLine(): number {
    if (this.viewMode === 'portrait') {
      return this.danmuSize * 0.8 + 8;
    }
    return this.danmuSize + 10;
  }

  private danmuTrackCount(): number {
    if (this.viewMode === 'portrait') {
      return Math.min(4, this.danmuTracks);
    }
    return this.danmuTracks;
  }

  /**
   * 手势层的高度：**避开底部控件条**。
   *
   * 手势挂在整块画面上时，拖进度条的水平拖动会被父级的「左右拖 = 找进度」抢走：
   * slider 不跟手，位移还被换算成几百秒，表现就是「一拖直接跳到最前/最后」。
   */
  private gestureH(): number {
    if (this.viewMode === 'portrait') {
      // 底部控件（工具行 + 播放条）加起来约 70vp，手势层要让开
      const bar: number = this.collapsedChrome() ? 34 : 74;
      return Math.max(48, this.videoBoxH() - bar);
    }
    if (this.viewMode === 'portraitFull') {
      return Math.max(48, this.vpH - 86);
    }
    return Math.max(48, this.vpH - 60);
  }

  /** 竖屏控件是否处于「只有一条 MiniBar」的状态。 */
  private collapsedChrome(): boolean {
    return this.shrunken() || !this.showControls;
  }

  /** 手势层的宽度（左半亮度 / 右半音量的分界就用它）。 */
  private gestureW(): number {
    if (this.viewMode === 'portrait') {
      return this.videoBoxW();
    }
    return this.vpW;
  }

  /**
   * 全屏切换（第 2 条：竖屏全屏先隐藏，代码留着）。
   *  - 页内 16:9 点「全屏」= 直接横屏（不再中途停在竖屏全屏那一档）
   *  - 横屏点「退出全屏」= 回竖屏 16:9
   */
  private toggleFull(): void {
    if (this.viewMode === 'landscape') {
      this.exitToPortrait();
      return;
    }
    this.toLandscape();
  }

  /** 竖屏全屏里点「横屏」：强制转过去（锁到用户把手机横过来为止） */
  private toLandscape(): void {
    this.orientIntent = 'landscape';
    this.lockIntent('landscape');
    this.viewMode = 'landscape';
    this.forceOrientation(window.Orientation.LANDSCAPE);
    this.applyWindowMode();
    this.rebindSurface(true);
    this.retryOrientation(false);
  }

  private forceOrientation(o: window.Orientation): void {
    const w: window.Window | undefined = this.win;
    if (w === undefined) {
      return;
    }
    w.setPreferredOrientation(o).catch((err: BusinessError) => {
      console.error(`[amane] orientation: ${err.code} ${err.message}`);
    });
  }

  /**
   * 形态变了（竖屏顶部 ↔ 全屏 ↔ 横屏）：换一代 XComponent 重建 surface。
   *
   * 只 detach/attach 同一块 surface 经常 attach 不回来 → 画面直接消失（用户第 7 条）。
   * 重建后 onLoad 里会 attach 新 surfaceId 并 seek 一帧。
   */
  private rebindSurface(forceSeek: boolean): void {
    // 重建会换一代 XComponent，onLoad 里又要 seek 一次；若外层由「尺寸变化」反复触发，
    // 就会变成 重建→seek→尺寸变化→重建 的自激循环（表现：播放一直重连、画面乱飞）。
    // 400ms 内的重复重建请求丢掉，只保留第一次。
    const nowMs: number = Date.now();
    if (!forceSeek && nowMs - this.lastRebindAt < 400) {
      return;
    }
    this.lastRebindAt = nowMs;
    AppLog.mark('surface', `rebind force=${forceSeek} gen=${this.surfaceGen}`);
    if (this.pipActive || this.pipStarting) {
      // 画中画期间 surface 借给小窗了，重建会把 controller 换掉，直接放弃这次重建
      return;
    }
    if (forceSeek) {
      this.stopPip();
      this.surfaceGen = this.surfaceGen + 1;
    }
  }

  private cycleSpeed(): void {
    if (this.player === undefined) {
      return;
    }
    let index: number = SPEEDS.indexOf(this.speed);
    if (index < 0) {
      index = 1;
    }
    index = (index + 1) % SPEEDS.length;
    const next: number = SPEEDS[index];
    try {
      this.player.setSpeed(next);
      this.speed = next;
      this.toast(`倍速 ${next}x`);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] speed: ${e.code} ${e.message}`);
    }
  }

  private toggleSubs(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      const st: PlayerState | undefined = this.player.state;
      if (st === undefined || st === null) {
        this.toast('内核还没就绪');
        return;
      }
      const tracks = st.tracks;
      if (tracks === undefined || tracks === null) {
        this.toast('没有可选的轨道');
        return;
      }
      const rawSubs: SubtitleTrack[] = tracks.subs === undefined || tracks.subs === null ? [] : tracks.subs;
      // 过滤掉已挂进 mpv 的外挂 URI 轨道（isUri === true），防止本地/在线外挂字幕
      // 又在内嵌轨道里重复出现一条「external」，导致切换状态错乱。
      const subsList: SubtitleTrack[] = [];
      for (let i = 0; i < rawSubs.length; i++) {
        if (rawSubs[i].isUri !== true) {
          subsList.push(rawSubs[i]);
        }
      }
      const audioList: AudioTrack[] = tracks.audio === undefined || tracks.audio === null ? [] : tracks.audio;
      this.subTracks = subsList;
      this.audioTracks = audioList;
      const subs: string[] = [];
      const audios: string[] = [];
      for (let i = 0; i < subsList.length; i++) {
        subs.push(this.trackLabel(subsList[i].title, subsList[i].lang, i));
      }
      const activeAudioId: string = st.track !== undefined && st.track !== null
        && st.track.audio !== undefined && st.track.audio !== null ? st.track.audio.id : '';
      for (let i = 0; i < audioList.length; i++) {
        audios.push(this.trackLabel(audioList[i].title, audioList[i].lang, i));
        if (activeAudioId.length > 0 && audioList[i].id === activeAudioId) {
          this.currentAudioIndex = i;
        }
      }
      this.subLabels = subs;
      this.audioLabels = audios;
      this.panelKind = 'subs';
      this.loadSubSources();
      this.panelOpenedAt = Date.now();
      this.subPanelDown = false;
      this.subStyleOpen = false;
      this.showPanel = true;
      AppLog.mark('subpanel', `打开面板 字幕轨道=${subs.length} 音轨=${audios.length}`);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] tracks: ${e.code} ${e.message}`);
      this.toast('读轨道失败');
    }
  }


  /** 打开字幕面板时拉取来源，做去重合并；仅在本会话尚未手动选择时恢复上次选择。 */
  private async loadSubSources(): Promise<void> {
    if (this.metaId <= 0) {
      this.subHint = '没有拿到条目 id，无法查询字幕';
      return;
    }
    this.subBusy = true;
    try {
      const res = await SubtitleClient.list(this.metaId);
      const choiceId: string = res.choice !== undefined && res.choice !== null
        && res.choice.subtitle_id !== undefined && res.choice.subtitle_id !== null
        ? res.choice.subtitle_id : '';
      const activeId: string = this.currentSubId.length > 0 ? this.currentSubId : choiceId;
      const dedup = dedupSubtitles(
        res.local === undefined || res.local === null ? [] : res.local,
        res.cached === undefined || res.cached === null ? [] : res.cached,
        activeId
      );
      this.localSubs = dedup.local;
      this.extSubs = dedup.cached;
      this.subHint = res.hint === undefined || res.hint === null ? '' : res.hint;
      // 关键修复：只有在本会话尚未主动选过/关闭过字幕时才回填服务端 choice；
      // 以前每次打开面板都无条件 applySub(choice)，导致「关掉或切了别的字幕，一开面板又被强制切回本地字幕」。
      if (!this.subChosen && choiceId.length > 0 && this.currentSubId !== choiceId) {
        this.applySub(choiceId, false, false);
      }
      // 若当前选中的字幕已在 extSubs 中，清掉多余的 currentLocalName，避免两行同时高亮
      if (this.currentSubId.length > 0) {
        for (let i = 0; i < this.extSubs.length; i++) {
          if (this.extSubs[i].id === this.currentSubId) {
            this.currentLocalName = '';
            break;
          }
        }
      }
    } catch (error) {
      console.error(`[amane] subtitles: ${JSON.stringify(error)}`);
    } finally {
      this.subBusy = false;
    }
  }

  /**
   * 这次点击算不算数。
   *
   * `down` = 面板容器的 onTouch 有没有收到 Down（见字段注释）。两条判据任一成立即忽略：
   *  - 没收到 Down：按下的那一下落在别处（打开面板的那个按钮），抬手才滑到面板上；
   *  - 距面板打开不足 280ms：兜底，防个别机型 onTouch 派发顺序不同。
   */
  private panelTapAllowed(down: boolean, sinceOpen: number, label: string): boolean {
    const dt: number = Date.now() - sinceOpen;
    if (!down || (dt >= 0 && dt < 280)) {
      AppLog.mark('subpanel', `守卫拦下 ${label}（down=${down} since=${dt}ms）`);
      return false;
    }
    return true;
  }

  /** 字幕面板：本次点击是否有效。 */
  private subTapOk(label: string): boolean {
    return this.panelTapAllowed(this.subPanelDown, this.panelOpenedAt, label);
  }

  /** 字幕样式面板：本次点击是否有效（从字幕面板再开一层，单独计时）。 */
  private styleTapOk(label: string): boolean {
    return this.panelTapAllowed(this.stylePanelDown, this.subStyleOpenedAt, label);
  }

  /**
   * 把字幕样式写进 mpv。播放中改一项就调一次，mpv 下一帧就套用（不重开流）。
   *
   * 2.6.1.68 起的诊断：`sub-font-size` / `sub-pos` / `sub-border-size` 在 mpv 里是
   * **double** 类型，而 `setProperty` 的桥接层是按整型下发的 —— 写不进去时内核不一定
   * 抛异常，`catch` 也就什么都不打印，表现就是「面板里选了、画面一点没变」，查了很多轮
   * 都只能猜。现在写完立刻**回读一遍**，把「期望 / 实际」打进日志：
   *   `[substyle] 写入 ... 回读 sub-font-size=50 ...`
   * 一眼就能区分是「没写进 mpv」还是「写进去了但 libass 没用」。
   */
  private applySubStyle(): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      AppLog.mark('substyle', '跳过：内核还没建');
      return;
    }
    const lib = p.native;
    const spec: SubStyleSpec = SubStyle.spec();
    // 一项一段 try：某个属性在个别 mpv 版本上不可写时，其余几项仍要生效。
    // 默认值对齐 MIMK-091 的中文硬字幕（字号 50 / 描边 3 / 贴底且下边距 10 / 纯白无底）。
    const names: string[] = ['sub-font-size', 'sub-pos', 'sub-margin-y', 'sub-border-size',
      'sub-shadow-offset', 'sub-border-style', 'sub-back-color'];
    const vals: (number | string)[] = [spec.fontSize, spec.pos, spec.marginY, spec.outline,
      spec.shadow, spec.borderStyle, spec.backColor];
    const failed: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const val: number | string = vals[i];
      // 首选 `command(['set', ...])`：mpv 的 `set` 命令走**字符串解析**，自己按属性的
      // 真实类型（double / int / string）转换。`sub-font-size` / `sub-pos` /
      // `sub-border-size` 都是 double，直接用 setProperty 按整型下发会被内核拒掉，
      // 而且有些版本连异常都不抛 —— 这就是「面板选了、画面没变」的头号嫌疑。
      let ok: boolean = false;
      try {
        lib.command(['set', name, `${val}`]);
        ok = true;
      } catch (err) {
        ok = false;
      }
      if (!ok) {
        try {
          lib.setProperty(name, val);
          ok = true;
        } catch (err) {
          failed.push(name);
          console.info(`[amane] sub style ${name}: ${JSON.stringify(err)}`);
        }
      }
    }
    const back: string[] = [];
    for (let i = 0; i < names.length; i++) {
      let v: string = '?';
      try {
        v = lib.getPropertyString(names[i]);
      } catch (err) {
        v = '读不出';
      }
      back.push(`${names[i]}=${v}`);
    }
    let subInfo: string = '';
    try {
      const st: PlayerState | undefined = p.state;
      const tracks = st === undefined || st === null ? undefined : st.tracks;
      const subs = tracks === undefined || tracks === null ? undefined : tracks.subs;
      const n: number = subs === undefined || subs === null ? 0 : subs.length;
      subInfo = ` 轨道=${n} sid=${lib.getProperty('sid')}`;
    } catch (err) {
      subInfo = ' 轨道读不出';
    }
    AppLog.mark('substyle',
      `写入${failed.length === 0 ? '成功' : `失败[${failed.join(' ')}]`} 回读 ${back.join(' ')}${subInfo}`);
  }

  /** 所有来源统一走这里：一个 subtitle_id → 一条远程字幕轨道。
   *
   * `closePanel`：面板打开时异步回填「上次的选择」不能收面板，否则就是「面板闪关」。
   * `remember`：自动恢复不需要把同一个值写回服务端。
   * `localName`：仅从同目录直接切换时传入；切其它字幕时清空，避免旧本地字幕一直卡高亮。
   */
  private applySub(id: string, closePanel: boolean = true, remember: boolean = true,
    localName: string = ''): void {
    // 先收起面板：字幕加载与 mpv 解析都在后台，不该把用户卡在面板上
    if (closePanel) {
      this.showPanel = false;
    }
    this.currentSubId = id;
    this.currentLocalName = localName;
    // -999 而不是 -1：`PanelRow('不使用字幕', -1)` 用 index 比对勾选态，
    // 挂外挂字幕时把 -1 写进去会让「不使用字幕」自己打上勾（真机 2026-11-13 23:00 看到）。
    this.currentSubIndex = -999;
    this.subChosen = true;
    AppLog.mark('sub', `apply id=${id} close=${closePanel} remember=${remember} player=${this.player !== undefined}`);
    if (this.player === undefined) {
      return;
    }
    try {
      const lib = this.player.native;
      // 切换外挂字幕前先移除当前已挂的旧外挂轨并清空 sid，防止已有本地/外挂字幕时
      // mpv 仍停留在旧轨道、表现为「有本地字幕时切不动其它字幕」。
      try {
        lib.command(['sub-remove']);
      } catch (e) {
        // 当前若是内嵌轨或无外挂轨，sub-remove 会安全报错，忽略即可
      }
      try {
        lib.command(['set', 'sid', 'no']);
      } catch (e) {
        // 忽略
      }
      const url: string = SubtitleClient.streamUrl(id, true);
      this.player.setSubtitleTrack(SubtitleTrack.uri(url, '', 'chi', 'external'));
      AppLog.mark('sub', `setSubtitleTrack ok url=${url.substring(0, 72)}`);
      // 选了字幕就一定让它显示：以前可能因为上一部片把 sub-visibility 关了（或内核默认 no）
      // 出现「面板里勾上了、画面上没有」的情况，肉眼看着就像「没挂上」。
      try {
        lib.command(['set', 'sub-visibility', 'yes']);
        if (this.subDelay !== 0) {
          lib.command(['set', 'sub-delay', `${this.subDelay}`]);
        }
      } catch (err) {
        console.info(`[amane] sub visibility: ${JSON.stringify(err)}`);
      }
      // 挂载是异步的：800ms 后回读 sid，-1/0 就说明 mpv 根本没接这条轨道
      setTimeout(() => {
        this.reportSubState('after-apply');
      }, 800);
      if (remember) {
        SubtitleClient.remember(this.metaId, id).catch(() => {
          // 记住失败不影响播放
        });
      }
      this.toast('已切换字幕');
    } catch (error) {
      console.error(`[amane] apply sub: ${JSON.stringify(error)}`);
      AppLog.mark('sub', `apply 抛异常 ${JSON.stringify(error)}`);
      this.toast('加载字幕失败');
    }
  }

  /** 诊断：把「mpv 现在到底挂了哪条字幕」打进日志（sid / 轨道数 / 可见性）。 */
  private reportSubState(tag: string): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      const lib = p.native;
      const st: PlayerState | undefined = p.state;
      const tracks = st === undefined || st === null ? undefined : st.tracks;
      const subs = tracks === undefined || tracks === null ? undefined : tracks.subs;
      const n: number = subs === undefined || subs === null ? 0 : subs.length;
      let labels: string = '';
      if (n > 0 && subs !== undefined && subs !== null) {
        for (let i = 0; i < n && i < 4; i++) {
          labels += `[${i}]${subs[i].title}/${subs[i].lang}/${subs[i].isUri === true ? 'uri' : 'in'} `;
        }
      }
      let vis: string = '?';
      try {
        vis = lib.getPropertyString('sub-visibility');
      } catch (err) {
        vis = '读不出';
      }
      AppLog.mark('sub', `${tag}: 轨道=${n} sid=${lib.getProperty('sid')} vis=${vis} ${labels}`);
    } catch (err) {
      AppLog.mark('sub', `${tag}: 读轨道失败 ${JSON.stringify(err)}`);
    }
  }

  /** 打开播放后就恢复上次选的字幕（2.6.1.7），不用再让用户去面板点一下。 */
  private async restoreSubChoice(): Promise<void> {
    if (this.subRestored || this.subChosen || this.metaId <= 0) {
      return;
    }
    this.subRestored = true;
    try {
      const ch: SubtitleChoice = await SubtitleClient.choice(this.metaId);
      if (ch !== undefined && ch !== null && ch.subtitle_id !== undefined
        && ch.subtitle_id !== null && ch.subtitle_id.length > 0 && !this.subChosen) {
        this.applySub(ch.subtitle_id, false, false);
      }
    } catch (error) {
      console.error(`[amane] restore sub: ${JSON.stringify(error)}`);
    }
  }

  private async useLocalSub(name: string): Promise<void> {
    // 同为面板行点击：刚打开的那一下不认（否则面板「点开即关」）
    if (!this.subTapOk(`本地字幕 ${name}`)) {
      return;
    }
    this.showPanel = false;
    try {
      const item: SubtitleItem = await SubtitleClient.loadLocal(this.metaId, name);
      this.applySub(item.id, true, true, name);
    } catch (error) {
      console.error(`[amane] local sub: ${JSON.stringify(error)}`);
      this.toast('读取同目录字幕失败');
    }
  }

  private async importSub(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const item: SubtitleItem = await SubtitleClient.importFromPhone(ctx, this.metaId);
      this.applySub(item.id);
    } catch (error) {
      console.error(`[amane] import sub: ${JSON.stringify(error)}`);
      this.toast('导入字幕失败');
    }
  }

  private async addSubUrl(): Promise<void> {
    const raw: string = this.subUrlInput.trim();
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      this.toast('请填写 http(s) 字幕地址');
      return;
    }
    try {
      const item: SubtitleItem = await SubtitleClient.addUrl(raw, this.metaId);
      this.subUrlInput = '';
      this.applySub(item.id);
    } catch (error) {
      console.error(`[amane] url sub: ${JSON.stringify(error)}`);
      this.toast('抓取字幕失败');
    }
  }

  private trackLabel(title: string, lang: string, index: number): string {
    if (title !== undefined && title !== null && title.length > 0) {
      return title;
    }
    if (lang !== undefined && lang !== null && lang.length > 0) {
      return `轨道 ${lang}`;
    }
    return `轨道 ${index + 1}`;
  }

  private pickSub(index: number): void {
    // 面板刚打开的短窗内忽略：那次点击的抬手会落到第一行上（不然面板「点开即关」）
    if (!this.subTapOk(`pickSub(${index})`)) {
      return;
    }
    this.showPanel = false;
    this.currentSubIndex = index;
    this.currentSubId = '';
    this.currentLocalName = '';
    this.subChosen = true;
    // 清掉服务端记住的外挂字幕 choice：用户明确切到「不使用」或「内嵌轨」，
    // 下次重开面板/影片时不再被旧的本地/外挂字幕强制覆写。
    if (this.metaId > 0) {
      SubtitleClient.remember(this.metaId, '').catch(() => {
      });
    }
    if (this.player === undefined) {
      return;
    }
    try {
      const lib = this.player.native;
      // 先卸载此前挂载的外挂/本地轨道，避免有本地字幕时切内嵌或关闭不生效
      try {
        lib.command(['sub-remove']);
      } catch (e) {
        // 忽略
      }
      if (index < 0) {
        this.player.disableSubtitleTrack();
        try {
          lib.command(['set', 'sid', 'no']);
          lib.command(['set', 'sub-visibility', 'no']);
        } catch (e) {
          // 忽略
        }
      } else if (index < this.subTracks.length) {
        this.player.setSubtitleTrack(this.subTracks[index]);
        try {
          lib.command(['set', 'sub-visibility', 'yes']);
          if (this.subDelay !== 0) {
            lib.command(['set', 'sub-delay', `${this.subDelay}`]);
          }
        } catch (e) {
          // 忽略
        }
      }
      this.toast(index < 0 ? '已关闭字幕' : '已切换字幕');
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] pick sub: ${e.code} ${e.message}`);
      this.toast('切换字幕失败');
    }
    this.showPanel = false;
  }

  private pickAudio(index: number): void {
    // 同上：面板刚开的那一下不认
    if (!this.subTapOk(`pickAudio(${index})`)) {
      return;
    }
    if (this.player === undefined) {
      return;
    }
    try {
      if (index >= 0 && index < this.audioTracks.length) {
        this.player.setAudioTrack(this.audioTracks[index]);
        this.currentAudioIndex = index;
        this.toast('已切换音轨');
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] pick audio: ${e.code} ${e.message}`);
    }
    this.showPanel = false;
  }

  private applyVolume(value: number): void {
    if (this.player === undefined) {
      return;
    }
    try {
      this.player.setVolume(value);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] volume: ${e.code} ${e.message}`);
    }
  }

  private toast(text: string): void {
    this.hint = text;
    setTimeout(() => {
      if (this.hint === text) {
        this.hint = '';
      }
    }, 1200);
  }

  /** 一眼分辨「请求没成功」和「带宽不够」：码率长期高于链路能力就会反复缓冲。 */
  private diagnostics(): string {
    const state: string = this.buffering ? '缓冲' : (this.playing ? '播放' : '等待');
    const rate: string = this.bitrate > 0 ? (this.bitrate / 1000000).toFixed(1) : '--';
    const cache: string = this.cacheSec > 0 ? `${this.cacheSec.toFixed(1)}s` : `${Math.round(this.bufPct)}%`;
    return `${state} · ${rate}M · 缓存${cache}`;
  }

  /**
   * 回读 mpv 真正生效的缓存参数，对不上就现改一次。
   *
   * 用户报「设置没生效」时很难从外部验证，这里把 mpv.conf 是否被读到、
   * 有没有被旧版本写脏一次性打成一行日志；顺带自愈（setProperty 立即生效）。
   */
  private verifyTuning(t: PlayerTuning): void {
    if (this.player === undefined || this.player === null) {
      return;
    }
    // 内核就绪 = 可以写属性了：把字幕样式（字号/描边/位置/背景）套一遍。
    // 这一步必须在 onReady 里做，太早写入会被 mpv 忽略（和上面缓存参数同一个道理）。
    this.applySubStyle();
    let line: string = '';
    try {
      const lib = this.player.native;
      const maxBytes: number = t.maxMiB * 1024 * 1024;
      const backBytes: number = t.backMiB * 1024 * 1024;
      const keys: string[] = ['demuxer-max-bytes', 'demuxer-max-back-bytes',
        'demuxer-readahead-secs', 'cache-pause-wait'];
      const wants: number[] = [maxBytes, backBytes, t.readahead, t.pauseWait];
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        const want: number = wants[i];
        let actual: number = -1;
        try {
          actual = lib.getProperty(key);
        } catch (e) {
          actual = -1;
        }
        line += `${key}=${actual}`;
        if (!(actual > 0) || Math.abs(actual - want) > Math.max(0.02, want * 0.02)) {
          try {
            lib.setProperty(key, want);
            line += `→${want}`;
          } catch (e) {
            line += '→改不动';
          }
        }
        line += ' ';
      }
      // 起播优先那个开关到底进没进内核（2.6.1.81）：只看 mpv.conf 里的文字不算数，
      // 老设备可能整份没被读取。这里回读真实值 —— 之前「起播优先」没验过，就是缺这一行。
      try {
        line += `cache-pause-initial=${lib.getPropertyString('cache-pause-initial')}`;
      } catch (e) {
        line += 'cache-pause-initial=?';
      }
      console.info(`[amane] mpv 生效参数: ${line}`);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] verify tuning: ${e.code} ${e.message}`);
    }
  }

  /** 外网链路余量小：码率超过警戒值给一条可操作提示，不阻断播放。 */
  private bandwidthText(): string {
    if (!this.bandwidthWarn || this.bitrate <= 0) {
      return '';
    }
    const mbps: number = this.bitrate / 1000000;
    return `外网约 10~17 Mbps，当前片源 ${mbps.toFixed(1)} Mbps 余量偏小，可能反复缓冲；回家切局域网更稳。`;
  }

  /** 读我的评分：已经打过就不弹提示。 */
  private async loadMyRating(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/ratings/${this.metaId}`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.myRating = Math.trunc(Number(obj.score) || 0);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] my rating: ${e.code} ${e.message}`);
    }
  }

  private async submitRate(score: number): Promise<void> {
    if (this.rateBusy || this.metaId <= 0) {
      return;
    }
    this.rateBusy = true;
    try {
      await rateFilm(this.metaId, score);
      this.myRating = score;
      this.showRateCard = false;
      this.toast('已打分');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] rate: ${e.code} ${e.message}`);
      this.toast('打分失败');
    }
    this.rateBusy = false;
  }

  private seekPreviewLabel(): string {
    const value: number = this.seekPreview >= 0 ? this.seekPreview : this.pos;
    return `${clock(value)} / ${clock(this.duration)}`;
  }

  /** 拖拽快进相对位移（例：`+05:40` / `-00:32`）。 */
  private seekDeltaText(): string {
    if (this.seekPreview < 0) {
      return '';
    }
    const diff: number = Math.round(this.seekPreview - this.panStartPos);
    const sign: string = diff >= 0 ? '+' : '-';
    return `${sign}${clock(Math.abs(diff))}`;
  }

  /** 字幕时间偏移文案（例：`+0.5s` / `-1.0s` / `0.0s`）。 */
  private subDelayText(): string {
    if (Math.abs(this.subDelay) < 0.05) {
      return '0.0s';
    }
    return `${this.subDelay > 0 ? '+' : ''}${this.subDelay.toFixed(1)}s`;
  }

  /** 字幕样式预览条：按当前字号/描边/位置/背景映射实时预览样式。 */
  private subPreviewFontSize(): number {
    return Math.max(11, Math.min(20, Math.round(14 * this.subSizePct / 100)));
  }

  private subPreviewAlign(): Alignment {
    if (this.subPosPct <= 85) {
      return Alignment.Top;
    }
    if (this.subPosPct <= 95) {
      return Alignment.Center;
    }
    return Alignment.Bottom;
  }

  private subPreviewBgColor(): string {
    if (this.subBgMode === 2) {
      return '#E6000000';
    }
    if (this.subBgMode === 1) {
      return '#8C000000';
    }
    return '#00000000';
  }

  build() {
    // 外层只管「把两层摞起来」：播放器固定在顶部，详情抽屉从下往上滑。
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 播放器层（竖屏：固定顶部 16:9；全屏：铺满） ----------
      Stack({ alignContent: Alignment.Center }) {
      // 视频铺满，控件浮在上面（顶部胶囊 + 底部面板，见 view/PlayerChrome）
      if (this.surfaceReady && this.player !== undefined) {
        // 自建 XComponent（替代 PlayerSurface）：画中画要 controller。
        // 形态切换（16:9 ↔ 全屏 ↔ 横屏）时用 ForEach 的 key 换一代：组件重建 →
        // onLoad 拿到**新的** surfaceId 重新 attach，mpv 才会按新尺寸出帧。
        // 之前是 detach + attach 同一块 surface，经常 attach 不回来，画面直接黑掉。
        ForEach([this.surfaceGen], (gen: number) => {
          XComponent({
            id: `amane_mpv_${gen}`,
            type: XComponentType.SURFACE,
            controller: this.xc
          })
            .onLoad(() => {
              const p: Player | undefined = this.player;
              if (p === undefined) {
                return;
              }
              try {
                const sid: string = this.xc.getXComponentSurfaceId();
                p.native.attachSurface(sid);
                this.attachAt = Date.now();
                this.preparePip();
                AppLog.mark('surface', `onLoad gen=${gen} attach sid=${sid.substring(0, 6)} pos=${this.pos.toFixed(1)} sinceOpen=${this.openAt > 0 ? Date.now() - this.openAt : -1}ms`);
                // 换 surface 后重新定位一帧，逼 mpv 按新 viewport 出画面
                if (this.pos > 0.5) {
                  AppLog.mark('surface', `resume seek -> ${this.pos.toFixed(1)}`);
                  p.seek(this.pos);
                }
              } catch (err) {
                const e = err as BusinessError;
                console.error(`[amane] attach surface: ${e.code} ${e.message}`);
              }
            })
            // 注意：这里**不要** detachSurface —— 旧组件销毁时新组件可能已经
            // attach 好了，再 detach 一次会把新 surface 摘掉（又黑屏）。
            .width('100%')
            .height('100%')
        }, (gen: number) => `xc-${gen}`)
      }
      // 首帧之前盖着海报：从「详情页那张图」平滑接过来，不闪黑
      if (!this.firstFrame && this.posterParam.length > 0) {
        Image(Store.I.img(this.posterParam))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .backgroundColor('#000000')
          .hitTestBehavior(HitTestMode.None)
      }

      // 手势层（第 8 条）：**只盖住画面区**，不盖底部控件条。
      // 之前手势挂在整块 Stack 上，拖进度条时父级的横向 Pan 会抢走触摸，
      // 于是 slider 不跟着手指走、一点点位移被换算成几百秒，表现成「直接跳到最前/最后」。
      Column()
        .width('100%')
        .height(this.gestureH())
        .position({ x: 0, y: 0 })
        .backgroundColor('#00000000')
        .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 1 })
            .onAction(() => {
              if (this.screenLocked) {
                this.flashLockUi();
                return;
              }
              // 收缩态点画面 = 展开回 16:9；正常态 = 显隐控件
              if (this.shrunken()) {
                this.toggleSheet();
              } else {
                this.showControls = !this.showControls;
              }
            }),
          TapGesture({ count: 2 })
            .onAction(() => {
              if (this.screenLocked) {
                this.flashLockUi();
                return;
              }
              this.togglePlay();
              this.toast(this.playing ? '播放' : '暂停');
            }),
          // 长按整屏 = 临时 3 倍速（R11）：触发点是整块画面，不是那个小胶囊
          LongPressGesture({ repeat: false, duration: 420 })
            .onAction(() => {
              if (this.screenLocked) {
                return;
              }
              this.tempSpeed(true);
            })
            .onActionEnd(() => {
              this.tempSpeed(false);
            }),
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart((event: GestureEvent) => {
              if (this.screenLocked || this.duration <= 0) {
                this.panKind = '';
                return;
              }
              const w: number = Math.max(1, this.gestureW());
              const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : w / 2;
              // 避开左右系统返回手势边缘 24vp
              if (x < 24 || x > w - 24) {
                this.panKind = '';
                return;
              }
              this.panKind = 'seek';
              this.panStartPos = this.pos;
              this.seekPreview = this.pos;
              this.seekCancel = false;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.panKind === 'seek') {
                const w: number = Math.max(300, this.gestureW());
                const span: number = Math.min(this.duration, Math.min(Math.max(this.duration * 0.25, 90), 240));
                const delta: number = (event.offsetX / w) * span;
                this.seekPreview = Math.max(0, Math.min(this.duration, this.panStartPos + delta));
                // 上滑超过 56vp 取消本次跳转，滑回来恢复
                if (event.offsetY < -56) {
                  this.seekCancel = true;
                } else if (event.offsetY > -40) {
                  this.seekCancel = false;
                }
              }
            })
            .onActionEnd(() => {
              if (this.panKind === 'seek' && this.seekPreview >= 0) {
                if (this.seekCancel) {
                  this.toast('已取消跳转');
                } else {
                  this.seekTo(this.seekPreview);
                }
              }
              this.panKind = '';
              this.seekPreview = -1;
              this.seekCancel = false;
            }),
          PanGesture({ direction: PanDirection.Vertical })
            .onActionStart((event: GestureEvent) => {
              if (this.screenLocked) {
                this.panKind = '';
                return;
              }
              const w: number = Math.max(1, this.gestureW());
              const x: number = event.fingerList.length > 0
                ? Math.max(0, Math.min(w, event.fingerList[0].localX)) : w / 2;
              const y: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 60;
              // 避开左右边缘 24vp 及顶边 20vp（防与系统通知栏/返回手势冲突）
              if (x < 24 || x > w - 24 || y < 20) {
                this.panKind = '';
                return;
              }
              if (x > w / 2) {
                this.panKind = 'volume';
                this.hudKind = 'volume';
                this.panBase = this.volume;
              } else {
                this.panKind = 'bright';
                this.hudKind = 'bright';
                this.panBase = this.readCurrentBrightness() * 100;
              }
              this.panSide = x > w / 2 ? 'right' : 'left';
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.panKind !== 'volume' && this.panKind !== 'bright') {
                return;
              }
              // 10vp 死区 + 高度归一化灵敏度（有效行程 ≥ 220vp 对应 0→100%），
              // 彻底修复「轻轻一划直接从 0 拉到 100」的过快问题。
              const rawY: number = event.offsetY;
              if (Math.abs(rawY) < 10) {
                return;
              }
              const effY: number = rawY > 0 ? rawY - 10 : rawY + 10;
              const span: number = Math.max(220, this.gestureH() * 0.72);
              const delta: number = (-effY / span) * 100;
              if (this.panKind === 'volume') {
                this.volume = Math.max(0, Math.min(100, this.panBase + delta));
                this.applyVolume(this.volume);
                this.volumeHint = Math.round(this.volume);
              } else if (this.panKind === 'bright') {
                const nextBright: number = Math.max(0.02, Math.min(1.0, (this.panBase + delta) / 100));
                this.setBrightnessThrottled(nextBright, false);
                this.volumeHint = Math.round(this.bright * 100);
              }
            })
            .onActionEnd(() => {
              if (this.panKind === 'bright') {
                this.setBrightnessThrottled(this.bright, true);
              }
              this.panKind = '';
              this.hudKind = '';
              this.volumeHint = -1;
            })
        )
        )

      // 控件层：顶部悬浮胶囊 + 底部悬浮面板（view/PlayerChrome，纯 ArkUI）
      if (this.showControls || (this.screenLocked && this.lockUiShown)
        || (this.viewMode === 'portrait' && this.shrunken())) {
        PlayerChrome({
          number: this.metaNumber,
          title: this.metaTitle,
          fileName: this.fileName,
          onAir: Store.I.onWan,
          speed: this.speed,
          playing: this.playing,
          pos: this.pos,
          duration: this.duration,
          seekPreview: this.seekPreview,
          volume: this.volume,
          diagnostics: this.diagnostics(),
          bandwidthText: this.bandwidthText(),
          seekStep: this.seekStep,
          layout: this.viewMode === 'portrait' ? 'compact' : this.viewMode,
          collapsed: this.collapsedChrome(),
          locked: this.screenLocked,
          aspectMode: this.aspectMode,
          onBack: () => {
            this.onExited();
          },
          onPlayPause: () => {
            this.togglePlay();
          },
          onSeekBy: (delta: number) => {
            this.seekBy(delta);
          },
          onTempSpeed: (on: boolean) => {
            this.tempSpeed(on);
          },
          onSpeed: () => {
            this.cycleSpeed();
          },
          onPickSpeed: (v: number) => {
            this.applySpeed(v);
          },
          onPickAspect: (mode: string) => {
            this.applyAspectMode(mode);
          },
          onToggleLock: () => {
            this.toggleScreenLock();
          },
          onSnap: () => {
            this.snapFrame();
          },
          onPicker: () => {
            this.openPicker();
          },
          onAnno: () => {
            this.openAnnoInput();
          },
          onPip: () => {
            if (PlaySession.handoff !== undefined) {
              PlaySession.handoff();
            } else {
              this.startPip();
            }
          },
          onToggleFull: () => {
            this.toggleFull();
          },
          onLandscape: () => {
            this.toLandscape();
          },
          tempSpeed: this.tempSpeedValue,
          pipActive: this.pipActive,
          onSeekMoving: (value: number) => {
            this.seekPreview = value;
            this.panStartPos = this.pos;
            this.seekCancel = false;
          },
          onSeekEnd: (value: number) => {
            this.seekTo(value);
            this.seekPreview = -1;
            this.seekCancel = false;
          },
          onSubs: () => {
            this.toggleSubs();
          },
          onAudio: () => {
            this.panelKind = 'audio';
            this.toggleSubs();
            this.panelKind = 'audio';
          },
          onMute: () => {
            this.volume = this.volume > 0 ? 0 : 100;
            this.applyVolume(this.volume);
            this.toast(this.volume > 0 ? `音量 ${this.volume}%` : '已静音');
          }
        })
      }

      // 弹幕层（B 站式）：从右往左飞，按轨道排，不吃触摸。
      if (this.danmuOn && this.live.length > 0 && !this.shrunken()) {
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.live, (d: DanmuLive) => {
            DanmuItem({ item: d, alpha: this.danmuAlpha })
          }, (d: DanmuLive) => `dm-${d.id}`)
        }
        .width('100%')
        .height('100%')
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
      }

      // 顶部悬浮长按倍速 HUD 胶囊（Mockup 3 右下）
      if (this.tempSpeedActive) {
        Column() {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.fast_forward'))
              .fontSize(15)
              .fontColor([Theme.ACCENT_INK])
            Text(`${this.tempSpeedValue.toFixed(1)}x 倍速播放中`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .fontFeature('"tnum" 1')
          }
          .padding({ left: 15, right: 15, top: 8, bottom: 8 })
          .backgroundColor('#C4141016')
          .backdropBlur(24)
          .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
          .borderRadius(20)
          .shadow({ radius: 18, color: Theme.accentAlpha(0.32), offsetY: 4 })
          .margin({ top: this.viewMode === 'portrait' ? 12 : 22 })
          Blank()
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }

      // 中央悬浮液态玻璃 HUD（Mockup 3：快进预览+上滑取消 / 亮度音量条 / 轻提示）
      if (this.seekPreview >= 0) {
        Column({ space: 6 }) {
          if (this.prevOk && !this.shrunken()) {
            // ★ alignContent 必须是 TopStart，否则雪碧图偏到中间 ★
            Stack({ alignContent: Alignment.TopStart }) {
              Image(Store.I.img(this.prevUrl))
                .width(this.prevCols * 128)
                .height(this.prevRows * 72)
                .objectFit(ImageFit.Fill)
                .offset({
                  x: this.previewX(),
                  y: this.previewY()
                })
            }
            .width(128)
            .height(72)
            .clip(true)
            .borderRadius(9)
            .backgroundColor('#000000')
            .border({
              width: 0.75,
              color: this.seekCancel ? '#80FF6B81' : Theme.accentAlpha(0.55)
            })
          }
          Row({ space: 8 }) {
            Text(clock(this.seekPreview))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .fontFeature('"tnum" 1')
            if (this.panKind === 'seek') {
              Text(this.seekDeltaText())
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.seekCancel ? '#FF8FA0' : Theme.ACCENT_INK)
                .fontFeature('"tnum" 1')
            } else {
              Text(`/ ${clock(this.duration)}`)
                .fontSize(12)
                .fontColor('#99FFFFFF')
                .fontFeature('"tnum" 1')
            }
          }
          if (this.panKind === 'seek') {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.chevron_up'))
                .fontSize(10)
                .fontColor([this.seekCancel ? '#FF8FA0' : '#B3FFFFFF'])
              Text(this.seekCancel ? '松手取消跳转' : '上滑取消')
                .fontSize(10)
                .fontColor(this.seekCancel ? '#FF8FA0' : '#B3FFFFFF')
            }
          }
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor('#CC141016')
        .backdropBlur(26)
        .border({ width: 0.75, color: this.seekCancel ? '#80FF6B81' : '#33FFFFFF' })
        .borderRadius(16)
        .shadow({ radius: 22, color: '#80000000', offsetY: 6 })
        .hitTestBehavior(HitTestMode.None)
      } else if (this.volumeHint >= 0) {
        // 亮度 / 音量液态玻璃条（Mockup 3 左下）
        Row({ space: 10 }) {
          SymbolGlyph(this.hudKind === 'bright'
            ? $r('sys.symbol.sun_max')
            : (this.volumeHint === 0 ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2')))
            .fontSize(18)
            .fontColor([Theme.ACCENT_INK])
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width(114)
              .height(4)
              .borderRadius(2)
              .backgroundColor('#33FFFFFF')
            Row()
              .width(Math.max(4, Math.round(114 * Math.max(0, Math.min(100, this.volumeHint)) / 100)))
              .height(4)
              .borderRadius(2)
              .linearGradient(Theme.ctaGradient())
          }
          .width(114)
          .height(6)
          Text(`${this.volumeHint}%`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .fontFeature('"tnum" 1')
            .width(36)
            .textAlign(TextAlign.End)
        }
        .padding({ left: 15, right: 15, top: 10, bottom: 10 })
        .backgroundColor('#CC141016')
        .backdropBlur(26)
        .border({ width: 0.75, color: '#33FFFFFF' })
        .borderRadius(22)
        .shadow({ radius: 20, color: '#80000000', offsetY: 6 })
        .hitTestBehavior(HitTestMode.None)
      } else if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#CC141016')
          .backdropBlur(24)
          .border({ width: 0.75, color: '#2EFFFFFF' })
          .borderRadius(18)
          .shadow({ radius: 16, color: '#66000000', offsetY: 4 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 收缩态：只留一行时间 + 「点一下展开」，画面本身还在播
      if (this.shrunken()) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Column()
              .width(3)
              .height(9)
              .backgroundColor('#E6FFFFFF')
            Column()
              .width(3)
              .height(9)
              .backgroundColor('#E6FFFFFF')
            Text(`${clock(this.pos)} / ${clock(this.duration)}`)
              .fontSize(9)
              .fontColor('#E6FFFFFF')
          }
          .alignItems(VerticalAlign.Center)

          Text('点画面展开')
            .fontSize(8)
            .fontColor('#8CFFFFFF')
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.showBufferOverlay) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color('#FFFFFF')
          Text(this.diagnostics())
            .fontSize(11)
            .fontColor('#B3FFFFFF')
        }
      }

      // 画中画占位（Mockup 1 中：居中黑曜石玻璃卡 + 蔷薇渐变主按钮）
      if (this.pipActive) {
        Column() {
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
                  .fontSize(20)
                  .fontColor([Theme.ACCENT_INK])
              }
              .width(42)
              .height(42)
              .borderRadius(13)
              .backgroundColor(Theme.accentAlpha(0.18))
              .border({ width: 0.75, color: Theme.accentAlpha(0.48) })

              Column({ space: 3 }) {
                Text('正在画中画播放')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                Text('视频已在系统小窗中继续播放')
                  .fontSize(11)
                  .fontColor('#99FFFFFF')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Row({ space: 10 }) {
              Text('回到播放页')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ON_ACCENT)
                .layoutWeight(1)
                .height(36)
                .textAlign(TextAlign.Center)
                .linearGradient(Theme.ctaGradient())
                .borderRadius(18)
                .shadow({ radius: 14, color: Theme.accentAlpha(0.35), offsetY: 3 })
                .onClick(() => {
                  this.restoreFromPip();
                })
              Text('关闭小窗')
                .fontSize(12)
                .fontColor('#E6FFFFFF')
                .layoutWeight(1)
                .height(36)
                .textAlign(TextAlign.Center)
                .backgroundColor('#24FFFFFF')
                .border({ width: 0.75, color: '#33FFFFFF' })
                .borderRadius(18)
                .onClick(() => {
                  this.stopPip();
                  this.onPipClosed();
                })
            }
            .width('100%')
          }
          .width('86%')
          .constraintSize({ maxWidth: 320 })
          .padding(16)
          .backgroundColor('#D9141016')
          .backdropBlur(24)
          .border({ width: 0.75, color: '#2EFFFFFF' })
          .borderRadius(20)
          .shadow({ radius: 24, color: '#80000000', offsetY: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#E60B090D')
      }
      }
      .width('100%')
      .height(this.viewMode === 'portrait' ? this.videoH() : '100%')
      .position({ x: 0, y: 0 })
      .backgroundColor('#000000')

      if (this.errorText.length > 0) {
        Column({ space: 10 }) {
          Text('播放失败')
            .fontSize(15)
            .fontColor('#FFFFFF')
          Text(this.errorText)
            .fontSize(11)
            .fontColor('#B3FFFFFF')
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 40, right: 40 })
            .textAlign(TextAlign.Center)
          Row({ space: 10 }) {
            Button('重试')
              .height(36)
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                this.errorText = '';
                this.openMedia();
              })
            Button('返回')
              .height(36)
              .backgroundColor('#33FFFFFF')
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                router.back();
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#B3000000')
      }

      // 发弹幕悬浮液态玻璃条（Mockup 2 右下）
      if (this.showAnnoInput) {
        Column() {
          Blank()
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text(clock(this.pos))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ACCENT_INK)
                .fontFeature('"tnum" 1')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(Theme.accentAlpha(0.18))
                .border({ width: 0.75, color: Theme.accentAlpha(0.45) })
                .borderRadius(12)

              TextInput({ text: this.annoDraft, placeholder: '发一条弹幕记录此刻…' })
                .layoutWeight(1)
                .height(36)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .placeholderColor('#80FFFFFF')
                .backgroundColor('#1FFFFFFF')
                .border({ width: 0.6, color: '#2EFFFFFF' })
                .borderRadius(14)
                .onChange((v: string) => {
                  this.annoDraft = v;
                })
                .onSubmit(() => {
                  this.addAnnotation();
                })

              Row({ space: 6 }) {
                ForEach(['#FFFFFF', '#FFD166', '#FF7597', '#67E8F9'], (col: string, idx: number) => {
                  Column()
                    .width(15)
                    .height(15)
                    .borderRadius(8)
                    .backgroundColor(col)
                    .border({
                      width: this.annoColorIdx === idx ? 1.5 : 0.5,
                      color: this.annoColorIdx === idx ? Theme.ACCENT_INK : '#4DFFFFFF'
                    })
                    .onClick(() => {
                      this.annoColorIdx = idx;
                    })
                }, (col: string) => `ac-${col}`)
              }

              Text(this.annoBusy ? '发送中' : '发送')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ON_ACCENT)
                .padding({ left: 14, right: 14 })
                .height(34)
                .textAlign(TextAlign.Center)
                .linearGradient(Theme.ctaGradient())
                .borderRadius(17)
                .opacity(this.annoBusy ? 0.5 : 1)
                .onClick(() => {
                  if (!this.annoBusy) {
                    this.addAnnotation();
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width(this.viewMode === 'portrait' ? '95%' : '76%')
          .constraintSize({ maxWidth: 620 })
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor('#D9141016')
          .backdropBlur(28)
          .border({ width: 0.75, color: '#33FFFFFF' })
          .borderRadius(22)
          .shadow({ radius: 24, color: '#80000000', offsetY: 8 })
          .margin({ bottom: this.viewMode === 'portrait' ? 10 : 18 })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showAnnoInput = false;
        })
      }

      // 选集面板（Mockup 2 右下：丝绒双 Tab + 海报同系列）
      if (this.showPicker) {
        Column() {
          Blank()
          Column({ space: 10 }) {
            Row() {
              Text('选集')
                .fontSize(15)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Bold)
              Blank()
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor(['#B3FFFFFF'])
              }
              .width(26)
              .height(26)
              .borderRadius(13)
              .backgroundColor('#1FFFFFFF')
              .onClick(() => {
                this.showPicker = false;
              })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 14 })

            // 丝绒双 Tab 分段胶囊
            Row({ space: 6 }) {
              Text(`${this.versions.length} 个版本`)
                .fontSize(12)
                .fontWeight(this.pickerTab === 'version' ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.pickerTab === 'version' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                .layoutWeight(1)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.pickerTab === 'version' ? Theme.accentAlpha(0.22) : '#00000000')
                .border({
                  width: this.pickerTab === 'version' ? 0.75 : 0,
                  color: Theme.accentAlpha(0.55)
                })
                .borderRadius(14)
                .onClick(() => {
                  this.pickerTab = 'version';
                })
              Text(this.sibName.length > 0
                ? `${this.sibName} (${this.siblings.length})`
                : `同系列 (${this.siblings.length})`)
                .fontSize(12)
                .fontWeight(this.pickerTab === 'series' ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.pickerTab === 'series' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                .layoutWeight(1)
                .height(32)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .backgroundColor(this.pickerTab === 'series' ? Theme.accentAlpha(0.22) : '#00000000')
                .border({
                  width: this.pickerTab === 'series' ? 0.75 : 0,
                  color: Theme.accentAlpha(0.55)
                })
                .borderRadius(14)
                .onClick(() => {
                  this.pickerTab = 'series';
                })
            }
            .width('100%')
            .padding(3)
            .backgroundColor('#1AFFFFFF')
            .border({ width: 0.6, color: '#24FFFFFF' })
            .borderRadius(17)
            .margin({ left: 14, right: 14 })

            if (this.pickerLoading) {
              Text('读取中…')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ left: 16, top: 4, bottom: 8 })
            }

            Scroll() {
              if (this.pickerTab === 'version') {
                Column({ space: 4 }) {
                  ForEach(this.versionOnly(), (v: VerItem) => {
                    this.VerRow(v)
                  }, (v: VerItem) => `ver-${v.key}`)
                  if (this.partOnly().length > 0) {
                    Row() {
                      Text(`分集 · ${partsHint(this.partOnly().length)}`)
                        .fontSize(10)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width('100%')
                    .padding({ left: 10, right: 10, top: 8, bottom: 2 })

                    ForEach(this.partOnly(), (v: VerItem) => {
                      this.VerRow(v)
                    }, (v: VerItem) => `part-${v.key}`)
                  }
                }
                .width('100%')
                .padding({ left: 10, right: 10 })
              } else {
                Column({ space: 4 }) {
                  ForEach(this.siblings, (s: SibItem) => {
                    Row({ space: 10 }) {
                      Image(Store.I.img(s.poster))
                        .width(38)
                        .height(52)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(7)
                        .backgroundColor(Theme.CARD)
                      Column({ space: 3 }) {
                        Text(s.number)
                          .fontSize(12)
                          .fontWeight(s.current ? FontWeight.Medium : FontWeight.Normal)
                          .fontColor(s.current ? Theme.ACCENT_INK : Theme.TEXT)
                          .maxLines(1)
                          .width('100%')
                        Text(s.actors.length > 0 ? s.actors.join(' · ') : s.title)
                          .fontSize(10)
                          .fontColor(Theme.TEXT_FAINT)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (s.current) {
                        Text('当前')
                          .fontSize(9)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(Theme.ACCENT_INK)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .backgroundColor(Theme.accentAlpha(0.20))
                          .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
                          .borderRadius(9)
                      } else {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(12)
                          .fontColor(['#66FFFFFF'])
                      }
                    }
                    .width('100%')
                    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                    .borderRadius(12)
                    .backgroundColor(s.current ? Theme.accentAlpha(0.14) : '#00000000')
                    .border({
                      width: s.current ? 0.75 : 0,
                      color: Theme.accentAlpha(0.42)
                    })
                    .onClick(() => {
                      this.pickSibling(s);
                    })
                  }, (s: SibItem) => `sib-${s.id}`)
                }
                .width('100%')
                .padding({ left: 10, right: 10 })
              }
            }
            .layoutWeight(1)
            .constraintSize({ maxHeight: this.viewMode === 'portrait' ? Math.max(80, this.videoH() - 108) : 300 })
            .scrollBar(BarState.Off)
            Blank().height(8)
          }
          .width(this.viewMode === 'portrait' ? '94%' : '52%')
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 14) : 420
          })
          .backgroundColor('#D9141016')
          .backdropBlur(28)
          .border({ width: 0.75, color: '#33FFFFFF' })
          .borderRadius(20)
          .shadow({ radius: 26, color: '#80000000', offsetY: 10 })
          .margin({
            bottom: this.viewMode === 'portrait' ? 8 : 14,
            right: this.viewMode === 'portrait' ? 0 : 14
          })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(this.viewMode === 'portrait' ? HorizontalAlign.Center : HorizontalAlign.End)
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showPicker = false;
        })
      }

      // 字幕 / 音轨面板（Mockup 2 左上 & 左下：带 Scroll 防裁切 + 时间偏移步进 + 丝绒高亮）
      if (this.showPanel) {
        Column() {
          Blank()
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Text(this.panelKind === 'subs' ? '字幕' : '音轨')
                .fontSize(15)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Bold)
              Blank()
              if (this.panelKind === 'subs') {
                Row({ space: 3 }) {
                  Text('样式')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.ACCENT_INK)
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(10)
                    .fontColor([Theme.ACCENT_INK])
                }
                .padding({ left: 10, right: 8, top: 5, bottom: 5 })
                .backgroundColor(Theme.accentAlpha(0.18))
                .border({ width: 0.75, color: Theme.accentAlpha(0.50) })
                .borderRadius(12)
                .onClick(() => {
                  if (!this.subTapOk('样式')) {
                    return;
                  }
                  this.showPanel = false;
                  this.subStyleOpenedAt = Date.now();
                  this.stylePanelDown = false;
                  this.subStyleOpen = true;
                })
              }
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor(['#B3FFFFFF'])
              }
              .width(26)
              .height(26)
              .borderRadius(13)
              .backgroundColor('#1FFFFFFF')
              .onClick(() => {
                if (!this.subTapOk('关闭')) {
                  return;
                }
                this.showPanel = false;
              })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 14, bottom: 4 })

            if (this.panelKind === 'subs') {
              // 时间偏移微调行（-0.5s / 当前偏移 / +0.5s / 归零）
              Row({ space: 6 }) {
                Text('时间偏移')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                Blank()
                Text('-0.5s')
                  .fontSize(11)
                  .fontColor('#E6FFFFFF')
                  .fontFeature('"tnum" 1')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#1FFFFFFF')
                  .border({ width: 0.6, color: '#29FFFFFF' })
                  .borderRadius(10)
                  .onClick(() => {
                    if (!this.subTapOk('偏移-0.5')) {
                      return;
                    }
                    this.adjustSubDelay(-0.5);
                  })
                Text(this.subDelayText())
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Math.abs(this.subDelay) >= 0.05 ? Theme.ACCENT_INK : '#B3FFFFFF')
                  .fontFeature('"tnum" 1')
                  .width(44)
                  .textAlign(TextAlign.Center)
                Text('+0.5s')
                  .fontSize(11)
                  .fontColor('#E6FFFFFF')
                  .fontFeature('"tnum" 1')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#1FFFFFFF')
                  .border({ width: 0.6, color: '#29FFFFFF' })
                  .borderRadius(10)
                  .onClick(() => {
                    if (!this.subTapOk('偏移+0.5')) {
                      return;
                    }
                    this.adjustSubDelay(0.5);
                  })
                Text('归零')
                  .fontSize(11)
                  .fontColor('#B3FFFFFF')
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                  .backgroundColor('#18FFFFFF')
                  .border({ width: 0.6, color: '#24FFFFFF' })
                  .borderRadius(10)
                  .onClick(() => {
                    if (!this.subTapOk('偏移归零')) {
                      return;
                    }
                    this.adjustSubDelay(0, true);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 14, top: 2, bottom: 4 })
            }

            // 轨道与外挂列表装进 Scroll，彻底修复 >3 条时底部导入按钮被裁切
            Scroll() {
              Column({ space: 3 }) {
                if (this.panelKind === 'subs') {
                  this.PanelRow('不使用字幕', -1)
                  ForEach(this.subLabels, (label: string, index: number) => {
                    this.PanelRow(`内嵌 · ${label}`, index)
                  }, (label: string, index: number) => `sub-${index}`)

                  Text('外挂字幕')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                    .padding({ left: 6, right: 6, top: 8, bottom: 3 })

                  if (this.localSubs.length === 0 && this.extSubs.length === 0 && this.subHint.length > 0) {
                    Text(this.subHint)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                      .padding({ left: 6, right: 6, top: 2, bottom: 4 })
                      .maxLines(3)
                  }

                  ForEach(this.localSubs, (item: LocalCandidate) => {
                    Row({ space: 8 }) {
                      if (this.currentLocalName === item.name && this.currentSubId.length === 0) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(12)
                          .fontColor([Theme.ACCENT_INK])
                      }
                      Text(`同目录 · ${item.name}`)
                        .fontSize(12)
                        .fontWeight(this.currentLocalName === item.name ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.currentLocalName === item.name ? Theme.ACCENT_INK : Theme.TEXT)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                    .borderRadius(11)
                    .backgroundColor(this.currentLocalName === item.name ? Theme.accentAlpha(0.18) : '#00000000')
                    .border({
                      width: this.currentLocalName === item.name ? 0.75 : 0,
                      color: Theme.accentAlpha(0.48)
                    })
                    .onClick(() => {
                      this.useLocalSub(item.name);
                    })
                  }, (item: LocalCandidate) => `local-${item.name}`)

                  ForEach(this.extSubs, (item: SubtitleItem) => {
                    Row({ space: 8 }) {
                      if (this.currentSubId === item.id) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(12)
                          .fontColor([Theme.ACCENT_INK])
                      }
                      Text(`${subSourceLabel(item.source)} · ${item.name}`)
                        .fontSize(12)
                        .fontWeight(this.currentSubId === item.id ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.currentSubId === item.id ? Theme.ACCENT_INK : Theme.TEXT)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                    .borderRadius(11)
                    .backgroundColor(this.currentSubId === item.id ? Theme.accentAlpha(0.18) : '#00000000')
                    .border({
                      width: this.currentSubId === item.id ? 0.75 : 0,
                      color: Theme.accentAlpha(0.48)
                    })
                    .onClick(() => {
                      if (!this.subTapOk(`远程字幕 ${item.name}`)) {
                        return;
                      }
                      this.applySub(item.id);
                    })
                  }, (item: SubtitleItem) => `ext-${item.id}`)

                  // 底部：手机导入 + 粘贴字幕 URL + 蔷薇渐变添加按钮
                  Row({ space: 6 }) {
                    Text('手机导入')
                      .fontSize(11)
                      .fontColor('#E6FFFFFF')
                      .padding({ left: 10, right: 10 })
                      .height(32)
                      .textAlign(TextAlign.Center)
                      .backgroundColor('#1FFFFFFF')
                      .border({ width: 0.6, color: '#2EFFFFFF' })
                      .borderRadius(11)
                      .onClick(() => {
                        if (!this.subTapOk('手机导入')) {
                          return;
                        }
                        this.importSub();
                      })
                    TextInput({ text: this.subUrlInput, placeholder: '粘贴字幕 URL' })
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .placeholderColor('#73FFFFFF')
                      .backgroundColor('#1AFFFFFF')
                      .border({ width: 0.6, color: '#29FFFFFF' })
                      .borderRadius(11)
                      .height(32)
                      .layoutWeight(1)
                      .onChange((value: string) => {
                        this.subUrlInput = value;
                      })
                    Text('添加')
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ON_ACCENT)
                      .padding({ left: 12, right: 12 })
                      .height(32)
                      .textAlign(TextAlign.Center)
                      .linearGradient(Theme.ctaGradient())
                      .borderRadius(11)
                      .onClick(() => {
                        if (!this.subTapOk('手动 URL')) {
                          return;
                        }
                        this.addSubUrl();
                      })
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 4 })
                } else {
                  if (this.audioLabels.length === 0) {
                    Text('当前影片仅有一条默认音轨')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  } else {
                    ForEach(this.audioLabels, (label: string, index: number) => {
                      this.PanelRow(label, index)
                    }, (label: string, index: number) => `audio-${index}`)
                  }
                }
                Blank().height(8)
              }
              .width('100%')
              .padding({ left: 10, right: 10 })
            }
            .layoutWeight(1)
            .constraintSize({
              maxHeight: this.viewMode === 'portrait'
                ? Math.max(90, this.videoH() - 96) : 340
            })
            .scrollBar(BarState.Off)
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.subPanelDown = true;
              }
            })
          }
          .width(this.viewMode === 'portrait' ? '94%' : '50%')
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 14) : 440
          })
          .backgroundColor('#D9141016')
          .backdropBlur(28)
          .border({ width: 0.75, color: '#33FFFFFF' })
          .borderRadius(20)
          .shadow({ radius: 26, color: '#80000000', offsetY: 10 })
          .margin({
            bottom: this.viewMode === 'portrait' ? 8 : 14,
            right: this.viewMode === 'portrait' ? 0 : 14
          })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.subPanelDown = true;
            }
          })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(this.viewMode === 'portrait' ? HorizontalAlign.Center : HorizontalAlign.End)
        .backgroundColor('#66000000')
        .onClick(() => {
          if (!this.subTapOk('遮罩')) {
            return;
          }
          this.showPanel = false;
        })
      }

      // 字幕样式面板（Mockup 2 右上：含实时迷你预览条 + 四行丝绒胶囊）
      if (this.subStyleOpen) {
        Column() {
          Blank()
          Column({ space: 10 }) {
            Row() {
              Text('字幕样式')
                .fontSize(15)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Bold)
              Blank()
              Text('完成')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ACCENT_INK)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor(Theme.accentAlpha(0.20))
                .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
                .borderRadius(12)
                .onClick(() => {
                  if (!this.styleTapOk('完成')) {
                    return;
                  }
                  this.subStyleOpen = false;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 14 })

            // 实时迷你预览条
            Stack({ alignContent: this.subPreviewAlign() }) {
              Column()
                .width('100%')
                .height('100%')
                .linearGradient({ angle: 135, colors: [['#FF1B1520', 0.0], ['#FF110E14', 0.5], ['#FF1D1418', 1.0]] })
              Text('今晚的雪下得很安静')
                .fontSize(this.subPreviewFontSize())
                .fontWeight(this.subOutlineW >= 3 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                .backgroundColor(this.subPreviewBgColor())
                .borderRadius(6)
                .textShadow(this.subOutlineW > 0 ? {
                  radius: this.subOutlineW * 1.6,
                  color: '#E6000000',
                  offsetX: 0,
                  offsetY: 1
                } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
                .margin({ top: 6, bottom: 6 })
            }
            .width('100%')
            .height(54)
            .borderRadius(12)
            .clip(true)
            .border({ width: 0.75, color: '#29FFFFFF' })
            .margin({ left: 14, right: 14 })

            Scroll() {
              Column({ space: 9 }) {
                Row({ space: 8 }) {
                  Text('字号')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .width(34)
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(SUB_SIZE_OPTS, (o: SubOpt) => {
                      Text(o.l)
                        .fontSize(11)
                        .fontWeight(this.subSizePct === o.v ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.subSizePct === o.v ? Theme.ACCENT_INK : '#D9FFFFFF')
                        .fontFeature('"tnum" 1')
                        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                        .backgroundColor(this.subSizePct === o.v ? Theme.accentAlpha(0.22) : '#1AFFFFFF')
                        .border({
                          width: 0.75,
                          color: this.subSizePct === o.v ? Theme.accentAlpha(0.55) : '#24FFFFFF'
                        })
                        .borderRadius(11)
                        .margin({ right: 6, bottom: 4 })
                        .onClick(() => {
                          if (!this.styleTapOk(`字号 ${o.l}`)) {
                            return;
                          }
                          this.subSizePct = o.v;
                          SubStyle.setSize(o.v);
                          this.applySubStyle();
                        })
                    }, (o: SubOpt) => `ss-${o.v}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')

                Row({ space: 8 }) {
                  Text('描边')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .width(34)
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(SUB_OUTLINE_OPTS, (o: SubOpt) => {
                      Text(o.l)
                        .fontSize(11)
                        .fontWeight(this.subOutlineW === o.v ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.subOutlineW === o.v ? Theme.ACCENT_INK : '#D9FFFFFF')
                        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                        .backgroundColor(this.subOutlineW === o.v ? Theme.accentAlpha(0.22) : '#1AFFFFFF')
                        .border({
                          width: 0.75,
                          color: this.subOutlineW === o.v ? Theme.accentAlpha(0.55) : '#24FFFFFF'
                        })
                        .borderRadius(11)
                        .margin({ right: 6, bottom: 4 })
                        .onClick(() => {
                          if (!this.styleTapOk(`描边 ${o.l}`)) {
                            return;
                          }
                          this.subOutlineW = o.v;
                          SubStyle.setOutline(o.v);
                          this.applySubStyle();
                        })
                    }, (o: SubOpt) => `so-${o.v}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')

                Row({ space: 8 }) {
                  Text('位置')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .width(34)
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(SUB_POS_OPTS, (o: SubOpt) => {
                      Text(o.l)
                        .fontSize(11)
                        .fontWeight(this.subPosPct === o.v ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.subPosPct === o.v ? Theme.ACCENT_INK : '#D9FFFFFF')
                        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                        .backgroundColor(this.subPosPct === o.v ? Theme.accentAlpha(0.22) : '#1AFFFFFF')
                        .border({
                          width: 0.75,
                          color: this.subPosPct === o.v ? Theme.accentAlpha(0.55) : '#24FFFFFF'
                        })
                        .borderRadius(11)
                        .margin({ right: 6, bottom: 4 })
                        .onClick(() => {
                          if (!this.styleTapOk(`位置 ${o.l}`)) {
                            return;
                          }
                          this.subPosPct = o.v;
                          SubStyle.setPos(o.v);
                          this.applySubStyle();
                        })
                    }, (o: SubOpt) => `sp-${o.v}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')

                Row({ space: 8 }) {
                  Text('背景')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .width(34)
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(SUB_BG_OPTS, (o: SubOpt) => {
                      Text(o.l)
                        .fontSize(11)
                        .fontWeight(this.subBgMode === o.v ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.subBgMode === o.v ? Theme.ACCENT_INK : '#D9FFFFFF')
                        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                        .backgroundColor(this.subBgMode === o.v ? Theme.accentAlpha(0.22) : '#1AFFFFFF')
                        .border({
                          width: 0.75,
                          color: this.subBgMode === o.v ? Theme.accentAlpha(0.55) : '#24FFFFFF'
                        })
                        .borderRadius(11)
                        .margin({ right: 6, bottom: 4 })
                        .onClick(() => {
                          if (!this.styleTapOk(`背景 ${o.l}`)) {
                            return;
                          }
                          this.subBgMode = o.v;
                          SubStyle.setBg(o.v);
                          this.applySubStyle();
                        })
                    }, (o: SubOpt) => `sb-${o.v}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')

                Text('实时生效，不打断播放')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 2, bottom: 8 })
              }
              .width('100%')
              .padding({ left: 16, right: 14 })
            }
            .layoutWeight(1)
            .constraintSize({
              maxHeight: this.viewMode === 'portrait'
                ? Math.max(70, this.videoH() - 122) : 260
            })
            .scrollBar(BarState.Off)
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.stylePanelDown = true;
              }
            })
          }
          .width(this.viewMode === 'portrait' ? '92%' : '50%')
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 14) : 410
          })
          .backgroundColor('#D9141016')
          .backdropBlur(28)
          .border({ width: 0.75, color: '#33FFFFFF' })
          .borderRadius(20)
          .shadow({ radius: 26, color: '#80000000', offsetY: 10 })
          .margin({
            bottom: this.viewMode === 'portrait' ? 8 : 14,
            right: this.viewMode === 'portrait' ? 0 : 14
          })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.stylePanelDown = true;
            }
          })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(this.viewMode === 'portrait' ? HorizontalAlign.Center : HorizontalAlign.End)
        .backgroundColor('#66000000')
        .onClick(() => {
          if (!this.styleTapOk('样式遮罩')) {
            return;
          }
          this.subStyleOpen = false;
        })
      }

      // （打分提示已改为「转回竖屏时由详情页高亮评分区」，这里不再弹卡）
    }
    .width('100%')
    // 页内 16:9 时只占详情页顶部那一条，不能把整页糊黑；全屏时才铺满
    .height(this.viewMode === 'portrait' ? this.videoH() : '100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#000000')
  }


  /** 看完就地打分卡（第 2 条）：5 星 + 语义标签，和详情页共用一套。 */
  @Builder
  RateCard() {
    Column({ space: 10 }) {
      Row() {
        Text('看完了，给这部片打个分？')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor(['#8CFFFFFF'])
          .padding({ left: 8, right: 2 })
          .onClick(() => {
            this.showRateCard = false;
          })
      }
      .width('100%')

      Row({ space: 4 }) {
        ForEach([1, 2, 3, 4, 5], (n: number) => {
          Column({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.star_fill'))
              .fontSize(20)
              .fontColor([n <= this.myRating ? '#FFC53D' : '#3DFFFFFF'])
            Text(RATE_LABELS[n])
              .fontSize(8)
              .fontColor(n <= this.myRating ? '#FFD06B' : '#8CFFFFFF')
          }
          .layoutWeight(1)
          .onClick(() => {
            this.submitRate(n);
          })
        }, (n: number) => `rate-${n}`)
      }
      .width('100%')
    }
    .width('88%')
    .padding(14)
    .backgroundColor('#E6141016')
    .borderRadius(16)
    .border({ width: 0.75, color: '#2EFFFFFF' })
    .shadow({ radius: 20, color: '#80000000', offsetY: 6 })
  }

  /** 画中画小图标（占位区用，和 PlayerChrome 里那个同一套画法）。 */
  @Builder
  PipGlyph() {
    SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
      .fontSize(22)
      .fontColor([Theme.ACCENT_INK])
  }

  private isPanelRowActive(index: number): boolean {
    if (this.panelKind === 'subs') {
      return this.subChosen && this.currentSubId.length === 0
        && this.currentLocalName.length === 0 && this.currentSubIndex === index;
    }
    return this.currentAudioIndex === index;
  }

  @Builder
  PanelRow(label: string, index: number) {
    Row({ space: 8 }) {
      if (this.isPanelRowActive(index)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(12)
          .fontColor([Theme.ACCENT_INK])
      }
      Text(label)
        .fontSize(12)
        .fontWeight(this.isPanelRowActive(index) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isPanelRowActive(index) ? Theme.ACCENT_INK : Theme.TEXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(11)
    .backgroundColor(this.isPanelRowActive(index) ? Theme.accentAlpha(0.18) : '#00000000')
    .border({
      width: this.isPanelRowActive(index) ? 0.75 : 0,
      color: Theme.accentAlpha(0.48)
    })
    .onClick(() => {
      if (this.panelKind === 'subs') {
        this.pickSub(index);
      } else {
        this.pickAudio(index);
      }
    })
  }
}
