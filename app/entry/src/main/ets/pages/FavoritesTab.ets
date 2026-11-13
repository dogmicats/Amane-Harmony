import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { BrowseResult, DetailParams, FavList, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { MYRATING_OPTIONS, SortOption } from '../common/BrowseOptions';
import { CollectionsBar } from '../ext/collections/CollectionsBar';
import { GachaSwitch } from '../ext/stills/GachaSwitch';
import { GachaWall } from '../ext/stills/GachaWall';
import { LikedStillsView } from '../ext/stills/LikedStillsView';
import { FavoriteActorsView } from '../ext/actors/FavoriteActorsView';
import { FavoriteFacetsView } from '../ext/facets/FavoriteFacetsView';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { TAB_SAFE } from '../view/BrowseGrid';
import { MarkBadges } from '../view/MarkBadges';

/** 收藏页顶部的一个分类标签。 */
interface FavSeg {
  key: string;
  label: string;
}

/** 顶栏总高度（标题行含视图开关 40 + 分类横条 42 + 留白）：内容按这个留白。 */
const HEADER_H: number = 108;
/** 演员/分类的分段：这几类共用「横版行 / 3 列简版」切换。 */
const ENTITY_SEGS: string[] = ['actor', 'director', 'tag', 'series'];
/** 视图偏好键：行 or 网格。 */
const PREF_FAV_VIEW: string = 'favView';

/**
 * 我的收藏：影片 / 剧照 / 演员 / 导演 / 标签 / 系列 共用一个页面，顶部切换。
 *
 * 各类收藏的数据源本来就是分开的（影片走 browse 的 collection=any、剧照走
 * stills 扩展的 still_likes、演员走 actors 扩展的 actor_favorites、导演/标签/系列
 * 走上游的 is_favorite 列），所以这里只做「切换 + 各自渲染」，不试图把它们
 * 合成一张表 —— 各自的时间序、各自的取消动作都保留。
 *
 * 顶部分段按扩展开关动态生成：没装演员扩展就不会出现「演员」标签，
 * 不会摆一个点了报 404 的入口。
 */
@Component
export struct FavoritesTab {
  /** 海报列数：设置页与双指捏合共用同一个值（2.5.2）。 */
  @StorageProp('amaneCols') posterCols: number = 3;
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State items: MediaItem[] = [];
  @State loading: boolean = true;
  /** 抽卡模式：把收藏影片的剧照随机铺成瀑布流。 */
  @State gachaOn: boolean = false;
  /** '' 全部收藏 / 'none' 未归类 / 数字串 指定清单 id。 */
  @State collectionKey: string = '';
  /** 排序：recent = 最近收藏（browse 的 recent），myrating = 我的评分。 */
  @State sortKey: string = 'recent';
  /** 我的评分筛选：'' 全部 / '1'..'5' 该星级及以上 / 'none' 未评分。 */
  @State fMyRating: string = '';
  /** 当前分段：film / still / actor / director / tag / series。 */
  @State seg: string = 'film';
  /** 下拉刷新中（2.5.7.19）：Refresh 的双向绑定状态。 */
  @State pullSeg: boolean = false;
  /**
   * 下拉刷新的自增令牌：`refreshKey` 是外部（Index）传进来的 @Prop，本页不能自增，
   * 所以自己再拿一个计数器，拼在一起传给子块，子块 @Watch 到变化就重拉。
   */
  @State pullKey: number = 0;
  /** 演员与分类的展示形态：false = 横版大行，true = 3 列简版。 */
  @State favGrid: boolean = false;
  /** 影片段的搜索与抽屉（2.4.6.26 起与媒体库一致）。 */
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  private sorts: SortOption[] = [
    { key: 'recent', label: '最近收藏', def: 'desc' },
    { key: 'myrating', label: '我的评分', def: 'desc' }
  ];

  aboutToAppear(): void {
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
    this.favGrid = Store.I.prefString(PREF_FAV_VIEW, 'row') === 'grid';
    this.load();
  }

  onRefresh(): void {
    if (this.seg === 'film') {
      this.load();
    }
  }

  /** 顶部分段：只列已经装了扩展的类别。 */
  private segs(): FavSeg[] {
    const out: FavSeg[] = [{ key: 'film', label: '影片' }];
    if (BuildConfig.ENABLE_GACHA) {
      out.push({ key: 'still', label: '剧照' });
    }
    if (BuildConfig.ENABLE_ACTORS) {
      out.push({ key: 'actor', label: '演员' });
    }
    if (BuildConfig.ENABLE_FACETS) {
      out.push({ key: 'director', label: '导演' });
      out.push({ key: 'tag', label: '标签' });
      out.push({ key: 'series', label: '系列' });
    }
    return out;
  }

  /** 当前分段是否用「横版行 / 网格」那套视图。 */
  private isEntitySeg(): boolean {
    return ENTITY_SEGS.indexOf(this.seg) >= 0;
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    // 全部收藏也要走 browse（collection=any）：收藏页要有「我的评分」筛选与排序，
    // 而 /api/user/favorites 只按收藏时间倒序、不支持任何条件。
    const ck: string = this.collectionKey.length === 0 ? 'any' : this.collectionKey;
    try {
      const all: MediaItem[] = [];
      for (let page = 0; page < 5; page++) {
        let url: string = `${Store.I.user}/api/user/browse?collection=${ck}` +
          `&sort=${this.sortKey}&order=desc&limit=120&offset=${page * 120}`;
        if (this.fMyRating.length > 0) {
          url += `&myrating=${this.fMyRating}`;
        }
        if (this.keyword.length > 0) {
          url += `&q=${encodeURIComponent(this.keyword)}`;
        }
        const text: string = await httpGet(url, Store.I.token);
        const data: BrowseResult = JSON.parse(text) as BrowseResult;
        const part: MediaItem[] = safeItems(data.items);
        for (let i = 0; i < part.length; i++) {
          all.push(part[i]);
        }
        if (part.length < 120) {
          break;
        }
      }
      this.items = all;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] favorites: ${e.code} ${e.message}`);
      // 服务端没装 collections 扩展时兜底回老接口，页面不至于全空
      if (this.collectionKey.length === 0 && this.fMyRating.length === 0) {
        try {
          const text: string = await httpGet(
            `${Store.I.user}/api/user/favorites?limit=200`, Store.I.token);
          const data: FavList = JSON.parse(text) as FavList;
          this.items = safeItems(data.items);
        } catch (err2) {
          const e2 = err2 as BusinessError;
          console.error(`[amane] favorites fallback: ${e2.code} ${e2.message}`);
        }
      }
    }
    this.loading = false;
  }

  @Builder
  Header() {
    Row() {
      Text('我的收藏')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
      Blank()
      if (this.seg === 'film') {
        Text(`${this.items.length} 部`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .margin({ right: 8 })
        if (BuildConfig.ENABLE_GACHA) {
          GachaSwitch({
            on: this.gachaOn,
            onToggle: (v: boolean) => {
              this.gachaOn = v;
            }
          })
        }
      }
      if (this.isEntitySeg()) {
        // 视图切换回到右上角，单独一块玻璃；不占下面横条的位置
        Row({ space: 2 }) {
          this.ViewIcon(false, '☰')
          this.ViewIcon(true, '▦')
        }
        .height(40)
        .padding({ left: 4, right: 4 })
        .backgroundColor('#1FFFFFFF')
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .border({ width: 1, color: '#26FFFFFF' })
        .borderRadius(15)
      }
    }
    .width('100%')
    .padding({ top: 6 })
  }

  @Builder
  ViewIcon(grid: boolean, glyph: string) {
    Text(glyph)
      .fontSize(15)
      .fontColor(this.favGrid === grid ? '#FFFFFF' : Theme.TEXT_FAINT)
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.favGrid === grid ? Theme.ACCENT : Color.Transparent)
      .borderRadius(12)
      .onClick(() => {
        this.favGrid = grid;
        Store.I.prefSetString(PREF_FAV_VIEW, grid ? 'grid' : 'row');
      })
  }

  /** 分类横条：**一整条**玻璃，从影片到系列一行排开（与影片段的筛选条同宽）。 */
  @Builder
  Capsule() {
    Row() {
      Scroll() {
        Row({ space: 4 }) {
          ForEach(this.segs(), (s: FavSeg) => {
            Text(s.label)
              .fontSize(13)
              .fontWeight(this.seg === s.key ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.seg === s.key ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor(this.seg === s.key ? Theme.ACCENT : Color.Transparent)
              .borderRadius(16)
              .onClick(() => {
                if (this.seg !== s.key) {
                  this.seg = s.key;
                }
              })
          }, (s: FavSeg) => `seg-${s.key}`)
        }
        .padding({ left: 5, right: 5 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)
    }
    .width('100%')
    .height(42)
    .backgroundColor('#1FFFFFFF')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 1, color: '#26FFFFFF' })
    .borderRadius(16)
  }

  /**
   * 顶栏：标题与视图开关一行（都不占横条位置），分类条一整条铺开。
   *
   * 整页内容从这块区域下面穿过（见 build 里把留白放进 Scroll），玻璃才有东西可糊；
   * 标题靠一层很淡的向下渐变压住背景，保持可读。
   */
  @Builder
  TopBar() {
    Column({ space: 8 }) {
      this.Header()
      this.Capsule()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 2, bottom: 10 })
    .linearGradient({
      angle: 180,
      colors: [['#CC000000', 0.0], ['#4D000000', 0.6], ['#00000000', 1.0]]
    })
  }

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortKey) {
        return this.sorts[i].label;
      }
    }
    return '最近收藏';
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: '筛选',
      actionLabel: '重置',
      onAction: () => {
        this.fMyRating = '';
        this.load();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      sheetHeight: '52%',
      tabInset: TAB_SAFE
    }) {
      ChipGroup({
        title: '我的评分', options: MYRATING_OPTIONS, current: this.fMyRating,
        onPick: (key: string) => {
          this.fMyRating = key;
          this.load();
        }
      })
      Blank().height(20)
    }
  }

  @Builder
  FilmContent() {
    // 公开扩展 collections：自创清单切换 + 新建
    if (BuildConfig.ENABLE_COLLECTIONS) {
      CollectionsBar({
        current: this.collectionKey,
        showManage: true,
        onPick: (key: string) => {
          this.collectionKey = key;
          this.load();
        }
      })
    }

    // 关键词：只在当前清单里再缩一层，服务端按相关性排（越精准越靠前）
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
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 10 })

    // 排序 + 筛选收进底部抽屉（原来两行 chip 常驻，一屏剩下的地方不多）
    ListToolbar({
      label: this.keyword.length > 0
        ? `「${this.keyword}」${this.items.length} 部`
        : `${this.items.length} 部`,
      sortLabel: this.sortLabel(),
      filterCount: this.fMyRating.length > 0 ? 1 : 0,
      showFilter: true,
      onSort: () => {
        this.showSort = true;
      },
      onFilter: () => {
        this.showFilter = true;
      }
    })

    if (this.gachaOn) {
      Scroll() {
        Column() {
          GachaWall({ scope: 'favorite', scopeId: 0, label: '我的收藏', count: 0,
            gachaOn: this.gachaOn, onToggleGacha: (v: boolean) => {
              this.gachaOn = v;
            } })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 84 })
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
    } else if (this.items.length === 0) {
      Column({ space: 10 }) {
        Text(this.keyword.length > 0 ? '◇' : '♥')
          .fontSize(34)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.keyword.length > 0
          ? `没有找到「${this.keyword}」`
          : (this.fMyRating.length > 0 ? '没有符合评分条件的收藏' : '还没有收藏的影片'))
          .fontSize(14)
          .fontColor(Theme.TEXT_DIM)
        Text(this.keyword.length > 0
          ? '换个关键词，或清空搜索看全部'
          : (this.fMyRating.length > 0 ? '把「我的评分」改回「全部」再看看' : '在详情页点小心心，片子会出现在这里'))
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Grid() {
        ForEach(this.items, (item: MediaItem) => {
          GridItem() {
            Column() {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(Store.I.img(item.poster))
                  .width('100%')
                  .aspectRatio(0.704)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .backgroundColor(Theme.CARD)
                Row({ space: 3 }) {
                  if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                    MarkBadges({ marks: item.marks, max: 2, badgeSize: 8, fill: 'dark' })
                  }
                  Text('♥')
                    .fontSize(13)
                    .fontColor(Theme.ACCENT)
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .backgroundColor('#99000000')
                    .borderRadius(10)
                }
                .margin(5)
              }
              .width('100%')

              Text(item.number)
                .fontSize(12)
                .fontColor(Theme.TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 5 })
            }
            .width('100%')
            .onClick(() => {
              const params: DetailParams = { id: item.id };
              router.pushUrl({ url: 'pages/DetailPage', params: params });
            })
          }
        }, (item: MediaItem) => `fav-${item.id}`)
      }
      .columnsTemplate(Personalize.colsTemplate(this.posterCols))
      .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
        Personalize.zoom(event.scale);
      }))
      .columnsGap(10)
      .rowsGap(14)
      // 底部要同时避开悬浮 Tab 栏和左下角的入库圆环
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 128 })
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 内容整体从玻璃顶栏下面穿过（顶部预留 HEADER_H），滚动时才有「沉浸」感
        Column() {
          if (this.seg === 'film') {
            // 影片段的筛选行是静止的，没法从板子下穿过，只能用等高的空位让开
            Blank().height(HEADER_H)
            this.FilmContent()
          } else {
            // 剧照瀑布流自带随机（/stills/liked?order=random），下拉就换一批（2.5.7.19）；
            // 其它两段一起挂上，行为一致，成本为零。
            Refresh({ refreshing: $$this.pullSeg }) {
              Scroll() {
                Column() {
                  if (this.seg === 'still') {
                    LikedStillsView({
                      refreshKey: this.refreshKey + this.pullKey, pulling: $pullSeg
                    })
                  } else if (this.seg === 'actor') {
                    FavoriteActorsView({
                      refreshKey: this.refreshKey + this.pullKey, grid: this.favGrid
                    })
                  } else {
                    FavoriteFacetsView({
                      kind: this.seg, refreshKey: this.refreshKey + this.pullKey,
                      grid: this.favGrid
                    })
                  }
                }
                .width('100%')
                // 留白放在滚动内容里（不是外层），图才会滑到板子底下，玻璃才有东西可糊
                .padding({ top: HEADER_H + 4, bottom: Theme.BOTTOM_SAFE + 48 })
              }
              .width('100%')
              .height('100%')
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
            }
            .layoutWeight(1)
            .onRefreshing(() => {
              this.pullKey += 1;
              // 兜底收圈：剧照块加载完会自己置 false，万一没加载（空/报错）也能收
              setTimeout(() => {
                this.pullSeg = false;
              }, 4000);
            })
          }
        }
        .width('100%')
        .height('100%')

        // 顶栏：渐变遮罩 + 与底栏同款的玻璃胶囊
        this.TopBar()
      }
      .width('100%')
      .height('100%')

      // 自动入库：左下角悬浮圆环，点开才是面板；只在影片分段出现

      // 排序 / 筛选抽屉：与媒体库同一套，遮罩 + 贴底面板
      if (this.seg === 'film' && (this.showSort || this.showFilter)) {
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
            // 收藏页两种排序都是固定倒序（最近收藏在前 / 高分在前）
            noOrderKey: this.sortKey,
            tabInset: TAB_SAFE,
            onPick: (key: string) => {
              this.sortKey = key;
              this.load();
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
