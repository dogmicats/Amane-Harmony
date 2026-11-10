import { router, uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import {
  CommentItem, DetailParams, ItemDetail, LibraryInfo, MediaFile, PlayerParams, StreamItem, StreamList
} from '../common/Types';
import { clock, runtimeText, scoreText, sizeText, dateText } from '../common/Util';
import { safeDetail, safeStreams } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { ActorChips } from '../ext/actors/ActorChips';
import { FacetTagChips, SeriesCard } from '../ext/facets/ItemFacetBlocks';
import { ItemFacets, emptyItemFacets, safeItemFacets } from '../ext/facets/FacetTypes';
import { HighlightStrip } from '../ext/highlights/HighlightStrip';
import { MarkBadges } from '../view/MarkBadges';
import { StillsWall } from '../view/StillsWall';

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
    still_ratios: [], comments: []
  };
  return d;
}

@Entry
@Component
struct DetailPage {
  @State detail: ItemDetail = emptyDetail();
  @State facets: ItemFacets = emptyItemFacets();
  @State streams: StreamItem[] = [];
  @State showVersions: boolean = false;
  @State versionsLoading: boolean = false;
  @State loading: boolean = true;
  @State fav: boolean = false;
  // 盲盒转场：从中心的小图放大铺满，等详情就绪后再从中心扩散淡出
  @State heroOn: boolean = false;
  @State heroUrl: string = '';
  @State heroScale: number = 0.3;
  @State heroFade: number = 1;
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
    const params = router.getParams() as DetailParams;
    if (params !== undefined && params !== null && params.id !== undefined && params.id !== null) {
      this.metaId = Number(params.id);
    }
    if (params !== undefined && params !== null && params.heroUrl !== undefined
      && params.heroUrl !== null && params.heroUrl.length > 0) {
      this.startHero(params.heroUrl);
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
  private withFiles(files: MediaFile[]): ItemDetail {
    const d: ItemDetail = {
      id: this.detail.id, number: this.detail.number, title: this.detail.title,
      plot: this.detail.plot, actors: this.detail.actors, tags: this.detail.tags,
      studio: this.detail.studio, series: this.detail.series,
      release: this.detail.release, runtime: this.detail.runtime,
      content_type: this.detail.content_type, score: this.detail.score,
      poster: this.detail.poster, fanart: this.detail.fanart,
      favorite: this.detail.favorite, position: this.detail.position,
      duration: this.detail.duration, finished: this.detail.finished,
      files: files, marks: this.detail.marks, stills: this.detail.stills,
      still_ratios: this.detail.still_ratios, comments: this.detail.comments
    };
    return d;
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

  /** 评价正文是 markdown，列表里只做轻量清理（去掉 ** > 与链接语法）。 */
  private plainComment(body: string): string {
    let s: string = body.replace(/\*\*/g, '').replace(/^>\s?/gm, '');
    s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
    s = s.replace(/magnet:\?xt=[^\s]+/g, '[磁力]');
    return s.trim();
  }

  private shownComments(): CommentItem[] {
    if (this.commentsOpen) {
      return this.detail.comments;
    }
    return this.detail.comments.slice(0, 2);
  }

  private async load(): Promise<void> {
    // 从剧照盲盒进来时已预取，先渲染出来，避免闪一次加载圈
    const cached: ItemDetail | undefined = Store.I.takeDetail(this.metaId);
    if (cached !== undefined) {
      this.detail = cached;
      this.fav = cached.favorite;
      this.loading = false;
    }
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/item/${this.metaId}`, Store.I.token);
      const detail: ItemDetail = safeDetail(JSON.parse(text) as ItemDetail);
      this.detail = detail;
      this.fav = detail.favorite;
      if (detail.favorite) {
        Store.I.favIds.add(detail.id);
      } else {
        Store.I.favIds.delete(detail.id);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] detail: ${e.code} ${e.message}`);
      this.toast = '加载失败';
    }
    this.loading = false;
    this.heroLoaded = true;
    this.tryReveal();
    // 分类归属（系列 / 标签 id）单独一次请求，失败不影响详情主体
    if (BuildConfig.ENABLE_FACETS) {
      this.loadFacets();
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
      urls: this.detail.stills,
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
    this.playFile('', '');
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
    const params: PlayerParams = {
      id: this.detail.id,
      number: this.detail.number,
      title: this.detail.title,
      position: start,
      fileKey: fileKey,
      fileName: fileName
    };
    this.startAt = -1;
    this.showVersions = false;
    router.pushUrl({ url: 'pages/PlayerPage', params: params });
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
            // 顶部大图
            Stack({ alignContent: Alignment.BottomStart }) {
              Image(Store.I.img(this.detail.fanart.length > 0 ? this.detail.fanart : this.detail.poster))
                .width('100%')
                .height(340)
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD)
              Column()
                .width('100%')
                .height(340)
                .linearGradient({
                  angle: 180,
                  colors: [['#00000000', 0.4], ['#800B0B0F', 0.85], ['#0B0B0F', 1.0]]
                })
            }
            .width('100%')
            .height(340)

            Column() {
              Row({ space: 14 }) {
                Image(Store.I.img(this.detail.poster))
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
              .margin({ top: -66 })

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
                  this.toggleFav();
                })

              }
              .width('100%')
              .margin({ top: 16 })

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
                  directors: this.facets.directors
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
              if (this.detail.stills.length > 0) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    Text('剧照')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(`${this.detail.stills.length}`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                    Text('点开看大图 ›')
                      .fontSize(10)
                      .fontColor(Theme.ACCENT)
                  }
                  .width('100%')
                  StillsWall({
                    urls: this.detail.stills,
                    ratios: this.detail.still_ratios,
                    onPick: (index: number) => {
                      this.openStills(index);
                    }
                  })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 评价
              if (this.detail.comments.length > 0) {
                Column({ space: 8 }) {
                  Row({ space: 6 }) {
                    Text('评价')
                      .fontSize(12)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(`${this.detail.comments.length} 条`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
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
                      Text(this.plainComment(c.body))
                        .fontSize(12)
                        .fontColor(Theme.TEXT_DIM)
                        .lineHeight(19)
                        .maxLines(this.commentsOpen ? 20 : 6)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(c.created_at.length >= 10 ? c.created_at.substring(0, 10) : c.created_at)
                        .fontSize(9)
                        .fontColor(Theme.TEXT_FAINT)
                        .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width('100%')
                    .padding(10)
                    .backgroundColor(Theme.CARD)
                    .borderRadius(10)
                    .border({ width: 0.5, color: '#14FFFFFF' })
                  }, (c: CommentItem) => `cm-${c.id}`)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
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

        // 返回按钮
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

        if (this.showVersions) {
          this.VersionSheet()
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
