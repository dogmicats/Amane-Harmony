import { BusinessError } from '@kit.BasicServicesKit';
import { httpPut } from '../../common/Http';
import { Store } from '../../common/Store';
import { rateColor, rateDesc, rateLabel, RATE_DESCS, RATE_LABELS, StarPick } from '../../common/RateStyle';

/** score=0 表示清除评分。详情页与「播放后打分」提示卡共用这一个入口。 */
export async function rateFilm(mid: number, score: number): Promise<void> {
  await httpPut(`${Store.I.user}/api/user/ratings/${mid}`, Store.I.token,
    JSON.stringify({ score: score }));
}

/**
 * 影片的「我的评分」。
 *
 * 显示、配色、档位说法全部由 `common/RateStyle` 提供 —— 与演员/导演/厂牌/标签/系列的
 * 分类评分**是同一套**。这里只多做一件事：把分存到影片评分接口。
 */
export { RATE_LABELS, RATE_DESCS, rateColor, rateLabel, rateDesc };

@Component
export struct RatingStars {
  @Prop metaId: number = 0;
  @Prop score: number = 0;
  @Prop starSize: number = 26;
  /** 是否在星星右侧显示这一档的说法（详情页开，卡片/提示卡关）。 */
  @Prop showDesc: boolean = false;
  onRate: (score: number) => void = (s: number) => {};

  @State busy: boolean = false;

  private async rate(n: number): Promise<void> {
    if (this.busy || this.metaId <= 0) {
      return;
    }
    const next: number = n === this.score ? 0 : n;
    this.busy = true;
    try {
      await rateFilm(this.metaId, next);
      this.onRate(next);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] rate: ${e.code} ${e.message}`);
    }
    this.busy = false;
  }

  build() {
    Column({ space: 6 }) {
      StarPick({
        score: this.score,
        starSize: this.starSize,
        showLabel: this.showDesc,
        onPick: (n: number) => {
          this.rate(n);
        }
      })
      if (this.showDesc && this.score > 0) {
        Text(rateDesc(this.score))
          .fontSize(11)
          .fontColor('#B3FFFFFF')
      }
    }
    .alignItems(HorizontalAlign.Start)
  }
}
