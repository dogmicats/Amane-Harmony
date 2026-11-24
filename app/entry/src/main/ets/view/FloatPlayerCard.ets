/**
 * 全局小窗（2.8.3 液态玻璃升级）——浮在应用最上层的那块播放画面。
 *
 * 位置算法：
 *   - 用绝对定位 `position({x, y})`，坐标来自屏幕尺寸（px2vp），顶边避让状态栏（amaneTopInset + 8）；
 *   - 每次拖动夹在屏幕内，松手靠左/靠右吸附；
 *   - 根节点透明穿透（HitTestMode.Transparent），不吞下面页面的触摸。
 *
 * 铁律：FloatSurface 内的 XComponent 全程常驻、不包裹 `if`、父容器不加动画，
 * 所有叠加控件仅切 visibility，绝不打断 mpv 画面输出。
 */
import { Player, PlayerConfig, Media, SubtitleTrack, PlayerState } from '@mpv-ohos/mpv-arkts';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { PlayHandoff, PlaySession } from '../common/PlaySession';
import { FloatBox } from '../common/FloatBox';
import { PlayerPrefs } from '../common/PlayerPrefs';
import { Store } from '../common/Store';
import { SubtitleClient } from '../common/Subtitles';
import { Theme } from '../common/Theme';

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

  private markAttached = (): void => {
    this.firstFrame = true;
    console.info('[amane] float attached, start media');
    this.openMedia();
  };

  aboutToAppear(): void {
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
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (this.progTimer >= 0) {
      clearInterval(this.progTimer);
      this.progTimer = -1;
    }
    try {
      this.player?.destroy();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] float destroy: ${e.code}`);
    }
    this.player = undefined;
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
    this.placeDefault();
  }

  private expandFromCollapsed(): void {
    this.collapsed = false;
    this.controlsOn = true;
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
        width: this.tier === 0 || this.collapsed ? 0.75 : 0,
        color: this.collapsed ? Theme.accentAlpha(0.45) : '#38FFFFFF'
      })
      .shadow({ radius: 22, color: '#80000000', offsetY: 6 })
      .position({ x: this.px, y: this.py })
      // 不给含 XComponent 的节点加动画，防止重建打断 mpv
      .opacity(this.dragging ? 0.78 : 1)
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
    .hitTestBehavior(HitTestMode.Transparent)
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
      .visibility(this.firstFrame || this.collapsed ? Visibility.None : Visibility.Visible)
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
        .hitTestBehavior(HitTestMode.Transparent)

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
      .hitTestBehavior(HitTestMode.Transparent)
      .visibility(this.controlsOn && !this.collapsed ? Visibility.Visible : Visibility.None)

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
      .visibility(this.collapsed ? Visibility.None : Visibility.Visible)

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
      .visibility(this.collapsed ? Visibility.Visible : Visibility.None)
      .onClick(() => {
        this.expandFromCollapsed();
      })
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
