import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { BrowseResult, DetailParams, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { PosterCard } from './PosterCard';
import { KeywordBox } from './KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from './ListSheets';
import { GachaSwitch } from '../ext/stills/GachaSwitch';
import { GachaWall } from '../ext/stills/GachaWall';
import { CollectionInfo, fetchCollections } from '../ext/collections/CollectionTypes';
import {
  AGE_BANDS, MYRATING_OPTIONS, PREF_AGE_GENDER, SORT_OPTIONS, VERSION_OPTIONS, ChipOption, SortOption,
  sortLabelWith, sortDefOf, ageBandParams, ageGenderParam, ageGenderLabel
} from '../common/BrowseOptions';

const PAGE_SIZE: number = 45;
/** 悬浮 Tab 导航栏占的底部高度：Tab 内的筛选/排序面板要让出这么多，否则最下面被挡住。 */
export const TAB_SAFE: number = 84;

const MOSAIC_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: 'LEAKED', label: '无码流出' },
  { key: 'CRACKED', label: '破解' },
  { key: 'NONE', label: '原版' }
];

const CTYPE_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: 'CENSORED', label: '有码' },
  { key: 'UNCENSORED', label: '无码' },
  { key: 'FC2', label: 'FC2' },
  { key: 'AMATEUR', label: '业余' }
];

const SUB_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '1', label: '有字幕' },
  { key: '0', label: '无字幕' }
];


const SCORE_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '4.5', label: '4.5 以上' },
  { key: '4.0', label: '4.0 以上' },
  { key: '3.5', label: '3.5 以上' },
  { key: '3.0', label: '3.0 以上' }
];

const YEAR_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '2026', label: '2026' },
  { key: '2025', label: '2025' },
  { key: '2024', label: '2024' },
  { key: 'old', label: '2023 及更早' }
];

/**
 * 媒体浏览网格：排序 + 筛选 + 分页。
 * 媒体库 Tab 和「全部影片」页都用它，库 id 由外部传入。
 */
@Component
export struct BrowseGrid {
  /** 海报列数：设置页与双指捏合共用同一个值（2.5.2，见 common/Personalize.ets）。 */
  @StorageProp('amaneCols') posterCols: number = 3;
  @Prop @Watch('onExternalChange') libraryId: number = 0;
  /** 只看某个清单里的片（详情页 / 清单页跳过来）。0 = 不限。 */
  @Prop @Watch('onExternalChange') collectionId: number = 0;
  @Prop @Watch('onExternalChange') refreshKey: number = 0;
  /** 从详情页点「N 岁」进来时预置的年龄分桶；空串=不预置。 */
  @Prop initialAgeBand: string = '';
  /** 预置排序键（如 cast_age）；空串=默认最近更新。 */
  @Prop initialSort: string = '';
  /** 预置年龄性别（female / male）；空串=读全局偏好（默认 female）。 */
  @Prop initialAgeGender: string = '';
  /** 底部悬浮 Tab 导航栏的安全间距：Tab 内传 TAB_SAFE，独立页留 0。 */
  @Prop tabInset: number = 0;

  @State items: MediaItem[] = [];
  /** 下拉刷新中（2.5.7.19）：Refresh 的双向绑定状态。 */
  @State pulling: boolean = false;
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State sort: string = 'recent';
  @State order: string = 'desc';
  @State fMosaic: string = '';
  @State fCtype: string = '';
  @State fSub: string = '';
  /** 多版本（2.5.7.7）：'' 全部 / '1' 多版本 / '0' 单文件。 */
  @State fMulti: string = '';
  @State fScore: string = '';
  @State fYear: string = '';
  @State fAge: string = '';
  /** 出演年龄看哪个性别：female（默认）/ male。全局偏好，与详情页、搜索页共用。 */
  @State fAgeGender: string = 'female';
  @State fState: string = '';
  @State fMyRating: string = '';
  @State fCollection: string = '';
  /** 收藏夹筛选的选项是用户自创的，运行时从服务端拉。 */
  @State collectionOptions: ChipOption[] = [];
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  /** 关键词：在当前库/当前筛选之上再缩一层，服务端按相关性排（越精准越靠前）。 */
  @State keyword: string = '';
  /** 抽卡模式：把这个库里的影片剧照随机铺成瀑布流，替代海报网格。 */
  @State gachaOn: boolean = false;

  aboutToAppear(): void {
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
    // 外部带入的初值必须先落进 @State 再发第一次请求，否则第一屏还是默认的
    // 「最近更新 + 全部」，看起来像点了岁数没反应。
    if (this.initialAgeBand.length > 0) {
      this.fAge = this.initialAgeBand;
    }
    if (this.initialSort.length > 0) {
      this.sort = this.initialSort;
      this.order = sortDefOf(this.initialSort);
    }
    // 性别是全局偏好（详情页徽章 / 筛选 / 搜索页共用一个）；从详情页跳来时
    // 外部带了明确值就用它，保证点「24 岁」看到的一定是女优 18–24。
    this.fAgeGender = this.initialAgeGender.length > 0
      ? this.initialAgeGender : Store.I.prefString(PREF_AGE_GENDER, 'female');
    this.loadCollections();
    this.reload();
  }

