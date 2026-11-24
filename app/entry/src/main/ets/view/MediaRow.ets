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
            .fontWeight(FontWeight.Bold)
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
      // 触碰落在这条横向行上 → 持续记时间戳：首页据此知道「这一划归行自己」，
      // 不抢去拉负一屏。**不能只靠 onScrollStart**：首页在第一个 Move 就会把页面推走，
      // 行根本没机会开始滚（2026-11-14 21:0x 实测），所以按"触碰过"算。
      .onTouch((ev: TouchEvent) => {
        AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 18 })
  }
}
