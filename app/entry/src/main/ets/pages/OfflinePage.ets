import { promptAction, router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Downloader, OfflineTask } from '../common/Downloader';
import { Theme } from '../common/Theme';
import { GlassBack, GlassBox, PageTitle } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsBarSectionTitle, SettingsRowDivider, VelvetChip
} from '../view/SettingsKit';

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';

const LIMITS: number[] = [4, 8, 16, 0];

@Entry
@Component
struct OfflinePage {
  @State st: string = ST_LOADING;
  @State tasks: OfflineTask[] = [];
  @State totalBytes: number = 0;
  @State usagePct: number = 0;
  @State busy: boolean = false;
  @State wifiOnly: boolean = true;
  @State maxGb: number = 8;
  @State warn: boolean = false;
  @State onWifi: boolean = true;
  @State runN: number = 0;
  @State waitN: number = 0;
  @State orphanBytes: number = 0;
  @State orphanFiles: number = 0;
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();
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
    const o: number[] = Downloader.orphanStats();
    this.orphanBytes = o[0];
    this.orphanFiles = o[1];
  }

  private confirmOrphans(): void {
    AlertDialog.show({
      title: '清理残留文件？',
      message: `盘上有 ${this.orphanFiles} 个文件（${this.mb(this.orphanBytes)}）不在列表中，清理不影响现有离线影片。`,
      primaryButton: {
        value: '清理',
        fontColor: Theme.DANGER,
        action: () => {
          const freed: number = Downloader.clearOrphans();
          promptAction.showToast({
            message: freed > 0 ? `已释放 ${this.mb(freed)}` : '没有可清理的文件',
            duration: 1800
          });
          this.refresh();
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  private async probeNet(): Promise<void> {
    const wifi: boolean = await Downloader.refreshNet();
    this.onWifi = wifi;
  }

  private mb(bytes: number): string {
    if (bytes <= 0) {
      return '0 MB';
    }
    if (bytes >= 1073741824) {
      return `${(bytes / 1073741824).toFixed(2)} GB`;
    }
    if (bytes >= 1048576) {
      return `${(bytes / 1048576).toFixed(bytes >= 10485760 ? 0 : 1)} MB`;
    }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }

  private capText(): string {
    return this.maxGb <= 0 ? '不限' : `${this.maxGb} GB`;
  }

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
      const when: string = t.lastOpen > 0 ? ' · 已看' : '';
      return `已缓存 · ${this.mb(t.total)}${when}`;
    }
    if (t.status === 'run') {
      const p = this.pct(t);
      return p >= 0 ? `下载中 · ${p}%` : `已下 ${this.mb(t.done)}`;
    }
    if (t.status === 'waiting') {
      if (this.wifiOnly && !this.onWifi) {
        return '等待 WiFi';
      }
      const pos: number = Downloader.waitingPos(t.mid, t.key);
      return pos > 0 ? `排队中 · 第 ${pos} 位` : '排队中';
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
      title: '删除这份缓存？',
      message: '手机将释放对应空间，影片本身不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
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
      message: `将删除 ${this.tasks.length} 份缓存，释放约 ${this.mb(this.totalBytes)}。`,
      primaryButton: {
        value: '取消',
        action: () => {}
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

  private confirmPurge(): void {
    const plan: OfflineTask[] = Downloader.purgePlan();
    if (plan.length === 0) {
      promptAction.showToast({ message: '没有可清理的缓存', duration: 1600 });
      return;
    }
    let freed: number = 0;
    for (let i = 0; i < plan.length; i++) {
      freed += plan[i].total;
    }
    AlertDialog.show({
      title: '按最久未看清理？',
      message: `将删除 ${plan.length} 部最久未看的缓存，释放约 ${this.mb(freed)}。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: `清理 ${plan.length} 部`,
        fontColor: Theme.DANGER,
        action: () => {
          const n: number = Downloader.purgeOldest();
          this.refresh();
          promptAction.showToast({ message: `已清理 ${n} 部缓存`, duration: 1800 });
        }
      }
    });
  }

  /** 合并的配额 + 规则黑曜石卡。 */
  @Builder
  QuotaRulesCard() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Row() {
          Text('离线空间占用')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Blank()
          Text(`${this.mb(this.totalBytes)} / ${this.capText()}`)
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.warn ? Theme.DANGER : Theme.ACCENT_INK)
            .fontFeature('"tnum" 1')
        }
        .width('100%')

        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width('100%')
            .height(7)
            .borderRadius(3.5)
            .backgroundColor('#1AFFFFFF')
          if (this.maxGb > 0 && this.usagePct > 0) {
            Column()
              .width(`${Math.min(100, Math.max(4, this.usagePct))}%`)
              .height(7)
              .borderRadius(3.5)
              .linearGradient(this.warn
                ? { angle: 90, colors: [[Theme.DANGER, 0.0], ['#FF9A9A', 1.0]] }
                : Theme.ctaGradient())
          }
        }
        .width('100%')
        .height(7)
      }
      .width('100%')

      SettingsRowDivider({ indent: 0 })

      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('仅 WiFi 下下载')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(this.wifiOnly
            ? (this.onWifi ? '当前在 WiFi，正常下载' : '当前为移动网络，排队等待 WiFi')
            : '移动网络下也会继续下载')
            .fontSize(10.5)
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

      SettingsRowDivider({ indent: 0 })

      Column({ space: 8 }) {
        Text('缓存上限')
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
          .width('100%')
        Row({ space: 7 }) {
          ForEach(LIMITS, (gb: number) => {
            VelvetChip({
              label: gb <= 0 ? '不限' : `${gb} GB`,
              active: this.maxGb === gb,
              padH: 12,
              padV: 6,
              fs: 11.5,
              onTap: () => {
                this.maxGb = gb;
                Downloader.setMaxGb(gb);
                this.refresh();
              }
            })
          }, (gb: number) => `cap-${gb}-${this.maxGb === gb ? 1 : 0}`)
        }
        .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 145,
      colors: [[Theme.accentAlpha(0.11), 0.0], ['#00000000', 0.60]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  WarnBar() {
    Row({ space: 8 }) {
      Text('缓存快满了')
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.DANGER)
      Text(`${this.mb(this.totalBytes)} / ${this.capText()}`)
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .fontFeature('"tnum" 1')
        .layoutWeight(1)
      Text('按最久未看清理')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.ACCENT_INK)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.accentAlpha(0.20))
        .border({ width: 0.75, color: Theme.inkAlpha(0.48) })
        .borderRadius(Theme.R_PILL)
        .onClick(() => {
          this.confirmPurge();
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.14))
    .border({ width: 0.75, color: Theme.alphaOf(Theme.DANGER, 0.36) })
    .borderRadius(16)
  }

  @Builder
  OrphanBar() {
    Row({ space: 8 }) {
      Text(`${this.orphanFiles} 个残留文件`)
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.GOLD)
      Text(this.mb(this.orphanBytes))
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .fontFeature('"tnum" 1')
        .layoutWeight(1)
      Text('清理')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.GOLD)
        .padding({ left: 11, right: 11, top: 5, bottom: 5 })
        .backgroundColor('#24FFD06B')
        .border({ width: 0.5, color: '#4DFFD06B' })
        .borderRadius(Theme.R_PILL)
        .onClick(() => {
          this.confirmOrphans();
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#18FFD06B')
    .border({ width: 0.75, color: '#38FFD06B' })
    .borderRadius(16)
  }

  @Builder
  TaskRow(t: OfflineTask) {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(t.number.length > 0 ? t.number : `#${t.mid}`)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ACCENT_INK)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(Theme.accentAlpha(0.18))
            .border({ width: 0.5, color: Theme.inkAlpha(0.38) })
            .borderRadius(Theme.R_PILL)
          Text(t.name.length > 0 ? t.name : '视频文件')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (t.status === 'done') {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor(['#8EE6B4'])
            Text(this.statusText(t))
              .fontSize(10.5)
              .fontColor('#8EE6B4')
              .fontFeature('"tnum" 1')
          }
          .padding({ left: 8, right: 9, top: 3, bottom: 3 })
          .backgroundColor('#1A45B075')
          .border({ width: 0.5, color: '#4245B075' })
          .borderRadius(Theme.R_PILL)
        } else {
          Text(this.statusText(t))
            .fontSize(11)
            .fontColor(t.status === 'run' ? Theme.ACCENT_INK : (t.status === 'fail' ? Theme.DANGER : Theme.TEXT_FAINT))
            .fontFeature('"tnum" 1')

          if (t.status === 'run' || (t.status === 'pause' && t.done > 0)) {
            Stack({ alignContent: Alignment.Start }) {
              Column().width('100%').height(4).borderRadius(2).backgroundColor('#1AFFFFFF')
              Column()
                .width(`${Math.max(4, this.pct(t) < 0 ? 12 : this.pct(t))}%`)
                .height(4)
                .borderRadius(2)
                .linearGradient(Theme.ctaGradient())
            }
            .width('100%')
            .height(4)
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右侧操作按钮组
      Row({ space: 8 }) {
        if (t.status === 'done') {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(13)
              .fontColor([Theme.ON_ACCENT])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .linearGradient(Theme.ctaGradient())
          .border({ width: 0.5, color: '#38FFFFFF' })
          .onClick(() => {
            router.pushUrl({ url: 'pages/DetailPage', params: { 'id': t.mid } });
          })
        } else if (t.status === 'run' || t.status === 'waiting') {
          Text(t.status === 'run' ? '暂停' : '取消')
            .fontSize(11)
            .fontColor(Theme.TEXT)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#18FFFFFF')
            .border({ width: 0.5, color: '#26FFFFFF' })
            .borderRadius(Theme.R_PILL)
            .onClick(() => {
              this.pause(t);
            })
        } else {
          Text('继续')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ACCENT_INK)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(Theme.accentAlpha(0.18))
            .border({ width: 0.75, color: Theme.inkAlpha(0.46) })
            .borderRadius(Theme.R_PILL)
            .onClick(() => {
              this.resume(t);
            })
        }

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(14)
            .fontColor([Theme.DANGER])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.14))
        .border({ width: 0.5, color: Theme.alphaOf(Theme.DANGER, 0.34) })
        .onClick(() => {
          this.confirmRemove(t);
        })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
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
        PageTitle({ text: '下载管理', fs: 18 })
        Blank()
        if (this.tasks.length > 0) {
          GlassBox({
            radius: 18,
            padH: 12,
            padV: 7,
            mat: true,
            onTap: () => {
              this.confirmClear();
            }
          }) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(13)
                .fontColor([Theme.DANGER])
              Text('清空')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.DANGER)
            }
            .alignItems(VerticalAlign.Center)
          }
        }
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
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        Scroll() {
          Column({ space: 14 }) {
            Blank().height(this.barH() + 6)

            if (this.warn) {
              this.WarnBar()
            }
            this.QuotaRulesCard()
            if (this.orphanFiles > 0) {
              this.OrphanBar()
            }

            SettingsBarSectionTitle({ title: '下载队列', count: `${this.tasks.length}` })

            if (this.tasks.length === 0) {
              Column({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.download'))
                  .fontSize(28)
                  .fontColor([Theme.TEXT_FAINT])
                Text('还没有离线缓存')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_DIM)
                Text('在影片详情页点「下载」，下完断网也能看。')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ top: 44, bottom: 24 })
              .justifyContent(FlexAlign.Center)
            } else {
              Column() {
                ForEach(this.tasks, (t: OfflineTask, idx: number) => {
                  Column() {
                    if (idx > 0) {
                      SettingsRowDivider({ indent: 14 })
                    }
                    this.TaskRow(t)
                  }
                  .width('100%')
                }, (t: OfflineTask) => `off-${t.mid}-${t.key}-${t.status}-${t.done}`)
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)

              Text('离线文件保存在应用空间内，卸载应用时会一并清除。')
                .fontSize(10.5)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .padding({ left: 4, top: 2, bottom: Theme.pageBottomSafe() })
            }
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
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
}
