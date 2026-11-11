import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams, MediaItem } from '../../common/Types';
import { BrowseResult } from '../../common/Types';
import { safeItems } from '../../common/Safe';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import { KeywordBox } from '../../view/KeywordBox';
import { BottomSheet, ChipGroup, SortSheet, ToolPill } from '../../view/ListSheets';
import { ChipOption, MYRATING_OPTIONS, SortOption, sortDefOf } from '../../common/BrowseOptions';
import { collectionChipOptions } from '../collections/CollectionTypes';
import { BuildConfig } from '../../common/BuildConfig';
import { GachaSwitch } from '../stills/GachaSwitch';
import { GachaWall } from '../stills/GachaWall';
import {
  FacetFavoriteResult, FacetItem, FacetMediaItem, FacetMediaList, FacetParams,
  emptyFacet, facetLabel, safeFacetMediaList
} from './FacetTypes';

const PAGE_SIZE: number = 30;

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
@Entry
@Component
struct FacetPage {
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
      this.facetId = Number(p.id);
      this.title = p.name === undefined || p.name === null ? '' : p.name;
    }
    // 默认进不进抽卡模式由设置页决定（列表页仍是默认视图）
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
    this.loadCollections();
    this.loadPropTags();
    this.load(0, false);
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
  }

  private async load(offset: number, append: boolean): Promise<void> {
    if (this.facetId <= 0) {
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
    if (this.kind === 'tag') {
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
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
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

  private setFav(fav: boolean): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, posterItems: this.facet.posterItems,
      topTags: this.facet.topTags, isFavorite: fav,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: this.facet.isHidden, prefixes: this.facet.prefixes
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
      // 404 有两种可能：服务端太旧，或者 App 连错端口（测试版 8771 / 正式版 8770）——
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
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: hidden, prefixes: this.facet.prefixes
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
    .borderRadius(8)
    .clip(true)
    .backgroundColor(Theme.CARD_HI)
    .margin({ right: 10 })
  }

  @Builder
  Header() {
    Row() {
      Text('‹')
        .fontSize(24)
        .fontColor(Theme.TEXT)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      if (this.kind === 'series' && this.items.length > 0) {
        this.Cover()
      }
      Column({ space: 3 }) {
        Text(this.title.length > 0 ? this.title : facetLabel(this.kind))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subLine())
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 分类收藏：与详情页的影片收藏是两条链路，这里只写 amane 的 is_favorite 位
      if (this.kind !== 'user_tag') {
        Column({ space: 1 }) {
          Text(this.facet.isFavorite ? '♥' : '♡')
            .fontSize(17)
            .fontColor(this.facet.isFavorite ? Theme.ACCENT : Theme.TEXT_DIM)
          Text(this.facet.isFavorite ? '已收藏' : '收藏')
            .fontSize(8)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(40)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleFav();
        })
      }

      // 隐藏：只在标签上开。隐藏只是不在「标签」列表里列出来，
      // 不删标签、不动刮削规则 —— 用户明确说懒得因此改刮削设置。
      if (this.kind === 'tag') {
        Column({ space: 1 }) {
          Text(this.facet.isHidden ? '⊘' : '◎')
            .fontSize(16)
            .fontColor(this.facet.isHidden ? Theme.GOLD : Theme.TEXT_DIM)
          Text(this.facet.isHidden ? '已隐藏' : '隐藏')
            .fontSize(8)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(40)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleHide();
        })
      }
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 一行工具条：部数 / 抽卡开关 / ⇅ 排序 / ⚙ 筛选。
   * 2.4.6.26 起原来的「筛选折叠头 + 排序行 + 属性行 + 片源行 + 字幕行」全部收进抽屉，
   * 与小标签页、媒体库、演员页同一形状。
   */
  @Builder
  Toolbar() {
    Row({ space: 8 }) {
      Text(this.keyword.length > 0 ? `「${this.keyword}」${this.total} 部` : `${this.total} 部`)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .layoutWeight(1)

      if (BuildConfig.ENABLE_GACHA) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.gachaOn = v;
          }
        })
      }

      ToolPill({
        label: `⇅ ${this.sortLabel()}${this.sortBy === 'random' ? '' : (this.order === 'asc' ? ' ↑' : ' ↓')}`,
        onTap: () => {
          this.showSort = true;
        }
      })

      ToolPill({
        label: this.filterCount() > 0 ? `⚙ 筛选 ${this.filterCount()}` : '⚙ 筛选',
        active: this.filterCount() > 0,
        onTap: () => {
          this.showFilter = true;
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4, bottom: 8 })
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
            .fontColor(this.pickedTags.indexOf(tg.id) >= 0 ? '#FFFFFF' :
              (tg.ratio >= 0.5 ? Theme.TEXT_DIM : Theme.TEXT_FAINT))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.pickedTags.indexOf(tg.id) >= 0 ? Theme.ACCENT : Theme.CARD)
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.toggleTag(tg.id);
            })
        }, (tg: TagStat) => 'pt-' + tg.id)
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
    PosterCard({
      item: this.cardOf(m),
      fluid: true,
      onTap: () => {
        const p: DetailParams = { id: m.id };
        router.pushUrl({ url: 'pages/DetailPage', params: p });
      }
    })
  }

  /**
   * 抽卡模式下的精简工具条：只留开关 + 一句说明。
   * 开关必须一直看得见 —— 否则进了抽卡模式就退不出来了。
   */
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
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Header()

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(10)
            .fontColor(Theme.DANGER)
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
        }

        // 抽卡模式下搜索/排序/筛选都收起来：那一堵墙不吃这些条件，摆着只会误导
        if (!this.gachaOn) {
          Row() {
            KeywordBox({
              placeholder: `在${facetLabel(this.kind)}里搜番号 / 标题`,
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
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 4 })

          this.Toolbar()
        }

        if (this.gachaOn) {
          this.GachaBar()
          Scroll() {
            Column() {
              GachaWall({
                scope: this.kind,
                scopeId: this.facetId,
                label: this.title,
                count: 0,
                gachaOn: this.gachaOn,
                onToggleGacha: (v: boolean) => {
                  this.gachaOn = v;
                }
              })
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 24 })
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
            Text('▤')
              .fontSize(32)
              .fontColor(Theme.TEXT_FAINT)
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
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(14)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
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
    .backgroundColor(Theme.BG)
  }
}
