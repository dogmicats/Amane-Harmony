import { Theme } from '../../common/Theme';
import { Store } from '../../common/Store';
import { uiMaterial } from '@kit.ArkUI';
import { StillFeed, openStill } from './GachaFeed';
import { GachaStill } from './GachaTypes';
import { GachaSwitch } from './GachaSwitch';
import { GachaCache } from './GachaCache';
import { NavBarWatch } from '../../common/NavBarWatch';
import { Personalize } from '../../common/Personalize';

/**
 * 抽卡墙：列表页「抽卡模式」的全部内容（标题条 + 瀑布流 + 换一批）。
 *
 * 刻意**不含 Scroll** —— 由页面决定怎么滚：
 *   - 列表页里替换掉网格：`Scroll() { GachaWall(...) }.layoutWeight(1)`
 *   - 详情页里塞进 List 的某一项：直接摆，不套滚动（套了会抢手势）
 *
 * 数据与轮换逻辑在 StillFeed（纯逻辑类），这里只负责渲染与状态，
 * 所以以后调「一次抓多少」「怎么随机」只改 GachaFeed，所有列表页一起变。
 */
@Component
export struct GachaWall {
  /** tag / series / studio / publisher / director / user_tag / library / favorite / all */
  @Prop @Watch('onScopeChange') scope: string = 'all';
  @Prop @Watch('onScopeChange') scopeId: number = 0;
  /** 文案里用的范围名（标签名 / 库名 / 「我的收藏」…）。 */
  @Prop label: string = '';
  /** 标题前缀，演员页传「盲盒」，列表页用默认的「抽卡」。 */
  @Prop heading: string = '抽卡';
  /** 一轮摆几张；0 = 跟随设置页里的值。 */
  @Prop count: number = 0;
  /**
   * 追加查询串（不带前导 &）。给「没有实体 id 的范围」传筛选条件：
   * 共演筛选结果页传 `female_n=1,2&exclude_director_id=130` 之类，
   * 条件变了（字符串变了）就自动重抽。
   */
  @Prop @Watch('onScopeChange') extra: string = '';
  /** 抽卡开关：由页面持有，放在标题行右端 —— 开和关都在同一侧。 */
  @Prop gachaOn: boolean = true;
  onToggleGacha: (v: boolean) => void = (v: boolean) => {};

  @State stills: GachaStill[] = [];
  @State urls: string[] = [];
  @State ratios: number[] = [];
  @State loading: boolean = true;
  /** 触底追加中（底部转圈）。 */
  @State loadingMore: boolean = false;
  /** 这个范围已经刷完了（追加两批都没新图）。 */
  @State exhausted: boolean = false;
  /** 下拉刷新的转圈（2026-11-16）。 */
  @State pulling: boolean = false;
  /** 是不是在最顶端：决定「回到顶部」按钮显不显示。 */
  @State atTop: boolean = true;
  /** 空墙 / 出错的人话说明；空串表示正常。 */
  @State note: string = '';
  /** 这个范围内有多少部片有剧照；-1 = 未知。 */
  @State candidates: number = -1;

  private feed: StillFeed | undefined = undefined;
  private busy: boolean = false;
  /** 瀑布流的滚动控制器（2026-11-16 起这面墙自己滚，底部导航栏也要靠它判方向）。 */
  private sc: Scroller = new Scroller();
  /** 列数：跟设置页里「剧照列数」联动（捏合也会改它）。 */
  @StorageProp('amaneStillCols') stillCols: number = 2;

  /** 列模板：'1fr 1fr' 这种，交给 WaterFlow。 */
  private colsTemplate(): string {
    const n: number = Personalize.clampStills(this.stillCols);
    let t: string = '';
    for (let i = 0; i < n; i++) {
      t += (i === 0 ? '1fr' : ' 1fr');
    }
    return t;
  }

  /** 每张的宽高比：服务端下发的为准，异常值夹在可读区间里。 */
  private ratioOf(st: GachaStill, idx: number): number {
    let r: number = st.ratio;
    if (!(r > 0) && idx < this.ratios.length) {
      r = this.ratios[idx];
    }
    if (!(r > 0)) {
      r = 1.5;
    }
    return Math.min(2.8, Math.max(0.42, r));
  }

