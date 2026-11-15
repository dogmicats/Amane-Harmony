/**
 * 观影日历（2.6.1.25）：365 格热力图，一眼看出「哪几个月我在看、哪几个月没碰」。
 *
 * 为什么用 Canvas 而不是 371 个 Column：371 个节点在 Tabs 里滚动时每一帧都要参与
 * 布局，中低端机直接掉帧；Canvas 只有 1 个节点，重绘一块画布不到 2ms。
 *
 * 三条约定：
 * 1. **列是周、行是星期**（和 GitHub  Contribution 图同一套读法）：左边不标文字，
 *    因为一列只有一周，标了反而挤；月份刻度放在下面。
 * 2. **强度用绝对值分档**，不按最大值归一化 —— 归一化会让「很闲的一年」看起来也很热闹，
 *    而用户想问的正是「今年到底看了多少」。四档：<30 分 / <1h / <2h / ≥2h。
 * 3. **空格用底色**（`Theme.CARD`），不留透明：透明会把面板底色透出来，整块看起来像漏了洞。
 */
import { Theme } from '../common/Theme';

/** 一天：日期 + 秒数 + 部数。只有有观看的日子才会出现。 */
export interface CalDay {
  d: string;
  s: number;
  f: number;
}

const WEEK_MS: number = 86400000;
/** 四档下限（秒）：30 分 / 1 小时 / 2 小时；超过最后一档用最亮。 */
const LEVELS: number[] = [1800, 3600, 7200];

@Component
export struct HeatCalendar {
  /** 稀疏数据：只有看过的日子。 */
  @Prop @Watch('redraw') days: CalDay[] = [];
  /** 窗口起始日 `YYYY-MM-DD`（含）。 */
  @Prop @Watch('redraw') from: string = '';
  /** 列数（周数）。53 周 = 一年多一点。 */
  @Prop cols: number = 53;
  /** 高亮色，空串用主题强调色。 */
  @Prop color: string = '';

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private w: number = 0;
  private h: number = 0;
  /** 一格边长（vp），onReady 按画布宽度算。 */
  private cell: number = 5;
  /** 画布高度：7 行格子撑满就好，多了会在下面留一块空。 */
  @State canvasH: number = 62;

  aboutToAppear(): void {
    // 画布尺寸要等布局：onReady 里取一次，再补两次重试 —— 这块挂在 Scroll 里的条件分支下，
    // 首帧的 ctx.width 可能还是 0（此时直接画会静默失败，整块看着像没渲染）。
    setTimeout(() => {
      this.syncSize();
      this.redraw();
    }, 80);
    setTimeout(() => {
      this.syncSize();
      this.redraw();
    }, 260);
  }

  private syncSize(): void {
    if (this.ctx.width > 0) {
      this.w = this.ctx.width;
    }
    if (this.ctx.height > 0) {
      this.h = this.ctx.height;
    }
  }

  onReadyDraw(): void {
    this.syncSize();
    this.redraw();
  }

  /** `#AARRGGBB` → `rgba()`：Canvas 的 fillStyle 走 CSS 口径，8 位 hex 会被当成 #RRGGBBAA。 */
  private rgba(hex: string, alpha: number): string {
    let h: string = hex;
    if (h.length === 9) {
      h = `#${h.substring(3)}`;
    }
    let r: number = 255;
    let g: number = 255;
    let b: number = 255;
    if (h.length === 7) {
      r = parseInt(h.substring(1, 3), 16);
      g = parseInt(h.substring(3, 5), 16);
      b = parseInt(h.substring(5, 7), 16);
    }
    if (r !== r || g !== g || b !== b) {
      r = 255;
      g = 255;
      b = 255;
    }
    return `rgba(${r},${g},${b},${alpha.toFixed(3)})`;
  }

