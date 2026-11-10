import { router, promptAction } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo, pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { httpGet, probe } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

/** 关于页：版本 / 运行环境 / 当前连的服务端 / 链接与致谢。 */

interface PingResp {
  ok: boolean;
  version: string;
}

interface LinkRow {
  title: string;
  desc: string;
  url: string;
}

@Entry
@Component
struct AboutPage {
  @State appVersion: string = BuildConfig.APP_VERSION;
  @State appCode: string = '';
  @State bundleName: string = '';
  @State serverVersion: string = '';
  @State serverState: string = '检测中…';
  @State serverColor: string = '#A3A3AE';

  aboutToAppear(): void {
    this.readBundle();
    this.ping();
  }

  private readBundle(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
      this.appCode = `${info.versionCode}`;
      this.bundleName = info.name;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] bundle info: ${e.code} ${e.message}`);
    }
  }

  private async ping(): Promise<void> {
    const url: string = `${Store.I.user}/api/user/ping`;
    // 先用 probe 定生死：它自带超时兜底，底层请求挂住也不会让状态停在「检测中」
    const alive: boolean = await probe(url, 5000);
    if (!alive) {
      this.serverState = '连不上';
      this.serverColor = '#FFB454';
      return;
    }
    // 先落地「在线」，版本号只是锦上添花 —— 拿不到版本不该让整块卡在「检测中」
    this.serverState = '在线';
    this.serverColor = '#8BD9A0';
    try {
      const text: string = await httpGet(url, Store.I.token);
      const resp = JSON.parse(text) as PingResp;
      this.serverVersion = resp.version;
      this.serverState = `在线 · v${resp.version}`;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] about ping: ${e.code} ${e.message}`);
    }
  }

  private async copy(text: string, tip: string): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: tip, duration: 1600 });
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] copy: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '复制失败', duration: 1600 });
    }
  }

  private versionLine(): string {
    const srv: string = this.serverVersion.length > 0 ? `v${this.serverVersion}` : '未知';
    return `Amane for HarmonyOS ${this.appVersion} (${this.appCode}) · ${BuildConfig.CHANNEL}\n`
      + `构建 ${BuildConfig.BUILD_TIME}\n`
      + `服务端 ${srv}（需 ≥ ${BuildConfig.MIN_SERVER}）\n`
      + `设备 ${deviceInfo.productModel} · HarmonyOS ${deviceInfo.osFullName}\n`
      + `连接 ${Store.I.onWan ? '外网' : '局域网'} ${Store.I.amane}`;
  }

  /** 会变的值必须在 builder 内部读 this，按值传进去的永远不会刷新。 */
  private factValue(kind: string): string {
    if (kind === 'state') {
      return this.serverState;
    }
    if (kind === 'min') {
      return `v${BuildConfig.MIN_SERVER}`;
    }
    if (kind === 'mode') {
      return Store.I.onWan ? '外网' : '局域网';
    }
    if (kind === 'addr') {
      return Store.I.amane.replace('http://', '').replace('https://', '');
    }
    if (kind === 'device') {
      return deviceInfo.productModel;
    }
    if (kind === 'system') {
      return `HarmonyOS ${deviceInfo.osFullName}`;
    }
    if (kind === 'bundle') {
      return this.bundleName;
    }
    // 并行会话可能各出一个同号包，附上构建时间才认得出手里这个是哪一次编的
    return `${this.appVersion} (${this.appCode}) · 构建 ${BuildConfig.BUILD_TIME}`;
  }

  private factColor(kind: string): string {
    return kind === 'state' ? this.serverColor : Theme.TEXT;
  }

  @Builder
  FactRow(kind: string, label: string, last: boolean) {
    Column() {
      Row({ space: 10 }) {
        Text(label)
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
        Blank()
        Text(this.factValue(kind))
          .fontSize(12)
          .fontColor(this.factColor(kind))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      if (!last) {
        Divider().color(Theme.CARD_HI)
      }
    }
    .width('100%')
  }

  @Builder
  Section(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_DIM)
      .width('100%')
      .margin({ top: 6, bottom: 2 })
  }

  @Builder
  LinkItem(row: LinkRow, last: boolean) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text(row.title)
            .fontSize(13)
            .fontColor(Theme.TEXT)
          Text(row.desc)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('复制')
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(8)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.copy(row.url, '链接已复制');
      })
      if (!last) {
        Divider().color(Theme.CARD_HI)
      }
    }
    .width('100%')
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
        Text('关于应用')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 4 })

      Scroll() {
        Column({ space: 12 }) {
          // 标识区
          Column({ space: 8 }) {
            Image($r('app.media.startIcon'))
              .width(64)
              .height(64)
              .borderRadius(16)
              .objectFit(ImageFit.Contain)
            Text('Amane')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            Text('HarmonyOS 客户端 · 自建媒体库')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
            Row({ space: 6 }) {
              Text(`v${this.appVersion}`)
                .fontSize(10)
                .fontColor('#FFFFFF')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
              Text(BuildConfig.CHANNEL === 'self' ? '自用版' : '公开版')
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
              Text(`code ${this.appCode}`)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
            }
          }
          .width('100%')
          .padding({ top: 14, bottom: 10 })

          // 运行环境
          this.Section('运行环境')
          Column() {
            this.FactRow('device', '设备', false)
            this.FactRow('system', '系统', false)
            this.FactRow('bundle', '包名', false)
            this.FactRow('appver', '应用版本', true)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 服务端
          this.Section('服务端')
          Column() {
            this.FactRow('state', '状态', false)
            this.FactRow('min', '最低要求', false)
            this.FactRow('mode', '连接方式', false)
            this.FactRow('addr', '地址', true)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })

          // 链接
          this.Section('链接')
          Column() {
            this.LinkItem({
              title: '项目主页',
              desc: 'github.com/dogmicats/Amane-Harmony',
              url: 'https://github.com/dogmicats/Amane-Harmony'
            }, false)
            this.LinkItem({
              title: '问题反馈',
              desc: 'github.com/dogmicats/Amane-Harmony/issues',
              url: 'https://github.com/dogmicats/Amane-Harmony/issues'
            }, true)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 致谢
          this.Section('开源与致谢')
          Column({ space: 8 }) {
            Text('界面与播放基于 HarmonyOS ArkUI 与 libmpv；媒体库服务端上游为 sqzw-x/amane（GPL-3.0），本客户端以 MIT 协议发布。')
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
              .lineHeight(17)
              .width('100%')
            Text('这个应用只做「自己服务器上已有媒体的浏览与播放」，不含任何内容源，也不提供下载。')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .lineHeight(17)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          Button('复制版本信息')
            .width('100%')
            .height(40)
            .backgroundColor(Theme.CARD_HI)
            .fontColor(Theme.TEXT)
            .fontSize(13)
            .margin({ top: 4 })
            .onClick(() => {
              this.copy(this.versionLine(), '版本信息已复制');
            })

          Text('© 2026 dogmicats')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 6, bottom: 24 })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