  /** 水墙的可视宽高（vp），由 onAreaChange 更新；用来判断"够不够一屏"。 */
  private vpW: number = 0;
  private vpH: number = 0;
  /** 连续自动补批次数（防失控）。 */
  private autoFills: number = 0;
  /**
   * 这个时刻之前不把滚动位移喂给底栏逻辑。
   * 追加一批后内容高度会变、列表会做一次收敛，那一小段位移不是用户手势，
   * 却会被判成「往回划」把收起的导航栏顶开（2026-11-16 用户报的 bug）。
   */
  private ignoreNavUntil: number = 0;
  /** 手指是否按在水墙上：只有按着时的位移算用户意图（松手后的弹簧/惯性不算）。 */
  private touching: boolean = false;

  /**
   * 估算当前水墙的内容总高（vp）。
   *
   * 为什么要算：选 3/4 列时一屏就能把 10 张装完，滚动条根本动不了，
   * `onReachEnd` 永远不触发 → 用户再怎么滑也拿不到更多（2026-11-16 用户指出的坑）。
   * 按「列宽 / 比例」贪心累加就能估出来，不需要量真实像素。
   */
  private contentHeight(): number {
    const n: number = Personalize.clampStills(this.stillCols);
    if (this.vpW <= 0 || n <= 0) {
      return 0;
    }
    const colW: number = (this.vpW - 8 * (n - 1)) / n;
    const heights: number[] = [];
    for (let c = 0; c < n; c++) {
      heights.push(0);
    }
    for (let i = 0; i < this.stills.length; i++) {
      const h: number = colW / this.ratioOf(this.stills[i], i);
      let pick: number = 0;
      for (let c = 1; c < n; c++) {
        if (heights[c] < heights[pick]) {
          pick = c;
        }
      }
      heights[pick] += h + 8;
    }
    let max: number = 0;
    for (let c = 0; c < n; c++) {
      if (heights[c] > max) {
        max = heights[c];
      }
    }
    return max;
  }

  /**
   * 内容不够一屏（或勉强一屏）就自己再补一批。
   * 上限 6 次，避免服务端一直给空、或者循环请求。
   */
  private maybeFill(): void {
    if (this.stills.length === 0 || this.loadingMore || this.exhausted) {
      return;
    }
    if (this.vpH <= 0 || this.vpW <= 0) {
      // `onAreaChange` 还没回来时给个保守估计（常见手机 ≈ 360×640vp）：
      // 宁可多补一批，也不要因为量不到尺寸就彻底不补（那就是上一版失效的样子）。
      if (this.vpW <= 0) {
        this.vpW = 360;
      }
      this.vpH = 640;
    }
    if (this.autoFills >= 6) {
      return;
    }
    // 1.15 倍：留一点余量，让手指确实能滑起来
    if (this.contentHeight() >= this.vpH * 1.15) {
      return;
    }
    this.autoFills++;
    this.loadMore();
  }

  aboutToAppear(): void {
    this.boot();
  }

  /** 页面换了范围（同一个 GachaWall 复用，比如切换标签）时重来一遍。 */
  onScopeChange(): void {
    this.boot();
  }

  private boot(): void {
    const n: number = this.count > 0 ? this.count : Store.I.gachaCount;
    if (this.feed === undefined) {
      this.feed = new StillFeed(this.scope, this.scopeId, n, this.extra);
    } else {
      this.feed.reset(this.scope, this.scopeId, n, this.extra);
    }
    // 先把上一批成功的铺出来（同范围）：父组件重渲染导致本组件被重建时，
    // 不清空→不闪空提示，等新一批回来再整体替换（2026-11-16 用户两次报的就是空态）。
    const k: string = GachaCache.key(this.scope, this.scopeId, this.extra);
    const cached: GachaStill[] = GachaCache.take(k);
    this.stills = cached;
    this.urls = GachaCache.urlsOf(k);
    this.ratios = GachaCache.ratiosOf(k);
    this.note = '';
    // 有旧图就不要整屏转圈，只在底部显示「在翻」
    this.loading = cached.length === 0;
    this.loadingMore = false;
    this.exhausted = false;
    this.atTop = true;
    this.autoFills = 0;
    // 诊断（2026-11-16）：下一步连上真机时看这两行就知道是「重建」还是「拉空」
    console.info(`[amane] gacha boot scope=${this.scope}/${this.scopeId} cached=${cached.length}`);
    this.load(false);
  }