  /** `days` 或 `from` 变了就重画（切范围、换口径）。 */
  redraw(): void {
    const c: CanvasRenderingContext2D = this.ctx;
    if (this.w < 40 || this.h < 20) {
      return;
    }
    c.clearRect(0, 0, this.w, this.h);
    const gap: number = 2;
    const startMs: number = this.dayMs(this.from);
    if (startMs <= 0) {
      return;
    }
    const now: number = Date.now();
    // 列数由「今天」倒推：起始日所在的周要补满，否则最后几天（也就是最近这几天，
    // 恰好是最该亮的那几格）会被挤出网格 —— 371 天按整周对齐后经常是 54 列而不是 53。
    const startDow: number = new Date(startMs).getDay();
    const firstMs: number = startMs - startDow * WEEK_MS;
    const totalDays: number = Math.floor((now - firstMs) / WEEK_MS) + 1;
    const colCount: number = Math.max(1, Math.ceil(totalDays / 7));

    const cell: number = Math.max(3, (this.w - gap * (colCount - 1)) / colCount);
    this.cell = cell;
    // 画布高度跟着格子走（7 行 + 6 个间隙），高度变化下一帧会再触发一次 onAreaChange
    const need: number = Math.round(7 * cell + 6 * gap);
    if (Math.abs(need - this.canvasH) > 1) {
      this.canvasH = need;
    }
    const base: string = this.color.length > 0 ? this.color : Theme.ACCENT;

    // 日期 → 秒数
    const secs: Map<string, number> = new Map();
    for (let i = 0; i < this.days.length; i++) {
      secs.set(this.days[i].d, this.days[i].s);
    }

    const empty: string = this.rgba(Theme.CARD_HI, 1);
    // 从起始日所在周的第一天（周日）开始铺，保证每一列是一整周
    let t: number = firstMs;

    for (let col = 0; col < colCount; col++) {
      for (let row = 0; row < 7; row++) {
        const x: number = col * (cell + gap);
        const y: number = row * (cell + gap);
        let fill: string = empty;
        if (t > now) {
          // 未来：不画（留空），否则右下角会出现一整片「没看过」的格子
        } else if (t >= startMs) {
          const key: string = this.keyOf(t);
          const s: number | undefined = secs.get(key);
          if (s !== undefined && s > 0) {
            fill = this.rgba(base, this.levelOf(s));
          }
        }
        c.fillStyle = fill;
        c.beginPath();
        c.moveTo(x + 1.5, y);
        c.lineTo(x + cell - 1.5, y);
        c.arcTo(x + cell, y, x + cell, y + 1.5, 1.5);
        c.lineTo(x + cell, y + cell - 1.5);
        c.arcTo(x + cell, y + cell, x + cell - 1.5, y + cell, 1.5);
        c.lineTo(x + 1.5, y + cell);
        c.arcTo(x, y + cell, x, y + cell - 1.5, 1.5);
        c.lineTo(x, y + 1.5);
        c.arcTo(x, y, x + 1.5, y, 1.5);
        c.closePath();
        c.fill();
        t += WEEK_MS;
      }
    }
  }

  /** 秒数 → 透明度档（0.22 / 0.42 / 0.65 / 0.92）。 */
  private levelOf(s: number): number {
    if (s < LEVELS[0]) {
      return 0.22;
    }
    if (s < LEVELS[1]) {
      return 0.42;
    }
    if (s < LEVELS[2]) {
      return 0.65;
    }
    return 0.92;
  }

  private dayMs(day: string): number {
    if (day.length !== 10) {
      return 0;
    }
    const y: number = Number(day.substring(0, 4));
    const m: number = Number(day.substring(5, 7));
    const d: number = Number(day.substring(8, 10));
    if (y < 2000 || m < 1 || m > 12 || d < 1 || d > 31) {
      return 0;
    }
    return new Date(y, m - 1, d).getTime();
  }

  private keyOf(ms: number): string {
    const dt: Date = new Date(ms);
    const m: string = `${dt.getMonth() + 1}`.padStart(2, '0');
    const d: string = `${dt.getDate()}`.padStart(2, '0');
    return `${dt.getFullYear()}-${m}-${d}`;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(this.canvasH)
      .onReady(() => {
        this.syncSize();
        this.redraw();
      })
      .onAreaChange((_old: Area, now: Area) => {
        // 尺寸真的是 0 时（首帧布局没算完）再补一次，别让整块空白
        const w: number = Number(now.width);
        const h: number = Number(now.height);
        if (w > 0 && h > 0 && (Math.abs(w - this.w) > 1 || Math.abs(h - this.h) > 1)) {
          this.w = w;
          this.h = h;
          this.redraw();
        }
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
