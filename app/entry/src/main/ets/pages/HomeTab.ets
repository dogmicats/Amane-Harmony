import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { httpDelete, httpGet, httpGetCached, cachedBody, dropPageCache, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { HomeData, HomeRow, LibraryInfo, MediaItem, BrowseParams, DetailParams, PlayerParams } from '../common/Types';
import { safeHome } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { Reason, ReasonPack, ReasonLine } from '../common/Reason';
import { HeroBanner } from '../view/HeroBanner';
import { MediaRow } from '../view/MediaRow';
import { BannerRow } from '../view/BannerRow';

/** 首页「媒体库」一栏的一张卡（2.5.5.4）。 */
interface LibCard {
  id: number;
  name: string;
  count: number;
  /** 用户换过的封面；空串 = 用 posters 拼贴。 */
  cover: string;
  posters: string[];
}

export function emptyHome(): HomeData {
  const data: HomeData = {
    hero: [], continue: [], recommend: [], banners: [], rows: [], libraries: [], generated_at: ''
  };
  return data;
}

/** 理由还没算出来 / 关掉时，副标题退回原来那句，行头也不出现「推荐理由」。 */
function emptyReasons(): ReasonPack {
  return { headline: Reason.DEFAULT_SUBTITLE, topic: '', lines: [], count: 0 };
}

/**
 * 首页的一行（2.5.2 起首页由数据驱动）。
 *
 * `kind` 决定用哪个组件渲染：`cast` 是共演筛选入口卡、`banner` 是横幅行、
 * 其余（`continue` / `row`）都是普通的横向海报行。`key` 同时是偏好里的键名，
 * 一旦发布不要再改（改了用户存的顺序就对不上了）。
 */
interface HomeSection {
  key: string;
  kind: string;
  title: string;
  subtitle: string;
  libraryId: number;
  /** `more` 按钮去哪：`history` 走观看记录，`library` 走这个媒体库。 */
  moreKind: string;
  items: MediaItem[];
}

/**
 * 首页「媒体库」一栏（2.5.5.4）：横向卡片，封面 = 自定义图 > 两张海报拼贴 > 首字。
 *
 * 换封面走**长按**（`bindContextMenu` + `ResponseType.LongPress`），单击仍是进库 ——
 * 同一张卡上再挂一个可点按钮，很容易点封面就误跳页面。
 */
@Component
struct LibraryRow {
  @Prop cards: LibCard[] = [];
  onOpen: (id: number, name: string) => void = (id: number, name: string) => {};
  onPickCover: (card: LibCard) => void = (card: LibCard) => {};
  onMakeGif: (card: LibCard) => void = (card: LibCard) => {};
  onRestoreCover: (card: LibCard) => void = (card: LibCard) => {};

  /** 长按菜单（`bindContextMenu` 只认 CustomBuilder）。 */
  @Builder
  CardMenu(c: LibCard) {
    Menu() {
      MenuItem({ content: '换封面（从相册选）' })
        .onClick(() => {
          this.onPickCover(c);
        })
      MenuItem({ content: '用库里海报做动图' })
        .onClick(() => {
          this.onMakeGif(c);
        })
      if (c.cover.length > 0) {
        MenuItem({ content: '恢复默认封面' })
          .onClick(() => {
            this.onRestoreCover(c);
          })
      }
    }
  }

  /**
   * 点「⇄」弹出的菜单。长按在很多机型上不灵（List 滚动手势会抢），
   * 所以给一个**明确可点**的入口，长按留着当捷径。
   */
  private menuItems(c: LibCard): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '换封面（从相册选）',
      action: () => {
        this.onPickCover(c);
      }
    });
    items.push({
      value: '用库里海报做动图',
      action: () => {
        this.onMakeGif(c);
      }
    });
    if (c.cover.length > 0) {
      items.push({
        value: '恢复默认封面',
        action: () => {
          this.onRestoreCover(c);
        }
      });
    }
    return items;
  }

  /**
   * 一张库卡。
   *
   * 为什么单独抽成一个组件：`bindContextMenu` 的 CustomBuilder **要的是「方法引用」，
   * 不是「调用结果」**。以前写成 `.bindContextMenu(this.Menu(c), ...)`，
   * 等于把执行完的 void 传进去 —— 长按的震动和缩放照旧（系统手势识别了），
   * 但菜单里什么都没有（2.5.6.8 用户报的正是这个）。
   * 这里把 `c` 放进 `@Prop`，菜单 builder 就能是无参的 `this.CardMenu`。
   */
  @Builder
  Card(c: LibCard) {
    LibCardCell({
      card: c,
      onOpen: (id: number, name: string) => {
        this.onOpen(id, name);
      },
      onPickCover: (card: LibCard) => {
        this.onPickCover(card);
      },
      onMakeGif: (card: LibCard) => {
        this.onMakeGif(card);
      },
      onRestoreCover: (card: LibCard) => {
        this.onRestoreCover(card);
      }
    })
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('媒体库')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text('长按换封面')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.cards, (c: LibCard) => {
            this.Card(c)
          }, (c: LibCard) => `lib-${c.id}-${c.cover}-${c.posters.length}`)
        }
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .margin({ bottom: 13 })
  }
}

