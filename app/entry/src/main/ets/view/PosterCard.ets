import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { scoreText } from '../common/Util';

/**
 * 海报卡：宽 116 固定，右上角评分，底部进度条（有播放进度时）。
 * 普通成员（非 @State）：内容由父组件的 ForEach 负责重建。
 */
@Component
export struct PosterCard {
  item: MediaItem = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    updated_at: '', position: 0, duration: 0
  };
  cardWidth: number = Theme.POSTER_W;
  showNumber: boolean = true;
  onTap: () => void = () => {};

  private ratio(): number {
    if (this.item.duration > 0 && this.item.position > 0) {
      return Math.min(100, Math.max(1, this.item.position / this.item.duration * 100));
    }
    return 0;
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(Store.I.img(this.item.poster))
          .width(this.cardWidth)
          .height(this.cardWidth * 1.42)
          .objectFit(ImageFit.Cover)
          .borderRadius(Theme.RADIUS)
          .backgroundColor(Theme.CARD)
          .alt($r('app.media.placeholder'))

        if (scoreText(this.item.score).length > 0) {
          Text(scoreText(this.item.score))
            .fontSize(10)
            .fontColor(Theme.GOLD)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#B3000000')
            .borderRadius(6)
            .margin(6)
        }

        if (this.ratio() > 0) {
          Column() {
            Blank()
            Progress({ value: this.ratio(), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(Theme.ACCENT)
              .backgroundColor('#4DFFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .borderRadius(Theme.RADIUS)
          .clip(true)
        }
      }
      .width(this.cardWidth)
      .borderRadius(Theme.RADIUS)

      Text(this.showNumber && this.item.number.length > 0 ? this.item.number : this.item.title)
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.cardWidth)
        .margin({ top: 6 })

      Text(this.showNumber ? (this.item.title.length > 0 ? this.item.title : ' ') : ' ')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.cardWidth)
        .margin({ top: 2 })
    }
    .width(this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onTap();
    })
  }
}
