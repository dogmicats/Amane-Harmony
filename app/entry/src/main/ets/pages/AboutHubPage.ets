import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BuildConfig } from '../common/BuildConfig';
import { PageTitle, GlassBack } from '../view/GlassKit';
import { SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider } from '../view/SettingsKit';

interface AboutRow {
  icon: Resource;
  title: string;
  desc: string;
  url: string;
}

const ROWS: AboutRow[] = [
  { icon: $r('sys.symbol.info_circle'), title: '关于 Amane', desc: '版本、运行环境与项目信息', url: 'pages/AboutPage' },
  { icon: $r('sys.symbol.arrow_clockwise'), title: '检查更新', desc: '检测客户端与服务端新版本', url: 'pages/UpdatePage' },
  { icon: $r('sys.symbol.doc_text'), title: '更新日志', desc: '各版本更新记录', url: 'pages/ChangelogPage' }
];

@Entry
@Component
struct AboutHubPage {
  @Builder
  EntryRow(r: AboutRow) {
    Row({ space: 12 }) {
      SettingsIconTile({ icon: r.icon, tileSize: 36, iconSize: 17 })
      Column({ space: 2 }) {
        Text(r.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text(r.desc)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SettingsChevron({ glyphSize: 13 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .onClick(() => {
      router.pushUrl({ url: r.url });
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
        PageTitle({ text: '关于', fs: 18 })
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
            Blank().height(this.barH() + 8)

            Column({ space: 8 }) {
              Image($r('app.media.startIcon'))
                .width(64)
                .height(64)
                .borderRadius(18)
                .objectFit(ImageFit.Contain)
                .backgroundColor(Theme.accentAlpha(0.10))
                .border({ width: 0.75, color: Theme.inkAlpha(0.32) })
              Text('Amane')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.TEXT)
              Text(`v${BuildConfig.APP_VERSION} · ${BuildConfig.CHANNEL === 'self' ? '自用版' : '公开版'}`)
                .fontSize(11)
                .fontColor(Theme.ACCENT_INK)
                .fontFeature('"tnum" 1')
                .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                .backgroundColor(Theme.accentAlpha(0.16))
                .border({ width: 0.5, color: Theme.inkAlpha(0.38) })
                .borderRadius(Theme.R_PILL)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Column() {
              ForEach(ROWS, (r: AboutRow, idx: number) => {
                Column() {
                  if (idx > 0) {
                    SettingsRowDivider()
                  }
                  this.EntryRow(r)
                }
                .width('100%')
              }, (r: AboutRow) => r.url)
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            Text('仅用于浏览与播放自有服务器上的媒体内容。')
              .fontSize(10.5)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 4, bottom: 10 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
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
