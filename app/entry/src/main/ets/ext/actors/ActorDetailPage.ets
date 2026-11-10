import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams, ItemDetail } from '../../common/Types';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import { StillsWall } from '../../view/StillsWall';
import { safeDetail } from '../../common/Safe';
import {
  ActorDetail, ActorMediaItem, ActorMediaList, ActorParams, ActorStill, ActorStillList,
  emptyActorDetail, safeActorDetail, safeActorMediaList, safeActorStills
} from './ActorTypes';

const WORK_PAGE: number = 18;
/** 一屏摆几张剧照（两列 × 5 行）。 */
const STILL_COUNT: number = 10;
/** 一次抓一批存本地：换一批先轮换这批，不用等网络（服务端上限 36）。 */
const STILL_POOL: number = 30;

interface FetchResult {
  ok: boolean;
  added: number;
  total: number;
  note: string;
  items: string[];
  source: string;
}

/** 全屏看写真（pages/ImageViewerPage）的入参。 */
interface ViewerParams {
  urls: string[];
  index: number;
  title: string;
}

/**
 * 公开扩展 actors：演员详情沉浸页。
 *
 * 用 List 而不是 Scroll 包 Grid：List 有 onReachEnd 可以自动续页，
 * 也避免 ArkUI 里嵌套滚动容器抢手势的问题。作品按「每 3 个一组」拆成
 * Row 渲染，宽度自适应不同屏幕，不需要给 Grid 硬算高度。
 */
@Entry
@Component
struct ActorDetailPage {
  @State data: ActorDetail = emptyActorDetail();
  @State works: ActorMediaItem[] = [];
  @State rows: ActorMediaItem[][] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State expanded: boolean = false;
  @State stills: ActorStill[] = [];
  // 剧照瀑布流只吃 url 数组；点第 i 张要回到 stills[i]，所以两份同步维护
  @State stillUrls: string[] = [];
  // 比例必须走 @State：以前是普通字段，传给 StillsWall 的永远是空数组，
  // 于是首帧全按 3:2 铺、图片加载完再重排 —— 用户看到的就是「先方块后瀑布流」。
  @State stillRatios: number[] = [];
  /** 一次抓一批（STILL_POOL 张）存在本地，换一批先在这批里轮换 → 瞬时，不等网络。 */
  private pool: ActorStill[] = [];
  private poolRatios: number[] = [];
  private poolCursor: number = 0;
  @State zoomOn: boolean = false;
  @State zoomUrl: string = '';
  @State zoomScale: number = 0.94;
  @State zoomBlur: number = 18;
  @State zoomFade: number = 1;
  @State showAddPhoto: boolean = false;
  @State photoUrl: string = '';
  @State addingPhoto: boolean = false;
  @State fetchingPhoto: boolean = false;
  @State stillsLoading: boolean = false;
  @State error: string = '';
  @State toast: string = '';
  private actorId: number = 0;
  private pendingName: string = '';

  aboutToAppear(): void {
    const p = router.getParams() as ActorParams;
    if (p !== undefined && p !== null) {
      this.actorId = Number(p.id);
      this.pendingName = p.name === undefined || p.name === null ? '' : p.name;
    }
    this.load();
  }

