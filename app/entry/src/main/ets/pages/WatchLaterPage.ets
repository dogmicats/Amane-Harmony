import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BrowseResult, DetailParams, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { ChipOption, MYRATING_OPTIONS, SortOption, sortDefOf } from '../common/BrowseOptions';
import { PosterCard } from '../view/PosterCard';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { collectionChipOptions } from '../ext/collections/CollectionTypes';
import { BuildConfig } from '../common/BuildConfig';
import { removeWatchLater } from '../ext/watchlater/WatchLaterApi';

/**
 * 稍后再看（公开扩展 watch_later）。
 *
 * 列表走核心 browse 的 `watchlater=1`（扩展的 browse_where 钩子加过滤），于是
 * 标记（无码/破解/中流）、我的评分、播放进度这些都由核心照常补齐，这里只负责摆放。
 * 2.4.6.26 起搜索与筛选/排序收进「工具条 + 底部抽屉」，与媒体库一致。
 */
@Entry
@Component
struct WatchLaterPage {
  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State note: string = '';
  /** 和其他 browse 系列表页同一套口径：我的评分 / 收藏夹筛选。 */
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State collectionOptions: ChipOption[] = [];
  @State sortKey: string = 'recent';
  @State order: string = 'desc';
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  private sorts: SortOption[] = [
    { key: 'recent', label: '最近加入', def: 'desc' },
    { key: 'release', label: '发行日期', def: 'desc' },
    { key: 'score', label: '评分', def: 'desc' },
    { key: 'number', label: '番号', def: 'asc' }
  ];

  /** 用 onPageShow：从详情页移出再回来，列表要立刻反映。 */
  onPageShow(): void {
    this.load();
  }

  aboutToAppear(): void {
    this.loadCollections();
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    let url: string = `${Store.I.user}/api/user/browse?watchlater=1` +
      `&sort=${this.sortKey}&order=${this.order}&limit=120`;
    if (this.fMyRating.length > 0) {
      url += `&myrating=${this.fMyRating}`;
    }
    if (this.fCollection.length > 0) {
      url += `&collection=${this.fCollection}`;
    }
    if (this.keyword.length > 0) {
      url += `&q=${encodeURIComponent(this.keyword)}`;
    }
    try {
      const text: string = await httpGet(url, Store.I.token);
      const data: BrowseResult = JSON.parse(text) as BrowseResult;
      this.items = safeItems(data.items);
      this.total = data.total === undefined || data.total === null ? this.items.length : data.total;
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] watch later: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端还没有这个功能（需 1.3.38+）' : '读取失败，请检查连接';
    }
    this.loading = false;
  }

  private filterCount(): number {
    let n: number = 0;
    if (this.fMyRating.length > 0) {
      n++;
    }
    if (this.fCollection.length > 0) {
      n++;
    }
    return n;
  }

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortKey) {
        return this.sorts[i].label;
      }
    }
    return '最近加入';
  }

  /** 移出队列：先本地移除（卡片立刻消失），失败再放回去。 */
  private async remove(id: number): Promise<void> {
    const before: MediaItem[] = this.items;
    const rest: MediaItem[] = [];
    for (let i = 0; i < before.length; i++) {
      if (before[i].id !== id) {
        rest.push(before[i]);
      }
    }
    this.items = rest;
    try {
      await removeWatchLater(id);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] watch later remove: ${e.code} ${e.message}`);
      this.items = before;
      this.note = '移出失败，请检查连接';
      setTimeout(() => {
        this.note = '';
      }, 2000);
    }
  }

  private open(id: number): void {
    const p: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(24)
        .fontColor(Theme.TEXT)
        .width(30)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      Text('稍后再看')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Blank()
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: '筛选',
      actionLabel: '重置',
      onAction: () => {
        this.fMyRating = '';
        this.fCollection = '';
        this.load();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      sheetHeight: '62%'
    }) {
      ChipGroup({
        title: '我的评分', options: MYRATING_OPTIONS, current: this.fMyRating,
        onPick: (key: string) => {
          this.fMyRating = key;
          this.load();
        }
      })
      if (BuildConfig.ENABLE_COLLECTIONS && this.collectionOptions.length > 0) {
        ChipGroup({
          title: '收藏夹', options: this.collectionOptions, current: this.fCollection,
          onPick: (key: string) => {
            this.fCollection = key;
            this.load();
          }
        })
      }
      Blank().height(20)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Header()

        if (this.note.length > 0) {
          Text(this.note)
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
        }

        if (this.items.length > 0 || this.filterCount() > 0 || this.keyword.length > 0) {
          Row() {
            KeywordBox({
              placeholder: '搜索番号 / 标题 / 演员',
              onCommit: (kw: string) => {
                const next: string = kw.trim();
                if (next === this.keyword) {
                  return;
                }
                this.keyword = next;
                this.load();
              }
            })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })

          ListToolbar({
            label: this.keyword.length > 0
              ? `「${this.keyword}」${this.total} 部`
              : `${this.total} 部`,
            sortLabel: `${this.sortLabel()}${this.order === 'asc' ? ' ↑' : ' ↓'}`,
            filterCount: this.filterCount(),
            showFilter: true,
            onSort: () => {
              this.showSort = true;
            },
            onFilter: () => {
              this.showFilter = true;
            }
          })
        }

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column({ space: 10 }) {
            Text(this.keyword.length > 0 ? '◇' : '⏱')
              .fontSize(30)
              .fontColor(Theme.TEXT_FAINT)
            Text(this.keyword.length > 0 ? `没有找到「${this.keyword}」` : '还没有稍后再看的片子')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text(this.keyword.length > 0
              ? '换个关键词，或清空搜索看全部'
              : '在影片详情页点「稍后再看」，回头想看的片会排在这里。')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.items, (item: MediaItem) => {
              GridItem() {
                Stack({ alignContent: Alignment.TopStart }) {
                  PosterCard({
                    item: item,
                    fluid: true,
                    showDate: true,
                    onTap: () => {
                      this.open(item.id);
                    }
                  })
                  // 移出队列：左上角一个半透明 ✕，不与海报右上角的评分标签打架
                  Text('✕')
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .width(20)
                    .height(20)
                    .textAlign(TextAlign.Center)
                    .borderRadius(10)
                    .backgroundColor('#99000000')
                    .margin({ left: 5, top: 5 })
                    .onClick(() => {
                      this.remove(item.id);
                    })
                }
                .width('100%')
              }
            }, (item: MediaItem) => `wl-${item.id}`)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(10)
          .rowsGap(14)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
          .scrollBar(BarState.Off)
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
          SortSheet({
            options: this.sorts,
            current: this.sortKey,
            order: this.order,
            tabInset: 0,
            onPick: (key: string) => {
              if (this.sortKey === key) {
                this.showSort = false;
                return;
              }
              this.sortKey = key;
              this.order = sortDefOf(key);
              this.load();
              this.showSort = false;
            },
            onToggleOrder: () => {
              this.order = this.order === 'asc' ? 'desc' : 'asc';
              this.load();
            },
            onClose: () => {
              this.showSort = false;
            }
          })
        }
        if (this.showFilter) {
          this.FilterSheet()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
