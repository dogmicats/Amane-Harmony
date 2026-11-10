import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { httpGet, probe } from '../common/Http';
import { CrashInfo, clearCrashLog, crashInfo, uploadCrashLog } from '../common/CrashReporter';
import {
  Store, normalizeBase, MODE_AUTO, MODE_LAN, MODE_WAN,
  DEFAULT_AMANE, DEFAULT_USER, DEFAULT_WAN_AMANE, DEFAULT_TOKEN
} from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

@Entry
@Component
struct SettingsPage {
  @State draftAmane: string = Store.I.lanAmane;
  @State draftUser: string = Store.I.lanUser;
  @State draftWan: string = Store.I.wanAmane;
  @State draftWanUser: string = Store.I.wanUser;
  /**
   * 外网用户数据走哪条路：
   *   domain —— 跟随域名，由隧道按路径分流到 8770（默认，等价于以前）
   *   dev    —— 域名 + /dev 前缀，隧道转到宿主 8771（测试实例；外网只开了 443，只能走前缀）
   *   custom —— 自己写完整地址，**可以带端口和路径**（把某个端口直接映射到公网时用）
   */
  @State wanPreset: string = 'domain';
  @State draftToken: string = Store.I.token;
  @State draftMode: string = Store.I.mode;
  @State testResult: string = '';
  @State testing: boolean = false;
  @State crashText: string = '';
  /** 抽卡模式：改了立刻生效并落盘，不跟「保存并重连」绑在一起（那个会跳回首页）。 */
  @State draftGachaCount: number = Store.I.gachaCount;
  @State draftGachaAuto: boolean = Store.I.gachaAuto;

