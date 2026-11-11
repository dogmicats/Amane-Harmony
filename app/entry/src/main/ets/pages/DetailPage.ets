import { router, uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { cachedBody, httpDelete, httpGet, httpPost, httpPut } from '../common/Http';
import { cachePut } from '../common/PageCache';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import {
  CommentItem, DetailParams, ItemDetail, LibraryInfo, MediaFile, MediaItem, PlayerParams, StreamItem,
  StreamList
} from '../common/Types';
import { clock, runtimeText, scoreText, sizeText, dateText } from '../common/Util';
import { safeDetail, safeItems, safeStreams } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { ActorChips } from '../ext/actors/ActorChips';
import { addWatchLater, removeWatchLater } from '../ext/watchlater/WatchLaterApi';
import { FacetTagChips, SeriesCard } from '../ext/facets/ItemFacetBlocks';
import { ItemFacets, emptyItemFacets, safeItemFacets } from '../ext/facets/FacetTypes';
import { HighlightStrip } from '../ext/highlights/HighlightStrip';
import { MarkBadges } from '../view/MarkBadges';
import { CollectionSheet } from '../ext/collections/CollectionSheet';
import { RatingStars, rateColor, rateLabel } from '../ext/ratings/RatingStars';
import { StillsWall } from '../view/StillsWall';
import { PosterCard } from '../view/PosterCard';
import { CommentSheet, commentPreview } from '../view/CommentSheet';
import { PlayerView } from '../view/PlayerView';

/** 剧照查看器入参（pages/ImageViewerPage）。 */
interface StillParams {
  urls: string[];
  index: number;
  title: string;
}

function emptyDetail(): ItemDetail {
  const d: ItemDetail = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    favorite: false, position: 0, duration: 0, finished: false, files: [], marks: [], stills: [],
    still_ratios: [], still_likes: [], comments: []
  };
  return d;
}

@Entry
@Component
export struct DetailPage {
  /**
   * 嵌在播放页下面当「详情」用（竖屏顶部的可拖动区域）。
   *
   * 这时不读路由参数、不画返回按钮、点播放不 push 新页面 —— 交给宿主播。
   * 这样播放页下面显示的就是**原原本本的详情页**，不用另写一份。
   */
  @Prop embedded: boolean = false;
  @Prop hostMid: number = 0;
  /** 宿主播放回调：fileKey / fileName。 */
  onHostPlay: (fileKey: string, fileName: string) => void =
    (fileKey: string, fileName: string) => {};

  @State detail: ItemDetail = emptyDetail();
  /** 就地播放（2.4.6.11）：播放器直接长在本页顶部，不再跳播放页。 */
  @State playerOn: boolean = false;
  @State pKey: string = '';
  @State pName: string = '';
  @State pPos: number = 0;
  /** 页内播放器当前形态（由 PlayerView 上报）：返回键据此先退全屏。 */
  @State pMode: string = 'portrait';
  /** 请求页内播放器退出全屏（自增信号）。 */
  @State pExitSig: number = 0;
  /** 带 autoplay 参数进来：详情就绪后自动开播。 */
  private pendingAuto: boolean = false;
  /** 「从横屏转回竖屏」时高亮评分区（第 3 条：不弹窗）。 */
  @State rateHint: boolean = false;
  @State facets: ItemFacets = emptyItemFacets();
  @State streams: StreamItem[] = [];
  @State showVersions: boolean = false;
  @State versionsLoading: boolean = false;
  @State loading: boolean = true;
  @State fav: boolean = false;
  // 公开扩展 ratings / collections
  @State myRating: number = 0;
  @State collectionIds: number[] = [];
  /** 公开扩展 watch_later：是否已加入稍后再看。 */
  @State watchLater: boolean = false;
  @State showCollections: boolean = false;
  @State showRatePrompt: boolean = false;
  /** 点开的那一条评价全文（空串 = 弹层关闭）。 */
  @State openCommentBody: string = '';
  /** 写/改自己的评价：草稿与弹层开关。 */
  @State showCommentEditor: boolean = false;
  @State commentDraft: string = '';
  @State savingComment: boolean = false;
  /** 我自己写的那条评价正文（空 = 还没写）。服务端在 comments 里用 mine 标记。 */
  @State myComment: string = '';
  /** >0 = 正在改哪一条（0 = 新写一条）。一部片可以有多条我的评价。 */
  @State editingCommentId: number = 0;
  @State openCommentDate: string = '';
  /** 本页发起过播放；从播放页返回且还没打过分时，弹一次评分提示。 */
  private playedHere: boolean = false;
  private promptShown: boolean = false;
  // 盲盒转场：从中心的小图放大铺满，等详情就绪后再从中心扩散淡出
  @State heroOn: boolean = false;
  @State heroUrl: string = '';
  @State heroScale: number = 0.3;
  @State heroFade: number = 1;
  /** 相似影片：详情主体先出，这块异步补；拉不到就整块不渲染。 */
  @State similar: MediaItem[] = [];
  @State commentsOpen: boolean = false;
  private heroT0: number = 0;
  private heroZoomed: boolean = false;
  private heroLoaded: boolean = false;
  private heroGone: boolean = false;
  @State expanded: boolean = false;
  @State toast: string = '';
  private metaId: number = 0;
  /**
   * 起播意图：-1 = 按进度续播（默认），>=0 = 从这一秒开始。
   *
   * 顶部播放拆成「继续 / 从头」之后，这两个入口和多版本选版面板是交叉的：
   * 先点「从头」再选版本、或先点亮点再说，都必须把意图带到真正起播的那一刻，
   * 所以意图存在这里，`playFile()` 消费一次就清掉（避免下一次点「继续」还从 0 开始）。
   */
  private startAt: number = -1;

  aboutToAppear(): void {
    if (this.embedded) {
      // 嵌在播放页里：id 由宿主给，没有路由参数，也不做盲盒转场
      this.metaId = this.hostMid;
      this.load();
      return;
    }
    const params = router.getParams() as DetailParams;
    if (params !== undefined && params !== null && params.id !== undefined && params.id !== null) {
      this.metaId = Number(params.id);
    }
    if (params !== undefined && params !== null && params.heroUrl !== undefined
      && params.heroUrl !== null && params.heroUrl.length > 0) {
      this.startHero(params.heroUrl);
    }
    // 带 autoplay 进来：等详情就绪后原地开播（观看记录 / 弹幕 / 截帧的跳转入口）
    if (params !== undefined && params !== null && params.autoplay === true) {
      this.pendingAuto = true;
      const pos: number = params.position === undefined || params.position === null
        ? 0 : Number(params.position);
      this.pPos = pos > 5 ? pos : 0;
      this.pKey = params.fileKey === undefined || params.fileKey === null ? '' : params.fileKey;
      this.pName = params.fileName === undefined || params.fileName === null ? '' : params.fileName;
    }
    this.load();
  }

