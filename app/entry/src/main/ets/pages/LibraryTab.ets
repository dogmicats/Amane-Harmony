import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { LibraryInfo } from '../common/Types';
import { BrowseGrid, TAB_SAFE } from '../view/BrowseGrid';

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
      .borderRadius(Theme.R_PILL)
      // 未选中加 1px 细边：深底上纯色块会和背景糊在一起（和首页卡片同一套判据）
      .border({ width: 1, color: this.activeId === id ? Theme.accentAlpha(0.55) : Theme.STROKE })
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
        // 搜索入口与首页统一：真矢量图标 + 36vp 暗玻璃圆 + 1px 亮边。
        // 原来这里是 '⌕' 字符（细、和首页那个图标不是一套），两页并排看就是"两套设计"。
        Stack() {
          Image($r('app.media.ic_search'))
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
            .draggable(false)
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#33000000')
        .border({ width: 1, color: '#40FFFFFF' })
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

      BrowseGrid({
        libraryId: this.activeId,
        refreshKey: this.refreshKey,
        tabInset: TAB_SAFE
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
