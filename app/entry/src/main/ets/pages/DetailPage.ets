import { router, uiMaterial, promptAction } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { cachedBody, dropPageCache, httpDelete, httpGet, httpPost, httpPut, httpWarmStream } from '../common/Http';
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
import { CastSheet } from '../ext/cast/CastSheet';
import { Downloader, OfflineTask, NEED_WIFI } from '../common/Downloader';
import { Reason, ReasonLine } from '../common/Reason';
import { inPartGroup, partGroupKeys, partNoOf, partsHint } from '../common/Parts';
import { RatingStars, rateColor, rateLabel } from '../ext/ratings/RatingStars';
import { StillsWall } from '../view/StillsWall';
import { PosterCard } from '../view/PosterCard';
import { SubtitleBlock } from '../view/SubtitleBlock';
import { PlayHandoff, PlaySession } from '../common/PlaySession';
import { FloatBox } from '../common/FloatBox';
import { GlowOrb, ParticleField, markScroll } from '../view/Fx';
import { SkeletonBlock } from '../view/Skeleton';
import { SectionHead } from '../view/SectionHead';
import { ArtColor } from '../common/ArtColor';
import { Haptics } from '../common/Haptics';

import { CommentSheet, commentPreview } from '../view/CommentSheet';
import { PlayerView } from '../view/PlayerView';

/** `/api/user/stream-choice` 的回包（2.6.1.14）。 */
interface StreamChoiceResult {
  item_id: number;
  file_key: string;
  updated_at: string;
}

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

/**
 * 详情页预热节流（2.6.1.84）：`metaId → 上次预热时刻`。
 * 模块级，页面来回进出不会重置；同一部片 10 分钟内只热一次。
 */
