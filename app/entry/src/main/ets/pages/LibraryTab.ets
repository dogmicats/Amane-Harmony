import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { LibraryInfo } from '../common/Types';
import { BrowseGrid, TAB_SAFE } from '../view/BrowseGrid';

/** 媒体库 Tab：顶部库切换（**可多选**）+ 浏览网格（排序/筛选在 BrowseGrid 里）。 */
@Component
export struct LibraryTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State libs: LibraryInfo[] = Store.I.libraries;
  /**
   * 选中的库。空数组 = 全部（2026-11-15 用户要求多选：
   * 「让用户可以筛选同时出现在哪些媒体库的内容」，所以多选是 AND，不是并集）。
   */
  @State activeIds: number[] = [];
  /**
   * 上半屏横滑（2026-11-15）：Index 在 `onContentWillChange` 里拦下这次翻页，
   * 把「哪个页面该往哪走」写进这个 AppStorage 键 —— 形如 `lib|1|时间戳`。
   */
  @StorageProp('inPageSwipe') @Watch('onInPageSwipe') inPageSwipe: string = '';
  private lastSwipe: string = '';

  aboutToAppear(): void {
    this.libs = Store.I.libraries;
  }

  onRefresh(): void {
    this.libs = Store.I.libraries;
  }

  /**
   * 点库 chip：切换这一个库的选中状态。
   * 点「全部」= 清空；再点已选中的最后一个也回到「全部」——
   * 否则会出现「一个都不选但看起来选了库」的歧义态。
   */
  private toggleLibrary(id: number): void {
    if (id <= 0) {
      this.activeIds = [];
      return;
    }
    const next: number[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.activeIds.length; i++) {
      const v: number = this.activeIds[i];
      if (v === id) {
        hit = true;
      } else {
        next.push(v);
      }
    }
    if (!hit) {
      next.push(id);
    }
    this.activeIds = next;
  }

  private isActive(id: number): boolean {
    if (id <= 0) {
      return this.activeIds.length === 0;
    }
    return this.activeIds.indexOf(id) >= 0;
  }

  /** Index 拦下翻页后发来的「切库」指令。 */
  onInPageSwipe(): void {
    const raw: string = this.inPageSwipe;
    if (raw.length === 0 || raw === this.lastSwipe) {
      return;
    }
    this.lastSwipe = raw;
    const parts: string[] = raw.split('|');
    if (parts.length < 2 || parts[0] !== 'lib') {
      return;
    }
    const dir: number = Number(parts[1]);
    if (dir === 1 || dir === -1) {
      this.swipeLibrary(dir);
    }
  }

  /**
   * 上半屏横滑 = 切库（2026-11-15）。多选时以「最后选中的那个库」为锚点往前后走，
   * 滑完回到单选 —— 滑动本质是「翻看下一个库」，不是继续加选。
   */
  private swipeLibrary(dir: number): void {
    const ids: number[] = [0];
    for (let i = 0; i < this.libs.length; i++) {
      ids.push(this.libs[i].id);
    }
    const anchor: number = this.activeIds.length > 0 ? this.activeIds[this.activeIds.length - 1] : 0;
    let at: number = ids.indexOf(anchor);
    if (at < 0) {
      at = 0;
    }
    const next: number = at + dir;
    if (next < 0 || next >= ids.length) {
      return;
    }
    const target: number = ids[next];
    this.activeIds = target > 0 ? [target] : [];
  }

  @Builder
  Chip(id: number, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.isActive(id) ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.isActive(id) ? Theme.ACCENT : Theme.CARD)
      .borderRadius(Theme.R_PILL)
      // 未选中加 1px 细边：深底上纯色块会和背景糊在一起（和首页卡片同一套判据）
      .border({ width: 1, color: this.isActive(id) ? Theme.accentAlpha(0.55) : Theme.STROKE })
      .onClick(() => {
        this.toggleLibrary(id);
      })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
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
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8 + this.topInset, bottom: 8 })

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
        // 多选直接交给 @Prop 的 onExternalChange 触发重载，不用动 refreshKey
        libraryIds: this.activeIds,
        refreshKey: this.refreshKey,
        tabInset: TAB_SAFE
      })
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.BG)
  }
}
