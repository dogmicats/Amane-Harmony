/**
 * 全局小窗（2.6.2.x）——浮在应用最上层的那块播放画面。
 *
 * 位置算法（2.6.1.25 重写，修「动一下就飞走 + 挡住详情页操作」）：
 *   - 用**绝对定位** `position({x, y})`，坐标来自屏幕尺寸（px2vp），不再靠父容器对齐 + offset；
 *   - 每次拖动都**夹在屏幕内**，松手只做「靠左/靠右」吸附，不再用写死的 ±360；
 *   - 根节点就是卡片本身（不铺满全屏），所以它不会吃掉页面的触摸。
 *
 * 两档：
 *   - `小窗` 208vp 16:9：**详情页发起的浮窗只允许这一档**（`compact = true`，双击不换档）；
 *   - `宽条` 横向拉满：只在允许换档的场景出现，纵向可拖（水平已拉满）。
 *
 * 三按钮：放大（全屏接着看）/ 回详情页（回这部片接着播）/ ×（停播留在当前页）。
 */
import { Player, PlayerConfig, Media, SubtitleTrack } from '@mpv-ohos/mpv-arkts';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { PlayHandoff, PlaySession } from '../common/PlaySession';
import { FloatBox } from '../common/FloatBox';
import { PlayerPrefs } from '../common/PlayerPrefs';
import { Store } from '../common/Store';
import { SubtitleClient } from '../common/Subtitles';

const CARD_W: number = 208;
const EDGE: number = 12;
/**
 * 贴底留白。
 *
 * 实测校准（CMM-AL10，1320×2848、密度 3.375）：底栏图标文字在 y=2639–2675，
 * 底栏容器顶边约 2579px；`BOTTOM_SAFE=68` 时小窗底边落在 2750px，**压住整个底栏**，
 * 「收藏」点不到。改成 125 后底边≈2530px，正好停在底栏上方。
 *
 * 注意：`display.getDefaultDisplaySync().height` 比窗口实际高度多出约 40vp，
 * 所以这里不能再按「底栏 56vp」去算，否则会偏下一截。
 */
const BOTTOM_SAFE: number = 125;