  /**
   * 盲盒转场（全部在详情页内部完成，不再依赖上一页的过渡层）。
   *
   * 这样淡出的时候，下面**已经是渲染好的详情页**，不会先露出演员页，
   * 也不会再叠加系统的左滑转场。
   *   1) 一张小图从屏幕中心长到铺满（340ms）
   *   2) 等详情数据就绪
   *   3) 从中心扩散淡出（380ms），露出底下的详情
   */
  private startHero(url: string): void {
    this.heroUrl = url;
    this.heroOn = true;
    this.heroScale = 0.3;
    this.heroFade = 1;
    this.heroT0 = Date.now();
    animateTo({ duration: 340, curve: Curve.EaseOut }, () => {
      this.heroScale = 1.0;
    });
    setTimeout(() => {
      this.heroZoomed = true;
      this.tryReveal();
    }, 340);
    // 兜底：网络卡住也不能一直盖着
    setTimeout(() => {
      this.heroLoaded = true;
      this.heroZoomed = true;
      this.tryReveal();
    }, 2200);
  }

  private tryReveal(): void {
    if (!this.heroOn || this.heroGone || !this.heroZoomed || !this.heroLoaded) {
      return;
    }
    this.heroGone = true;
    // 至少停留 160ms，让人看清"这张图铺满了"
    const held: number = Date.now() - this.heroT0;
    const wait: number = Math.max(0, 500 - held);
    setTimeout(() => {
      animateTo({ duration: 380, curve: Curve.EaseIn }, () => {
        this.heroFade = 0;
        this.heroScale = 1.18;
      });
      setTimeout(() => {
        this.heroOn = false;
      }, 400);
    }, wait);
  }

  /**
   * 影片的关键属性：无码 / 破解 / 流出 / 中字。
   *
   * 服务端 /api/user/item 已经按文件汇总好 `marks`，优先用它；
   * 老服务端没有这个字段时再退回本地从 files 汇总（兼容，不再各页各写）。
   */
  private marks(): string[] {
    if (this.detail.marks !== undefined && this.detail.marks !== null && this.detail.marks.length > 0) {
      return this.detail.marks;
    }
    const out: string[] = [];
    let cracked: boolean = false;
    let leaked: boolean = false;
    let uncensored: boolean = false;
    let sub: boolean = false;
    for (let i = 0; i < this.detail.files.length; i++) {
      const f: MediaFile = this.detail.files[i];
      // 库里是大写 CRACKED / LEAKED，统一转大写再比
      const mosaic: string = f.mosaic.toUpperCase();
      if (mosaic === 'CRACKED') {
        cracked = true;
      } else if (mosaic === 'LEAKED') {
        leaked = true;
      } else if (mosaic === 'UNCENSORED') {
        uncensored = true;
      }
      if (f.has_subtitle_in_name || f.has_external_subtitle) {
        sub = true;
      }
    }
    if (cracked) {
      out.push('破解');
    }
    if (leaked) {
      out.push('流出');
    }
    if (uncensored) {
      out.push('无码');
    }
    if (sub) {
      out.push('中字');
    }
    return out;
  }

  /**
   * 换掉文件列表后重建整个 detail 对象。
   * 只写 `this.detail.files = xxx` 在某些 ArkUI 版本上不会触发重绘，
   * 详情页这类 @State 对象统一走「整对象替换」最稳（见 FacetPage.setFav）。
   */
  private cloneDetail(files: MediaFile[], likes: string[]): ItemDetail {
    const d: ItemDetail = {
      id: this.detail.id, number: this.detail.number, title: this.detail.title,
      plot: this.detail.plot, actors: this.detail.actors, tags: this.detail.tags,
      studio: this.detail.studio, series: this.detail.series,
      release: this.detail.release, runtime: this.detail.runtime,
      content_type: this.detail.content_type, score: this.detail.score,
      poster: this.detail.poster, fanart: this.detail.fanart,
      favorite: this.detail.favorite, position: this.detail.position,
      duration: this.detail.duration, finished: this.detail.finished,
      files: files, marks: this.detail.marks, stills: this.allStills(),
      still_ratios: this.mergedRatios(), still_likes: likes,
      comments: this.detail.comments,
    };
    return d;
  }

  private withFiles(files: MediaFile[]): ItemDetail {
    return this.cloneDetail(files, this.likesOf());
  }

  /** 剧照墙用的完整列表：我截的帧在前，刮削剧照在后。 */
  private allStills(): string[] {
    const out: string[] = [];
    const mine: string[] | undefined = this.detail.my_stills;
    if (mine !== undefined) {
      for (let i = 0; i < mine.length; i++) {
        out.push(mine[i]);
      }
    }
    for (let i = 0; i < this.detail.stills.length; i++) {
      out.push(this.detail.stills[i]);
    }
    return out;
  }

  /** 与 allStills() 等长的比例：我截的帧给 0（客户端按实际图量），刮削的沿用服务端值。 */
  private mergedRatios(): number[] {
    const out: number[] = [];
    const mine: string[] | undefined = this.detail.my_stills;
    if (mine !== undefined) {
      for (let i = 0; i < mine.length; i++) {
        out.push(0);
      }
    }
    for (let i = 0; i < this.detail.still_ratios.length; i++) {
      out.push(this.detail.still_ratios[i]);
    }
    return out;
  }

  /** 已「喜爱」的剧照地址（老服务端没这字段 → 空数组）。 */
  private likesOf(): string[] {
    const v: string[] | undefined = this.detail.still_likes;
    return v === undefined ? [] : v;
  }

  /** 与 stills 等长的心形状态，供 StillsWall 逐张画实心/空心。 */
  private likedFlags(): boolean[] {
    const likes: string[] = this.likesOf();
    const flags: boolean[] = [];
    const list: string[] = this.allStills();
    for (let i = 0; i < list.length; i++) {
      flags.push(likes.indexOf(list[i]) >= 0);
    }
    return flags;
  }

  /** 与 allStills() 等长：哪几张是我自己截的帧（墙上要标出来，第 4 条）。 */
  private minedFlags(): boolean[] {
    const flags: boolean[] = [];
    const mine: string[] | undefined = this.detail.my_stills;
    const n: number = mine === undefined ? 0 : mine.length;
    for (let i = 0; i < this.allStills().length; i++) {
      flags.push(i < n);
    }
    return flags;
  }

  /** 我截的帧有几张（剧照标题行显示「其中我截的 N」）。 */
  private myStillCount(): number {
    const mine: string[] | undefined = this.detail.my_stills;
    return mine === undefined ? 0 : mine.length;
  }

