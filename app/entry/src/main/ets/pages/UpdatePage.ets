import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Updater, CheckResult } from '../common/Updater';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

/** 公开版的兜底步骤（`BuildConfig.CHANNEL === 'public'`）。不写端口、不写账号密码。 */
const HOWTO_PUBLIC: string =
  '在跑服务的那台机器上操作（不是手机上）：\n' +
  '1. 备份：cp -r data data.bak-$(date +%Y%m%d)\n' +
  '2. 到仓库目录：git pull\n' +
  '3. 重建：docker compose -f deploy/compose.yml up -d --build\n' +
  '   （当初把 compose 改成 image: 的，先把 tag 改成新版本号，再 docker compose pull && up -d）\n' +
  '4. 回本页点「重新检查」，服务端那行会变成新版本号\n' +
  '想退回上一版：把 data.bak-<日期> 换回 data，再做一次第 3 步';

/** 兜底步骤：按通道取（公版只有 HOWTO_PUBLIC 这一套）。 */
const DEFAULT_SERVER_HOWTO: string = HOWTO_PUBLIC;

/** 当前通道该用哪套兜底步骤。 */
function defaultHowto(): string {
  return BuildConfig.CHANNEL === 'public' ? HOWTO_PUBLIC : DEFAULT_SERVER_HOWTO;
}

/**
 * 装包提示（主）。
 *
 * 区别的根源是**包的签名状态**：公开版 Release 里放的是未签名包，手机点它装不上，
 * 必须先用侧载工具拿自己的证书签一次；自用版签的是含本机 UDID 的证书，直接点就能装。
 * 这两句不能混写，否则公开版用户会卡在「点了没反应」。
 */
function installHint(): string {
  return BuildConfig.CHANNEL === 'public'
    ? '① 点下面的「另存到手机」把包存下来；② 用侧载工具（Hokit / 小白调试助手）选这个 hap，'
      + '它会用你的华为账号签一次再装；③ 装好会覆盖旧版，设置和数据都还在。'
    : '① 先把包存到手机；② 在文件管理里点它，按系统的提示安装；'
      + '③ 装好后这一版就是新的了，旧的一版会被覆盖。';
}

/** 装包提示（备用路径）。公开版不能提 hdc —— 那也要先有签名，等于绕回侧载工具。 */
function installHintFallback(): string {
  return BuildConfig.CHANNEL === 'public'
    ? '没有侧载工具：用 DevEco Studio 打开 app 目录、配上自动签名，把包放进去重新运行一次即可。'
    : '点了没反应（个别机型没有安装器）：把包拷到电脑，用 hdc install -r <包路径> 装，效果一样。';
}

const ST_IDLE: string = 'idle';
const ST_CHECKING: string = 'checking';
const ST_DONE: string = 'done';
const ST_DOWNLOADING: string = 'downloading';
const ST_READY: string = 'ready';
const ST_FAILED: string = 'failed';

/**
 * 检查更新（2.5.7）。
 *
 * 说明一件平台事实：侧载安装的 App **无法自己装自己** —— 鸿蒙公开 SDK 里没有
 * 第三方可用的安装接口（`@ohos.bundle.installer` 不在 SDK，`INSTALL_BUNDLE` 是系统权限）。
 * 所以这一页只做到「检查 → 下载 → 校验 → 另存到手机」。
 *
 * 最后一步两种通道不一样，别混写：
 * - public：Release 里是未签名包，必须用侧载工具（Hokit / 小白调试助手 / DevEco）签一次；
 * - self：签的是含本机 UDID 的证书，文件管理里点开就能装。
 * 侧载工具不提供可被程序调用的安装接口，所以这一下永远是人点，无法自动化。
 */
@Entry
@Component
struct UpdatePage {
  @State st: string = ST_IDLE;
  @State msg: string = '';
  @State clientNow: string = '';
  @State serverNow: string = '';
  @State clientLatest: string = '';
  @State serverLatest: string = '';
  @State serverHowto: string = '';
  @State clientUpdatable: boolean = false;
  @State serverUpdatable: boolean = false;
  @State notes: string = '';
  @State manifestUrl: string = '';
  @State pct: number = -1;
  @State savedPath: string = '';
  @State savedUri: string = '';
  /** 清单地址输入框（留空 = 用服务端默认）。 */
  @State draft: string = '';
  /** 验收自检：用内置演示数据把「可更新」态造出来，不联网、不下载、不写偏好。 */
  @State demo: boolean = false;
  /** 服务端升级步骤卡是否展开。有新版时默认展开；没新版也能手动点开看。 */
  @State howtoOpen: boolean = false;
  /** 清单新鲜度：来自哪、什么时候发布的、这次什么时候查的。 */
  @State publishedAt: string = '';
  @State checkedAt: string = '';
  @State sourceLabel: string = '';
  @State fellBack: boolean = false;
  @State attempts: string = '';
  @State hint: string = '';

