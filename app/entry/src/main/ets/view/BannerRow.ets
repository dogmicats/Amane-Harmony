import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { MarkBadges } from './MarkBadges';

/**
 * 首页「每日推荐」横幅行。
 *
 * 卡面尺寸不再写死 16:9：服务端会验证一张真横图并下发真实宽高比
 * （dmm 剧照普遍是 3:2，不是 16:9），这里按比例定宽 —— 高度固定，
 * 宽度 = 高度 × 比例，图片按原比例铺满，不裁切也就不会被放大成糊图。
 * 极少数没有比例的条目退回 16:9。
 */
@Component
export struct BannerRow {
  static readonly CARD_H: number = 168;
  static readonly FALLBACK_RATIO: number = 1.778;

  title: string = '';
  subtitle: string = '';
  items: MediaItem[] = [];
  onMore: () => void = () => {};
  onTap: (item: MediaItem) => void = () => {};

  /** 卡片宽度：高度 × 真实比例，限制在 1.25~2.4 之间，避免极端长条。 */
  private widthOf(item: MediaItem): number {
    let ratio: number = item.fanart_ratio === undefined || item.fanart_ratio === null
      ? BannerRow.FALLBACK_RATIO : item.fanart_ratio;
    if (!isFinite(ratio) || ratio <= 0) {
      ratio = BannerRow.FALLBACK_RATIO;
    }
    ratio = Math.max(1.25, Math.min(2.4, ratio));
    return Math.round(BannerRow.CARD_H * ratio);
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Text('全部 ›')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.onMore();
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 10 })

      List({ space: 12 }) {
        ForEach(this.items, (item: MediaItem) => {
          ListItem() {
            Stack({ alignContent: Alignment.BottomStart }) {
              Image(Store.I.img(item.fanart.length > 0 ? item.fanart : item.poster))
                .width(this.widthOf(item))
                .height(BannerRow.CARD_H)
                .objectFit(ImageFit.Cover)
                .borderRadius(Theme.RADIUS)
                .backgroundColor(Theme.CARD)
                .alt($r('app.media.placeholder'))

              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 180,
                  colors: [['#00000000', 0.35], ['#CC000000', 1.0]]
                })
                .borderRadius(Theme.RADIUS)

              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  Text(item.number)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 160 })
                  if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                    MarkBadges({ marks: item.marks, max: 2, badgeSize: 8, fill: 'dark' })
                  }
                  if (item.score > 0) {
                    Text(item.score.toFixed(1))
                      .fontSize(10)
                      .fontColor(Theme.GOLD)
                  }
                }
                Text(item.title.length > 0 ? item.title : item.number)
                  .fontSize(11)
                  .fontColor('#E6FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .padding(10)
              .width('100%')
            }
            .width(this.widthOf(item))
            .height(BannerRow.CARD_H)
            .borderRadius(Theme.RADIUS)
            .clip(true)
            .backgroundColor(Theme.CARD)
            .onClick(() => {
              this.onTap(item);
            })
          }
        }, (item: MediaItem) => `bn-${item.id}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(BannerRow.CARD_H)
      .contentStartOffset(Theme.PAGE_PAD)
      .contentEndOffset(Theme.PAGE_PAD)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 18 })
  }
}
