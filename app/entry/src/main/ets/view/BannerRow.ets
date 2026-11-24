import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { MarkBadges } from './MarkBadges';
import { ReasonLine } from '../common/Reason';

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
  /** 2.6.1.32：同 HeroBanner —— 普通成员不会跟着父组件刷新，下拉后每日推荐会停在旧那批。 */
  @Prop items: MediaItem[] = [];
  /** 行头「推荐理由」入口；空串 = 不显示（设置里关掉推荐理由时）。 */
  whyLabel: string = '';
  onWhy: () => void = () => {};
  onMore: () => void = () => {};
  onTap: (item: MediaItem) => void = () => {};
  /**
   * 今天这批片的推荐理由（2.6.1.36）：**每张卡自己的下方**写它那句。
   *
   * 用户 19:21：「把每部影片的推荐理由对应写上就好了」—— 理由要和片对得上号，
   * 所以不能再拿一个汇总块，而是贴在各自的卡片下面（红框那个位置）。
   * 传数组而不是回调：ArkTS 的自定义组件传函数属性在 ForEach 重建时会踩引用，数组更稳。
   */
  @Prop lines: ReasonLine[] = [];

  /** 这部片今天的理由（没有就空串，卡片下方不留白）。 */
  private reasonOf(id: number): string {
    for (let i = 0; i < this.lines.length; i++) {
      if (this.lines[i].id === id) {
        return this.lines[i].reason;
      }
    }
    return '';
  }

  /** 有理由时列表要多留一条高度（2 行 11px + 间距）。 */
  private stripHeight(): number {
    for (let i = 0; i < this.items.length; i++) {
      if (this.reasonOf(this.items[i].id).length > 0) {
        return 44;
      }
    }
    return 0;
  }

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
          Row({ space: 6 }) {
            Text(this.title)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            // 2.6.1.30：和顶部「随手翻到」区分开 —— 这一行是当天固定的那批
            Text('每天固定')
              .fontSize(9)
              .fontColor(Theme.TEXT_DIM)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.CARD_HI)
              .border({ width: 0.5, color: '#24FFFFFF' })
              .borderRadius(8)
          }
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        // 推荐理由：只占行头一个小 chip，卡片内一行文字都不加，
        // 理由全部放进点开的底部抽屉里读（见 HomeTab.ReasonSheet）。
        if (this.whyLabel.length > 0) {
          Text(this.whyLabel)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ACCENT_INK)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(Theme.accentAlpha(0.14))
            .border({ width: 0.5, color: Theme.inkAlpha(0.34) })
            .borderRadius(12)
            .margin({ right: 8 })
            .onClick(() => {
              this.onWhy();
            })
        }

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
            // 卡片 + 它自己那句理由（理由在卡片下方，不压图、不挡标题）
            Column({ space: 5 }) {
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
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)
            .backgroundColor(Theme.CARD)
            .onClick(() => {
              this.onTap(item);
            })

              // 这张片今天的理由：金色一句，最多两行；没有就不占位
              if (this.reasonOf(item.id).length > 0) {
                Text(this.reasonOf(item.id))
                  .fontSize(11)
                  .fontColor(Theme.GOLD)
                  .lineHeight(16)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(this.widthOf(item))
                  .padding({ left: 2, right: 2 })
              }
            }
            .alignItems(HorizontalAlign.Start)
          }
        }, (item: MediaItem) => `bn-${item.id}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(BannerRow.CARD_H + this.stripHeight())
      .contentStartOffset(Theme.PAGE_PAD)
      .contentEndOffset(Theme.PAGE_PAD)
      // 同 MediaRow：触碰落在横向行上就不抢（行自己决定是滚动还是点击）
      .onTouch((ev: TouchEvent) => {
        AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 18 })
  }
}