  aboutToAppear(): void {
    try {
      Updater.init(getContext(this) as common.UIAbilityContext);
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] update init: ${e.code} ${e.message}`);
    }
    this.draft = Store.I.prefString('update_manifest_url', '');
    this.runCheck();
  }

  private apply(r: CheckResult): void {
    this.clientNow = r.clientNow;
    this.serverNow = r.serverNow;
    this.clientLatest = r.clientLatest;
    this.serverLatest = r.serverLatest;
    this.serverHowto = r.serverHowto.length > 0 ? r.serverHowto : defaultHowto();
    this.clientUpdatable = r.clientUpdatable;
    this.serverUpdatable = r.serverUpdatable;
    this.notes = r.clientNotes.length > 0 ? r.clientNotes : r.serverNotes;
    this.manifestUrl = r.manifestUrl;
    this.publishedAt = r.publishedAt;
    this.checkedAt = r.checkedAt;
    this.sourceLabel = r.sourceLabel;
    this.fellBack = r.fellBack;
    this.attempts = r.attempts;
    this.hint = r.hint;
    this.howtoOpen = r.serverUpdatable;
    // 下载要用到的三项：不放进 @State（不需要触发渲染），但一定要跟着清单更新
    this.currentUrl = r.url;
    this.currentSize = r.size;
    this.currentSha = r.sha256;
  }

  /**
   * 验收自检：把「可更新」态直接造出来，**完全不联网**。
   *
   * 为什么需要：这套开发流程是「改完即上线」（客户端签完就装、服务端 deploy 完就最新），
   * 运行时版本永远等于仓库最新，正常情况根本不会出现版本差 —— 于是这一页永远只显示
   * 「已是最新」，服务端步骤卡也永远不出现，功能没法验收。自检让验收不依赖真的去发布/降级。
   *
   * 自检态下**不给下载按钮**：没有真实包，也不该让人误以为下到的包是 0.0.0。
   * 想验真实下载链路，用底部清单地址填入 `tools/publish_update.py` 发布的地址。
   */
  private applyDemo(): void {
    this.demo = true;
    this.st = ST_DONE;
    this.msg = '';
    this.pct = -1;
    this.savedPath = '';
    this.savedUri = '';
    if (this.clientNow.length === 0) {
      this.clientNow = '（本机版本）';
    }
    if (this.serverNow.length === 0) {
      this.serverNow = '（读不到）';
    }
    this.clientLatest = '0.0.0';
    this.serverLatest = '1.4.99';
    this.clientUpdatable = true;
    this.serverUpdatable = true;
    this.howtoOpen = true;
    this.serverHowto = defaultHowto();
    this.notes = '验收自检：这是内置的演示数据，用来看「可更新」长什么样、以及服务端升级步骤。' +
      '不会联网、不会下载、不会改你的清单地址。点「重新检查」就回到真实结果。';
    this.manifestUrl = '验收自检（演示数据，未联网）';
    this.publishedAt = '';
    this.checkedAt = '—';
    this.sourceLabel = '内置演示数据';
    this.fellBack = false;
    this.attempts = '';
    this.hint = '';
    this.currentUrl = '';
    this.currentSize = 0;
    this.currentSha = '';
  }

  private async runCheck(): Promise<void> {
    if (this.st === ST_CHECKING || this.st === ST_DOWNLOADING) {
      return;
    }
    this.demo = false;
    this.st = ST_CHECKING;
    this.msg = '';
    const r: CheckResult = await Updater.check();
    this.apply(r);
    if (!r.ok) {
      this.st = ST_FAILED;
      this.msg = r.message;
      return;
    }
    this.st = ST_DONE;
    if (!r.clientUpdatable && !r.serverUpdatable) {
      this.msg = '客户端和服务端都是最新的';
    }
  }

  private async startDownload(): Promise<void> {
    if (this.st === ST_DOWNLOADING) {
      return;
    }
    this.st = ST_DOWNLOADING;
    this.pct = -1;
    this.msg = '';
    const r = await Updater.download(this.clientLatest, this.currentUrl, this.currentSize,
      this.currentSha, (p: number) => {
        this.pct = p;
      });
    if (r.ok) {
      this.st = ST_READY;
      this.savedPath = r.path;
      this.msg = r.message;
    } else {
      this.st = ST_FAILED;
      this.msg = r.message;
    }
  }

  // 清单值存在 apply() 里，这里从组件状态取，避免再存一份私有字段
  private currentUrl: string = '';
  private currentSize: number = 0;
  private currentSha: string = '';

  private async saveToPhone(): Promise<void> {
    if (this.savedPath.length === 0) {
      return;
    }
    const uri: string = await Updater.saveToPhone(this.savedPath, this.clientLatest);
    if (uri.length === 0) {
      promptAction.showToast({ message: '没存成功（可能取消了保存）', duration: 1800 });
      return;
    }
    this.savedUri = uri;
    promptAction.showToast({ message: '已保存到手机', duration: 1800 });
  }

  private mb(bytes: number): string {
    if (bytes <= 0) {
      return '—';
    }
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }

  private stateLine(): string {
    if (this.demo) {
      return '验收自检 · 内置演示数据（未联网，不会下载）';
    }
    if (this.st === ST_CHECKING) {
      return '正在检查…';
    }
    if (this.st === ST_DOWNLOADING) {
      return this.pct >= 0 ? `正在下载 ${this.pct}%` : '正在下载…';
    }
    if (this.st === ST_READY) {
      return '已下载并校验通过';
    }
    return this.msg;
  }

  private stateColor(): string {
    if (this.st === ST_FAILED) {
      return Theme.DANGER;
    }
    if (this.st === ST_READY) {
      return Theme.GOLD;
    }
    return Theme.TEXT_DIM;
  }

  /** 清单超过 30 天没发布就提醒：多半是发布流程漏跑了，而不是 App 坏了。 */
  private freshnessNote(): string {
    if (this.st === ST_FAILED) {
      return '这次没读到清单，无法判断它有多新';
    }
    if (this.publishedAt.length === 0) {
      return '这份清单没写 published_at，无法判断它有多新';
    }
    const t: number = Date.parse(this.publishedAt);
    if (!(t > 0)) {
      return '';
    }
    const days: number = Math.floor((Date.now() - t) / 86400000);
    if (days > 30) {
      return `这份清单已经 ${days} 天没发布过了，可能发布流程漏跑了`;
    }
    return '';
  }

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('检查更新')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(`当前客户端 ${this.clientNow.length > 0 ? this.clientNow : '—'}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('重新检查')
        .fontSize(11)
        .fontColor(Theme.ACCENT)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.CARD)
        .borderRadius(9)
        .onClick(() => {
          this.runCheck();
        })
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  /**
   * 版本行。**参数只传「哪一行」，值一律在 builder 内读状态** ——
   * `@Builder` 的传值参数不会随 `@State` 变化重新求值，之前两行版本号一直停在初始的「—」。
   */
  @Builder
  VerRow(which: string) {
    Row({ space: 8 }) {
      Text(which === 'client' ? '客户端' : '服务端')
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .width(66)
      Text(this.nowOf(which).length > 0 ? this.nowOf(which) : '—')
        .fontSize(12)
        .fontColor(Theme.TEXT_DIM)
        .layoutWeight(1)
      if (this.latestOf(which).length > 0) {
        Text(this.canUpOf(which) ? `→ ${this.latestOf(which)}` : this.latestOf(which))
          .fontSize(12)
          .fontColor(this.canUpOf(which) ? Theme.GOLD : Theme.TEXT_FAINT)
      }
      if (this.latestOf(which).length > 0) {
        Text(this.canUpOf(which) ? '可更新' : '最新')
          .fontSize(9)
          .fontColor(this.canUpOf(which) ? '#FFFFFF' : Theme.TEXT_FAINT)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(this.canUpOf(which) ? Theme.ACCENT : Theme.CARD_HI)
          .borderRadius(6)
      }
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  private nowOf(which: string): string {
    return which === 'client' ? this.clientNow : this.serverNow;
  }

  private latestOf(which: string): string {
    return which === 'client' ? this.clientLatest : this.serverLatest;
  }

  private canUpOf(which: string): boolean {
    return which === 'client' ? this.clientUpdatable : this.serverUpdatable;
  }

  @Builder
  MainCard() {
    Column({ space: 4 }) {
      this.VerRow('client')
      // 服务端那行只在真读到版本号时出现：没连服务端（首次启动、ping 不通）时显示
      // 「— / 清单未给」等于把内部状态词丢给用户，不如整行不显示。
      if (this.serverNow.length > 0) {
        Divider()
          .color(Theme.CARD_HI)
        this.VerRow('server')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
  }

  /**
   * 清单新鲜度卡 —— 把「清单到底新不新」做成看得见的东西。
   *
   * App 里没有清单，只有一个固定地址；每次检查现取。所以这里显示的是
   * 「服务器上那份清单什么时候发布的」和「我这次什么时候查的」，
   * 而不是「这个 App 是什么时候装的」。旧版 App 也能读到刚发布的新清单。
   * 值一律在 builder 内读 @State（@Builder 传值参数不会随状态刷新）。
   */
  @Builder
  FreshnessCard() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('清单新鲜度')
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        if (this.fellBack) {
          Text('已自动回退')
            .fontSize(9)
            .fontColor(Theme.GOLD)
        }
      }
      .width('100%')
      Text(`来源：${this.sourceLabel.length > 0 ? this.sourceLabel : '—'}`)
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      Text(`清单发布于：${this.publishedAt.length > 0 ? this.publishedAt : '没写'}`)
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      Text(`本次检查：${this.checkedAt.length > 0 ? this.checkedAt : '—'}`)
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      if (this.freshnessNote().length > 0) {
        Text(this.freshnessNote())
          .fontSize(10)
          .fontColor(this.publishedAt.length > 0 ? Theme.DANGER : Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(15)
      }
      Text('App 里不存清单，只存一个固定地址；每次检查现取。发布新版只需覆盖 GitHub 上那一份，' +
        '旧版 App 不用升级就能看到。')
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
  }

  /** 把步骤复制到剪贴板（用户粘到终端里照做）。 */
  private copyHowto(): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.serverHowto);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '步骤已复制，粘到终端里照做', duration: 1800 });
      }).catch((err: BusinessError) => {
        console.info(`[amane] copy howto: ${err.code} ${err.message}`);
      });
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] copy howto: ${e.code} ${e.message}`);
    }
  }

  /**
   * 服务端升级步骤卡 —— **常驻**，不再只挂在 `serverUpdatable` 上。
   *
   * 原因：本项目的服务端「改完代码就自动部署到最新」，正常开发期几乎不会出现版本差，
   * 如果只在有差时才显示，用户永远看不到「怎么升」这块（等于白做）。
   * 有新版时高亮 + 默认展开；没新版时低调收起，但仍能点开看、复制。
   */
  @Builder
  ServerCard() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(this.serverUpdatable
          ? `服务端也有新版本 · ${this.serverLatest}`
          : '怎么升级服务端（目前是最新）')
          .fontSize(12)
          .fontColor(this.serverUpdatable ? Theme.GOLD : Theme.TEXT_DIM)
          .layoutWeight(1)
        Text(this.howtoOpen ? '收起' : '展开')
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(8)
          .onClick(() => {
            this.howtoOpen = !this.howtoOpen;
          })
        Text('复制步骤')
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(8)
          .onClick(() => {
            this.copyHowto();
          })
      }
      .width('100%')

      if (this.howtoOpen) {
        Text(this.serverHowto)
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
          .width('100%')
          .lineHeight(17)
          .copyOption(CopyOptions.LocalDevice)

        Text('为什么这里不能一键升：服务端跑在 NAS 的容器里，换版本要落到宿主机的文件与容器上。' +
          '把「能换服务端代码」做成 App 里的一个按钮，等于谁拿到这把钥匙都能在你机器上跑东西；' +
          '而且升挂了 App 自己也连不上，没法自救。所以这一步留在你能看到输出的地方做。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(14)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.serverUpdatable ? Theme.ACCENT_SOFT : Theme.CARD)
    .borderRadius(12)
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 10 }) {
          this.MainCard()
          this.FreshnessCard()

          Column({ space: 8 }) {
            Text(this.stateLine())
              .fontSize(12)
              .fontColor(this.stateColor())
              .width('100%')
              .lineHeight(18)

            if (this.st === ST_FAILED && this.attempts.length > 0) {
              Text(this.attempts)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(15)
                .copyOption(CopyOptions.LocalDevice)
            }
            if (this.st === ST_FAILED && this.hint.length > 0) {
              Text(this.hint)
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .width('100%')
                .lineHeight(15)
            }

            if (this.st === ST_DOWNLOADING) {
              Progress({
                value: this.pct < 0 ? 0 : this.pct,
                total: 100,
                type: ProgressType.Linear
              })
                .width('100%')
                .height(4)
                .color(Theme.ACCENT)
                .backgroundColor(Theme.CARD_HI)
            }

            if (this.notes.length > 0) {
              Text(this.notes)
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
                .width('100%')
                .lineHeight(17)
            }

            if (this.st === ST_DONE && this.clientUpdatable && !this.demo) {
              Row({ space: 8 }) {
                Text(`下载新版本 ${this.clientLatest}`)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(10)
                  .onClick(() => {
                    this.startDownload();
                  })
                if (this.currentSize > 0) {
                  Text(this.mb(this.currentSize))
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
              }
              .width('100%')
            }

            if (this.st === ST_READY) {
              Text(installHint())
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(16)
              Text(installHintFallback())
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(14)
              Row({ space: 8 }) {
                Text(this.savedUri.length > 0 ? '已存到手机' : '另存到手机')
                  .fontSize(12)
                  .fontColor(this.savedUri.length > 0 ? Theme.GOLD : '#FFFFFF')
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .backgroundColor(this.savedUri.length > 0 ? Theme.CARD_HI : Theme.ACCENT)
                  .borderRadius(10)
                  .onClick(() => {
                    if (this.savedUri.length === 0) {
                      this.saveToPhone();
                    }
                  })
              }
              .width('100%')
            }

            if (this.st === ST_FAILED) {
              Text('重试')
                .fontSize(12)
                .fontColor(Theme.ACCENT)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(Theme.ACCENT_SOFT)
                .borderRadius(10)
                .onClick(() => {
                  this.runCheck();
                })
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(12)

          this.ServerCard()

          // 手填清单地址是自测线的调试口：公开版固定走默认源（Release → 镜像 → 自有服务端），
          // 不该让用户看到「测试版」「留空 = 用服务端默认清单」这类内部说法。
          if (BuildConfig.CHANNEL === 'self') {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              TextInput({ text: this.draft, placeholder: '留空 = 用服务端默认清单' })
                .fontSize(10)
                .height(32)
                .layoutWeight(1)
                .backgroundColor(Theme.CARD_HI)
                .fontColor(Theme.TEXT)
                .placeholderColor(Theme.TEXT_FAINT)
                .onChange((v: string) => {
                  this.draft = v;
                })
              Text('保存并检查')
                .fontSize(10)
                .fontColor(Theme.ACCENT)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(Theme.ACCENT_SOFT)
                .borderRadius(8)
                .onClick(() => {
                  Store.I.prefSetString('update_manifest_url', this.draft.trim());
                  this.runCheck();
                })
              Text('恢复默认')
                .fontSize(10)
                .fontColor(Theme.ACCENT)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
                .onClick(() => {
                  Store.I.prefSetString('update_manifest_url', '');
                  this.draft = '';
                  this.runCheck();
                })
            }
            .width('100%')
            Text(`当前在用：${this.manifestUrl}`)
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)

            // 验收自检只在自测线出现：公开包里 CHANNEL 是 public，整块不渲染，
            // 用户不会看到「0.0.0」这种假版本号，也不会去点一个没有真实包的按钮。
            if (BuildConfig.CHANNEL === 'self') {
              Row({ space: 8 }) {
                Text(this.demo ? '退回真实结果' : '验收自检（不用联网）')
                  .fontSize(10)
                  .fontColor(Theme.ACCENT)
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(Theme.ACCENT_SOFT)
                  .borderRadius(8)
                  .onClick(() => {
                    if (this.demo) {
                      this.runCheck();
                    } else {
                      this.applyDemo();
                    }
                  })
                Text(this.demo ? '内置演示数据，不会下载' : '一键造出「可更新」态，看服务端升级步骤')
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                  .layoutWeight(1)
                  .lineHeight(14)
              }
              .width('100%')
            }

            Text('发布版默认按 GitHub Release → 仓库镜像 → CDN 镜像 → 自有服务端 依次找清单；' +
              '自测版可在上面手填任意地址，连不上会自动回退到下一个源。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)
            Text('这个 App 是自己签名侧载安装的，系统不允许 App 自己装自己 —— ' +
              '公开接口里没有安装能力。所以最后一步必须你点一下。' +
              '下载的包会做 sha256 校验，对不上自动删掉。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)
          }
          .width('100%')
          .padding({ top: 4, bottom: Theme.BOTTOM_SAFE })
          } else {
            Column({ space: 4 }) {
              Text('检查时按 GitHub Release → 仓库镜像 → CDN 镜像 → 自有服务端 依次找清单，连不上自动换下一个源。')
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(14)
              Text('这个 App 是侧载安装的，系统不允许 App 自己装自己 —— 公开接口里没有安装能力，' +
                '所以最后一步必须你点一下。下载的包会做 sha256 校验，对不上自动删掉。')
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(14)
            }
            .width('100%')
            .padding({ top: 4, bottom: Theme.BOTTOM_SAFE })
          }
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4 })
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
