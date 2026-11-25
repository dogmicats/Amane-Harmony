/**
 * 全局小窗（2.8.3 液态玻璃升级 + 系统画中画无缝接力）——浮在应用最上层的那块播放画面。
 *
 * 位置与触摸：
 *   - 外层 Stack 与 CustomNode 均设 `HitTestMode.None`（自身不参与命中、不阻断子卡片与底层页面），
 *     只有实际 216×122vp 的卡片节点响应拖动与点击，卡片以外 100% 穿透给 App 界面；
 *   - 用绝对定位 `position({x, y})`，顶边避让状态栏（amaneTopInset + 8），松手左右吸附；
 *
 * 系统画中画接力：
 *   - 小窗播放中自动在当前 XComponentController 上注册 `PiPWindow.PiPController` 并开启
 *     `setAutoStartEnabled(true)`，最小化 App（上滑回桌面）时由系统自动无缝接管为系统画中画小窗。
 *
 * 铁律：FloatSurface 内的 XComponent 全程常驻、不包裹 `if`、父容器不加动画，
 * 所有叠加控件仅切 visibility，绝不打断 mpv 画面输出。
 */
import { Player, PlayerConfig, Media, SubtitleTrack, PlayerState } from '@mpv-ohos/mpv-arkts';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { display, PiPWindow } from '@kit.ArkUI';
import { PlayHandoff, PlaySession } from '../common/PlaySession';
import { FloatBox } from '../common/FloatBox';
import { PlayerPrefs } from '../common/PlayerPrefs';
import { Store } from '../common/Store';
import { SubtitleClient } from '../common/Subtitles';
import { Theme } from '../common/Theme';
import { PipHub } from '../common/PipHub';
import { BackAudio } from '../common/BackAudio';

const CARD_W: number = 216;
const EDGE: number = 12;
const TAB_W: number = 36;
const TAB_H: number = 58;

/**
 * 贴底留白：保证停在底部导航栏上方，不压住收藏/我的等底栏入口。
 */
const BOTTOM_SAFE: number = 125;

/**
 * 画面层单独一个组件：把 XComponent 与父组件状态彻底隔开，确保 surface 全程稳定不断流。
 */
@Component
struct FloatSurface {
  player: Player | undefined = undefined;
  ctrl: XComponentController = new XComponentController();
  attached: () => void = () => {};

  build() {
    XComponent({
      id: 'amane_float_mpv',
      type: XComponentType.SURFACE,
      controller: this.ctrl
    })
      .onLoad(() => {
        const p: Player | undefined = this.player;
        console.info(`[amane] float surface load player=${p !== undefined}`);
        if (p === undefined) {
          return;
        }
        try {
          p.native.attachSurface(this.ctrl.getXComponentSurfaceId());
          console.info('[amane] float surface attached');
          this.attached();
        } catch (err) {
          const e = err as BusinessError;
          console.error(`[amane] float attach: ${e.code} ${e.message}`);
        }
      })
      .width('100%')
      .height('100%')
  }
}

@Component
export struct FloatPlayerCard {
  session: PlayHandoff = PlaySession.empty();
  @StorageProp('amaneTopInset') topInset: number = 0;
  /** 只做小窗（详情页发起）：双击切播放/暂停，不切宽条。 */
  private compactOnly: boolean = true;
  /** 0 = 小窗，1 = 宽条。 */
  @State tier: number = 0;
  @State controlsOn: boolean = true;
  @State playing: boolean = false;
  @State firstFrame: boolean = false;
  @State dragging: boolean = false;
  @State progRatio: number = 0;
  @State snappedLeft: boolean = false;
  /** 已切到系统画中画中：此时不画应用内卡片装饰（但保留 FloatSurface 节点不断流）。 */
  @State pipActive: boolean = false;
  private disposed: boolean = false;
  private opened: boolean = false;
  private startPx: number = 0;
  private startPy: number = 0;
  /** 收起成边缘玻璃标签：不销毁播放，轻点即可恢复。 */
  @State collapsed: boolean = false;
  @State px: number = 0;
  @State py: number = 0;
  private winW: number = 360;
  private winH: number = 720;
  private xc: XComponentController = new XComponentController();
  private player: Player | undefined = undefined;
  private hideTimer: number = -1;
  private progTimer: number = -1;
  private pipPrepTimer: number = -1;
  private pipCtrl: PiPWindow.PiPController | undefined = undefined;
  private pipPreparing: boolean = false;
  private pipStarting: boolean = false;
  private pipRestoring: boolean = false;
  private pipAutoArmed: boolean = false;
  private pipSized: boolean = false;
  private lastPipPlaying: boolean = false;
  private pipEpoch: number = 0;
  private readonly pipOwner: string = `float_${Date.now()}_${Math.floor(Math.random() * 10000)}`;