  onExternalChange(): void {
    this.loadCollections();
    this.reload();
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    try {
      const lists: CollectionInfo[] = await fetchCollections();
      const opts: ChipOption[] = [
        { key: '', label: '全部' },
        { key: 'none', label: '未归类' }
      ];
      for (let i = 0; i < lists.length; i++) {
        opts.push({ key: `${lists[i].id}`, label: lists[i].name });
      }
      this.collectionOptions = opts;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collections: ${e.code} ${e.message}`);
    }
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
    if (this.fMulti.length > 0) {
      n++;
    }
    if (this.fScore.length > 0) {
      n++;
    }
    if (this.fYear.length > 0) {
      n++;
    }
    if (this.fAge.length > 0) {
      n++;
    }
    if (this.fState.length > 0) {
      n++;
    }
    if (this.fMyRating.length > 0) {
      n++;
    }
    if (this.fCollection.length > 0) {
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
    // 清单视图（2.5.5.25）：`collection=<id>` 由 collections 扩展在 browse 里加条件
    if (this.collectionId > 0) {
      parts.push(`collection=${this.collectionId}`);
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
    // 多版本（2.5.7.7）：服务端按 media_files 条数现算，删/加文件后刷新即变
    if (this.fMulti.length > 0) {
      parts.push(`multi=${this.fMulti}`);
    }
    if (this.fScore.length > 0) {
      parts.push(`min_score=${this.fScore}`);
    }
    if (this.fYear === 'old') {
      parts.push('year_to=2023');
    } else if (this.fYear.length > 0) {
      parts.push(`year_from=${this.fYear}`);
    }
    const ageParts: string[] = ageBandParams(this.fAge);
    for (let i = 0; i < ageParts.length; i++) {
      parts.push(ageParts[i]);
    }
    // 性别只在真的用到年龄时带上（区间筛选或按年龄排序），不往每条 URL 塞无关参数。
    if (this.fAge.length > 0 || this.sort === 'cast_age') {
      parts.push(ageGenderParam(this.fAgeGender));
    }
    if (this.fState.length > 0) {
      parts.push(`state=${this.fState}`);
    }
    if (this.fMyRating.length > 0) {
      parts.push(`myrating=${this.fMyRating}`);
    }
    if (this.fCollection.length > 0) {
      parts.push(`collection=${this.fCollection}`);
    }
    if (this.keyword.length > 0) {
      // 服务端 browse 的 q：拆词 AND 命中番号/标题/演员/系列，并按相关性排在前
      parts.push(`q=${encodeURIComponent(this.keyword)}`);
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

  /**
   * 下拉刷新（2.5.7.19）：媒体库带「随机」排序时，下拉理应换一批；
   * 其它排序同样重拉第一页（顺便把服务端新入库的片带进来）。
   */
  private async pullDown(): Promise<void> {
    this.pulling = true;
    this.items = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    try {
      await this.load(0, false);
    } finally {
      this.pulling = false;
    }
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
    this.fMulti = '';
    this.fScore = '';
    this.fYear = '';
    this.fAge = '';
    this.fState = '';
    this.fMyRating = '';
    this.fCollection = '';
  }

  /** 抽卡空墙文案里用的库名（0 = 全部库）。 */
  private scopeLabel(): string {
    if (this.libraryId <= 0) {
      return '全部影片';
    }
    for (let i = 0; i < Store.I.libraries.length; i++) {
      if (Store.I.libraries[i].id === this.libraryId) {
        return Store.I.libraries[i].name;
      }
    }
    return '';
  }

  /** 清单内关键词搜索：不动筛选条件，只在当前结果里按相关性缩小。 */
  @Builder
  SearchBar() {
    Row() {
      KeywordBox({
        placeholder: '搜索番号 / 标题 / 演员 / 系列',
        onCommit: (kw: string) => {
          const next: string = kw.trim();
          if (next === this.keyword) {
            return;
          }
          this.keyword = next;
          this.reload();
        }
      })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
  }

  @Builder
  Toolbar() {
    // 2.5.6.13：与分类墙 / 收藏 / 搜索统一走 ListToolbar；抽卡开关走 extra 插槽。
    ListToolbar({
      label: this.keyword.length > 0 ? `「${this.keyword}」${this.total} 部` : `${this.total} 部`,
      sortLabel: sortLabelWith(this.sort, this.fAgeGender) +
        (this.sort === 'random' ? '' : (this.order === 'asc' ? ' ↑' : ' ↓')),
      filterCount: this.filterCount(),
      showFilter: true,
      onSort: () => {
        this.showSort = true;
      },
      onFilter: () => {
        this.showFilter = true;
      }
    }) {
      // 抽卡模式：换一种看法，不改筛选/排序
      if (BuildConfig.ENABLE_GACHA) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.gachaOn = v;
          }
        })
      }
    }
  }

  /** 抽卡模式下的精简工具条：开关必须一直看得见，否则退不出抽卡模式。 */
  @Builder
  GachaBar() {
    Row({ space: 8 }) {
      GachaSwitch({
        on: this.gachaOn,
        onToggle: (v: boolean) => {
          this.gachaOn = v;
        }
      })
      Blank()
      Text('随机剧照 · 点图看详情')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 6 })
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

  /** 排序项按当前性别换标签（出演年龄 → 女优年龄 / 男优年龄），抽屉与工具条同一口径。 */
  private sortOptions(): SortOption[] {
    const out: SortOption[] = [];
    for (let i = 0; i < SORT_OPTIONS.length; i++) {
      const opt: SortOption = SORT_OPTIONS[i];
      out.push({ key: opt.key, label: sortLabelWith(opt.key, this.fAgeGender), def: opt.def });
    }
    return out;
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: '筛选',
      actionLabel: '重置',
      onAction: () => {
        this.resetFilters();
        this.reload();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      tabInset: this.tabInset
    }) {
      ChipGroup({
        title: '马赛克', options: MOSAIC_OPTIONS, current: this.fMosaic,
        onPick: (key: string) => {
          this.fMosaic = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '类型', options: CTYPE_OPTIONS, current: this.fCtype,
        onPick: (key: string) => {
          this.fCtype = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '字幕', options: SUB_OPTIONS, current: this.fSub,
        onPick: (key: string) => {
          this.fSub = key;
          this.reload();
        }
      })
      // 多版本（2.5.7.7）：找重复资源用。放在「字幕」下面 —— 两者都是「这一部有几个文件」层面的事。
      ChipGroup({
        title: '版本', options: VERSION_OPTIONS, current: this.fMulti,
        onPick: (key: string) => {
          this.fMulti = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '评分', options: SCORE_OPTIONS, current: this.fScore,
        onPick: (key: string) => {
          this.fScore = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '年份', options: YEAR_OPTIONS, current: this.fYear,
        onPick: (key: string) => {
          this.fYear = key;
          this.reload();
        }
      })
      ChipGroup({
        title: `${ageGenderLabel(this.fAgeGender)}年龄`,
        options: AGE_BANDS,
        current: this.fAge,
        trailing: this.fAgeGender === 'male' ? '♀ 换女优' : '♂ 换男优',
        onTrailing: () => {
          this.fAgeGender = this.fAgeGender === 'male' ? 'female' : 'male';
          Store.I.prefSetString(PREF_AGE_GENDER, this.fAgeGender);
          this.reload();
        },
        onPick: (key: string) => {
          this.fAge = key;
          this.reload();
        }
      })
      if (BuildConfig.ENABLE_RATINGS) {
        ChipGroup({
          title: '我的评分', options: MYRATING_OPTIONS, current: this.fMyRating,
          onPick: (key: string) => {
            this.fMyRating = key;
            this.reload();
          }
        })
      }
      if (BuildConfig.ENABLE_COLLECTIONS) {
        ChipGroup({
          title: '收藏夹', options: this.collectionOptions, current: this.fCollection,
          onPick: (key: string) => {
            this.fCollection = key;
            this.reload();
          }
        })
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.gachaOn) {
          this.GachaBar()
        } else {
          this.SearchBar()
          this.Toolbar()
        }

        if (this.gachaOn) {
          Scroll() {
            Column() {
              GachaWall({
                scope: this.libraryId > 0 ? 'library' : 'all',
                scopeId: this.libraryId,
                label: this.scopeLabel(),
                count: 0,
                gachaOn: this.gachaOn,
                onToggleGacha: (v: boolean) => {
                  this.gachaOn = v;
                }
              })
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: TAB_SAFE })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        } else if (this.loading) {
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
            Text(this.keyword.length > 0
              ? `没有找到「${this.keyword}」`
              : (this.filterCount() > 0 ? '没有符合条件的影片' : '这个库还是空的'))
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            if (this.keyword.length > 0) {
              Text('换个关键词，或清空搜索看全部')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
            } else if (this.filterCount() > 0) {
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
          // 下拉刷新：随机排序下拉换一批，其它排序重拉第一页
          Refresh({ refreshing: $$this.pulling }) {
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
          .columnsTemplate(Personalize.colsTemplate(this.posterCols))
          .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
            Personalize.zoom(event.scale);
          }))
          .columnsGap(9)
          .rowsGap(14)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: TAB_SAFE })
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.loadMore();
          })
          }
          .layoutWeight(1)
          .onRefreshing(() => {
            this.pullDown();
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
          SortSheet({
            options: this.sortOptions(),
            current: this.sort,
            order: this.order,
            tabInset: this.tabInset,
            onPick: (key: string) => {
              if (this.sort === key) {
                this.showSort = false;
                return;
              }
              this.sort = key;
              this.order = sortDefOf(key);
              this.reload();
              this.showSort = false;
            },
            onToggleOrder: () => {
              this.order = this.order === 'asc' ? 'desc' : 'asc';
              this.reload();
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
  }
}