  /**
   * 点剧照右上角的心：喜欢 / 取消喜欢这一张。
   * 先本地翻状态（点下去立刻有反馈），失败再翻回来并提示；服务端只存
   * 「影片 id + 图片地址」，不写上游，也不影响收藏与评分。
   */
  private async toggleStillLike(index: number): Promise<void> {
    const list: string[] = this.allStills();
    const url: string = index >= 0 && index < list.length ? list[index] : '';
    if (url.length === 0) {
      return;
    }
    const before: string[] = this.likesOf().slice();
    const likes: string[] = before.slice();
    const at: number = likes.indexOf(url);
    const liked: boolean = at < 0;
    if (liked) {
      likes.push(url);
    } else {
      likes.splice(at, 1);
    }
    this.detail = this.cloneDetail(this.detail.files, likes);
    const ratio: number = index < this.detail.still_ratios.length
      ? this.detail.still_ratios[index] : 0;
    try {
      await httpPost(`${Store.I.user}/api/user/stills/like`, Store.I.token,
        JSON.stringify({ id: this.detail.id, url: url, ratio: ratio, liked: liked }));
      this.toast = liked ? '已加入喜爱的剧照' : '已取消喜爱';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] still like: ${e.code} ${e.message}`);
      this.detail = this.cloneDetail(this.detail.files, before);
      this.toast = e.code === 404 ? '服务端还没有这个功能（需 1.3.25+）' : '保存失败，请检查连接';
    }
    setTimeout(() => {
      this.toast = '';
    }, 1600);
  }

  /** 文件所在目录（用于判断「删整个目录」时同目录还有哪些行）。 */
  private folderOf(path: string): string {    const index: number = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : '';
  }

  /** 文件属于哪个库：详情页文件行要显示来源（Store 里已有库 id → 名称）。 */
  private libraryName(id: number): string {
    const libs: LibraryInfo[] = Store.I.libraries;
    for (let i = 0; i < libs.length; i++) {
      if (libs[i].id === id) {
        return libs[i].name;
      }
    }
    return id > 0 ? `库 ${id}` : '';
  }

  /** 一行文件：文件名 + 清晰度 / 所在库 / 体积，点一下直接播这个版本。 */
  @Builder
  FileRow(file: MediaFile) {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(this.fileName(file.path))
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 5 }) {
          Text(file.definition.length > 0 ? file.definition : '视频')
            .fontSize(9)
            .fontColor(Theme.TEXT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(4)
          if (this.libraryName(file.library_id).length > 0) {
            Text(this.libraryName(file.library_id))
              .fontSize(9)
              .fontColor(Theme.GOLD)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor('#2AF2C14E')
              .borderRadius(4)
          }
          Text(sizeText(file.size))
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('▶')
        .fontSize(9)
        .fontColor(Theme.ACCENT)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius(6)
  }

  /** 封面地址：刮削海报 → 我截的关键帧（R25）→ 空。 */
  private coverUrl(): string {
    if (this.detail.poster.length > 0) {
      return this.detail.poster;
    }
    return this.detail.frame_cover === undefined ? '' : this.detail.frame_cover;
  }

  /** 评价正文是 markdown：列表只显示摘要，点开看全文并渲染链接（见 view/CommentSheet）。 */
  private shownComments(): CommentItem[] {
    if (this.commentsOpen) {
      return this.detail.comments;
    }
    return this.detail.comments.slice(0, 2);
  }

  /**
   * 从播放页返回（Emby 模式）：不弹窗，只把「我的评分」那块点亮一下
   * （用户上一轮第 3 条：提示改成高亮，别用弹窗打断）。
   */
  onPageShow(): void {
    if (this.playedHere && !this.promptShown && this.myRating === 0 && this.detail.id > 0) {
      this.promptShown = true;
      this.rateHint = true;
      this.toast = '看完了？顺手打个分';
      setTimeout(() => {
        this.toast = '';
      }, 2200);
    }
    if (this.playedHere) {
      // 刚从播放页回来：进度/看完状态都变了，重拉一次详情（有页面缓存，秒出）。
      // 不重拉的话「继续播放 12:34」还停在进场前的那个时间。
      this.playedHere = false;
      this.load(true);
    }
  }

  /**
   * 返回键：页内播放器正横屏时**先退出全屏**（用户第 4 条），
   * 再按一次才退出详情页。B 站模式下播放器长在本页，横屏转回来时
   * 下面露出来的就是详情，正好符合「退出全屏就该看到详情」。
   */
  onBackPress(): boolean {
    if (this.playerOn && this.pMode !== 'portrait') {
      this.pExitSig = this.pExitSig + 1;
      return true;
    }
    return false;
  }

  /**
   * @param skipCache 跳过磁盘缓存直接走网络（从播放页回来刷新进度时用，
   *                  否则会先把 30 分钟前的旧进度铺一遍再跳成新的）
   */
  private async load(skipCache: boolean = false): Promise<void> {
    // 预热进度条预览：服务端首次要现抽 64 格（网盘约 15s），
    // 在这里先起跑，用户从详情页点进播放时多半已经好了。不 await、失败无所谓。
    httpGet(`${Store.I.user}/api/user/preview/${this.metaId}`, Store.I.token)
      .catch((err: BusinessError) => {
        console.error(`[amane] preview warm: ${err.code} ${err.message}`);
      });
    const url: string = `${Store.I.user}/api/user/item/${this.metaId}`;
    // ① 从剧照盲盒进来时已预取，先渲染出来，避免闪一次加载圈
    const cached: ItemDetail | undefined = Store.I.takeDetail(this.metaId);
    if (cached !== undefined) {
      this.applyDetail(cached);
      this.loading = false;
    } else {
      // ② 页面级缓存（用户第 9 条）：这一页刚才看过就先把上次的数据铺上去，
      //    网络在后台刷新。不是「不发请求」，而是「不再让用户对着加载圈等」。
      const stale: string | undefined = skipCache ? undefined : cachedBody(url);
      if (stale !== undefined) {
        try {
          this.applyDetail(safeDetail(JSON.parse(stale) as ItemDetail));
          this.loading = false;
          this.heroLoaded = true;
          this.tryReveal();
        } catch (err) {
          console.info('[amane] detail cache parse failed');
        }
      }
    }
    try {
      const text: string = await httpGet(url, Store.I.token);
      this.applyDetail(safeDetail(JSON.parse(text) as ItemDetail));
      cachePut(url, text, 1800000);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] detail: ${e.code} ${e.message}`);
      if (this.detail.id <= 0) {
        this.toast = '加载失败';
      }
    }
    this.loading = false;
    this.heroLoaded = true;
    this.tryReveal();
    // 从观看记录 / 弹幕 / 截帧点进来的「直接开播」：详情就绪后再起播，
    // 这样页面一渲染就是「顶部已经在放」，切回竖屏也还有详情可看（第 8 条）。
    if (this.pendingAuto && this.detail.id > 0) {
      this.pendingAuto = false;
      if (this.pKey.length === 0 && this.detail.files.length === 1) {
        this.pKey = `f${this.detail.files[0].id}`;
      }
      this.playerOn = true;
    }
    // 分类归属（系列 / 标签 id）单独一次请求，失败不影响详情主体
    if (BuildConfig.ENABLE_FACETS) {
      this.loadFacets();
    }
    // 相似影片也是附加块：不 await，详情先显示完再补出来
    this.loadSimilar();
  }

  /** 把一次详情响应铺到界面上（首屏缓存与网络结果走同一条路，避免两处不一致）。 */
  private applyDetail(detail: ItemDetail): void {
    this.detail = detail;
    this.fav = detail.favorite;
    this.myRating = detail.my_rating === undefined ? 0 : detail.my_rating;
    this.collectionIds = detail.collection_ids === undefined ? [] : detail.collection_ids;
    this.watchLater = detail.watch_later === true;
    this.myComment = '';
    for (let i = 0; i < detail.comments.length; i++) {
      if (detail.comments[i].mine === true) {
        this.myComment = detail.comments[i].body;
      }
    }
    if (detail.favorite) {
      Store.I.favIds.add(detail.id);
    } else {
      Store.I.favIds.delete(detail.id);
    }
  }

  /**
   * 相似影片（同系列 / 同演员 / 共同标签，服务端打分）。
   *
   * 打开新详情时先把上一部的列表清掉，否则上一部的横滑卡会短暂串到这一部下面。
   * 失败就留空 —— 整块不渲染，不占位置也不报错。
   */
  private async loadSimilar(): Promise<void> {
    this.similar = [];
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/item/${this.metaId}/similar?limit=12`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const list: MediaItem[] = obj.items === undefined ? [] : (obj.items as MediaItem[]);
      this.similar = safeItems(list);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] item similar: ${e.code} ${e.message}`);
    }
  }

  private async loadFacets(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/item/${this.metaId}/facets`, Store.I.token);
      this.facets = safeItemFacets(JSON.parse(text) as ItemFacets);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] item facets: ${e.code} ${e.message}`);
    }
  }

  private openStills(index: number): void {
    const params: StillParams = {
      urls: this.allStills(),
      index: index,
      title: this.detail.number.length > 0 ? this.detail.number : this.detail.title
    };
    router.pushUrl({ url: 'pages/ImageViewerPage', params: params });
  }

  /** 有进度可续（且没看完）时，顶部按钮才有「继续 / 从头」两个选项。 */
  private resumable(): boolean {
    return this.detail.position > 5 && !this.detail.finished;
  }

  private play(fromStart: boolean): void {
    // 从头播 = 位置 0；否则让 playFile 按进度自己决定
    this.startAt = fromStart ? 0 : -1;
    // 一个条目挂多个版本时先让用户选；只有一个文件就直接播
    if (this.detail.files.length > 1) {
      this.openVersions();
      return;
    }
    // 只有一个文件也把 key 带上：弹幕/进度的「文件」归属要确定，别再让播放页猜。
    // 注意 detail.files 是 MediaFile（只有 id/path），播放用的 key 形如 f<文件id>。
    const only: MediaFile | undefined =
      this.detail.files.length === 1 ? this.detail.files[0] : undefined;
    if (only !== undefined) {
      const slash: number = only.path.lastIndexOf('/');
      this.playFile(`f${only.id}`, slash >= 0 ? only.path.substring(slash + 1) : only.path);
    } else {
      this.playFile('', '');
    }
  }

  /** 点亮点缩略图：从这一秒起播，并且用**抽帧的那个文件**（多版本时位置才准）。 */
  private playAt(t: number, fileKey: string, fileName: string): void {
    this.startAt = Math.max(0, t);
    this.playFile(fileKey, fileName);
  }

  private playFile(fileKey: string, fileName: string): void {
    const start: number = this.startAt >= 0
      ? this.startAt
      : (this.detail.finished ? 0 : this.detail.position);
    this.startAt = -1;
    this.showVersions = false;
    this.playedHere = true;
    // 嵌在播放页里：换版本 = 换播放器当前的文件，不再叠一层播放页
    if (this.embedded) {
      this.onHostPlay(fileKey, fileName);
      return;
    }
    // 就地起播（默认）：播放器长在本页顶部，不跳页、不重拉详情
    if (Store.I.prefString('player_open_mode', 'bili') === 'bili') {
      this.pKey = fileKey;
      this.pName = fileName;
      this.pPos = start;
      this.playerOn = true;
      return;
    }
    const params: PlayerParams = {
      id: this.detail.id,
      number: this.detail.number,
      title: this.detail.title,
      position: start,
      fileKey: fileKey,
      fileName: fileName
    };
    // Emby 模式：push 一层播放页（用户第 1 条）。
    // 退出播放 = 回本页（详情页还在栈里，滚动位置和数据都留着），
    // 而不是把详情页一起 replace 掉 —— 那会让人「退播放直接退到列表」。
    //
    // 指向 PlayerHostPage 而不是 PlayerPage：后者会被并行会话的 emu-verify
    // 还原成旧的自包含播放器（见 PlayerHostPage 头部说明）。
    router.pushUrl({ url: 'pages/PlayerHostPage', params: params });
  }

  /**
   * 公开扩展 watch_later：「稍后再看」切换。
   *
   * 与收藏刻意分开：收藏表示「我中意/我拥有」，稍后再看只是「排个队回头再看」，
   * 所以它不进收藏表、不参与清单归类，也不影响入库。
   */
  private async toggleWatchLater(): Promise<void> {
    if (!BuildConfig.ENABLE_WATCHLATER || this.metaId <= 0) {
      return;
    }
    const want: boolean = !this.watchLater;
    this.watchLater = want;
    try {
      if (want) {
        await addWatchLater(this.metaId);
      } else {
        await removeWatchLater(this.metaId);
      }
      this.toast = want ? '已加入稍后再看' : '已移出稍后再看';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] watch later: ${e.code} ${e.message}`);
      this.watchLater = !want;
      this.toast = e.code === 404 ? '服务端还没有这个功能（需 1.3.38+）' : '保存失败，请检查连接';
    }
    setTimeout(() => {
      this.toast = '';
    }, 1800);
  }

  /** 拉取该条目的全部可播版本（含分辨率/体积/时长/所在库）。 */
  private async openVersions(): Promise<void> {
    this.showVersions = true;
    if (this.streams.length > 0 || this.versionsLoading) {
      return;
    }
    this.versionsLoading = true;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/streams/${Store.I.playbackSource}/${this.metaId}`, Store.I.token);
      this.streams = safeStreams(JSON.parse(text) as StreamList);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] streams: ${e.code} ${e.message}`);
      this.toast = '版本列表加载失败';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    }
    this.versionsLoading = false;
  }

  private versionLine(s: StreamItem): string {
    const parts: string[] = [];
    if (s.definition.length > 0) {
      parts.push(s.definition);
    }
    if (s.size > 0) {
      parts.push(sizeText(s.size));
    }
    if (s.duration > 0) {
      parts.push(clock(s.duration));
    }
    if (s.library.length > 0) {
      parts.push(s.library);
    }
    return parts.join(' · ');
  }

  private async toggleFav(): Promise<void> {
    try {
      const on: boolean = await Store.I.toggleFav(this.detail.id);
      this.fav = on;
      this.toast = on ? '已加入收藏' : '已取消收藏';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] fav: ${e.code} ${e.message}`);
      this.toast = '操作失败';
    }
  }

  @Builder
  VersionRow(s: StreamItem) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(s.name.length > 0 ? s.name : '视频文件')
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 6 }) {
          if (s.definition.length > 0) {
            Text(s.definition)
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(4)
          }
          if (s.has_subtitle) {
            Text('字幕')
              .fontSize(9)
              .fontColor(Theme.GOLD)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor('#332E2410')
              .borderRadius(4)
          }
          Text(this.versionLine(s))
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        if (!s.available && s.detail.length > 0) {
          Text(s.detail)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('▶')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .borderRadius(15)
        .backgroundColor(Theme.ACCENT)
    }
    .width('100%')
    .padding(11)
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
    .onClick(() => {
      this.playFile(s.key, s.name);
    })
  }

  @Builder
  VersionSheet() {
    Column() {
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.detail.files.length > 1 ? '选择版本' : '选择流')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            Text(`${this.detail.number} · 共 ${this.streams.length} 个可播文件`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.showVersions = false;
              // 关掉选版面板 = 这次播放没发生，起播意图跟着作废
              this.startAt = -1;
            })
        }
        .width('100%')

        if (this.versionsLoading) {
          Column() {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .height(90)
          .justifyContent(FlexAlign.Center)
        } else if (this.streams.length === 0) {
          Column({ space: 6 }) {
            Text('没有拿到可播版本')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
            Text('直接用默认文件播放')
              .fontSize(11)
              .fontColor(Theme.ACCENT)
              .onClick(() => {
                this.playFile('', '');
              })
          }
          .width('100%')
          .height(90)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.streams, (s: StreamItem) => {
                this.VersionRow(s)
              }, (s: StreamItem) => `ver-${s.key}`)
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 340 })
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 22 })
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius({ topLeft: 18, topRight: 18 })
      .onClick(() => {
        // 吞掉点击，避免穿透到遮罩把面板关掉
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#99000000')
    .onClick(() => {
      this.showVersions = false;
      this.startAt = -1;
    })
  }

  /** 保存 / 删除我自己的评价。body 空串 = 删除。 */
  private async saveComment(): Promise<void> {
    if (this.savingComment) {
      return;
    }
    const text: string = this.commentDraft.trim();
    if (text.length === 0) {
      this.toast = '评价不能为空';
      setTimeout(() => {
        this.toast = '';
      }, 1600);
      return;
    }
    this.savingComment = true;
    try {
      if (this.editingCommentId > 0) {
        await httpPut(
          `${Store.I.user}/api/user/item/${this.metaId}/comment/${this.editingCommentId}`,
          Store.I.token, JSON.stringify({ body: text }));
      } else {
        await httpPost(`${Store.I.user}/api/user/item/${this.metaId}/comment`, Store.I.token,
          JSON.stringify({ body: text }));
      }
      this.showCommentEditor = false;
      this.editingCommentId = 0;
      this.commentDraft = '';
      await this.load();
      this.toast = '评价已保存';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] save comment: ${e.code} ${e.message}`);
      this.toast = '保存失败';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    }
    this.savingComment = false;
  }

  /** 删除单条我的评价：先确认，再删。 */
  private askDeleteComment(id: number): void {
    AlertDialog.show({
      title: '删除这条评价？',
      message: '删了就找不回来了（只删你写的这条，影片本身不受影响）。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.DANGER,
        action: () => {
          this.deleteComment(id);
        }
      }
    });
  }

  private async deleteComment(id: number): Promise<void> {
    try {
      await httpDelete(`${Store.I.user}/api/user/item/${this.metaId}/comment/${id}`, Store.I.token);
      await this.load();
      this.toast = '评价已删除';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] del comment: ${e.code} ${e.message}`);
      this.toast = '删除失败';
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    }
  }

  @Builder
  CommentEditor() {
    Column() {
      Column({ space: 10 }) {
        Text(this.editingCommentId > 0 ? '改这条评价' : '写一条评价')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        TextArea({ text: this.commentDraft, placeholder: '写点什么…（会同步到你的服务端，只有你自己看得到这条标记）' })
          .height(160)
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onChange((v: string) => {
            this.commentDraft = v;
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.showCommentEditor = false;
            })
          Text(this.savingComment ? '保存中…' : '保存')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.saveComment();
            })
        }
        .width('100%')

      }
      .width('88%')
      .padding(18)
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        // 吞掉点击，避免穿透到遮罩
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
    .onClick(() => {
      this.showCommentEditor = false;
    })
  }

  /** 播放返回后的打分提示：复用同一排星星，打完或「以后再说」自动收起。 */
  @Builder
  RatePrompt() {
    Column() {
      Column({ space: 10 }) {
        Text('看完啦，给这部片打个分？')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text(this.detail.number.length > 0 ? this.detail.number : this.detail.title)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        RatingStars({
          metaId: this.metaId,
          score: this.myRating,
          starSize: 30,
          showDesc: true,
          onRate: (v: number) => {
            this.myRating = v;
            this.showRatePrompt = false;
            this.toast = v > 0 ? `已打分：${rateLabel(v)}` : '已清除评分';
            setTimeout(() => {
              this.toast = '';
            }, 1800);
          }
        })
        // 五档图例：不打分也能看懂「几分=什么感觉」，选中的那档会上下加粗
        Text('配菜 · 有意思 · 对味 · 反复看 · 社保')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .textAlign(TextAlign.Center)
          .margin({ top: 2 })
        Text('以后再说')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .onClick(() => {
            this.showRatePrompt = false;
          })
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 22, bottom: 20 })
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        // 吞掉点击，避免穿透到遮罩
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
    .onClick(() => {
      this.showRatePrompt = false;
    })
  }

  @Builder
  Chip(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Theme.TEXT_DIM)
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .backgroundColor(Theme.CARD)
      .borderRadius(11)
      .margin({ right: 6, bottom: 6 })
  }

  /**
   * 详情页主体（顶部大图 + 全部信息块）。
   *
   * 抽成 @Builder 是为了让私有扩展「右滑删除」能把它整体包一层；
   * public 通道没有这个扩展，直接渲染同一份内容，行为与之前完全一致。
   */
  @Builder
  Body() {
        Scroll() {
          Column() {
            // 顶部原来是 340vp 的剧照大图，现在这块位置留给播放器（16:9）。
            // 播放器/海报是页面根 Stack 里的一层（固定不滚动），这里只用等高的
            // 空白把它顶开 —— 16:9 用 aspectRatio 算，不需要知道窗口宽度。
            Column()
              .width('100%')
              .aspectRatio(16 / 9)

            Column() {
              Row({ space: 14 }) {
                Image(Store.I.img(this.coverUrl()))
                  .width(104)
                  .height(148)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .backgroundColor(Theme.CARD)
                  .shadow({ radius: 16, color: '#99000000', offsetY: 6 })

                Column({ space: 6 }) {
                  Text(this.detail.number)
                    .fontSize(12)
                    .fontColor(Theme.ACCENT)
                    .fontWeight(FontWeight.Medium)
                  Text(this.detail.title.length > 0 ? this.detail.title : this.detail.number)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Theme.TEXT)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.metaLine())
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .maxLines(2)
                  if (this.detail.score > 0) {
                    Text(`★ ${scoreText(this.detail.score)}`)
                      .fontSize(12)
                      .fontColor(Theme.GOLD)
                  }
                  if (this.marks().length > 0) {
                    MarkBadges({ marks: this.marks(), max: 4, badgeSize: 10, fill: 'card' })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .margin({ top: 12 })

              // 操作区
              Row({ space: 10 }) {
                Button() {
                  if (this.resumable()) {
                    // 和「从头」并排之后，一行放不下「继续播放 01:40:21」（真机被截成省略号），
                    // 所以主按钮给两行：上面是动作，下面就是「从哪儿接着播」
                    Column({ space: 1 }) {
                      Text('继续播放')
                        .fontSize(13)
                        .fontColor('#FFFFFF')
                      Text(`${clock(this.detail.position)} 起`)
                        .fontSize(9)
                        .fontColor('#D9FFFFFF')
                    }
                  } else {
                    Row({ space: 6 }) {
                      Text('▶')
                        .fontSize(13)
                        .fontColor('#FFFFFF')
                      Text(this.playLabel())
                        .fontSize(14)
                        .fontColor('#FFFFFF')
                    }
                  }
                }
                .layoutWeight(1)
                .height(42)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(21)
                .onClick(() => {
                  this.play(false);
                })

                // 有进度时补一个「从头」：想重看不用先进播放页再拖进度条
                if (this.resumable()) {
                  Button() {
                    Row({ space: 4 }) {
                      Text('⏮')
                        .fontSize(11)
                        .fontColor(Theme.TEXT)
                      Text('从头')
                        .fontSize(12)
                        .fontColor(Theme.TEXT)
                    }
                  }
                  .width(66)
                  .height(42)
                  .backgroundColor(Theme.CARD)
                  .borderRadius(21)
                  .onClick(() => {
                    this.play(true);
                  })
                }

                Column({ space: 1 }) {
                  Text(this.fav ? '♥' : '♡')
                    .fontSize(15)
                    .fontColor(this.fav ? Theme.ACCENT : Theme.TEXT)
                  Text(this.fav ? '已收藏' : '收藏')
                    .fontSize(9)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .width(58)
                .height(42)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Theme.CARD)
                .borderRadius(21)
                .onClick(() => {
                  this.showCollections = true;
                })

              }
              .width('100%')
              .margin({ top: 16 })

              // 公开扩展 watch_later：稍后再看。细条放在主操作行下面，
              // 不跟「播放 / 收藏 / 还行」抢横向空间。
              if (BuildConfig.ENABLE_WATCHLATER) {
                Row({ space: 6 }) {
                  Text('⏱')
                    .fontSize(13)
                    .fontColor(this.watchLater ? Theme.ACCENT : Theme.TEXT_DIM)
                  Text(this.watchLater ? '已加入稍后再看' : '稍后再看')
                    .fontSize(12)
                    .fontColor(this.watchLater ? Theme.ACCENT : Theme.TEXT_DIM)
                  Blank()
                  Text(this.watchLater ? '点一下移出' : '先记下来，回头在观看记录里找')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                .backgroundColor(this.watchLater ? Theme.ACCENT_SOFT : Theme.CARD)
                .borderRadius(12)
                .margin({ top: 10 })
                .onClick(() => {
                  this.toggleWatchLater();
                })
              }

              // 公开扩展 ratings：我的评分。和头部那个上游站点评分隔开，两套数据互不覆盖。
              if (BuildConfig.ENABLE_RATINGS) {
                Column({ space: 6 }) {
                  Row() {
                    Text('我的评分')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                    if (this.myRating > 0) {
                      Text(`${this.myRating} 星 · ${rateLabel(this.myRating)}`)
                        .fontSize(11)
                        .fontColor(rateColor(this.myRating))
                    } else {
                      Text(this.rateHint ? '点这里打个分' : '还没打过分')
                        .fontSize(11)
                        .fontColor(this.rateHint ? Theme.ACCENT : Theme.TEXT_DIM)
                    }
                  }
                  .width('100%')
                  RatingStars({
                    metaId: this.metaId,
                    score: this.myRating,
                    showDesc: true,
                    onRate: (v: number) => {
                      this.myRating = v;
                      this.rateHint = false;
                      this.toast = v > 0 ? `已打分：${rateLabel(v)}` : '已清除评分';
                      setTimeout(() => {
                        this.toast = '';
                      }, 1800);
                    }
                  })
                }
                .width('100%')
                .padding(this.rateHint ? 10 : 0)
                .backgroundColor(this.rateHint ? '#1FFFC53D' : '#00000000')
                .borderRadius(12)
                .border({
                  width: this.rateHint ? 1 : 0,
                  color: this.rateHint ? '#66FFC53D' : '#00000000'
                })
                .margin({ top: 16 })
              }

              // 公开扩展 highlights：影片亮点（片子里随机位置的抽帧缩略图，点图从该处起播）。
              // 服务端抽不到帧（没 ffmpeg / 文件不在线）时组件自己整块隐藏，核心页面不受影响。
              if (BuildConfig.ENABLE_HIGHLIGHTS && this.detail.files.length > 0) {
                HighlightStrip({
                  metaId: this.metaId,
                  onPick: (t: number, fileKey: string, fileName: string) => {
                    this.playAt(t, fileKey, fileName);
                  }
                })
              }

              // 私有扩展：手动入库状态卡（2.4.5 起与收藏解耦，不再自动触发）

              // 公开扩展 facets：所属系列（名称 + 同系列片数，点进系列影片墙）
              if (BuildConfig.ENABLE_FACETS && this.facets.series.name.length > 0) {
                Column() {
                  SeriesCard({
                    series: this.facets.series,
                    studioName: this.facets.studio.name
                  })
                }
                .width('100%')
                .margin({ top: 16 })
              }

              // 标签：装了 facets 扩展就是可点 chip，能顺着一个标签看下去；
              // 没装（public 精简部署）时退回纯文本 chip，核心行为不变
              if (BuildConfig.ENABLE_FACETS
                && (this.facets.tags.length > 0 || this.facets.user_tags.length > 0
                  || this.facets.directors.length > 0)) {
                FacetTagChips({
                  tags: this.facets.tags,
                  userTags: this.facets.user_tags,
                  directors: this.facets.directors,
                  studio: this.facets.studio,
                  prefix: this.facets.prefix
                })
              } else if (this.detail.tags.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.detail.tags, (tag: string) => {
                    this.Chip(tag)
                  }, (tag: string) => `tag-${tag}`)
                }
                .width('100%')
                .margin({ top: 14 })
              }

              // 公开扩展 actors：演员名变成可点 chip，直接进演员页；
              // 关掉 ENABLE_ACTORS 时退回原来的纯文本，核心不残留扩展行为。
              if (this.detail.actors.length > 0) {
                if (BuildConfig.ENABLE_ACTORS) {
                  ActorChips({ metaId: this.metaId, names: this.detail.actors })
                } else {
                  Column({ space: 6 }) {
                    Text('出演')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                    Text(this.detail.actors.join(' / '))
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ top: 14 })
                }
              }

              // 简介
              if (this.detail.plot.length > 0) {
                Column({ space: 6 }) {
                  Text('简介')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                  Text(this.detail.plot)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_DIM)
                    .lineHeight(19)
                    .maxLines(this.expanded ? 40 : 4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(this.expanded ? '收起' : '展开')
                    .fontSize(11)
                    .fontColor(Theme.ACCENT)
                    .onClick(() => {
                      this.expanded = !this.expanded;
                    })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 14 })
              }

              // 文件：排在剧照前面 —— 瀑布流一铺就是好几屏，把「选版本直接播」顶到墙底下太难受
              if (this.detail.files.length > 0) {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text(this.detail.files.length > 1
                      ? `版本（${this.detail.files.length}）· 点一行播这个文件`
                      : `文件（${this.detail.files.length}）`)
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                  }
                  .width('100%')

                  ForEach(this.detail.files, (file: MediaFile) => {
                    Column() {
                      this.FileRow(file)
                    }
                    .width('100%')
                    .onClick(() => {
                      this.playFile(`f${file.id}`, this.fileName(file.path));
                    })
                  }, (file: MediaFile) => `file-${file.id}`)
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 剧照：两列瀑布流，横竖版各按原比例占位（不再一刀切成 16:9），点开进全屏查看器
              if (this.allStills().length > 0) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    Text('剧照')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(`${this.allStills().length}`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    if (this.myStillCount() > 0) {
                      Text(`其中我截的 ${this.myStillCount()}`)
                        .fontSize(9)
                        .fontColor('#FFD06B')
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                        .backgroundColor('#26FFD06B')
                        .borderRadius(5)
                    }
                    Blank()
                    Text('点开看大图 ›')
                      .fontSize(10)
                      .fontColor(Theme.ACCENT)
                  }
                  .width('100%')
                  StillsWall({
                    urls: this.allStills(),
                    ratios: this.mergedRatios(),
                    showLike: true,
                    liked: this.likedFlags(),
                    mined: this.minedFlags(),
                    onLike: (index: number) => {
                      this.toggleStillLike(index);
                    },
                    onPick: (index: number) => {
                      this.openStills(index);
                    }
                  })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 相似影片：同系列 / 同演员 / 共同标签，服务端打分排序（同厂牌只加分不单独入选）
              if (this.similar.length > 0) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    Text('相似影片')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(`${this.similar.length}`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                    Text('往右滑 ›')
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                  }
                  .width('100%')

                  Scroll() {
                    Row({ space: 10 }) {
                      ForEach(this.similar, (it: MediaItem) => {
                        PosterCard({
                          item: it,
                          cardWidth: 104,
                          showTitle: true,
                          onTap: () => {
                            const params: DetailParams = { id: it.id };
                            router.pushUrl({ url: 'pages/DetailPage', params: params });
                          }
                        })
                      }, (it: MediaItem) => `sim-${it.id}`)
                    }
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                  .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 评价（0 条时也显示标题行：要能从这里写第一条）
              Column({ space: 8 }) {
                  Row({ space: 6 }) {
                    Text('评价')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(`${this.detail.comments.length} 条`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                    // 管理入口：所有评价的增删改都在那一页集中做
                    Text('管理')
                      .fontSize(11)
                      .fontColor(Theme.TEXT_DIM)
                      .padding({ left: 4, right: 8 })
                      .onClick(() => {
                        router.pushUrl({ url: 'pages/MyCommentsPage' });
                      })
                    Text('写评价')
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor(Theme.ACCENT)
                      .borderRadius(9)
                      .onClick(() => {
                        this.editingCommentId = 0;
                        this.commentDraft = '';
                        this.showCommentEditor = true;
                      })
                    if (this.detail.comments.length > 2) {
                      Text(this.commentsOpen ? '收起' : '展开全部')
                        .fontSize(11)
                        .fontColor(Theme.ACCENT)
                        .onClick(() => {
                          this.commentsOpen = !this.commentsOpen;
                        })
                    }
                  }
                  .width('100%')

                  ForEach(this.shownComments(), (c: CommentItem) => {
                    Column({ space: 5 }) {
                      Text(commentPreview(c.body, this.commentsOpen ? 2000 : 180))
                        .fontSize(12)
                        .fontColor(Theme.TEXT_DIM)
                        .lineHeight(19)
                        .maxLines(6)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Row() {
                        Text(c.created_at.length >= 10
                          ? c.created_at.substring(0, 10) : c.created_at)
                          .fontSize(9)
                          .fontColor(Theme.TEXT_FAINT)
                        Blank()
                        // 我自己写的这条：就地改 / 删（删除有二次确认）
                        if (c.mine === true) {
                          Text('改')
                            .fontSize(9)
                            .fontColor(Theme.ACCENT)
                            .padding({ left: 6, right: 6 })
                            .onClick(() => {
                              this.editingCommentId = c.id;
                              this.commentDraft = c.body;
                              this.showCommentEditor = true;
                            })
                          Text('删')
                            .fontSize(9)
                            .fontColor(Theme.DANGER)
                            .padding({ left: 4, right: 6 })
                            .onClick(() => {
                              this.askDeleteComment(c.id);
                            })
                        }
                        // 长评在列表里只留摘要，点开看全文（链接也能点了）
                        Text('查看全文 ›')
                          .fontSize(9)
                          .fontColor(Theme.ACCENT)
                      }
                      .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width('100%')
                    .padding(10)
                    .backgroundColor(c.mine === true ? Theme.CARD_HI : Theme.CARD)
                    .borderRadius(10)
                    .border({
                      width: c.mine === true ? 1 : 0.5,
                      color: c.mine === true ? Theme.ACCENT : '#14FFFFFF'
                    })
                    .onClick(() => {
                      this.openCommentBody = c.body;
                      this.openCommentDate = c.created_at;
                    })
                  }, (c: CommentItem) => `cm-${c.id}`)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .margin({ top: 16 })

              Blank().height(30)
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 未播放时的顶部海报（16:9）：点一下就在原地开播。
   * 这块原来是一张 340vp 的剧照大图 —— 现在同一块位置直接当成播放器的「封面状态」。
   */
  @Builder
  PosterPlay() {
    Stack({ alignContent: Alignment.Center }) {
      Image(Store.I.img(this.detail.fanart.length > 0 ? this.detail.fanart : this.detail.poster))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor('#000000')

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.45], ['#8C0B0B0F', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(54)
            .height(54)
            .borderRadius(27)
            .backgroundColor('#73000000')
            .border({ width: 0.8, color: '#4DFFFFFF' })
          Image($r('app.media.ic_play'))
            .width(22)
            .height(22)
        }
        .width(54)
        .height(54)

        Text(this.resumable() ? `继续播放 ${clock(this.detail.position)}` : '播放')
          .fontSize(11)
          .fontColor('#F2FFFFFF')
      }
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .aspectRatio(16 / 9)
    .backgroundColor('#000000')
    .onClick(() => {
      this.play(false);
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 私有扩展「右滑删除」现在挂在每个文件行上（见 FileRow），页面本身不再包一层
        this.Body()

        // 顶部 16:9：没播时是海报（点一下就地开播），播了就是播放器本体。
        // 播放器是页面根 Stack 里的一层 —— 详情内容照常在下边滚动，不重拉任何数据。
        if (this.playerOn) {
          PlayerView({
            metaIdParam: this.detail.id,
            numberParam: this.detail.number,
            titleParam: this.detail.title,
            keyParam: this.pKey,
            nameParam: this.pName,
            posParam: this.pPos,
            modeParam: 'portrait',
            autoplay: true,
            posterParam: this.detail.fanart.length > 0 ? this.detail.fanart : this.detail.poster,
            exitSignal: this.pExitSig,
            onModeChange: (m: string) => {
              this.pMode = m;
            },
            onAskRate: () => {
              // 第一次从横屏转回竖屏：不弹窗，把「我的评分」那块高亮一下
              if (this.myRating > 0) {
                return;
              }
              this.rateHint = true;
              this.toast = '看到这儿了，顺手打个分？';
              setTimeout(() => {
                this.toast = '';
              }, 2200);
            },
            onExited: () => {
              // 横屏时点返回箭头 = 先退出全屏（和系统返回键一致），
              // 竖屏时才是「退出播放 + 退出详情页」
              if (this.pMode !== 'portrait') {
                this.pExitSig = this.pExitSig + 1;
                return;
              }
              this.playerOn = false;
              router.back();
            }
          })
        } else {
          this.PosterPlay()
        }

        // 返回按钮（嵌在播放页里时不画：那时候的「返回」是播放页自己的事）
        if (!this.embedded && !this.playerOn) {
          Text('‹')
            .fontSize(24)
            .fontColor('#FFFFFF')
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            // 沉浸光感：用系统材质替掉手写的半透明底 + 模糊，边缘会带流光；
            // 老设备不支持材质时退回半透明底（材质生效时会接管 backgroundColor）
            .backgroundColor('#40000000')
            .systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              materialColor: '#26000000'
            }))
            .margin({ left: 12, top: 8 })
            .onClick(() => {
              router.back();
            })
        }

        if (this.showVersions) {
          this.VersionSheet()
        }

        if (this.showCollections) {
          CollectionSheet({
            metaId: this.metaId,
            favorite: this.fav,
            onClose: () => {
              this.showCollections = false;
            },
            onChanged: (fav: boolean, ids: number[]) => {
              this.fav = fav;
              this.collectionIds = ids;
              this.toast = fav ? (ids.length > 0 ? '已收藏并归类' : '已加入收藏') : '已取消收藏';
              setTimeout(() => {
                this.toast = '';
              }, 1800);
            }
          })
        }

        if (this.showRatePrompt) {
          this.RatePrompt()
        }

        if (this.showCommentEditor) {
          this.CommentEditor()
        }

        if (this.openCommentBody.length > 0) {
          CommentSheet({
            comment: {
              id: 0, body: this.openCommentBody, created_at: this.openCommentDate, updated_at: ''
            },
            onClose: () => {
              this.openCommentBody = '';
              this.openCommentDate = '';
            }
          })
        }

        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor('#CC000000')
            .borderRadius(16)
            .position({ x: '50%', y: '88%' })
            .translate({ x: -40 })
        }
      }

      // 盲盒转场遮罩：压在详情页之上，页面自己先渲染好，再从这里扩散淡出。
      // 整块（含黑底）一起 scale，小尺寸时就是「画面中心一张图长出来」。
      if (this.heroOn) {
        Stack() {
          Image(Store.I.img(this.heroUrl))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(36)
            .opacity(0.45)
          Image(Store.I.img(this.heroUrl))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .scale({ x: this.heroScale, y: this.heroScale })
        .opacity(this.heroFade)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  /**
   * 进场/退场都只淡入淡出，不要系统的左右滑。
   * 从盲盒进来时自己已经做了一次放大+雾化，再叠一个左滑转场会显得两套逻辑打架。
   */
  pageTransition(): void {
    // 只做极短的淡入：完整的「放大 / 扩散」由页面内的 hero 遮罩承担，
    // 这里再叠一个系统左滑会变成两套动效打架。
    PageTransitionEnter({ type: RouteType.None, duration: 120, curve: Curve.EaseOut })
      .opacity(0)
    PageTransitionExit({ type: RouteType.None, duration: 120, curve: Curve.EaseIn })
      .opacity(0)
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.detail.release.length > 0) {
      parts.push(dateText(this.detail.release));
    }
    if (this.detail.runtime > 0) {
      parts.push(runtimeText(this.detail.runtime));
    }
    if (this.detail.studio.length > 0) {
      parts.push(this.detail.studio);
    }
    if (this.detail.series.length > 0) {
      parts.push(this.detail.series);
    }
    return parts.join(' · ');
  }

  private playLabel(): string {
    const n: number = this.detail.files.length;
    if (this.resumable()) {
      return '继续播放';
    }
    return n > 1 ? `播放 · ${n} 个版本` : '播放';
  }

  private fileName(path: string): string {
    const index: number = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }
}
