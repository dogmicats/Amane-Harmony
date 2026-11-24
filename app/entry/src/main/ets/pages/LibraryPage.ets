import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { Theme } from '../common/Theme';
import { BrowseParams } from '../common/Types';
import { BrowseGrid } from '../view/BrowseGrid';
import { GlassBack, GlassCapsule } from '../view/GlassKit';
import { GachaSwitch } from '../ext/stills/GachaSwitch';
import { BuildConfig } from '../common/BuildConfig';

/** 某个媒体库的完整列表页（从首页「全部 ›」进来）。 */
@Entry
@Component
struct LibraryPage {
  @State title: string = '媒体库';
  @State libraryId: number = 0;
  /** 只看某个清单的片（2.5.5.25，从清单页 / 详情页跳进来）。 */
  @State collectionId: number = 0;
  /** 详情页点演员「N 岁」进来时预置的年龄分桶 / 排序 / 性别。 */
  @State ageBand: string = '';
  @State sort: string = '';
  @State ageGender: string = '';
  @State ready: boolean = false;
  /** 抽卡开关（2026-11-17）：BrowseGrid 改成 @Link 后，父组件必须持有这个状态。 */
  @State gachaOn: boolean = false;
  /** 排序/筛选面板开关（2026-11-17）：BrowseGrid 改成 @Link 后由父组件持有。 */
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  /** 七十二改：顶栏要显示「排依据 / 筛选是否生效」，由 BrowseGrid 回调上报。 */
  @State sortText: string = '';
  @State sortCustom: boolean = false;
  @State filterOn: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as BrowseParams;
    if (params !== undefined && params !== null) {
      this.libraryId = params.libraryId === undefined ? 0 : params.libraryId;
      this.collectionId = params.collectionId === undefined ? 0 : params.collectionId;
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

  @Builder
  TitleBar() {
    // 七十二改：与媒体库 Tab 同一套 —— 顶栏只留「返回球 + 库名 + 排序 + 筛选 + 抽卡」，
    // 搜索/工具条一律不画（`leanMode`），内容交给 `headerTopPad` 让位。
    Column() {
      Row({ space: 8 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        // 五十九改：标题与基底同规格（18 Bold / 白 / 暗投影）。
        // 这页不能用 `PageTitle`：库名可能很长，必须保留 ellipsis + layoutWeight。
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        GlassCapsule({
          label: `⇅ ${this.sortCustom ? this.sortText : '排序'}`,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          maxW: 100,
          active: this.sortCustom,
          mat: true,
          onTap: () => {
            this.showSort = true;
          }
        })
        GlassCapsule({
          label: this.filterOn ? '筛选 ·' : '筛选',
          active: this.filterOn,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          mat: true,
          onTap: () => {
            this.showFilter = true;
          }
        })
        if (BuildConfig.ENABLE_GACHA) {
          GachaSwitch({
            mat: true,
            on: this.gachaOn,
            onToggle: (v: boolean) => {
              this.gachaOn = v;
            }
          })
        }
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 10, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset - 8 })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  /** 真·全屏（七十二改）：窗口铺到系统栏后面；离开本页不关，见 common/PageFullscreen。 */
  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Column() {

        if (this.ready) {
          // 七十二改：`leanMode` = 内部不再画搜索框 / 工具条（那两条不透明底会把海报挡住），
          // 让位交给 `headerTopPad`（**滚动区内边距**，一滑就跟着走，海报才钻得到玻璃底下）。
          BrowseGrid({
            libraryId: this.libraryId,
            collectionId: this.collectionId,
            refreshKey: 0,
            initialAgeBand: this.ageBand,
            initialSort: this.sort,
            initialAgeGender: this.ageGender,
            tabInset: 0,
            leanMode: true,
            headerTopPad: this.barH() + 4,
            gachaTopPad: this.barH() + 4,
            gachaOn: $gachaOn,
            showSort: $showSort,
            showFilter: $showFilter,
            onFilterChange: (n: number) => {
              this.filterOn = n > 0;
            },
            onSortChange: (label: string, isDefault: boolean) => {
              this.sortText = label;
              this.sortCustom = !isDefault;
            }
          })
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
