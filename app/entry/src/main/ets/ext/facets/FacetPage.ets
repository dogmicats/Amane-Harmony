import { promptAction, router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dropPageCache, httpDelete, httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { StarPick } from '../../common/RateStyle';
import { Personalize } from '../../common/Personalize';
import { DetailParams, MediaItem } from '../../common/Types';
import { BrowseResult } from '../../common/Types';
import { safeItems } from '../../common/Safe';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import { KeywordBox } from '../../view/KeywordBox';
import { BottomSheet, ChipGroup, ListToolbar, SortSheet } from '../../view/ListSheets';
import { ChipOption, MYRATING_OPTIONS, SortOption, sortDefOf } from '../../common/BrowseOptions';
import { collectionChipOptions } from '../collections/CollectionTypes';
import { BuildConfig } from '../../common/BuildConfig';
import { GachaSwitch } from '../stills/GachaSwitch';
import { GachaWall } from '../stills/GachaWall';
import { GlassBack, GlassCapsule, GlassGlyph, GlassSearchBar } from '../../view/GlassKit';
import { ImmersiveGlass } from '../../common/ImmersiveGlass';
import {
  FacetFavoriteResult, FacetItem, FacetMediaItem, FacetMediaList, FacetParams,
  emptyFacet, facetLabel, safeFacetMediaList
} from './FacetTypes';

const PAGE_SIZE: number = 30;

/**
 * 这几类「我的标签」下的影片要显示「要 / 不要」（2026-11-19）。
 *
 * 名字必须与 `extensions/private/pending_pick/pending_pick.json` 的 `tags` 完全一致：
 * 服务端按名字判定、客户端按名字显示，两边对不上就是「点了没反应」。
 */
const PENDING_TAGS: string[] = ['破解待下载', '网友推荐待下载'];

/** 点「要」之前要问「存到破解还是 JAV」的那几类（来源混杂）。 */
const PENDING_ASK_TAG: string[] = ['网友推荐待下载'];

/** 服务端 pending_pick 表的决策行（客户端只关心 decision）。 */
interface PickState {
  decision: string;
  target: string;
  state: string;
}

/** 点「要 / 不要」时提交的 body。 */
interface DecideBody {
  number: string;
  decision: string;
  target: string;
  metadata_id: number;
  source: string;
}

interface TagStat {
  id: number;
  name: string;
  count: number;
  ratio: number;
}

/**
 * 公开扩展 facets：某个分类（标签 / 系列 / 制片商 / 我的标签）下的影片墙。
 *
 * 这轮补上「筛选 + 排序」：排序支持发行时间 / 番号 / 评分 / 时长，
 * 筛选支持有字幕、无码/破解/流出、4K —— 和影片库同一套口径，全部下推给上游。
 * 系列页额外把前四张海报拼成四宫格放进标题栏，系列一眼能认出来
 * （详情页的系列卡用的是同一套四宫格视觉）。
 */
interface FacetLogo {
  id: number;
  name: string;
  url: string;
}

@Entry
@Component
struct FacetPage {
  /** 海报列数：设置页与双指捏合共用同一个值（2.5.2）。 */
  @StorageProp('amaneCols') posterCols: number = 3;
  @State items: FacetMediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State sortBy: string = 'release';
  @State order: string = 'desc';
  /** 随机排序时服务端随机开的窗口起点：翻页要续接这个窗口，而不是从 0 重新数。 */
  @State baseOffset: number = 0;
  @State subOnly: boolean = false;
  @State mosaic: string = '';
  /** 分类自己的收藏位：只写 amane 的 is_favorite，与「影片收藏 → 自动入库」无关。 */
  @State facet: FacetItem = emptyFacet();
  /** 制片厂的官方 logo（服务端缓存后的本地路径），没有就空着。 */
  @State logoUrl: string = '';
  /** 自己给这个分类换的封面（站内相对路径）；空 = 用拼贴 / 首字（2.5.5.4）。 */
  @State coverUrl: string = '';
  /** 同一张封面的 16:9 横版：头部这里是个 84×46 的横条，竖图会被裁掉大半。 */
  @State coverWide: string = '';
  @State coverBusy: boolean = false;
  @State tip: string = '';
  /** 我的评分 / 收藏夹：本地库的数据，上游代理分不了，命中时改走 /api/user/browse。 */
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State collectionOptions: ChipOption[] = [];
  /** 该分类下最常出现的标签（系列 = 系列属性），可多选做 AND 收窄。 */
  @State propTags: TagStat[] = [];
  @State pickedTags: number[] = [];
  /** 抽卡模式：把这款分类下的影片剧照随机铺成瀑布流，替代海报网格。 */
  @State gachaOn: boolean = false;
  /**
   * 待下载决策（2026-11-19）：只有「破解待下载」这类标签才显示「要 / 不要」。
   * 状态存服务端的 pending_pick 表，这里只是镜像（点完先本地更新，失败再回滚）。
   */
  @State pickOn: boolean = false;
  @State wants: string[] = [];
  @State skips: string[] = [];
  /** 搜索与抽屉（2.4.6.26 起与媒体库一致）。 */
  @State keyword: string = '';
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  private kind: string = 'tag';
  private facetId: number = 0;
  private title: string = '';
  private sorts: SortOption[] = [
    { key: 'release', label: '发行时间', def: 'desc' },
    { key: 'number', label: '番号', def: 'asc' },
    { key: 'score', label: '评分', def: 'desc' },
    { key: 'runtime', label: '时长', def: 'desc' },
    { key: 'myrating', label: '我的评分', def: 'desc' },
    { key: 'random', label: '随机', def: 'desc' }
  ];
  private mosaics: ChipOption[] = [
    { key: '', label: '不限' },
    { key: 'uncensored', label: '无码' },
    { key: 'cracked', label: '破解' },
    { key: 'leaked', label: '流出' }
  ];
  private subs: ChipOption[] = [
    { key: '', label: '全部' },
    { key: '1', label: '只看有字幕' }
  ];

  aboutToAppear(): void {
    const p = router.getParams() as FacetParams;
    if (p !== undefined && p !== null) {
      this.kind = p.kind === undefined || p.kind === null ? 'tag' : p.kind;
      this.loadLogo();
      this.facetId = Number(p.id);
      this.title = p.name === undefined || p.name === null ? '' : p.name;
      // 分类封面按名字取（自建分类没有 id），拿不到就当没换过
      this.loadCover();
    }
    // 默认进不进抽卡模式由设置页决定（列表页仍是默认视图）
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
    // 「破解待下载」这类标签才有「要 / 不要」两颗钮（仅 self/ui 通道启用；公版零触发）
    this.pickOn = BuildConfig.CHANNEL !== 'public' && this.kind === 'user_tag' && PENDING_TAGS.indexOf(this.title) >= 0;
    this.loadCollections();
    this.loadPropTags();
    this.load(0, false);
  }

  /**
   * 真·全屏（七十一改）：海报要画到状态栏 / 手势条后面，**窗口层**就必须先铺满。
   *
   * 之前的 `expandSafeArea` 挂在内容层却一点用都没有，因为 `Index.onPageHide` 在
   * 打开二级页时把 `setWindowLayoutFullScreen(false)` 关掉了 —— 窗口本身就避让了
   * 系统栏，内容再怎么 expand 也画不出窗口边界。所以本页自己开。
   *
   * ★ 七十二改：**离开本页不关** ★
   * 路由返回时 `onPageHide` 是**后触发**的（`Index.onPageShow` 已经先把全屏设回 true），
   * 若在这里再关一次，等于把主界面刚设好的状态改回 false —— 表现就是用户报的
   * 「从标签详情返回，整个 tab 页往下掉一个状态栏的高度」。
   * 需要让位的只有「本页 → 影片详情」，那一步在 `pushDetail()` 里**推之前**关。
   */
  onPageShow(): void {
    this.setFullScreen(true);
    // 从详情页回来：刚才可能点了「要 / 不要」，那条的标签已经被摘掉 —— 重拉第一页，
    // 否则列表里还挂着它，看着就像「点了没生效」（2026-11-19 用户第一反应）。
    if (this.pickOn && this.items.length > 0) {
      this.load(0, false);
    }
  }

  private setFullScreen(on: boolean): void {
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.setWindowLayoutFullScreen(on).catch((err: BusinessError) => {
        console.info(`[amane] facet fullscreen: ${err.code} ${err.message}`);
      });
    }).catch((err: BusinessError) => {
      console.info(`[amane] facet window: ${err.code} ${err.message}`);
    });
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
  }

  /**
   * 拉这批卡的决策状态（一次批量问，不是每张卡一个请求）。
   *
   * 只在 `pickOn` 的标签里跑；翻页后也重新拉一次（新卡需要自己的状态）。
   * 失败就当全「没选过」——按钮仍在，点下去照样能写服务端。
   */
  private async loadPickState(): Promise<void> {
    if (!this.pickOn || this.items.length === 0) {
      return;
    }
    const nums: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const n: string = this.items[i].number;
      if (n !== undefined && n !== null && n.length > 0) {
        nums.push(n);
      }
    }
    if (nums.length === 0) {
      return;
    }
    try {
      const url: string = `${Store.I.user}/api/user/pending/state?numbers=${encodeURIComponent(nums.join(','))}`;
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const box = obj.items as Record<string, PickState>;
      const w: string[] = [];
      const s: string[] = [];
      for (let i = 0; i < nums.length; i++) {
        const st: PickState = box[nums[i]];
        if (st === undefined || st === null) {
          continue;
        }
        if (st.decision === 'want') {
          w.push(nums[i]);
        } else if (st.decision === 'skip') {
          s.push(nums[i]);
        }
      }
      this.wants = w;
      this.skips = s;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] pending state: ${e.code} ${e.message}`);
    }
  }

  /**
   * 点「要 / 不要」。
   *
   * 「要」= 进下载队列（worker 每几分钟捞一批去提交 115；额度尽了就排队等月初）；
   * 「不要」= 服务端立刻记账，worker 下一轮摘标签 + 写 CSV + 进黑名单。
   * 先本地更新再发请求（点了就有反馈），失败回滚并提示。
   */
  private async decidePick(m: FacetMediaItem, decision: string): Promise<void> {
    const num: string = m.number;
    if (num === undefined || num === null || num.length === 0) {
      this.tip = '这一条没有番号，无法标记';
      return;
    }
    let target: string = 'pojie';
    if (decision === 'want' && PENDING_ASK_TAG.indexOf(this.title) >= 0) {
      // 网友推荐那批来源混杂：点「要」时问一次存到哪个网盘目录
      const r = await promptAction.showDialog({
        title: '存到哪个网盘目录？',
        message: '这条进了下载队列，115 会存到你选的目录',
        buttons: [
          { text: '破解', color: Theme.ACCENT },
          { text: 'JAV', color: Theme.ACCENT }
        ]
      });
      if (r.index < 0) {
        return;
      }
      target = r.index === 1 ? 'jav' : 'pojie';
    }
    const oldW: string[] = this.wants;
    const oldS: string[] = this.skips;
    if (decision === 'want') {
      this.wants = this.withNum(this.wants, num);
      this.skips = this.withoutNum(this.skips, num);
    } else {
      this.skips = this.withNum(this.skips, num);
      this.wants = this.withoutNum(this.wants, num);
    }
    try {
      const payload: DecideBody = {
        number: num,
        decision: decision,
        target: target,
        metadata_id: m.id,
        source: 'user_tag'
      };
      const body: string = JSON.stringify(payload);
      await httpPost(`${Store.I.user}/api/user/pending/decide`, Store.I.token, body);
      this.tip = decision === 'want' ? `已排入下载：${num}` : `已标记不要：${num}`;
    } catch (err) {
      const e = err as BusinessError;
      this.wants = oldW;
      this.skips = oldS;
      this.tip = e.code === 404 ? '服务端未启用待下载扩展（pending_pick）' : '标记失败，请重试';
    }
  }

  private withNum(src: string[], num: string): string[] {
    if (src.indexOf(num) >= 0) {
      return src;
    }
    const out: string[] = src.slice();
    out.push(num);
    return out;
  }

  private withoutNum(src: string[], num: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < src.length; i++) {
      if (src[i] !== num) {
        out.push(src[i]);
      }
    }
    return out;
  }

  private async load(offset: number, append: boolean): Promise<void> {
    // 自建分类没有 id，只能靠名字（服务端按名字把库里 + 覆盖层里的片一起取）
    if (this.facetId <= 0 && this.facetName().length === 0) {
      this.error = '分类不存在';
      this.loading = false;
      return;
    }
    if (this.useLocal()) {
      return this.loadLocal(offset, append);
    }
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${PAGE_SIZE}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`
    ];
    // 「我的标签」里多是待下载片（还没有 media_files），核心 browse 索引不到，
    // 搜索必须仍在 facets/media 这条链上做；上游 /api/metadata 认 search=（不是 q=）。
    if (this.keyword.length > 0) {
      parts.push(`search=${encodeURIComponent(this.keyword)}`);
    }
    if (this.facetId <= 0) {
      parts.push(`name=${encodeURIComponent(this.facetName())}`);
    }
    if (this.subOnly) {
      parts.push('has_subtitle=true');
    }
    if (this.mosaic.length > 0) {
      parts.push(`mosaic=${this.mosaic}`);
    }
    const url: string = `${Store.I.user}/api/user/facets/${this.kind}/${this.facetId}/media?` + parts.join('&');
    try {
      const text: string = await httpGet(url, Store.I.token);
      const r: FacetMediaList = safeFacetMediaList(JSON.parse(text) as FacetMediaList);
      this.baseOffset = r.offset;
      this.facet = r.facet;
      this.items = append ? this.items.concat(r.items) : r.items;
      this.total = r.total;
      this.error = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet media: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404 ? '服务端未启用分类扩展' : '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
    this.loadPickState();
  }

  /** 用了本地筛选或「我的评分」排序就得走本地 browse：上游代理不认识这些条件。 */
  /** 拉这个分类的标签统计：系列页当属性看，标签页当「再叠一层」用。 */
  private async loadPropTags(): Promise<void> {
    if (this.kind === 'user_tag' || this.facetId <= 0) {
      return;
    }
    try {
      const url: string = Store.I.user + '/api/user/facets/' + this.kind + '/' + this.facetId + '/tags?limit=16';
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items;
      const out: TagStat[] = [];
      if (Array.isArray(raw)) {
        for (let i = 0; i < raw.length; i++) {
          const it = raw[i] as TagStat;
          out.push({ id: Number(it.id), name: String(it.name),
            count: Number(it.count), ratio: Number(it.ratio) });
        }
      }
      this.propTags = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error('[amane] facet tags: ' + (err as BusinessError).message);
    }
  }

  private toggleTag(id: number): void {
    const next: number[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.pickedTags.length; i++) {
      if (this.pickedTags[i] === id) {
        removed = true;
      } else {
        next.push(this.pickedTags[i]);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.pickedTags = next;
    // 不清空列表、不置 loading：直接按新条件重取，避免闪屏和滚动条被拖回最前
    this.load(0, false);
  }

  private useLocal(): boolean {
    if (this.kind === 'user_tag') {
      return false;
    }
    // 自建分类（id=0）：facets 的 media 端点查不到，而 browse 支持按名字筛 ——
    // 走本地这条才有完整的筛选能力（关键词 / 评分 / 收藏 / 排序），和原分类一致。
    if (this.facetId <= 0) {
      return true;
    }
    // 关键词只有核心 browse 认识（`q`）；上游 facets/media 没有这个参数
    return this.keyword.length > 0 || this.fMyRating.length > 0 || this.fCollection.length > 0 ||
      this.pickedTags.length > 0 || this.sortBy === 'myrating';
  }

  private browseSort(): string {
    if (this.sortBy === 'myrating') {
      return 'myrating';
    }
    if (this.sortBy === 'number') {
      return 'number';
    }
    if (this.sortBy === 'score') {
      return 'score';
    }
    if (this.sortBy === 'release') {
      return 'release';
    }
    return 'recent';
  }

  private browseMosaic(): string {
    if (this.mosaic === 'cracked') {
      return 'CRACKED';
    }
    if (this.mosaic === 'leaked') {
      return 'LEAKED';
    }
    if (this.mosaic === 'uncensored') {
      return 'NONE';
    }
    return '';
  }

  /**
   * 本地取数：分类 id 直接作为 browse 的维度过滤（`tag_id` / `series_id` …），
   * 这样「我的评分 / 收藏夹」筛选与「我的评分」排序都在 SQL 里生效，分页仍是对的。
   * 返回结构与 facets/media 对齐，页面其余部分不用改。
   */
  private async loadLocal(offset: number, append: boolean): Promise<void> {
    // 维度参数统一在下面拼：kind=tag 时要把「当前标签 + 叠加标签」合成一个 tag_id，
    // 分两次 push 会让服务端只认第一个参数，叠加条件直接丢掉（这就是「选了没反应」的根因）。
    const parts: string[] = [
      `sort=${this.browseSort()}`,
      `order=${this.order}`,
      `offset=${offset}`,
      `limit=${PAGE_SIZE}`
    ];
    const tagIds: number[] = [];
    if (this.facetId <= 0) {
      // 自建分类没有 id：按名字查，服务端会把「库里原有 + 覆盖层里改过来的」并起来
      parts.push(`facet_kind=${this.kind}`);
      parts.push(`facet_name=${encodeURIComponent(this.facetName())}`);
    } else if (this.kind === 'tag') {
      tagIds.push(this.facetId);
    } else {
      parts.push(this.kind + '_id=' + this.facetId);
    }
    for (let i = 0; i < this.pickedTags.length; i++) {
      const tid: number = this.pickedTags[i];
      if (tid > 0 && tagIds.indexOf(tid) < 0) {
        tagIds.push(tid);
      }
    }
    if (tagIds.length > 0) {
      parts.push('tag_id=' + tagIds.join(','));
    }
    if (this.fMyRating.length > 0) {
      parts.push(`myrating=${this.fMyRating}`);
    }
    if (this.fCollection.length > 0) {
      parts.push(`collection=${this.fCollection}`);
    }
    if (this.subOnly) {
      parts.push('sub=1');
    }
    const mos: string = this.browseMosaic();
    if (mos.length > 0) {
      parts.push(`mosaic=${mos}`);
    }
    if (this.keyword.length > 0) {
      parts.push(`q=${encodeURIComponent(this.keyword)}`);
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/browse?${parts.join('&')}`, Store.I.token);
      const data = JSON.parse(text) as BrowseResult;
      const src: MediaItem[] = safeItems(data.items);
      const mapped: FacetMediaItem[] = [];
      for (let i = 0; i < src.length; i++) {
        const m: MediaItem = src[i];
        mapped.push({
          id: m.id, number: m.number, title: m.title, release: m.release,
          score: m.score, poster: m.poster,
          marks: m.marks === undefined ? [] : m.marks,
          my_rating: m.my_rating === undefined ? 0 : m.my_rating
        });
      }
      this.baseOffset = data.offset;
      this.items = append ? this.items.concat(mapped) : mapped;
      this.total = data.total;
      this.error = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet media local: ${e.code} ${e.message}`);
      if (!append) {
        this.error = '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
    this.loadPickState();
  }

  private reload(): void {
    this.items = [];
    this.total = 0;
    this.loading = true;
    this.load(0, false);
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.items.length >= this.total || this.total <= 0) {
      return;
    }
    this.loadingMore = true;
    // 随机排序时 items 是「随机窗口」里的一段，绝对 offset = 窗口起点 + 已加载数
    this.load(this.baseOffset + this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private open(item: FacetMediaItem): void {
    this.pushDetail(item.id);
  }

  /**
   * 进影片详情（七十二改）：**先把窗口的全屏关掉，再推页面**。
   *
   * 详情页没有状态栏让位逻辑（它的标题栏按安全区排），本页是全屏窗口，
   * 直接推过去会被时钟压住。关窗口是异步的，所以用回调串起来；
   * 失败也要照样跳 —— 宁可详情页顶到状态栏，不能点了没反应。
   */
  private pushDetail(id: number): void {
    const params: DetailParams = { id: id };
    const go: () => void = () => {
      router.pushUrl({ url: 'pages/DetailPage', params: params });
    };
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.setWindowLayoutFullScreen(false).then(() => {
        go();
      }).catch(() => {
        go();
      });
    }).catch(() => {
      go();
    });
  }

  /**
   * 收藏这个分类。乐观更新 + 失败回滚：服务端动作是「置为」而不是「取反」，
   * 所以每次都把目标值显式带上。
   */
  private async toggleFav(): Promise<void> {
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0) {
      return;
    }
    const want: boolean = !this.facet.isFavorite;
    this.setFav(want);
    try {
      const text: string = await httpPost(
        `${Store.I.user}/api/user/facets/${this.kind}/${id}/favorite`,
        Store.I.token, JSON.stringify({ favorite: want }));
      const r: FacetFavoriteResult = JSON.parse(text) as FacetFavoriteResult;
      this.setFav(r.favorite === true);
      Store.I.facetDirty = true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet favorite: ${e.code} ${e.message}`);
      this.setFav(!want);
      this.tip = e.code === 404 ? `服务端未启用分类收藏（${Store.I.user}，需 1.3.3+）` : '收藏失败，请重试';
    }
  }

  /** 给这个分类打星（0 = 清除）。与影片评分是两套数据。 */
  private async loadLogo(): Promise<void> {
    if (this.kind !== 'studio') {
      return;
    }
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/facets/studio/${id}/logo`, Store.I.token);
      const r = JSON.parse(text) as FacetLogo;
      const rel: string = r.url === undefined ? '' : r.url;
      this.logoUrl = rel.length > 0 ? `${Store.I.user}${rel}?token=${encodeURIComponent(Store.I.token)}` : '';
    } catch (err) {
      this.logoUrl = '';
    }
  }

  /** 分类名：换封面按**名字**存，自建分类没有 id（2.5.5.4）。 */
  private facetName(): string {
    return this.facet.name.length > 0 ? this.facet.name : this.title;
  }

  private coverPath(): string {
    return `${Store.I.user}/api/user/cover-any/${this.kind}/${encodeURIComponent(this.facetName())}`;
  }

  private async loadCover(): Promise<void> {
    if (this.kind === 'user_tag' || this.facetName().length === 0) {
      return;
    }
    try {
      const text: string = await httpGet(this.coverPath(), Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const data = obj.data as Record<string, Object>;
      const url = data === undefined || data === null || data.url === undefined || data.url === null
        ? '' : `${data.url}`;
      const wide = data === undefined || data === null || data.wide === undefined || data.wide === null
        ? '' : `${data.wide}`;
      this.coverUrl = url;
      this.coverWide = wide;
    } catch (err) {
      // 老服务端没这个接口：当「没换过」，不打扰
      this.coverUrl = '';
      this.coverWide = '';
    }
  }

  /** 头部横条优先用横版；没有（老数据）才退回竖版。 */
  private coverShown(): string {
    return this.coverWide.length > 0 ? this.coverWide : this.coverUrl;
  }

  private coverMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '从相册选一张',
      action: () => {
        this.pickCover();
      }
    });
    // 用这个分类里几部片的海报拼轮播动图（服务端合成）
    items.push({
      value: '用类里的海报做动图',
      action: () => {
        this.makeGifCover();
      }
    });
    if (this.coverUrl.length > 0) {
      items.push({
        value: '恢复默认封面',
        action: () => {
          this.restoreCover();
        }
      });
    }
    return items;
  }

  /** 分类动图：取类内最近 6 部的海报缝成循环 GIF，约 10 秒。 */
  private async makeGifCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    promptAction.showToast({ message: '正在用类里的海报拼动图，约 10 秒…', duration: 3000 });
    try {
      const url: string = `${Store.I.user}/api/user/facet-gif/${this.kind}/` +
        encodeURIComponent(this.facetName());
      const body: Record<string, Object> = { 'count': 6, 'duration': 900 };
      const raw: string = await httpPost(url, Store.I.token, JSON.stringify(body), 90000);
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '动图封面好了', duration: 1500 });
        this.loadCover();
      } else {
        const why: string = obj.reason === undefined || obj.reason === null ? '' : `${obj.reason}`;
        promptAction.showToast({ message: why.length > 0 ? why : '没做成，稍后再试', duration: 2200 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] facet gif: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没做成（服务端可能不支持或海报太少）', duration: 2200 });
    } finally {
      this.coverBusy = false;
    }
  }

  /** 换分类封面：相册选图（GIF 也能选）→ base64 → `/cover-any/{kind}/{名字}`。 */
  private async pickCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const opt: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
      if (res.photoUris.length === 0) {
        return;
      }
      const uri: string = res.photoUris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(f.fd).size;
      if (size > 8 * 1024 * 1024) {
        fileIo.closeSync(f);
        promptAction.showToast({ message: '图太大了（超过 8MB），换一张', duration: 2000 });
        return;
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(buf));
      const body: Record<string, Object> = { 'data': b64, 'ext': this.extOf(uri) };
      const raw: string = await httpPost(this.coverPath(), Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '封面换好了', duration: 1500 });
        this.loadCover();
      } else {
        promptAction.showToast({ message: '没换成功，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] facet cover: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没换成功（选图或上传失败）', duration: 1800 });
    } finally {
      this.coverBusy = false;
    }
  }

  private async restoreCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    try {
      await httpDelete(this.coverPath(), Store.I.token);
      dropPageCache();
      Store.I.coverDirty = true;
      this.coverUrl = '';
      promptAction.showToast({ message: '已恢复默认封面', duration: 1500 });
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] facet cover del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没恢复成，稍后再试', duration: 1600 });
    } finally {
      this.coverBusy = false;
    }
  }

  private extOf(uri: string): string {
    const lower: string = uri.toLowerCase();
    if (lower.indexOf('.png') >= 0) {
      return 'png';
    }
    if (lower.indexOf('.webp') >= 0) {
      return 'webp';
    }
    if (lower.indexOf('.gif') >= 0) {
      return 'gif';
    }
    return 'jpg';
  }

  private async rate(stars: number): Promise<void> {
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0 || this.kind === 'user_tag') {
      return;
    }
    const before: number = this.facet.myRating === undefined ? 0 : this.facet.myRating;
    const want: number = before === stars ? 0 : stars;
    this.setRating(want);
    try {
      await httpPost(`${Store.I.user}/api/user/facets/${this.kind}/${id}/rating`,
        Store.I.token, JSON.stringify({ stars: want }));
      Store.I.facetDirty = true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet rating: ${e.code} ${e.message}`);
      this.setRating(before);
      this.tip = e.code === 404 ? '服务端还不支持分类评分（需 1.3.54+）' : '评分失败，请重试';
    }
  }

  private setRating(stars: number): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, posterItems: this.facet.posterItems,
      topTags: this.facet.topTags, isFavorite: this.facet.isFavorite,
      myRating: stars,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: this.facet.isHidden, prefixes: this.facet.prefixes, logo: this.facet.logo
    };
  }

  private myStars(): number {
    const v: number | undefined = this.facet.myRating;
    return v === undefined ? 0 : v;
  }

  private setFav(fav: boolean): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, posterItems: this.facet.posterItems,
      topTags: this.facet.topTags, isFavorite: fav,
      // myRating 必须原样带上：这对象是整份重建的，漏一个字段 = 那个字段当场归零
      // （用户报的「打了星返回就没了」，一半原因在这里）
      myRating: this.facet.myRating,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: this.facet.isHidden, prefixes: this.facet.prefixes, logo: this.facet.logo
    };
  }

  /**
   * 隐藏 / 恢复这个标签。写旁挂服务的 facet_hidden 表，与 amane 的库和刮削规则无关；
   * 成功后打 Store.I.facetDirty，返回列表时那一页会自动重拉。
   */
  private async toggleHide(): Promise<void> {
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0) {
      return;
    }
    const want: boolean = !this.facet.isHidden;
    this.setHidden(want);
    try {
      await httpPost(`${Store.I.user}/api/user/facets/${this.kind}/${id}/hide`,
        Store.I.token, JSON.stringify({ hidden: want }));
      Store.I.facetDirty = true;
      this.tip = want ? '已隐藏，标签列表里不再显示' : '已恢复显示';
      this.clearTipLater();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet hide: ${e.code} ${e.message}`);
      this.setHidden(!want);
      // 把实际连的地址打出来，一眼能看出是哪个
      this.tip = e.code === 404 ? `服务端未启用隐藏（${Store.I.user}，需 1.3.5+）` : '操作失败，请重试';
      this.clearTipLater();
    }
  }

  private clearTipLater(): void {
    setTimeout(() => {
      this.tip = '';
    }, 2600);
  }

  private setHidden(hidden: boolean): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, posterItems: this.facet.posterItems,
      topTags: this.facet.topTags,
      isFavorite: this.facet.isFavorite,
      myRating: this.facet.myRating,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: hidden, prefixes: this.facet.prefixes, logo: this.facet.logo
    };
  }

  /**
   * 标题栏副标题：分类 / 片数，制片商与发行商再带上番号前缀。
   * 日文厂牌名认不出来时，`SPSD/SPSB/SPSC` 这类字母是更快的识别锚点。
   */
  private subLine(): string {
    const parts: string[] = [`${facetLabel(this.kind)} · ${this.total} 部`];
    if (this.facet.prefixes.length > 0) {
      parts.push(this.facet.prefixes.join('/'));
    }
    return parts.join(' · ');
  }

  private posterAt(i: number): string {
    return i < this.items.length ? this.items[i].poster : '';  }

  private filterCount(): number {
    let n: number = 0;
    if (this.subOnly) {
      n++;
    }
    if (this.mosaic.length > 0) {
      n++;
    }
    if (this.pickedTags.length > 0) {
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

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortBy) {
        return this.sorts[i].label;
      }
    }
    return '发行时间';
  }

  private resetFilters(): void {
    this.subOnly = false;
    this.mosaic = '';
    this.pickedTags = [];
    this.fMyRating = '';
    this.fCollection = '';
    this.reload();
  }

  /**
   * 系列页标题左侧的封面：三张海报横向并列、不裁剪（2:3 原比例）。
   * 之前是四宫格截图式裁切，看不出海报原貌，换掉。
   */
  @Builder
  Cover() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.coverShown().length > 0) {
        // 换过的封面：横条位优先用 16:9 横版（竖图在这儿只剩中间一条），点它出菜单
        Image(Store.I.img(this.coverShown()))
          .width(84)
          .height(46)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.CARD_HI)
          .alt($r('app.media.placeholder'))
      } else {
        Row({ space: 2 }) {
          ForEach([0, 1, 2], (i: number) => {
            Image(this.posterAt(i).length > 0 ? Store.I.img(this.posterAt(i)) : '')
              .width(this.items.length >= 2 ? 31 : 40)
              .height(46)
              .objectFit(ImageFit.Cover)
              .backgroundColor(Theme.CARD_HI)
              .alt($r('app.media.placeholder'))
              .visibility(this.posterAt(i).length > 0 ? Visibility.Visible : Visibility.None)
          }, (i: number) => `cv-${i}`)
        }
        .height(46)
      }
    }
    .height(46)
    .borderRadius(8)
    .clip(true)
    .backgroundColor(Theme.CARD_HI)
    .border({
      width: this.coverShown().length > 0 ? 1 : 0,
      color: Theme.accentAlpha(0.32)
    })
    .margin({ right: 10 })
    // 轻点封面就出菜单（选图 / 恢复默认），不另占一行按钮
    .bindMenu(this.kind === 'user_tag' ? [] : this.coverMenu())
  }


  /**
   * 一行工具条：部数 / 抽卡开关 / ⇅ 排序 / ⚙ 筛选。
   * 2.4.6.26 起原来的「筛选折叠头 + 排序行 + 属性行 + 片源行 + 字幕行」全部收进抽屉，
   * 与小标签页、媒体库、演员页同一形状。
   */
  @Builder
  Toolbar() {
    // 2.5.6.13：与媒体库 / 收藏 / 搜索统一走 ListToolbar；抽卡开关走 extra 插槽。
    ListToolbar({
      label: this.keyword.length > 0 ? `「${this.keyword}」${this.total} 部` : `${this.total} 部`,
      sortLabel: this.sortLabel() + (this.sortBy === 'random' ? '' : (this.order === 'asc' ? ' ↑' : ' ↓')),
      filterCount: this.filterCount(),
      showFilter: true,
      onSort: () => {
        this.showSort = true;
      },
      onFilter: () => {
        this.showFilter = true;
      }
    }) {
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

  /** 属性 / 叠加标签：多选 = AND，所以不用 ChipGroup（那件是单选），单独一组。 */
  @Builder
  PropTagRow() {
    Column({ space: 8 }) {
      Text(this.kind === 'series' ? '系列属性（多选 = 同时具备）' : '叠加标签（多选 = 同时具备）')
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.propTags, (tg: TagStat) => {
          Text(tg.name + ' ' + Math.round(tg.ratio * 100) + '%')
            .fontSize(12)
            .fontColor(this.pickedTags.indexOf(tg.id) >= 0 ? Theme.ON_ACCENT :
              (tg.ratio >= 0.5 ? Theme.TEXT_DIM : Theme.TEXT_FAINT))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.pickedTags.indexOf(tg.id) >= 0 ? Theme.ACCENT : Theme.CARD)
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.toggleTag(tg.id);
            })
        }, (tg: TagStat) => `pt-${tg.id}-${this.pickedTags.indexOf(tg.id) >= 0 ? 1 : 0}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
      sheetHeight: '84%'
    }) {
      ChipGroup({
        title: '片源', options: this.mosaics, current: this.mosaic,
        onPick: (key: string) => {
          this.mosaic = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '字幕', options: this.subs, current: this.subOnly ? '1' : '',
        onPick: (key: string) => {
          this.subOnly = key === '1';
          this.reload();
        }
      })
      if (this.propTags.length > 0) {
        this.PropTagRow()
      }
      if (BuildConfig.ENABLE_RATINGS) {
        ChipGroup({
          title: '我的评分', options: MYRATING_OPTIONS, current: this.fMyRating,
          onPick: (key: string) => {
            this.fMyRating = key;
            this.reload();
          }
        })
      }
      if (BuildConfig.ENABLE_COLLECTIONS && this.collectionOptions.length > 0) {
        ChipGroup({
          title: '收藏夹', options: this.collectionOptions, current: this.fCollection,
          onPick: (key: string) => {
            this.fCollection = key;
            this.reload();
          }
        })
      }
      Blank().height(20)
    }
  }

  private cardOf(m: FacetMediaItem): MediaItem {
    return posterItem(m.id, m.number, m.title, m.release, m.poster, m.score, m.marks,
      m.my_rating === undefined ? 0 : m.my_rating);
  }

  /** 与媒体库完全同一张卡：封面 + 评分角标 + 番号 + 标题。 */
  @Builder
  Cell(m: FacetMediaItem) {
    // 「要 / 不要」已搬到影片详情页（用户 2026-11-19：别压在封面上），列表回到纯浏览。
    PosterCard({
      item: this.cardOf(m),
      fluid: true,
      onTap: () => {
        this.open(m);
      }
    })
  }

  /**
   * 「要 / 不要」两颗钮（2026-11-19）。
   *
   * 压在**左上角**而不是右上角：右上角已经被「无码 / 中字」角标占了，
   * 叠上去两块都看不清。底色用 40% 黑 + 系统厚玻璃，亮海报上也认得出。
   */
  @Builder
  PickBar(m: FacetMediaItem) {
    Row({ space: 5 }) {
      Text(this.wants.indexOf(m.number) >= 0 ? '✓' : '＋')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.wants.indexOf(m.number) >= 0 ? Theme.ON_ACCENT : '#FFFFFF')
        .width(27)
        .height(27)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor(this.wants.indexOf(m.number) >= 0 ? Theme.ACCENT : '#66000000')
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .border({ width: 0.5, color: '#40FFFFFF' })
        .onClick(() => {
          this.decidePick(m, 'want');
        })
      Text('✕')
        .fontSize(12)
        .fontColor(this.skips.indexOf(m.number) >= 0 ? Theme.DANGER : '#FFFFFF')
        .width(27)
        .height(27)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor('#66000000')
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .border({ width: 0.5, color: '#40FFFFFF' })
        .onClick(() => {
          this.decidePick(m, 'skip');
        })
    }
    .margin({ left: 6, top: 6 })
  }

  /**
   * 抽卡模式下的精简工具条：只留开关 + 一句说明。
   * 开关必须一直看得见 —— 否则进了抽卡模式就退不出来了。
   *
   * 七十二改：**停用**（见下方 `GachaBar` 的调用点被删掉的原因）。
   * 抽卡不再另起一条工具条，标题栏原样保留，与 tab 页（媒体库 / 收藏）一致。
   */
  @Builder
  GachaBarLegacy() {
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
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 8 })
  }

  /** 统一转场（2.6.1.18）：二级页统一 200ms 淡入，不再硬切。 */
  pageTransition(): void {
    PageTransitionEnter({ type: RouteType.None, duration: 200, curve: Curve.EaseOut })
      .opacity(0)
    PageTransitionExit({ type: RouteType.None, duration: 160, curve: Curve.EaseIn })
      .opacity(0)
  }

  @Builder
  TitleBar() {
    // 七十一改（用户选 B：第二行整体上移）：两行贴紧，中间不留 6 的空档。
    Column({ space: 0 }) {
      // 第一行：返回球 + 封面胶囊 + 名字。收藏/隐藏挪到第二行（这里给封面让位）。
      Row({ space: 8 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })

        // 封面胶囊（六十九改）：横向的——小封面 + 星级装在一颗玻璃胶囊里。
        // 下滑时整颗收起（宽度补间到 0），名字左移拿到整行；上拉再展开。
        if (this.coverOn) {
          Row({ space: 6 }) {
            if (this.kind !== 'user_tag' && (this.coverUrl.length > 0 || this.items.length > 0)) {
              this.Cover()
            }
            if (this.kind !== 'user_tag') {
              StarPick({
                score: this.myStars(),
                starSize: 14,
                gap: 1,
                onPick: (n: number) => {
                  this.rate(n);
                }
              })
            }
          }
          .padding({ left: 6, right: 8, top: 4, bottom: 4 })
          .borderRadius(17)
          .systemMaterial(ImmersiveGlass.pressMaterial(this.glassLevel, undefined))
          .clip(true)
          .transition(TransitionEffect.OPACITY)
        }

        Text(this.title.length > 0 ? this.title : facetLabel(this.kind))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 收藏 / 隐藏：第一行最右（用户 11:25：别挤到下面来）
        if (this.kind !== 'user_tag') {
          GlassGlyph({
            glyph: this.facet.isFavorite ? '♥' : '♡',
            active: this.facet.isFavorite,
            glyphSize: 15,
            mat: true,
            onTap: () => {
              this.toggleFav();
            }
          })
        }
        if (this.kind === 'tag') {
          GlassGlyph({
            glyph: this.facet.isHidden ? '⊘' : '◎',
            active: this.facet.isHidden,
            glyphSize: 15,
            mat: true,
            onTap: () => {
              this.toggleHide();
            }
          })
        }
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      // 第二行：搜索胶囊（点一下自己长成搜索栏）+ 抽卡 / 排序 / 筛选
      // 七十二改：抽卡时**这一行照旧在场** —— 与 tab 页同一个做法（只换内容区，不动标题栏）。
      // 之前抽卡时把整行藏起来、另起一条 `GachaBar`，用户一眼看出「又新开了一个布局」。
      Row({ space: 5 }) {
          GlassSearchBar({
            placeholder: '搜索番号 / 标题',
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
              this.reload();
            }
          })
          .layoutWeight(1)

          if (BuildConfig.ENABLE_GACHA) {
            GlassCapsule({
              label: this.gachaOn ? '抽卡中' : '抽卡',
              active: this.gachaOn,
              fs: 11,
              padH: 7,
              padV: 7,
              mat: true,
              onTap: () => {
                this.gachaOn = !this.gachaOn;
              }
            })
          }
          GlassCapsule({
            label: `${this.sortLabel()}`,
            fs: 11,
            padH: 7,
            padV: 7,
            maxW: 88,
            mat: true,
            onTap: () => {
              this.showSort = true;
            }
          })
          GlassCapsule({
            label: this.filterCount() > 0 ? `筛选 ${this.filterCount()}` : '筛选',
            active: this.filterCount() > 0,
            fs: 11,
            padH: 7,
            padV: 7,
            mat: true,
            onTap: () => {
              this.showFilter = true;
            }
          })
        }
        .height(42)
        .alignItems(VerticalAlign.Center)
        .width('100%')
    }
    .width('100%')
    .height('100%')
    // 用户 11:25：整个导航上移一点（状态栏下面留 8，不再空 16）
    .padding({ left: 10, right: Theme.PAGE_PAD, top: this.topInset - 8 })
  }

  // ────────────────────────────────────────────────────────────────
  // 首屏 hero（六十二改）：封面铺到屏幕最顶端（**连状态栏一起**），
  // 标题栏只是浮在它上面的一层 —— 这页的「大黑条」就是让位留白造成的。
  // ────────────────────────────────────────────────────────────────
  private heroImg(): string {
    const c: string = this.coverShown();
    if (c.length > 0) {
      return c;
    }
    return this.posterAt(0);
  }

  @Builder
  HeroBlock() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.heroImg().length > 0) {
        Image(Store.I.img(this.heroImg()))
          .width('100%')
          .height(this.topInset + 200)
          .objectFit(ImageFit.Cover)
          .blur(16)
          .backgroundColor(Theme.CARD_HI)
      } else {
        Column()
          .width('100%')
          .height(this.topInset + 200)
          .backgroundColor(Theme.CARD_HI)
      }

      // 上下两条压暗：上面给状态栏和返回键留可读性，下面融进页面底色
      Column()
        .width('100%')
        .height(this.topInset + 200)
        .linearGradient({
          angle: 180,
          colors: [['#A6000000', 0], ['#33000000', 0.38], ['#CC000000', 0.78], ['#FF000000', 1]]
        })

      Row({ space: 12 }) {
        if (this.kind !== 'user_tag' && (this.coverUrl.length > 0 || this.items.length > 0)) {
          this.Cover()
        }
        Column({ space: 4 }) {
          Text(this.title.length > 0 ? this.title : facetLabel(this.kind))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textShadow({ radius: 10, color: '#99000000', offsetX: 0, offsetY: 1 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subLine())
            .fontSize(11)
            .fontColor('#D9FFFFFF')
            .width('100%')
          if (this.kind !== 'user_tag') {
            StarPick({
              score: this.myStars(),
              starSize: 16,
              gap: 2,
              onPick: (n: number) => {
                this.rate(n);
              }
            })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 10 })
    }
    .width('100%')
  }

  @StorageProp('amaneTopInset') topInset: number = 30;
  @StorageProp('amaneGlass') glassLevel: number = 2;
  /** 封面模块是否展开（六十四改）：下滑自动收起，回到顶部自己弹出来。 */
  @State coverOn: boolean = true;
  /** 上一次的首行索引（六十六改）：靠它判方向 —— 下滑收、上拉放，不用拉到顶。 */
  private lastFirst: number = -1;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。46 第一行 + 42 第二行，无间隙。 */
  private barH(): number {
    return this.topInset + 88;
  }

  /** 标题栏配置：高度 = 状态栏 + 88，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      // 六十九改：封面改成**横向胶囊**放进第一行，收起只是横向缩没，不改高度 → 不会留空档。
      height: 88 + this.topInset
    };
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {

          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(10)
              .fontColor(Theme.DANGER)
              .width('100%')
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
          }


          if (this.gachaOn) {
            // 七十二改：**照 tab 页（媒体库 BrowseGrid / 收藏 FavoritesTab）的版式** ——
            // 标题栏原封不动，只把内容区换成抽卡墙。不再另起 `GachaBar`，也不再自己套一层
            // `Scroll`（墙内部就是 WaterFlow，自己会滚）。
            //
            // 首屏让位交给水墙自己的 `topPad`（**滚动内边距**，一滑就收成 0、图顶到物理屏顶）；
            // 写在外层 Column 的 padding 上是死留白，滚了也不动，那就永远做不到真全屏。
            // 墙头（剧照 · 范围 · 开关）不画：范围已在本页第一行，退出抽卡靠第二行那颗高亮的「抽卡中」。
            Column() {
              GachaWall({
                scope: this.kind,
                scopeId: this.facetId,
                label: this.title,
                count: 0,
                hideHeader: true,
                topPad: this.barH() + 6,
                gachaOn: this.gachaOn,
                onToggleGacha: (v: boolean) => {
                  this.gachaOn = v;
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 0, bottom: 0 })
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
                .onClick(() => {
                  this.loading = true;
                  this.load(0, false);
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.items.length === 0) {
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.film'))
                .fontSize(28)
                .fontColor([Theme.TEXT_FAINT])
              Text(this.keyword.length > 0
                ? `没有找到「${this.keyword}」`
                : (this.filterCount() > 0 ? '没有符合筛选条件的影片' : '这个分类下还没有影片'))
                .fontSize(13)
                .fontColor(Theme.TEXT_DIM)
              if (this.keyword.length > 0) {
                Text('换个关键词，或清空搜索看全部')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
              } else if (this.filterCount() > 0) {
                Text('重置筛选')
                  .fontSize(12)
                  .fontColor(Theme.ACCENT)
                  .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                  .backgroundColor(Theme.ACCENT_SOFT)
                  .borderRadius(14)
                  .onClick(() => {
                    this.resetFilters();
                  })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Grid() {
              ForEach(this.items, (m: FacetMediaItem) => {
                GridItem() {
                  this.Cell(m)
                }
              }, (m: FacetMediaItem) => `fm-${m.id}`)

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
                  .height(120)
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
            .columnsGap(8)
            .rowsGap(14)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: this.barH() + 6, bottom: Theme.pageBottomSafe() })
            .layoutWeight(1)
            .cachedCount(6)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd(() => {
              this.loadMore();
            })
            // 六十六改：按**方向**触发，不再等回到顶 —— 下滑收、上拉放（200ms 补间）
            .onScrollIndex((first: number) => {
              const up: boolean = this.lastFirst >= 0 && first < this.lastFirst;
              const down: boolean = this.lastFirst >= 0 && first > this.lastFirst;
              this.lastFirst = first;
              if (down && this.coverOn) {
                this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                  this.coverOn = false;
                });
              } else if (up && !this.coverOn) {
                this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                  this.coverOn = true;
                });
              }
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
              options: this.sorts,
              current: this.sortBy,
              order: this.order,
              tabInset: 0,
              onPick: (key: string) => {
                if (this.sortBy !== key) {
                  this.sortBy = key;
                  this.order = sortDefOf(key);
                }
                // 随机再点一次 = 重摇一批
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
      // 六十五改：让**内容**铺进上下系统栏 —— 海报要能画到状态栏/导航条后面，
      // 只在 Navigation 上挂 expandSafeArea 是不够的（那只是让导航壳变大，内容照样被裁）。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor(Theme.BG)
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