/**
 * 一张库卡（2.5.5.4）。
 *
 * 单独抽成组件的原因见上面 `LibraryRow.Card` 的注释：长按菜单要的 CustomBuilder
 * 必须是无参方法引用，数据只能从 `@Prop` 里读。
 */
@Component
struct LibCardCell {
  @Prop card: LibCard = { id: 0, name: '', count: 0, cover: '', posters: [] };
  onOpen: (id: number, name: string) => void = (id: number, name: string) => {};
  onPickCover: (card: LibCard) => void = (card: LibCard) => {};
  onMakeGif: (card: LibCard) => void = (card: LibCard) => {};
  onRestoreCover: (card: LibCard) => void = (card: LibCard) => {};

  @Builder
  CardMenu() {
    Menu() {
      MenuItem({ content: '换封面（从相册选）' })
        .onClick(() => {
          this.onPickCover(this.card);
        })
      MenuItem({ content: '用库里海报做动图' })
        .onClick(() => {
          this.onMakeGif(this.card);
        })
      if (this.card.cover.length > 0) {
        MenuItem({ content: '恢复默认封面' })
          .onClick(() => {
            this.onRestoreCover(this.card);
          })
      }
    }
  }

  private menuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '换封面（从相册选）',
      action: () => {
        this.onPickCover(this.card);
      }
    });
    items.push({
      value: '用库里海报做动图',
      action: () => {
        this.onMakeGif(this.card);
      }
    });
    if (this.card.cover.length > 0) {
      items.push({
        value: '恢复默认封面',
        action: () => {
          this.onRestoreCover(this.card);
        }
      });
    }
    return items;
  }

  build() {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (this.card.cover.length > 0) {
          Image(Store.I.img(this.card.cover))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else if (this.card.posters.length > 0) {
          Row({ space: 1 }) {
            ForEach(this.card.posters, (p: string, i: number) => {
              Image(Store.I.img(p))
                .layoutWeight(1)
                .height('100%')
                .objectFit(ImageFit.Cover)
            }, (p: string, i: number) => `lp-${this.card.id}-${i}`)
          }
          .width('100%')
          .height('100%')
        } else {
          Column() {
            Text(this.card.name.substring(0, 1))
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT_DIM)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.CARD_HI)
        }
        // 明确可点：点它出菜单（长按在很多机型上会被滚动手势抢掉）
        Text('⇄')
          .fontSize(10)
          .fontColor('#F2FFFFFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#99000000')
          .borderRadius(7)
          .margin({ top: 5, right: 5 })
          .bindMenu(this.menuItems())
      }
      .width('100%')
      .height(84)
      .borderRadius(10)
      .clip(true)
      .backgroundColor(Theme.CARD_HI)
      .border({
        width: this.card.cover.length > 0 ? 1 : 0,
        color: Theme.accentAlpha(0.32)
      })

      Text(this.card.name)
        .fontSize(11)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(`${this.card.count} 部`)
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
    }
    .width(148)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen(this.card.id, this.card.name);
    })
    // 传方法引用，不要传 `this.CardMenu()` —— 那是执行结果（void），菜单会是空的
    .bindContextMenu(this.CardMenu, ResponseType.LongPress)
  }
}

