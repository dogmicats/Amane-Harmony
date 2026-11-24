/**
 * 年度报告（2.6.1.25）：把这一年看的东西讲成几屏，而不是一堆数字。
 *
 * 数据来自 `/api/user/stats/annual`（一次全取，翻的时候不再等）。
 * 设计上刻意**不联动统计页的筛选器**：年报说的是「这一整年」，一筛就不是年了；
 * 页顶只标「2026 · 全部片」和口径，免得跟统计页的数字对不上时说不清。
 *
 * 每屏一个主题，滚动即翻页：总量 → 最忙的一天 → 12 个月 → 几点看 → 最爱 → 偏好 → 连续。
 */
import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

interface AnnualBest {
  d: string;
  s: number;
  f: number;
}

interface AnnualFilm {
  id: number;
  number: string;
  title: string;
  seconds: number;
}

interface AnnualName {
  name: string;
  id: number;
  films: number;
  seconds: number;
}

/** 服务端 annual 的 data 段。 */
interface AnnualData {
  year: number;
  films: number;
  seconds: number;
  hours: number;
  days: number;
  finished_days: number;
  months: number[];
  hour_secs: number[];
  best: AnnualBest | null;
  max_streak: number;
  from: string | null;
  to: string | null;
  top_films: AnnualFilm[];
  top_actors: AnnualName[];
  top_tags: AnnualName[];
}

interface AnnualEnvelope {
  ok: boolean;
  confidence: string;
  reason?: string;
  data: AnnualData;
}

function emptyAnnual(year: number): AnnualData {
  return {
    year: year, films: 0, seconds: 0, hours: 0, days: 0, finished_days: 0,
    months: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    hour_secs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    best: null, max_streak: 0, from: null, to: null,
    top_films: [], top_actors: [], top_tags: []
  };
}

/** 秒 → 「3 小时 12 分」/「12 分钟」/「不到 1 分钟」。 */
function dur(secs: number): string {
  const s: number = Math.round(secs);
  if (s <= 0) {
    return '0 分钟';
  }
  if (s < 60) {
    return '不到 1 分钟';
  }
  const h: number = Math.floor(s / 3600);
  const m: number = Math.round((s % 3600) / 60);
  if (h <= 0) {
    return `${m} 分钟`;
  }
  if (m <= 0) {
    return `${h} 小时`;
  }
  return `${h} 小时 ${m} 分`;
}

function monthName(i: number): string {
  return `${i + 1} 月`;
}

