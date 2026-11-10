import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { LibraryInfo } from '../common/Types';
import { BrowseGrid } from '../view/BrowseGrid';

/** 媒体库 Tab：顶部库切换 + 浏览网格（排序/筛选在 BrowseGrid 里）。 */
@Component
export struct LibraryTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State libs: LibraryInfo[] = Store.I.libraries;
  @State activeId: number = 0;

  aboutToAppear(): void {
    this.libs = Store.I.libraries;
  }

  onRefresh(): void {
    this.libs = Store.I.libraries;
  }

  private pickLibrary(id: number): void {
    if (this.activeId === id) {
      return;
    }
    this.activeId = id;
  }

  @Builder
  Chip(id: number, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.activeId === id ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.activeId === id ? Theme.ACCENT : Theme.CARD)
      .borderRadius(16)
      .onClick(() => {
        this.pickLibrary(id);
      })
  }

  build() {
    Column() {
      Row() {
        Text('媒体库')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text('⌕')
          .fontSize(22)
          .fontColor(Theme.TEXT)
          .width(38)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SearchPage' });
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8, bottom: 8 })

      Scroll() {
        Row({ space: 8 }) {
          this.Chip(0, '全部')
          ForEach(this.libs, (lib: LibraryInfo) => {
            this.Chip(lib.id, lib.name)
          }, (lib: LibraryInfo) => `lib-${lib.id}`)
        }
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(44)

      BrowseGrid({ libraryId: this.activeId, refreshKey: this.refreshKey })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