  /**
   * 顶部下拉：整面墙重抽一批（2026-11-16）。
   *
   * **不清旧图**：`boot()` 会先把 stills 清空再拉，一旦这次请求失败/超时，用户就看到
   * 「转一会就没了、回到空提示」（2026-11-16 用户报的就是这个，被当成"抽卡抽不动"）。
   * 这里改成：新池子照建，但**拿到新图才替换**，失败就保留原样。
   */
  private async refreshAll(): Promise<void> {
    const f: StillFeed | undefined = this.feed;
    if (f === undefined) {
      return;
    }
    this.pulling = true;
    try {
      const n: number = this.count > 0 ? this.count : Store.I.gachaCount;
      f.reset(this.scope, this.scopeId, n, this.extra);
      const list: GachaStill[] = await f.next(false);
      this.candidates = f.candidates;
      if (list.length > 0) {
        const urls: string[] = [];
        const ratios: number[] = [];
        for (let i = 0; i < list.length; i++) {
          urls.push(list[i].url);
          ratios.push(list[i].ratio);
        }
        this.stills = list;
        this.urls = urls;
        this.ratios = ratios;
        this.note = '';
        this.exhausted = false;
        this.autoFills = 0;
        this.sc.scrollEdge(Edge.Top);
        GachaCache.put(GachaCache.key(this.scope, this.scopeId, this.extra), list);
        setTimeout(() => {
          this.maybeFill();
        }, 80);
      } else if (this.stills.length === 0) {
        // 本来就没图：这才是真的空态，给说明
        this.note = f.error.length > 0 ? f.error : '这次没抽到剧照，再下拉试试';
      }
      // 有旧图 + 这次失败 → 什么都不做，用户继续看原来的
    } catch (err) {
      console.error('[amane] gacha refresh failed');
    } finally {
      this.pulling = false;
    }
  }

  /**
   * @param more true = 「换一批」：优先用本地池子，瞬时出图；
   *             false = 首次进入，必须重新拉。
   */
  private async load(more: boolean): Promise<void> {
    const f: StillFeed | undefined = this.feed;
    if (f === undefined || this.busy) {
      return;
    }
    this.busy = true;
    if (!more) {
      this.loading = true;
    }
    try {
    const list: GachaStill[] = await f.next(more);
    console.info(`[amane] gacha load more=${more} got=${list.length} err=${f.error.length}`);
    this.candidates = f.candidates;
    if (list.length === 0) {
      // 三种失败给人话分开写（2026-11-16）：不连真机时，用户读这一句就能告诉我是哪一种。
      if (f.error.length > 0) {
        this.note = '抽卡没拿到数据（网络或服务端没返回）';
      } else if (f.candidates === 0) {
        this.note = this.label.length > 0
          ? `「${this.label}」里还没有剧照`
          : '这个范围里还没有剧照';
      } else {
        this.note = '服务端这次没给出剧照';
      }
    } else {
      const urls: string[] = [];
      const ratios: number[] = [];
      for (let i = 0; i < list.length; i++) {
        urls.push(list[i].url);
        ratios.push(list[i].ratio);
      }
      this.stills = list;
      this.urls = urls;
      this.ratios = ratios;
      this.note = '';
      GachaCache.put(GachaCache.key(this.scope, this.scopeId, this.extra), list);
    }
    } catch (err) {
      console.error('[amane] gacha load failed');
    } finally {
      this.loading = false;
      this.busy = false;
      // 首屏到手后也要判一次「够不够一屏」（2026-11-16 修）：
      // `onAreaChange` 只在布局尺寸变化时触发，而它第一次触发时 stills 还是空的，
      // 于是四列场景永远等不到「补满」——上一版因此失效。延一帧等布局落定再算。
      setTimeout(() => {
        this.maybeFill();
      }, 80);
    }
  }

