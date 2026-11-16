import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpGetCached, cachedBody } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { NavBarWatch } from '../common/NavBarWatch';
import { Personalize } from '../common/Personalize';
import { BrowseResult, DetailParams, FavList, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import {
  AGE_BANDS, MYRATING_OPTIONS, PREF_AGE_GENDER, SortOption, VERSION_OPTIONS, ageBandParams,
  ageGenderLabel, ageGenderParam
} from '../common/BrowseOptions';
import { CollectionsBar } from '../ext/collections/CollectionsBar';
import { GachaSwitch } from '../ext/stills/GachaSwitch';
import { GachaWall } from '../ext/stills/GachaWall';
import { LikedStillsView } from '../ext/stills/LikedStillsView';
import { FavoriteActorsView } from '../ext/actors/FavoriteActorsView';
import { FavoriteFacetsView } from '../ext/facets/FavoriteFacetsView';
import { KeywordBox } from '../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../view/ListSheets';
import { TAB_SAFE } from '../view/BrowseGrid';
import {
  CTYPE_OPTIONS, MOSAIC_OPTIONS, SCORE_OPTIONS, SUB_OPTIONS,
  YEAR_OPTIONS
} from '../view/BrowseGrid';
import { MarkBadges } from '../view/MarkBadges';

/** 收藏页顶部的一个分类标签。 */
interface FavSeg {
  key: string;
  label: string;
}

/** 顶栏总高度（标题行含视图开关 40 + 分类横条 42 + 留白）：内容按这个留白。 */
const HEADER_H: number = 108;
/**
 * 影片段多一条清单胶囊（2026-11-16）：`108`（标题+分类条）`+ 8`（行距）`+ 30`（胶囊）
 * 再减掉顶栏底部内边距从 10 收到 2 的 8 —— 不然胶囊和搜索栏之间会多空一截。
 */
const HEADER_H_COLLECTIONS: number = 138;
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
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State items: MediaItem[] = [];
  /** 收藏网格的控制器：底栏自动收起要用绝对偏移判方向（见 common/NavBarWatch）。 */
  private sc: Scroller = new Scroller();
  /** 剧照/演员/导演/标签/系列 这几段共用的滚动控制器。 */
  private scSeg: Scroller = new Scroller();
  @State loading: boolean = true;
  /** 抽卡模式：把收藏影片的剧照随机铺成瀑布流。 */
  @State gachaOn: boolean = false;
  /** '' 全部收藏 / 'none' 未归类 / 数字串 指定清单 id。 */
  /**
   * 选中的清单（2026-11-16 多选）：空 = 全部收藏；一个 = 该清单；
   * 多个 = **同时**在这些清单里（服务端 `collection=1,2` 取交集，AND 语义）。
   */
  @State collectionKeys: string[] = [];
  /** 排序：recent = 最近收藏（browse 的 recent），myrating = 我的评分。 */
  @State sortKey: string = 'recent';
  /** 我的评分筛选：'' 全部 / '1'..'5' 该星级及以上 / 'none' 未评分。 */
  @State fMyRating: string = '';
  // ── 影片段的筛选（2026-11-16 用户要求：与媒体库/标签页/演员详情页对齐）─────────────
  // 收藏页以前只有「我的评分」一项，用户认为「筛选项太少，要当作一个正常的筛选页」。
  // 这里补齐与 BrowseGrid 完全相同的那几组，参数名也保持一致（mosaic/ctype/sub/multi/
  // min_score/year_from/age/state），服务端 browse 本来就支持。
  @State fMosaic: string = '';
  @State fCtype: string = '';
  @State fSub: string = '';
  @State fMulti: string = '';
  @State fScore: string = '';
  @State fYear: string = '';
  @State fAge: string = '';
  @State fState: string = '';
  /** 年龄看哪个性别（默认读全局偏好）。 */
  @State fAgeGender: string = 'female';
  /** 当前分段：film / still / actor / director / tag / series。 */
  @State seg: string = 'film';
  /** 上半屏横滑（2026-11-15）：Index 拦下翻页后写 `fav|<dir>|<时间戳>` 到这里。 */
  @StorageProp('inPageSwipe') @Watch('onInPageSwipe') inPageSwipe: string = '';
  private lastSwipe: string = '';
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
    // 年龄看哪个性别：与媒体库共用同一个偏好（那边切了这边跟手）
    this.fAgeGender = Store.I.prefString(PREF_AGE_GENDER, 'female') === 'male' ? 'male' : 'female';
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

  /** Index 拦下翻页后发来的「切分段」指令。 */
  onInPageSwipe(): void {
    const raw: string = this.inPageSwipe;
    if (raw.length === 0 || raw === this.lastSwipe) {
      return;
    }
    this.lastSwipe = raw;
    const parts: string[] = raw.split('|');
    if (parts.length < 2 || parts[0] !== 'fav') {
      return;
    }
    const dir: number = Number(parts[1]);
    if (dir === 1 || dir === -1) {
      this.swipeSeg(dir);
    }
  }

  /** 上半屏横滑切分段（dir：1 = 下一个，-1 = 上一个）。到头就停，不循环。 */
  private swipeSeg(dir: number): void {    const list: FavSeg[] = this.segs();
    let at: number = -1;
    for (let i = 0; i < list.length; i++) {
      if (list[i].key === this.seg) {
        at = i;
        break;
      }
    }
    if (at < 0) {
      return;
    }
    const next: number = at + dir;
    if (next < 0 || next >= list.length) {
      return;
    }
    this.seg = list[next].key;
  }

  /**
   * 收藏页某一页的地址。
   *
   * 抽出来是为了「首屏缓存」和「真正请求」用**同一个** URL —— 缓存 key 就是 URL，
   * 两处拼法差一个参数对，缓存就永远命不中（以前容易被后续改动悄悄弄坏）。
   */
  private urlOf(ck: string, page: number): string {
    let url: string = `${Store.I.user}/api/user/browse?collection=${ck}` +
      `&sort=${this.sortKey}&order=desc&limit=120&offset=${page * 120}`;
    // 筛选参数与 BrowseGrid 一字不差（2026-11-16 对齐媒体库/标签/演员详情）
    if (this.fMosaic.length > 0) {
      url += `&mosaic=${this.fMosaic}`;
    }
    if (this.fCtype.length > 0) {
      url += `&ctype=${this.fCtype}`;
    }
    if (this.fSub.length > 0) {
      url += `&sub=${this.fSub}`;
    }
    if (this.fMulti.length > 0) {
      url += `&multi=${this.fMulti}`;
    }
    if (this.fScore.length > 0) {
      url += `&min_score=${this.fScore}`;
    }
    if (this.fYear === 'old') {
      url += '&year_to=2023';
    } else if (this.fYear.length > 0) {
      url += `&year_from=${this.fYear}`;
    }
    const ageParts: string[] = ageBandParams(this.fAge);
    for (let i = 0; i < ageParts.length; i++) {
      url += `&${ageParts[i]}`;
    }
    if (this.fAge.length > 0) {
      url += `&${ageGenderParam(this.fAgeGender)}`;
    }
    if (this.fState.length > 0) {
      url += `&state=${this.fState}`;
    }
    if (this.fMyRating.length > 0) {
      url += `&myrating=${this.fMyRating}`;
    }
    if (this.keyword.length > 0) {
      url += `&q=${encodeURIComponent(this.keyword)}`;
    }
    return url;
  }

  /**
   * 拉某个清单（或 any）的全部片，最多 5 页。
   * 抽出来是为了多选：多选要**逐个清单各拉一份**再在本地求交（见 load()）。
   */
  private async fetchList(ck: string): Promise<MediaItem[]> {
    const all: MediaItem[] = [];
    for (let page = 0; page < 5; page++) {
      const url: string = this.urlOf(ck, page);
      // TTL 2 分钟：收藏页要能看到刚收藏/取消的片子，又不能每次都从零拉五页
      const text: string = await httpGetCached(url, Store.I.token, 120000);
      const data: BrowseResult = JSON.parse(text) as BrowseResult;
      const part: MediaItem[] = safeItems(data.items);
      for (let i = 0; i < part.length; i++) {
        all.push(part[i]);
      }
      if (part.length < 120) {
        break;
      }
    }
    return all;
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    // 全部收藏也要走 browse（collection=any）：收藏页要有「我的评分」筛选与排序，
    // 而 /api/user/favorites 只按收藏时间倒序、不支持任何条件。
    const keys: string[] = this.collectionKeys;
    const ck: string = keys.length === 0 ? 'any' : keys[0];
    const firstUrl: string = this.urlOf(ck, 0);
    // ★ 2.6.2.1：上次那份先铺上，别让「切回收藏」先空一屏。
    // 多选时不铺 —— 缓存那份是单个清单的，铺上来会先闪一下"多出来的片"。
    if (this.items.length === 0 && keys.length <= 1) {
      const stale: string | undefined = cachedBody(firstUrl);
      if (stale !== undefined) {
        try {
          const d: BrowseResult = JSON.parse(stale) as BrowseResult;
          const part: MediaItem[] = safeItems(d.items);
          if (part.length > 0) {
            this.items = part;
            this.loading = false;
          }
        } catch (err) {
          // 缓存坏了就当没有，下面照常请求
        }
      }
    }
    try {
      if (keys.length >= 2) {
        // ★ 多清单：**客户端求交**（2026-11-16）★
        // 旧版清单扩展不认识多值，会**整条过滤被忽略 → 列出全库**（18:40 用户实际撞到）。
        // 逐个清单各拉一份再本地求交，与服务器版本无关，永远不会退化成全库。
        let acc: MediaItem[] = [];
        for (let i = 0; i < keys.length; i++) {
          const one: MediaItem[] = await this.fetchList(keys[i]);
          if (i === 0) {
            acc = one;
            continue;
          }
          const ids: Set<number> = new Set<number>();
          for (let j = 0; j < one.length; j++) {
            ids.add(one[j].id);
          }
          const keep: MediaItem[] = [];
          for (let j = 0; j < acc.length; j++) {
            if (ids.has(acc[j].id)) {
              keep.push(acc[j]);
            }
          }
          acc = keep;
          if (acc.length === 0) {
            break;
          }
        }
        // 顺序取第一个清单的顺序（服务端已按当前排序排好）
        this.items = acc;
      } else {
        this.items = await this.fetchList(ck);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] favorites: ${e.code} ${e.message}`);
      // 服务端没装 collections 扩展时兜底回老接口，页面不至于全空
      if (this.collectionKeys.length === 0 && this.fMyRating.length === 0) {
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

  /** 顶栏实际高度：影片段多一条清单胶囊时让开更多；真全屏后还要加上状态栏那一截。 */
  private headerH(): number {
    return (this.seg === 'film' && BuildConfig.ENABLE_COLLECTIONS ? HEADER_H_COLLECTIONS : HEADER_H)
      + this.topInset;
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
        .border({ width: 1, color: Theme.STROKE_HI })
        .borderRadius(Theme.R_PILL)
      }
    }
    .width('100%')
    .padding({ top: 6 + this.topInset })
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
    .border({ width: 1, color: Theme.STROKE_HI })
    .borderRadius(Theme.R_PILL)
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
      // 清单条（2026-11-16）：紧贴分类胶囊下方、同一材质，读作「影片」这一项的子菜单；
      // 原来它挂在内容区顶部（在搜索框上面），既抢视觉重心，又像独立一块功能。
      if (this.seg === 'film' && BuildConfig.ENABLE_COLLECTIONS) {
        CollectionsBar({
          variant: 'strip',
          multi: true,
          currents: this.collectionKeys,
          current: this.collectionKeys.length === 1 ? this.collectionKeys[0] : '',
          showManage: true,
          onPickMulti: (keys: string[]) => {
            this.collectionKeys = keys;
            this.load();
          },
          onPick: (key: string) => {
            this.collectionKeys = key.length === 0 ? [] : [key];
            this.load();
          }
        })
      }
    }
    .width('100%')
    // 底部不给空隙（2026-11-16 用户：胶囊与搜索栏之间不要这么大间隙，紧贴着就好）——
    // 预留高度 headerH 也同步减掉这 8，见 HEADER_H_COLLECTIONS。
    .padding({ left: 14, right: 14, top: 2, bottom: 2 })
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

  /** 筛选面板：与 BrowseGrid 同一套分组/顺序（媒体库、标签、演员详情都是这套）。 */
  @Builder
  FilterSheet() {
    BottomSheet({
      title: '筛选',
      actionLabel: '重置',
      onAction: () => {
        this.resetFilters();
        this.load();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      sheetHeight: '72%',
      tabInset: TAB_SAFE
    }) {
      ChipGroup({
        title: '马赛克', options: MOSAIC_OPTIONS, current: this.fMosaic,
        onPick: (key: string) => {
          this.fMosaic = key;
          this.load();
        }
      })
      ChipGroup({
        title: '类型', options: CTYPE_OPTIONS, current: this.fCtype,
        onPick: (key: string) => {
          this.fCtype = key;
          this.load();
        }
      })
      ChipGroup({
        title: '字幕', options: SUB_OPTIONS, current: this.fSub,
        onPick: (key: string) => {
          this.fSub = key;
          this.load();
        }
      })
      ChipGroup({
        title: '版本', options: VERSION_OPTIONS, current: this.fMulti,
        onPick: (key: string) => {
          this.fMulti = key;
          this.load();
        }
      })
      ChipGroup({
        title: '评分', options: SCORE_OPTIONS, current: this.fScore,
        onPick: (key: string) => {
          this.fScore = key;
          this.load();
        }
      })
      ChipGroup({
        title: '年份', options: YEAR_OPTIONS, current: this.fYear,
        onPick: (key: string) => {
          this.fYear = key;
          this.load();
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
          this.load();
        },
        onPick: (key: string) => {
          this.fAge = key;
          this.load();
        }
      })
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

  /** 清空全部筛选（不含清单 —— 清单是页面上的独立入口，不该被「重置」顺手清掉）。 */
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
  }

  /** 当前生效的筛选条数（工具条上的角标）。 */
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
    return n;
  }

  @Builder
  FilmContent() {
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
      filterCount: this.filterCount(),
      showFilter: true,
      onSort: () => {
        this.showSort = true;
      },
      onFilter: () => {
        this.showFilter = true;
      }
    })

    if (this.gachaOn) {
      // 抽卡墙自己滚（2026-11-16 改成瀑布流：一次一批、触底继续）；这里只给高度和左右留白。
      Column() {
        GachaWall({ scope: 'favorite', scopeId: 0, label: '我的收藏', count: 0,
          gachaOn: this.gachaOn, onToggleGacha: (v: boolean) => {
            this.gachaOn = v;
          } })
      }
      .width('100%')
      .layoutWeight(1)
      // 抽卡墙体铺到屏幕最底（2026-11-16）：底部不留 TAB_SAFE，让图延伸到底
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 0 })
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
      Grid(this.sc) {
        ForEach(this.items, (item: MediaItem) => {
          GridItem() {
            Column() {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(Store.I.img(item.poster))
                  .width('100%')
                  .aspectRatio(0.704)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(Theme.R_IMG)
                  .border({ width: 1, color: Theme.STROKE })
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
      // 往下看收起底栏、往回划弹回来（2026-11-15）：绝对偏移差分，见 common/NavBarWatch
      .onScroll((x: number, y: number) => {
        NavBarWatch.onOffset(this.sc.currentOffset().yOffset);
      })
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 内容整体从玻璃顶栏下面穿过（顶部预留 HEADER_H），滚动时才有「沉浸」感
        Column() {
          if (this.seg === 'film') {
            // 影片段的筛选行是静止的，没法从板子下穿过，只能用等高的空位让开
            Blank().height(this.headerH())
            this.FilmContent()
          } else {
            // 剧照瀑布流自带随机（/stills/liked?order=random），下拉就换一批（2.5.7.19）；
            // 其它两段一起挂上，行为一致，成本为零。
            Refresh({ refreshing: $$this.pullSeg }) {
              Scroll(this.scSeg) {
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
                .padding({ top: this.headerH() + 4, bottom: Theme.BOTTOM_SAFE + 48 })
              }
              .width('100%')
              .height('100%')
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              // 剧照/演员/导演/标签/系列 这几段也走同一套底栏收起（2026-11-16）
              .onScroll((x: number, y: number) => {
                NavBarWatch.onOffset(this.scSeg.currentOffset().yOffset);
              })
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
