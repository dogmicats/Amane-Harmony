/**
 * 今天的推荐理由（2.6.1.32）
 *
 * 原来是详情页上方弹出的抽屉（bindSheet）。两个问题：
 * ① 抽屉被另一个页面压住时系统会**自动收起**，返回时不会自己回来 —— 点一条理由进详情、
 *    再返回就掉回首页了（2.6.1.28 用状态变量修过，无效，这是 sheet 的生命周期）；
 * ② 抽屉右上角同时有系统自带的 ✕ 和我们自己的「关闭」，两个按钮挨着，看着像 bug。
 * 改成独立页面后两个问题一起消失：返回必然回到这一页（页面栈），也没有多余按钮。
 *
 * **卡片的样式是照搬抽屉的**（用户明确要求「一条一条排列的样式不要变」）：
 * 左封面 46×66 + 番号·标题 + 金色主句（左侧 2vp 金色细线）+ 可选补充句。
 *
 * 数据只读 `Reason.today()`（当天快照），不重新生成 —— 句子按天固定，换个入口看必须同一批话。
 */
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams, HomeData, MediaItem } from '../common/Types';
import { safeHome } from '../common/Safe';
import { Reason, ReasonLine } from '../common/Reason';

@Entry
@Component
struct ReasonsPage {
  @State lines: ReasonLine[] = [];
  /** 只用来取封面：理由快照里不存图片地址。 */
  @State posters: MediaItem[] = [];

  aboutToAppear(): void {
    this.lines = Reason.today();
    this.loadCovers();
  }

  /** 封面走首页同一批 items（快照里只有 id/番号/标题）。失败就不画封面，不影响理由。 */
  private async loadCovers(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/home`, Store.I.token);
      const home: HomeData = safeHome(JSON.parse(text) as HomeData);
      this.posters = home.banners.length > 0 ? home.banners : home.recommend;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] reason covers: ${e.code}`);
    }
  }

  private coverOf(id: number): string {
    for (let i = 0; i < this.posters.length; i++) {
      if (this.posters[i].id === id) {
        return this.posters[i].poster.length > 0 ? this.posters[i].poster : this.posters[i].fanart;
      }
    }
    return '';
  }

  /** 真正写出了说法的条目（空理由的不摆，抽屉里也是这么处理的）。 */
  private shown(): ReasonLine[] {
    const out: ReasonLine[] = [];
    for (let i = 0; i < this.lines.length; i++) {
      if (this.lines[i].reason.length > 0) {
        out.push(this.lines[i]);
      }
    }
    return out;
  }

  private count(): number {
    let n: number = 0;
    for (let i = 0; i < this.lines.length; i++) {
      if (this.lines[i].reason.length > 0) {
        n++;
      }
      if (this.lines[i].extra.length > 0) {
        n++;
      }
    }
    return n;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(22)
          .fontColor(Theme.TEXT)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Column({ space: 2 }) {
          Text('今天的推荐理由')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text('每天换一种说法，同一部片当天不变')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')
      .padding({ left: 6, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      if (this.shown().length === 0) {
        Column({ space: 8 }) {
          Text('今天还没有推荐理由')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
          Text('推荐位空着、或者「推荐理由」开关关掉了')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.shown(), (l: ReasonLine) => {
              Row({ space: 12 }) {
                if (this.coverOf(l.id).length > 0) {
                  Image(Store.I.img(this.coverOf(l.id)))
                    .width(46)
                    .height(66)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(7)
                    .backgroundColor(Theme.CARD_HI)
                    .alt($r('app.media.placeholder'))
                }
                Column({ space: 7 }) {
                  Row({ space: 6 }) {
                    Text(l.number)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .maxLines(1)
                    Text('·')
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                    Text(l.title)
                      .fontSize(11)
                      .fontColor(Theme.TEXT_DIM)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')

                  // 一句话是这张卡的重点（与抽屉同一套：15px 金色 + 左侧 2vp 细线）
                  Text(l.reason)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.GOLD)
                    .width('100%')
                    .lineHeight(24)
                    .padding({ left: 9 })
                    .border({
                      width: { left: 2 },
                      color: { left: Theme.GOLD }
                    })

                  if (l.extra.length > 0) {
                    Text(l.extra)
                      .fontSize(11)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                      .lineHeight(17)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(12)
              .alignItems(VerticalAlign.Top)
              .onClick(() => {
                const params: DetailParams = { id: l.id };
                router.pushUrl({ url: 'pages/DetailPage', params: params });
              })
            }, (l: ReasonLine) => `rp-${l.id}`)

            Column({ space: 4 }) {
              Divider().color(Theme.CARD_HI).margin({ bottom: 6 })
              Text(`共 ${this.count()} 句 · 每天换一种说法，同一部片当天不变`)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
            }
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
    .backgroundColor(Theme.BG)
  }
}
