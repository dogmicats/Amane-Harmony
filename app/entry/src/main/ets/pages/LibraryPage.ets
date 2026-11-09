import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { BrowseParams } from '../common/Types';
import { BrowseGrid } from '../view/BrowseGrid';

/** 某个媒体库的完整列表页（从首页「全部 ›」进来）。 */
@Entry
@Component
struct LibraryPage {
  @State title: string = '媒体库';
  @State libraryId: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as BrowseParams;
    if (params !== undefined && params !== null) {
      this.libraryId = params.libraryId === undefined ? 0 : params.libraryId;
      const t: string = params.title === undefined ? '' : params.title;
      this.title = t.length > 0 ? t : '媒体库';
    }
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text(this.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })

      BrowseGrid({ libraryId: this.libraryId, refreshKey: 0 })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
