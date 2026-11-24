import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { BrowseResult, DetailParams, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { ChipOption, MYRATING_OPTIONS, SortOption, sortDefOf } from '../common/BrowseOptions';
import { PosterCard } from '../view/PosterCard';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { collectionChipOptions } from '../ext/collections/CollectionTypes';
import { BuildConfig } from '../common/BuildConfig';
import { PrefixParams } from '../ext/facets/FacetTypes';
import { GlassBack, GlassBox, GlassCapsule, GlassGlyph, GlassSearchBar, PageTitle } from '../view/GlassKit';

/**
 * 同番号前缀的影片列表（2.4.6.18）。
 *
 * 前缀来自 facets 扩展（`SPSD-14` → `SPSD`，与厂牌页显示的是同一个正则），
 * 列表走核心 browse 的 `?prefix=SPSD`（facets 的 `browse_where` 钩子加 `m.number LIKE 'SPSD%'`），
 * 于是标记、我的评分、播放进度、收藏夹筛选都由核心照常补齐。
 *
 * 2.4.6.26 起与媒体库同一套「搜索 + 工具条 + 底部抽屉」：搜索是在这个前缀里再缩一层
 * （`q` 与 `prefix` 是 AND），不是跳出前缀去全库搜。
 *
 * 为什么不复用 FacetPage：那里的入参是「分类 id」，而前缀不是分类，没有 id 也没有收藏位。
 */
@Entry
@Component
struct PrefixPage {
  @StorageProp('amaneCols') posterCols: number = 3;
  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State note: string = '';
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State collectionOptions: ChipOption[] = [];
  @State sortKey: string = 'recent';
  @State order: string = 'desc';
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  private prefix: string = '';
  private sorts: SortOption[] = [
    { key: 'recent', label: '最近更新', def: 'desc' },
    { key: 'release', label: '发行日期', def: 'desc' },
    { key: 'number', label: '番号', def: 'asc' },
    { key: 'score', label: '评分', def: 'desc' }
  ];

  aboutToAppear(): void {
    const p = router.getParams() as PrefixParams;
    if (p !== undefined && p !== null && typeof p.prefix === 'string') {
      this.prefix = p.prefix.trim().toUpperCase();
    }
    this.loadCollections();
    this.load();
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
  }

  private async load(): Promise<void> {
    if (this.prefix.length === 0) {
      this.loading = false;
      this.note = '没有可用的番号前缀';
      return;
    }
    this.loading = this.items.length === 0;
    let url: string = `${Store.I.user}/api/user/browse?prefix=${encodeURIComponent(this.prefix)}` +
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
      console.error(`[amane] prefix ${this.prefix}: ${e.code} ${e.message}`);
      this.note = '读取失败，请检查连接';
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
    return '最近更新';
  }

  private open(id: number): void {
    const p: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
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

  @Builder
  TitleBar() {
    // 七十二改：与标签详情页同一套 —— 第一行「返回 + 番号 + 排序 + 筛选」，
    // 第二行整条搜索胶囊。原来压在海报上的 KeywordBox / ListToolbar 一并搬进来。
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        // 七十二改：标题按规范装进玻璃胶囊（与演员作品页同一颗）
        GlassBox({ radius: 23, padH: 14, padV: 9, mat: true }) {
          PageTitle({ text: this.prefix.length > 0 ? `${this.prefix} 番号` : '番号', fs: 18 })
        }
        Blank()
        GlassCapsule({
          label: `${this.sortLabel()}`,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          maxW: 100,
          mat: true,
          onTap: () => {
            this.showSort = true;
          }
        })
        GlassCapsule({
          label: this.filterCount() > 0 ? `筛选 ${this.filterCount()}` : '筛选',
          active: this.filterCount() > 0,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          mat: true,
          onTap: () => {
            this.showFilter = true;
          }
        })
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      Row({ space: 6 }) {
        GlassSearchBar({
          placeholder: `在 ${this.prefix} 里搜番号 / 标题`,
          boxH: 34,
          rowH: 42,
          radius: 17,
          iconSize: 15,
          mat: true,
          onCommit: (kw: string) => {
            const next: string = kw.trim();
            if (next === this.keyword) {
              return;
            }
            this.keyword = next;
            this.load();
          }
        })
        .layoutWeight(1)
        Text(this.note.length > 0 ? this.note : `${this.total} 部`)
          .fontSize(10)
          .fontColor(this.note.length > 0 ? Theme.GOLD : Theme.TEXT_FAINT)
          .maxLines(1)
      }
      .height(42)
      .alignItems(VerticalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: this.topInset - 8 })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。46 第一行 + 42 第二行。 */
  private barH(): number {
    return this.topInset + 88;
  }

  /** 标题栏配置：高度 = 状态栏 + 88，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 88 + this.topInset
    };
  }

  /** 真·全屏（七十二改）：窗口铺到系统栏后面；离开本页不关，见 common/PageFullscreen。 */
  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {

          // 七十二改：搜索 / 排序 / 筛选 / 错误提示都进了标题栏，这里不再有死留白；
          // 让位落在网格自己的 padding 上（随内容滚走），海报能钻进两行玻璃底下。

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
              Text('#')
                .fontSize(30)
                .fontColor(Theme.TEXT_FAINT)
              Text(this.keyword.length > 0
                ? `这个前缀里没有「${this.keyword}」`
                : '没有这个前缀的影片')
                .fontSize(14)
                .fontColor(Theme.TEXT_DIM)
              if (this.keyword.length > 0) {
                Text('换个关键词，或清空搜索看全部')
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
                  PosterCard({
                    item: item,
                    fluid: true,
                    showDate: true,
                    onTap: () => {
                      this.open(item.id);
                    }
                  })
                }
              }, (item: MediaItem) => `pf-${item.id}`)
            }
            .columnsTemplate(Personalize.colsTemplate(this.posterCols))
            .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
              Personalize.zoom(event.scale);
            }))
            .columnsGap(10)
            .rowsGap(14)
            .width('100%')
            .layoutWeight(1)
            .cachedCount(6)
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: this.barH() + 6, bottom: Theme.pageBottomSafe() })
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
