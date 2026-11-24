import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { GlassBack, GlassBox, GlassCapsule, PageTitle } from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

/** 服务端 pending_pick 的一行历史。 */
interface PickHistory {
  number: string;
  decision: string;
  target: string;
  state: string;
  source: string;
  created_at: string;
  updated_at: string;
  /** 服务端 pending_history 现补：海报（已过 public_image 代理）与标题，用来认片。 */
  poster: string;
  title: string;
}

/**
 * 「要 / 不要」的决策记录（2026-11-19 用户要的设置页）。
 *
 * 为什么单独一页：这些片点完就从标签里消失了（不然列表里永远有已决定的），
 * 那"我到底点过什么"就没地方看了。服务端 pending_pick 表留着全部记录，
 * 这里按最近更新倒序列出来，附带「存哪 / 现在什么状态」。
 */
@Entry
@Component
struct PendingHistoryPage {
  @State loading: boolean = true;
  @State err: string = '';
  @State tip: string = '';
  @State items: PickHistory[] = [];
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  /**
   * 还原（2026-11-19 用户要的「后悔」入口）。
   *
   * 服务端会把标签挂回去、把这条标成 restore；NAS 上的 worker 下一轮清黑名单再删记录。
   * 所以这里点完立刻重拉一次：标签已回来，但决策行还在（显示「已还原」），
   * 到 worker 那轮才彻底消失。
   */
  private async restore(it: PickHistory): Promise<void> {
    try {
      const body: string = JSON.stringify({ number: it.number });
      await httpPost(`${Store.I.user}/api/user/pending/restore`, Store.I.token, body);
      this.tip = `${it.number} 已还原：标签挂回去了，下载黑名单等后台那轮清`;
      setTimeout(() => {
        this.tip = '';
      }, 3000);
      this.load();
    } catch (err) {
      const e = err as BusinessError;
      this.tip = e.code === 404 ? '还原失败：服务端没有这条记录' : '还原失败，请重试';
      setTimeout(() => {
        this.tip = '';
      }, 2500);
    }
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/pending/history?limit=300`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const raw = obj.items as PickHistory[];
      this.items = raw === undefined || raw === null ? [] : raw;
      this.err = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pending history: ${e.code} ${e.message}`);
      this.err = e.code === 404 ? '服务端未启用待下载扩展' : '加载失败，下拉重试';
    }
    this.loading = false;
  }

  private title(): string {
    let w: number = 0;
    let s: number = 0;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].decision === 'want') {
        w++;
      } else if (this.items[i].decision === 'skip') {
        s++;
      }
    }
    return `决策记录 · 要 ${w} / 不要 ${s}`;
  }

  private stateText(it: PickHistory): string {
    const st: string = it.state;
    if (it.decision === 'want') {
      if (st === 'new') {
        return '待提交';
      }
      if (st === 'submitted') {
        return '已交 115';
      }
      if (st === 'done') {
        return '已完成';
      }
      return st;
    }
    if (st === 'skipped') {
      return '待清理';
    }
    if (st === 'done') {
      return '已清理';
    }
    return st;
  }

  private stateColor(it: PickHistory): string {
    const st: string = it.state;
    if (st === 'done') {
      return Theme.TEXT_FAINT;
    }
    if (st === 'submitted') {
      return Theme.ACCENT;
    }
    return Theme.GOLD;
  }

  private when(iso: string): string {
    if (iso === undefined || iso === null || iso.length < 16) {
      return '';
    }
    return iso.substring(0, 16).replace('T', ' ');
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 8 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        GlassBox({ radius: 23, padH: 14, padV: 9, mat: true }) {
          PageTitle({ text: '决策记录', fs: 18 })
        }
        Blank()
        GlassCapsule({
          label: '刷新',
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          mat: true,
          onTap: () => {
            this.load();
          }
        })
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 10, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  private barH(): number {
    return this.topInset + 46;
  }

  @Builder
  Row(it: PickHistory) {
    Row({ space: 11 }) {
      // 带海报的缩略图（2026-11-20 用户要）：认得出是哪部才好决定要不要反悔。
      // 决策符号压在海报左下角；无海报时用番号首字母兜底，不留空框。
      Stack({ alignContent: Alignment.BottomStart }) {
        if (it.poster !== undefined && it.poster.length > 0) {
          Image(Store.I.img(it.poster))
            .width(52)
            .height(72)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor(Theme.CARD)
            .alt(it.number.substring(0, 1))
        } else {
          Column() {
            Text(it.number.substring(0, 1))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width(52)
          .height(72)
          .borderRadius(6)
          .backgroundColor('#1AFFFFFF')
          .justifyContent(FlexAlign.Center)
        }
        Text(it.decision === 'want' ? '✓' : '✕')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(it.decision === 'want' ? Theme.ACCENT : Theme.DANGER)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor('#CC000000')
          .borderRadius({ topLeft: 0, topRight: 6, bottomLeft: 6, bottomRight: 0 })
          .margin({ left: 0, top: 0 })
      }
      .width(52)
      .height(72)

      Column({ space: 4 }) {
        Text(it.number)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (it.title !== undefined && it.title.length > 0) {
          Text(it.title)
            .fontSize(12)
            .fontColor(Theme.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Row({ space: 6 }) {
          Text(this.stateText(it))
            .fontSize(10)
            .fontColor(this.stateColor(it))
          if (it.decision === 'want') {
            Text(it.target === 'jav' ? '→ 网盘JAV' : '→ 网盘破解')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
          }
          Text(this.when(it.updated_at))
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 后悔药：标签挂回去、黑名单放行（worker 下一轮清）
      if (it.decision === 'restore') {
        Text('已还原')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .padding({ left: 8, right: 4 })
      } else {
        Text('还原')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .borderRadius(9)
          .backgroundColor('#1AFFFFFF')
          .onClick(() => {
            this.restore(it);
          })
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(11)
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()
        Column() {
        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.err.length > 0) {
          Text(this.err)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .padding(24)
            .onClick(() => {
              this.load();
            })
        } else if (this.items.length === 0) {
          Column({ space: 10 }) {
            Text('◇')
              .fontSize(32)
              .fontColor(Theme.TEXT_FAINT)
            Text('还没有点过「要 / 不要」')
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Row({ space: 8 }) {
            Text(this.title())
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: this.barH() + 6, bottom: 6 })

          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(11)
              .fontColor(Theme.GOLD)
              .width('100%')
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
          }

          List({ space: 8 }) {
            ForEach(this.items, (it: PickHistory) => {
              ListItem() {
                this.Row(it)
              }
            }, (it: PickHistory) => `${it.number}_${it.updated_at}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
        }
      }
      .width('100%')
      .height('100%')

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