@Entry
@Component
struct YearReportPage {
  @State data: AnnualData = emptyAnnual(new Date().getFullYear());
  @State loading: boolean = true;
  @State err: string = '';
  @State year: number = new Date().getFullYear();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.err = '';
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/stats/annual?year=${this.year}`, Store.I.token);
      const env: AnnualEnvelope = JSON.parse(text) as AnnualEnvelope;
      if (env.data !== undefined && env.data !== null) {
        this.data = env.data;
      }
      if (!env.ok) {
        this.err = env.reason === undefined ? '这一年还没有观看记录' : env.reason;
      }
    } catch (e) {
      const be = e as BusinessError;
      this.err = `取不到年报（${be.code}）`;
      console.info(`[amane] annual: ${be.code} ${be.message}`);
    }
    this.loading = false;
  }

  /** 12 个月的峰值，柱高按它归一。 */
  private monthPeak(): number {
    let p: number = 0;
    for (let i = 0; i < this.data.months.length; i++) {
      if (this.data.months[i] > p) {
        p = this.data.months[i];
      }
    }
    return p;
  }

  private hourPeak(): number {
    let p: number = 0;
    for (let i = 0; i < this.data.hour_secs.length; i++) {
      if (this.data.hour_secs[i] > p) {
        p = this.data.hour_secs[i];
      }
    }
    return p;
  }

  /** 一天里最集中的两个小时（「你多半在 22 点看」）。 */
  private peakHourText(): string {
    let best: number = -1;
    let bestV: number = 0;
    for (let i = 0; i < this.data.hour_secs.length; i++) {
      if (this.data.hour_secs[i] > bestV) {
        bestV = this.data.hour_secs[i];
        best = i;
      }
    }
    if (best < 0 || bestV <= 0) {
      return '';
    }
    const tail: string = best >= 23 ? '（跨零点）' : '';
    return `${best} 点 – ${best + 1} 点${tail}`;
  }

  @Builder
  SectionHeadText(title: string, sub: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      Text(sub === '__peak_hour__' ? `最集中的时段：${this.peakHourText()}` : sub)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 12 })
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
        PageTitle({ text: `${this.year} 观影年报`, fs: 18 })
        Blank()
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 6, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  /** 真·全屏（七十二改）：窗口铺到系统栏后面；离开本页不关，见 common/PageFullscreen。 */
  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()
        Column() {

  // 六十改：让出浮层标题栏的高度
  Blank().height(this.barH())

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.err.length > 0) {
          Column({ space: 10 }) {
            Text(this.err)
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
            Text('换一年试试')
              .fontSize(11)
              .fontColor(Theme.ACCENT_INK)
              .onClick(() => {
                this.year = this.year - 1;
                this.load();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 14 }) {
              // ① 总量
              Column({ space: 8 }) {
                Text(`${this.data.year}`)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ACCENT_INK)
                  .fontFeature('"tnum" 1')
                Text(`${this.data.hours} 小时`)
                  .fontSize(40)
                  .fontColor(Theme.TEXT)
                  .fontWeight(FontWeight.Bold)
                Text(`看了 ${this.data.films} 部 · ${this.data.days} 天有动静`)
                  .fontSize(12)
                  .fontColor(Theme.TEXT_DIM)
                Text(`平均每次坐下来看 ${dur(this.data.seconds / Math.max(1, this.data.days))}`)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ top: 18, bottom: 18 })
              .alignItems(HorizontalAlign.Center)

              // ② 最忙的一天
              if (this.data.best !== null) {
                Column({ space: 8 }) {
                  this.SectionHeadText('最投入的一天', '这一天你坐得最久')
                  Text(this.data.best.d)
                    .fontSize(20)
                    .fontColor(Theme.GOLD)
                  Text(`那天看了 ${this.data.best.f} 部，合计 ${dur(this.data.best.s)}`)
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14)
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
              }

              // ③ 12 个月
              Column() {
                this.SectionHeadText('一年十二个月', '柱子的高矮 = 那个月看了多久')
                Row({ space: 6 }) {
                  ForEach(this.data.months, (v: number, i: number) => {
                    Column() {
                      Column()
                        .width('100%')
                        .height(Math.max(2, Math.round(v / Math.max(1, this.monthPeak()) * 62)))
                        .backgroundColor(v > 0 ? Theme.alphaOf(Theme.ACCENT,
                          Math.max(0.25, v / Math.max(1, this.monthPeak()) * 0.9)) : Theme.CARD_HI)
                        .borderRadius(3)
                    }
                    .layoutWeight(1)
                    .height(64)
                    .justifyContent(FlexAlign.End)
                  }, (v: number, i: number) => `mo-${i}`)
                }
                .width('100%')
                .alignItems(VerticalAlign.Bottom)

                Row({ space: 6 }) {
                  ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], (m: number) => {
                    Text(`${m}`)
                      .fontSize(8)
                      .fontColor(Theme.TEXT_FAINT)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                  }, (m: number) => `mn-${m}`)
                }
                .width('100%')
                .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })

              // ④ 几点看
              if (this.peakHourText().length > 0) {
                Column({ space: 8 }) {
                  this.SectionHeadText('你多半在几点看', '__peak_hour__')
                  Row({ space: 2 }) {
                    ForEach(this.data.hour_secs, (v: number, i: number) => {
                      Column()
                        .layoutWeight(1)
                        .height(Math.max(3, Math.round(v / Math.max(1, this.hourPeak()) * 40)))
                        .backgroundColor(v > 0 ? Theme.alphaOf(Theme.ACCENT2,
                          Math.max(0.22, v / Math.max(1, this.hourPeak()) * 0.9)) : Theme.CARD_HI)
                        .borderRadius(2)
                    }, (v: number, i: number) => `hr-${i}`)
                  }
                  .width('100%')
                  .height(42)
                  .alignItems(VerticalAlign.Bottom)
                  Row() {
                    Text('0 点').fontSize(8).fontColor(Theme.TEXT_FAINT)
                    Blank()
                    Text('12 点').fontSize(8).fontColor(Theme.TEXT_FAINT)
                    Blank()
                    Text('23 点').fontSize(8).fontColor(Theme.TEXT_FAINT)
                  }
                  .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14)
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
              }

              // ⑤ 看得最久的几部
              if (this.data.top_films.length > 0) {
                Column({ space: 8 }) {
                  this.SectionHeadText('看得最久的几部', '按这一年累计的播放时长排')
                  ForEach(this.data.top_films.slice(0, 5), (f: AnnualFilm, i: number) => {
                    Row({ space: 8 }) {
                      Text(`${i + 1}`)
                        .fontSize(11)
                        .fontColor(i < 3 ? Theme.GOLD : Theme.TEXT_FAINT)
                        .width(16)
                      Column({ space: 2 }) {
                        Text(f.number.length > 0 ? f.number : `#${f.id}`)
                          .fontSize(11)
                          .fontColor(Theme.ACCENT_INK)
                        if (f.title.length > 0) {
                          Text(f.title)
                            .fontSize(10)
                            .fontColor(Theme.TEXT_DIM)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Text(dur(f.seconds))
                        .fontSize(10)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width('100%')
                    .padding({ top: 4, bottom: 4 })
                  }, (f: AnnualFilm) => `tf-${f.id}`)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14)
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
              }

              // ⑥ 偏好：演员 / 标签
              if (this.data.top_actors.length > 0 || this.data.top_tags.length > 0) {
                Column({ space: 10 }) {
                  this.SectionHeadText('这一年偏谁、偏什么', '按有看的部数算')
                  if (this.data.top_actors.length > 0) {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.data.top_actors, (a: AnnualName) => {
                        Text(a.name)
                          .fontSize(11)
                          .fontColor(Theme.TEXT)
                          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                          .backgroundColor(Theme.CARD_HI)
                          .borderRadius(11)
                          .margin({ right: 6, bottom: 6 })
                      }, (a: AnnualName) => `ta-${a.id}-${a.name}`)
                    }
                    .width('100%')
                  }
                  if (this.data.top_tags.length > 0) {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.data.top_tags, (t: AnnualName) => {
                        Text(`# ${t.name}`)
                          .fontSize(11)
                          .fontColor(Theme.TEXT_DIM)
                          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                          .backgroundColor(Theme.CARD_HI)
                          .borderRadius(11)
                          .margin({ right: 6, bottom: 6 })
                      }, (t: AnnualName) => `tt-${t.id}-${t.name}`)
                    }
                    .width('100%')
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14)
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
              }

              // ⑦ 连续
              if (this.data.max_streak > 1) {
                Column({ space: 6 }) {
                  this.SectionHeadText('最长的一段', '连续有观看的天数')
                  Text(`${this.data.max_streak} 天`)
                    .fontSize(24)
                    .fontColor(Theme.TEXT)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14)
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
              }

              Text(this.data.from !== null && this.data.to !== null
                ? `${this.data.from} ~ ${this.data.to} · 数据来自这台设备的上报`
                : '数据来自这台设备的上报')
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .padding({ top: 2, bottom: 26 })
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
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