/**
 * 画面层单独一个组件。
 *
 * 目的：把 XComponent 和父组件的状态彻底隔开 —— 父组件（控件显隐、档位、拖动）
 * 每次 build 都不会重建这里，surface 因此不会被换掉。mpv 一收到 surface 销毁就直接停
 * （不是暂停），所以这一层必须绝对稳定。传进来的 `player` / `ctrl` 全程不变，
 * 回调用类字段箭头函数（每次 build 是同一个引用，不会触发子组件刷新）。
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
  /** 只做小窗（详情页发起）：双击不换档、也不做宽条。由 `session.compact` 带进来。 */
  private compactOnly: boolean = true;
  /** 0 = 小窗，1 = 宽条。 */
  @State tier: number = 0;
  @State controlsOn: boolean = true;
  @State playing: boolean = false;
  @State firstFrame: boolean = false;
  @State dragging: boolean = false;
  /** 已经起过播（onReady 与 attach 两条路都可能调 openMedia，只认第一次）。 */
  private opened: boolean = false;
  /** 拖动起点（px/py 的基线）：`GestureEvent.offsetX/Y` 是相对起点的累计值。 */
  private startPx: number = 0;
  private startPy: number = 0;
  /** 收起成小条（点 × 之后）：**不销毁播放**，点小条能恢复 —— 手滑点到 × 不该丢播放。 */
  @State collapsed: boolean = false;
  /** 左上角坐标（vp），绝对定位用。 */
  @State px: number = 0;
  @State py: number = 0;
  private winW: number = 360;
  private winH: number = 720;
  private xc: XComponentController = new XComponentController();
  private player: Player | undefined = undefined;
  private hideTimer: number = -1;
  /** 传给 FloatSurface 的回调：类字段箭头函数，引用恒定，不会触发画面层重建。 */
  private markAttached = (): void => {
    this.firstFrame = true;
    // 关键（2.6.1.41）：**不能等 Player 的 onReady**。
    // 真机日志里 `NativePlayer SetClassRefs` 全程只出现一次 —— 浮窗第二次 `new Player()`
    // 复用同一个 native 对象，`onReady` 不会再回调，于是 openMedia 永远不执行，
    // 表现就是「小窗出来了、黑的、也没声音」。surface 一绑好就主动起播。
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
    this.armHideTimer();
  }

  aboutToDisappear(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    try {
      this.player?.destroy();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] float destroy: ${e.code}`);
    }
    this.player = undefined;
  }

  private cardW(): number {
    if (this.collapsed) {
      return 64;
    }
    return this.tier === 0 ? CARD_W : this.winW;
  }

  private cardH(): number {
    if (this.collapsed) {
      return 40;
    }
    return this.cardW() * 9 / 16;
  }

  /** 默认落点：小窗贴右下（避开底部导航），宽条贴顶下方 92vp。 */
  private placeDefault(): void {
    if (this.tier === 0) {
      this.px = Math.max(EDGE, this.winW - CARD_W - EDGE);
      this.py = Math.max(EDGE, this.winH - this.cardH() - BOTTOM_SAFE);
    } else {
      this.px = 0;
      this.py = 92;
    }
  }

  /** 夹在屏幕内（宽条档 x 恒为 0）。 */
  private clampPos(): void {
    const w: number = this.cardW();
    const h: number = this.cardH();
    const maxX: number = Math.max(0, this.winW - w);
    const maxY: number = Math.max(0, this.winH - h);
    if (this.tier === 1) {
      this.px = 0;
    } else if (this.px < EDGE) {
      this.px = EDGE;
    } else if (this.px > maxX - EDGE) {
      this.px = Math.max(EDGE, maxX - EDGE);
    }
    if (this.py < EDGE) {
      this.py = EDGE;
    } else if (this.py > maxY - EDGE) {
      this.py = Math.max(EDGE, maxY - EDGE);
    }
  }

  /** 松手吸附：小窗档只吸左右，纵向停在原处。 */
  private snapX(): void {
    if (this.tier === 1) {
      return;
    }
    const maxX: number = Math.max(0, this.winW - this.cardW());
    this.px = this.px + this.cardW() / 2 < this.winW / 2
      ? EDGE : Math.max(EDGE, maxX - EDGE);
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
    }, 3000);
  }

  private toggleControls(): void {
    this.controlsOn = !this.controlsOn;
    if (this.controlsOn) {
      this.armHideTimer();
    }
  }

  private toggleTier(): void {
    if (this.compactOnly) {
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

  /**
   * 点 ×：**只暂停 + 收成小条，不销毁浮窗**。
   *
   * 卡片只有 208×117，右上角那个 × 太容易手滑 —— 之前直接销毁浮窗，
   * 用户体感就是「点一下小窗，播放没了」（2026-11-13）。收成小条后点一下就能回来。
   */
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

  /** 交接出去之前，把当前位置写回会话。 */
  private currentSession(): PlayHandoff {
    const h: PlayHandoff = this.session;
    const p: Player | undefined = this.player;
    if (p !== undefined) {
      try {
        const st = p.state;
        if (st !== undefined && st !== null && st.position > 0) {
          h.pos = st.position;
        }
      } catch (err) {
        console.info(`[amane] float pos: ${JSON.stringify(err)}`);
      }
    }
    return h;
  }

  build() {
    // 外面这层全屏 Stack 是**为了不吃掉整页触摸**（2.6.1.41，真机反馈「整页动不了」）：
    // 浮层挂在 OverlayManager 上时，承载节点默认按整屏算，空白区域会把点击/滚动全吞掉。
    // `HitTestMode.Transparent` = 这一层自己不参与命中，但**子节点照常**响应，
    // 所以卡片上的拖动/单击/按钮都还在，卡片以外的区域直接透给下面的页面。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardBody()
      }
      .width(this.cardW())
      .height(this.cardH())
      .borderRadius(this.tier === 0 ? 12 : 0)
      .clip(true)
      .backgroundColor('#000000')
      .shadow({ radius: 18, color: '#40000000', offsetY: 4 })
      // 绝对定位 + 夹边界：位置只由 px/py 决定，父容器不参与布局
      .position({ x: this.px, y: this.py })
      // 拖动时的半透明**不加 animation**：给含 XComponent 的节点跑属性动画，
      // 每帧都会重排/重建，真机上直接把 mpv 的画面输出打断（点一下停播就是这么来的）。
      .opacity(this.dragging ? 0.72 : 1)
      .gesture(
        GestureGroup(GestureMode.Parallel,
          // 拖动阈值放到 16vp：8vp 时「轻点一下」也会被判成拖动，
          // 于是每点一次都在改位置、改尺寸，画面层跟着重建（点一下就停播）。
          PanGesture({ fingers: 1, distance: 16 })
            .onActionStart(() => {
              this.dragging = true;
              // 记起点：`ev.offsetX/Y` 是**相对手势起点**的累计位移，不是每帧增量。
              // 之前写成 `this.px += ev.offsetX`，等于把累计值一帧帧叠上去，
              // 手指走 100vp 小窗会跑出几百 vp —— 这就是「拖动不跟手」。
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
            this.controlsOn = true;
            this.armHideTimer();
          }),
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => {
            this.toggleTier();
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
    // 关键：自身不参与命中（否则整页的点击/滚动都会被这层吞掉），子节点照常响应
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
      // 占位（首帧前盖一层）：**常驻树里**，只切可见性 ——
      // 用 `if` 会让兄弟节点整棵重建，XComponent 跟着重建就把 mpv 的画面输出打断了（点一下停播）。
      Column() {
        Text(this.session.number.length > 0 ? this.session.number : '准备播放')
          .fontSize(11)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#000000')
      .visibility(this.firstFrame ? Visibility.None : Visibility.Visible)
      .hitTestBehavior(HitTestMode.None)

      // 控件层**常驻**树里，只切 visibility —— 绝对不能用 `if`。
      // 用 `if` 时点一下画面 = 增删一个兄弟节点 → ArkUI 重建这一层 → XComponent 跟着换 surface，
      // mpv 收到 surface 销毁就直接停（用户反馈的就是「点一下真的停了，不是暂停」）。
      Column() {
        Row({ space: 6 }) {
            Text(this.session.number.length > 0 ? this.session.number : this.session.title)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('–')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                // 收起，不是关闭（关闭在下面那一排，需要明确点）
                this.collapse();
              })
          }
          .width('100%')
          .padding({ left: 8, right: 4, top: 4 })

          Blank()

          Row({ space: 6 }) {
            Text(this.playing ? '暂停' : '播放')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#66000000')
              .borderRadius(10)
              .onClick(() => {
                this.togglePlay();
              })
            Blank()
            Text('放大')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#66000000')
              .borderRadius(10)
              .onClick(() => {
                FloatBox.requestExpand(this.currentSession());
              })
            Text('回详情页')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#66FFFFFF')
              .borderRadius(10)
              .onClick(() => {
                FloatBox.requestBackDetail(this.currentSession());
              })
            Text('关闭')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#88000000')
              .borderRadius(10)
              .onClick(() => {
                FloatBox.requestClose();
              })
          }
          .width('100%')
          .padding({ left: 8, right: 8, bottom: 6 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        // 控件层铺满整张卡，必须设 Transparent：否则单击画面全部被它吃掉，
        // 「点一下只显隐控件」变成了「点了没反应」（真机反馈）。
        .hitTestBehavior(HitTestMode.Transparent)
        .visibility(this.controlsOn ? Visibility.Visible : Visibility.None)

      // 控件收起时留一个「把手」：单击只收控件、不关浮窗，但画面若是黑的，
      // 光靠猜看不见浮窗在哪 —— 有个小圆点就知道它还在、点回来就能操作（2026-11-13 反馈）。
      // 同样是常驻 + visibility，避免点按时动结构。
      Text('⋯')
        .fontSize(12)
        .fontColor('#D9FFFFFF')
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .backgroundColor('#59000000')
        .borderRadius(12)
        .margin({ right: 6, bottom: 6 })
        .align(Alignment.BottomEnd)
        .visibility(this.controlsOn ? Visibility.None : Visibility.Visible)
        .onClick(() => {
          if (this.collapsed) {
            this.expandFromCollapsed();
          } else {
            this.toggleControls();
          }
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
