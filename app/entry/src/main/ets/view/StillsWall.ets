import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';

/**
 * 剧照瀑布流。
 *
 * 详情页原来是一行 190x107 的横滑条：剧照里混着 16:9 截图和竖版海报，塞进同一个
 * 横框只能 Cover 裁切，竖版就成了「砍头照」。这里改成瀑布流 —— 每张图按自己的
 * 宽高比定高，横的铺满一列、竖的成一条，高低错落，反而比整齐排列更像照片墙。
 *
 * **列数是可调的**（2.5.1.18 起，1–4 列，默认 2）：`Personalize` 里的 `ui_still_cols`，
 * 双指张开放大（列变少）、捏合变密（列变多）。三处瀑布流（抽卡墙 / 演员盲盒 /
 * 影片剧照）走的都是这一个组件，所以**改这里就等于三处一起有了**，没有第二份实现。
 *
 * 比例优先用服务端下发的 ratios（img_dims 缓存，命中就准）；没量过时值为 0，
 * 先按 3:2 占位，等 Image.onComplete 拿到真实尺寸再重排一次。重排做了 180ms 合并，
 * 否则十来张图陆续加载完会反复跳位。
 *
 * 张数不截断：剧照本来就不多（详情页上限 12、演员页 10），直接往下铺，
 * 用户顺着页面下滑就全看到了 —— 不需要「+N 张」这种要再点一次的中间态。
 */

/** 列间距，和页面里其它卡片间距保持一致。 */
const COL_GAP: number = 8;
/** 服务端没量过、图片也还没加载完时的占位比例（绝大多数剧照是 3:2 横图）。 */
const FALLBACK_RATIO: number = 1.5;
/** 比例兜底区间：超长竖条会一张吃掉一屏，超宽横条同理，两头都收一收。 */
const MIN_RATIO: number = 0.42;
const MAX_RATIO: number = 2.8;
/** 尺寸合并窗口。 */
const SETTLE_MS: number = 180;
/** 心形：已喜欢 / 未喜欢。已喜欢用暖粉，在任意画面上都看得清。 */
const LIKE_ON: string = '#FF6B93';
const LIKE_OFF: string = '#FFFFFF';

@Component
export struct StillsWall {
  @Prop @Watch('onInputChange') urls: string[] = [];
  @Prop @Watch('onInputChange') ratios: number[] = [];
  /** 点第几张（原始下标）。 */
  onPick: (index: number) => void = (index: number) => {};
  /** 是否给每张图叠心形（喜欢功能）；false = 纯看图墙，行为和以前一样。 */
  @Prop showLike: boolean = false;
  /** 与 urls 等长：这一张是否已被喜欢。 */
  @Prop liked: boolean[] = [];
  /** 点心形（不会触发 onPick：小图标自己吃掉点击）。 */
  onLike: (index: number) => void = (index: number) => {};
  /** 与 urls 等长：这一张是不是「我自己截的帧」。是的话左下角标一下。 */
  @Prop mined: boolean[] = [];

  /** 列数：订阅全局值，设置页或捏合改完这里立刻重排。 */
  @StorageProp('amaneStillCols') @Watch('onColsChange') stillCols: number = 2;

  /** 每一列装哪些下标（按下标顺序贪心填最短的那列）。 */
  @State buckets: number[][] = [];
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

  /** 设置页改了列数 / 在别的瀑布流上捏过：同一页里的墙立刻跟着变。 */
  onColsChange(): void {
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
   * 贪心分列：按顺序把下一张丢给当前最矮的那列。
   * 高度统一用「列宽」做单位（1 / 比例），不需要知道真实像素宽度。
   * 单列时就是一个普通长列表，四列时是缩略图联系表 —— 同一套代码。
   */
  private relayout(): void {
    const n: number = this.urls.length;
    const cols: number = Personalize.clampStills(this.stillCols);
    const buckets: number[][] = [];
    const heights: number[] = [];
    for (let c = 0; c < cols; c++) {
      buckets.push([]);
      heights.push(0);
    }
    for (let i = 0; i < n; i++) {
      const h: number = 1 / this.ratioAt(i);
      let pick: number = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[pick] - 0.0001) {
          pick = c;
        }
      }
      buckets[pick].push(i);
      heights[pick] += h;
    }
    this.buckets = buckets;
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
    Stack({ alignContent: Alignment.TopEnd }) {
      // 图片自己一层、且整块可点：嵌套滚动里只绑 Image 时偶发只命中内容区，
      // 点了像没反应。心形是和它并列的另一层，点♥不会连带触发看图。
      Stack({ alignContent: Alignment.BottomStart }) {
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

        // 「我截的帧」标记（用户第 4 条）：刮削剧照和我自己截的必须一眼能分开。
        if (i < this.mined.length && this.mined[i]) {
          Row({ space: 3 }) {
            Text('◎')
              .fontSize(8)
              .fontColor('#FFD06B')
            Text('我截的')
              .fontSize(8)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor('#A6000000')
          .borderRadius(6)
          .margin({ left: 6, bottom: 6 })
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .onClick(() => {
        this.onPick(i);
      })

      if (this.showLike) {
        // 心形只在需要时叠上去：详情页 / 我的喜爱有，抽卡墙没有。
        Text(i < this.liked.length && this.liked[i] ? '♥' : '♡')
          .fontSize(15)
          .fontColor(i < this.liked.length && this.liked[i] ? LIKE_ON : LIKE_OFF)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .borderRadius(13)
          .backgroundColor('#59000000')
          .margin({ top: 6, right: 6 })
          .onClick(() => {
            this.onLike(i);
          })
      }
    }
    .width('100%')
  }

  build() {
    Row({ space: COL_GAP }) {
      ForEach(this.buckets, (col: number[], ci: number) => {
        Column({ space: COL_GAP }) {
          ForEach(col, (i: number) => {
            this.tile(i);
          }, (i: number) => `still-c${ci}-${i}`)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }, (col: number[], ci: number) => `still-col-${ci}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
      Personalize.zoomStills(event.scale);
    }))
  }
}
