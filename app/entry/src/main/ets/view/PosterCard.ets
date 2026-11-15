import { MediaItem } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { scoreText } from '../common/Util';
import { rateLabel, rateColor } from '../ext/ratings/RatingStars';
import { MarkBadges } from './MarkBadges';

/**
 * 首屏错落入场（2.6.1.18）：**模块级**计数器，不需要调用方传 index。
 *
 * 一批卡片在同一帧里连续 `aboutToAppear`，按出现顺序每张差 18ms，最多推到 240ms；
 * 两批之间有 140ms 以上的空档就重置。超过 520ms 才出现的卡片（滚动补进来的）
 * 直接显示、不播动画 —— 否则一边滑一边有卡片在闪，比没有动画更糟。
 *
 * 为什么不用 `ForEach` 的 index：`PosterCard` 被十几个页面复用，
 * 每处都改签名风险远大于收益，这里自己排一下就够了。
 */
let batchSeq: number = 0;
let batchAt: number = 0;

/**
 * 海报卡：宽 116 固定，右上角评分，底部进度条（有播放进度时）。
 * 普通成员（非 @State）：内容由父组件的 ForEach 负责重建。
 */
@Component
export struct PosterCard {
  item: MediaItem = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    updated_at: '', position: 0, duration: 0
  };
  cardWidth: number = Theme.POSTER_W;
  showNumber: boolean = true;
  /** 自适应宽度（网格里用）：宽 100%，海报按 0.704 竖版比例撑高。 */
  fluid: boolean = false;
  showTitle: boolean = true;
  /** 第三行显示发行日期（媒体库网格用，信息密度和原来一致）。 */
  showDate: boolean = false;
  onTap: () => void = () => {};
  /** 入场动画是否已经播过（见文件头的「首屏错落入场」）。 */
  @State private shown: boolean = false;
  /** 按下态（缩放反馈）。 */
  @State private press: boolean = false;
  @StorageProp('amaneFx') private fx: number = 2;

  aboutToAppear(): void {
    const now: number = Date.now();
    if (this.fx <= 0 || now - batchAt > 140) {
      batchSeq = 0;
      batchAt = now;
    }
    if (this.fx <= 0 || now - batchAt > 520) {
      this.shown = true;
      return;
    }
    const delay: number = Math.min(240, batchSeq * 18);
    batchSeq++;
    if (delay === 0) {
      this.shown = true;
      return;
    }
    setTimeout(() => {
      this.shown = true;
    }, delay);
  }

  private itemMarks(): string[] {
    if (this.item.marks === undefined || this.item.marks === null) {
      return [];
    }
    return this.item.marks;
  }

  /** 我打的分（0 = 没打过）。老服务端不返回该字段，safeItem 已兜成 0。 */
  private myRating(): number {
    const v: number = this.item.my_rating === undefined ? 0 : this.item.my_rating;
    return v > 0 ? Math.min(5, Math.trunc(v)) : 0;
  }

  private ratio(): number {
    if (this.item.duration > 0 && this.item.position > 0) {
      return Math.min(100, Math.max(1, this.item.position / this.item.duration * 100));
    }
    return 0;
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        // 内层只放「图片 + 底部进度条」：图片自己有确定高度（aspectRatio / 固定高），
        // 进度条贴在底边对齐，不再用 height('100%') 的浮层。
        // 之前那层 100% 高的 Column 在 Grid 里没有确定父高，会把整个单元格撑到
        // 一屏高——带播放记录的影片出现在中间时，元素就「乱飞」（网格行高被它顶开）。
        Stack({ alignContent: Alignment.BottomStart }) {
          if (this.fluid) {
            Image(Store.I.img(this.item.poster))
              .width('100%')
              .aspectRatio(0.704)
              .objectFit(ImageFit.Cover)
              .backgroundColor(Theme.CARD)
              .alt($r('app.media.placeholder'))
          } else {
            Image(Store.I.img(this.item.poster))
              .width(this.cardWidth)
              .height(this.cardWidth * 1.42)
              .objectFit(ImageFit.Cover)
              .backgroundColor(Theme.CARD)
              .alt($r('app.media.placeholder'))
          }

          if (this.ratio() > 0) {
            Progress({ value: this.ratio(), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(Theme.ACCENT)
              .backgroundColor('#4DFFFFFF')
          }
        }
        .width(this.fluid ? '100%' : this.cardWidth)
        .borderRadius(Theme.R_IMG)
        // 1px 描边：深色底上海报边缘会和背景糊在一起，加一道极淡的白边才有"卡片感"
        .border({ width: 1, color: Theme.STROKE })
        .clip(true)

        // 右上角竖排两行：上行是标记 + 刮削评分，下行是「我的评价」。
        // 左下单放不下（会被圆角吃掉），右上角是唯一稳妥的位置。
        if (scoreText(this.item.score).length > 0 || this.itemMarks().length > 0 ||
          this.myRating() > 0) {
          Column({ space: 3 }) {
            if (scoreText(this.item.score).length > 0 || this.itemMarks().length > 0) {
              Row({ space: 3 }) {
                if (this.itemMarks().length > 0) {
                  MarkBadges({ marks: this.itemMarks(), max: 2, badgeSize: 8, fill: 'dark' })
                }
                if (scoreText(this.item.score).length > 0) {
                  Text(scoreText(this.item.score))
                    .fontSize(10)
                    .fontColor(Theme.GOLD)
                    .fontWeight(FontWeight.Medium)
                    .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                    .backgroundColor('#B3000000')
                    .borderRadius(6)
                }
              }
            }
            // 我的评价：刮削评分下面那一行，字用星级配色，一眼能分出「谁给的」
            if (this.myRating() > 0) {
              Text(rateLabel(this.myRating()))
                .fontSize(9)
                .fontColor(rateColor(this.myRating()))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .backgroundColor('#B3000000')
                .borderRadius(6)
            }
          }
          .alignItems(HorizontalAlign.End)
          .margin(6)
        }

      }
      .width(this.fluid ? '100%' : this.cardWidth)
      .borderRadius(Theme.RADIUS)

      Text(this.showNumber && this.item.number.length > 0 ? this.item.number : this.item.title)
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.fluid ? '100%' : this.cardWidth)
        .margin({ top: 6 })

      if (this.showTitle) {
        Text(this.showNumber ? (this.item.title.length > 0 ? this.item.title : ' ') : ' ')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.fluid ? '100%' : this.cardWidth)
          .margin({ top: 2 })
      }
      if (this.showDate && this.item.release.length >= 4) {
        Text(this.item.release.substring(0, 10))
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .width(this.fluid ? '100%' : this.cardWidth)
          .margin({ top: 2 })
      }
    }
    .width(this.fluid ? '100%' : this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .opacity(this.shown ? 1 : 0)
    .translate({ y: this.shown ? 0 : 10 })
    // 按压缩放（2026-11-14）：手指下去缩到 0.97，抬手回弹 —— 比"点完变色"更像实体按键
    .scale({ x: this.press ? 0.97 : 1, y: this.press ? 0.97 : 1 })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.press = true;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.press = false;
      }
    })
    .onClick(() => {
      this.onTap();
    })
  }
}
