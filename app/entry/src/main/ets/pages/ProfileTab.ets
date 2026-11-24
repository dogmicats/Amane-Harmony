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
import { GlassBox, PageTitle } from '../view/GlassKit';
import { SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider } from '../view/SettingsKit';

@Component
export struct ProfileTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State stats: StatsInfo = { favorites: 0, history: 0, finished: 0, library_items: 0 };
  @State serverHost: string = '';
  @State appVersion: string = '';
  /**
   * 静默检测结果（`common/UpdateWatch.ets` 写，这里只读）。
   * 两个红点分别代表：客户端有新包 / 服务端有新版本。
   */
  @StorageProp('update_dot_client') dotClient: boolean = false;
  @StorageProp('update_dot_server') dotServer: boolean = false;
  @StorageProp('update_ver_client') verClient: string = '';
  @StorageProp('update_ver_server') verServer: string = '';
  /** 导航栈（五十七改）：整页套 Navigation 只为拿到标题栏这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();
  private sc: Scroller = new Scroller();

  /** 版本号从包信息读，别手写，省得发版忘了改。 */
  private readVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] version: ${e.code} ${e.message}`);
      return BuildConfig.APP_VERSION;
    }
  }

  /** 短版本号（去掉 `-dev-fe-...` 后缀，放在身份卡胶囊里更利落）。 */
  private shortVer(): string {
    const raw: string = this.appVersion.length > 0 ? this.appVersion : BuildConfig.APP_VERSION;
    const dash: number = raw.indexOf('-');
    const clean: string = dash > 0 ? raw.substring(0, dash) : raw;
    const parts: string[] = clean.split('.');
    if (parts.length >= 3) {
      return `v${parts[0]}.${parts[1]}.${parts[2]}`;
    }
    return `v${clean}`;
  }

  aboutToAppear(): void {
    this.appVersion = this.readVersion();
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.serverHost = Store.I.amane.replace('http://', '').replace('https://', '');
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/stats`, Store.I.token);
      this.stats = JSON.parse(text) as StatsInfo;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats: ${e.code} ${e.message}`);
    }
  }

  /** 顶部私人影院身份卡：应用图标 + 连接状态 + 版本胶囊。 */
  @Builder
  IdentityCard() {
    Row({ space: 12 }) {
      Image($r('app.media.startIcon'))
        .width(46)
        .height(46)
        .borderRadius(13)
        .objectFit(ImageFit.Contain)
        .backgroundColor(Theme.accentAlpha(0.10))
        .border({ width: 0.75, color: Theme.inkAlpha(0.32) })

      Column({ space: 4 }) {
        Text('Amane 私人影院')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .maxLines(1)
        Row({ space: 6 }) {
          Row()
            .width(7)
            .height(7)
            .borderRadius(3.5)
            .backgroundColor(Store.I.onWan ? '#F4C97E' : '#45B075')
          Text(`${Store.I.onWan ? '外网已连接' : '局域网已连接'} · ${this.serverHost}`)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .fontFeature('"tnum" 1')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.shortVer())
        .fontSize(10.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
        .fontFeature('"tnum" 1')
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .backgroundColor('#14FFFFFF')
        .border({ width: 0.5, color: '#24FFFFFF' })
        .borderRadius(Theme.R_PILL)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 135,
      colors: [[Theme.accentAlpha(0.12), 0.0], ['#00000000', 0.65]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
    .onClick(() => {
      router.pushUrl({ url: 'pages/SettingsConnectionPage' });
    })
  }

  /** 高频 Bento 双磁贴（观看记录 / 稍后再看）。 */
  @Builder
  BentoTile(icon: Resource, kind: string, title: string, action: () => void) {
    Column({ space: 12 }) {
      Row() {
        SettingsIconTile({ icon: icon, tileSize: 36, iconSize: 17 })
        Blank()
        SettingsChevron({ glyphSize: 13 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .maxLines(1)
        Text(kind === 'history' ? `${this.stats.history} 条 · 可续播` : '想看的先记一下')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .fontFeature('"tnum" 1')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .layoutWeight(1)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 145,
      colors: [[Theme.accentAlpha(0.08), 0.0], ['#00000000', 0.62]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
    .onClick(() => {
      action();
    })
  }

  /** 分组黑曜石卡内的单行菜单。 */
  @Builder
  GroupRow(icon: Resource, title: string, desc: string, badge: string, action: () => void) {
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

      if (badge.length > 0) {
        Text(badge)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .margin({ right: 2 })
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
  Dot(size: number, color: string) {
    Row()
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .backgroundColor(color)
  }

  /** 「我的」右上角的更新入口：仅检测到更新时出现。 */
  @Builder
  UpdateEntry() {
    Row({ space: 6 }) {
      Text('更新')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Row({ space: 3 }) {
        if (this.dotClient) {
          this.Dot(7, '#FF453A')
        }
        if (this.dotServer) {
          this.Dot(6, '#FF9F0A')
        }
      }
    }
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .backgroundColor('#1AFFFFFF')
    .borderRadius(Theme.R_PILL)
    .border({ width: 0.75, color: '#2EFFFFFF' })
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

  @Builder
  Header() {
    Row({ space: 8 }) {
      GlassBox({ radius: 23, padH: 15, padV: 9, mat: true }) {
        PageTitle({ text: '我的' })
      }
      Blank()
      if (this.dotClient || this.dotServer) {
        this.UpdateEntry()
      }
    }
    .width('100%')
    .height(46)
    .alignItems(VerticalAlign.Center)
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleShell();
      },
      height: this.barH()
    };
  }

  @Builder
  TitleShell() {
    Column() {
      this.Header()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset, left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
  }

  private barH(): number {
    return this.topInset + 46;
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        Scroll(this.sc) {
          Column({ space: 14 }) {
            Blank().height(this.barH() + 8)

            // 私人影院身份卡
            this.IdentityCard()

            // 高频双磁贴（观看记录 / 稍后再看）
            Row({ space: 12 }) {
              this.BentoTile($r('sys.symbol.arrow_counterclockwise_clock'), 'history', '观看记录', () => {
                router.pushUrl({ url: 'pages/HistoryPage' });
              })
              this.BentoTile($r('sys.symbol.bookmark'), 'later', '稍后再看', () => {
                router.pushUrl({ url: 'pages/WatchLaterPage' });
              })
            }
            .width('100%')

            // 统一分组黑曜石卡：4 大主入口齐聚一张卡
            Column() {
              this.GroupRow($r('sys.symbol.square_grid_2x2'), '我的内容', '收藏、统计、夯到拉、评价与截帧', '', () => {
                router.pushUrl({ url: 'pages/MyContentPage' });
              })
              SettingsRowDivider()
              this.GroupRow($r('sys.symbol.doc_text'), '网页管理', '刮削、入库与任务队列', '', () => {
                router.pushUrl({ url: 'pages/WebPage' });
              })
              SettingsRowDivider()
              this.GroupRow(
                $r('sys.symbol.gearshape'),
                '设置',
                '连接、外观、播放与存储',
                Theme.paletteOf(Theme.paletteKey).name,
                () => {
                  router.pushUrl({ url: 'pages/SettingsPage' });
                }
              )
              SettingsRowDivider()
              this.GroupRow($r('sys.symbol.info_circle'), '关于', '版本、检查更新与日志', '', () => {
                router.pushUrl({ url: 'pages/AboutHubPage' });
              })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            Column({ space: 4 }) {
              Text(`Amane for HarmonyOS · ${this.appVersion}`)
                .fontSize(10.5)
                .fontColor(Theme.TEXT_FAINT)
                .fontFeature('"tnum" 1')
            }
            .width('100%')
            .padding({ top: 8, bottom: Theme.BOTTOM_SAFE })
            .onClick(() => {
              router.pushUrl({ url: 'pages/AboutPage' });
            })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll((x: number, y: number) => {
          NavBarWatch.onOffset(this.sc.currentOffset().yOffset);
        })
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
