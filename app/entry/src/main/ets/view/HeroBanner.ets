import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { runtimeText } from '../common/Util';
import { MarkBadges } from './MarkBadges';

/**
 * 首页顶部大海报轮播：横图铺满 + 底部渐变 + 番号/标题/两个按钮。
 * 素材优先用剧照（16:9 横图），没有就退回竖版海报（会裁切，但不至于空着）。
 */
@Component
export struct HeroBanner {
  items: MediaItem[] = [];
  onPlay: (item: MediaItem) => void = () => {};
  onDetail: (item: MediaItem) => void = () => {};
  @State current: number = 0;

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.items.length > 0) {
        Swiper() {
          ForEach(this.items, (item: MediaItem) => {
            Stack({ alignContent: Alignment.BottomStart }) {
              Image(Store.I.img(item.fanart.length > 0 ? item.fanart : item.poster))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD)

              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 180,
                  colors: [['#00000000', 0.30], ['#B30B0B0F', 0.72], ['#0B0B0F', 1.0]]
                })

              Column() {
                Row({ space: 6 }) {
                  Text(item.number)
                    .fontSize(11)
                    .fontColor(Theme.TEXT)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor('#4D7C5CFF')
                    .borderRadius(4)
                  if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                    MarkBadges({ marks: item.marks, max: 3, badgeSize: 9, fill: 'dark' })
                  }
                  if (item.studio.length > 0) {
                    Text(item.studio)
                      .fontSize(11)
                      .fontColor(Theme.TEXT_DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width('100%')
                .margin({ bottom: 6 })

                Text(item.title.length > 0 ? item.title : item.number)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.TEXT)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ bottom: 4 })

                Text(runtimeText(item.runtime))
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .margin({ bottom: 12 })

                Row({ space: 10 }) {
                  Button() {
                    Row({ space: 6 }) {
                      Text('▶')
                        .fontSize(13)
                        .fontColor('#FFFFFF')
                      Text(item.position > 0 ? '继续播放' : '立即播放')
                        .fontSize(14)
                        .fontColor('#FFFFFF')
                        .fontWeight(FontWeight.Medium)
                    }
                  }
                  .height(38)
                  .padding({ left: 18, right: 18 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(19)
                  .onClick(() => {
                    this.onPlay(item);
                  })

                  Button('详情')
                    .height(38)
                    .padding({ left: 18, right: 18 })
                    .fontSize(14)
                    .fontColor(Theme.TEXT)
                    .backgroundColor('#33FFFFFF')
                    .borderRadius(19)
                    .onClick(() => {
                      this.onDetail(item);
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .height('100%')
          }, (item: MediaItem) => `${item.id}`)
        }
        .autoPlay(this.items.length > 1)
        .interval(7000)
        .loop(true)
        .indicator(false)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.current = index;
        })

        Row({ space: 5 }) {
          ForEach(this.items, (item: MediaItem, index: number) => {
            Column()
              .width(index === this.current ? 16 : 5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(index === this.current ? Theme.TEXT : '#59FFFFFF')
          }, (item: MediaItem, index: number) => `dot-${item.id}-${index}`)
        }
        .position({ right: Theme.PAGE_PAD, top: 64 })
      }
    }
    .width('100%')
    .height(Theme.HERO_H)
    .backgroundColor(Theme.BG)
  }
}
