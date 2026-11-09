import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { probe } from '../common/Http';
import { CrashInfo, clearCrashLog, crashInfo, uploadCrashLog } from '../common/CrashReporter';
import {
  Store, normalizeBase, MODE_AUTO, MODE_LAN, MODE_WAN,
  DEFAULT_AMANE, DEFAULT_USER, DEFAULT_WAN_AMANE, DEFAULT_TOKEN
} from '../common/Store';
import { Theme } from '../common/Theme';

@Entry
@Component
struct SettingsPage {
  @State draftAmane: string = Store.I.lanAmane;
  @State draftUser: string = Store.I.lanUser;
  @State draftWan: string = Store.I.wanAmane;
  @State draftToken: string = Store.I.token;
  @State draftMode: string = Store.I.mode;
  @State testResult: string = '';
  @State testing: boolean = false;
  @State crashText: string = '';

  aboutToAppear(): void {
    this.refreshCrash();
  }

  private refreshCrash(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const info: CrashInfo = crashInfo(ctx);
    this.crashText = info.exists
      ? `崩溃日志 ${info.lines} 行 / ${info.bytes} 字符（启动后会静默上报）`
      : '暂无崩溃日志';
  }

  private async uploadCrash(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const n: number = await uploadCrashLog(ctx);
    if (n > 0) {
      this.refreshCrash();
      this.testResult = `已上报 ${n} 字符的崩溃日志`;
    } else {
      this.crashText = '没有可上报的日志，或服务不可达（本地文件已保留）';
    }
  }

  private clearCrash(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    clearCrashLog(ctx);
    this.refreshCrash();
  }

  @Builder
  Field(label: string, value: string, hint: string, onChange: (v: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      TextInput({ text: value, placeholder: hint })
        .height(42)
        .backgroundColor(Theme.CARD)
        .fontColor(Theme.TEXT)
        .fontSize(13)
        .placeholderColor(Theme.TEXT_FAINT)
        .caretColor(Theme.ACCENT)
        .onChange((v: string) => {
          onChange(v);
        })
    }
    .width('100%')
  }

