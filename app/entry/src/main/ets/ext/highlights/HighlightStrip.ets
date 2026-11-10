import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { clock } from '../../common/Util';
import { HighlightItem, HighlightList, safeHighlights } from './HighlightTypes';

/**
 * 影片亮点：一排「片子自己的画面」缩略图，点哪张从哪一秒开始播。
 *
 * 和剧照（`view/StillsWall`）的区别必须先说清，否则容易被当成一个东西：
 * 剧照是刮削来的宣传图，和这部片实际拍了什么没关系；亮点是**从视频文件里抽的帧**，
 * 用户点它的时候脑子里已经有「我要看这一段」了 —— 所以这里不接查看大图，
 * 只有一件事可做：带着 `t` 进播放页。
 *
 * 三条实现约定：
 *   1. **整块可缺席**：服务端没有 ffmpeg、文件不在线、片子太短抽不出帧时都会回
 *      `ok:false`，这时候这一块**完全不渲染**（不是渲染一个空标题再报错）——
 *      亮点是锦上添花，不能因为它让详情页看起来坏了。
 *   2. **首屏不等齐**：服务端预算内先回一部分，`pending>0` 就说明还有在抽。
 *      这里自动等一会儿再取一次，第二次基本是直接命中磁盘缓存。
 *   3. **版本要跟着走**：缩略图是从某个具体文件抽的，点图起播必须带同一个
 *      `file_key`（f<文件id>），否则多版本条目会「用 A 版本的画面从 B 版本的位置起播」。
 */

/** 一张缩略图画布（16:9 略扁，和详情页的横卡视觉一致）。 */
const CARD_W: number = 132;
const CARD_H: number = 74;
/** 骨架占位几张：一屏内能看出「正在抽帧」就够了，不必等真实张数。 */
const SKELETONS: number[] = [0, 1, 2, 3];
/** pending 时最多补取几次，以及每轮间隔（服务端返回很快，靠密集轮询把图逐张补进来）。 */
const MAX_TRIES: number = 12;
const RETRY_BASE_MS: number = 900;

@Component
export struct HighlightStrip {
  /** 元数据 id（= 详情页的 metaId）。 */
  metaId: number = 0;
  /** 点了第几张：把起播秒数与版本 key 交回页面。 */
  onPick: (t: number, fileKey: string, name: string) => void = (t: number, fileKey: string, name: string) => {};

  @State items: HighlightItem[] = [];
  @State loading: boolean = true;
  /** 服务端这一轮要抽几张（进度文案用）。 */
  @State total: number = 0;
  /** 抽不到帧就整块隐藏，连标题都不留。 */
  @State gone: boolean = false;
  private fileKey: string = '';
  private tries: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private async load(): Promise<void> {
    if (this.metaId <= 0) {
      this.loading = false;
      this.gone = true;
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/highlights/${this.metaId}`, Store.I.token);
      const data: HighlightList = safeHighlights(JSON.parse(text) as HighlightList);
      if (data.file_key.length > 0) {
        this.fileKey = data.file_key;
      }
      if (data.count > 0) {
        this.total = data.count;
      }
      if (data.items.length > 0) {
        // 先到的先摆上去，后面几批到了再补，不为了凑齐把整条藏起来
        this.items = data.items;
        this.loading = false;
      }
      if (data.pending > 0 && this.tries < MAX_TRIES) {
        this.tries += 1;
        this.timer = setTimeout(() => {
          this.load();
        }, RETRY_BASE_MS + this.tries * 250);
        return;
      }
      this.loading = false;
      if (this.items.length === 0) {
        this.gone = true;
      }
    } catch (err) {
      const e = err as BusinessError;
      // 老服务端没有这个接口（404）/ 没开扩展：安静地不显示，不 toast
      console.error(`[amane] highlights: ${e.code} ${e.message}`);
      this.loading = false;
      if (this.items.length === 0) {
        this.gone = true;
      }
    }
  }

  @Builder
  Skeleton() {
    Column()
      .width(CARD_W)
      .height(CARD_H)
      .backgroundColor(Theme.CARD)
      .borderRadius(8)
  }

  @Builder
  Cell(item: HighlightItem) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Image(Store.I.img(item.url))
        .width(CARD_W)
        .height(CARD_H)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .backgroundColor(Theme.CARD)
      Text(clock(item.t))
        .fontSize(9)
        .fontColor('#FFFFFF')
        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        .backgroundColor('#A6000000')
        .borderRadius(5)
        .margin(5)
    }
    .width(CARD_W)
    .height(CARD_H)
    .onClick(() => {
      this.onPick(item.t, this.fileKey, '');
    })
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('亮点')
          .fontSize(12)
          .fontColor(Theme.TEXT_FAINT)
        if (this.items.length > 0) {
          Text(`${this.items.length}`)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        Blank()
        // 网盘库首次打开要现场抽帧（一帧约 4s，抽完永久缓存），给个明确的状态，
        // 否则一排灰块看起来像加载失败
        Text(this.loading ? `抽帧中 ${this.items.length}/${this.total}` : '点图从那处开始播 ›')
          .fontSize(10)
          .fontColor(this.loading ? Theme.TEXT_FAINT : Theme.ACCENT)
      }
      .width('100%')

      Scroll() {
        Row({ space: 8 }) {
          if (this.loading && this.items.length === 0) {
            ForEach(SKELETONS, (i: number) => {
              this.Skeleton()
            }, (i: number) => `hi-sk-${i}`)
          } else {
            ForEach(this.items, (item: HighlightItem) => {
              this.Cell(item)
            }, (item: HighlightItem) => `hi-${item.ms}`)
          }
        }
        .padding({ right: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      // 横向 Scroll 不给高度会把下半页挤扁
      .height(CARD_H)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 16 })
    // 抽不到帧就整块不占位（Visibility.None 连 margin 一起收掉）
    .visibility(this.gone ? Visibility.None : Visibility.Visible)
  }
}
