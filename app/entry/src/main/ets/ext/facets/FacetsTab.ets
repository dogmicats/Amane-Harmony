import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { BuildConfig } from '../../common/BuildConfig';
import { MergeBar } from '../merge/MergeBar';
import {
  FacetItem, FacetList, FacetParams, facetLabel, safeFacetList
} from './FacetTypes';

const PAGE_SIZE: number = 40;

interface Choice {
  key: string;
  label: string;
}

/** chip 必须是子组件：@Builder 按值传参不刷新，选中态会停在初始值。 */
@Component
struct FacetChoiceChips {
  options: Choice[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Row({ space: 7 }) {
      ForEach(this.options, (opt: Choice) => {
        Text(opt.label)
          .fontSize(11)
          .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.onPick(opt.key);
          })
      }, (opt: Choice) => `fchoice-${opt.key}`)
    }
  }
}

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
  @State picked: number[] = [];
  private searchTimer: number = -1;
  private tipTimer: number = -1;
  private kinds: Choice[] = [
    { key: 'tag', label: '标签' },
    { key: 'series', label: '系列' },
    { key: 'director', label: '导演' },
    { key: 'studio', label: '制片商' },
    { key: 'user_tag', label: '我的标签' }
  ];

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
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

  private sortOptions(): Choice[] {
    if (this.hasTimeSort()) {
      return [
        { key: 'count', label: '作品数' },
        { key: 'name', label: '名称' },
        { key: 'recent_update', label: '最近更新' },
        { key: 'recent_release', label: '最新发布' },
        { key: 'random', label: '随机' }
      ];
    }
    return [
      { key: 'count', label: '作品数' },
      { key: 'name', label: '名称' }
    ];
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

  private onKeyword(value: string): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const kw: string = value;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.keyword = kw;
      this.reload();
    }, 350);
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

  private pickSort(key: string): void {
    if (key === 'random') {
      // 再点一次「随机」= 重摇一批（清掉 seed，让服务端重新发一个）
      this.sortBy = 'random';
      this.seed = 0;
      this.reload();
      return;
    }
    if (this.sortBy === key) {
      this.order = this.order === 'desc' ? 'asc' : 'desc';
    } else {
      this.sortBy = key;
      this.order = key === 'name' ? 'asc' : 'desc';
    }
    this.seed = 0;
    this.reload();
  }

  private toggleOrder(): void {
    this.order = this.order === 'desc' ? 'asc' : 'desc';
    this.reload();
  }

  private sortLabel(): string {
    // 作品数用「从多到少」更好懂，名称用「A→Z / Z→A」
    if (this.sortBy === 'name') {
      return this.order === 'asc' ? '名称 A→Z' : '名称 Z→A';
    }
    if (this.sortBy === 'recent_update') {
      return this.order === 'desc' ? '最近更新 新→旧' : '最近更新 旧→新';
    }
    if (this.sortBy === 'recent_release') {
      return this.order === 'desc' ? '最新发布 新→旧' : '最新发布 旧→新';
    }
    if (this.sortBy === 'random') {
      return '随机 · 再点一次重摇';
    }
    return this.order === 'desc' ? '作品数 多→少' : '作品数 少→多';
  }

  private open(f: FacetItem): void {
    const params: FacetParams = { kind: this.kind, id: f.id, name: f.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: params });
  }

  private isPicked(id: number): boolean {
    return this.picked.indexOf(id) >= 0;
  }

  /** 长按起手：进入多选并把按住的这一项捎上。 */
  private beginSelect(f: FacetItem): void {
    if (!BuildConfig.ENABLE_FACET_MULTISELECT) {
      return;
    }
    this.selecting = true;
    this.picked = [f.id];
  }

  private togglePick(f: FacetItem): void {
    const next: number[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === f.id) {
        removed = true;
      } else {
        next.push(this.picked[i]);
      }
    }
    if (!removed) {
      next.push(f.id);
    }
    this.picked = next;
    if (next.length === 0) {
      this.selecting = false;
    }
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
        isFavorite: fav, lastRelease: it.lastRelease, lastAdded: it.lastAdded,
        isHidden: it.isHidden
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

  /** 长条卡副标题：片数 + 最近上映（日期都没有时只说片数）。 */
  private laneSub(f: FacetItem): string {
    const parts: string[] = [`${f.count} 部`];
    if (f.lastRelease.length > 0) {
      parts.push(`最近 ${f.lastRelease}`);
    }
    if (f.isHidden) {
      parts.push('已隐藏');
    }
    return parts.join(' · ');
  }

  @Builder
  Toolbar() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(facetLabel(this.kind))
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`${this.total} 项 · ${this.sortLabel()}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      Scroll() {
        FacetChoiceChips({
          options: this.kinds,
          current: this.kind,
          onPick: (key: string) => {
            if (this.kind === key) {
              return;
            }
            this.kind = key;
            this.endSelect();
            // user_tag 不支持 favorite 筛选，切过去时清掉，避免按钮消失但条件还生效
            if (key === 'user_tag') {
              this.onlyFav = false;
            }
            // 切到不支持时间排序的分类时把排序拉回作品数，否则会带一个它没有的排序值
            if (!this.hasTimeSort() && (this.sortBy === 'recent_update' ||
              this.sortBy === 'recent_release')) {
              this.sortBy = 'count';
              this.order = 'desc';
            }
            this.reload();
          }
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)

      TextInput({ placeholder: `搜索${facetLabel(this.kind)}名` })
        .height(38)
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 12 })
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((value: string) => {
          this.onKeyword(value);
        })

      Row({ space: 8 }) {
        Scroll() {
          FacetChoiceChips({
            options: this.sortOptions(),
            current: this.sortBy,
            onPick: (key: string) => {
              this.pickSort(key);
            }
          })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Start)

        // 显式方向开关：↓ = 多到少 / Z→A / 新到旧，↑ = 反向
        Text(this.order === 'desc' ? '↓' : '↑')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(30)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.order === 'desc' ? Theme.ACCENT : Theme.CARD_HI)
          .borderRadius(13)
          .visibility(this.sortBy === 'random' ? Visibility.None : Visibility.Visible)
          .onClick(() => {
            this.toggleOrder();
          })

      }
      .width('100%')

      // 「收藏 / 显示隐藏」单独一行：和排序 chip 挤一行会把「随机」挤到屏幕外，
      // 用户根本不知道有随机排序。
      Row({ space: 8 }) {
        if (this.kind !== 'user_tag') {
          Text(this.onlyFav ? '♥ 只看收藏' : '♡ 只看收藏')
            .fontSize(11)
            .fontColor(this.onlyFav ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.onlyFav ? Theme.ACCENT : Theme.CARD)
            .borderRadius(12)
            .onClick(() => {
              this.onlyFav = !this.onlyFav;
              this.reload();
            })
        }

        // 隐藏是标签自己的偏好：默认不列出来，想找回来看这里
        if (this.kind === 'tag') {
          Text(this.includeHidden
            ? (this.hiddenCount > 0 ? `⊘ 列出隐藏中 ${this.hiddenCount}` : '⊘ 列出隐藏')
            : (this.hiddenCount > 0 ? `◎ 显示隐藏 ${this.hiddenCount}` : '◎ 显示隐藏'))
            .fontSize(11)
            .fontColor(this.includeHidden ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.includeHidden ? Theme.CARD_HI : Theme.CARD)
            .borderRadius(12)
            .onClick(() => {
              this.includeHidden = !this.includeHidden;
              this.reload();
            })
        }
        Blank()
      }
      .width('100%')

      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(10)
          .fontColor(Theme.DANGER)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 12, bottom: 8 })
  }

  build() {
    Column() {
      this.Toolbar()

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
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 84 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.loadMore();
        })
      }

      // 多选操作条：公版不含合并能力，这里是零尺寸空桩，不影响列表布局。
      if (this.selecting) {
        MergeBar({
          kind: this.kind,
          items: this.items,
          picked: this.picked,
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
  }
}
