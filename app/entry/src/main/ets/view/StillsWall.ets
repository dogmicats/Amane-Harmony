import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 剧照瀑布流。
 *
 * 详情页原来是一行 190x107 的横滑条：剧照里混着 16:9 截图和竖版海报，塞进同一个
 * 横框只能 Cover 裁切，竖版就成了「砍头照」。这里改成两列瀑布流 —— 每张图按自己的
 * 宽高比定高，横的铺满一列、竖的成一条，高低错落，反而比整齐排列更像照片墙。
 *
 * 比例优先用服务端下发的 ratios（img_dims 缓存，命中就准）；没量过时值为 0，
 * 先按 3:2 占位，等 Image.onComplete 拿到真实尺寸再重排一次。重排做了 180ms 合并，
 * 否则十来张图陆续加载完会反复跳位。
 *
 * 张数不截断：剧照本来就不多（详情页上限 12、演员页 10），直接往下铺，
 * 用户顺着页面下滑就全看到了 —— 不需要「+N 张」这种要再点一次的中间态。
 */

/** 两列间距，和页面里其它卡片间距保持一致。 */
const COL_GAP: number = 8;
/** 服务端没量过、图片也还没加载完时的占位比例（绝大多数剧照是 3:2 横图）。 */
const FALLBACK_RATIO: number = 1.5;
/** 比例兜底区间：超长竖条会一张吃掉一屏，超宽横条同理，两头都收一收。 */
const MIN_RATIO: number = 0.42;
const MAX_RATIO: number = 2.8;
/** 尺寸合并窗口。 */
const SETTLE_MS: number = 180;

@Component
export struct StillsWall {
  @Prop @Watch('onInputChange') urls: string[] = [];
  @Prop @Watch('onInputChange') ratios: number[] = [];
  /** 点第几张（原始下标）。 */
  onPick: (index: number) => void = (index: number) => {};

  @State left: number[] = [];
  @State right: number[] = [];
  /** 客户端实测比例，下标与 urls 对齐，0 = 还没量到。 */
  @State measured: number[] = [];
  private pending: Map<number, number> = new Map<number, number>();
  private timer: number = -1;

  aboutToAppear(): void {
    this.relayout();
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  /** 详情页二次刷新（缓存先渲染、接口随后到）时重新分列。 */
  onInputChange(): void {
    this.measured = [];
    this.pending.clear();
    this.relayout();
  }

  /** 渲染用比例：实测 > 服务端 > 兜底，最后夹在兜底区间里。 */
  private ratioAt(i: number): number {
    let r: number = 0;
    if (i < this.measured.length && this.measured[i] > 0) {
      r = this.measured[i];
    } else if (i < this.ratios.length && this.ratios[i] > 0) {
      r = this.ratios[i];
    }
    if (!(r > 0)) {
      r = FALLBACK_RATIO;
    }
    return Math.min(MAX_RATIO, Math.max(MIN_RATIO, r));
  }

  /**
   * 贪心分列：按顺序把下一张丢给当前更矮的那列。
   * 高度统一用「列宽」做单位（1 / 比例），不需要知道真实像素宽度。
   */
  private relayout(): void {
    const n: number = this.urls.length;
    const l: number[] = [];
    const r: number[] = [];
    let hl: number = 0;
    let hr: number = 0;
    for (let i = 0; i < n; i++) {
      const h: number = 1 / this.ratioAt(i);
      if (hl <= hr) {
        l.push(i);
        hl += h;
      } else {
        r.push(i);
        hr += h;
      }
    }
    this.left = l;
    this.right = r;
  }

  /** 图片加载完给的原始尺寸。和服务端对不上才重排，且合并成一次。 */
  private noteSize(i: number, w: number, h: number): void {
    if (!(w > 0) || !(h > 0)) {
      return;
    }
    const r: number = w / h;
    const known: number = i < this.ratios.length ? this.ratios[i] : 0;
    if (known > 0 && Math.abs(known - r) < 0.12) {
      return;
    }
    if (i < this.measured.length && Math.abs(this.measured[i] - r) < 0.01) {
      return;
    }
    this.pending.set(i, r);
    if (this.timer !== -1) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flushSizes();
    }, SETTLE_MS);
  }

  private flushSizes(): void {
    const m: number[] = this.measured.slice();
    while (m.length < this.urls.length) {
      m.push(0);
    }
    let changed: boolean = false;
    this.pending.forEach((v: number, k: number) => {
      if (k >= 0 && k < m.length && Math.abs(m[k] - v) > 0.01) {
        m[k] = v;
        changed = true;
      }
    });
    this.pending.clear();
    if (changed) {
      this.measured = m;
      this.relayout();
    }
  }

  @Builder
  tile(i: number) {
    Image(Store.I.img(this.urls[i]))
      .width('100%')
      .aspectRatio(this.ratioAt(i))
      .objectFit(ImageFit.Cover)
      .borderRadius(10)
      .backgroundColor(Theme.CARD)
      .onComplete((e) => {
        if (e !== undefined && e !== null) {
          this.noteSize(i, e.width, e.height);
        }
      })
      .onClick(() => {
        this.onPick(i);
      })
  }

  build() {
    Row({ space: COL_GAP }) {
      Column({ space: COL_GAP }) {
        ForEach(this.left, (i: number) => {
          this.tile(i);
        }, (i: number) => `still-l-${i}`)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: COL_GAP }) {
        ForEach(this.right, (i: number) => {
          this.tile(i);
        }, (i: number) => `still-r-${i}`)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}