  private markAttached = (): void => {
    this.firstFrame = true;
    console.info('[amane] float attached, start media');
    this.openMedia();
    // 稍微延后 180ms 注册系统画中画：让刚退出内嵌播放的 PlayerView 先完成旧 PiPController 释放
    if (this.pipPrepTimer >= 0) {
      clearTimeout(this.pipPrepTimer);
    }
    this.pipPrepTimer = setTimeout(() => {
      this.pipPrepTimer = -1;
      this.preparePip();
    }, 180);
  };

  aboutToAppear(): void {
    this.disposed = false;
    this.compactOnly = this.session.compact !== false;
    try {
      const d = display.getDefaultDisplaySync();
      const w: number = px2vp(d.width);
      const h: number = px2vp(d.height);
      if (w > 120 && h > 120) {
        this.winW = w;
        this.winH = h;
      }
    } catch (err) {
      console.info(`[amane] float display: ${JSON.stringify(err)}`);
    }
    this.placeDefault();
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const tuning = PlayerPrefs.apply(ctx);
      PlayerPrefs.dir(ctx);
      this.player = new Player(new PlayerConfig({
        configDir: PlayerPrefs.dir(ctx),
        hwdec: tuning.hwdec,
        vo: 'gpu-next',
        osc: false,
        osd: false,
        onReady: () => {
          console.info('[amane] float player ready');
          this.openMedia();
        }
      }));
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] float player: ${e.code} ${e.message}`);
    }
    this.progTimer = setInterval(() => {
      this.syncProgress();
    }, 500);
    this.armHideTimer();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (this.progTimer >= 0) {
      clearInterval(this.progTimer);
      this.progTimer = -1;
    }
    if (this.pipPrepTimer >= 0) {
      clearTimeout(this.pipPrepTimer);
      this.pipPrepTimer = -1;
    }
    this.stopPip();
    BackAudio.setPlaying(false);
    try {
      this.player?.destroy();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] float destroy: ${e.code}`);
    }
    this.player = undefined;
  }

  /** 注册系统画中画控制器：应用内小窗在播时，上滑最小化 App 由系统自动接管成系统小窗。 */
  private async preparePip(): Promise<void> {
    if (this.disposed || !this.firstFrame || this.pipCtrl !== undefined
      || this.pipPreparing || !PiPWindow.isPiPEnabled()) {
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
          this.pipSized = true;
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
      if (this.disposed || epoch !== this.pipEpoch) {
        ctrl.setAutoStartEnabled(false);
        return;
      }
      this.pipCtrl = ctrl;
      ctrl.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        if (this.disposed || this.pipCtrl !== ctrl) {
          return;
        }
        console.info(`[amane] float pip state ${state}: ${reason}`);
        if (state === PiPWindow.PiPState.ABOUT_TO_START) {
          this.pipStarting = true;
        } else if (state === PiPWindow.PiPState.STARTED) {
          this.pipStarting = false;
          this.pipActive = true;
          PipHub.claim(this.pipOwner, () => {
            this.stopPip();
            FloatBox.requestClose();
          });
          if (BackAudio.screenOff() && this.playing) {
            this.togglePlay();
          }
        } else if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
          this.pipRestoring = true;
        } else if (state === PiPWindow.PiPState.STOPPED) {
          const restoring: boolean = this.pipRestoring;
          this.pipRestoring = false;
          this.pipStarting = false;
          this.pipActive = false;
          PipHub.release(this.pipOwner);
          if (restoring) {
            this.updatePipAutoStart();
          } else {
            // 用户点了系统画中画的 × 关闭：停播并收掉应用内浮窗
            FloatBox.requestClose();
          }
        } else if (state === PiPWindow.PiPState.ERROR) {
          this.pipStarting = false;
          this.pipActive = false;
          this.pipRestoring = false;
          PipHub.autoArmed = false;
          PipHub.release(this.pipOwner);
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
      console.info('[amane] float pip prepared');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] float pip prepare: ${e.code} ${e.message}`);
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
    // 用户已经主动开启了应用内小窗：只要在播且未折叠，最小化 App 一律自动变系统小窗
    const enable: boolean = !this.disposed && this.playing && !this.collapsed && this.firstFrame;
    PipHub.autoArmed = enable;
    if (enable !== this.pipAutoArmed) {
      try {
        ctrl.setAutoStartEnabled(enable);
        this.pipAutoArmed = enable;
        console.info(`[amane] float pip auto: ${enable}`);
      } catch (err) {
        const e = err as BusinessError;
        console.error(`[amane] float pip auto: ${e.code} ${e.message}`);
      }
    }
    if (enable) {
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        const title: string = this.session.number.length > 0 ? this.session.number : this.session.title;
        BackAudio.ensure(ctx, title);
        BackAudio.setPlaying(true);
      } catch (e) {
        // 忽略
      }
    } else {
      BackAudio.setPlaying(false);
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
      console.info(`[amane] float release pip: ${e.code} ${e.message}`);
    }
    if (running) {
      c.stopPiP().catch((err: BusinessError) => {
        console.error(`[amane] float stop pip: ${err.code} ${err.message}`);
      });
    }
  }

  private syncProgress(): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      const st: PlayerState | undefined = p.state;
      if (st === undefined || st === null) {
        return;
      }
      if (st.duration > 0) {
        const r: number = Math.max(0, Math.min(1, st.position / st.duration));
        if (Math.abs(r - this.progRatio) >= 0.004) {
          this.progRatio = r;
        }
      }
      this.playing = st.playing;
      if (this.pipCtrl === undefined && this.firstFrame && !this.pipPreparing && !this.disposed) {
        this.preparePip();
      }
      if (this.pipCtrl !== undefined && !this.pipSized) {
        const vp = st.videoParams;
        if (vp !== undefined && vp.dw > 0 && vp.dh > 0) {
          this.pipSized = true;
          try {
            this.pipCtrl.updateContentSize(Math.round(vp.dw), Math.round(vp.dh));
          } catch (e) {
            // 忽略
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
          // 忽略
        }
      }
      this.updatePipAutoStart();
    } catch (err) {
      // 忽略瞬时读取异常
    }
  }

  private minY(): number {
    return Math.max(EDGE, this.topInset + 8);
  }

  private cardW(): number {
    if (this.collapsed) {
      return TAB_W;
    }
    return this.tier === 0 ? CARD_W : this.winW;
  }

  private cardH(): number {
    if (this.collapsed) {
      return TAB_H;
    }
    return Math.round(this.cardW() * 9 / 16);
  }

  private placeDefault(): void {
    if (this.collapsed) {
      this.px = this.snappedLeft ? 0 : Math.max(0, this.winW - TAB_W);
      this.py = Math.max(this.minY(), Math.min(this.winH - TAB_H - BOTTOM_SAFE, this.py > 0 ? this.py : this.winH * 0.46));
      return;
    }
    if (this.tier === 0) {
      this.px = this.snappedLeft ? EDGE : Math.max(EDGE, this.winW - CARD_W - EDGE);
      this.py = Math.max(this.minY(), this.winH - this.cardH() - BOTTOM_SAFE);
    } else {
      this.px = 0;
      this.py = Math.max(this.minY(), 92);
    }
  }

  private clampPos(): void {
    const w: number = this.cardW();
    const h: number = this.cardH();
    const topSafe: number = this.minY();
    const maxX: number = Math.max(0, this.winW - w);
    const maxY: number = Math.max(topSafe, this.winH - h - EDGE);
    if (this.collapsed) {
      this.px = this.snappedLeft ? 0 : maxX;
    } else if (this.tier === 1) {
      this.px = 0;
    } else if (this.px < EDGE) {
      this.px = EDGE;
    } else if (this.px > maxX - EDGE) {
      this.px = Math.max(EDGE, maxX - EDGE);
    }
    if (this.py < topSafe) {
      this.py = topSafe;
    } else if (this.py > maxY) {
      this.py = maxY;
    }
  }

  private snapX(): void {
    if (this.tier === 1 && !this.collapsed) {
      return;
    }
    const maxX: number = Math.max(0, this.winW - this.cardW());
    this.snappedLeft = this.px + this.cardW() / 2 < this.winW / 2;
    if (this.collapsed) {
      this.px = this.snappedLeft ? 0 : maxX;
    } else {
      this.px = this.snappedLeft ? EDGE : Math.max(EDGE, maxX - EDGE);
    }
  }

  private openMedia(): void {
    if (this.opened) {
      return;
    }
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      const media: Media = new Media(Store.I.playSource(this.session.mid, this.session.fileKey), {
        start: this.session.pos
      });
      p.open(media);
      this.opened = true;
      this.playing = true;
      if (this.session.speed > 0.1 && this.session.speed !== 1) {
        p.setSpeed(this.session.speed);
      }
      if (this.session.subId.length > 0) {
        p.setSubtitleTrack(SubtitleTrack.uri(
          SubtitleClient.streamUrl(this.session.subId, true), '', 'chi', 'external'));
      }
      this.updatePipAutoStart();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] float open: ${e.code} ${e.message}`);
    }
  }

  private armHideTimer(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      this.controlsOn = false;
      this.hideTimer = -1;
    }, 3200);
  }

  private toggleControls(): void {
    if (this.collapsed) {
      this.expandFromCollapsed();
      return;
    }
    this.controlsOn = !this.controlsOn;
    if (this.controlsOn) {
      this.armHideTimer();
    }
  }

  private onDoubleTap(): void {
    if (this.collapsed) {
      this.expandFromCollapsed();
      return;
    }
    if (this.compactOnly) {
      this.togglePlay();
      return;
    }
    this.tier = this.tier === 0 ? 1 : 0;
    this.placeDefault();
    this.controlsOn = true;
    this.armHideTimer();
  }

  private togglePlay(): void {
    const p: Player | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      p.playOrPause();
      this.playing = !this.playing;
      this.updatePipAutoStart();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] float play: ${e.code} ${e.message}`);
    }
    this.armHideTimer();
  }

  /** 收起为侧边玻璃耳标：暂停但不销毁播放，点一下即恢复。 */
  private collapse(): void {
    const p: Player | undefined = this.player;
    if (p !== undefined && this.playing) {
      try {
        p.playOrPause();
        this.playing = false;
      } catch (err) {
        console.info(`[amane] float pause: ${JSON.stringify(err)}`);
      }
    }
    this.collapsed = true;
    this.controlsOn = false;
    this.updatePipAutoStart();
    this.placeDefault();
  }

  private expandFromCollapsed(): void {
    this.collapsed = false;
    this.controlsOn = true;
    this.updatePipAutoStart();
    this.placeDefault();
    this.armHideTimer();
  }

  private currentSession(): PlayHandoff {
    const h: PlayHandoff = this.session;
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        const st: PlayerState | undefined = p.state;
        if (st !== undefined && st !== null && st.position > 0) {
          h.pos = st.position;
        }
      } catch (err) {
        console.info(`[amane] float pos: ${JSON.stringify(err)}`);
      }
    }
    return h;
  }

  private cardRadius(): BorderRadiuses {
    if (this.collapsed) {
      if (this.snappedLeft) {
        return { topLeft: 0, bottomLeft: 0, topRight: 18, bottomRight: 18 };
      }
      return { topLeft: 18, bottomLeft: 18, topRight: 0, bottomRight: 0 };
    }
    const r: number = this.tier === 0 ? 14 : 0;
    return { topLeft: r, topRight: r, bottomLeft: r, bottomRight: r };
  }

  @Builder
  MicroGlassBtn(sym: Resource, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(sym)
        .fontSize(11)
        .fontColor(['#F2FFFFFF'])
    }
    .width(23)
    .height(23)
    .borderRadius(12)
    .backgroundColor('#99100D11')
    .border({ width: 0.6, color: '#38FFFFFF' })
    .onClick(() => {
      onTap();
    })
  }

  build() {
    // 关键修复（2.8.3）：外层全屏 Stack 必须用 HitTestMode.None（不能用 Transparent）！
    // Transparent 仍会让全屏 Stack 自身响应命中，挂在 OverlayManager 上时直接截断底层整个 App 界面；
    // None 表示 Stack 自身绝不响应命中，同时照常放行子卡片（Column）与底层页面，卡片外 100% 可点可滑。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardBody()
      }
      .width(this.cardW())
      .height(this.cardH())
      .borderRadius(this.cardRadius())
      .clip(true)
      .backgroundColor(this.collapsed ? '#D9141016' : '#000000')
      .border({
        width: this.pipActive ? 0 : (this.tier === 0 || this.collapsed ? 0.75 : 0),
        color: this.collapsed ? Theme.accentAlpha(0.45) : '#38FFFFFF'
      })
      .shadow(this.pipActive ? { radius: 0, color: '#00000000', offsetY: 0 }
        : { radius: 22, color: '#80000000', offsetY: 6 })
      .position({ x: this.px, y: this.py })
      // 不给含 XComponent 的节点加动画，防止重建打断 mpv
      .opacity(this.pipActive ? 0 : (this.dragging ? 0.78 : 1))
      .hitTestBehavior(this.pipActive ? HitTestMode.None : HitTestMode.Default)
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PanGesture({ fingers: 1, distance: 16 })
            .onActionStart(() => {
              this.dragging = true;
              this.startPx = this.px;
              this.startPy = this.py;
            })
            .onActionUpdate((ev: GestureEvent) => {
              this.px = this.startPx + ev.offsetX;
              this.py = this.startPy + ev.offsetY;
              this.clampPos();
            })
            .onActionEnd(() => {
              this.dragging = false;
              this.snapX();
              this.clampPos();
              if (!this.collapsed) {
                this.controlsOn = true;
                this.armHideTimer();
              }
            }),
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => {
              this.onDoubleTap();
            }),
            TapGesture({ count: 1 }).onAction(() => {
              if (!this.dragging) {
                this.toggleControls();
              }
            })
          )
        )
      )
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  CardBody() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.player !== undefined) {
        FloatSurface({
          player: this.player,
          ctrl: this.xc,
          attached: this.markAttached
        })
      }

      // 首帧前占位：常驻树里，只切可见性
      Column({ space: 4 }) {
        Text(this.session.number.length > 0 ? this.session.number : '准备播放')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#0D0B0E')
      .visibility(this.firstFrame || this.collapsed || this.pipActive ? Visibility.None : Visibility.Visible)
      .hitTestBehavior(HitTestMode.None)

      // 展开态悬浮液态玻璃控件层（常驻，只切 visibility）
      Stack({ alignContent: Alignment.Center }) {
        // 顶部微条：番号 + 折叠 / 回详情 / 关闭三枚圆形玻璃按钮
        Column() {
          Row({ space: 5 }) {
            Text(this.session.number.length > 0 ? this.session.number : this.session.title)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F5FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            this.MicroGlassBtn($r('sys.symbol.minus'), () => {
              this.collapse();
            })
            this.MicroGlassBtn($r('sys.symbol.arrow_counterclockwise'), () => {
              FloatBox.requestBackDetail(this.currentSession());
            })
            this.MicroGlassBtn($r('sys.symbol.xmark'), () => {
              FloatBox.requestClose();
            })
          }
          .width('100%')
          .padding({ left: 8, right: 6, top: 6, bottom: 8 })
          .linearGradient({ angle: 180, colors: [['#B309070B', 0.0], ['#0009070B', 1.0]] })

          Blank()

          // 右下角放大全屏圆形玻璃键
          Row() {
            Blank()
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.full_screen'))
                .fontSize(12)
                .fontColor(['#F2FFFFFF'])
            }
            .width(26)
            .height(26)
            .borderRadius(13)
            .backgroundColor('#99100D11')
            .border({ width: 0.6, color: '#3DFFFFFF' })
            .onClick(() => {
              FloatBox.requestExpand(this.currentSession());
            })
          }
          .width('100%')
          .padding({ left: 8, right: 7, bottom: 9 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)

        // 中央 40×40 丝绒玻璃播放/暂停圆钮
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(17)
            .fontColor(['#FFFFFF'])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Theme.accentAlpha(0.32))
        .backdropBlur(18)
        .border({ width: 0.85, color: Theme.accentAlpha(0.75) })
        .shadow({ radius: 14, color: Theme.accentAlpha(0.45), offsetY: 2 })
        .onClick(() => {
          this.togglePlay();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#3309070B')
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.controlsOn && !this.collapsed && !this.pipActive ? Visibility.Visible : Visibility.None)

      // 底部极细 2.5vp 蔷薇渐变进度条（非折叠态常驻显示）
      Column() {
        Blank()
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(2.5)
            .backgroundColor('#38FFFFFF')
          Row()
            .width(`${Math.round(this.progRatio * 1000) / 10}%`)
            .height(2.5)
            .linearGradient(Theme.ctaGradient())
        }
        .width('100%')
        .height(2.5)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.collapsed || this.pipActive ? Visibility.None : Visibility.Visible)

      // 折叠态贴边液态玻璃耳标（常驻，只切 visibility）
      Column({ space: 6 }) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(4)
          .linearGradient(Theme.ctaGradient())
          .shadow({ radius: 8, color: Theme.accentAlpha(0.75), offsetY: 0 })
        SymbolGlyph(this.snappedLeft ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left_2'))
          .fontSize(13)
          .fontColor(['#E6FFFFFF'])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#EB141016')
      .backdropBlur(24)
      .visibility(this.collapsed && !this.pipActive ? Visibility.Visible : Visibility.None)
      .onClick(() => {
        this.expandFromCollapsed();
      })
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