  aboutToAppear(): void {
    this.refreshCrash();
    // 从已保存的地址反推当前是哪种走法，用户再进来看到的还是自己上次选的
    const u: string = Store.I.wanUser.trim();
    if (u.length === 0) {
      this.wanPreset = 'domain';
    } else if (BuildConfig.CHANNEL === 'self' && u.endsWith('/dev')) {
      // 'dev' 只有自用线才有这个 chip；发布版把带 /dev 的地址当普通自定义地址
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

  /** 抽卡参数是列表页的全局默认值，改了马上存，不依赖下面那个「保存并重连」。 */
  private applyGachaCount(n: number): void {
    this.draftGachaCount = n;
    Store.I.gachaCount = n;
    Store.I.save();
  }

  private applyGachaAuto(on: boolean): void {
    this.draftGachaAuto = on;
    Store.I.gachaAuto = on;
    Store.I.save();
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

  @Builder
  WanChip(label: string, key: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.wanPreset === key ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.wanPreset === key ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(12)
      .onClick(() => {
        this.wanPreset = key;
      })
  }

  /** 按当前选择算出「外网用户数据地址」；空串 = 跟随外网地址（走隧道默认分流）。 */
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

  /** 三种走法各说各的原理；发布版不提 /dev 与端口号（那是本仓库的部署细节）。 */
  private wanHint(): string {
    if (this.wanPreset === 'dev') {
      return '走 https://域名/dev：隧道把这个前缀转到宿主 8771，前缀会被剥掉。外网只映射了 443，所以端口方式连不通，只能用前缀。';
    }
    if (this.wanPreset === 'custom') {
      return '填完整地址，端口和路径都按你写的来；前提是那个端口真的能从公网连上（路由器 / 反向代理有映射）。';
    }
    if (BuildConfig.CHANNEL === 'self') {
      return '跟随外网地址：媒体与用户数据同一个域名，由隧道按路径分流（用户数据 → 8770）。';
    }
    return '跟随外网地址：媒体与用户数据都用上面这一个地址（默认，不用额外设置）。';
  }

  /** 探一次 /api/user/ping 拿版本号；连不上返回空串（用来区分 1.3.6 和 1.3.14）。 */
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

  @Builder
  GachaChip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(active ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(active ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(14)
      .onClick(() => {
        onTap();
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

          this.Field('外网地址（媒体、播放；用户数据默认也走它）', this.draftWan, DEFAULT_WAN_AMANE,
            (v: string) => {
              this.draftWan = v;
            })

          // 外网用户数据默认跟随外网地址（隧道按路径分流）。
          // 「自定义」两条通道都开：发布版用户可以填自己的域名/端口/反代前缀。
          // 「测试实例」只是自用线的调试捷径（本仓库的 8771 + /dev 前缀），
          // 不该出现在发布版里 —— 端口号和前缀是部署细节，不是用户该关心的事。
          Text('外网用户数据走哪儿')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Row({ space: 7 }) {
            this.WanChip(BuildConfig.CHANNEL === 'self' ? '跟随域名 8770' : '跟随外网地址', 'domain')
            if (BuildConfig.CHANNEL === 'self') {
              this.WanChip('测试实例 8771', 'dev')
            }
            this.WanChip('自定义', 'custom')
          }
          .width('100%')

          if (this.wanPreset === 'custom') {
            this.Field('外网用户数据地址（可带端口 / 路径）', this.draftWanUser,
              BuildConfig.CHANNEL === 'self'
                ? 'https://域名:端口/前缀，例如 https://example.com:8443'
                : 'https://域名:端口/前缀，留空则同外网地址',
              (v: string) => {
                this.draftWanUser = v;
              })
          }

          Text(this.wanHint())
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(16)

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

          Text('自动模式：启动时先探局域网（1.5 秒），连不上就走外网；回家再启动会自动切回来。外网下媒体走「外网地址」，用户数据按上面选的走。')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(16)

          Text(`当前使用：${Store.I.onWan ? '外网' : '局域网'}` +
            ` · 媒体 ${Store.I.amane}` +
            (Store.I.user === Store.I.amane ? '' : ` · 用户 ${Store.I.user}`))
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
              this.draftWanUser = '';
              this.draftToken = DEFAULT_TOKEN;
            })

          Text('播放器设置已经独立成页（我的 → 播放器）')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .margin({ top: 8 })

          Text('列表页 · 抽卡模式')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .margin({ top: 8 })

          Column({ space: 12 }) {
            Row({ space: 8 }) {
              Text('每轮张数')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
                .width(72)
              this.GachaChip('6 张', this.draftGachaCount === 6, () => {
                this.applyGachaCount(6);
              })
              this.GachaChip('10 张', this.draftGachaCount === 10, () => {
                this.applyGachaCount(10);
              })
              this.GachaChip('16 张', this.draftGachaCount === 16, () => {
                this.applyGachaCount(16);
              })
            }
            .width('100%')

            Row({ space: 8 }) {
              Text('默认开启')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
                .width(72)
              this.GachaChip('关', !this.draftGachaAuto, () => {
                this.applyGachaAuto(false);
              })
              this.GachaChip('开', this.draftGachaAuto, () => {
                this.applyGachaAuto(true);
              })
              Blank()
            }
            .width('100%')

            Text('抽卡模式 = 把标签 / 系列 / 导演 / 制片商 / 媒体库 / 收藏这些列表页换成随机剧照瀑布流，' +
              '点图直接进那部片的详情。每轮张数越大一次铺得越多；默认开启是「一进列表页就是剧照墙」。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(16)
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(12)

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
        // 底部留够系统导航条的高度：最后那排「测试连接 / 保存并重连」原来贴着屏幕边缘，
        // 一半压在导航条下面，点不动（真机/模拟器都点不到）。
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 96 })
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

    if (this.draftMode === MODE_WAN) {
      const media: string = normalizeBase(this.draftWan, 'https');
      const picked: string = this.wanUserBase();
      const user: string = picked.length > 0 ? picked : media;
      const okMedia: boolean = await probe(`${media}/api/health`, 8000);
      const ver: string = await this.pingVersion(user);
      this.testResult = okMedia && ver.length > 0
        ? `连接正常：媒体在线 · 用户数据 ${ver}（${user}）`
        : (okMedia
          ? `媒体在线，但用户数据连不上（${user}）—— 检查端口映射`
            + (BuildConfig.CHANNEL === 'self' ? '或 /dev 前缀' : '或地址是否写全')
          : `外网连不上（${media}）—— 检查域名或隧道`);
    } else if (this.draftMode === MODE_LAN) {
      const okAmane: boolean = await probe(`${lan}/api/health`, 4000);
      const ver: string = await this.pingVersion(lanUser);
      this.testResult = ver.length > 0 && okAmane
        ? `连接正常：局域网两个服务都在线（用户数据 ${ver}）`
        : (okAmane ? `amane 正常，用户服务连不上（${lanUser}）` : `局域网地址连不上（${lan}）`);
    } else {
      const okLan: boolean = await probe(`${lan}/api/health`, 1500);
      if (okLan) {
        const ver: string = await this.pingVersion(lanUser);
        this.testResult = ver.length > 0
          ? `在家：局域网两个服务都正常（用户数据 ${ver}）`
          : `amane 正常，但用户服务（${lanUser}）连不上`;
      } else {
        // 不在家：按外网那套地址探，用户数据同样受上面「走哪儿」的选择影响
        const media: string = normalizeBase(this.draftWan, 'https');
        const picked: string = this.wanUserBase();
        const user: string = picked.length > 0 ? picked : media;
        const ver: string = await this.pingVersion(user);
        this.testResult = ver.length > 0
          ? `不在家：外网链路正常（用户数据 ${ver}）`
          : '局域网和 外网都连不上';
      }
    }
    this.testing = false;
  }

  private save(): void {
    Store.I.lanAmane = normalizeBase(this.draftAmane, 'http');
    Store.I.lanUser = normalizeBase(this.draftUser, 'http');
    Store.I.wanAmane = normalizeBase(this.draftWan, 'https');
    // 三种走法在这里落成一个地址：空 = 跟随域名（隧道默认分流到 8770）
    Store.I.wanUser = this.wanUserBase();
    Store.I.token = this.draftToken.trim();
    Store.I.mode = this.draftMode;
    Store.I.save();
    router.replaceUrl({ url: 'pages/Index' });
  }
}
