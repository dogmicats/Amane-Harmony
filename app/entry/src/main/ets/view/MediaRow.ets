import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { PosterCard } from './PosterCard';

/** 首页的横向卡片行（每日推荐 / 每个媒体库一行）。 */
@Component
export struct MediaRow {
  title: string = '';
  subtitle: string = '';
  items: MediaItem[] = [];
  onMore: () => void = () => {};
  onTap: (item: MediaItem) => void = () => {};

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
            PosterCard({
              item: item,
              onTap: () => {
                this.onTap(item);
              }
            })
          }
        }, (item: MediaItem) => `${item.id}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(210)
      .contentStartOffset(Theme.PAGE_PAD)
      .contentEndOffset(Theme.PAGE_PAD)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 18 })
  }
}
