import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BrowseResult, DetailParams, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { PosterCard } from './PosterCard';

const PAGE_SIZE: number = 45;

export interface SortOption {
  key: string;
  label: string;
  def: string;
}

export interface FilterOption {
  key: string;
  label: string;
}

export const SORT_OPTIONS: SortOption[] = [
  { key: 'recent', label: '最近更新', def: 'desc' },
  { key: 'release', label: '发行日期', def: 'desc' },
  { key: 'score', label: '评分', def: 'desc' },
  { key: 'number', label: '番号', def: 'asc' },
  { key: 'title', label: '标题', def: 'asc' },
  { key: 'runtime', label: '时长', def: 'desc' },
  { key: 'random', label: '随机', def: 'desc' }
];

const MOSAIC_OPTIONS: FilterOption[] = [
  { key: '', label: '全部' },
  { key: 'LEAKED', label: '无码流出' },
  { key: 'CRACKED', label: '破解' },
  { key: 'NONE', label: '原版' }
];

const CTYPE_OPTIONS: FilterOption[] = [
  { key: '', label: '全部' },
  { key: 'CENSORED', label: '有码' },
  { key: 'UNCENSORED', label: '无码' },
  { key: 'FC2', label: 'FC2' },
  { key: 'AMATEUR', label: '业余' }
];

const SUB_OPTIONS: FilterOption[] = [
  { key: '', label: '全部' },
  { key: '1', label: '有字幕' },
  { key: '0', label: '无字幕' }
];

const SCORE_OPTIONS: FilterOption[] = [
  { key: '', label: '全部' },
  { key: '4.5', label: '4.5 以上' },
  { key: '4.0', label: '4.0 以上' },
  { key: '3.5', label: '3.5 以上' },
  { key: '3.0', label: '3.0 以上' }
];

const YEAR_OPTIONS: FilterOption[] = [
  { key: '', label: '全部' },
  { key: '2026', label: '2026' },
  { key: '2025', label: '2025' },
  { key: '2024', label: '2024' },
  { key: 'old', label: '2023 及更早' }
];

function sortLabelOf(key: string): string {
  for (let i = 0; i < SORT_OPTIONS.length; i++) {
    if (SORT_OPTIONS[i].key === key) {
      return SORT_OPTIONS[i].label;
    }
  }
  return '最近更新';
}

/**
 * 一组筛选 chip。
 * 必须做成子组件：@Builder 按值传参不会刷新，选中态会一直停在初始值。
 */