  @Builder
  ModeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.draftMode === value ? '#FFFFFF' : Theme.TEXT_DIM)
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.draftMode === value ? Theme.ACCENT : Color.Transparent)
      .onClick(() => {
        this.draftMode = value;
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
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 4 })

      Scroll() {
        Column({ space: 14 }) {
          Row({ space: 6 }) {
            this.ModeChip('自动', MODE_AUTO)
            this.ModeChip('局域网', MODE_LAN)
            this.ModeChip('外网', MODE_WAN)
          }
          .width('100%')
          .padding(4)
          .backgroundColor(Theme.CARD)
          .borderRadius(12)

          Text('局域网')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .margin({ top: 4 })

          this.Field('amane 地址（媒体与播放）', this.draftAmane, DEFAULT_AMANE, (v: string) => {
            this.draftAmane = v;
          })
          this.Field('用户数据服务地址（收藏/历史）', this.draftUser, DEFAULT_USER, (v: string) => {
            this.draftUser = v;
          })

          Text('外网')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .margin({ top: 4 })

          this.Field('外网地址（一个域名搞定，代理内部已分流）', this.draftWan, DEFAULT_WAN_AMANE,
            (v: string) => {
              this.draftWan = v;
            })

          Text('API Token')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .margin({ top: 4 })
          TextInput({ text: this.draftToken })
            .height(42)
            .backgroundColor(Theme.CARD)
            .fontColor(Theme.TEXT)
            .fontSize(13)
            .caretColor(Theme.ACCENT)
            .onChange((v: string) => {
              this.draftToken = v;
            })

          Text('自动模式：启动时先探局域网（1.5 秒），连不上就走外网；回家再启动会自动切回来。外网模式下媒体和收藏共用一个域名。')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(16)

          Text(`当前使用：${Store.I.onWan ? '外网' : '局域网'} · ${Store.I.user}`)
            .fontSize(10)
            .fontColor(Store.I.onWan ? '#FFB454' : '#8BD9A0')
            .width('100%')

          if (this.testResult.length > 0) {
            Text(this.testResult)
              .fontSize(11)
              .fontColor(this.testResult.startsWith('连接正常') ? '#8BD9A0' : Theme.DANGER)
              .width('100%')
          }

          Row({ space: 10 }) {
            Button('测试连接')
              .layoutWeight(1)
              .height(42)
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(13)
              .enabled(!this.testing)
              .onClick(() => {
                this.test();
              })
            Button('保存并重连')
              .layoutWeight(1)
              .height(42)
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .margin({ top: 4 })

          Button('恢复默认地址')
            .width('100%')
            .height(38)
            .backgroundColor(Color.Transparent)
            .fontColor(Theme.TEXT_FAINT)
            .fontSize(12)
            .onClick(() => {
              this.draftAmane = DEFAULT_AMANE;
              this.draftUser = DEFAULT_USER;
              this.draftWan = DEFAULT_WAN_AMANE;
              this.draftToken = DEFAULT_TOKEN;
            })

          Text('播放器设置已经独立成页（我的 → 播放器）')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .margin({ top: 8 })

          Text('诊断')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .margin({ top: 8 })

          Column({ space: 8 }) {
            Text(this.crashText)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
            Row({ space: 8 }) {
              Button('上传崩溃日志')
                .layoutWeight(1)
                .height(36)
                .backgroundColor(Theme.CARD_HI)
                .fontColor(Theme.TEXT)
                .fontSize(12)
                .onClick(() => {
                  this.uploadCrash();
                })
              Button('清空')
                .width(80)
                .height(36)
                .backgroundColor(Color.Transparent)
                .fontColor(Theme.TEXT_FAINT)
                .fontSize(12)
                .onClick(() => {
                  this.clearCrash();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(12)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  /** 按当前选的模式测：自动模式两边都探。 */
  private async test(): Promise<void> {
    this.testing = true;
    this.testResult = '正在测试…';
    const lan: string = normalizeBase(this.draftAmane, 'http');
    const lanUser: string = normalizeBase(this.draftUser, 'http');
    const wan: string = normalizeBase(this.draftWan, 'https');

    if (this.draftMode === MODE_WAN) {
      const okWan: boolean = await probe(`${wan}/api/user/ping`, 6000);
      const okMedia: boolean = await probe(`${wan}/api/health`, 6000);
      this.testResult = okWan && okMedia ? '连接正常：外网媒体与用户服务都在线'
        : (okMedia ? '外网媒体在线，用户服务不通' : '外网连不上，检查域名或隧道');
    } else if (this.draftMode === MODE_LAN) {
      const okUser: boolean = await probe(`${lanUser}/api/user/ping`, 4000);
      const okAmane: boolean = await probe(`${lan}/api/health`, 4000);
      this.testResult = okUser && okAmane ? '连接正常：局域网两个服务都在线'
        : (okAmane ? 'amane 正常，用户服务连不上' : '局域网地址连不上');
    } else {
      const okLan: boolean = await probe(`${lan}/api/health`, 1500);
      if (okLan) {
        const okUser: boolean = await probe(`${lanUser}/api/user/ping`, 3000);
        this.testResult = okUser ? '在家：局域网两个服务都正常' : 'amane 正常，但用户服务（8770）连不上';
      } else {
        const okWan: boolean = await probe(`${wan}/api/user/ping`, 6000);
        this.testResult = okWan ? '不在家：外网链路正常' : '局域网和外网都连不上';
      }
    }
    this.testing = false;
  }

  private save(): void {
    Store.I.lanAmane = normalizeBase(this.draftAmane, 'http');
    Store.I.lanUser = normalizeBase(this.draftUser, 'http');
    Store.I.wanAmane = normalizeBase(this.draftWan, 'https');
    Store.I.token = this.draftToken.trim();
    Store.I.mode = this.draftMode;
    Store.I.save();
    router.replaceUrl({ url: 'pages/Index' });
  }
}
