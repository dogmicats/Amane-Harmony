import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams, HistoryItem, HistoryList } from '../common/Types';
import { clock, dateText, remainText } from '../common/Util';
import { safeHistory } from '../common/Safe';
import { ChipOption, MYRATING_OPTIONS, SortOption } from '../common/BrowseOptions';
import { MarkBadges } from '../view/MarkBadges';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { collectionChipOptions } from '../ext/collections/CollectionTypes';
import { BuildConfig } from '../common/BuildConfig';

/**
 * 观看记录（2.4.6.26 起与媒体库同一套「搜索 + 工具条 + 底部抽屉」）。
 *
 * 历史接口一次给 120 条、不分页，所以关键词与筛选都在本地做：
 * 这样每敲一个字不会重新打一次服务端（历史命中率还高）。
 */
@Entry
@Component
struct HistoryPage {
  @State items: HistoryItem[] = [];
  @State loading: boolean = true;
  /** 我的评分 / 收藏夹筛选。 */
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State sortKey: string = 'recent';
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  @State collectionOptions: ChipOption[] = [];
  private sorts: SortOption[] = [
    { key: 'recent', label: '最近观看', def: 'desc' },
    { key: 'myrating', label: '我的评分', def: 'desc' }
  ];

  aboutToAppear(): void {
    this.load();
    this.loadCollections();
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
  }

  /** 筛选 + 排序后的列表。评分与清单字段由扩展在列表接口上补。 */
  private shown(): HistoryItem[] {
    const kw: string = this.keyword.trim().toLowerCase();
    const out: HistoryItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: HistoryItem = this.items[i];
      if (kw.length > 0) {
        const hay: string = `${it.number} ${it.title}`.toLowerCase();
        if (hay.indexOf(kw) < 0) {
          continue;
        }
      }
      const mine: number = it.my_rating === undefined ? 0 : it.my_rating;
      if (this.fMyRating === 'none') {
        if (mine > 0) {
          continue;
        }
      } else if (this.fMyRating.length > 0) {
        if (mine < Number(this.fMyRating)) {
          continue;
        }
      }
      const ids: number[] = it.collection_ids === undefined ? [] : it.collection_ids;
      if (this.fCollection === 'none') {
        if (ids.length > 0) {
          continue;
        }
      } else if (this.fCollection.length > 0) {
        if (ids.indexOf(Number(this.fCollection)) < 0) {
          continue;
        }
      }
      out.push(it);
    }
    if (this.sortKey === 'myrating') {
      out.sort((a: HistoryItem, b: HistoryItem): number => {
        const x: number = a.my_rating === undefined ? 0 : a.my_rating;
        const y: number = b.my_rating === undefined ? 0 : b.my_rating;
        return y - x;
      });
    }
    return out;
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
    return '最近观看';
  }

  private resetFilters(): void {
    this.fMyRating = '';
    this.fCollection = '';
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/history?limit=120`, Store.I.token);
      const data: HistoryList = JSON.parse(text) as HistoryList;
      this.items = safeHistory(data.items);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] history: ${e.code} ${e.message}`);
    }
    this.loading = false;
  }

  private async remove(id: number): Promise<void> {
    try {
      await httpDelete(`${Store.I.user}/api/user/history/${id}`, Store.I.token);
      const next: HistoryItem[] = [];
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].id !== id) {
          next.push(this.items[i]);
        }
      }
      this.items = next;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] history delete: ${e.code} ${e.message}`);
    }
  }

  private resume(item: HistoryItem): void {
    // 进详情页并直接开播：竖屏就在详情页顶部播，横屏全屏；退出回列表。
    const params: DetailParams = {
      id: item.id,
      autoplay: true,
      position: item.finished ? 0 : item.position
    };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private ratio(item: HistoryItem): number {
    if (item.duration <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(1, item.position / item.duration * 100));
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
      Text('观看记录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Blank()
      if (BuildConfig.ENABLE_WATCHLATER) {
        // 稍后再看和观看记录是同一件事的两半：看过的在这页，想看的在那个队列
        Text('稍后 ›')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(11)
          .onClick(() => {
            router.pushUrl({ url: 'pages/WatchLaterPage' });
          })
      }
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
        this.resetFilters();
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
        }
      })
      if (BuildConfig.ENABLE_COLLECTIONS && this.collectionOptions.length > 0) {
        ChipGroup({
          title: '收藏夹', options: this.collectionOptions, current: this.fCollection,
          onPick: (key: string) => {
            this.fCollection = key;
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

        if (this.items.length > 0) {
          Row() {
            KeywordBox({
              placeholder: '搜索番号 / 标题',
              onCommit: (kw: string) => {
                this.keyword = kw.trim();
              }
            })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })

          ListToolbar({
            label: this.keyword.length > 0
              ? `「${this.keyword}」${this.shown().length} 条`
              : `${this.shown().length} 条`,
            sortLabel: this.sortLabel(),
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
          Column({ space: 8 }) {
            Text('还没有观看记录')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text('看过的片子会出现在这里，可以接着播')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.shown().length === 0) {
          Column({ space: 8 }) {
            Text(this.keyword.length > 0 ? `没有找到「${this.keyword}」` : '没有符合条件的记录')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text(this.keyword.length > 0
              ? '换个关键词，或清空搜索看全部'
              : '把「我的评分」「收藏夹」改回「全部」再看看')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.shown(), (item: HistoryItem) => {
              ListItem() {
                Row({ space: 12 }) {
                  Stack({ alignContent: Alignment.BottomStart }) {
                    Image(Store.I.img(item.poster))
                      .width(86)
                      .height(120)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(8)
                      .backgroundColor(Theme.CARD)
                    if (this.ratio(item) > 0) {
                      Progress({ value: this.ratio(item), total: 100, type: ProgressType.Linear })
                        .width('100%')
                        .height(3)
                        .color(Theme.ACCENT)
                        .backgroundColor('#4DFFFFFF')
                    }
                  }
                  .width(86)
                  .borderRadius(8)

                  Column({ space: 5 }) {
                    Row({ space: 6 }) {
                      Text(item.number)
                        .fontSize(12)
                        .fontColor(Theme.ACCENT)
                      if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                        MarkBadges({ marks: item.marks, max: 2, badgeSize: 8, fill: 'card' })
                      }
                    }
                    .alignItems(VerticalAlign.Center)
                    Text(item.title)
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${clock(item.position)} / ${clock(item.duration)}`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(item.finished ? '已看完' : remainText(item.position, item.duration))
                      .fontSize(10)
                      .fontColor(item.finished ? Theme.TEXT_FAINT : '#8BD9A0')
                    Text(dateText(item.played_at.replace('T', ' ')))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding(10)
                .backgroundColor(Theme.CARD)
                .borderRadius(Theme.RADIUS)
                .onClick(() => {
                  this.resume(item);
                })
              }
              .swipeAction({
                end: {
                  builder: () => {
                    Text('删除')
                      .fontSize(13)
                      .fontColor('#FFFFFF')
                      .width(72)
                      .height('100%')
                      .textAlign(TextAlign.Center)
                      .backgroundColor(Theme.DANGER)
                      .onClick(() => {
                        this.remove(item.id);
                      })
                  }
                }
              })
            }, (item: HistoryItem) => `his-${item.id}`)
          }
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
            order: 'desc',
            // 历史的两种排序都是固定倒序（最近在前 / 高分在前），不显示方向开关
            noOrderKey: this.sortKey,
            tabInset: 0,
            onPick: (key: string) => {
              this.sortKey = key;
              this.showSort = false;
            },
            onToggleOrder: () => {
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
