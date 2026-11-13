import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { StatsInfo } from '../common/Types';
import { BuildConfig } from '../common/BuildConfig';

/** Tier 图历史只取 total（副标题用），不解析条目。 */
interface TierListData {
  total: number;
}

interface TierListRes {
  ok: boolean;
  data: TierListData;
}

@Component
export struct ProfileTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  /** Tier 图存过几张（-1 = 还没问到；老服务端不问，保持 0 显示默认文案）。 */
  @State tierCount: number = -1;
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
    this.loadTierCount();
  }

  /** 只取 total（limit=1），拿到几张够写菜单副标题了；老服务端 404 就保持 -1。 */
  private async loadTierCount(): Promise<void> {
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/tier/snapshots?limit=1`, Store.I.token);
      const res: TierListRes = JSON.parse(raw) as TierListRes;
      if (res.data !== undefined && res.data !== null) {
        this.tierCount = res.data.total === undefined || res.data.total === null
          ? 0 : Number(res.data.total);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] tier count: ${e.code} ${e.message}`);
      this.tierCount = -1;
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
    .height(58)
    .justifyContent(FlexAlign.Center)
  }

  /** 会变的 desc 也在这里拼，别从外面传值进来。 */
  private rowDesc(kind: string, fallback: string): string {
    if (kind === 'history') {
      return `${this.stats.history} 条，可续播`;
    }
    if (kind === 'server') {
      return this.serverLabel;
    }
    if (kind === 'tier') {
      if (this.tierCount > 0) {
        return `存了 ${this.tierCount} 张，点开切换统计页展示哪张`;
      }
      return this.tierCount < 0 ? fallback : '还没存过，先从统计页生成一张';
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

        // 三个数字并成一张卡（原来是三张独立卡：横向被两处 10 的缝切成三段，
        // 还各自带一层背景，看起来像三个互不相关的东西）。数字与含义都没变。
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
        .borderRadius(Theme.RADIUS)
        .clip(true)

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
          this.MenuRow('▦', '观看统计', '看多少、什么时候看、最热哪段、偏谁', 'static', () => {
            router.pushUrl({ url: 'pages/StatsPage' });
          })
          // 2.5.4.7：入口直接进「从夯到拉」主页面（配置 + 当前图 + 历史 + 下载都在那一页）。
          // 以前进的是 TierManagePage —— 那只是个历史列表，用户点进来根本看不到生成页。
          this.MenuRow('▤', '从夯到拉', '按星级排的 Tier 图：生成、看图、下到相册', 'tier', () => {
            router.pushUrl({ url: 'pages/TierPage' });
          })
          this.MenuRow('◷', '稍后再看', '想看的先记一下，回头再看', 'static', () => {
            router.pushUrl({ url: 'pages/WatchLaterPage' });
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
        .padding({ top: 10, bottom: 24 })
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
    .backgroundColor(Theme.BG)
  }
}
