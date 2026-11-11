import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { BuildConfig } from '../../common/BuildConfig';
import { ChipOption, SortOption } from '../../common/BrowseOptions';
import { MergeBar } from '../merge/MergeBar';
import { KeywordBox } from '../../view/KeywordBox';
import { BottomSheet, ChipGroup, ChipRow, SortSheet, ToolPill } from '../../view/ListSheets';
import {
  FacetItem, FacetList, FacetParams, FacetPick, facetLabel, pickOf, safeFacetList
} from './FacetTypes';

const PAGE_SIZE: number = 40;

/**
 * 公开扩展 facets：底部「标签」Tab —— 分类浏览入口。
 *
 * 为什么要单独一页：影片详情里的标签以前只是死文本，媒体库只能按库翻，
 * 想「顺着一个标签看下去」没有入口。这里把上游统一的 facet 体系
 * （标签 / 系列 / 制片商 / 我的标签）做成同一套网格，点进去就是该分类的影片墙。
 *
 * 这一版补三件事：
 *  - 系列 / 标签卡片左侧拼最近几部的海报，系列一眼能认出来（标签的缩略图
 *    只在这一页出现，影片详情页的标签行保持纯文字）；
 *  - 卡片右下角可以直接收藏这个分类。分类收藏是 amane 自己的 is_favorite 位，
 *    和「影片收藏 → 自动入库」是两条链路，这里不写收藏表也不搬文件；
 *  - 排序多了「最近更新」（分类内最新一部影片的入库时间）和「最新发布」
 *    （分类内最晚发行日），由服务端算好再返回。
 *
 * 阅览体验取舍：
 *  - 默认按「作品数」倒序，先看到真正有内容的大分类，而不是名字排序的头几个生僻词；
 *  - 三个卡片一行、缩略图铺满整张卡、名字压在底部渐变上：图片是主角，一屏能看十几个；

 *  - 搜索防抖 350ms，切换分类立即重载，触底自动续页。
 */
