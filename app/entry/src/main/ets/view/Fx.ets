/**
 * 沉浸光效（2.6.1.14）：光晕 `GlowOrb` + 粒子 `ParticleField`。
 *
 * 为什么单独一个文件：这套东西要在首页大图、详情页封面、启动页、底栏四处复用，
 * 抄四遍就会出现「首页粒子密、详情页粒子稀」这种不一致，调参时还要改四处。
 * 只有两个组件、一个强度偏好，参数全在调用处传。
 *
 * 三条硬约束（改之前先读）：
 * 1. **不许压住文字**。光晕只铺在图片/底色上，粒子的 alpha 峰值也只有 0.5 左右；
 *    任何压在标题、按钮上的光效都会让「晚上躺着看」变得刺眼。
 * 2. **必须能关**。`Personalize` 的 `amaneFx` 0/1/2 = 关/轻/强，页面用 `if` 整块拿掉；
 *    组件自己不判断「跳过渲染」，靠调用方 `if`，这样关掉时连定时器一起销毁。
 * 3. **必须有 `hitTestBehavior(None)`**。光效铺满整块区域，不吃手势，
 *    否则大图轮播的左右滑、播放按钮的点击都会被吃掉。
 *
 * 粒子为什么用 Canvas 而不是堆 `Circle` 组件：一屏二十多个圆，用组件写就是二十多个
 * 节点每帧改 `position`，布局层每帧重算一遍；Canvas 只重绘一块画布，节点数恒定为 1。
 * 帧率取 25fps（40ms），一张 430vp 高的图上看不出差别，耗电差一截。
 */
import { Theme } from '../common/Theme';

export const FX_OFF: number = 0;
export const FX_SOFT: number = 1;
export const FX_FULL: number = 2;

/**
 * 光效预算（2.6.1.18）：粒子是唯一持续耗电的部分，所以给它两个「暂时闭嘴」的开关。
 *
 * - `KEY_FX_SCROLL`：正在滚动 → 1，停手 420ms 后自己归 0（`markScroll()` 维护）。
 *   滚动时每帧重绘 Canvas 会和列表合成抢主线程，掉帧感比粒子本身明显得多。
 * - `KEY_FX_LOW`：低电量 / App 不可见 → 1。这个由页面生命周期与电量决定，
 *   不自动恢复，谁置的谁清。
 *
 * 两个开关都走 AppStorage：调用方（首页列表、详情页滚动区）只要在 `onScroll` 里
 * 喊一句 `markScroll()`，所有页面的粒子一起停下，不用把状态一层层往下传 prop。
 */
export const KEY_FX_SCROLL: string = 'amaneFxScroll';
export const KEY_FX_LOW: string = 'amaneFxLow';

let scrollTimer: number = -1;

/** 滚动中喊一句：粒子暂停，停手 420ms 后恢复。 */
export function markScroll(): void {
  AppStorage.setOrCreate<number>(KEY_FX_SCROLL, 1);
  if (scrollTimer >= 0) {
    clearTimeout(scrollTimer);
  }
  scrollTimer = setTimeout(() => {
    scrollTimer = -1;
    AppStorage.setOrCreate<number>(KEY_FX_SCROLL, 0);
  }, 420);
}

/** 低电量 / 不可见时整体降档（1 = 粒子静止）。 */
export function setFxLow(off: boolean): void {
  AppStorage.setOrCreate<number>(KEY_FX_LOW, off ? 1 : 0);
}

/** 粒子：位置、半径、速度、基础透明度、相位（让每颗粒子的呼吸/摆动不同步）。 */
interface Mote {
  x: number;
  y: number;
  r: number;
  vx: number;
  vy: number;
  a: number;
  ph: number;
}

/** `#RRGGBB` / `#AARRGGBB` → [r,g,b]；读不出来就当白色，不让一处脏数据把粒子画成黑块。 */
function rgbOf(hex: string): number[] {
  let h: string = hex;
  if (h.length === 9) {
    h = `#${h.substring(3)}`;
  }
  if (h.length !== 7 || h.charAt(0) !== '#') {
    return [255, 255, 255];
  }
  const r: number = parseInt(h.substring(1, 3), 16);
  const g: number = parseInt(h.substring(3, 5), 16);
  const b: number = parseInt(h.substring(5, 7), 16);
  if (r !== r || g !== g || b !== b) {
    return [255, 255, 255];
  }
  return [r, g, b];
}

/**
 * 一团柔光：径向渐变从中心往外淡到全透明。
 *
 * `size` 是外接正方形边长（vp），实际看得见的核心只有它的三分之一左右 ——
 * 径向渐变的边缘本来就散，写小了会显得是一块「圆饼」。
 * `breath` 打开时用 2.8–3.6 秒的呼吸，幅度只到 62%，再大就像呼吸灯了。
 */
