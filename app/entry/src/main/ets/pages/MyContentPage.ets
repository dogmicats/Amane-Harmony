import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { StatsInfo } from '../common/Types';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';

/** Tier 图历史只取 total（副标题用），不解析条目。 */
interface TierListData2 {
  total: number;
}

interface TierListRes2 {
  ok: boolean;
  data: TierListData2;
}

/**
 * 我的内容（2026-11-15 用户要求新建）。
 *
 * 为什么单开一页：「我的」原来一屏堆了 11 行 + 三个数字，其中一半是低频入口
 * （评价/弹幕/截帧/统计/夯到拉/喜爱）。用户的原话是「全部放到一个菜单里」，
 * 让首屏只留每天会点的东西（观看记录 / 稍后再看 / 设置）。
 *
 * 归属说明：
 *  - 收藏 / 看过 / 库内条目 这三个数字从「我的」首屏搬到这里，**口径与接口都没变**
 *    （`/api/user/stats` 的 favorites / history / library_items）。
 *  - 「看过」的数字点和外面「观看记录」是同一份数据，这里只做展示，不再单独给入口。
 */
@Entry
@Component
struct MyContentPage {
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  /** Tier 图存过几张（-1 = 还没问到；老服务端不问，保持 0 显示默认文案）。 */
  @State tierCount: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/stats`, Store.I.token);
      this.stats = JSON.parse(text) as StatsInfo;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] content stats: ${e.code} ${e.message}`);
    }
    this.loadTierCount();
  }

  /** 只取 total（limit=1）；老服务端 404 就保持 -1，副标题退回默认文案。 */
  private async loadTierCount(): Promise<void> {
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/tier/snapshots?limit=1`, Store.I.token);
      const res: TierListRes2 = JSON.parse(raw) as TierListRes2;
      if (res.data !== undefined && res.data !== null) {
        this.tierCount = res.data.total === undefined || res.data.total === null
          ? 0 : Number(res.data.total);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] content tier count: ${e.code} ${e.message}`);
      this.tierCount = -1;
    }
  }

  /** 数字在 builder 内部读 this.stats（@Builder 按值传参不刷新，这里只传 kind）。 */
  private statValue(kind: string): string {
    if (kind === 'favorites') {
      return `${this.stats.favorites}`;
    }
    if (kind === 'history') {
      return `${this.stats.history}`;
    }
    return `${this.stats.library_items}`;
  }

  private tierDesc(): string {
    if (this.tierCount > 0) {
      return `存了 ${this.tierCount} 张，点开切换统计页展示哪张`;
    }
    return this.tierCount < 0 ? '按星级排的 Tier 图：生成、看图、下到相册' : '还没存过，先从统计页生成一张';
  }

  @Builder
  StatCell(kind: string, label: string) {
    Column({ space: 4 }) {
      Text(this.statValue(kind))
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
      Text(label)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  MenuRow(glyph: string, title: string, desc: string, action: () => void) {
    Row({ space: 12 }) {
      Text(glyph)
        .fontSize(16)
        .fontColor(Theme.ACCENT)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(17)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT)
        Text(desc)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(16)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: Theme.G_L, right: Theme.G_L, top: 10, bottom: 10 })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.R_CARD)
    .border({ width: 1, color: Theme.STROKE })
    .onClick(() => {
      action();
    })
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
          router.back();
          }
        })
        PageTitle({ text: '我的内容', fs: 18 })
        Blank()
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
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

        Scroll() {
          Column({ space: 12 }) {

          // 六十改：标题栏浮在内容之上 —— 首屏落在玻璃下方，一滚动就从玻璃底下穿过去，
          // 材质才有颜色可采样。
          Blank().height(this.barH())
            // 三个数字（原来在「我的」首屏那张卡里，整体搬过来，口径没变）
            Row() {
              this.StatCell('favorites', '收藏')
              Divider()
                .vertical(true)
                .height(26)
                .strokeWidth(1)
                .color(Theme.CARD_HI)
              this.StatCell('history', '看过')
              Divider()
                .vertical(true)
                .height(26)
                .strokeWidth(1)
                .color(Theme.CARD_HI)
              this.StatCell('library', '库内条目')
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.R_CARD)
            .border({ width: 1, color: Theme.STROKE })
            .clip(true)

            Column({ space: 10 }) {
              this.MenuRow('✎', '我的评价', '写过的短评，按时间排', () => {
                router.pushUrl({ url: 'pages/MyCommentsPage' });
              })
              this.MenuRow('⌗', '我的弹幕', '播放时发的时间点，点一条回到那里', () => {
                router.pushUrl({ url: 'pages/MyAnnotationsPage' });
              })
              this.MenuRow('◎', '我的截帧', '我截的关键帧：看、跳、删', () => {
                router.pushUrl({ url: 'pages/FramePicksPage' });
              })
              this.MenuRow('▦', '观看统计', '看多少、什么时候看、最热哪段、偏谁', () => {
                router.pushUrl({ url: 'pages/StatsPage' });
              })
              // 直接进「从夯到拉」主页面（配置 + 当前图 + 历史 + 下载都在那一页）
              this.MenuRow('▤', '从夯到拉', this.tierDesc(), () => {
                router.pushUrl({ url: 'pages/TierPage' });
              })
              // 刷一刷的「喜爱」：措辞避开「收藏」二字，那是服务端的影片收藏
              this.MenuRow('♡', '我的喜爱', '刷一刷里点过心的片段（和「收藏」无关）', () => {
                router.pushUrl({ url: 'pages/MyLikedShortsPage' });
              })
            }
            .width('100%')

            Text('「收藏」「看过」「库内条目」只是数字；观看记录和稍后再看留在「我的」首屏。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
              .padding({ left: 4, right: 4 })

            Blank().height(Theme.BOTTOM_SAFE)
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .width('100%')
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