  /**
   * 触底追加一批（2026-11-16）：抽卡从「点一下换一批」改成瀑布流不断往下加载。
   * 去重与「刷完了」的判定都在 `StillFeed.more()` 里，这里只管把新图接在墙上。
   */
  private async loadMore(): Promise<void> {
    const f: StillFeed | undefined = this.feed;
    // 只用一个 loadingMore 当闸门：以前另有一个 `busy`，中途抛异常就永久卡住，
    // 表现是「再翻一批…」一直转、怎么滑都不再请求（2026-11-16 用户报的就是这个）。
    if (f === undefined || this.loadingMore || this.exhausted || this.stills.length === 0) {
      return;
    }
    this.loadingMore = true;
    try {
      const add: GachaStill[] = await f.more();
      if (add.length > 0) {
        const urls: string[] = this.urls.slice();
        const ratios: number[] = this.ratios.slice();
        const all: GachaStill[] = this.stills.slice();
        for (let i = 0; i < add.length; i++) {
          all.push(add[i]);
          urls.push(add[i].url);
          ratios.push(add[i].ratio);
        }
      this.stills = all;
      this.urls = urls;
      this.ratios = ratios;
      this.candidates = f.candidates;
      GachaCache.put(GachaCache.key(this.scope, this.scopeId, this.extra), all);
      }
      this.exhausted = f.exhausted;
    } catch (err) {
      console.error('[amane] gacha more failed');
    } finally {
      // 无论如何都要把转圈收掉，否则用户只能退出页面
      this.loadingMore = false;
      // 追加后的收敛位移别喂给底栏逻辑（否则导航栏会被顶开）
      this.ignoreNavUntil = Date.now() + 400;
      // 补完一批还不够一屏就继续补（3/4 列时最常见的场景）
      this.maybeFill();
    }
  }

