import { Theme } from '../../common/Theme';
import { Store } from '../../common/Store';
import { StillsWall } from '../../view/StillsWall';
import { StillFeed, openStill } from './GachaFeed';
import { GachaStill } from './GachaTypes';
import { GachaSwitch } from './GachaSwitch';

/**
 * 抽卡墙：列表页「抽卡模式」的全部内容（标题条 + 瀑布流 + 换一批）。
 *
 * 刻意**不含 Scroll** —— 由页面决定怎么滚：
 *   - 列表页里替换掉网格：`Scroll() { GachaWall(...) }.layoutWeight(1)`
 *   - 详情页里塞进 List 的某一项：直接摆，不套滚动（套了会抢手势）
 *
 * 数据与轮换逻辑在 StillFeed（纯逻辑类），这里只负责渲染与状态，
 * 所以以后调「一次抓多少」「怎么随机」只改 GachaFeed，所有列表页一起变。
 */
@Component
export struct GachaWall {
  /** tag / series / studio / publisher / director / user_tag / library / favorite / all */
  @Prop @Watch('onScopeChange') scope: string = 'all';
  @Prop @Watch('onScopeChange') scopeId: number = 0;
  /** 文案里用的范围名（标签名 / 库名 / 「我的收藏」…）。 */
  @Prop label: string = '';
  /** 标题前缀，演员页传「盲盒」，列表页用默认的「抽卡」。 */
  @Prop heading: string = '抽卡';
  /** 一轮摆几张；0 = 跟随设置页里的值。 */
  @Prop count: number = 0;
  /**
   * 追加查询串（不带前导 &）。给「没有实体 id 的范围」传筛选条件：
   * 共演筛选结果页传 `female_n=1,2&exclude_director_id=130` 之类，
   * 条件变了（字符串变了）就自动重抽。
   */
  @Prop @Watch('onScopeChange') extra: string = '';
  /** 抽卡开关：由页面持有，放在标题行右端 —— 开和关都在同一侧。 */
  @Prop gachaOn: boolean = true;
  onToggleGacha: (v: boolean) => void = (v: boolean) => {};

  @State stills: GachaStill[] = [];
  @State urls: string[] = [];
  @State ratios: number[] = [];
  @State loading: boolean = true;
  /** 空墙 / 出错的人话说明；空串表示正常。 */
  @State note: string = '';
  /** 这个范围内有多少部片有剧照；-1 = 未知。 */
  @State candidates: number = -1;

  private feed: StillFeed | undefined = undefined;
  private busy: boolean = false;

  aboutToAppear(): void {
    this.boot();
  }

  /** 页面换了范围（同一个 GachaWall 复用，比如切换标签）时重来一遍。 */
  onScopeChange(): void {
    this.boot();
  }

  private boot(): void {
    const n: number = this.count > 0 ? this.count : Store.I.gachaCount;
    if (this.feed === undefined) {
      this.feed = new StillFeed(this.scope, this.scopeId, n, this.extra);
    } else {
      this.feed.reset(this.scope, this.scopeId, n, this.extra);
    }
    this.stills = [];
    this.urls = [];
    this.ratios = [];
    this.note = '';
    this.loading = true;
    this.load(false);
  }

  /**
   * @param more true = 「换一批」：优先用本地池子，瞬时出图；
   *             false = 首次进入，必须重新拉。
   */
  private async load(more: boolean): Promise<void> {
    const f: StillFeed | undefined = this.feed;
    if (f === undefined || this.busy) {
      return;
    }
    this.busy = true;
    if (!more) {
      this.loading = true;
    }
    const list: GachaStill[] = await f.next(more);
    this.candidates = f.candidates;
    if (list.length === 0) {
      if (f.error.length > 0) {
        this.note = f.error;
      } else if (f.candidates === 0) {
        this.note = this.label.length > 0
          ? `「${this.label}」里还没有剧照`
          : '这个范围里还没有剧照';
      } else {
        this.note = '这次没抽到剧照，换一批试试';
      }
    } else {
      const urls: string[] = [];
      const ratios: number[] = [];
      for (let i = 0; i < list.length; i++) {
        urls.push(list[i].url);
        ratios.push(list[i].ratio);
      }
      this.stills = list;
      this.urls = urls;
      this.ratios = ratios;
      this.note = '';
    }
    this.loading = false;
    this.busy = false;
  }

  @Builder
  Header() {
    Row({ space: 6 }) {
      Text(this.heading)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
      Text('剧照')
        .fontSize(9)
        .fontColor(Theme.ACCENT)
        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(4)
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
      if (this.loading) {
        Text('搜索中…')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      } else if (this.stills.length > 0) {
        Text(`${this.stills.length} 张`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      if (this.onToggleGacha !== undefined) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.onToggleGacha(v);
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Placeholder() {
    Column({ space: 8 }) {
      if (this.loading) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(Theme.ACCENT)
        Text('正在翻剧照…')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      } else {
        Text('✦')
          .fontSize(26)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.note.length > 0 ? this.note : '这里还没有剧照')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
        Text('再试一次')
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(14)
          .onClick(() => {
            this.load(true);
          })
      }
    }
    .width('100%')
    .height(180)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column({ space: 10 }) {
      this.Header()

      if (this.stills.length > 0) {
        // 和影片详情页 / 演员页同一套瀑布流：横竖版各按原比例占位，不裁构图
        StillsWall({
          urls: this.urls,
          ratios: this.ratios,
          onPick: (i: number) => {
            if (i >= 0 && i < this.stills.length) {
              openStill(this.stills[i]);
            }
          }
        })
      } else {
        this.Placeholder()
      }

      if (this.stills.length > 0) {
        Column({ space: 6 }) {
          Text('❖ 换一批')
            .fontSize(12)
            .fontColor(Theme.TEXT)
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .backgroundColor(this.loading ? Theme.CARD_HI : Theme.CARD)
            .borderRadius(16)
            .onClick(() => {
              this.load(true);
            })
          Text(this.candidates > 0
            ? `范围里 ${this.candidates} 部片有剧照 · 点图看详情`
            : '点图看详情')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
