import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams, HistoryItem, HistoryList } from '../common/Types';
import { clock, dateText } from '../common/Util';
import { safeHistory } from '../common/Safe';
import { ChipOption, MYRATING_OPTIONS, SortOption } from '../common/BrowseOptions';
import { MarkBadges } from '../view/MarkBadges';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { collectionChipOptions } from '../ext/collections/CollectionTypes';
import { BuildConfig } from '../common/BuildConfig';
import { GlassBack, GlassCapsule, PageTitle } from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

@Entry
@Component
struct HistoryPage {
  @State items: HistoryItem[] = [];
  @State loading: boolean = true;
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State sortKey: string = 'recent';
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  @State collectionOptions: ChipOption[] = [];
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();
  private sorts: SortOption[] = [
    { key: 'recent', label: '最近观看', def: 'desc' },
    { key: 'plays', label: '看得最多', def: 'desc' },
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
      const order: string = this.sortKey === 'plays' ? 'plays' : 'recent';
      const text: string = await httpGet(
        `${Store.I.user}/api/user/history?limit=120&order=${order}`, Store.I.token);
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
    const params: DetailParams = {
      id: item.id,
      autoplay: true,
      position: item.finished ? 0 : item.position
    };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openDetail(item: HistoryItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private ratio(item: HistoryItem): number {
    if (item.finished) {
      return 100;
    }
    if (item.duration <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(1, Math.round(item.position / item.duration * 100)));
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        PageTitle({ text: '观看记录', fs: 18 })
        Blank()
        if (BuildConfig.ENABLE_WATCHLATER) {
          GlassCapsule({
            label: '稍后再看',
            fs: 12,
            padH: 12,
            padV: 6,
            radius: 16,
            mat: true,
            onTap: () => {
              router.pushUrl({ url: 'pages/WatchLaterPage' });
            }
          })
        }
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  private barH(): number {
    return this.topInset + 46;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
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

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.Top }) {
          SettingsAmbientGlow()

          Column() {
            Blank().height(this.barH() + 4)

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
                  .color(Theme.ACCENT_INK)
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
            } else if (this.items.length === 0) {
              Column({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.arrow_counterclockwise_clock'))
                  .fontSize(28)
                  .fontColor([Theme.TEXT_FAINT])
                Text('还没有观看记录')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_DIM)
                Text('看过的片子会出现在这里，点开就能接着播')
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
                  : '重置筛选条件再看看')
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
                          .width(68)
                          .height(96)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(10)
                          .backgroundColor(Theme.CARD_HI)
                        if (this.ratio(item) > 0) {
                          Stack({ alignContent: Alignment.Start }) {
                            Column().width('100%').height(3).backgroundColor('#4D000000')
                            Column()
                              .width(`${this.ratio(item)}%`)
                              .height(3)
                              .linearGradient(item.finished
                                ? { angle: 90, colors: [['#45B075', 0.0], ['#8EE6B4', 1.0]] }
                                : Theme.ctaGradient())
                          }
                          .width('100%')
                          .height(3)
                        }
                      }
                      .width(68)
                      .height(96)
                      .borderRadius(10)
                      .clip(true)
                      .border({ width: 0.5, color: Theme.STROKE })

                      Column({ space: 4 }) {
                        Row({ space: 6 }) {
                          Text(item.number)
                            .fontSize(13)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(Theme.TEXT)
                            .maxLines(1)
                          if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                            MarkBadges({ marks: item.marks, max: 2, badgeSize: 8, fill: 'card' })
                          }
                        }
                        .alignItems(VerticalAlign.Center)

                        Text(item.title)
                          .fontSize(12)
                          .fontColor(Theme.TEXT_DIM)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')

                        if (item.finished) {
                          Row({ space: 4 }) {
                            SymbolGlyph($r('sys.symbol.checkmark'))
                              .fontSize(9.5)
                              .fontColor(['#8EE6B4'])
                            Text('已看完 · 100%')
                              .fontSize(10.5)
                              .fontColor('#8EE6B4')
                              .fontFeature('"tnum" 1')
                          }
                          .padding({ left: 7, right: 8, top: 2.5, bottom: 2.5 })
                          .backgroundColor('#1A45B075')
                          .border({ width: 0.5, color: '#4245B075' })
                          .borderRadius(Theme.R_PILL)
                        } else {
                          Text(`看到 ${clock(item.position)} · ${this.ratio(item)}%`)
                            .fontSize(11)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(Theme.ACCENT_INK)
                            .fontFeature('"tnum" 1')
                        }

                        Text(dateText(item.played_at.replace('T', ' ')))
                          .fontSize(10)
                          .fontColor(Theme.TEXT_FAINT)
                          .fontFeature('"tnum" 1')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      .onClick(() => {
                        this.openDetail(item);
                      })

                      Stack({ alignContent: Alignment.Center }) {
                        SymbolGlyph($r('sys.symbol.play_fill'))
                          .fontSize(13)
                          .fontColor([Theme.ACCENT_INK])
                      }
                      .width(34)
                      .height(34)
                      .borderRadius(17)
                      .backgroundColor(Theme.accentAlpha(0.18))
                      .border({ width: 0.75, color: Theme.inkAlpha(0.46) })
                      .onClick(() => {
                        this.resume(item);
                      })
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor(Theme.CARD)
                    .borderRadius(16)
                    .border({ width: 0.75, color: Theme.STROKE })
                    .alignItems(VerticalAlign.Center)
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
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
            }
          }
          .width('100%')
          .height('100%')
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
              noOrderKey: this.sortKey,
              tabInset: 0,
              onPick: (key: string) => {
                this.sortKey = key;
                this.showSort = false;
                this.load();
              },
              onToggleOrder: () => {},
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