  private async load(): Promise<void> {
    if (this.actorId <= 0) {
      this.error = '没有找到该演员的资料';
      this.loading = false;
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/actors/${this.actorId}`, Store.I.token);
      this.data = safeActorDetail(JSON.parse(text) as ActorDetail);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actor detail: ${e.code} ${e.message}`);
      this.error = '加载失败，点这里重试';
      this.loading = false;
      return;
    }
    this.loading = false;
    this.loadWorks(0, false);
    this.loadStills();
  }

  /**
   * 随机剧照墙：每张图带影片 id，点图直接跳对应影片详情。
   *
   * 「再抽一次」不再每次都等网络：一次抓 STILL_POOL 张（服务端连真实比例一起给），
   * 之后每点一次就在本地池里往后挪一格窗口，瞬时出图；池子用完才去抓下一批。
   * 因为比例是现成的，瀑布流首帧就是最终版式，不会先方块再跳位。
   */
  private async loadStills(fromRefresh: boolean = false): Promise<void> {
    if (this.actorId <= 0 || this.stillsLoading) {
      return;
    }
    // 池子里还有余量：直接轮换，零网络
    if (fromRefresh && this.pool.length >= this.poolCursor + STILL_COUNT) {
      this.showSlice(this.poolCursor);
      this.poolCursor += STILL_COUNT;
      return;
    }
    this.stillsLoading = true;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/actors/${this.actorId}/stills?limit=${STILL_POOL}`, Store.I.token);
      const list: ActorStill[] = safeActorStills(JSON.parse(text) as ActorStillList);
      if (list.length > 0) {
        const ratios: number[] = [];
        for (let i = 0; i < list.length; i++) {
          ratios.push(list[i].ratio);
        }
        this.pool = list;
        this.poolRatios = ratios;
        this.poolCursor = 0;
        this.showSlice(0);
        this.poolCursor = STILL_COUNT;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actor stills: ${e.code} ${e.message}`);
    }
    this.stillsLoading = false;
  }

  /** 把池子里从 start 开始的 STILL_COUNT 张摆上来（不足就少摆几张）。 */
  private showSlice(start: number): void {
    const end: number = Math.min(this.pool.length, start + STILL_COUNT);
    if (start >= end) {
      return;
    }
    const slice: ActorStill[] = this.pool.slice(start, end);
    const urls: string[] = [];
    const ratios: number[] = [];
    for (let i = 0; i < slice.length; i++) {
      urls.push(slice[i].url);
      ratios.push(this.poolRatios[i + start]);
    }
    this.stills = slice;
    this.stillUrls = urls;
    this.stillRatios = ratios;
  }

  /**
   * 点剧照：只做两件事 —— 预取详情、带着图片地址跳过去。
   *
   * 「从中心放大铺满 → 扩散淡出」整套动效搬到详情页内部做，
   * 这样淡出的时候下面已经是渲染好的详情页，不会先露出演员页，
   * 也不会再叠一层系统的左滑转场。
   */
  private openStill(x: ActorStill): void {
    const p: DetailParams = { id: x.id, heroUrl: x.url };
    this.fetchDetail(x.id);
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  private async fetchDetail(id: number): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/item/${id}`, Store.I.token);
      Store.I.cacheDetail(safeDetail(JSON.parse(text) as ItemDetail));
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] prefetch detail: ${e.code} ${e.message}`);
    }
  }

  /** 从相册选一张图上传入库（base64 走 JSON，服务端落本地写真目录）。 */
  private async pickPhoto(): Promise<void> {
    if (this.addingPhoto) {
      return;
    }
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const picked: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (picked.photoUris.length === 0) {
        return;
      }
      const uri: string = picked.photoUris[0];
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size > 12 * 1024 * 1024) {
        fileIo.closeSync(file);
        this.toast = '图片太大（上限 12MB）';
        return;
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);

      this.addingPhoto = true;
      const helper: util.Base64Helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(buf));
      let ext: string = 'jpg';
      const low: string = uri.toLowerCase();
      if (low.indexOf('.png') >= 0) {
        ext = 'png';
      } else if (low.indexOf('.webp') >= 0) {
        ext = 'webp';
      }
      await httpPost(`${Store.I.user}/api/user/actors/${this.actorId}/gallery/upload`, Store.I.token,
        JSON.stringify({ data: b64, ext: ext }));
      this.showAddPhoto = false;
      await this.load();
      this.toast = '已加入写真库';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pick photo: ${e.code} ${e.message}`);
      this.toast = '上传失败';
    }
    this.addingPhoto = false;
    setTimeout(() => {
      this.clearToast();
    }, 2000);
  }

  /** 从 gfriends 头像库按名字自动补图（服务端下载到本地后入库）。 */
  private async fetchPhotos(): Promise<void> {
    if (this.fetchingPhoto) {
      return;
    }
    this.fetchingPhoto = true;
    this.toast = '正在找图…';
    try {
      const text: string = await httpPost(
        `${Store.I.user}/api/user/actors/${this.actorId}/gallery/fetch`, Store.I.token,
        JSON.stringify({ limit: 8 }));
      const r: FetchResult = JSON.parse(text) as FetchResult;
      await this.load();
      if (r.added > 0) {
        this.toast = `补了 ${r.added} 张写真`;
      } else if (r.note !== undefined && r.note.length > 0) {
        this.toast = r.note;
      } else {
        this.toast = '没有新写真';
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] fetch photo: ${e.code} ${e.message}`);
      this.toast = '抓取失败';
    }
    this.fetchingPhoto = false;
    setTimeout(() => {
      this.clearToast();
    }, 2400);
  }

  private clearToast(): void {
    if (this.toast === '正在找图…') {
      return;
    }
    this.toast = '';
  }

  /** 把一张图片直链收进写真库（服务端会做白名单校验）。 */
  private async addPhoto(): Promise<void> {
    const url: string = this.photoUrl.trim();
    if (url.length === 0 || this.addingPhoto) {
      return;
    }
    this.addingPhoto = true;
    try {
      await httpPost(`${Store.I.user}/api/user/actors/${this.actorId}/gallery`, Store.I.token,
        JSON.stringify({ url: url }));
      this.showAddPhoto = false;
      this.photoUrl = '';
      await this.load();
      this.toast = '已加入写真库';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] add photo: ${e.code} ${e.message}`);
      this.toast = '添加失败：只支持白名单图床的 http(s) 地址';
    }
    this.addingPhoto = false;
    setTimeout(() => {
      this.clearToast();
    }, 2000);
  }

  private resetZoom(): void {
    this.zoomOn = false;
    this.zoomFade = 1;
    this.zoomScale = 0.94;
    this.zoomBlur = 18;
  }

  onPageShow(): void {
    this.resetZoom();
  }

  /** 作品按 3 个一组成行，宽度自适应屏幕。 */
  private chunk(list: ActorMediaItem[]): ActorMediaItem[][] {
    const out: ActorMediaItem[][] = [];
    let row: ActorMediaItem[] = [];
    for (let i = 0; i < list.length; i++) {
      row.push(list[i]);
      if (row.length === 3) {
        out.push(row);
        row = [];
      }
    }
    if (row.length > 0) {
      out.push(row);
    }
    return out;
  }

  private async loadWorks(offset: number, append: boolean): Promise<void> {
    const url: string = `${Store.I.user}/api/user/actors/${this.actorId}/media` +
      `?offset=${offset}&limit=${WORK_PAGE}&sort_by=release&order=desc`;
    try {
      const text: string = await httpGet(url, Store.I.token);
      const r: ActorMediaList = safeActorMediaList(JSON.parse(text) as ActorMediaList);
      this.works = append ? this.works.concat(r.items) : r.items;
      this.total = r.total;
      this.rows = this.chunk(this.works);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actor works: ${e.code} ${e.message}`);
      if (!append) {
        this.toast = '作品列表加载失败';
      }
    }
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.works.length >= this.total || this.total <= 0) {
      return;
    }
    this.loadingMore = true;
    this.loadWorks(this.works.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private measures(): string {
    if (this.data.bust <= 0 || this.data.waist <= 0 || this.data.hip <= 0) {
      return '';
    }
    return `${this.data.bust}/${this.data.waist}/${this.data.hip}`;
  }

  /** 点头像看写真：优先用上游给的多张图，只有一张时也能全屏看。 */
  private openGallery(): void {
    let urls: string[] = this.data.avatars;
    if (urls.length === 0 && this.data.avatar.length > 0) {
      urls = [this.data.avatar];
    }
    if (urls.length === 0) {
      return;
    }
    const p: ViewerParams = { urls: urls, index: 0, title: this.data.name };
    router.pushUrl({ url: 'pages/ImageViewerPage', params: p });
  }

  @Builder
  InfoCell(label: string, value: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
      Text(value.length > 0 ? value : '—')
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  Stills() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text('盲盒')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('剧照')
          .fontSize(9)
          .fontColor(Theme.ACCENT)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(4)
        Blank()
        if (this.stillsLoading) {
          Text('搜索中…')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        } else {
          Text('再抽一次')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.CARD)
            .borderRadius(10)
            .onClick(() => {
              this.loadStills(true);
            })
        }
      }
      .width('100%')

      // 和影片详情页同一套瀑布流：横竖版各按原比例占位，不裁构图
      StillsWall({
        urls: this.stillUrls,
        ratios: this.stillRatios,
        onPick: (i: number) => {
          if (i >= 0 && i < this.stills.length) {
            this.openStill(this.stills[i]);
          }
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  WorkCell(m: ActorMediaItem) {
    // 复用媒体库那张卡：这样「破解 / 流出 / 无码 / 中字」和评分都自带，
    // 不必每个页面各画一套（之前这里就是漏掉来源标记的地方）。
    Column() {
      PosterCard({
        item: posterItem(m.id, m.number, m.title, m.release, m.poster, m.score, m.marks),
        fluid: true,
        showTitle: false,
        onTap: () => {
          const params: DetailParams = { id: m.id };
          router.pushUrl({ url: 'pages/DetailPage', params: params });
        }
      })
    }
    .layoutWeight(1)
  }

  @Builder
  WorkRow(row: ActorMediaItem[]) {
    Row({ space: 9 }) {
      ForEach(row, (m: ActorMediaItem) => {
        this.WorkCell(m)
      }, (m: ActorMediaItem) => `work-${m.id}`)
      if (row.length < 3) {
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  Header() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.data.avatar.length > 0) {
        Image(Store.I.img(this.data.avatar))
          .width('100%')
          .height(360)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.CARD)
          .alt($r('app.media.placeholder'))
      } else {
        Column()
          .width('100%')
          .height(360)
          .backgroundColor(Theme.CARD_HI)
      }
      Column()
        .width('100%')
        .height(360)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.35], ['#990B0B0F', 0.82], ['#0B0B0F', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
      Column({ space: 5 }) {
        Text(this.data.name.length > 0 ? this.data.name : this.pendingName)
          .fontSize(25)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.data.tagline.length > 0) {
          Text(this.data.tagline)
            .fontSize(12)
            .fontColor('#D3D3DC')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Text(`${this.data.count} 部作品` + (this.data.gender === 'female' ? ' · 女优' : ''))
          .fontSize(11)
          .fontColor('#B9B9C4')
          .width('100%')
        if (this.data.avatars.length > 0) {
          Text(`${this.data.avatars.length} 张写真 · 下面可看可加`)
            .fontSize(10)
            .fontColor('#9E9EAC')
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .margin({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 16 })
      .borderRadius(16)
      .backgroundColor('#330B0B0F')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .border({ width: 0.5, color: '#26FFFFFF' })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(360)
    .onClick(() => {
      this.openGallery();
    })
  }

  /**
   * 头部下方的操作条。
   * 之前把「＋」放在图片右上角，实际被图片和渐变盖住、点不到；
   * 写真入口也只是一行灰字，藏在玻璃面板里。现在做成两条明确的按钮。
   */
  @Builder
  ActorActions() {
    Row({ space: 10 }) {
      Row({ space: 6 }) {
        Text('🖼')
          .fontSize(13)
        Text(this.data.avatars.length > 0 ? `写真 ${this.data.avatars.length} 张` : '写真库')
          .fontSize(13)
          .fontColor(Theme.TEXT)
      }
      .layoutWeight(1)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.CARD)
      .borderRadius(20)
      .border({ width: 0.5, color: '#26FFFFFF' })
      .onClick(() => {
        if (this.data.avatars.length > 0) {
          this.openGallery();
        } else {
          this.showAddPhoto = true;
        }
      })

      Row({ space: 6 }) {
        Text('＋')
          .fontSize(15)
          .fontColor('#FFFFFF')
        Text('加写真')
          .fontSize(13)
          .fontColor('#FFFFFF')
      }
      .layoutWeight(1)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.ACCENT)
      .borderRadius(20)
      .onClick(() => {
        this.showAddPhoto = true;
      })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 12 })
  }

  @Builder
  Profile() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        this.InfoCell('生日', this.data.birthday)
        this.InfoCell('身高', this.data.height > 0 ? `${this.data.height} cm` : '')
        this.InfoCell('罩杯', this.data.cup)
      }
      .width('100%')
      Row({ space: 10 }) {
        this.InfoCell('三围 B/W/H', this.measures())
        this.InfoCell('出生地', this.data.birthplace)
        this.InfoCell('资料更新', this.data.updated_at.length >= 10 ? this.data.updated_at.substring(0, 10) : '')
      }
      .width('100%')
      if (this.data.aliases.length > 0) {
        Column({ space: 7 }) {
          Text('别名')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.data.aliases, (alias: string) => {
              Text(alias)
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .backgroundColor(Theme.CARD)
                .borderRadius(11)
                .margin({ right: 6, bottom: 6 })
            }, (alias: string) => `alias-${alias}`)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  Overview() {
    Column({ space: 8 }) {
      Text('简介')
        .fontSize(12)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      Text(this.data.overview)
        .fontSize(13)
        .fontColor(Theme.TEXT_DIM)
        .lineHeight(22)
        .maxLines(this.expanded ? 80 : 5)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.expanded ? '收起' : '展开全文')
        .fontSize(11)
        .fontColor(Theme.ACCENT)
        .onClick(() => {
          this.expanded = !this.expanded;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
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
      } else if (this.error.length > 0) {
        Column({ space: 12 }) {
          Text('☺')
            .fontSize(36)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.error = '';
              this.loading = true;
              this.load();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ListItem() {
            Column() {
              this.Header()
              this.ActorActions()
            }
            .width('100%')
          }
          ListItem() {
            Column({ space: 18 }) {
              this.Profile()
              if (this.data.overview.length > 0) {
                this.Overview()
              }
              if (this.stills.length > 0) {
                Column() {
                  this.Stills()
                }
                .width('100%')
                .margin({ top: 18, bottom: 18 })
              }

              Row({ space: 8 }) {
                Text(`作品 · ${this.total}`)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                Blank()
                Text('共演')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                  .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                  .backgroundColor(Theme.CARD)
                  .borderRadius(11)
                  .onClick(() => {
                    router.pushUrl({ url: 'ext/actors/CastFinderPage' });
                  })
                Text('筛选 ›')
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                  .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(11)
                  .onClick(() => {
                    const p: ActorParams = { id: this.actorId, name: this.data.name };
                    router.pushUrl({ url: 'ext/actors/ActorWorksPage', params: p });
                  })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 14 })
          }

          ForEach(this.rows, (row: ActorMediaItem[]) => {
            ListItem() {
              this.WorkRow(row)
            }
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 10 })
          }, (row: ActorMediaItem[]) => `wrow-${row[0].id}`)

          ListItem() {
            Column() {
              if (this.works.length < this.total) {
                Text(this.loadingMore ? '加载中…' : '加载更多作品')
                  .fontSize(12)
                  .fontColor(Theme.ACCENT)
                  .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                  .backgroundColor(Theme.ACCENT_SOFT)
                  .borderRadius(14)
                  .onClick(() => {
                    this.loadMore();
                  })
              } else if (this.works.length === 0) {
                Text('暂无作品')
                  .fontSize(12)
                  .fontColor(Theme.TEXT_FAINT)
              } else {
                Text('— 已经到底了 —')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
              }
            }
            .width('100%')
            .padding({ top: 6, bottom: 28 })
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.loadMore();
        })
        .padding({ bottom: 0 })
      }

      Text('‹')
        .fontSize(24)
        .fontColor('#FFFFFF')
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor('#40000000')
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .margin({ left: 12, top: 8 })
        .onClick(() => {
          router.back();
        })

      if (this.zoomOn) {
        Stack() {
          Image(Store.I.img(this.zoomUrl))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(40)
            .opacity(0.5)
          Image(Store.I.img(this.zoomUrl))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .blur(this.zoomBlur)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .opacity(this.zoomFade)
      }

      if (this.showAddPhoto) {
        Column() {
          Column({ space: 12 }) {
            Text('写真库')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
              .width('100%')
            Text('现在已经 ' + `${this.data.avatars.length}` + ' 张。可以从相册传一张，或者按名字自动去图库找。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')

            // 主入口：相册上传
            Row({ space: 8 }) {
              Text('＋')
                .fontSize(15)
                .fontColor('#FFFFFF')
              Text(this.addingPhoto ? '上传中…' : '从相册上传')
                .fontSize(13)
                .fontColor('#FFFFFF')
            }
            .width('100%')
            .height(42)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.pickPhoto();
            })

            Row({ space: 8 }) {
              Text('⟳')
                .fontSize(14)
                .fontColor(Theme.ACCENT)
              Text(this.fetchingPhoto ? '正在找图…' : '自动补图（gfriends）')
                .fontSize(13)
                .fontColor(Theme.TEXT)
            }
            .width('100%')
            .height(42)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(10)
            .border({ width: 0.5, color: '#26FFFFFF' })
            .onClick(() => {
              this.fetchPhotos();
            })

            Text('或者粘图片直链（只收白名单图床）')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .margin({ top: 2 })

            TextInput({ placeholder: 'https://...jpg', text: this.photoUrl })
              .height(38)
              .fontSize(12)
              .fontColor(Theme.TEXT)
              .placeholderColor(Theme.TEXT_FAINT)
              .placeholderFont({ size: 11 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .width('100%')
              .onChange((v: string) => {
                this.photoUrl = v;
              })

            Row({ space: 10 }) {
              Blank()
              Text('关闭')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .onClick(() => {
                  this.showAddPhoto = false;
                  this.photoUrl = '';
                })
              Text(this.addingPhoto ? '保存中…' : '保存直链')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 18, right: 18, top: 7, bottom: 7 })
                .backgroundColor(Theme.ACCENT)
                .borderRadius(16)
                .onClick(() => {
                  this.addPhoto();
                })
            }
            .width('100%')
          }
          .width('88%')
          .padding(16)
          .backgroundColor(Theme.BG_RAISED)
          .borderRadius(16)
          .border({ width: 0.5, color: '#26FFFFFF' })
          .onClick(() => {
            // 吞掉点击，避免穿到遮罩
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {
          this.showAddPhoto = false;
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
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
