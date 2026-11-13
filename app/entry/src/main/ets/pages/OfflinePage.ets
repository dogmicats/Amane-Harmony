import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Downloader, OfflineTask } from '../common/Downloader';
import { Theme } from '../common/Theme';

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';

/** 空间上限的可选项（GB；0 = 不限）。 */
const LIMITS: number[] = [4, 8, 16, 0];

/**
 * 离线缓存（2.5.6 起，2.5.7 补设置与清理）。
 *
 * 「下到手机里、断网也能看」的入口。下载交给系统下载代理（断点续传、后台），
 * 这里管四件事：看进度、排队/暂停/继续、删掉腾空间、定只走 WiFi 与总上限。
 *
 * 下完之后这部片在详情页会直接播本地文件，不再走网络（见 `Store.playSource`）。
 */
@Entry
@Component
struct OfflinePage {
  @State st: string = ST_LOADING;
  @State tasks: OfflineTask[] = [];
  @State totalBytes: number = 0;
  /** 占用百分比：必须存成状态，直接在 build 里调 Downloader.usageRatio() 不会随上限变化重算。 */
  @State usagePct: number = 0;
  @State busy: boolean = false;
  @State wifiOnly: boolean = true;
  @State maxGb: number = 8;
  @State warn: boolean = false;
  @State onWifi: boolean = true;
  @State runN: number = 0;
  @State waitN: number = 0;
  private stopWatch: () => void = () => {};