@Component
export struct GlowOrb {
  @Prop color: string = '#FFFFFF';
  @Prop diameter: number = 220;
  @Prop alpha: number = 0.32;
  @Prop breath: boolean = true;
  @Prop period: number = 3200;
  @State private phase: number = 1;
  private timer: number = -1;

  aboutToAppear(): void {
    if (!this.breath) {
      return;
    }
    this.timer = setInterval(() => {
      // 来回切：每次变化都走下面那条 3.x 秒的 animation，看起来就是缓慢呼吸
      this.phase = this.phase > 0.9 ? 0.62 : 1;
    }, this.period);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Column()
      .width(this.diameter)
      .height(this.diameter)
      .radialGradient({
        center: ['50%', '50%'],
        radius: this.diameter / 2,
        colors: [
          [Theme.alphaOf(this.color, this.alpha), 0.0],
          [Theme.alphaOf(this.color, this.alpha * 0.55), 0.35],
          [Theme.alphaOf(this.color, this.alpha * 0.16), 0.68],
          [Theme.alphaOf(this.color, 0), 1.0]
        ]
      })
      .opacity(this.phase)
      .animation({ duration: this.period, curve: Curve.EaseInOut })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 飘浮微尘：像放映厅里被光束照亮的那层浮尘，缓慢往上飘。
 *
 * `count` 建议 14–26：大图 22、封面 12、启动页 18。再多不会更「高级」，
 * 只会让视线一直跟着粒子跑，反而看不清标题。
 * `alpha` 是峰值，实际每颗按相位在 `alpha*0.35 ~ alpha` 之间波动。
 */
@Component
export struct ParticleField {
  @Prop count: number = 18;
  @Prop color: string = '#FFFFFF';
  @Prop alpha: number = 0.5;
  /** 漂移倍率：0.6 很慢（启动页），1.0 正常（大图）。 */
  @Prop drift: number = 1;
  /** 滚动 / 低电时整块暂停重绘（见文件头的「光效预算」）。 */
  @StorageProp('amaneFxScroll') private scrollBusy: number = 0;
  @StorageProp('amaneFxLow') private lowPower: number = 0;
  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private motes: Mote[] = [];
  private timer: number = -1;
  private w: number = 0;
  private h: number = 0;

  aboutToAppear(): void {
    this.spawn();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 按当前画布尺寸撒一遍粒子；尺寸未知（0）时先按 360×430 估，`onReady` 里会重撒。 */
  private spawn(): void {
    const w: number = this.w > 4 ? this.w : 360;
    const h: number = this.h > 4 ? this.h : 430;
    const out: Mote[] = [];
    const n: number = this.count < 0 ? 0 : this.count;
    for (let i = 0; i < n; i++) {
      const mote: Mote = {
        x: Math.random() * w,
        y: Math.random() * h,
        r: 1.1 + Math.random() * 2.1,
        vx: 0.04 + Math.random() * 0.10,
        // 越小的粒子飘得越快，视觉上才有纵深
        vy: (0.18 + Math.random() * 0.42) * this.drift,
        a: 0.35 + Math.random() * 0.65,
        ph: Math.random() * 360
      };
      out.push(mote);
    }
    this.motes = out;
  }

  private frame(): void {
    const c: CanvasRenderingContext2D = this.ctx;
    if (this.w < 4 || this.h < 4) {
      return;
    }
    // 暂停只跳过「重绘」，不销毁画布：停手瞬间画面保持原样，恢复时不会闪一下
    if (this.scrollBusy === 1 || this.lowPower === 1) {
      return;
    }
    c.clearRect(0, 0, this.w, this.h);
    const rgb: number[] = rgbOf(this.color);
    for (let i = 0; i < this.motes.length; i++) {
      const m: Mote = this.motes[i];
      m.y = m.y - m.vy;
      // 横向做正弦摆动，不是直线上升：直线看着像下雪，摆动才像空气里的尘
      m.x = m.x + Math.sin((m.y + m.ph) / 34) * m.vx;
      if (m.y < -14) {
        m.y = this.h + 10;
        m.x = Math.random() * this.w;
      }
      if (m.x < -14) {
        m.x = this.w + 8;
      } else if (m.x > this.w + 14) {
        m.x = -8;
      }
      const wave: number = 0.4 + 0.6 * Math.abs(Math.sin((m.y + m.ph) / 74));
      const a: number = this.alpha * m.a * wave;
      const g: CanvasGradient = c.createRadialGradient(m.x, m.y, 0, m.x, m.y, m.r * 2.4);
      g.addColorStop(0, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a.toFixed(3)})`);
      g.addColorStop(1, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0)`);
      c.fillStyle = g;
      c.beginPath();
      c.arc(m.x, m.y, m.r * 2.4, 0, Math.PI * 2);
      c.fill();
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.w = this.ctx.width;
        this.h = this.ctx.height;
        this.spawn();
        if (this.timer >= 0) {
          clearInterval(this.timer);
        }
        this.timer = setInterval(() => {
          this.frame();
        }, 40);
        this.frame();
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
