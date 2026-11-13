import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

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

  build() {
    Column({ space: 14 }) {
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
        Text('关于')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 4 })

      Scroll() {
        Column({ space: 12 }) {
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
}