  aboutToAppear(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      Downloader.init(ctx);
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline init: ${e.code} ${e.message}`);
    }
    this.wifiOnly = Downloader.wifiOnly();
    this.maxGb = Downloader.maxGb();
    Downloader.reconcile();
    this.refresh();
    this.probeNet();
    // 清完队列会接着跑：进来先推一次
    Downloader.pump();
    this.stopWatch = Downloader.watch(() => {
      this.refresh();
    });
    this.st = ST_OK;
    if (Downloader.takeWarnSlot()) {
      this.warn = true;
    }
  }

  aboutToDisappear(): void {
    this.stopWatch();
  }

  private refresh(): void {
    this.tasks = Downloader.list();
    this.totalBytes = Downloader.totalBytes();
    this.usagePct = Math.round(Downloader.usageRatio() * 100);
    this.runN = Downloader.runningCount();
    this.waitN = Downloader.waitingCount();
    this.warn = Downloader.overSoftLimit();
  }

  private async probeNet(): Promise<void> {
    const wifi: boolean = await Downloader.refreshNet();
    this.onWifi = wifi;
  }

  private mb(bytes: number): string {
    if (bytes <= 0) {
      return '—';
    }
    if (bytes >= 1073741824) {
      return `${(bytes / 1073741824).toFixed(1)} GB`;
    }
    if (bytes >= 1048576) {
      return `${(bytes / 1048576).toFixed(bytes >= 10485760 ? 0 : 1)} MB`;
    }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }

  private capText(): string {
    return this.maxGb <= 0 ? '不限' : `${this.maxGb} GB`;
  }

  /** 进度百分比（0–100）；总大小未知时给 -1，界面显示「已下 xx」。 */
  private pct(t: OfflineTask): number {
    if (t.status === 'done') {
      return 100;
    }
    if (t.total <= 0) {
      return -1;
    }
    const v = Math.floor((t.done * 100) / t.total);
    return v < 0 ? 0 : (v > 100 ? 100 : v);
  }

  private statusText(t: OfflineTask): string {
    if (t.status === 'done') {
      const when: string = t.lastOpen > 0 ? ' · 看过' : '';
      return `${this.mb(t.total)}${when}`;
    }
    if (t.status === 'run') {
      const p = this.pct(t);
      return p >= 0 ? `${p}%` : `已下 ${this.mb(t.done)}`;
    }
    if (t.status === 'waiting') {
      if (this.wifiOnly && !this.onWifi) {
        return '等 WiFi';
      }
      const pos: number = Downloader.waitingPos(t.mid, t.key);
      return pos > 0 ? `等待中 · 第 ${pos} 位` : '等待中';
    }
    if (t.status === 'fail') {
      return '下载失败，可重试';
    }
    return t.done > 0 ? `已暂停 · ${this.mb(t.done)}` : '未开始';
  }

  private async resume(t: OfflineTask): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const err: string = await Downloader.resume(t.mid, t.key);
    this.busy = false;
    if (err.length > 0) {
      promptAction.showToast({ message: err, duration: 1800 });
    }
    this.refresh();
  }

  private async pause(t: OfflineTask): Promise<void> {
    await Downloader.pause(t.mid, t.key);
    this.refresh();
  }

  private confirmRemove(t: OfflineTask): void {
    AlertDialog.show({
      title: '删掉这份缓存？',
      message: '手机会腾出空间；想再看需要重新下载。影片本身不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删掉',
        fontColor: Theme.DANGER,
        action: () => {
          Downloader.remove(t.mid, t.key);
          this.refresh();
        }
      }
    });
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空所有离线缓存？',
      message: `会删掉 ${this.tasks.length} 份缓存，腾出约 ${this.mb(this.totalBytes)}。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.DANGER,
        action: () => {
          Downloader.clearAll();
          this.refresh();
        }
      }
    });
  }

  /** 「按最久没看清理」：先算要删几部、腾多少，问过再删。 */
  private confirmPurge(): void {
    const plan: OfflineTask[] = Downloader.purgePlan();
    if (plan.length === 0) {
      promptAction.showToast({ message: '没有可以清理的缓存', duration: 1600 });
      return;
    }
    let freed: number = 0;
    for (let i = 0; i < plan.length; i++) {
      freed += plan[i].total;
    }
    AlertDialog.show({
      title: '按最久没看清理？',
      message: `会删掉 ${plan.length} 部最久没看的缓存，腾出约 ${this.mb(freed)}。` +
        '清理到上限的 80% 就停，不会一次清空。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: `删 ${plan.length} 部`,
        fontColor: Theme.DANGER,
        action: () => {
          const n: number = Downloader.purgeOldest();
          this.refresh();
          promptAction.showToast({ message: `已清理 ${n} 部缓存`, duration: 1800 });
        }
      }
    });
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
        Text('离线缓存')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(`${this.tasks.length} 份 · 已用 ${this.mb(this.totalBytes)} / ${this.capText()}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.tasks.length > 0) {
        Text('清空')
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(9)
          .onClick(() => {
            this.confirmClear();
          })
      }
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  /** 占用条 + 上限进度（到 90% 变金色，满了变红）。 */
  @Builder
  UsageBar() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(`已用 ${this.mb(this.totalBytes)}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
        if (this.maxGb > 0) {
          Text(`/ ${this.capText()}`)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          Blank()
          Text(`${this.usagePct}%`)
            .fontSize(11)
            .fontColor(this.warn ? Theme.DANGER : Theme.TEXT_FAINT)
        } else {
          Blank()
          Text('不限上限')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
      .width('100%')

      if (this.maxGb > 0) {
        Progress({
          value: this.usagePct,
          total: 100,
          type: ProgressType.Linear
        })
          .width('100%')
          .height(4)
          .color(this.warn ? Theme.DANGER : Theme.ACCENT)
          .backgroundColor(Theme.CARD_HI)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
  }

  /** 两个开关：只走 WiFi、上限（4/8/16/不限）。 */
  @Builder
  SettingsCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('只在 WiFi 下下载')
            .fontSize(12)
            .fontColor(Theme.TEXT)
          Text(this.wifiOnly
            ? (this.onWifi ? '当前在 WiFi，正常下载' : '当前是移动网络，排队等 WiFi')
            : '已关闭：移动网络下也会下载')
            .fontSize(10)
            .fontColor(this.wifiOnly && !this.onWifi ? Theme.GOLD : Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.wifiOnly })
          .selectedColor(Theme.ACCENT)
          .onChange((on: boolean) => {
            this.wifiOnly = on;
            Downloader.setWifiOnly(on);
            this.refresh();
            if (on) {
              this.probeNet();
            }
          })
      }
      .width('100%')

      Divider()
        .color(Theme.CARD_HI)

      Row({ space: 6 }) {
        Text('上限')
          .fontSize(12)
          .fontColor(Theme.TEXT)
        Blank()
        ForEach(LIMITS, (gb: number) => {
          Text(gb <= 0 ? '不限' : `${gb}G`)
            .fontSize(11)
            .fontColor(this.maxGb === gb ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.maxGb === gb ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(9)
            .onClick(() => {
              this.maxGb = gb;
              Downloader.setMaxGb(gb);
              this.refresh();
            })
        }, (gb: number) => `cap-${gb}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
  }

  /** 快满了的提示条（只在 90% 以上出现）。 */
  @Builder
  WarnBar() {
    Row({ space: 8 }) {
      Text('缓存快满了')
        .fontSize(12)
        .fontColor(Theme.DANGER)
      Text(`已用 ${this.mb(this.totalBytes)} / ${this.capText()}`)
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .layoutWeight(1)
      Text('按最久没看清理')
        .fontSize(11)
        .fontColor('#FFFFFF')
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.ACCENT)
        .borderRadius(9)
        .onClick(() => {
          this.confirmPurge();
        })
    }
    .width('100%')
    .padding(11)
    .backgroundColor(Theme.ACCENT_SOFT)
    .borderRadius(12)
  }

  @Builder
  TaskRow(t: OfflineTask) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Text(t.number.length > 0 ? t.number : `${t.mid}`)
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(6)
        Text(t.name.length > 0 ? t.name : '视频文件')
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.statusText(t))
          .fontSize(10)
          .fontColor(t.status === 'done' ? Theme.GOLD
            : (t.status === 'waiting' ? Theme.TEXT_DIM : Theme.TEXT_FAINT))
      }
      .width('100%')

      if (t.status === 'run' || (t.status === 'pause' && t.done > 0)) {
        Progress({ value: this.pct(t) < 0 ? 0 : this.pct(t), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(Theme.ACCENT)
          .backgroundColor(Theme.CARD_HI)
      }

      Row({ space: 8 }) {
        if (t.status === 'run') {
          Text('暂停')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
            .onClick(() => {
              this.pause(t);
            })
        } else if (t.status === 'waiting') {
          Text('取消排队')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
            .onClick(() => {
              this.pause(t);
            })
        } else if (t.status === 'done') {
          Text('播放')
            .fontSize(11)
            .fontColor(Theme.ACCENT)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(8)
            .onClick(() => {
              router.pushUrl({ url: 'pages/DetailPage', params: { 'id': t.mid } });
            })
        } else {
          Text('继续')
            .fontSize(11)
            .fontColor(Theme.ACCENT)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(8)
            .onClick(() => {
              this.resume(t);
            })
        }
        Blank()
        Text('删除')
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            this.confirmRemove(t);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 10 }) {
          if (this.warn) {
            this.WarnBar()
          }
          this.UsageBar()
          this.SettingsCard()

          if (this.tasks.length === 0) {
            Column({ space: 8 }) {
              Text('还没有离线缓存')
                .fontSize(13)
                .fontColor(Theme.TEXT_DIM)
              Text('在影片详情页点「下载」，下完断网也能看。')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .textAlign(TextAlign.Center)
                .lineHeight(15)
            }
            .width('100%')
            .padding({ top: 40, bottom: 20 })
            .justifyContent(FlexAlign.Center)
          } else {
            if (this.runN + this.waitN > 0) {
              Text(`正在下 ${this.runN} 个，排队 ${this.waitN} 个`)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
            }
            ForEach(this.tasks, (t: OfflineTask) => {
              this.TaskRow(t)
            }, (t: OfflineTask) => `off-${t.mid}-${t.key}-${t.status}-${t.done}`)
            Text('缓存存在 App 自己的空间里，卸载 App 会一起清掉。' +
              '下载时用的是只读播放地址，不额外占用你的流量以外的东西。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)
              .padding({ top: 4, bottom: Theme.BOTTOM_SAFE })
          }
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4 })
        // Scroll 会把短内容竖向居中（同 ProfileTab.ets:229），撑满最小高度才贴顶
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
