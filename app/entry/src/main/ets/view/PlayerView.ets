import { router, window, PiPWindow } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { sensor } from '@kit.SensorServiceKit';
import { AudioTrack, Media, Player, PlayerConfig, SubtitleTrack } from '@mpv-ohos/mpv-arkts';
import { httpGet, httpPost, httpPut } from '../common/Http';
import { savePickLocal } from '../common/FrameStore';
import { Gallery } from '../common/Gallery';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { AppLog } from '../common/AppLog';
import { DetailParams, PlayerParams } from '../common/Types';
import { clock } from '../common/Util';
import { common } from '@kit.AbilityKit';
import { SubtitleClient, SubtitleItem, LocalCandidate, SubtitleChoice } from '../common/Subtitles';
import { PlayerPrefs, PlayerTuning } from '../common/PlayerPrefs';
import { RATE_LABELS, rateFilm } from '../ext/ratings/RatingStars';
import { PipHub } from '../common/PipHub';
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
  /** 是否显示「缓存中」全屏遮罩：只有真的卡住（>0.4s）才显示。 */
  @Local showBufferOverlay: boolean = false;
  /** 起播时刻：开头这几秒的 buffering 是正常起播，不算「卡住」（用户第 4 条）。 */
  private openAt: number = 0;
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
  /** 返回桌面自动画中画（设置项，默认关）。 */
  private pipAuto: boolean = false;
  @Local errorText: string = '';
  /** 我的评分（0 = 没打），看完时就地弹一张打分卡。 */
  @Local myRating: number = 0;
  @Local showRateCard: boolean = false;
  private ratePrompted: boolean = false;
  private rateBusy: boolean = false;
  @Local showPanel: boolean = false;
  @Local panelKind: string = 'subs';
  /**
   * 面板打开时刻（毫秒）。打开面板的那一次点击，**抬手**会落到刚插进来的第一行上，
   * 直接触发 pickSub/pickAudio → 面板刚开就关，观感就是「点字幕闪退」。
   * PlayerPage（竖屏/独立播放页）2.5.5.7 就加了这道 350ms 守卫，横屏这个 PlayerView 一直漏着
   * （2.6.1.5 补上，用户报的「横屏字幕又闪退」就是它）。
   */
  private panelOpenedAt: number = 0;
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
    // 返回桌面自动画中画（默认关，避免一按 home 就冒小窗）
    this.pipAuto = Store.I.prefString('player_pip_auto', '0') === '1';
    const ts: number = Number(Store.I.prefString('player_temp_speed', '3'));
    this.tempSpeedValue = ts >= 1.5 && ts <= 5 ? ts : 3;
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

  aboutToDisappear(): void {
    this.stopGravity();
    if (this.lockTimer >= 0) {
      clearTimeout(this.lockTimer);
      this.lockTimer = -1;
    }
    if (this.releaseTimer >= 0) {
      clearTimeout(this.releaseTimer);
      this.releaseTimer = -1;
    }
    // 页面走了 mpv 也销毁了，小窗留着只会黑屏
    this.stopPip();
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
      this.win = win;
      const props: window.WindowProperties = win.getWindowProperties();
      this.vpW = px2vp(props.windowRect.width);
      this.vpH = px2vp(props.windowRect.height);
      this.lastWinPortrait = this.vpH >= this.vpW;
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
      // 返回桌面 / 切到后台：开关打开就自动进画中画（R18）
      win.on('windowVisibilityChange', (visible: boolean) => {
        if (!visible && this.pipAuto && !this.pipActive) {
          this.startPip();
        }
      });
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
        // 详情页里的播放器跟着重力走（auto）：不锁死，否则「竖不回来」
        w.setPreferredOrientation(this.pageHost
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
    if (now - this.intentAt > 2000 || now - this.lastNudgeAt < 400) {
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
    // ★ 不要在这里锁 PORTRAIT ★
    // 用户第 4 条报「横屏退出播放页后变成横屏主页，重力也回不来」：退出时锁竖屏
    // 只是碰巧能回去；真正的原因是整个 App 在播放页之外还是竖屏锁定，
    // 而播放页把窗口留在了横屏。现在统一交还给重力（AUTO_ROTATION），
    // 由 EntryAbility 在启动时给主窗口设一次，任何界面都跟着手机转。
    this.win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
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
    this.openAt = Date.now();
    // 被判成外网但此刻局域网可达时，先把地址切回内网再开流
    await Store.I.preferLanForPlay();
    // 先定下「到底播哪个文件」：弹幕、进度、截帧都要跟着它走
    await this.ensureFileKey();
    try {
      // token 已经在 URL 的 query 里，不要再走 httpHeaders：
      // mpv-arkts 会把头名编码坏（%65%authorization），反而触发 401。
      // 有离线缓存就播本地（file://），没有才走代理 —— 见 Store.playSource
      const media: Media = new Media(Store.I.playSource(this.metaId, this.fileKey), {
        start: this.startPos
      });
      this.player.stream.error.listen((message: string) => {
        this.errorText = message.length > 0 ? message : '播放失败';
      });
      this.player.open(media);
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
      const text: string = await httpGet(url, Store.I.token);
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
      const st = this.player.state;
      if (st === undefined || st === null) {
        return;
      }
      this.pos = st.position;
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
        }
      }
      if (st.eof && !this.completed) {
        this.completed = true;
        this.saveProgress(true);
      }
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
        if (this.speed < this.tempSpeedValue) {
          this.speedBeforeTemp = this.speed;
          p.setSpeed(this.tempSpeedValue);
          this.speed = this.tempSpeedValue;
          this.toast(`${this.tempSpeedValue}x（松手恢复）`);
        }
      } else if (this.speed > this.tempSpeedValue - 0.001) {
        const back: number = this.speedBeforeTemp > 0 ? this.speedBeforeTemp : 1.0;
        p.setSpeed(back);
        this.speed = back;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] temp speed: ${e.code} ${e.message}`);
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
  private async startPip(): Promise<void> {
    if (this.pipActive) {
      return;
    }
    try {
      if (!PiPWindow.isPiPEnabled()) {
        this.toast('这台设备不支持画中画');
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      // 小窗比例按**视频实际宽高**给：写死 16:9 会让 4:3、竖屏片源在小窗里被拉变形
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
      this.pipCtrl = ctrl;
      ctrl.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
          // 用户点了小窗上的「回到应用」：这才是「退出画中画」
          this.restoreFromPip();
        } else if (state === PiPWindow.PiPState.STOPPED) {
          // 关掉小窗（X）或系统回收：停在这一页，不跳详情页
          this.onPipClosed();
        }
        console.info(`[amane] pip state ${state}: ${reason}`);
      });
      await ctrl.startPiP();
      this.pipActive = true;
      // 全局只留一个小窗：别的播放页要是也在开小窗，先让它关掉
      PipHub.claim(this.pipOwner, () => {
        this.stopPip();
        this.onPipClosed();
      });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pip: ${e.code} ${e.message}`);
      this.toast('画中画启动失败');
    }
  }

  /** 小窗被关掉：留在当前页面，播放停住（没有画面了，继续放声音只会让人困惑）。 */
  private onPipClosed(): void {
    this.pipActive = false;
    this.pipCtrl = undefined;
    PipHub.release(this.pipOwner);
    try {
      if (this.player !== undefined && this.playing) {
        this.player.playOrPause();
        this.playing = false;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pause after pip: ${e.code} ${e.message}`);
    }
  }

  /** 小窗「回到应用」：回到播放页，按设置里的默认形态继续播。 */
  private restoreFromPip(): void {
    this.pipActive = false;
    this.pipCtrl = undefined;
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
    this.pipCtrl = undefined;
    this.pipActive = false;
    PipHub.release(this.pipOwner);
    if (c === undefined) {
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
    if (this.pipActive) {
      // 画中画期间 surface 借给小窗了，重建会把 controller 换掉，直接放弃这次重建
      return;
    }
    if (forceSeek) {
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
      const st = this.player.state;
      if (st === undefined || st === null) {
        this.toast('内核还没就绪');
        return;
      }
      const tracks = st.tracks;
      if (tracks === undefined || tracks === null) {
        this.toast('没有可选的轨道');
        return;
      }
      const subsList: SubtitleTrack[] = tracks.subs === undefined || tracks.subs === null ? [] : tracks.subs;
      const audioList: AudioTrack[] = tracks.audio === undefined || tracks.audio === null ? [] : tracks.audio;
      this.subTracks = subsList;
      this.audioTracks = audioList;
      const subs: string[] = [];
      const audios: string[] = [];
      for (let i = 0; i < subsList.length; i++) {
        subs.push(this.trackLabel(subsList[i].title, subsList[i].lang, i));
      }
      for (let i = 0; i < audioList.length; i++) {
        audios.push(this.trackLabel(audioList[i].title, audioList[i].lang, i));
      }
      this.subLabels = subs;
      this.audioLabels = audios;
      this.panelKind = 'subs';
      this.loadSubSources();
      this.panelOpenedAt = Date.now();
      this.showPanel = true;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] tracks: ${e.code} ${e.message}`);
      this.toast('读轨道失败');
    }
  }


  /** 打开字幕面板时拉取来源，并自动套用上次的选择。 */
  private async loadSubSources(): Promise<void> {
    if (this.metaId <= 0) {
      this.subHint = '没有拿到条目 id，无法查询字幕';
      return;
    }
    this.subBusy = true;
    try {
      const res = await SubtitleClient.list(this.metaId);
      this.localSubs = res.local === undefined || res.local === null ? [] : res.local;
      this.extSubs = res.cached === undefined || res.cached === null ? [] : res.cached;
      this.subHint = res.hint === undefined || res.hint === null ? '' : res.hint;
      if (res.choice !== undefined && res.choice !== null && res.choice.subtitle_id.length > 0) {
        // 面板开着的时候自动套用：**不收面板**（收了就是「闪关」）
        this.applySub(res.choice.subtitle_id, false);
      }
    } catch (error) {
      console.error(`[amane] subtitles: ${JSON.stringify(error)}`);
    } finally {
      this.subBusy = false;
    }
  }

  /** 所有来源统一走这里：一个 subtitle_id → 一条远程字幕轨道。
   *
   * `closePanel`：面板打开时异步回填「上次的选择」不能收面板，否则就是「面板闪关」。
   * `remember`：自动恢复不需要把同一个值写回服务端。
   */
  private applySub(id: string, closePanel: boolean = true, remember: boolean = true): void {
    // 先收起面板：字幕加载与 mpv 解析都在后台，不该把用户卡在面板上
    if (closePanel) {
      this.showPanel = false;
    }
    this.currentSubId = id;
    this.currentSubIndex = -1;
    this.subChosen = true;
    if (this.player === undefined) {
      return;
    }
    try {
      const url: string = SubtitleClient.streamUrl(id, true);
      this.player.setSubtitleTrack(SubtitleTrack.uri(url, '', 'chi', 'external'));
      if (remember) {
        SubtitleClient.remember(this.metaId, id).catch(() => {
          // 记住失败不影响播放
        });
      }
      this.toast('已切换字幕');
    } catch (error) {
      console.error(`[amane] apply sub: ${JSON.stringify(error)}`);
      this.toast('加载字幕失败');
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
    if (Date.now() - this.panelOpenedAt < 350) {
      return;
    }
    this.currentLocalName = name;
    this.showPanel = false;
    try {
      const item: SubtitleItem = await SubtitleClient.loadLocal(this.metaId, name);
      this.applySub(item.id);
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
    // 面板刚打开的 350ms 内忽略：那次点击的抬手会落到第一行上（不然面板「点开即关」）
    if (Date.now() - this.panelOpenedAt < 350) {
      return;
    }
    this.showPanel = false;
    this.currentSubIndex = index;
    this.currentSubId = '';
    this.subChosen = true;
    if (this.player === undefined) {
      return;
    }
    try {
      if (index < 0) {
        this.player.disableSubtitleTrack();
      } else if (index < this.subTracks.length) {
        this.player.setSubtitleTrack(this.subTracks[index]);
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
    if (Date.now() - this.panelOpenedAt < 350) {
      return;
    }
    if (this.player === undefined) {
      return;
    }
    try {
      if (index >= 0 && index < this.audioTracks.length) {
        this.player.setAudioTrack(this.audioTracks[index]);
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
                AppLog.mark('surface', `onLoad gen=${gen} attach sid=${sid.substring(0, 6)} pos=${this.pos.toFixed(1)}`);
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
              // 收缩态点画面 = 展开回 16:9；正常态 = 显隐控件
              if (this.shrunken()) {
                this.toggleSheet();
              } else {
                this.showControls = !this.showControls;
              }
            }),
          TapGesture({ count: 2 })
            .onAction(() => {
              this.togglePlay();
              this.toast(this.playing ? '播放' : '暂停');
            }),
          // 长按整屏 = 临时 3 倍速（R11）：触发点是整块画面，不是那个小胶囊
          LongPressGesture({ repeat: false, duration: 420 })
            .onAction(() => {
              this.tempSpeed(true);
            })
            .onActionEnd(() => {
              this.tempSpeed(false);
            }),
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart(() => {
              this.panKind = 'seek';
              this.panStartPos = this.pos;
              this.seekPreview = this.pos;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.panKind === 'seek') {
                const delta: number = event.offsetX / 400 * Math.min(this.duration, 600);
                this.seekPreview = Math.max(0, Math.min(this.duration, this.panStartPos + delta));
              }
            })
            .onActionEnd(() => {
              if (this.panKind === 'seek' && this.seekPreview >= 0) {
                this.seekTo(this.seekPreview);
              }
              this.panKind = '';
              this.seekPreview = -1;
            }),
          PanGesture({ direction: PanDirection.Vertical })
            .onActionStart((event: GestureEvent) => {
              // 左半屏 = 亮度，右半屏 = 音量（用户第 5 条）。
              // 之前写死 localX > 300，横屏（780 宽）时几乎恒真 → 两边都调音量。
              // 现在按「手势层宽度」的比例判断，竖屏/横屏都对。
              const w: number = Math.max(1, this.gestureW());
              const x: number = event.fingerList.length > 0
                ? Math.max(0, Math.min(w, event.fingerList[0].localX)) : w / 2;
              if (x > w / 2) {
                this.panKind = 'volume';
                this.panBase = this.volume;
              } else {
                this.panKind = 'bright';
                this.panBase = this.bright * 100;
              }
              this.panSide = x > w / 2 ? 'right' : 'left';
            })
            .onActionUpdate((event: GestureEvent) => {
              const delta: number = -event.offsetY / 3;
              if (this.panKind === 'volume') {
                this.volume = Math.max(0, Math.min(100, this.panBase + delta));
                this.applyVolume(this.volume);
                this.volumeHint = Math.round(this.volume);
              } else if (this.panKind === 'bright') {
                this.bright = Math.max(0.05, Math.min(1, (this.panBase + delta) / 100));
                if (this.win !== undefined) {
                  this.win.setWindowBrightness(this.bright).catch((err: BusinessError) => {
                    console.error(`[amane] brightness: ${err.code} ${err.message}`);
                  });
                }
                this.volumeHint = Math.round(this.bright * 100);
              }
            })
            .onActionEnd(() => {
              this.panKind = '';
              this.volumeHint = -1;
            })
        )
        )

      // 控件层：顶部悬浮胶囊 + 底部悬浮面板（view/PlayerChrome，纯 ArkUI）
      // 竖屏下**永远画**（缩小了也要有播放/进度/全屏），全屏时才跟 showControls 走
      if (this.viewMode === 'portrait' || this.showControls) {
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
            this.startPip();
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
          },
          onSeekEnd: (value: number) => {
            this.seekTo(value);
            this.seekPreview = -1;
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
            // 图标本身会跟着变（喇叭 ↔ 带叉），再补一条文字，别看半天不确定
            this.toast(this.volume > 0 ? `音量 ${this.volume}%` : '已静音');
          }
        })
      }

      // 拖动进度条时的画面预览（R08）：从雪碧图里裁一格，不用等 seek 完成
      if (this.seekPreview >= 0 && this.prevOk && !this.shrunken()) {
        // ★ alignContent 必须是 TopStart ★
        // Stack 默认居中：1024×576 的雪碧图被塞进 128×72 的框里时，图上边会在
        // y=-252，再按格子偏移就切到中间去了 —— 屏幕上就是「一格里有四个小画面」，
        // 时间轴也跟着对不上。左上对齐之后 offset 才等于「第几格」。
        Stack({ alignContent: Alignment.TopStart }) {
          Image(Store.I.img(this.prevUrl))
            // 每格固定 128×72：雪碧图整张按 cols×rows 铺开，offset 就是「第几格」
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
        .borderRadius(6)
        .backgroundColor('#000000')
        .border({ width: 0.6, color: '#3DFFFFFF' })
        .shadow({ radius: 12, color: '#66000000', offsetY: 4 })
        .margin({ bottom: this.viewMode === 'portrait' ? 44 : 150 })
      }

      // 弹幕层（B 站式）：从右往左飞，按轨道排，不吃触摸。
      // 每条弹幕是一个独立组件，进入时启动一次 Linear 补间跑完全程 ——
      // key 只用 id，不会每帧重建（用户第 5 条：之前一跳一跳的）。
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

      // 中央提示
      if (this.seekPreview >= 0) {
        Text(this.seekPreviewLabel())
          .fontSize(15)
          .fontColor('#FFFFFF')
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
      } else if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
      } else if (this.volumeHint >= 0) {
        // 左边调亮度、右边调音量，提示文字要跟着走（之前写死「音量」）
        Text(`${this.panKind === 'bright' ? '亮度' : '音量'} ${this.volumeHint}%`)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
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

      // 画中画占位（第 6 条）：小窗在外面放着，这里原地留一块牌子，
      // 用户可以继续在应用里逛，关掉小窗也不跳页。
      if (this.pipActive) {
        Column({ space: 12 }) {
          Row() {
            this.PipGlyph()
          }
          Text('正在画中画播放')
            .fontSize(13)
            .fontColor('#E6FFFFFF')
          Text('小窗浮在最上层，你可以继续在应用里做别的事')
            .fontSize(10)
            .fontColor('#8CFFFFFF')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Row({ space: 10 }) {
            Text('回到播放页')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor(Theme.ACCENT)
              .borderRadius(14)
              .onClick(() => {
                this.restoreFromPip();
              })
            Text('关闭小窗')
              .fontSize(12)
              .fontColor(Theme.TEXT)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .onClick(() => {
                this.stopPip();
                this.onPipClosed();
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0E0E12')
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

      // 写批注（R23）：带上当前时间点，保存后下次播到这里就出现
      if (this.showAnnoInput) {
        Column() {
          Column({ space: 12 }) {
            Row() {
              Text('发弹幕')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT)
              Blank()
              Text(`@ ${clock(this.pos)}`)
                .fontSize(11)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')

            TextArea({ text: this.annoDraft, placeholder: '这一段怎么样？一句话飘过去' })
              .width('100%')
              .height(88)
              .fontSize(13)
              .backgroundColor(Theme.CARD)
              .borderRadius(10)
              .onChange((v: string) => {
                this.annoDraft = v;
              })

            Row({ space: 10 }) {
              Button('取消')
                .layoutWeight(1)
                .height(38)
                .fontSize(13)
                .backgroundColor(Theme.CARD)
                .fontColor(Theme.TEXT)
                .onClick(() => {
                  this.showAnnoInput = false;
                })
              Button(this.annoBusy ? '保存中…' : '保存')
                .layoutWeight(1)
                .height(38)
                .fontSize(13)
                .backgroundColor(Theme.ACCENT)
                .fontColor('#FFFFFF')
                .enabled(!this.annoBusy)
                .onClick(() => {
                  this.addAnnotation();
                })
            }
            .width('100%')
          }
          .width(this.viewMode === 'portrait' ? '92%' : '58%')
          // 竖屏这块只有 16:9 那么高，输入框 + 按钮正好塞满，别溢出到详情页
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 16) : 420
          })
          .padding(18)
          .backgroundColor(Theme.BG_RAISED)
          .borderRadius(16)
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {
          this.showAnnoInput = false;
        })
      }

      // 选集面板（R12）：左边版本、右边同系列，都带海报 —— 挑片不用退回详情页
      if (this.showPicker) {
        Column() {
          Blank()
          Column({ space: 8 }) {
            Row() {
              Text('选集')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('关闭')
                .fontSize(12)
                .fontColor(Theme.TEXT_FAINT)
                .onClick(() => {
                  this.showPicker = false;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 2 })

            Row({ space: 8 }) {
              Text(`${this.versions.length} 个版本`)
                .fontSize(12)
                .fontColor(this.pickerTab === 'version' ? '#FFFFFF' : Theme.TEXT_DIM)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.pickerTab === 'version' ? Theme.ACCENT : Theme.CARD)
                .borderRadius(12)
                .onClick(() => {
                  this.pickerTab = 'version';
                })
              Text(this.sibName.length > 0 ? this.sibName : '同系列')
                .fontSize(12)
                .fontColor(this.pickerTab === 'series' ? '#FFFFFF' : Theme.TEXT_DIM)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.pickerTab === 'series' ? Theme.ACCENT : Theme.CARD)
                .borderRadius(12)
                .onClick(() => {
                  this.pickerTab = 'series';
                })
              Blank()
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })

            if (this.pickerLoading) {
              Text('读取中…')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ left: 16, top: 8, bottom: 12 })
            }

            Scroll() {
              if (this.pickerTab === 'version') {
                Column({ space: 2 }) {
                  ForEach(this.versions, (v: VerItem) => {
                    Row({ space: 10 }) {
                      Column({ space: 3 }) {
                        Text(v.name)
                          .fontSize(12)
                          .fontColor(v.key === this.fileKey ? Theme.ACCENT : Theme.TEXT)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Text(`${v.definition.length > 0 ? v.definition : '未知清晰度'} · ${Math.round(v.size / 1048576)} MB`)
                          .fontSize(9)
                          .fontColor(Theme.TEXT_FAINT)
                          .width('100%')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (v.key === this.fileKey) {
                        Text('播放中')
                          .fontSize(9)
                          .fontColor(Theme.ACCENT)
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                    .onClick(() => {
                      this.pickVersion(v);
                    })
                  }, (v: VerItem) => `ver-${v.key}`)
                }
                .width('100%')
              } else {
                Column({ space: 2 }) {
                  ForEach(this.siblings, (s: SibItem) => {
                    Row({ space: 10 }) {
                      Image(Store.I.img(s.poster))
                        .width(38)
                        .height(53)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(6)
                        .backgroundColor(Theme.CARD)
                      Column({ space: 3 }) {
                        Text(s.number)
                          .fontSize(12)
                          .fontColor(s.current ? Theme.ACCENT : Theme.TEXT)
                          .maxLines(1)
                          .width('100%')
                        Text(s.actors.length > 0 ? s.actors.join(' · ') : s.title)
                          .fontSize(9)
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
                          .fontColor(Theme.ACCENT)
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                    .onClick(() => {
                      this.pickSibling(s);
                    })
                  }, (s: SibItem) => `sib-${s.id}`)
                }
                .width('100%')
              }
            }
            .constraintSize({ maxHeight: 300 })
            .scrollBar(BarState.Off)
            Blank().height(10)
          }
          .width(this.viewMode === 'portrait' ? '94%' : '52%')
          // ★ 竖屏只能待在播放器那一条里 ★
          // 播放器在详情页顶部只有 16:9 高（≈200vp）。之前面板按 '100%' 排、内容
          // maxHeight 给到 300，结果下半截直接压到下面的影片详情上（第 2 条）。
          // 现在竖屏把整块面板限制在播放区高度内，内容超出的部分在面板内部滚动。
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 16) : 420
          })
          .backgroundColor('#66000000')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .border({ width: 1, color: '#33FFFFFF' })
          .borderRadius(22)
          .shadow({ radius: 26, color: '#73000000', offsetY: 10 })
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

      // 字幕 / 音轨面板
      if (this.showPanel) {
        Column() {
          Blank()
          Column({ space: 2 }) {
            Row() {
              Text(this.panelKind === 'subs' ? '字幕' : '音轨')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('关闭')
                .fontSize(12)
                .fontColor(Theme.TEXT_FAINT)
                .onClick(() => {
                  this.showPanel = false;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })

            if (this.panelKind === 'subs') {
              this.PanelRow('不使用字幕', -1)
              ForEach(this.subLabels, (label: string, index: number) => {
                this.PanelRow(label, index)
              }, (label: string, index: number) => `sub-${index}`)

              Text('外挂字幕').fontSize(11).fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 4 })
              if (this.localSubs.length === 0 && this.subHint.length > 0) {
                Text(this.subHint)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 2, bottom: 4 })
                  .maxLines(3)
              }
              ForEach(this.localSubs, (item: LocalCandidate) => {
                Text(`${this.currentLocalName === item.name ? '✓ ' : ''}同目录 · ${item.name}`)
                  .fontSize(12)
                  .fontColor(this.currentLocalName === item.name ? Theme.ACCENT : Theme.TEXT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => {
                    this.useLocalSub(item.name);
                  })
              }, (item: LocalCandidate) => `local-${item.name}`)
              ForEach(this.extSubs, (item: SubtitleItem) => {
                Text(`${this.currentSubId === item.id ? '✓ ' : ''}${item.name} · ${item.source}`)
                  .fontSize(12)
                  .fontColor(this.currentLocalName === item.name ? Theme.ACCENT : Theme.TEXT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => {
                    this.applySub(item.id);
                  })
              }, (item: SubtitleItem) => `ext-${item.id}`)
              Row() {
                Button('手机导入')
                  .fontSize(11)
                  .height(30)
                  .onClick(() => {
                    this.importSub();
                  })
                Button('手动 URL')
                  .fontSize(11)
                  .height(30)
                  .onClick(() => {
                    this.addSubUrl();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 6 })
              TextInput({ placeholder: 'https://.../subtitle.srt' })
                .fontSize(11)
                .height(32)
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.subUrlInput = value;
                })
            } else {
              ForEach(this.audioLabels, (label: string, index: number) => {
                this.PanelRow(label, index)
              }, (label: string, index: number) => `audio-${index}`)
            }
            Blank().height(12)
          }
          .width(this.viewMode === 'portrait' ? '92%' : '48%')
          .constraintSize({
            maxHeight: this.viewMode === 'portrait'
              ? Math.max(150, this.videoH() - 16) : 460
          })
          // 面板同样是悬浮玻璃：毛玻璃 + 细边 + 投影，四周留 14vp 让视频透出来
          .backgroundColor('#66000000')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .border({ width: 0.5, color: '#26FFFFFF' })
          .borderRadius(22)
          .shadow({ radius: 26, color: '#73000000', offsetY: 10 })
          .margin({
            bottom: this.viewMode === 'portrait' ? 8 : 14,
            right: this.viewMode === 'portrait' ? 0 : 14
          })
          .onClick(() => {
            // 吞掉点击：不然会冒泡到下面的遮罩层，面板刚点就关了
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
        .onClick(() => {
          // 遮罩同理：面板刚开的那一次点击不能把它关掉
          if (Date.now() - this.panelOpenedAt < 350) {
            return;
          }
          this.showPanel = false;
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
        Text('×')
          .fontSize(16)
          .fontColor('#8CFFFFFF')
          .padding({ left: 8, right: 2 })
          .onClick(() => {
            this.showRateCard = false;
          })
      }
      .width('100%')

      Row({ space: 4 }) {
        ForEach([1, 2, 3, 4, 5], (n: number) => {
          Column({ space: 3 }) {
            Text('★')
              .fontSize(22)
              .fontColor(n <= this.myRating ? '#FFC53D' : '#3DFFFFFF')
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
    .backgroundColor('#E60B0B0F')
    .borderRadius(16)
    .border({ width: 0.6, color: '#26FFFFFF' })
    .shadow({ radius: 20, color: '#80000000', offsetY: 6 })
  }

  /** 画中画小图标（占位区用，和 PlayerChrome 里那个同一套画法）。 */
  @Builder
  PipGlyph() {
    Stack({ alignContent: Alignment.Start }) {
      Path()
        .commands('M1 1 L25 1 L25 19 L1 19 Z')
        .stroke('#8CFFFFFF')
        .strokeWidth(1.6)
        .fillOpacity(0)
        .width(26)
        .height(20)
      Column()
        .width(11)
        .height(7)
        .backgroundColor('#8CFFFFFF')
        .position({ x: 12, y: 10 })
    }
    .width(26)
    .height(20)
  }

  @Builder
  PanelRow(label: string, index: number) {
    Text((this.panelKind === 'subs' && this.subChosen && this.currentSubIndex === index ? '✓ ' : '') + label)
      .fontSize(13)
      .fontColor(Theme.TEXT)
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick(() => {
        if (this.panelKind === 'subs') {
          this.pickSub(index);
        } else {
          this.pickAudio(index);
        }
      })
  }
}