const WARM_AT: Map<number, number> = new Map();

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
  /** 今日推荐理由：只有这部片当天上了每日推荐位才非空（任意入口进来都生效）。 */
  @State todayReason: ReasonLine | undefined = undefined;
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
  /** 沉浸光效强度（0 关 / 1 轻 / 2 强），见 `view/Fx.ets`。 */
  @StorageProp('amaneFx') fx: number = 2;
  /** 「从横屏转回竖屏」时高亮评分区（第 3 条：不弹窗）。 */
  @State rateHint: boolean = false;
  @State facets: ItemFacets = emptyItemFacets();
  /** 本片已选字幕（SubtitleBlock 双向绑定；服务端另有一份 choice，播放器据此自动套用）。 */
  @State subChosenId: string = '';
  @State streams: StreamItem[] = [];
  @State showVersions: boolean = false;
  /**
   * 上次选的可播版本（服务端记的 file_key，2.6.1.14）。
   * 多版本片子再点播放就用它，不再每次都弹「选择版本」让人重挑一遍。
   */
  @State defaultKey: string = '';
  @State versionsLoading: boolean = false;
  @State loading: boolean = true;
  @State fav: boolean = false;
  /** 2.5.5：服务端支持本地覆盖层（`/meta_override` 不 404）才显示「编辑 / 换封面」。 */
  @State metaOk: boolean = false;
  @State coverBusy: boolean = false;
  // 公开扩展 ratings / collections
  @State myRating: number = 0;
  @State collectionIds: number[] = [];
  /** 公开扩展 watch_later：是否已加入稍后再看。 */
  @State watchLater: boolean = false;
  @State showCollections: boolean = false;
  /** 投屏面板（2.5.6）：把这一部 + 这个版本变成只读地址交给电视。 */
  @State showCast: boolean = false;
  @State castKey: string = '';
  @State castSource: string = '';
  /** 投屏入口是否显示（默认关，见 aboutToAppear）。 */
  @State castOn: boolean = false;
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
  /** 一片一色（2.6.1.18）：这张海报的主色 / 第二色。空串 = 没取到，各处退回主题色。 */
  @State tint: string = '';
  @State tint2: string = '';
  private tintTried: boolean = false;
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
  /** 离线缓存记录快照：下载/排队/完成时刷新按钮文字（2.5.7）。 */
  @State dlTasks: OfflineTask[] = [];
  private stopDl: () => void = () => {};
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
    // 播放器点「画中画」时由它发起交接，落地在这里（停内嵌 + 开浮窗）
    PlaySession.handoff = () => {
      this.handoffToFloat();
    };
    // 浮窗点「回详情页」时由它回调这里（2.6.1.59 真机修）：
    // 这时候本页**往往还在栈里**（浮窗只是盖在它上面），`router.back` 等于原地不动，
    // 所以不能再靠路由回来 —— 由页面直接把画面接回去。
    PlaySession.opener = (h: PlayHandoff) => {
      this.takeOverFromFloat(h);
    };
    // 离线缓存要先拿到沙箱路径才能建目录；只在离线页初始化会出现「从没进过离线页就下不了」（2.5.7 修）
    try {
      Downloader.init(getContext(this) as common.UIAbilityContext);
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] detail offline init: ${e.code} ${e.message}`);
    }
    this.dlTasks = Downloader.list();
    this.stopDl = Downloader.watch(() => {
      this.dlTasks = Downloader.list();
    });
    // 投屏默认隐藏（这套要真机 + 同网才能验）；偏好 enable_cast=1 才显示入口
    this.castOn = Store.I.prefString('enable_cast', '0') === '1';
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
    // 2.6.1.84：顺手把播放首块热起来 —— 用户从详情页点「播放」时就不用再等网盘回源
    this.warmStream();
  }

  /**
   * 预热播放首块（2.6.1.84）。
   *
   * 实测：网盘片第一次播放，服务端取首块要 1.8~4.9 秒（CD2 冷区），客户端只能干等；
   * 而缓存命中后是 0.02 秒。详情页本来就是「用户要停一下才点播放」的地方 ——
   * 在这里发一个 1 字节请求把服务端的块任务拉起来，等于把那几秒提前花掉。
   *
   * 节流：同一部片 10 分钟只预热一次（Map 在模块级，页面来回进出不重复触发）。
   */
  private warmStream(): void {
    if (this.metaId <= 0 || !Store.I.ready) {
      return;
    }
    const now: number = Date.now();
    const at: number | undefined = WARM_AT.get(this.metaId);
    if (at !== undefined && now - at < 600000) {
      return;
    }
    WARM_AT.set(this.metaId, now);
    const url: string = `${Store.I.user}/api/user/play/${Store.I.playbackSource}/${this.metaId}` +
      `?token=${encodeURIComponent(Store.I.token)}`;
    // 先让详情本身的数据请求跑完，再抢带宽
    setTimeout(() => {
      httpWarmStream(url).catch(() => {
        // 预热失败不影响任何东西
      });
    }, 700);
  }

  aboutToDisappear(): void {
    this.stopDl();
    // 页面没了就别再留回调：浮窗那边会退化成 router（新开一页详情）
    if (PlaySession.opener !== undefined) {
      PlaySession.opener = undefined;
    }
  }

  /**
   * 浮窗「回详情页」：把画面接回页内播放器（2.6.1.59 真机修）。
   *
   * 之前这条路走的是 `router.back({url:'pages/DetailPage'})`，但浮窗只是**盖在**
   * 详情页上的 Overlay，本页从没离开栈 —— back 等于原地不动，于是画面留在浮窗里、
   * 页内播放器停在 `playerOn=false`，表现就是「详情页停着、小窗还在放」。
   */
  private takeOverFromFloat(h: PlayHandoff): void {
    if (h.mid > 0 && h.mid !== this.metaId) {
      // 浮窗里放的是**另一部片**：不在本页接手，新开一页详情，让那边的 onPageShow 收尾
      try {
        router.pushUrl({
          url: 'pages/DetailPage',
          params: { 'id': h.mid, 'fileKey': h.fileKey, 'position': h.pos } as Record<string, Object>
        });
      } catch (err) {
        console.error(`[amane] float push other: ${JSON.stringify(err)}`);
      }
      return;
    }
    if (FloatBox.isOpen) {
      FloatBox.close(this.getUIContext());
    }
    // 用页面自己的起播链路（亮点条也是它）：`startAt` 只消费一次，
    // 直接设 pPos + playerOn 会让播放器挂在「反复 seek 到 0」的死循环里（真机 22:42 抓到）。
    this.pKey = h.fileKey;
    this.pName = h.fileName;
    this.playAt(h.pos, h.fileKey, h.fileName);
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

  /** 可播版本（streams）里的分段组键，口径与文件列表一致。 */
  private streamPartKeys(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.streams.length; i++) {
      names.push(this.streams[i].name);
    }
    return partGroupKeys(names);
  }

  private versionStreams(): StreamItem[] {
    const keys: string[] = this.streamPartKeys();
    const out: StreamItem[] = [];
    for (let i = 0; i < this.streams.length; i++) {
      if (!inPartGroup(this.streams[i].name, keys)) {
        out.push(this.streams[i]);
      }
    }
    return out;
  }

  private partStreams(): StreamItem[] {
    const keys: string[] = this.streamPartKeys();
    const out: StreamItem[] = [];
    for (let i = 0; i < this.streams.length; i++) {
      if (inPartGroup(this.streams[i].name, keys)) {
        out.push(this.streams[i]);
      }
    }
    out.sort((a: StreamItem, b: StreamItem) => partNoOf(a.name) - partNoOf(b.name));
    return out;
  }

  /** 分段组键（见 `common/Parts.ets`）：同目录同前缀、至少两段才算一组分段。 */
  private filePartKeys(): string[] {
    const paths: string[] = [];
    for (let i = 0; i < this.detail.files.length; i++) {
      paths.push(this.detail.files[i].path);
    }
    return partGroupKeys(paths);
  }

  /**
   * 文件区拆两块（2026-11-13 用户反馈：多版本与分集堆在一起）。
   *
   * **版本** = 同一部的不同画质 / 来源（4K、破解、有码）；
   * **分集** = 同一部被切开的 cd1/cd2/cd3（碟片容量所限），它们不是版本。
   */
  private versionFiles(): MediaFile[] {
    const keys: string[] = this.filePartKeys();
    const out: MediaFile[] = [];
    for (let i = 0; i < this.detail.files.length; i++) {
      if (!inPartGroup(this.detail.files[i].path, keys)) {
        out.push(this.detail.files[i]);
      }
    }
    return out;
  }

  private partFiles(): MediaFile[] {
    const keys: string[] = this.filePartKeys();
    const out: MediaFile[] = [];
    for (let i = 0; i < this.detail.files.length; i++) {
      if (inPartGroup(this.detail.files[i].path, keys)) {
        out.push(this.detail.files[i]);
      }
    }
    // 按段号排：cd1 必须在 cd2 前面（入库顺序不保证）
    out.sort((a: MediaFile, b: MediaFile) => partNoOf(a.path) - partNoOf(b.path));
    return out;
  }

  /** 文件区标题：分段不再算进「版本」里；全是分段时不写「版本（0）」。 */
  private filesTitle(): string {
    const v: number = this.versionFiles().length;
    const p: number = this.partFiles().length;
    if (p === 0) {
      return v > 1 ? `版本（${v}）· 点一行播这个文件` : `文件（${v}）`;
    }
    if (v === 0) {
      return `分集（${p} 段）· 点一行播这个文件`;
    }
    return `版本（${v}）· 分集 ${p} 段`;
  }

  /** 一行文件（含右滑删除扩展的包裹）：版本区与分集区共用。 */
  @Builder
  FileEntry(file: MediaFile) {
    // 没有删除扩展时点击落在这一层，行为与以前一致
    Column() {
      this.FileRow(file)
    }
    .width('100%')
    .onClick(() => {
      this.playFile(`f${file.id}`, this.fileName(file.path));
    })
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

  /**
   * 一片一色（2.6.1.18）：取当前这部片海报的主色。
   *
   * 只用竖版海报（比剧照小、下载快）；取不到就保持空串，所有调用点都走
   * `tintColor()` 兜底到 `Theme.ACCENT` —— 所以「没取到」和「没这功能」长得一模一样，
   * 老服务端 / 断网 / 黑白色海报都不会露出半截怪色。
   *
   * 先同步读缓存（上次算过的色），首帧就能上色；没有再异步算一次。
   * 不 await：取色慢不该拖住详情主体。
   */
  private loadTint(): void {
    if (this.tintTried) {
      return;
    }
    const raw: string = this.detail.poster.length > 0 ? this.detail.poster : this.detail.fanart;
    if (raw.length === 0) {
      // 2.6.1.28 修：原来这里先把 tintTried 置 true 再判空 —— 详情数据还没到时
      // 这一次机会就被白白用掉了，之后永远不再取色（表现就是「每部片都是主题色」）。
      return;
    }
    this.tintTried = true;
    const url: string = Store.I.img(raw);
    const cached: string = ArtColor.cached(url);
    if (cached.length > 0) {
      this.applyTint(cached);
      return;
    }
    ArtColor.of(url, Store.I.token).then((accent: string) => {
      if (accent.length > 0) {
        this.applyTint(accent);
      } else {
        // 取不到就留空（退回主题色），但留一条 error 日志：真机上排查靠它
        console.error(`[amane] detail tint empty: ${url}`);
      }
    }).catch((err: BusinessError) => {
      console.error(`[amane] detail tint: ${err.code} ${err.message}`);
    });
  }

  private applyTint(accent: string): void {
    this.tint = accent;
    this.tint2 = ArtColor.second(accent);
  }

  /** 当前页的环境色：取不到就用主题强调色，调用处不必写三元。 */
  private tintColor(): string {
    return this.tint.length > 0 ? this.tint : Theme.ACCENT;
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
   * 把当前播放交接给应用内浮窗（点「画中画」按钮 / 离开页面都走这里）。
   *
   * 交接顺序很关键：先开浮窗（那边起播要几百毫秒），再停内嵌 ——
   * 反过来的话中间会有一段完全没声音的真空。
   * 浮窗没挂上（极少见）就保持内嵌继续播，绝不把用户搞成「没画面也没声」。
   * `compact = false`：浮窗默认还是小窗，但允许双击切成宽条。
   *
   * 返回是否真的交接成功。
   */
  private handoffToFloat(): boolean {
    if (FloatBox.isOpen) {
      // 已经在浮窗里了（比如刚点过画中画）：只需把页内的停掉
      if (this.playerOn) {
        this.playerOn = false;
      }
      return true;
    }
    const s: PlayHandoff = PlaySession.snapshot();
    if (s.mid <= 0) {
      return false;
    }
    const ok: boolean = FloatBox.open(this.getUIContext(), s, false);
    if (ok) {
      this.playerOn = false;
    }
    return ok;
  }

  /**
   * 离开这一页：**不自动弹小窗**（2026-11-13 21:12 用户口径）。
   *
   * 「自动小窗」只留一个入口 —— 用户按 Home 回桌面时由系统画中画接管
   * （`PlayerView` 里 `setAutoStartEnabled`）。只是退出详情页、翻回列表时不该
   * 凭空多出一个浮窗；想要浮窗就点播放器上的「画中画」按钮，那是明确意图。
   *
   * 这里以前会自动 `handoffToFloat()`，所以「返回列表」也会留下一个小窗。
   * 现在什么都不做：页面销毁时页内播放器自己停，声音跟着停，不留浮层。
   */
  onPageHide(): void {
    // 故意留空：见上方注释。
  }

  /**
   * 从播放页返回（Emby 模式）：不弹窗，只把「我的评分」那块点亮一下
   * （用户上一轮第 3 条：提示改成高亮，别用弹窗打断）。
   */
  onPageShow(): void {
    setPageFullScreen(getContext(this), false);
    // 带着浮窗回到这一页：把画面接回页面内，别让小窗和页面同时出声
    if (FloatBox.isOpen) {
      const s: PlayHandoff | undefined = PlaySession.active;
      FloatBox.close(this.getUIContext());
      if (s !== undefined && s.mid === this.metaId) {
        this.pKey = s.fileKey;
        this.pName = s.fileName;
        this.pPos = s.pos;
        this.playerOn = true;
      }
    }
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
    // 今日推荐理由：按 id 从当天快照里取，所以从收藏 / 搜索 / 演员页进来也能看到。
    // 跨天、开关关掉、没上推荐位都会得到 undefined，整张卡不渲染。
    this.todayReason = Reason.forId(this.metaId);
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
      this.loadStreamChoice();
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
    // 一片一色：详情主体已经能显示，取色在后台跑（取到才变色，取不到就是主题色）
    this.loadTint();
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
    // 2.5.5：探一次本地覆盖层在不在（老服务端 404 → 隐藏编辑/换封面）
    this.probeMeta();
  }

  /**
   * 覆盖层是否可用。不 await、失败当不可用 —— 这个能力是锦上添花，
   * 不能因为探测慢或失败把详情主体卡住。
   */
  private async probeMeta(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      await httpGet(`${Store.I.user}/api/user/meta_override/${this.metaId}`, Store.I.token);
      this.metaOk = true;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] meta_override probe: ${e.code}`);
      this.metaOk = false;
    }
  }

  private openMetaEdit(): void {
    const p: DetailParams = { id: this.metaId };
    router.pushUrl({ url: 'pages/MetaEditPage', params: p });
  }

  /**
   * 封面菜单。只换不还原是上一版漏的：换错了就只能「恢复默认」把字段一起清掉。
   * 这里把「恢复原封面」单独一条，只管封面，不碰标题/演员/标签。
   */
  private coverMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '从相册选一张',
      action: () => {
        this.pickCover();
      }
    });
    // 用剧照拼一段循环动图当封面（服务端合成，约 10 秒）
    items.push({
      value: '用剧照做动图封面',
      action: () => {
        this.makeGifCover();
      }
    });
    if (this.detail.poster_is_custom === true) {
      items.push({
        value: '恢复原封面',
        action: () => {
          this.restoreCover();
        }
      });
    }
    return items;
  }

  /**
   * 用这部片的剧照拼一段循环动图当封面。
   *
   * 合成在服务端做（Pillow），客户端只等结果 —— 6 张图大约 10 秒，
   * 所以这里把超时放宽到 90 秒，并先给一句「正在拼」的提示，
   * 否则用户会以为按钮没反应。
   */
  private async makeGifCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    promptAction.showToast({ message: '正在用剧照拼动图，约 10 秒…', duration: 4000 });
    try {
      const body: Record<string, Object> = { 'count': 6, 'duration': 700 };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/cover/${this.metaId}/gif`, Store.I.token,
        JSON.stringify(body), 90000);
      const res = JSON.parse(raw) as Record<string, Object>;
      if (res.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '动图封面好了', duration: 1500 });
        this.load(true);
      } else {
        const why: string = res.reason === undefined || res.reason === null ? '' : `${res.reason}`;
        promptAction.showToast({ message: why.length > 0 ? why : '没做成，稍后再试', duration: 2200 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cover gif: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没做成（服务端可能不支持，或剧照太少）', duration: 2200 });
    } finally {
      this.coverBusy = false;
    }
  }

  /** 只清封面覆盖（`DELETE /cover/{mid}`），字段改动保留。 */
  private async restoreCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    try {
      await httpDelete(`${Store.I.user}/api/user/cover/${this.metaId}`, Store.I.token);
      // 首页 / 列表页的 GET 缓存也要一并丢掉，否则返回后还是旧封面
      dropPageCache();
      Store.I.coverDirty = true;
      promptAction.showToast({ message: '已恢复原封面', duration: 1500 });
      this.load(true);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cover del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没恢复成，稍后再试', duration: 1600 });
    } finally {
      this.coverBusy = false;
    }
  }

  /**
   * 换封面：系统相册 Picker（不需要权限，GIF 也能选）→ base64 → `POST /cover/{mid}`。
   * 服务端用现成的 `save_photo()` 落盘并按 hash 起名，所以这里**不传文件名**。
   */
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
      const ext: string = this.extOf(uri);
      const body: Record<string, Object> = { 'data': b64, 'ext': ext };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/cover/${this.metaId}`, Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        promptAction.showToast({ message: '封面换好了', duration: 1500 });
        // 详情页自己重拉；首页/列表页靠这份 GET 缓存，必须一起清掉（2.5.5.4）
        dropPageCache();
        Store.I.coverDirty = true;
        this.load(true);
      } else {
        promptAction.showToast({ message: '没换成功，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cover: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没换成功（选图或上传失败）', duration: 1800 });
    } finally {
      this.coverBusy = false;
    }
  }

  /** picker 给的 uri 后缀就是真实格式（服务端只认 jpg/png/webp/gif）。 */
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
    // 2.6.1.34：播完的片也要能续播 —— 用户 19:24「应该记住每一次退出播放的位置，
    // 不管他是否已经播放完毕」。位置一直在记，原来被 `!finished` 挡掉了。
    return this.detail.position > 5;
  }

  private play(fromStart: boolean): void {
    // 从头播 = 位置 0；否则让 playFile 按进度自己决定
    this.startAt = fromStart ? 0 : -1;
    // 一个条目挂多个版本时：记过默认版本就直接播它（2.6.1.14），
    // 没记过才让用户挑；想换版本走下面「N 个版本」那个入口。
    if (this.detail.files.length > 1) {
      if (this.defaultKey.length > 0 && this.hasFile(this.defaultKey)) {
        this.playFile(this.defaultKey, this.fileNameOf(this.defaultKey));
        return;
      }
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

  /** 这个 file_key 还在这部片的文件列表里吗（记过的那一版可能已被删/换库）。 */
  private hasFile(key: string): boolean {
    if (key.length < 2) {
      return false;
    }
    for (let i = 0; i < this.detail.files.length; i++) {
      if (`f${this.detail.files[i].id}` === key) {
        return true;
      }
    }
    return false;
  }

  /** file_key → 文件名（播放页标题要显示，取路径最后一段）。 */
  private fileNameOf(key: string): string {
    for (let i = 0; i < this.detail.files.length; i++) {
      const f: MediaFile = this.detail.files[i];
      if (`f${f.id}` === key) {
        const slash: number = f.path.lastIndexOf('/');
        return slash >= 0 ? f.path.substring(slash + 1) : f.path;
      }
    }
    return '';
  }

  /**
   * 读回「这部片上次播的是哪个文件」（2.6.1.14）。
   *
   * 只在文件列表里还有这一版时才采用 —— 用户可能换过库或删过文件，
   * 这时要回到「让他挑」而不是播一个不存在的文件。
   */
  private async loadStreamChoice(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/stream-choice?item_id=${this.metaId}`, Store.I.token);
      const data = JSON.parse(text) as StreamChoiceResult;
      const key: string = data.file_key === undefined || data.file_key === null ? '' : data.file_key;
      this.defaultKey = this.hasFile(key) ? key : '';
    } catch (err) {
      const e = err as BusinessError;
      // 老服务端没有这个端点：静默，按老逻辑弹选择
      console.info(`[amane] stream choice: ${e.code}`);
    }
  }

  /** 记下这次选的版本，下次直接用它。 */
  private async rememberStream(key: string): Promise<void> {
    if (key.length === 0) {
      return;
    }
    this.defaultKey = key;
    try {
      await httpPut(`${Store.I.user}/api/user/stream-choice`, Store.I.token,
        JSON.stringify({ item_id: this.metaId, file_key: key }));
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] remember stream: ${e.code}`);
    }
  }

  private openCast(): void {
    this.castSource = Store.I.playbackSource;
    this.castKey = this.streams.length > 0 ? this.streams[0].key : '';
    this.showCast = true;
  }

  /** 从本地快照里找这一版的缓存记录（读 @State 数组，下载状态一变按钮就跟着变）。 */
  private taskOf(key: string): OfflineTask | undefined {
    for (let i = 0; i < this.dlTasks.length; i++) {
      const t = this.dlTasks[i];
      if (t.mid === this.metaId && t.key === key) {
        return t;
      }
    }
    return undefined;
  }

  /** 版本行右侧那个按钮的字：已下完 ✓ / 在跑或排队 · / 没下 ↓。 */
  private offlineMark(s: StreamItem): string {
    const t = this.taskOf(s.key);
    if (t === undefined) {
      return '↓';
    }
    if (t.status === 'done') {
      return '✓';
    }
    if (t.status === 'run' || t.status === 'pause' || t.status === 'waiting') {
      return '·';
    }
    return '↓';
  }

  /** 主按钮行那个下载键的字：↓ 未下 / · 在跑或排队 / ✓ 已缓存（看第一个版本）。 */
  private downloadMark(): string {
    if (this.streams.length === 0) {
      return '↓';
    }
    const t = this.taskOf(this.streams[0].key);
    if (t === undefined) {
      return '↓';
    }
    if (t.status === 'done') {
      return '✓';
    }
    return t.status === 'run' || t.status === 'pause' || t.status === 'waiting' ? '·' : '↓';
  }

  private downloadDone(): boolean {
    if (this.streams.length === 0) {
      return false;
    }
    const t = this.taskOf(this.streams[0].key);
    return t !== undefined && t.status === 'done';
  }

  /**
   * 下载这部片：只有一个版本就直接下，多版本打开面板让用户挑。
   *
   * 这条路径是为「单文件」准备的 —— 那种片没有版本面板，否则就完全没有下载入口。
   */
  private async downloadAny(): Promise<void> {
    // 没开过版本面板时 streams 是空的：先拉一次，否则这一行永远是「没有可下载的版本」
    if (this.streams.length === 0) {
      await this.loadStreams();
    }
    if (this.streams.length === 0) {
      this.flash('没有可下载的版本');
      return;
    }
    if (this.streams.length === 1) {
      this.downloadStream(this.streams[0]);
      return;
    }
    this.openVersions();
  }

  /** 移动网络下点下载：先说清楚，再让用户决定（2.5.7）。 */
  private askCellular(s: StreamItem): void {
    AlertDialog.show({
      title: '当前是移动网络',
      message: '「只在 WiFi 下下载」是开着的。要用流量下这一部吗？' +
        '（已经在下或已排队的不会被这个开关打断）',
      primaryButton: {
        value: '等 WiFi',
        action: () => {
          this.toast = '已跳过，连上 WiFi 再点下载';
          setTimeout(() => {
            this.toast = '';
          }, 2000);
        }
      },
      secondaryButton: {
        value: '用流量继续',
        action: () => {
          this.downloadNow(s);
        }
      }
    });
  }

  private flash(msg: string): void {
    this.toast = msg;
    setTimeout(() => {
      this.toast = '';
    }, 2000);
  }

  /** 入队（默认路径）：走「仅 WiFi」与队列规则。 */
  private async downloadStream(s: StreamItem): Promise<void> {
    const cur = this.taskOf(s.key);
    if (cur !== undefined && cur.status === 'done') {
      this.flash('这一版已经下好了，断网也能看');
      return;
    }
    if (cur !== undefined && (cur.status === 'run' || cur.status === 'waiting')) {
      this.flash('这一版已经在下或排队了');
      return;
    }
    try {
      Downloader.init(getContext(this) as common.UIAbilityContext);
    } catch (err) {
      console.info('[amane] offline init on download');
    }
    const err: string = await Downloader.enqueue(
      this.metaId, s.key, Store.I.playbackSource, this.detail.number, s.name);
    this.afterEnqueue(err, s, false);
  }

  /** 用户明确选「用流量继续」时走这条：跳过 WiFi 判断。 */
  private async downloadNow(s: StreamItem): Promise<void> {
    const err: string = await Downloader.enqueue(
      this.metaId, s.key, Store.I.playbackSource, this.detail.number, s.name, true);
    this.afterEnqueue(err, s, true);
  }

  private afterEnqueue(err: string, s: StreamItem, forced: boolean): void {
    if (err === NEED_WIFI) {
      this.askCellular(s);
      return;
    }
    if (err === 'done') {
      this.flash('这一版已经下好了，断网也能看');
      return;
    }
    if (err === 'queued') {
      this.flash('这一版已经在下或排队了');
      return;
    }
    if (err.length > 0) {
      this.flash(err);
      return;
    }
    const pos: number = Downloader.waitingPos(this.metaId, s.key);
    if (pos > 0) {
      this.flash(forced
        ? `已加入队列（用流量），前面还有 ${pos - 1} 个`
        : `已加入队列，前面还有 ${pos - 1} 个`);
    } else {
      this.flash('开始下载，进度在「设置 → 离线缓存」里看');
    }
  }

  /** 把这一部的所有版本一次排进队列（最多 20 部，防止误点）。 */
  private async downloadAllVersions(): Promise<void> {
    if (this.streams.length === 0) {
      this.flash('没有可下载的版本');
      return;
    }
    let ok: number = 0;
    let needWifi: number = 0;
    let other: string = '';
    for (let i = 0; i < this.streams.length && i < 20; i++) {
      const err: string = await Downloader.enqueue(
        this.metaId, this.streams[i].key, Store.I.playbackSource,
        this.detail.number, this.streams[i].name);
      if (err.length === 0) {
        ok++;
      } else if (err === NEED_WIFI) {
        needWifi++;
      } else if (err !== 'queued' && err !== 'done') {
        other = err;
      }
    }
    this.showVersions = false;
    if (needWifi > 0) {
      this.flash('移动网络下没排队，连上 WiFi 再点');
      return;
    }
    if (other.length > 0) {
      this.flash(other);
      return;
    }
    this.flash(ok > 0 ? `已把 ${ok} 个版本排进队列` : '这些版本都已经下过或在队列里了');
  }

  private playFile(fileKey: string, fileName: string): void {
    // 2.6.1.34：播完的片不再强制从头 —— 退出在哪就从哪起（哪怕在末尾），
    // 想重看走「从头」那个按钮。
    const start: number = this.startAt >= 0 ? this.startAt : this.detail.position;
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

  /**
   * 只拉版本列表，不开面板。
   *
   * 2.5.7 修：`streams` 原来只在 `openVersions()` 里拉，主按钮行的「下载」在
   * 没开过面板时永远面对空数组 → 点下去只会说「没有可下载的版本」。
   * 现在下载键先调这个，拿到列表再决定「直接下 / 开面板挑」。
   */
  private async loadStreams(): Promise<void> {
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
      this.flash('版本列表加载失败');
    }
    this.versionsLoading = false;
  }

  /** 拉取该条目的全部可播版本（含分辨率/体积/时长/所在库）。 */
  private async openVersions(): Promise<void> {
    this.showVersions = true;
    await this.loadStreams();
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
      // 触感（2.6.1.18）：收藏成功一记轻震，和 toast 一起构成「确实收下了」的双重确认
      Haptics.tap();
      // 收藏是有明确结果的操作，给一下确认感（播放器里不加）
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
          // 上次选的那一版标出来，下次点播放就是它（2.6.1.14）
          if (s.key === this.defaultKey) {
            Text('默认')
              .fontSize(9)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.ACCENT)
              .borderRadius(4)
          }
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

      // 下载这一版到手机（离线缓存，2.5.6）
      // 两轮反馈「看不见」：先是纯图标、再是 8px 小字。这次直接做成胶囊写全「下载」。
      Row({ space: 4 }) {
        Text(this.offlineMark(s))
          .fontSize(12)
          .fontColor(this.offlineMark(s) === '✓' ? Theme.GOLD : Theme.TEXT)
        Text(this.offlineMark(s) === '✓' ? '已缓存' : '下载')
          .fontSize(10)
          .fontColor(this.offlineMark(s) === '✓' ? Theme.GOLD : Theme.TEXT_DIM)
      }
      .height(30)
      .padding({ left: 9, right: 9 })
      .borderRadius(Theme.R_PILL)
      .backgroundColor(Theme.CARD_HI)
      .border({
        width: 1,
        color: this.offlineMark(s) === '✓' ? Theme.GOLD : '#4DFFFFFF'
      })
      .onClick(() => {
        this.downloadStream(s);
      })

      Text('▶')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .borderRadius(Theme.R_PILL)
        .backgroundColor(Theme.ACCENT)
    }
    .width('100%')
    .padding(11)
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
    .onClick(() => {
      this.rememberStream(s.key);
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
          // 投屏：默认隐藏（没有真机能验）。偏好 `enable_cast=1` 才出现。
          if (this.castOn) {
            Text('投屏')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(9)
              .onClick(() => {
                this.showVersions = false;
                this.startAt = -1;
                this.openCast();
              })
          }
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
              // 版本：不同画质 / 来源
              ForEach(this.versionStreams(), (s: StreamItem) => {
                this.VersionRow(s)
              }, (s: StreamItem) => `ver-${s.key}`)

              // 分集：同一部被切开的 cd1/cd2 —— 与版本分开列，别混成「N 个版本」
              if (this.partStreams().length > 0) {
                Row() {
                  Text(`分集 · ${partsHint(this.partStreams().length)}`)
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .width('100%')
                .padding({ top: 6 })

                ForEach(this.partStreams(), (s: StreamItem) => {
                  this.VersionRow(s)
                }, (s: StreamItem) => `part-${s.key}`)
              }
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 340 })
          .width('100%')

          // 批量：多版本片子一次全排进队列（2.5.7）。单文件没有这条，主按钮那个就够了。
          if (this.streams.length > 1) {
            Text(`把 ${this.streams.length} 个版本都排进下载队列`)
              .fontSize(11)
              .fontColor(Theme.ACCENT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 10, bottom: 10 })
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .backgroundColor('#1FFFFFFF')
              .border({ width: 0.5, color: '#33FFFFFF' })
              .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
              .borderRadius(10)
              .onClick(() => {
                this.downloadAllVersions();
              })
          }
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
      .borderRadius(Theme.R_CARD)
      .border({ width: 1, color: Theme.STROKE })
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
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor('#1FFFFFFF')
      .border({ width: 0.5, color: '#33FFFFFF' })
      .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
      .borderRadius(11)
      .margin({ right: 6, bottom: 6 })
  }

  private reasonMain(): string {
    const l: ReasonLine | undefined = this.todayReason;
    return l === undefined ? '' : l.reason;
  }

  private reasonExtra(): string {
    const l: ReasonLine | undefined = this.todayReason;
    return l === undefined ? '' : l.extra;
  }

  /**
   * 今日推荐理由卡（2.5.7.21）：把首页抽屉里那句话复制到详情页。
   * 不常驻、不占卡片版面 —— 没上推荐位（或开关关掉）时整块不渲染。
   * 注意：@Builder 的传值参数不随 @State 刷新，所以这里直接读 getter，
   * 并在 if 里显式触碰 this.todayReason，保证状态变化能触发重绘。
   *
   * 2.6.1.18：从「标签/演员之后」提到**主按钮行正下方** —— 用户从每日推荐点进来，
   * 第一眼就该知道「为什么今天推这部」，而不是滑到一半才看见。
   * 同时把主句从金色改成正文色：金色留给「✦ 今日推荐理由」这个标签，
   * 一句话读起来才不刺眼（原来整句金 + 11px 补充句挤在一起，字全糊成一片）。
   */
  @Builder
  ReasonCard() {
    if (this.todayReason !== undefined && this.reasonMain().length > 0) {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Text('✦ 今日推荐理由')
            .fontSize(11)
            .fontColor(Theme.GOLD)
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('每日推荐')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')

        Text(this.reasonMain())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.GOLD)
          .width('100%')
          .lineHeight(23)
          .padding({ left: 9 })
          .border({
            width: { left: 2 },
            color: { left: Theme.GOLD }
          })

        if (this.reasonExtra().length > 0) {
          Text(this.reasonExtra())
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .lineHeight(17)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor(Theme.CARD)
      .borderRadius(12)
      .border({ width: 0.5, color: '#26FFFFFF' })
      .margin({ top: 12 })
    }
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
                // 封面右上角挂一个「换」：叠在图上，不额外占一行（2.5.5）
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(Store.I.img(this.coverUrl()))
                    .width(104)
                    .height(148)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(10)
                    .backgroundColor(Theme.CARD)
                    .shadow({ radius: 16, color: '#99000000', offsetY: 6 })

                  if (this.metaOk) {
                    Text(this.coverBusy ? '…' : (this.detail.poster_is_custom === true ? '已换' : '换'))
                      .fontSize(9)
                      .fontColor('#F2FFFFFF')
                      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                      .backgroundColor(this.detail.poster_is_custom === true ? '#B37C5CFF' : '#B3000000')
                      .borderRadius({ topRight: 10, bottomLeft: 8 })
                      // 点它只出菜单，不直接弹相册：菜单里才有「恢复原封面」（2.5.5.4）
                      .bindMenu(this.coverMenu())
                  }
                }
                .width(104)
                .height(148)

                Column({ space: 6 }) {
                  Text(this.detail.number)
                    .fontSize(12)
                    .fontColor(this.tintColor())
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
                  // 2.5.5：本地覆盖层可用才给编辑入口（老服务端 404 时整块不出现）
                  if (this.metaOk) {
                    Text('✎ 编辑信息')
                      .fontSize(10)
                      .fontColor(Theme.ACCENT)
                      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                      .backgroundColor(Theme.ACCENT_SOFT)
                      .borderRadius(9)
                      .onClick(() => {
                        this.openMetaEdit();
                      })
                  }
                  Row() {
                    Column({ space: 6 }) {
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

                    Blank()

                    // 字幕：跟评分/标记同一行的右侧空位，点开是底部抽屉
                    SubtitleBlock({ metaId: this.detail.id, chosenId: $subChosenId })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
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

                // 下载（离线缓存，2.5.6）：**单文件时没有「选择版本」面板**，
                // 这里是唯一的下载入口，所以按钮必须常驻，不能只挂在版本行上。
                Column({ space: 1 }) {
                  Text(this.downloadMark())
                    .fontSize(15)
                    .fontColor(this.downloadDone() ? Theme.GOLD : Theme.TEXT)
                  Text(this.downloadDone() ? '已缓存' : '下载')
                    .fontSize(9)
                    .fontColor(this.downloadDone() ? Theme.GOLD : Theme.TEXT_FAINT)
                }
                .width(58)
                .height(42)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Theme.CARD)
                .borderRadius(21)
                .onClick(() => {
                  this.downloadAny();
                })

                // 公开扩展 watch_later：稍后再看（2.6.1.22 从细横条升成主按钮）。
                // 它原来在按钮下面当一条 46vp 高的横条 —— 一屏里最容易被忽略的位置，
                // 而它恰恰是「现在不想看、但别忘」这种最常见的动作，所以和「归档」换位。
                if (BuildConfig.ENABLE_WATCHLATER) {
                  Column({ space: 1 }) {
                    Text(this.watchLater ? '◉' : '◷')
                      .fontSize(15)
                      .fontColor(this.watchLater ? Theme.ACCENT : Theme.TEXT)
                    Text(this.watchLater ? '已记录' : '稍后再看')
                      .fontSize(9)
                      .fontColor(this.watchLater ? Theme.ACCENT : Theme.TEXT_FAINT)
                  }
                  .width(58)
                  .height(42)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(this.watchLater ? Theme.ACCENT_SOFT : Theme.CARD)
                  .borderRadius(21)
                  .onClick(() => {
                    this.toggleWatchLater();
                  })
                }
              }
              .width('100%')
              .margin({ top: 16 })

              // 今日推荐理由：紧跟主按钮 —— 从推荐位进来的人第一眼就看到「为什么是它」
              this.ReasonCard()


              // 公开扩展 ratings：我的评分。和头部那个上游站点评分隔开，两套数据互不覆盖。
              if (BuildConfig.ENABLE_RATINGS) {
                Column({ space: 6 }) {
                  Row() {
                    SectionHead({ title: '我的评分' })
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

              // 公开扩展 actors：演员名变成可点 chip，直接进演员页；
              // 关掉 ENABLE_ACTORS 时退回原来的纯文本，核心不残留扩展行为。
              if (this.detail.actors.length > 0) {
                if (BuildConfig.ENABLE_ACTORS) {
                  ActorChips({ metaId: this.metaId, names: this.detail.actors })
                } else {
                  Column({ space: 6 }) {
                    SectionHead({ title: '出演' })
                    Text(this.detail.actors.join(' / '))
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ top: 14 })
                }
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

              // 本片字幕的入口已经挪到标题区右侧（评分/标记那一行），这里不再重复放。

              // 简介
              if (this.detail.plot.length > 0) {
                Column({ space: 6 }) {
                  SectionHead({ title: '简介' })
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

              // 剧照：两列瀑布流，横竖版各按原比例占位（不再一刀切成 16:9），点开进全屏查看器
              if (this.allStills().length > 0) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    SectionHead({ title: '剧照', count: `${this.allStills().length}` })
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

              // 评价（0 条时也显示标题行：要能从这里写第一条）
              Column({ space: 8 }) {
                  Row({ space: 6 }) {
                    SectionHead({ title: '评价', count: `${this.detail.comments.length} 条` })
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

              // 文件管理（2.6.1.22 从「简介之前」挪到评价下方）：
              // 选版本直接播的入口在顶部主按钮和播放键上已经有了，这一段主要是**管理**
              // （看清有几个版本/分集、右滑删掉失效资源），属于「看完再收拾」的动作，
              // 放在内容（简介/剧照/评价）之后更顺手，也不会把剧照墙顶到屏幕外。
              if (this.detail.files.length > 0) {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    SectionHead({ title: this.filesTitle() })
                    Blank()
                  }
                  .width('100%')

                  // 版本：不同画质 / 来源（4K、破解、有码）
                  ForEach(this.versionFiles(), (file: MediaFile) => {
                    this.FileEntry(file)
                  }, (file: MediaFile) => `ver-${file.id}`)

                  // 分集：同一部被切开的 cd1/cd2 —— 单独一段，不再混进「版本」数里
                  if (this.partFiles().length > 0) {
                    Row() {
                      Text(`分集 · ${partsHint(this.partFiles().length)}`)
                        .fontSize(11)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width('100%')
                    .padding({ top: 8 })

                    ForEach(this.partFiles(), (file: MediaFile) => {
                      this.FileEntry(file)
                    }, (file: MediaFile) => `part-${file.id}`)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 相似影片：同系列 / 同演员 / 共同标签，服务端打分排序（同厂牌只加分不单独入选）
              if (this.similar.length > 0) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    SectionHead({ title: '相似影片', count: `${this.similar.length}` })
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
        // 滚动时暂停浮尘（2.6.1.18 光效预算）：详情页这块 Canvas 盖在整张封面上，
        // 一边合成列表一边重绘最费电，停手 420ms 自动恢复。
        .onScroll((x: number, y: number) => {
          markScroll();
        })
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
          // 把海报主色薄薄地铺在底部：整张图会从「通用深色压边」变成「这部片自己的色调」
          // 2.6.1.28：0.16 → 0.34 —— 0.16 在暗色头图上几乎看不出来，等于没上色。
          colors: [['#00000000', 0.40], [Theme.alphaOf(this.tintColor(), 0.34), 0.74], ['#8C0B0B0F', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      // 播放按钮背后的一团柔光：像放映机打在幕布上的光斑，颜色跟着这张海报走。
      // 放在按钮之前，所以它永远不会盖住 ▶ 图标本身。
      if (this.fx >= 1) {
        GlowOrb({
          color: this.tintColor(),
          diameter: this.fx >= 2 ? 210 : 168,
          alpha: this.fx >= 2 ? 0.30 : 0.18,
          breath: true,
          period: 3000
        })
      }

      Column({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          // 亮剧照上「大团柔光」会被画面吃掉，所以真正的可读信号做成两层硬边：
          // 一圈强调色描边（任何底上都看得见）+ 按钮本体的外发光（暗画面上会散开）。
          if (this.fx >= 1) {
            Column()
              .width(this.fx >= 2 ? 74 : 64)
              .height(this.fx >= 2 ? 74 : 64)
              .borderRadius(this.fx >= 2 ? 37 : 32)
              .border({ width: 1, color: Theme.alphaOf(this.tintColor(), this.fx >= 2 ? 0.58 : 0.34) })
          }
          Column()
            .width(54)
            .height(54)
            .borderRadius(27)
            .backgroundColor('#73000000')
            // 2.6.1.28：描边 0.72 → 0.95、外发光 0.80 → 0.90，让「一片一色」真的看得见
            .border({ width: 1, color: this.fx >= 1 ? Theme.alphaOf(this.tintColor(), 0.95) : '#4DFFFFFF' })
            .shadow(this.fx >= 1
              ? { radius: this.fx >= 2 ? 30 : 20, color: Theme.alphaOf(this.tintColor(), this.fx >= 2 ? 0.90 : 0.55) }
              : { radius: 0, color: '#00000000' })
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

      // 封面上的浮尘：比首页大图更淡更少（这里下面压着按钮和片名，粒子一多就脏）
      if (this.fx >= 2) {
        ParticleField({ count: 12, color: '#FFFFFF', alpha: 0.22, drift: 0.8 })
      }
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
        // 骨架屏（2.6.1.18）：先把「一张大图 + 封面 + 标题两行 + 一排按钮」的位置占出来。
        // 数据到了只是把灰块换成实内容，整屏不会从转圈直接跳成满屏信息。
        Column() {
          SkeletonBlock({ w: '100%', h: 208, radius: 0 })
          Column({ space: 10 }) {
            Row({ space: 14 }) {
              SkeletonBlock({ w: '104', h: 148, radius: 10 })
              Column({ space: 9 }) {
                SkeletonBlock({ w: '28%', h: 12 })
                SkeletonBlock({ w: '92%', h: 16, lag: 70 })
                SkeletonBlock({ w: '68%', h: 12, lag: 120 })
                SkeletonBlock({ w: '44%', h: 11, lag: 170 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            Row({ space: 10 }) {
              SkeletonBlock({ w: '46%', h: 38, radius: 19, lag: 60 })
              SkeletonBlock({ w: '28%', h: 38, radius: 19, lag: 140 })
            }
            .width('100%')
            .margin({ top: 6 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
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
          // 五十八改：形状与基底的返回胶囊统一（34 见方 / 圆角 12 / 20 号字），
          // 材质仍用 ULTRA_THIN + 半透明黑（它浮在海报上，需要一点压暗才看得清）
          Text('‹')
            .fontSize(20)
            .fontColor('#FFFFFF')
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .borderRadius(12)
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

        if (this.showCast) {
          Column() {
            Column() {
              CastSheet({
                metaId: this.metaId,
                number: this.detail.number,
                title: this.detail.title,
                source: this.castSource,
                fileKey: this.castKey,
                onClose: () => {
                  this.showCast = false;
                }
              })
            }
            .width('100%')
            .backgroundColor(Theme.BG_RAISED)
            .borderRadius({ topLeft: 18, topRight: 18 })
            .margin({ top: 'auto' })
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .onClick(() => {
            this.showCast = false;
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
    if (this.resumable()) {
      return '继续播放';
    }
    // 2.6.1.16：分段不算版本 —— 只有 cd1/cd2 的片子别再写「2 个版本」
    const v: number = this.versionFiles().length;
    const p: number = this.partFiles().length;
    if (v === 0 && p > 0) {
      return `播放 · 分集 ${p} 段`;
    }
    if (v > 1) {
      return `播放 · ${v} 个版本`;
    }
    return '播放';
  }

  private fileName(path: string): string {
    const index: number = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }
}
