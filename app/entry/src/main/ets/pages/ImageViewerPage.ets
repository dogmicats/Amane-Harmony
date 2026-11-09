import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';

/** 大图查看器入参：剧照列表 + 起始下标。 */
interface ViewerParams {
  urls: string[];
  index: number;
  title: string;
}

/**
 * 全屏大图查看器（核心页面，非扩展）。
 *
 * 详情页的剧照原来只是缩略图，点了没反应 —— 剧照的价值恰恰在于看清。
 * 这里用 Swiper 做左右翻页（和系统相册同一手感），黑色沉浸底 + 顶部计数，
 * 点任意处或右上角 ✕ 关闭。图片 URL 已在服务端转成 /img?b= 形式，
 * 用 Store.img() 补前缀即可，不要在这里拼 % 编码。
 */
@Entry
@Component
struct ImageViewerPage {
  @State urls: string[] = [];
  @State current: number = 0;
  @State title: string = '';
  @State showBar: boolean = true;

  aboutToAppear(): void {
    const p = router.getParams() as ViewerParams;
    if (p !== undefined && p !== null) {
      this.urls = Array.isArray(p.urls) ? p.urls : [];
      const idx: number = Number(p.index);
      this.current = isFinite(idx) && idx >= 0 && idx < this.urls.length ? Math.trunc(idx) : 0;
      this.title = p.title === undefined || p.title === null ? '' : p.title;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Swiper() {
        ForEach(this.urls, (url: string, i: number) => {
          // 竖屏看横图时，底层铺一张模糊同图填满黑边，上层 Contain 完整显示不裁构图
          Stack() {
            Image(Store.I.img(url))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(32)
              .opacity(0.4)
            Image(Store.I.img(url))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
          }
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.showBar = !this.showBar;
          })
        }, (url: string, i: number) => `viewer-${i}`)
      }
      .index(this.current)
      .loop(false)
      .indicator(false)
      .duration(220)
      .width('100%')
      .height('100%')
      .onChange((index: number) => {
        this.current = index;
      })

      if (this.showBar) {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            if (this.title.length > 0) {
              Text(this.title)
                .fontSize(11)
                .fontColor('#C6C6D0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            Text(`${this.current + 1} / ${this.urls.length}`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('✕')
            .fontSize(16)
            .fontColor('#FFFFFF')
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .borderRadius(17)
            .backgroundColor('#59000000')
            .onClick(() => {
              router.back();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 14, top: 12, bottom: 12 })
        .backgroundColor('#33000000')
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