@Component
export struct HomeTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State home: HomeData = emptyHome();
  /** 这次真的要铺的行（顺序 / 显隐来自「设置 → 首页内容」）。 */
  @State sections: HomeSection[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  /** 首页「媒体库」一栏的卡（含自定义封面 / 拼贴海报）。 */
  @State libCards: LibCard[] = [];
  /** 下拉刷新中（Refresh 的双向绑定）。 */
  @State pulling: boolean = false;
  /** 每日推荐的整批理由（纯客户端生成，不占卡片版面）。 */
  @State reasonPack: ReasonPack = emptyReasons();
  @State reasonOn: boolean = true;
  @State showReasons: boolean = false;
  /** 老缓存补拉统计只试一次，避免不支持该字段的服务端每次冷启动都被多打一次。 */
  private statsTried: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  /**
   * 首页数据一变就重算理由。理由按「日期 + item.id」稳定复现，
   * 所以下拉刷新不会让同一部片换一句话；换一天才会。
   */
  private refreshReasons(): void {
    this.reasonOn = Reason.enabled();
    if (!this.reasonOn) {
      this.reasonPack = emptyReasons();
      return;
    }
    const items: MediaItem[] = this.home.banners.length > 0 ? this.home.banners : this.home.recommend;
    if (items.length === 0) {
      this.reasonPack = emptyReasons();
      return;
    }
    // 全库统计摘要由 /api/user/home 下发；老服务端没有该字段时 undefined，
    // Reason.build 会自动跳过全库族，其余理由照常生成。
    this.reasonPack = Reason.build(items, this.home.continue, this.home.library_stats);
    // 老缓存兜底：home 会被 PageCache 落盘（TTL 5 分钟 / 跨重启仍在），服务端
    // 刚升级完时首屏很可能还是升级前那份没有 library_stats 的 JSON。补一次
    // 不走缓存的请求，拿到统计后重算 —— 同一天同一批的理由结果稳定，不会跳字。
    if (this.home.library_stats === undefined && !this.statsTried) {
      this.statsTried = true;
      this.fetchStatsAndRebuild(items);
    }
  }

  /** 只补统计字段，不替换整份 home，避免把用户正在看的列表刷掉。 */
  private async fetchStatsAndRebuild(items: MediaItem[]): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/home`, Store.I.token);
      const fresh: HomeData = safeHome(JSON.parse(text) as HomeData);
      if (fresh.library_stats !== undefined) {
        this.home.library_stats = fresh.library_stats;
        this.reasonPack = Reason.build(items, fresh.continue, fresh.library_stats);
      }
    } catch (err) {
      // 老服务端 / 断网都静默降级：全库族不出现，其余理由照常
      console.info('[amane] reason stats refresh failed');
    }
  }

  onRefresh(): void {
    this.load();
  }

  /**
   * 下拉刷新：**必须绕开两层缓存**，否则转了圈还是旧数据。
   * ① 客户端 httpGetCached（load() 用的）；② 服务端 /home 的 5 分钟聚合缓存 ——
   *    所以要带 `fresh=1`，服务端才会重算并把横幅重新洗一批（推荐仍按日固定）。
   */
  private async pullRefresh(): Promise<void> {
    if (!Store.I.ready) {
      this.pulling = false;
      return;
    }
    this.pulling = true;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/home?fresh=1`, Store.I.token);
      this.home = safeHome(JSON.parse(text) as HomeData);
      this.error = '';
      this.loading = false;
      this.refreshReasons();
      this.buildLibCards();
      this.buildSections();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] home pull: ${e.code} ${e.message}`);
      if (this.home.rows.length === 0) {
        this.error = '首页加载失败，下拉重试';
      }
    }
    this.pulling = false;
  }

  private async load(): Promise<void> {
    if (!Store.I.ready) {
      // 冷启动时 Index 还没拿到 config，稍后 refreshKey 变化会再来一次
      this.loading = false;
      return;
    }
    this.error = '';
    const url: string = `${Store.I.user}/api/user/home`;
    // 先用缓存把首页画出来（哪怕已过期）：来回切 tab 不用每次都看骨架屏
    if (this.home.rows.length === 0 && this.home.hero.length === 0) {
      const stale: string | undefined = cachedBody(url);
      if (stale !== undefined) {
        try {
          this.home = safeHome(JSON.parse(stale) as HomeData);
          this.loading = false;
        } catch (err) {
          console.info('[amane] home cache parse failed');
        }
      }
    }
    try {
      // 5 分钟内重复进入直接读缓存，不发请求
      const text: string = await httpGetCached(url, Store.I.token, 300000);
      this.home = safeHome(JSON.parse(text) as HomeData);
      this.loading = false;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] home: ${e.code} ${e.message}`);
      if (this.home.rows.length === 0) {
        this.error = '首页加载失败，下拉重试';
      }
      this.loading = false;
    }
    this.refreshReasons();
    this.buildLibCards();
    this.buildSections();
  }

  /**
   * 媒体库卡：封面优先用用户换过的，没有就拿该库最近两部的海报拼。
   * 海报只能从 `home.rows` 里借（每行就是这个库的前 18 部），没有行的小库
   * 就显示首字 —— 不为它单独再发一次请求。
   */
  private buildLibCards(): void {
    const cards: LibCard[] = [];
    for (let i = 0; i < this.home.libraries.length; i++) {
      const lib: LibraryInfo = this.home.libraries[i];
      const posters: string[] = [];
      for (let r = 0; r < this.home.rows.length && posters.length < 2; r++) {
        const row: HomeRow = this.home.rows[r];
        if (row.library_id !== lib.id) {
          continue;
        }
        for (let k = 0; k < row.items.length && posters.length < 2; k++) {
          const p = row.items[k].poster;
          if (p !== undefined && `${p}`.length > 0) {
            posters.push(`${p}`);
          }
        }
      }
      cards.push({
        id: lib.id,
        name: lib.name,
        count: lib.count,
        cover: lib.cover === undefined || lib.cover === null ? '' : lib.cover,
        posters: posters
      });
    }
    this.libCards = cards;
  }

  /**
   * 按偏好排一次首页：「服务端这次给了哪些行」∩「用户要的显隐与顺序」。
   *
   * 只影响行的排列，不改任何一行的内部版式；`key` 用媒体库 id 而不是标题，
   * 改名不会让已存的顺序失效。偏好里没有的新库会自动追加到末尾并打开。
   */
  private buildSections(): void {
    const avail: HomeSection[] = [];
    const keys: string[] = [];
    if (BuildConfig.ENABLE_ACTORS) {
      avail.push({
        key: 'cast', kind: 'cast', title: '共演筛选', subtitle: '',
        libraryId: 0, moreKind: '', items: []
      });
      keys.push('cast');
    }
    if (this.home.continue.length > 0) {
      avail.push({
        key: 'continue', kind: 'continue', title: '继续观看', subtitle: '接着上次的进度',
        libraryId: 0, moreKind: 'history', items: this.home.continue
      });
      keys.push('continue');
    }
    if (this.home.banners.length > 0 || this.home.recommend.length > 0) {
      avail.push({
        key: 'banner', kind: 'banner', title: '每日推荐',
        subtitle: this.reasonOn ? this.reasonPack.headline : Reason.DEFAULT_SUBTITLE,
        libraryId: 0, moreKind: 'library',
        items: this.home.banners.length > 0 ? this.home.banners : this.home.recommend
      });
      keys.push('banner');
    }
    // 「媒体库」目录：横向一排卡片，一眼看到每个库长什么样、各有多少片
    if (this.libCards.length > 0) {
      avail.push({
        key: 'libs', kind: 'libs', title: '媒体库', subtitle: `${this.libCards.length} 个`,
        libraryId: 0, moreKind: '', items: []
      });
      keys.push('libs');
    }
    for (let i = 0; i < this.home.rows.length; i++) {
      const row: HomeRow = this.home.rows[i];
      const key: string = `row:${row.id}`;
      avail.push({
        key: key, kind: 'row', title: row.title, subtitle: `${row.count} 部`,
        libraryId: row.library_id, moreKind: 'library', items: row.items
      });
      keys.push(key);
    }

    const ordered: string[] = Personalize.orderKeys(keys);
    const out: HomeSection[] = [];
    for (let i = 0; i < ordered.length; i++) {
      for (let j = 0; j < avail.length; j++) {
        if (avail[j].key === ordered[i]) {
          out.push(avail[j]);
          break;
        }
      }
    }
    this.sections = out;
  }

  private openDetail(item: MediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openPlayer(item: MediaItem): void {
    const params: DetailParams = { id: item.id, autoplay: true, position: item.position };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openLibrary(id: number, title: string): void {
    const params: BrowseParams = { libraryId: id, title: title };
    router.pushUrl({ url: 'pages/LibraryPage', params: params });
  }

  /** 媒体库封面按 `lib-<id>` 存（和分类封面同一张表，kind=library）。 */
  private libCoverUrl(card: LibCard): string {
    return `${Store.I.user}/api/user/cover-any/library/${encodeURIComponent(`lib-${card.id}`)}`;
  }

  private async pickLibCover(card: LibCard): Promise<void> {
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
      let ext: string = 'jpg';
      const lower: string = uri.toLowerCase();
      if (lower.indexOf('.png') >= 0) {
        ext = 'png';
      } else if (lower.indexOf('.webp') >= 0) {
        ext = 'webp';
      } else if (lower.indexOf('.gif') >= 0) {
        ext = 'gif';
      }
      const body: Record<string, Object> = { 'data': b64, 'ext': ext };
      const raw: string = await httpPost(this.libCoverUrl(card), Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        promptAction.showToast({ message: '封面换好了', duration: 1500 });
        this.load();
      } else {
        promptAction.showToast({ message: '没换成功，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib cover: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没换成功（选图或上传失败）', duration: 1800 });
    }
  }

  /** 媒体库动图封面：取库里最近几部的海报拼轮播（服务端合成）。 */
  private async makeLibGif(card: LibCard): Promise<void> {
    promptAction.showToast({ message: '正在用库里的海报拼动图，约 10 秒…', duration: 3000 });
    try {
      const url: string = `${Store.I.user}/api/user/facet-gif/library/` +
        encodeURIComponent(`lib-${card.id}`);
      const body: Record<string, Object> = { 'count': 6, 'duration': 900 };
      const raw: string = await httpPost(url, Store.I.token, JSON.stringify(body), 90000);
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '动图封面好了', duration: 1500 });
        this.load();
      } else {
        const why: string = obj.reason === undefined || obj.reason === null ? '' : `${obj.reason}`;
        promptAction.showToast({ message: why.length > 0 ? why : '没做成，稍后再试', duration: 2200 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib gif: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没做成（服务端可能不支持）', duration: 2200 });
    }
  }

  private async restoreLibCover(card: LibCard): Promise<void> {
    try {
      await httpDelete(this.libCoverUrl(card), Store.I.token);
      dropPageCache();
      promptAction.showToast({ message: '已恢复默认封面', duration: 1500 });
      this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib cover del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没恢复成，稍后再试', duration: 1600 });
    }
  }

  @Builder
  Header() {
    Row() {
      Text('Amane')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
        .textShadow({ radius: 8, color: '#99000000', offsetX: 0, offsetY: 2 })
      Blank()
      // 搜索键（2.5.7.8）：原先是「42vp 半透明灰圆盘 + `⌕` 字形」——46% 的灰底压在亮色
      // 横幅上像一块脏印子，字形又细又小。现在换成真矢量图标（20vp）+ 36vp 暗玻璃底 +
      // 一圈 1px 亮边：亮背景上有轮廓，暗背景上不突兀。
      Stack() {
        Image($r('app.media.ic_search'))
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor('#33000000')
      .border({ width: 1, color: '#40FFFFFF' })
      .onClick(() => {
        router.pushUrl({ url: 'pages/SearchPage' });
      })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 公开扩展 actors 的特色入口卡（共演筛选）。
   *
   * 从 build() 里搬出来只是为了让首页那段 ForEach 短一点；
   * 版式与 2.4.x 完全一致，别顺手改。
   */
  @Builder
  CastEntry() {
    // 外层 Column 承担左右留白：Row 再设 width('100%') 时，
    // 100% 就是「已减掉留白」的宽度，不会像 margin 那样把整条撑出屏幕。
    Column() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('共演筛选')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            Text('特色')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(4)
          }
          Text('挑几个人找同台作品，或按「几个女演员」直接筛')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(2)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('去试 ›')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(14)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.CARD)
      .borderRadius(14)
      .border({ width: 0.5, color: '#1FFFFFFF' })
      .onClick(() => {
        router.pushUrl({ url: 'ext/actors/CastFinderPage' });
      })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    .margin({ bottom: 12 })
  }

  /** 推荐理由抽屉：整批理由都在这里读，卡片版面一个字都不加。 */
  @Builder
  ReasonSheet() {
    Column() {
      Row({ space: 8 }) {
        Text('今天的推荐理由')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(9)
          .onClick(() => {
            this.showReasons = false;
          })
      }
      .width('100%')
      .padding({ top: 6, bottom: 10 })

      Text(this.reasonPack.headline)
        .fontSize(13)
        .fontColor(Theme.GOLD)
        .width('100%')
        .padding({ bottom: 8 })

      Text(this.reasonPack.topic)
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
        .lineHeight(17)
        .padding({ bottom: 12 })

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.reasonPack.lines, (l: ReasonLine) => {
            Column({ space: 5 }) {
              Row({ space: 8 }) {
                Text(l.number)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .constraintSize({ maxWidth: 110 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(l.title)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')

              if (l.reason.length > 0) {
                Text(l.reason)
                  .fontSize(13)
                  .fontColor(Theme.GOLD)
                  .width('100%')
                  .lineHeight(19)
              } else {
                Text('今天没替它找到说法，就先不编了')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
              }
              if (l.extra.length > 0) {
                Text(l.extra)
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(12)
            .onClick(() => {
              this.showReasons = false;
              const params: DetailParams = { id: l.id };
              router.pushUrl({ url: 'pages/DetailPage', params: params });
            })
          }, (l: ReasonLine) => `rs-${l.id}`)
        }
        .width('100%')
        .padding({ bottom: Theme.BOTTOM_SAFE })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      Text(`共 ${this.reasonPack.count} 句 · 每天换一种说法，同一部片当天不变`)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .padding({ top: 10, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 12 })
    .backgroundColor(Theme.BG)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Theme.ACCENT)
          Text('正在整理媒体库…')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 12 }) {
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
          Button('重试')
            .height(36)
            .backgroundColor(Theme.CARD)
            .fontColor(Theme.TEXT)
            .fontSize(13)
            .onClick(() => {
              this.loading = true;
              this.load();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 下拉刷新：refresh 包住 List（Header 是悬浮层，不能包进去）。
        // refreshing 用 $$ 双向绑定，onRefreshing 里置 true 由 pullRefresh 收尾置 false。
        Refresh({ refreshing: $$this.pulling }) {
          List() {
          ListItem() {
            HeroBanner({
              items: this.home.hero,
              onPlay: (item: MediaItem) => {
                this.openPlayer(item);
              },
              onDetail: (item: MediaItem) => {
                this.openDetail(item);
              }
            })
          }


          // 行的顺序与显隐来自「设置 → 首页内容」（2.5.2）：这里按 sections 铺，
          // 每行内部版式与原来完全一致，只是改由数据驱动。顶部大图固定在最上面。
          ForEach(this.sections, (s: HomeSection) => {
            ListItem() {
              if (s.kind === 'cast') {
                this.CastEntry()
              } else if (s.kind === 'libs') {
                LibraryRow({
                  cards: this.libCards,
                  onOpen: (id: number, name: string) => {
                    this.openLibrary(id, name);
                  },
                  onPickCover: (card: LibCard) => {
                    this.pickLibCover(card);
                  },
                  onMakeGif: (card: LibCard) => {
                    this.makeLibGif(card);
                  },
                  onRestoreCover: (card: LibCard) => {
                    this.restoreLibCover(card);
                  }
                })
              } else if (s.kind === 'banner') {
                // 每日推荐用高清横幅：优先用服务端校验过的真横图（带真实比例），
                // 没有时才退回推荐列表（按 16:9 裁切）。
                BannerRow({
                  title: s.title,
                  subtitle: s.subtitle,
                  items: s.items,
                  whyLabel: this.reasonOn ? '推荐理由' : '',
                  onWhy: () => {
                    this.showReasons = true;
                  },
                  onTap: (item: MediaItem) => {
                    this.openDetail(item);
                  },
                  onMore: () => {
                    this.openLibrary(0, '全部影片');
                  }
                })
              } else {
                MediaRow({
                  title: s.title,
                  subtitle: s.subtitle,
                  items: s.items,
                  onTap: (item: MediaItem) => {
                    this.openDetail(item);
                  },
                  onMore: () => {
                    if (s.moreKind === 'history') {
                      router.pushUrl({ url: 'pages/HistoryPage' });
                    } else {
                      this.openLibrary(s.libraryId, s.title);
                    }
                  }
                })
              }
            }
          }, (s: HomeSection) => s.key)

          ListItem() {
            Text(`共 ${this.home.libraries.length} 个媒体库 · Amane`)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 96 })
          }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => {
          this.pullRefresh();
        })

        this.Header()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    .bindSheet($$this.showReasons, this.ReasonSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: Theme.BG
    })
  }
}
