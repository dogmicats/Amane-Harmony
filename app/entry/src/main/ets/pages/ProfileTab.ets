import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { StatsInfo } from '../common/Types';
import { BuildConfig } from '../common/BuildConfig';

@Component
export struct ProfileTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  @State serverLabel: string = '';
  @State appVersion: string = '';

  /** 版本号从包信息读，别手写，省得发版忘了改。 */
  private readVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] version: ${e.code} ${e.message}`);
      return '';
    }
  }

  aboutToAppear(): void {
    this.appVersion = this.readVersion();
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.serverLabel = (Store.I.onWan ? '外网 · ' : '局域网 · ')
      + Store.I.amane.replace('http://', '').replace('https://', '');
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/stats`, Store.I.token);
      this.stats = JSON.parse(text) as StatsInfo;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats: ${e.code} ${e.message}`);
    }
  }

  /** kind 是静态值，数字在 builder 内部读 this.stats（按值传参不会刷新）。 */
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
    .height(66)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 会变的 desc 也在这里拼，别从外面传值进来。 */
  private rowDesc(kind: string, fallback: string): string {
    if (kind === 'history') {
      return `${this.stats.history} 条，可续播`;
    }
    if (kind === 'server') {
      return this.serverLabel;
    }
    return fallback;
  }

  @Builder
  MenuRow(glyph: string, title: string, desc: string, kind: string, action: () => void) {
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
        Text(this.rowDesc(kind, desc))
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
      action();
    })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('我的')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
        }
        .width('100%')
        .padding({ top: 8 })

        Row({ space: 10 }) {
          this.StatCell('favorites', '收藏')
          this.StatCell('history', '看过')
          this.StatCell('library', '库内条目')
        }
        .width('100%')

        Column({ space: 10 }) {
          this.MenuRow('✎', '我的评价', '', 'comment', () => {
            router.pushUrl({ url: 'pages/MyCommentsPage' });
          })
          this.MenuRow('⌗', '我的弹幕', '播放时发的时间点，点一条回到那里', 'comment', () => {
            router.pushUrl({ url: 'pages/MyAnnotationsPage' });
          })
          this.MenuRow('◎', '我的截帧', '我截的关键帧：看、跳、删', 'comment', () => {
            router.pushUrl({ url: 'pages/FramePicksPage' });
          })
          this.MenuRow('▶', '观看记录', '', 'history', () => {
            router.pushUrl({ url: 'pages/HistoryPage' });
          })
          this.MenuRow('◷', '稍后再看', '想看的先记一下，回头再看', 'static', () => {
            router.pushUrl({ url: 'pages/WatchLaterPage' });
          })
          this.MenuRow('▤', '网页管理', '刮削、入库、任务队列', 'static', () => {
            router.pushUrl({ url: 'pages/WebPage' });
          })
          // 播放器 / 更新日志 / 关于 都在「设置」里，这里不再重复（2026-11-11 去重）
          this.MenuRow('⚙', '设置', '', 'server', () => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text(`Amane for HarmonyOS ${this.appVersion} · ${BuildConfig.CHANNEL} · 服务端需 ≥ ${BuildConfig.MIN_SERVER}`)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          Text(Store.I.user)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .padding({ top: 10, bottom: 24 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/AboutPage' });
        })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 84 })
      // Scroll 会把内容竖向居中，撑满最小高度才能贴顶
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Theme.BG)
  }
}