  @Builder
  Header() {
    Row({ space: 6 }) {
      // 2026-11-16：原来这里还有一个「抽卡」大标题，和右上角开关的「抽卡中」重复了，
      // 按用户要求去掉这处文案，只留「剧照」徽章 + 张数 + 开关。
      Text('剧照')
        .fontSize(9)
        .fontColor(Theme.ACCENT)
        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(4)
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
      // 张数计数与「搜索中…」都去掉了（2026-11-16 用户：那行看着不干净）
      if (this.onToggleGacha !== undefined) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.onToggleGacha(v);
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Placeholder() {
    Column({ space: 8 }) {
      if (this.loading) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(Theme.ACCENT)
        Text('正在翻剧照…')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      } else {
        Text('✦')
          .fontSize(26)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.note.length > 0 ? this.note : '这里还没有剧照')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
        Text('再试一次')
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(14)
          .onClick(() => {
            this.load(true);
          })
      }
    }
    .width('100%')
    .height(180)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
    Column({ space: 10 }) {
      this.Header()

      // 自己带滚动（2026-11-16）：瀑布流要能一直往下拉，所以不再由页面套 Scroll。
      // 顶部下拉 = 整面墙重抽；触底 = 追加下一批；到底了给一句「刷完了」。
      //
      // 用原生 `WaterFlow` 而不是 `view/StillsWall`：后者是给「一次性铺完」写的
      // （内部按比例贪心分列，只在 @Prop 变更时重排），追加时画面停在第一批 10 张
      // ——2026-11-16 用户实测「张数涨到 50，墙上还是 10 张」就是这个。
      // WaterFlow 天生支持往后追加，也自带懒加载，几百张也不卡。
      Refresh({ refreshing: $$this.pulling }) {
      WaterFlow({ scroller: this.sc }) {
        ForEach(this.stills, (st: GachaStill, idx: number) => {
          FlowItem() {
            Image(Store.I.img(st.url))
              .width('100%')
              .aspectRatio(this.ratioOf(st, idx))
              .objectFit(ImageFit.Cover)
              .borderRadius(10)
              // 占位用中性灰而不是近黑（2026-11-16）：底部毛玻璃胶囊压在还没加载的格子上时，
              // 近黑占位透出来就是一块死黑；灰底透出来才是"玻璃"。
              .backgroundColor('#3A3A42')
              .onClick(() => {
                openStill(st);
              })
          }
          .width('100%')
        }, (st: GachaStill, idx: number) => `gw-${st.id}-${idx}`)
      }
      .columnsTemplate(this.colsTemplate())
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      // 弹簧保留，但**只在内容真能滚动时才生效**（2026-11-16 用户要求）：
      // `alwaysEnabled: false` 表示内容不足一屏时不触发边缘效果——
      // 之前三/四列内容刚好一屏，轻轻一滑就到底弹一下，反而把瀑布流搅得不丝滑。
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
      .onReachEnd(() => {
        this.loadMore();
      })
      // 三/四列时一屏就能装完，永远滑不到底 → 用真实尺寸算一遍内容高度，
      // 不够一屏就自己再补一批（2026-11-16 用户提的第 2 条）。
      .onAreaChange((o: Area, n: Area) => {
        const w: number = parseFloat(`${n.width}`);
        const h: number = parseFloat(`${n.height}`);
        if (w > 0 && h > 0) {
          this.vpW = w;
          this.vpH = h;
          this.maybeFill();
        }
      })
      // 底栏自动收起（2026-11-16）：抽卡墙现在自己滚，方向也在这里上报
      .onTouch((e: TouchEvent) => {
        // 只有手指在屏上才算"用户操作"：触底弹簧的回弹、惯性滚动都在松手之后，
        // 它们会把偏移往回带一点，被误判成"往回划"→ 刚收起的底栏又弹出来
        // （2026-11-16 用户第二次报）。这里用按下状态把这类余震彻底排除。
        this.touching = e.type === TouchType.Down || e.type === TouchType.Move;
      })
      .onScroll((x: number, y: number) => {
        const off: number = this.sc.currentOffset().yOffset;
        if (this.touching) {
          NavBarWatch.onOffset(off, true);
        } else if (Date.now() > this.ignoreNavUntil) {
          // 松手后的余震：仍允许"继续收起"，但不允许把底栏弹回来
          NavBarWatch.onOffset(off, false);
        }
        // 离顶端 60vp 内算「在顶部」，「回到顶部」按钮这时没必要出现
        this.atTop = off <= 60;
      })
      // 双指切列数（2026-11-16 补回来）：`WaterFlow` 自己不带缩放手势，
      // 以前这份能力写在 `view/StillsWall` 里，换容器后就丢了 —— 不是手势冲突。
      .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
        Personalize.zoomStills(event.scale);
      }))
      }
      .layoutWeight(1)
      .onRefreshing(() => {
        this.refreshAll();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)

    if (this.stills.length === 0) {
      // 撑满整块再居中（2026-11-16 修）：Stack 的对齐是 BottomEnd，
      // 直接放进来会被推到右下角，首次进抽卡的「正在翻剧照…」就是歪的。
      Row() {
        this.Placeholder()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }

    // 只在真正翻页时浮一个毛玻璃小胶囊（2026-11-16 用户要求）：
    // 平时不占位、不挡图 —— 水墙一直铺到屏幕最底，被导航栏压住一部分正好。
    // 位置：**底部居中、压在导航栏上方一点**（导航栏 58 + 底边距 12 ≈ 70，留到 84）。
    if (this.loadingMore) {
      Row() {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color('#FFFFFF')
          Text('再翻一批…')
            .fontSize(12)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(16)
        // 2026-11-16 第五次调（回应用户两点）：
        // 1) 图片还没加载出来时背后是深色占位，底色若偏黑就会"透成一块黑" → 底色降到 30%，
        //    并保留系统背景模糊，让没图的地方也呈中灰玻璃而不是死黑；
        // 2) 边缘光晕：重新挂回系统 `systemMaterial`（上一轮我是直接删掉、没让你看过它 THICK 的样子）。
        //    ArkUI 的说法是这个材质会接管 backgroundColor/blur/border，所以它生效时会盖住下面两行；
        //    若设备不支持，这两行就是兜底，不会变成透明。
        .backgroundColor('#4D000000')
        .backgroundBlurStyle(BlurStyle.BACKGROUND_ULTRA_THICK)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          materialColor: '#33000000'
        }))
        .border({ width: 0.5, color: '#40FFFFFF' })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 84 })
      .hitTestBehavior(HitTestMode.None)
    }

    // 「回到顶部」：滚下去之后右下角浮一个，点一下回顶（抽卡容易越刷越深，找不着头）
    if (!this.atTop) {
      Text('↑')
        .fontSize(18)
        .fontColor(Theme.TEXT)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.CARD)
        .borderRadius(22)
        .border({ width: 1, color: Theme.STROKE })
        .margin({ right: 18, bottom: 72 })
        .onClick(() => {
          this.sc.scrollEdge(Edge.Top);
        })
    }
    }
  }
}