@Component
export struct FacetsTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State items: FacetItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State tip: string = '';
  @State keyword: string = '';
  @State kind: string = 'tag';
  @State sortBy: string = 'count';
  @State order: string = 'desc';
  @State onlyFav: boolean = false;
  /** 随机排序的 seed：翻页带回去，顺序才不会每页重摇。 */
  @State seed: number = 0;
  /** 是否把隐藏的标签也列出来（默认不列）。 */
  @State includeHidden: boolean = false;
  @State hiddenCount: number = 0;
  /** 多选合并态：长按卡片进入，这时候点卡片是「选中」而不是「进去」。 */
  @State selecting: boolean = false;
  /** 选中项自带名字/作品数：换搜索词、翻页后当前列表里可能已经没有它了。 */
  @State picked: FacetPick[] = [];
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  private tipTimer: number = -1;
  private kinds: ChipOption[] = [
    { key: 'tag', label: '标签' },
    { key: 'series', label: '系列' },
    { key: 'director', label: '导演' },
    { key: 'studio', label: '制片商' },
    { key: 'user_tag', label: '我的标签' }
  ];
  private favOptions: ChipOption[] = [
    { key: '', label: '不限' },
    { key: '1', label: '♥ 只看收藏' }
  ];

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
  }

  onRefresh(): void {
    this.reload();
  }

  /** 只有标签和系列有「最近更新 / 最新发布」：其他分类的影片量太小，加了也是噪音。 */
  private hasTimeSort(): boolean {
    return this.kind === 'tag' || this.kind === 'series';
  }

  /**
   * 导演 / 制片商走「长条」版式：一行一个，横排 8 张海报连成一大条。
   *
   * 为什么单独给这两种：标签和系列的名字短、彼此靠名字区分，3 列网格一屏能看十五个；
   * 导演和制片商要靠「拍了哪些片」来认人/认厂，3 列小卡只塞得下 3 张图，
   * 一条长图的辨识度高得多（用户明确要求「每一排一个导演」）。
   * 这不是漏改成网格，是两种版式。
   */
  private isLane(): boolean {
    return this.kind === 'director' || this.kind === 'studio';
  }

  private pageSize(): number {
    return this.isLane() ? 20 : PAGE_SIZE;
  }

  private sortOptions(): SortOption[] {
    if (this.hasTimeSort()) {
      return [
        { key: 'count', label: '作品数', def: 'desc' },
        { key: 'name', label: '名称', def: 'asc' },
        { key: 'recent_update', label: '最近更新', def: 'desc' },
        { key: 'recent_release', label: '最新发布', def: 'desc' },
        { key: 'random', label: '随机', def: 'desc' }
      ];
    }
    return [
      { key: 'count', label: '作品数', def: 'desc' },
      { key: 'name', label: '名称', def: 'asc' }
    ];
  }

  /** 抽屉里「隐藏」这一组的文案：把数量写进选项里，不用再单开一行提示。 */
  private hiddenOptions(): ChipOption[] {
    return [
      { key: '', label: '不列出' },
      { key: '1', label: this.hiddenCount > 0 ? `列出隐藏 ${this.hiddenCount}` : '列出隐藏' }
    ];
  }

  /** 生效的筛选条数（排序不算）：只看收藏 / 列出隐藏。 */
  private filterCount(): number {
    let n: number = 0;
    if (this.onlyFav) {
      n++;
    }
    if (this.includeHidden) {
      n++;
    }
    return n;
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${this.pageSize()}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`
    ];
    if (this.keyword.length > 0) {
      parts.push(`search=${encodeURIComponent(this.keyword)}`);
    }
    // 上游只有 tag/series/studio/publisher 支持 favorite；user_tag 传了会 400
    if (this.onlyFav && this.kind !== 'user_tag') {
      parts.push('favorite=true');
    }
    if (this.includeHidden) {
      parts.push('include_hidden=true');
    }
    if (this.sortBy === 'random' && this.seed > 0) {
      parts.push(`seed=${this.seed}`);
    }
    return `${Store.I.user}/api/user/facets/${this.kind}?${parts.join('&')}`;
  }

  private reload(): void {
    this.items = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      const text: string = await httpGet(this.buildUrl(offset), Store.I.token);
      const data: FacetList = safeFacetList(JSON.parse(text) as FacetList);
      this.items = append ? this.items.concat(data.items) : data.items;
      this.total = data.total;
      this.seed = data.seed;
      this.hiddenCount = data.hiddenCount;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facets: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404
          ? '服务端未启用分类扩展（需 amane-user 1.3.3+）'
          : '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.items.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.load(this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private showTip(text: string): void {
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
    this.tip = text;
    this.tipTimer = setTimeout(() => {
      this.tipTimer = -1;
      this.tip = '';
    }, 2600);
  }

  /**
   * 换大类。切走时要顺手清掉这个大类不支持的筛选/排序，
   * 否则会出现「按钮消失了但条件还在生效」——用户看到一个筛过的列表却找不到原因。
   */
  private pickKind(key: string): void {
    if (this.kind === key) {
      return;
    }
    this.kind = key;
    this.endSelect();
    // user_tag 不支持 favorite 筛选
    if (key === 'user_tag') {
      this.onlyFav = false;
    }
    // 只有标签有隐藏位
    if (key !== 'tag') {
      this.includeHidden = false;
    }
    // 切到不支持时间排序的分类时把排序拉回作品数，否则会带一个它没有的排序值
    if (!this.hasTimeSort() && (this.sortBy === 'recent_update' ||
      this.sortBy === 'recent_release')) {
      this.sortBy = 'count';
      this.order = 'desc';
    }
    this.showSort = false;
    this.showFilter = false;
    this.reload();
  }

  /**
   * 点排序项：只负责「换成这一项」，方向由抽屉里当前行的 ↑/↓ 单独控制。
   * 再点一次「随机」= 重摇一批（清掉 seed，让服务端重新发一个）。
   */
  private pickSort(key: string): void {
    this.sortBy = key;
    if (key === 'random') {
      this.seed = 0;
      this.reload();
      return;
    }
    this.order = key === 'name' ? 'asc' : 'desc';
    this.seed = 0;
    this.reload();
  }

  private toggleOrder(): void {
    this.order = this.order === 'desc' ? 'asc' : 'desc';
    this.reload();
  }

  /** 工具条胶囊上的短标签（长句塞不进胶囊）。 */
  private sortLabel(): string {
    for (let i = 0; i < this.sortOptions().length; i++) {
      if (this.sortOptions()[i].key === this.sortBy) {
        return this.sortOptions()[i].label;
      }
    }
    return '作品数';
  }

  private open(f: FacetItem): void {
    const params: FacetParams = { kind: this.kind, id: f.id, name: f.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: params });
  }

  private isPicked(id: number): boolean {
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 长按起手：进入多选并把按住的这一项捎上。 */
  private beginSelect(f: FacetItem): void {
    if (!BuildConfig.ENABLE_FACET_MULTISELECT) {
      return;
    }
    this.selecting = true;
    if (!this.isPicked(f.id)) {
      this.picked = this.picked.concat([pickOf(f)]);
    }
  }

  /**
   * 点选 / 取消。选中项连名字和作品数一起存，所以换搜索词、翻页之后
   * 它即使不在当前列表里，也仍然是一个完整可用的选中项。
   */
  private togglePick(f: FacetItem): void {
    const next: FacetPick[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].id === f.id) {
        removed = true;
      } else {
        next.push(this.picked[i]);
      }
    }
    if (!removed) {
      next.push(pickOf(f));
    }
    this.picked = next;
    if (next.length === 0) {
      this.selecting = false;
    }
  }

  /**
   * 「已选」面板里摘掉一项。摘空了也**不退**多选：
   * 面板正开着的时候把操作条抽掉，等于在弹层上抽掉自己的宿主，容易闪一下。
   * 退出多选只走「取消」那一路。
   */
  private removePick(id: number): void {
    const next: FacetPick[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].id !== id) {
        next.push(this.picked[i]);
      }
    }
    this.picked = next;
  }

  private endSelect(): void {
    this.selecting = false;
    this.picked = [];
  }

  /** 多选结束：重拉列表。 */
  private onMerged(): void {
    this.reload();
  }

  /**
   * 分类收藏：先本地翻转再落库，失败时回滚。
   *
   * 收藏位是服务端的布尔值（动作是「置为」不是「取反」），所以要把目标值传上去，
   * 连点两下也不会因为请求乱序而停在错误状态之外——最后到达的那次带的是它自己的目标值。
   */
  private async toggleFav(f: FacetItem): Promise<void> {
    if (f.id <= 0) {
      return;
    }
    const want: boolean = !f.isFavorite;
    this.applyFav(f.id, want);
    const body: string = JSON.stringify({ favorite: want });
    try {
      await httpPost(`${Store.I.user}/api/user/facets/${this.kind}/${f.id}/favorite`, Store.I.token, body);
      if (this.onlyFav && !want) {
        this.reload();
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet favorite: ${e.code} ${e.message}`);
      this.applyFav(f.id, !want);
      this.showTip(e.code === 404
        ? `服务端未启用分类收藏（${Store.I.user}，需 1.3.3+）`
        : '收藏失败，请重试');
    }
  }

  private applyFav(id: number, fav: boolean): void {
    const next: FacetItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: FacetItem = this.items[i];
      if (it.id !== id) {
        next.push(it);
        continue;
      }
      next.push({
        id: it.id, name: it.name, count: it.count, posters: it.posters,
        posterItems: it.posterItems,
        topTags: it.topTags,
        isFavorite: fav, lastRelease: it.lastRelease, lastAdded: it.lastAdded,
        isHidden: it.isHidden, prefixes: it.prefixes
      });
    }
    this.items = next;
  }

  /**
   * 系列 / 标签封面：最多三张海报横向并排，铺满整张卡片。
   * 与影片详情页的系列条、分类影片墙标题栏保持同一套「三张横排」视觉。
   */
  @Builder
  Cell(f: FacetItem) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Row({ space: 1 }) {
          if (f.posters.length === 0) {
            Column() {
              Text(this.kind === 'series' ? '系' : '#')
                .fontSize(18)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.CARD_HI)
          } else {
            ForEach(f.posters.slice(0, 3), (p: string, i: number) => {
              Image(Store.I.img(p))
                .width(`${(100 / Math.min(3, f.posters.length)).toFixed(2)}%`)
                .height('100%')
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD_HI)
                .alt($r('app.media.placeholder'))
            }, (p: string, i: number) => `fp-${f.id}-${i}`)
          }
        }
        .width('100%')
        .height('100%')

        // 底部渐变：名字压在图上也要看得清，同时不再为文字单独留一块空白
        Column()
          .width('100%')
          .height('58%')
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0], ['#B80B0B0F', 0.5], ['#F20B0B0F', 1]]
          })

        Column({ space: 1 }) {
          Text(f.name.length > 0 ? f.name : '未命名')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(2)
            .lineHeight(14)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(f.isHidden ? `${f.count} 部 · 已隐藏` : `${f.count} 部`)
            .fontSize(9)
            .fontColor(f.isHidden ? Theme.GOLD : '#B9B9C6')
            .maxLines(1)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 6, top: 2 })
      }
      .width('100%')
      .height('100%')

      Text(f.isFavorite ? '♥' : '♡')
        .fontSize(13)
        .fontColor(f.isFavorite ? Theme.ACCENT : '#FFFFFF')
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .backgroundColor('#8C000000')
        .borderRadius(11)
        .margin({ top: 5, right: 5 })
        .onClick(() => {
          this.toggleFav(f);
        })
    }
    .width('100%')
    .height(92)
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(10)
    .border({ width: this.isPicked(f.id) ? 2 : 0, color: Theme.ACCENT })
    .clip(true)
    .opacity(f.isHidden ? 0.55 : 1)
    .onClick(() => {
      if (this.selecting) {
        this.togglePick(f);
      } else {
        this.open(f);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.beginSelect(f);
        })
    )
  }

  /**
   * 长条卡（导演 / 制片商）：一整排海报 + 左下角名字。
   *
   * 张数由服务端给（POSTER_KINDS：导演/制片商 8 张），这里按实际数量均分宽度，
   * 所以只有 3 部的冷门导演也能铺满整条，不会右边空一截。
   */
  @Builder
  LaneCell(f: FacetItem) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Row() {
          if (f.posters.length === 0) {
            Column() {
              Text(this.kind === 'director' ? '导' : '厂')
                .fontSize(20)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.CARD_HI)
          } else {
            ForEach(f.posters, (p: string, i: number) => {
              Image(Store.I.img(p))
                .width(`${(100 / f.posters.length).toFixed(2)}%`)
                .height('100%')
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD_HI)
                .alt($r('app.media.placeholder'))
            }, (p: string, i: number) => `lp-${f.id}-${i}`)
          }
        }
        .width('100%')
        .height('100%')

        // 左侧到右下的渐变：名字压在照片上也要看得清
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 90,
            colors: [['#E60B0B0F', 0], ['#A60B0B0F', 0.45], ['#00000000', 1]]
          })

        Column({ space: 2 }) {
          Text(f.name.length > 0 ? f.name : '未命名')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.laneSub(f))
            .fontSize(9)
            .fontColor(f.isHidden ? Theme.GOLD : '#C7C7D2')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('58%')
        .padding({ left: 11, right: 11, bottom: 10 })
      }
      .width('100%')
      .height('100%')

      Text(f.isFavorite ? '♥' : '♡')
        .fontSize(13)
        .fontColor(f.isFavorite ? Theme.ACCENT : '#FFFFFF')
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .backgroundColor('#8C000000')
        .borderRadius(12)
        .margin({ top: 6, right: 6 })
        .onClick(() => {
          this.toggleFav(f);
        })
    }
    .width('100%')
    .height(104)
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(12)
    .border({ width: this.isPicked(f.id) ? 2 : 0, color: Theme.ACCENT })
    .clip(true)
    .opacity(f.isHidden ? 0.55 : 1)
    .onClick(() => {
      if (this.selecting) {
        this.togglePick(f);
      } else {
        this.open(f);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.beginSelect(f);
        })
    )
  }

  /** 长条卡副标题：片数 + 番号前缀 + 最近上映（没有的就跳过）。 */
  private laneSub(f: FacetItem): string {
    const parts: string[] = [`${f.count} 部`];
    // 制片商 / 发行商才带前缀：日文厂牌名认不出来时，SPSD/GHKQ 这种字母更好认
    if (f.prefixes.length > 0) {
      parts.push(f.prefixes.join('/'));
    }
    if (f.lastRelease.length > 0) {
      parts.push(`最近 ${f.lastRelease}`);
    }
    if (f.isHidden) {
      parts.push('已隐藏');
    }
    return parts.join(' · ');
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Text(facetLabel(this.kind))
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
      Blank()
      Text(this.loading ? '' : `${this.total} 项`)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8, bottom: 6 })
  }

  /** 标签 / 系列 / 导演 / 制片商 / 我的标签：换大类，属于导航不是筛选。 */
  @Builder
  KindRow() {
    Scroll() {
      ChipRow({
        options: this.kinds,
        current: this.kind,
        onPick: (key: string) => {
          this.pickKind(key);
        }
      })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
  }

  @Builder
  SearchBar() {
    Row() {
      KeywordBox({
        placeholder: `搜索${facetLabel(this.kind)}名`,
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
    Row({ space: 8 }) {
      Text(this.keyword.length > 0 ? '相关度优先' : '')
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .layoutWeight(1)

      ToolPill({
        label: `⇅ ${this.sortLabel()}` +
          (this.sortBy === 'random' ? '' : (this.order === 'desc' ? ' ↓' : ' ↑')),
        onTap: () => {
          this.showSort = true;
        }
      })

      // user_tag 既没有收藏位也没有隐藏位，抽屉会是空的 —— 干脆不给入口
      if (this.kind !== 'user_tag') {
        ToolPill({
          label: this.filterCount() > 0 ? `⚙ 筛选 ${this.filterCount()}` : '⚙ 筛选',
          active: this.filterCount() > 0,
          onTap: () => {
            this.showFilter = true;
          }
        })
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 8 })
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: `筛选${facetLabel(this.kind)}`,
      actionLabel: '重置',
      onAction: () => {
        this.onlyFav = false;
        this.includeHidden = false;
        this.reload();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      tabInset: 84
    }) {
      if (this.kind !== 'user_tag') {
        ChipGroup({
          title: '收藏', options: this.favOptions, current: this.onlyFav ? '1' : '',
          onPick: (key: string) => {
            const want: boolean = key === '1';
            if (this.onlyFav === want) {
              return;
            }
            this.onlyFav = want;
            this.reload();
          }
        })
      }
      if (this.kind === 'tag') {
        ChipGroup({
          title: '隐藏', options: this.hiddenOptions(), current: this.includeHidden ? '1' : '',
          onPick: (key: string) => {
            const want: boolean = key === '1';
            if (this.includeHidden === want) {
              return;
            }
            this.includeHidden = want;
            this.reload();
          }
        })
      }
      if (this.kind === 'series') {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text('按属性筛系列')
              .fontSize(13)
              .fontColor(Theme.TEXT)
            Text('选若干标签，找同时具备这些属性的系列')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(16)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          router.pushUrl({ url: 'ext/facets/SeriesByTagPage' });
        })
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Header()
        this.KindRow()
        this.SearchBar()
        this.Toolbar()

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(10)
            .fontColor(Theme.DANGER)
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
        }

        if (this.loading) {
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
            Text('⌗')
              .fontSize(32)
              .fontColor(Theme.TEXT_FAINT)
            Text(this.error)
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .onClick(() => {
                this.reload();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column({ space: 10 }) {
            Text('⌗')
              .fontSize(34)
              .fontColor(Theme.TEXT_FAINT)
            Text(this.keyword.length > 0
              ? `没有找到「${this.keyword}」`
              : (this.onlyFav ? '还没有收藏的分类' : `还没有${facetLabel(this.kind)}数据`))
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text(this.keyword.length > 0
              ? '换个关键字试试'
              : (this.onlyFav ? '点卡片右下角的小心心收藏这个分类' : '先去媒体库刮削几部影片'))
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.items, (f: FacetItem) => {
              GridItem() {
                if (this.isLane()) {
                  this.LaneCell(f)
                } else {
                  this.Cell(f)
                }
              }
            }, (f: FacetItem) => `facet-${this.kind}-${f.id}-${f.isFavorite ? 1 : 0}` +
              `-${this.selecting ? 1 : 0}${this.isPicked(f.id) ? 1 : 0}`)

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
                .height(this.isLane() ? 52 : 92)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.loadMore();
                })
              }
            }
          }
          .columnsTemplate(this.isLane() ? '1fr' : '1fr 1fr 1fr')
          .columnsGap(9)
          .rowsGap(9)
          // 平时底部留 84 给悬浮胶囊；多选时操作条自己让出了胶囊的位置，这里就收回
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: this.selecting ? 10 : 84 })
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.loadMore();
          })
        }

        // 选中项自带名字，所以换搜索词继续选，已选的那几个不会丢。
        if (this.selecting) {
          MergeBar({
            kind: this.kind,
            picked: this.picked,
            onRemove: (id: number) => {
              this.removePick(id);
            },
            onCancel: () => {
              this.endSelect();
              this.reload();
            },
            onMerged: () => {
              this.onMerged();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)

      // 抽屉层：盖住整页，交给外层 Stack 贴底。和多选操作条同时出现时它在上面。
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
            current: this.sortBy,
            order: this.order,
            tabInset: 84,
            onPick: (key: string) => {
              // 已经选中的那一项：非随机就只是关掉抽屉；随机 = 重摇一批
              if (this.sortBy === key && key !== 'random') {
                this.showSort = false;
                return;
              }
              this.pickSort(key);
              this.showSort = false;
            },
            onToggleOrder: () => {
              this.toggleOrder();
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
