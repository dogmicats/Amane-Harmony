import { BusinessError } from '@kit.BasicServicesKit';
import { httpPut } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';

/** score=0 表示清除评分。详情页与「播放后打分」提示卡共用这一个入口。 */
export async function rateFilm(mid: number, score: number): Promise<void> {
  await httpPut(`${Store.I.user}/api/user/ratings/${mid}`, Store.I.token,
    JSON.stringify({ score: score }));
}

/**
 * 1–5 星的语义（用户定的说法，**唯一的定义处**）。
 * 海报卡徽标、详情页、播放后提示卡都从这里取，别再各写一份。
 *
 * 梯度：1 只用来下饭 → 5 是本命。3 星是「中间那档」：比 2 更主动（会留着，
 * 但还没到想重看的程度），比 4 保守（不保证二刷）。
 */
export const RATE_LABELS: string[] = ['', '配菜', '有意思', '对味', '反复看', '社保'];
export const RATE_DESCS: string[] = [
  '',
  '下饭用，看完就忘',
  '有亮点，不亏',
  '合口味，会留着',
  '会重看，值得存',
  '本命，神作级'
];

/** 星级渐强的配色：**冷 → 暖**（蓝 → 青 → 绿 → 琥珀 → 玫红），一星蓝、五星红。
 *  一星必须明显亮于未点亮的灰（Theme.TEXT_FAINT #6C6C78），否则用户以为没点上。 */
const RATE_COLORS: string[] = ['#8A8F99', '#6FA8DC', '#5FC9C0', '#7BC98A', '#FFB347', '#FF5A7A'];

export function rateLabel(score: number): string {
  const n: number = Math.trunc(score);
  if (n < 1 || n > 5) {
    return '';
  }
  return RATE_LABELS[n];
}

export function rateDesc(score: number): string {
  const n: number = Math.trunc(score);
  if (n < 1 || n > 5) {
    return '';
  }
  return RATE_DESCS[n];
}

export function rateColor(score: number): string {
  const n: number = Math.trunc(score);
  if (n < 1 || n > 5) {
    return RATE_COLORS[0];
  }
  return RATE_COLORS[n];
}

/**
 * 我的评分（1–5 星）。与详情页头部那个上游 javdb 评分不是一回事：
 * 那是站点刮削来的，这是用户自己打的，存在服务端 user.db。
 * 再点一次当前那颗 = 清除评分（score 0）。
 *
 * 打完/选中时右侧显示这一档的说法（如「社保」），下面可选一行解释，
 * 让「打几分」变成「这是什么感觉」而不是一个裸数字。
 */
@Component
export struct RatingStars {
  @Prop metaId: number = 0;
  @Prop score: number = 0;
  @Prop starSize: number = 26;
  /** 是否在星星下方显示一句解释（详情页开，卡片/提示卡关）。 */
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
      Row({ space: 6 }) {
        ForEach([1, 2, 3, 4, 5], (n: number) => {
          Text('★')
            .fontSize(this.starSize)
            .fontColor(n <= this.score ? rateColor(this.score) : Theme.TEXT_FAINT)
            .padding({ left: 1, right: 1 })
            .onClick(() => {
              this.rate(n);
            })
        }, (n: number) => `star-${n}`)

        // 选中后把这一档的说法贴在星星右边——打分过程中就能看到「我这是什么意思」
        if (this.score > 0) {
          Text(rateLabel(this.score))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(rateColor(this.score))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor('#1FFFFFFF')
            .borderRadius(8)
            .margin({ left: 2 })
        }
      }
      .alignItems(VerticalAlign.Center)

      if (this.showDesc && this.score > 0) {
        Text(rateDesc(this.score))
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .alignItems(HorizontalAlign.Start)
  }
}
