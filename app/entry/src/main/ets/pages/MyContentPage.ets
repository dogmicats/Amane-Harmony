import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { StatsInfo } from '../common/Types';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider, SettingsSectionTitle
} from '../view/SettingsKit';

/** Tier 图历史只取 total（右侧胶囊用），不解析条目。 */
interface TierListData2 {
  total: number;
}

interface TierListRes2 {
  ok: boolean;
  data: TierListData2;
}

/**
 * 我的内容：三项统计指标 + 「观影足迹」「个人沉淀」两组大圆角黑曜石卡。
 */
@Entry
@Component
struct MyContentPage {
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  /** Tier 图存过几张（-1 = 还没问到 / 老服务端）。 */
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

  private statValue(kind: string): string {
    if (kind === 'favorites') {
      return `${this.stats.favorites}`;
    }
    if (kind === 'history') {
      return `${this.stats.history}`;
    }
    return `${this.stats.library_items}`;
  }

  @Builder
  StatCell(kind: string, label: string, accent: boolean) {
    Column({ space: 4 }) {
      Text(this.statValue(kind))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(accent ? Theme.ACCENT_INK : Theme.TEXT)
        .fontFeature('"tnum" 1')
      Text(label)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
    }
    .layoutWeight(1)
    .height(74)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  MenuRow(icon: Resource, title: string, desc: string, pill: string, action: () => void) {
    Row({ space: 12 }) {
      SettingsIconTile({ icon: icon, tileSize: 36, iconSize: 17 })
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (pill === '__tier__' && this.tierCount > 0) {
        Text(`已存 ${this.tierCount} 张`)
          .fontSize(10.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .fontFeature('"tnum" 1')
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(Theme.accentAlpha(0.18))
          .border({ width: 0.5, color: Theme.inkAlpha(0.42) })
          .borderRadius(Theme.R_PILL)
      }
      SettingsChevron({ glyphSize: 13 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
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
  private navStack: NavPathStack = new NavPathStack();

  private barH(): number {
    return this.topInset + 46;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        Scroll() {
          Column({ space: 16 }) {
            Blank().height(this.barH() + 6)

            // 顶部三项指标卡
            Row() {
              this.StatCell('favorites', '收藏', false)
              Divider()
                .vertical(true)
                .height(30)
                .strokeWidth(0.5)
                .color('#1AFFFFFF')
              this.StatCell('history', '看过', false)
              Divider()
                .vertical(true)
                .height(30)
                .strokeWidth(0.5)
                .color('#1AFFFFFF')
              this.StatCell('library', '库内条目', true)
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .linearGradient({
              angle: 160,
              colors: [[Theme.accentAlpha(0.10), 0.0], ['#00000000', 0.65]]
            })
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            // 观影足迹
            Column({ space: 8 }) {
              SettingsSectionTitle({ title: '观影足迹' })
              Column() {
                this.MenuRow($r('sys.symbol.histogram'), '观看统计', '时长、热区与偏好趋势', '', () => {
                  router.pushUrl({ url: 'pages/StatsPage' });
                })
                SettingsRowDivider()
                this.MenuRow($r('sys.symbol.wand_and_stars'), '我的口味', '演员、标签与系列排行', '', () => {
                  router.pushUrl({ url: 'pages/TastePage' });
                })
                SettingsRowDivider()
                this.MenuRow($r('sys.symbol.layer'), '从夯到拉', '星级 Tier 榜单与快照', '__tier__', () => {
                  router.pushUrl({ url: 'pages/TierPage' });
                })
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)
            }
            .width('100%')

            // 个人沉淀
            Column({ space: 8 }) {
              SettingsSectionTitle({ title: '个人沉淀' })
              Column() {
                this.MenuRow($r('sys.symbol.pencil_line'), '我的评价', '写过的短评记录', '', () => {
                  router.pushUrl({ url: 'pages/MyCommentsPage' });
                })
                SettingsRowDivider()
                this.MenuRow($r('sys.symbol.message'), '我的弹幕', '播放时间点弹幕跳转', '', () => {
                  router.pushUrl({ url: 'pages/MyAnnotationsPage' });
                })
                SettingsRowDivider()
                this.MenuRow($r('sys.symbol.picture'), '我的截帧', '收藏的关键帧图库', '', () => {
                  router.pushUrl({ url: 'pages/FramePicksPage' });
                })
                SettingsRowDivider()
                this.MenuRow($r('sys.symbol.heart'), '我的喜爱', '刷一刷里点过心的片段', '', () => {
                  router.pushUrl({ url: 'pages/MyLikedShortsPage' });
                })
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)
            }
            .width('100%')

            Blank().height(Theme.pageBottomSafe())
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
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
