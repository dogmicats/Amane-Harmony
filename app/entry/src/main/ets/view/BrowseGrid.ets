import { curves, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGetCached, cachedBody } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { NavBarWatch } from '../common/NavBarWatch';
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

export const MOSAIC_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: 'LEAKED', label: '无码流出' },
  { key: 'CRACKED', label: '破解' },
  { key: 'NONE', label: '原版' }
];

export const CTYPE_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: 'CENSORED', label: '有码' },
  { key: 'UNCENSORED', label: '无码' },
  { key: 'FC2', label: 'FC2' },
  { key: 'AMATEUR', label: '业余' }
];

export const SUB_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '1', label: '有字幕' },
  { key: '0', label: '无字幕' }
];

// 必须导出：收藏页的 9 组筛选复用同一套选项（2026-11-16 agent2）。

export const SCORE_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '4.5', label: '4.5 以上' },
  { key: '4.0', label: '4.0 以上' },
  { key: '3.5', label: '3.5 以上' },
  { key: '3.0', label: '3.0 以上' }
];

export const YEAR_OPTIONS: ChipOption[] = [
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
  /**
   * 多选媒体库（2.6.3.3）：给了就用它，且**语义是 AND** ——
   * 影片要同时出现在所选每个库里才算命中（用户要的是「同时出现在哪些库」）。
   * 只选一个时等价于 `libraryId`；一个都不选 = 全部。
   */
  @Prop @Watch('onExternalChange') libraryIds: number[] = [];
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
  /**
   * 头部（搜索框 + 工具条）随滚动收起（2026-11-17，HDS 标题栏试点）。
   * 媒体库把标题栏交给了 HDS（标题、库切换在那儿），这两行不能在顶上常驻，
   * 否则顶部会堆成一坨；这里让它们往下滑时自动让位，滑回顶部再展开。
   * 其它入口（演员 / 标签 / 收藏）不传 = false，行为不变。
   */
  @Prop scrollAwayHeader: boolean = false;
  /** 抽卡开关变化的对外通知（2026-11-17 起父组件用 @Link 直接读，这个回调保留兼容）。 */
  onGachaChange?: (v: boolean) => void;
  /**
   * 当前生效的筛选项个数（2026-11-17 七改）。
   *
   * 媒体库把「筛选」搬到了顶栏，那边看不到这里的 `fXxx` 字段，
   * 所以由这边在每次重载前报一声 —— 个数 > 0 时顶栏把「筛选」也点亮。
   */
  onFilterChange?: (n: number) => void;
  /**
   * 当前排序依据（2026-11-17 七改）。
   *
   * 媒体库顶栏的「排序」不再只写两个字：用户选过排序就在那儿显示依据（「评分」「女优年龄」…），
   * `isDefault` 为 true 表示还是默认排序 —— 那时顶栏仍旧显示「排序」两个字，不制造"我改过"的错觉。
   */
  onSortChange?: (label: string, isDefault: boolean) => void;
  /**
   * 首屏几张海报（2026-11-17 三十五改）：媒体库顶栏拿它们做「海报光晕」。
   *
   * 用户要求「刚切进来海报从导航栏下方开始，这时候上面会是纯黑，胶囊的玻璃就废了，
   * 给这排胶囊一个高光，颜色最好来自海报」—— 这里把第一排的封面报上去，
   * 顶栏把它们糊成一片色光垫在胶囊底下。不给 URL 而是给路径，`Store.I.img()` 负责拼。
   */
  onHeadPosters?: (posters: string[]) => void;
  /**
   * 网格竖向滚动偏移（节流后报告，2026-11-17 三十五改）。
   * 顶栏用它决定「海报光晕」什么时候收掉 —— 内容已经滑到标题栏底下了，
   * 那儿的颜色是真实海报给的，再叠一层光晕就糊了。
   */
  onScrollY?: (y: number) => void;
  /** 上一次报出去的滚动偏移（节流用，避免每帧都往父组件推状态）。 */
  private lastScrollY: number = -999;
  /** 头部是否已收起（只在 `scrollAwayHeader` 下生效）。 */
  @State headGone: boolean = false;
  /**
   * 抽卡墙顶部的让位高度（2026-11-17）：媒体库抽卡时标题栏隐藏、水墙要顶到状态栏后面，
   * 但墙头那行「剧照 · 范围 · 抽卡中」得躲开时间/电量。独立页/收藏页不传 = 2（原来那样）。
   */
  @Prop gachaTopPad: number = 2;
  /**
   * 网格的滚动控制器（2026-11-17）：媒体库从外面传进来，HDS 的 `bindToScrollable`
   * 要用同一个实例才能联动标题栏显隐。不传也能用（默认自己 new 一个）。
   */
  gridScroller: Scroller = new Scroller();
  /**
   * 网格内容顶部的首屏让位（2026-11-17，三十五改改口径）。
   *
   * 这里是**滚动区内边距**（不是容器 padding）：静止时第一排完整落在标题栏下方，
   * 一开始滚动，这段留白跟着内容滚走，海报直接钻到标题栏底下被虚化 —— 正是要的效果。
   *
   * 三十四改之前传 0（内容从屏幕最顶开始，标题栏直接压在海报上）。用户看完说
   * 「默认顶到最上面也不是很好」，于是改成让位：静止时露出完整第一排，
   * 标题栏底下那一带的补光交给顶栏自己的「海报光晕」（见 LibraryTab.HeadGlow）。
   */
  @Prop headerTopPad: number = 0;
  /**
   * 精简头部（2026-11-17，方案 A）：为 true 时**完全不画**搜索框和工具条，
   * 所有入口交给 HDS 标题栏（排序/筛选面板仍由这里的 SortSheet/FilterSheet 弹）。
   * 这样内容区从屏幕最顶铺下来，没有任何东西和标题栏抢位置。
   */
  @Prop leanMode: boolean = false;
  /**
   * 外部下发的关键词（2026-11-18 三十八改）。
   *
   * 媒体库的搜索框搬进了**父页的标题栏**（`GlassSearchBar`），父级读不到这里的
   * `@State keyword`，所以由父级下发、这里 `@Watch` 接住。本地 `SearchBar()` 仍保留
   * （其他调用方还在用），两条路最终都落到同一个 `keyword` + `reload()`。
   */
  @Prop @Watch('onExternalKeyword') externalKeyword: string = '';

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
  @Link showSort: boolean;
  @Link showFilter: boolean;
  /** 关键词：在当前库/当前筛选之上再缩一层，服务端按相关性排（越精准越靠前）。 */
  @State keyword: string = '';
  /** 抽卡模式：把这个库里的影片剧照随机铺成瀑布流，替代海报网格。 */
  /**
   * 抽卡开关（2026-11-17 改为 @Link）：单一真相在父组件。
   * 之前两边各存一份，媒体库那边一改就会触发父组件重渲染、子组件状态回退，
   * 表现就是「点了抽卡中退不回来」。现在只有父组件持有，子组件直接读写。
   */
  @Link gachaOn: boolean;

  aboutToAppear(): void {
    // 抽卡的初始状态由父组件按偏好设定（@Link），这里不再自行覆盖
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

  /**
   * 父页顶栏的搜索框改了关键词（三十八改）。
   *
   * 只是把值搬进本地 `keyword` 再重载：所有「拼参数 / 空态文案 / 工具条计数」
   * 都读本地这一个字段，所以两条入口（自带 SearchBar 与父页 GlassSearchBar）
   * 的行为天然一致。
   */
  onExternalKeyword(): void {
    const next: string = this.externalKeyword.trim();
    if (next === this.keyword) {
      return;
    }
    this.keyword = next;
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

  /**
   * **筛选条件**（2026-11-18 六十一改：从 `buildUrl` 里抽出来，抽卡墙与列表共用）。
   *
   * 以前只有列表会用这套参数，抽卡墙按 `scope=library` 抽全库 —— 于是「筛完了再抽卡
   * 还是全库」，用户报的就是这个。现在同一份字符串发两处：
   *   · 列表：`/api/user/browse?offset=…&sort=…&<这里>`
   *   · 抽卡：`/api/user/stills?scope=…&id=…&<这里>`
   * 服务端 `core/filters.py` 是同一份实现（那边是 SQL，这里是参数），
   * 所以「列表筛什么、抽卡就抽什么」不再是靠两边各写一遍保持同步。
   *
   * ★ 注意：**不要**把 `sort` / `order` / `offset` / `limit` 放进来。
   * 抽卡是随机的，带排序参数会让服务端白算一遍 ORDER BY（而且语义上也不对）。
   */
  private filterQuery(): string {
    const parts: string[] = [];
    // 媒体库筛选（2.6.3.3）：多选发 `libs=1,2`（语义是「同时出现在每个所选库」），
    // 单选仍走 `library_id` —— 老服务端也认识，不至于退化成全部。
    const libIds: number[] = this.activeLibIds();
    if (libIds.length > 1) {
      parts.push(`libs=${libIds.join(',')}`);
    } else if (libIds.length === 1) {
      parts.push(`library_id=${libIds[0]}`);
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
    return parts.join('&');
  }

  private buildUrl(offset: number): string {
    const head: string = `offset=${offset}&limit=${PAGE_SIZE}&sort=${this.sort}&order=${this.order}`;
    const fq: string = this.filterQuery();
    // 拼接顺序变了（筛选整段放到最后）会让缓存 key 变一次，只是多拉一屏，无副作用。
    return `${Store.I.user}/api/user/browse?${head}${fq.length > 0 ? '&' + fq : ''}`;
  }

  private reload(): void {
    this.error = '';
    // 筛选条件一改就会走到这里：先把「现在有几个筛选项」报给顶栏（七改）
    if (this.onFilterChange !== undefined) {
      this.onFilterChange(this.filterCount());
    }
    // 排序依据也一起报：顶栏那颗按钮要显示当前依据而不是「排序」两个字
    if (this.onSortChange !== undefined) {
      this.onSortChange(sortLabelWith(this.sort, this.fAgeGender), this.sort === 'recent');
    }
    // ★ 2.6.2.1：上次那份先铺上 —— 切回媒体库/收藏时不闪骨架屏。
    //   下面照样拉新的，网络回来再替换；缓存过期也不影响这里（cachedBody 不看 TTL）。
    let showed: boolean = false;
    const stale: string | undefined = cachedBody(this.buildUrl(0));
    if (stale !== undefined) {
      try {
        const d: BrowseResult = JSON.parse(stale) as BrowseResult;
        const list: MediaItem[] = safeItems(d.items);
        if (list.length > 0) {
          this.items = list;
          this.reportHead();
          this.total = d.total === undefined || d.total === null ? list.length : d.total;
          showed = true;
        }
      } catch (err) {
        showed = false;
      }
    }
    if (!showed) {
      this.items = [];
      this.total = 0;
      this.loading = true;
    }
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

  /** 把第一排的封面路径报给顶栏（最多 5 张，够糊出一片色光了）。 */
  private reportHead(): void {
    if (this.onHeadPosters === undefined) {
      return;
    }
    const out: string[] = [];
    for (let i = 0; i < this.items.length && out.length < 5; i++) {
      const p: string = this.items[i].poster;
      if (p !== undefined && p !== null && p.length > 0) {
        out.push(p);
      }
    }
    this.onHeadPosters(out);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      // 带缓存：命中就立刻返回（同时也把这次结果写进磁盘，下次进来先铺这份）。
      // TTL 压到 2 分钟 —— 媒体库要看新入库的片，不能像首页那样放 5 分钟。
      const text: string = await httpGetCached(this.buildUrl(offset), Store.I.token, 120000);
      const result: BrowseResult = JSON.parse(text) as BrowseResult;
      const list: MediaItem[] = safeItems(result.items);
      this.items = append ? this.items.concat(list) : list;
      if (!append) {
        // 换了一批（切库 / 改排序 / 筛选）→ 顶栏那片「海报光晕」的取色对象也要换
        this.reportHead();
      }
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

  /** 当前生效的库 id 列表：多选优先，其次单选，都没有 = 全部。 */
  private activeLibIds(): number[] {
    if (this.libraryIds.length > 0) {
      return this.libraryIds;
    }
    return this.libraryId > 0 ? [this.libraryId] : [];
  }

  /** 空墙/标题文案里用的库名（多选时用「A + B」，全选 = 全部影片）。 */
  private scopeLabel(): string {
    const ids: number[] = this.activeLibIds();
    if (ids.length === 0) {
      return '全部影片';
    }
    const names: string[] = [];
    for (let k = 0; k < ids.length; k++) {
      for (let i = 0; i < Store.I.libraries.length; i++) {
        if (Store.I.libraries[i].id === ids[k]) {
          names.push(Store.I.libraries[i].name);
          break;
        }
      }
    }
    return names.length > 1 ? names.join(' + ') : (names[0] || '');
  }

  /**
   * 打开 / 关闭排序·筛选抽屉（2026-11-17 三十一改：空间动效·弹出）。
   *
   * 抽屉自己的 `.transition()` 只是「怎么动」；**状态变更必须包在 animateTo 里**它才会真的动，
   * 否则就是瞬间出现/消失。曲线用官方 Spatialization 那颗弹簧（`interpolatingSpring(0,1,288,30)`），
   * 收尾有一点点回弹，和底栏材质是同一套手感。
   */
  private openSheet(which: string): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 288, 30) }, () => {
      if (which === 'sort') {
        this.showSort = true;
      } else {
        this.showFilter = true;
      }
    });
  }

  /** 关掉两个抽屉（同上，走弹簧）。 */
  private closeSheets(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 288, 30) }, () => {
      this.showSort = false;
      this.showFilter = false;
    });
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
        this.openSheet('sort');
      },
      onFilter: () => {
        this.openSheet('filter');
      }
    }) {
      // 抽卡模式：换一种看法，不改筛选/排序
      if (BuildConfig.ENABLE_GACHA) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.gachaOn = v;
            if (this.onGachaChange !== undefined) {
              this.onGachaChange(v);
            }
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
        this.closeSheets();
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
        // 抽卡模式下不再放工具条（2026-11-16 用户要求）：那行「抽卡中 · 随机剧照 ·
        // 点图看详情」和墙头里的开关重复；退出抽卡用墙头右端那个开关。
        if (!this.gachaOn && !this.leanMode) {
          if (this.scrollAwayHeader) {
            // 可收起头部（2026-11-17）：往下滑时高度收缩到 0、内容整体上移，
            // 顶部只留 HDS 标题栏；滑回顶部再展开。不用逐帧跟手，阈值触发 + 一次过渡，稳且不卡。
            Column() {
              this.SearchBar()
              this.Toolbar()
            }
            .width('100%')
            .clip(true)
            .opacity(this.headGone ? 0 : 1)
            .constraintSize({ maxHeight: this.headGone ? 0 : 400 })
          } else {
            this.SearchBar()
            this.Toolbar()
          }
        }

        if (this.gachaOn) {
          // 抽卡墙自己滚（2026-11-16 改成瀑布流：一次一批、触底继续）
          Column() {
            GachaWall({
              // 抽卡是「这个库里随机铺」，多选时按第一个库 = 各库合并随机感受最接近；
              // 一个都不选才是全站。
              scope: this.activeLibIds().length > 0 ? 'library' : 'all',
              scopeId: this.activeLibIds().length > 0 ? this.activeLibIds()[0] : 0,
              // ★ 六十一改：把当前筛选条件一起交给抽卡墙 ★
              // 以前这里什么都不传，抽卡按 scope 抽全库 —— 用户在列表里筛了画质/字幕/年份，
              // 点进抽卡看到的还是全库，问「这两个是不是各干各的」。答案当时是「是」。
              // 现在传同一份 `filterQuery()`，服务端 `core/filters.py` 与列表页共用一份实现。
              // 老服务端（<2.8.0）会安静忽略这些参数，退回「全库抽」，不会报错。
              extra: this.filterQuery(),
              label: this.scopeLabel(),
              count: 0,
              gachaOn: this.gachaOn,
              // 媒体库（leanMode）抽卡时不画墙头：退出抽卡靠标题栏那个高亮的「抽卡」按钮
              hideHeader: this.leanMode,
              // 首屏让位交给水墙自己（2026-11-17 七/八改）：第一排不压在顶栏玻璃底下（点得到），
              // 一滚动水墙自己把这个留白收成 0、顶到物理屏顶（见 GachaWall 的 padNow）。
              // 放在外层 Column 的 padding 上做不到这件事：那是死留白，滚了也不动。
              // 其它入口沿用原来的那点余隙（2vp），行为不变。
              topPad: this.gachaTopPad,
              onToggleGacha: (v: boolean) => {
                this.gachaOn = v;
                if (this.onGachaChange !== undefined) {
                  this.onGachaChange(v);
                }
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          // 抽卡墙体铺到屏幕最底（2026-11-16 用户要求）：底部不再留 TAB_SAFE，
          // 被悬浮导航栏压住一部分没关系 —— 它自己会收起，还带沉浸光感。
          .padding({
            left: Theme.PAGE_PAD,
            right: Theme.PAGE_PAD,
            // 顶部一律 0（2026-11-17 七改）：媒体库要让位时走 GachaWall 自己的 `topPad`
            // （滚动区内边距，会随内容滚走）；这里的容器 padding 是不动的死留白，
            // 用了它水墙就永远顶不到屏顶。其它入口的余隙也一并挪进 `topPad`。
            top: 0,
            bottom: 0
          })
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
              .fontColor(Theme.ACCENT_INK)
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
              : (this.filterCount() > 0 ? '没有符合条件的影片'
                : (this.activeLibIds().length > 1 ? '这几个库没有共同的影片' : '这个库还是空的')))
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
            Grid(this.gridScroller) {
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
            .columnsGap(Theme.G_M)
            .rowsGap(Theme.G_L)
          // 关键修复（2.8.3 真机定位）：Grid 默认 ContentClipMode.CONTENT_ONLY 会按 padding.top/bottom
          // 裁切视口，且 cachedCount(n) 默认 show=false 不画 padding 内的预加载行，导致底栏下方
          // 出现 84vp 大黑边、滚过边界瞬间闪现/闪没。配合 SAFE_AREA + show=true 后上下边界全程连续渲染。
          .cachedCount(6, true)
          .clipContent(ContentClipMode.BOUNDARY)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: this.headerTopPad, bottom: TAB_SAFE })
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.loadMore();
          })
          // 滚动偏移上报（三十五改）：只在跨过阈值时才推一次状态。
          // 每一帧都往父组件写 @State 会让整个媒体库页跟着重建，滑动立刻发涩。
          .onDidScroll(() => {
            if (this.onScrollY === undefined) {
              return;
            }
            const y: number = this.gridScroller.currentOffset().yOffset;
            if (Math.abs(y - this.lastScrollY) > 24) {
              this.lastScrollY = y;
              this.onScrollY(y);
            }
          })
          // 往下看收起底栏、往回划弹回来（2026-11-15，学 piliplus）
          .onScrollIndex((first: number) => {
            NavBarWatch.onIndex(first);
            // 头部收起（2026-11-17）：离开第一屏就收，回到第一屏就展开。
            // 用 animateTo 走一次 200ms 过渡，避免滚动时反复抖动。
            if (this.scrollAwayHeader) {
              const next: boolean = first > 0;
              if (next !== this.headGone) {
                animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
                  this.headGone = next;
                });
              }
            }
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
            this.closeSheets();
          })
          // 背景遮罩跟着一起淡入淡出（三十一改）
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))

        if (this.showSort) {
          SortSheet({
            options: this.sortOptions(),
            current: this.sort,
            order: this.order,
            tabInset: this.tabInset,
            onPick: (key: string) => {
              if (this.sort === key) {
                this.closeSheets();
                return;
              }
              this.sort = key;
              this.order = sortDefOf(key);
              this.reload();
              this.closeSheets();
            },
            onToggleOrder: () => {
              this.order = this.order === 'asc' ? 'desc' : 'asc';
              this.reload();
            },
            onClose: () => {
              this.closeSheets();
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
