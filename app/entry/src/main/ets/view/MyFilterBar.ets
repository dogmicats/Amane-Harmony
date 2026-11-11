import { Theme } from '../common/Theme';
import { ChipOption, MYRATING_OPTIONS } from '../common/BrowseOptions';
import { BuildConfig } from '../common/BuildConfig';
import { CollectionsBar } from '../ext/collections/CollectionsBar';

/**
 * 「我的评分 / 收藏夹」筛选条：四个走各自端点的列表页（分类墙、演员作品、
 * 共演、观看记录）共用同一份，免得每页各写一遍 chip。
 *
 * 2.4.5.17 起「收藏夹」不再是平铺 chip，而是与收藏页**同一个** `CollectionsBar`：
 * 组件自己取数、每次点开都刷新，所以在收藏页新建 / 改名 / 删除清单后，
 * 这里的选项和当前清单名会同步，不会再停在「全部／未归类」。
 * 排序不在这里——各页本来就有自己的排序 chip 列表。
 */
@Component
export struct MyFilterBar {
  @Prop myRating: string = '';
  @Prop collection: string = '';
  /** 关掉 ratings / collections 扩展时整块不显示（发布版可能没有）。 */
  showRating: boolean = true;
  showCollection: boolean = true;
  onMyRating: (key: string) => void = (k: string) => {};
  onCollection: (key: string) => void = (k: string) => {};

  @Builder
  ChipRow(prefix: string, options: ChipOption[], current: string, onPick: (key: string) => void) {
    Scroll() {
      Row({ space: 7 }) {
        Text(prefix)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        ForEach(options, (opt: ChipOption) => {
          Text(opt.label)
            .fontSize(11)
            .fontColor(current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(current === opt.key ? Theme.ACCENT : Theme.CARD)
            .borderRadius(11)
            .onClick(() => {
              onPick(opt.key);
            })
        }, (opt: ChipOption) => `${prefix}-${opt.key}`)
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Start)
      .width('100%')
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
    .width('100%')
  }

  build() {
    Column({ space: 6 }) {
      if (this.showRating && BuildConfig.ENABLE_RATINGS) {
        this.ChipRow('我的评分', MYRATING_OPTIONS, this.myRating, this.onMyRating)
      }
      if (this.showCollection && BuildConfig.ENABLE_COLLECTIONS) {
        Row({ space: 7 }) {
          Text('收藏夹')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
          CollectionsBar({
            current: this.collection,
            showManage: false,
            onPick: (key: string) => {
              this.onCollection(key);
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
