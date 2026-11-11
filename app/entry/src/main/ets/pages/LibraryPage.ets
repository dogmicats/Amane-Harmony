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
  /** 详情页点演员「N 岁」进来时预置的年龄分桶 / 排序 / 性别。 */
  @State ageBand: string = '';
  @State sort: string = '';
  @State ageGender: string = '';
  @State ready: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as BrowseParams;
    if (params !== undefined && params !== null) {
      this.libraryId = params.libraryId === undefined ? 0 : params.libraryId;
      const t: string = params.title === undefined ? '' : params.title;
      this.title = t.length > 0 ? t : '媒体库';
      this.ageBand = params.ageBand === undefined ? '' : params.ageBand;
      this.sort = params.sort === undefined ? '' : params.sort;
      this.ageGender = params.ageGender === undefined ? '' : params.ageGender;
    }
    // 参数齐了才创建 BrowseGrid：它的 aboutToAppear 只跑一次，
    // 后补的初始值赶不上那一帧发出的第一次请求。
    this.ready = true;
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

      if (this.ready) {
        BrowseGrid({
          libraryId: this.libraryId,
          refreshKey: 0,
          initialAgeBand: this.ageBand,
          initialSort: this.sort,
          initialAgeGender: this.ageGender
        })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
