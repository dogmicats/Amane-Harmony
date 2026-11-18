import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';

/**
 * 「关于」聚合页（2.6.1.7）。
 *
 * 原来「关于 Amane / 检查更新 / 更新日志」三行压在「我的 → 设置 → 关于」的最末一组，
 * 想看一眼版本得先想「设置里有没有」，用户找不到。现在「我的」页直接给一行「关于」，
 * 进来就是这三项；设置页那一组已移除，避免同一个东西两处入口。
 */

interface AboutRow {
  glyph: string;
  title: string;
  desc: string;
  url: string;
}

const ROWS: AboutRow[] = [
  { glyph: 'ⓘ', title: '关于 Amane', desc: '版本、运行环境、许可与项目信息', url: 'pages/AboutPage' },
  { glyph: '↑', title: '检查更新', desc: '看客户端与服务端有没有新版，下载新包并校验', url: 'pages/UpdatePage' },
  { glyph: '≡', title: '更新日志', desc: '每个版本改了什么', url: 'pages/ChangelogPage' }
];

@Entry
@Component
struct AboutHubPage {
  @Builder
  EntryRow(r: AboutRow) {
    Row({ space: 12 }) {
      Text(r.glyph)
        .fontSize(16)
        .fontColor(Theme.ACCENT)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(17)
      Column({ space: 2 }) {
        Text(r.title)
          .fontSize(14)
          .fontColor(Theme.TEXT)
        Text(r.desc)
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
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
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

  build() {
    Navigation(this.navStack) {
      Column({ space: 14 }) {

        Scroll() {
          Column({ space: 12 }) {

          // 六十改：标题栏浮在内容之上 —— 首屏落在玻璃下方，一滚动就从玻璃底下穿过去，
          // 材质才有颜色可采样。
          Blank().height(this.barH())
            // 标识：图标 + 名字 + 版本，一眼确认装的是哪一版（与「关于应用」页同一套口径）
            Column({ space: 6 }) {
              Image($r('app.media.startIcon'))
                .width(56)
                .height(56)
                .borderRadius(14)
                .objectFit(ImageFit.Contain)
              Text('Amane')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.TEXT)
              Text(`v${BuildConfig.APP_VERSION} · ${BuildConfig.CHANNEL === 'self' ? '自用版' : '公开版'}`)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })

            ForEach(ROWS, (r: AboutRow) => {
              this.EntryRow(r)
            }, (r: AboutRow) => r.url)

            Text('这个应用只做「自己服务器上已有媒体的浏览与播放」，不含任何内容源，也不提供下载。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ top: 6, bottom: 10 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}