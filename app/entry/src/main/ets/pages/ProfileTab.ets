import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { StatsInfo } from '../common/Types';
import { BuildConfig } from '../common/BuildConfig';
import { UpdateWatch } from '../common/UpdateWatch';
import { NavBarWatch } from '../common/NavBarWatch';

@Component
export struct ProfileTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  @State serverLabel: string = '';
  @State appVersion: string = '';
  /**
   * 静默检测结果（`common/UpdateWatch.ets` 写，这里只读）。
   * 两个红点分别代表：客户端有新包 / 服务端有新版本 —— 两者都能升的时候才是「两个」。
   */
  @StorageProp('update_dot_client') dotClient: boolean = false;
  @StorageProp('update_dot_server') dotServer: boolean = false;
  @StorageProp('update_ver_client') verClient: string = '';
  @StorageProp('update_ver_server') verServer: string = '';
  /** 主滚动区的控制器：底栏自动收起要用绝对偏移判断方向（见 HomeTab 同名注释）。 */
  private sc: Scroller = new Scroller();

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

  /**
   * 首屏那两格（观看记录 / 稍后再看）。
   *
   * 只有「观看记录」有数字（`stats.history`，和「我的内容」里那个「看过」是同一份数据）；
   * 「稍后再看」没有计数接口，就写一句用途，别硬编一个数字。
   */
  @Builder
  QuickCell(glyph: string, kind: string, title: string, action: () => void) {
    Column({ space: 3 }) {
      Text(glyph)
        .fontSize(16)
        .fontColor(Theme.ACCENT)
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Text(kind === 'history' ? `${this.stats.history} 条 · 可续播` : '想看的先记一下')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
    }
    .layoutWeight(1)
    .height(84)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      action();
    })
  }

  /** 会变的 desc 也在这里拼，别从外面传值进来。 */
  private rowDesc(kind: string, fallback: string): string {
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
    .padding({ left: Theme.G_L, right: Theme.G_L, top: 10, bottom: 10 })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.R_CARD)
    .border({ width: 1, color: Theme.STROKE })
    .onClick(() => {
      action();
    })
  }

  /** 一个小圆点（红点 / 橙点）。空 Row 画点最省事，不会带进文字基线。 */
  @Builder
  Dot(size: number, color: string) {
    Row()
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .backgroundColor(color)
  }

  /**
   * 「我的」右上角的更新入口（2026-11-14）。
   *
   * 只有检测到更新才出现：左点 = 客户端有新包（红），右点 = 服务端有新版本（橙、略小）。
   * 点它弹菜单，给用户两条路：去更新 / **本次更新不提醒**（记下当前这组版本号，
   * 下次真出了更新的版本仍会提示，不会一按就永久失聪）。
   */
  @Builder
  UpdateEntry() {
    Row({ space: 7 }) {
      Row({ space: 3 }) {
        if (this.dotClient) {
          this.Dot(9, '#FF3B30')
        }
        if (this.dotServer) {
          this.Dot(7, '#FF9F0A')
        }
      }
      Text('更新')
        .fontSize(12)
        .fontColor(Theme.TEXT)
    }
    .padding({ left: 11, right: 12, top: 6, bottom: 6 })
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(Theme.R_PILL)
    .border({ width: 1, color: Theme.STROKE })
    .bindMenu([
      {
        value: this.verClient.length > 0 ? `去更新（${this.verClient}）` : '去更新',
        action: () => {
          router.pushUrl({ url: 'pages/UpdatePage' });
        }
      },
      {
        value: this.verServer.length > 0 ? `服务端新版 ${this.verServer}，看说明` : '看更新说明',
        action: () => {
          router.pushUrl({ url: 'pages/UpdatePage' });
        }
      },
      {
        value: '本次更新不提醒',
        action: () => {
          UpdateWatch.mute();
        }
      }
    ])
  }

  build() {
    Scroll(this.sc) {
      Column({ space: 12 }) {
        Row() {
          Text('我的')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
          Blank()
          if (this.dotClient || this.dotServer) {
            this.UpdateEntry()
          }
        }
        .width('100%')
        .padding({ top: 8 + this.topInset })

        // 2026-11-15 用户重排：原来这三个数字（收藏 / 看过 / 库内条目）搬进「我的内容」，
        // 这个位置让给**每天都会点**的两项：观看记录、稍后再看。
        // 数字口径与接口都没动，只是换了展示位置（在 MyContentPage 里）。
        Row() {
          this.QuickCell('▶', 'history', '观看记录', () => {
            router.pushUrl({ url: 'pages/HistoryPage' });
          })
          Divider()
            .vertical(true)
            .height(38)
            .strokeWidth(1)
            .color(Theme.CARD_HI)
          this.QuickCell('◷', 'later', '稍后再看', () => {
            router.pushUrl({ url: 'pages/WatchLaterPage' });
          })
        }
        .width('100%')
        .backgroundColor(Theme.CARD)
        .borderRadius(Theme.R_CARD)
        .border({ width: 1, color: Theme.STROKE })
        .clip(true)

        Column({ space: 10 }) {
          // 2026-11-15：评价 / 弹幕 / 截帧 / 统计 / 夯到拉 / 喜爱 + 三个数字统一收进这一页，
          // 首屏只留高频入口。原来那 6 行是这一页最长的一段。
          this.MenuRow('▦', '我的内容', '收藏、看过、库内条目 + 评价 / 弹幕 / 截帧 / 统计 / 夯到拉 / 喜爱', 'static', () => {
            router.pushUrl({ url: 'pages/MyContentPage' });
          })
          this.MenuRow('▤', '网页管理', '刮削、入库、任务队列', 'static', () => {
            router.pushUrl({ url: 'pages/WebPage' });
          })
          // 播放器仍在「设置」里（2026-11-11 去重）；「关于」2.6.1.7 起改成这一行入口。
          this.MenuRow('⚙', '设置', '', 'server', () => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
          // 2.6.1.7：「关于 Amane / 检查更新 / 更新日志」三项原来压在设置的最末一组，
          // 找不到；这里给一行明确入口，进去就是那三项（设置里那一组已移除）。
          this.MenuRow('ⓘ', '关于', '版本、检查更新、更新日志', 'static', () => {
            router.pushUrl({ url: 'pages/AboutHubPage' });
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
        .padding({ top: 10, bottom: Theme.BOTTOM_SAFE })
        .onClick(() => {
          router.pushUrl({ url: 'pages/AboutPage' });
        })
      }
      .width('100%')
      // 84 不够：「设置」是这一页最后一行，会被底部浮动胶囊栏压住一半（点不利索）。
      // 统一用 Theme.BOTTOM_SAFE（TabBar + 手势条 + 余量），收藏页当初就是同一个坑。
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      // Scroll 会把内容竖向居中，撑满最小高度才能贴顶
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      // 往下看收起底栏、往回划弹回来（2026-11-15，学 piliplus）
      .onScroll((x: number, y: number) => {
        NavBarWatch.onOffset(this.sc.currentOffset().yOffset);
      })
      .backgroundColor(Theme.BG)
  }
}