@Component
struct FilterChips {
  title: string = '';
  options: FilterOption[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Column({ space: 8 }) {
      Text(this.title)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (opt: FilterOption) => {
          Text(opt.label)
            .fontSize(12)
            .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onPick(opt.key);
            })
        }, (opt: FilterOption) => `${this.title}-${opt.key}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 媒体浏览网格：排序 + 筛选 + 分页。
 * 媒体库 Tab 和「全部影片」页都用它，库 id 由外部传入。
 */
@Component
export struct BrowseGrid {
  @Prop @Watch('onExternalChange') libraryId: number = 0;
  @Prop @Watch('onExternalChange') refreshKey: number = 0;

  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State sort: string = 'recent';
  @State order: string = 'desc';
  @State fMosaic: string = '';
  @State fCtype: string = '';
  @State fSub: string = '';
  @State fScore: string = '';
  @State fYear: string = '';
  @State fState: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onExternalChange(): void {
    this.reload();
  }

  private filterCount(): number {
    let n: number = 0;
    if (this.fMosaic.length > 0) {
      n++;
    }
    if (this.fCtype.length > 0) {
      n++;
    }
    if (this.fSub.length > 0) {
      n++;
    }
    if (this.fScore.length > 0) {
      n++;
    }
    if (this.fYear.length > 0) {
      n++;
    }
    if (this.fState.length > 0) {
      n++;
    }
    return n;
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`, `limit=${PAGE_SIZE}`, `sort=${this.sort}`, `order=${this.order}`
    ];
    if (this.libraryId > 0) {
      parts.push(`library_id=${this.libraryId}`);
    }
    if (this.fMosaic.length > 0) {
      parts.push(`mosaic=${this.fMosaic}`);
    }
    if (this.fCtype.length > 0) {
      parts.push(`ctype=${this.fCtype}`);
    }
    if (this.fSub.length > 0) {
      parts.push(`sub=${this.fSub}`);
    }
    if (this.fScore.length > 0) {
      parts.push(`min_score=${this.fScore}`);
    }
    if (this.fYear === 'old') {
      parts.push('year_to=2023');
    } else if (this.fYear.length > 0) {
      parts.push(`year_from=${this.fYear}`);
    }
    if (this.fState.length > 0) {
      parts.push(`state=${this.fState}`);
    }
    return `${Store.I.user}/api/user/browse?${parts.join('&')}`;
  }

  private reload(): void {
    this.items = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      const text: string = await httpGet(this.buildUrl(offset), Store.I.token);
      const result: BrowseResult = JSON.parse(text) as BrowseResult;
      const list: MediaItem[] = safeItems(result.items);
      this.items = append ? this.items.concat(list) : list;
      const total: number = result.total === undefined || result.total === null ? list.length : result.total;
      this.total = total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] browse: ${e.code} ${e.message}`);
      if (!append) {
        this.error = '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.items.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.load(this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private openDetail(item: MediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private resetFilters(): void {
    this.fMosaic = '';
    this.fCtype = '';
    this.fSub = '';
    this.fScore = '';
    this.fYear = '';
    this.fState = '';
  }

  @Builder
  Toolbar() {
    Row({ space: 8 }) {
      Text(`${this.total} 部`)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .layoutWeight(1)

      Text(`⇅ ${sortLabelOf(this.sort)}${this.sort === 'random' ? '' : (this.order === 'asc' ? ' ↑' : ' ↓')}`)
        .fontSize(12)
        .fontColor(Theme.TEXT_DIM)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.CARD)
        .borderRadius(12)
        .onClick(() => {
          this.showSort = true;
        })

      Text(this.filterCount() > 0 ? `⚙ 筛选 ${this.filterCount()}` : '⚙ 筛选')
        .fontSize(12)
        .fontColor(this.filterCount() > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.filterCount() > 0 ? Theme.ACCENT : Theme.CARD)
        .borderRadius(12)
        .onClick(() => {
          this.showFilter = true;
        })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4, bottom: 8 })
  }

  /**
   * 网格单元直接用统一海报卡：媒体库原先自己拼了一套图 + 评分 + 日期，
   * 结果标记（破解/流出/中字）在媒体库里永远不显示。
   * 现在所有影片列表共用 PosterCard，标记只在一处实现。
   */
  @Builder
  Cell(item: MediaItem) {
    PosterCard({
      item: item,
      fluid: true,
      showDate: true,
      onTap: () => {
        this.openDetail(item);
      }
    })
  }

  @Builder
  SortPanel() {
    Column() {
      Row() {
        Text('排序方式')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('关闭')
          .fontSize(13)
          .fontColor(Theme.TEXT_FAINT)
          .onClick(() => {
            this.showSort = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 6 })

      ForEach(SORT_OPTIONS, (opt: SortOption) => {
        Row() {
          Text(opt.label)
            .fontSize(14)
            .fontColor(this.sort === opt.key ? Theme.ACCENT : Theme.TEXT)
            .layoutWeight(1)
          if (this.sort === opt.key && opt.key !== 'random') {
            Text(this.order === 'asc' ? '↑ 正序' : '↓ 倒序')
              .fontSize(11)
              .fontColor(Theme.TEXT)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
              .onClick(() => {
                this.order = this.order === 'asc' ? 'desc' : 'asc';
                this.reload();
              })
          }
        }
        .width('100%')
        .height(46)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          if (this.sort === opt.key) {
            this.showSort = false;
            return;
          }
          this.sort = opt.key;
          this.order = opt.def;
          this.reload();
          this.showSort = false;
        })
      }, (opt: SortOption) => opt.key)

      Blank().height(20)
    }
    .width('100%')
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  @Builder
  FilterPanel() {
    Column() {
      Row() {
        Text('筛选')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('重置')
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.resetFilters();
            this.reload();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          FilterChips({
            title: '马赛克', options: MOSAIC_OPTIONS, current: this.fMosaic,
            onPick: (key: string) => {
              this.fMosaic = key;
              this.reload();
            }
          })
          FilterChips({
            title: '类型', options: CTYPE_OPTIONS, current: this.fCtype,
            onPick: (key: string) => {
              this.fCtype = key;
              this.reload();
            }
          })
          FilterChips({
            title: '字幕', options: SUB_OPTIONS, current: this.fSub,
            onPick: (key: string) => {
              this.fSub = key;
              this.reload();
            }
          })
          FilterChips({
            title: '评分', options: SCORE_OPTIONS, current: this.fScore,
            onPick: (key: string) => {
              this.fScore = key;
              this.reload();
            }
          })
          FilterChips({
            title: '年份', options: YEAR_OPTIONS, current: this.fYear,
            onPick: (key: string) => {
              this.fYear = key;
              this.reload();
            }
          })
          Blank().height(10)
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Row() {
        Button('完成')
          .width('100%')
          .height(42)
          .backgroundColor(Theme.ACCENT)
          .fontColor('#FFFFFF')
          .fontSize(14)
          .onClick(() => {
            this.showFilter = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 18 })
    }
    .width('100%')
    .height('84%')
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Toolbar()

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.error.length > 0) {
          Column({ space: 10 }) {
            Text(this.error)
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
            Text('重试')
              .fontSize(13)
              .fontColor(Theme.ACCENT)
              .onClick(() => {
                this.reload();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column({ space: 8 }) {
            Text(this.filterCount() > 0 ? '没有符合条件的影片' : '这个库还是空的')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            if (this.filterCount() > 0) {
              Text('试试放宽筛选条件')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .onClick(() => {
                  this.resetFilters();
                  this.reload();
                })
            } else {
              Text('在 amane 网页端入库后会自动出现在这里')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.items, (item: MediaItem) => {
              GridItem() {
                this.Cell(item)
              }
            }, (item: MediaItem) => `m-${item.id}`)

            if (this.items.length < this.total) {
              GridItem() {
                Column() {
                  if (this.loadingMore) {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color(Theme.TEXT_FAINT)
                  } else {
                    Text('加载更多')
                      .fontSize(11)
                      .fontColor(Theme.TEXT_FAINT)
                  }
                }
                .width('100%')
                .height(180)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.loadMore();
                })
              }
            }
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(9)
          .rowsGap(14)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 84 })
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')

      if (this.showSort || this.showFilter) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .onClick(() => {
            this.showSort = false;
            this.showFilter = false;
          })

        if (this.showSort) {
          this.SortPanel()
        }
        if (this.showFilter) {
          this.FilterPanel()
        }
      }
    }
    .width('100%')
    .height('100%')
  }
}
