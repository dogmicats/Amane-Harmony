import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { httpGet, probe } from '../common/Http';
import { CrashInfo, clearCrashLog, crashInfo, uploadCrashLog } from '../common/CrashReporter';
import {
  Store, normalizeBase, MODE_AUTO, MODE_LAN, MODE_WAN,
  DEFAULT_AMANE, DEFAULT_USER, DEFAULT_WAN_AMANE, DEFAULT_TOKEN
} from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BuildConfig } from '../common/BuildConfig';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsRowDivider, SettingsSectionTitle, VelvetChip
} from '../view/SettingsKit';

function hostOf(raw: string): string {
  const s: string = raw.trim();
  if (s.length === 0) {
    return '';
  }
  const https: boolean = s.indexOf('https://') === 0;
  const rest: string = https ? s.substring(8) : (s.indexOf('http://') === 0 ? s.substring(7) : s);
  const host: string = rest.split('/')[0].split(':')[0];
  return host.length > 0 ? `${https ? 'https://' : 'http://'}${host}` : '';
}

@Entry
@Component
struct SettingsConnectionPage {
  @State draftAmane: string = Store.I.lanAmane;
  @State draftUser: string = Store.I.lanUser;
  @State devActive: boolean = Store.I.prefString('dev_local_active', '0') === '1';
  @State draftWan: string = Store.I.wanAmane;
  @State draftWanUser: string = Store.I.wanUser;
  @State wanPreset: string = 'domain';
  @State draftToken: string = Store.I.token;
  @State showToken: boolean = false;
  @State draftMode: string = Store.I.mode;
  @State testResult: string = '';
  @State testOk: boolean = true;
  @State pingMs: number = -1;
  @State serverVer: string = '';
  @State testing: boolean = false;
  @State deployOpen: boolean = false;
  @State crashText: string = '';
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.refreshCrash();
    const u: string = Store.I.wanUser.trim();
    if (u.length === 0) {
      this.wanPreset = 'domain';
    } else if (BuildConfig.CHANNEL === 'self' && u.endsWith('/dev')) {
      this.wanPreset = 'dev';
    } else {
      this.wanPreset = 'custom';
      this.draftWanUser = u;
    }
  }

  private refreshCrash(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const info: CrashInfo = crashInfo(ctx);
    this.crashText = info.exists
      ? `崩溃日志 ${info.lines} 行 / ${info.bytes} 字符`
      : '暂无崩溃日志';
  }

  private async uploadCrash(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const n: number = await uploadCrashLog(ctx);
    if (n > 0) {
      this.refreshCrash();
      this.testOk = true;
      this.testResult = `已上报 ${n} 字符崩溃日志`;
    } else {
      this.crashText = '无可上报日志或服务不可达';
    }
  }

  private clearCrash(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    clearCrashLog(ctx);
    this.refreshCrash();
  }

  private toggleDevLocal(nextOn: boolean): void {
    if (!nextOn) {
      const back: string = Store.I.prefString('dev_local_before', '');
      this.draftUser = back.length > 0 ? back : DEFAULT_USER;
      Store.I.prefSetString('dev_local_active', '0');
      this.devActive = false;
      return;
    }
    Store.I.prefSetString('dev_local_before', this.draftUser);
    const host: string = hostOf(this.draftUser);
    if (host.length === 0) {
      return;
    }
    this.draftUser = `${host}:本地端口`;
    Store.I.prefSetString('dev_local_active', '1');
    this.devActive = true;
  }

  private wanUserBase(): string {
    const domain: string = normalizeBase(this.draftWan, 'https');
    if (this.wanPreset === 'dev') {
      return domain.length > 0 ? `${domain}/dev` : '';
    }
    if (this.wanPreset === 'custom') {
      return normalizeBase(this.draftWanUser, 'https');
    }
    return '';
  }

  private wanHint(): string {
    if (this.wanPreset === 'dev') {
      return '该预设不在发布版提供。';
    }
    if (this.wanPreset === 'custom') {
      return '填写完整公网地址与端口';
    }
    return BuildConfig.CHANNEL === 'self' ? '同域名按路径分流至用户服务' : '默认复用上方外网地址';
  }

  private async pingVersion(base: string): Promise<string> {
    if (base.length === 0) {
      return '';
    }
    try {
      const text: string = await httpGet(`${base}/api/user/ping`, Store.I.token);
      const obj: Record<string, string> = JSON.parse(text) as Record<string, string>;
      const v: string = obj.version;
      return v === undefined || v === null ? '在线' : v;
    } catch (err) {
      return '';
    }
  }

  private statusSubLine(): string {
    const parts: string[] = [];
    if (this.pingMs >= 0) {
      parts.push(`延迟 ${this.pingMs} ms`);
    }
    if (this.serverVer.length > 0) {
      parts.push(`服务 ${this.serverVer}`);
    }
    if (parts.length > 0) {
      return parts.join(' · ');
    }
    return Store.I.amane.replace('http://', '').replace('https://', '');
  }

  @Builder
  StatusBanner() {
    Row({ space: 10 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(Store.I.onWan ? '#F4C97E' : '#45B075')
      Column({ space: 3 }) {
        Text(`已连接 · ${Store.I.onWan ? '外网' : '局域网'}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text(this.statusSubLine())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .fontFeature('"tnum" 1')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(12)
          .fontColor([this.testing ? Theme.TEXT_FAINT : Theme.ACCENT_INK])
        Text(this.testing ? '测速中' : '测速')
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.testing ? Theme.TEXT_FAINT : Theme.TEXT)
      }
      .padding({ left: 11, right: 12, top: 6, bottom: 6 })
      .backgroundColor('#16FFFFFF')
      .border({ width: 0.75, color: '#24FFFFFF' })
      .borderRadius(Theme.R_PILL)
      .onClick(() => {
        if (!this.testing) {
          this.test();
        }
      })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 140,
      colors: [[Theme.accentAlpha(0.11), 0.0], ['#00000000', 0.62]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  ModeChip(label: string, value: string) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.draftMode === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.draftMode === value ? Theme.ACCENT_INK : Theme.TEXT_DIM)
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(Theme.R_PILL)
      .backgroundColor(this.draftMode === value ? Theme.accentAlpha(0.22) : Color.Transparent)
      .border({
        width: this.draftMode === value ? 0.75 : 0,
        color: this.draftMode === value ? Theme.inkAlpha(0.52) : Color.Transparent
      })
      .onClick(() => {
        this.draftMode = value;
      })
  }

  @Builder
  FormField(label: string, value: string, hint: string, onChange: (v: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      TextInput({ text: value, placeholder: hint })
        .height(40)
        .backgroundColor('#141114')
        .border({ width: 0.75, color: '#1EFFFFFF' })
        .borderRadius(12)
        .fontColor(Theme.TEXT)
        .fontSize(13)
        .placeholderColor(Theme.TEXT_FAINT)
        .caretColor(Theme.ACCENT_INK)
        .onChange((v: string) => {
          onChange(v);
        })
    }
    .width('100%')
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
        PageTitle({ text: '服务器连接', fs: 18 })
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
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.Top }) {
          SettingsAmbientGlow()

          Scroll() {
            Column({ space: 14 }) {
              Blank().height(this.barH() + 6)

              this.StatusBanner()

              if (this.testResult.length > 0) {
                Text(this.testResult)
                  .fontSize(11.5)
                  .fontColor(this.testOk ? '#8EE6B4' : Theme.DANGER)
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                  .backgroundColor(this.testOk ? '#1845B075' : Theme.alphaOf(Theme.DANGER, 0.14))
                  .border({
                    width: 0.5,
                    color: this.testOk ? '#4045B075' : Theme.alphaOf(Theme.DANGER, 0.36)
                  })
                  .borderRadius(12)
              }

              // 网络模式分段器
              Column({ space: 10 }) {
                Text('网络模式')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                  .width('100%')
                Row({ space: 4 }) {
                  this.ModeChip('自动', MODE_AUTO)
                  this.ModeChip('仅局域网', MODE_LAN)
                  this.ModeChip('仅外网', MODE_WAN)
                }
                .width('100%')
                .padding(4)
                .backgroundColor('#141114')
                .border({ width: 0.5, color: '#18FFFFFF' })
                .borderRadius(Theme.R_PILL)

                Text('自动模式优先探局域网（1.5s），不通自动切外网。')
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })

              // 局域网地址分组卡
              Column({ space: 12 }) {
                Text('局域网地址')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                  .width('100%')

                this.FormField('媒体服务地址', this.draftAmane, DEFAULT_AMANE, (v: string) => {
                  this.draftAmane = v;
                })
                this.FormField('用户数据服务', this.draftUser, DEFAULT_USER, (v: string) => {
                  this.draftUser = v;
                })

                if (BuildConfig.CHANNEL === 'self') {
                  Row({ space: 10 }) {
                    SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
                      .fontSize(15)
                      .fontColor([Theme.ACCENT_INK])
                    Text('本机开发实例 :本地端口')
                      .fontSize(12.5)
                      .fontColor(Theme.TEXT)
                      .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.devActive })
                      .selectedColor(Theme.ACCENT)
                      .onChange((v: boolean) => {
                        if (v !== this.devActive) {
                          this.toggleDevLocal(v);
                        }
                      })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 10, top: 7, bottom: 7 })
                  .backgroundColor('#141114')
                  .border({ width: 0.5, color: '#1AFFFFFF' })
                  .borderRadius(12)
                  .alignItems(VerticalAlign.Center)
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })

              // 外网与认证分组卡
              Column({ space: 12 }) {
                Text('外网与认证')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                  .width('100%')

                this.FormField('外网域名', this.draftWan, DEFAULT_WAN_AMANE, (v: string) => {
                  this.draftWan = v;
                })

                Row({ space: 8 }) {
                  VelvetChip({
                    label: BuildConfig.CHANNEL === 'self' ? '跟随域名 8770' : '跟随域名',
                    active: this.wanPreset === 'domain',
                    padH: 12,
                    padV: 6,
                    fs: 11.5,
                    onTap: () => {
                      this.wanPreset = 'domain';
                    }
                  })
                  if (BuildConfig.CHANNEL === 'self') {
                    VelvetChip({
                      active: this.wanPreset === 'dev',
                      padH: 12,
                      padV: 6,
                      fs: 11.5,
                      onTap: () => {
                        this.wanPreset = 'dev';
                      }
                    })
                  }
                  VelvetChip({
                    label: '自定义',
                    active: this.wanPreset === 'custom',
                    padH: 12,
                    padV: 6,
                    fs: 11.5,
                    onTap: () => {
                      this.wanPreset = 'custom';
                    }
                  })
                }
                .width('100%')

                if (this.wanPreset === 'custom') {
                  this.FormField('外网用户数据地址', this.draftWanUser,
                    'https://域名:端口/前缀，留空同外网地址',
                    (v: string) => {
                      this.draftWanUser = v;
                    })
                }

                Text(this.wanHint())
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')

                SettingsRowDivider({ indent: 0 })

                Column({ space: 6 }) {
                  Text('API Token')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                    .width('100%')
                  Row({ space: 8 }) {
                    TextInput({ text: this.draftToken, placeholder: '输入服务端 Token' })
                      .type(this.showToken ? InputType.Normal : InputType.Password)
                      .showPasswordIcon(false)
                      .height(40)
                      .layoutWeight(1)
                      .backgroundColor(Color.Transparent)
                      .fontColor(Theme.TEXT)
                      .fontSize(13)
                      .placeholderColor(Theme.TEXT_FAINT)
                      .caretColor(Theme.ACCENT_INK)
                      .onChange((v: string) => {
                        this.draftToken = v;
                      })
                    Stack() {
                      SymbolGlyph(this.showToken ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
                        .fontSize(16)
                        .fontColor([Theme.TEXT_DIM])
                    }
                    .width(34)
                    .height(34)
                    .onClick(() => {
                      this.showToken = !this.showToken;
                    })
                  }
                  .width('100%')
                  .padding({ right: 6 })
                  .backgroundColor('#141114')
                  .border({ width: 0.75, color: '#1EFFFFFF' })
                  .borderRadius(12)
                }
                .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })

              // 辅助折叠区：恢复默认 + 部署说明
              Column() {
                Row() {
                  Text('部署说明（服务器侧）')
                    .fontSize(13)
                    .fontColor(Theme.TEXT_DIM)
                    .layoutWeight(1)
                  SymbolGlyph(this.deployOpen ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                    .fontSize(13)
                    .fontColor([Theme.TEXT_FAINT])
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .onClick(() => {
                  this.deployOpen = !this.deployOpen;
                })

                if (this.deployOpen) {
                  Column({ space: 6 }) {
                    SettingsRowDivider({ indent: 0 })
                    Text('容器挂载大容量盘（预览/打分缓存）：')
                      .fontSize(11)
                      .fontColor(Theme.TEXT)
                      .width('100%')
                    Text('1. mkdir -p <宿主机目录>')
                      .fontSize(10.5)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                    Text('2. compose volumes 加入：- <宿主机目录>:/cache')
                      .fontSize(10.5)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                    Text('3. docker compose up -d --force-recreate')
                      .fontSize(10.5)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                    Text('4. 在「进度条预览」中将缓存路径填为 /cache 并保存。')
                      .fontSize(10.5)
                      .fontColor(Theme.GOLD)
                      .width('100%')
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, bottom: 14 })
                  .alignItems(HorizontalAlign.Start)
                }
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(16)
              .border({ width: 0.75, color: Theme.STROKE })

              Text('恢复默认地址')
                .fontSize(12)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ top: 4, bottom: 4 })
                .onClick(() => {
                  this.draftAmane = DEFAULT_AMANE;
                  this.draftUser = DEFAULT_USER;
                  this.draftWan = DEFAULT_WAN_AMANE;
                  this.draftWanUser = '';
                  this.draftToken = DEFAULT_TOKEN;
                })

              Blank().height(110)
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')

        // 底部悬浮动作栏（玻璃「测试连接」 + 宝石渐变「保存并重连」）
        Row({ space: 10 }) {
          Button(this.testing ? '测试中…' : '测试连接')
            .layoutWeight(4)
            .height(44)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .backgroundColor('#22FFFFFF')
            .border({ width: 0.75, color: '#2EFFFFFF' })
            .borderRadius(22)
            .fontColor(Theme.TEXT)
            .fontSize(13.5)
            .fontWeight(FontWeight.Medium)
            .enabled(!this.testing)
            .onClick(() => {
              this.test();
            })
          Button('保存并重连')
            .layoutWeight(6)
            .height(44)
            .backgroundColor(Color.Transparent)
            .linearGradient(Theme.ctaGradient())
            .border({ width: 0.75, color: '#38FFFFFF' })
            .borderRadius(22)
            .shadow({ radius: 14, color: Theme.accentAlpha(0.32), offsetX: 0, offsetY: 4 })
            .fontColor(Theme.ON_ACCENT)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .onClick(() => {
              this.save();
            })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 14, bottom: Theme.pageBottomSafe() + 6 })
        .linearGradient({
          angle: 180,
          colors: [['#000B0B0F', 0.0], ['#E60B0B0F', 0.35], ['#FF0B0B0F', 1.0]]
        })
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

  private async test(): Promise<void> {
    this.testing = true;
    this.testOk = true;
    this.testResult = '正在探测连接…';
    const t0: number = Date.now();
    const lan: string = normalizeBase(this.draftAmane, 'http');
    const lanUser: string = normalizeBase(this.draftUser, 'http');

    if (this.draftMode === MODE_WAN) {
      const media: string = normalizeBase(this.draftWan, 'https');
      const picked: string = this.wanUserBase();
      const user: string = picked.length > 0 ? picked : media;
      const okMedia: boolean = await probe(`${media}/api/health`, 8000);
      const ver: string = await this.pingVersion(user);
      const dt: number = Date.now() - t0;
      this.testOk = okMedia && ver.length > 0;
      if (this.testOk) {
        this.pingMs = dt;
        this.serverVer = ver;
      }
      this.testResult = this.testOk
        ? `连接正常（${dt} ms）· 用户服务 ${ver}`
        : (okMedia
          ? `媒体在线，但用户服务连不上（${user}）`
          : `外网连不上（${media}）`);
    } else if (this.draftMode === MODE_LAN) {
      const okAmane: boolean = await probe(`${lan}/api/health`, 4000);
      const ver: string = await this.pingVersion(lanUser);
      const dt: number = Date.now() - t0;
      this.testOk = ver.length > 0 && okAmane;
      if (this.testOk) {
        this.pingMs = dt;
        this.serverVer = ver;
      }
      this.testResult = this.testOk
        ? `连接正常（${dt} ms）· 局域网双服务在线（${ver}）`
        : (okAmane ? `媒体正常，用户服务连不上（${lanUser}）` : `局域网连不上（${lan}）`);
    } else {
      const okLan: boolean = await probe(`${lan}/api/health`, 1500);
      if (okLan) {
        const ver: string = await this.pingVersion(lanUser);
        const dt: number = Date.now() - t0;
        this.testOk = ver.length > 0;
        if (this.testOk) {
          this.pingMs = dt;
          this.serverVer = ver;
        }
        this.testResult = this.testOk
          ? `局域网连接正常（${dt} ms · ${ver}）`
          : `媒体正常，用户服务（${lanUser}）连不上`;
      } else {
        const media: string = normalizeBase(this.draftWan, 'https');
        const picked: string = this.wanUserBase();
        const user: string = picked.length > 0 ? picked : media;
        const ver: string = await this.pingVersion(user);
        const dt: number = Date.now() - t0;
        this.testOk = ver.length > 0;
        if (this.testOk) {
          this.pingMs = dt;
          this.serverVer = ver;
        }
        this.testResult = this.testOk
          ? `外网链路正常（${dt} ms · ${ver}）`
          : '局域网与外网均不可达';
      }
    }
    this.testing = false;
  }

  private save(): void {
    Store.I.lanAmane = normalizeBase(this.draftAmane, 'http');
    Store.I.lanUser = normalizeBase(this.draftUser, 'http');
    Store.I.wanAmane = normalizeBase(this.draftWan, 'https');
    Store.I.wanUser = this.wanUserBase();
    Store.I.token = this.draftToken.trim();
    Store.I.mode = this.draftMode;
    Store.I.save();
    router.replaceUrl({ url: 'pages/Index' });
  }
}
