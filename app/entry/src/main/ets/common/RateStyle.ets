import { Theme } from './Theme';

/**
 * 「我的评分」的唯一实现处：等级说法、配色、可点的星行。
 *
 * 影片（详情页 / 海报卡 / 播放后提示）和分类（演员、导演、厂牌、标签、系列）
 * 用的是**同一套语义与颜色** —— 用户看到「四颗琥珀色星」在任何地方都该是同一个意思。
 * 所以这里只放「怎么显示、怎么点」，不碰任何接口；谁用谁接自己的 API：
 * 影片走 `/api/user/ratings/{id}`，分类走 `/api/user/facets/{kind}/{id}/rating`。
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

/** 星级渐强的配色：冷 → 暖（蓝 → 青 → 绿 → 琥珀 → 玫红），一星蓝、五星红。 */
const RATE_COLORS: string[] = ['#8A8F99', '#6FA8DC', '#5FC9C0', '#7BC98A', '#FFB347', '#FF5A7A'];

export function rateColor(score: number): string {
  const n: number = Math.trunc(score);
  if (n < 1 || n > 5) {
    return RATE_COLORS[0];
  }
  return RATE_COLORS[n];
}

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

/**
 * 可点的 1–5 星（纯展示 + 回调，不含请求）。
 *
 * - `score` 0 表示没打分，星星是灰的；
 * - 点当前已选那档 = 取消（调用方决定要不要真的清）；
 * - `showLabel` 打开时右侧贴这一档的说法（「社保」），列表里别开，太吵。
 */
@Component
export struct StarPick {
  @Prop score: number = 0;
  @Prop starSize: number = 26;
  @Prop showLabel: boolean = false;
  @Prop gap: number = 6;
  onPick: (score: number) => void = (s: number) => {};

  build() {
    Row({ space: this.gap }) {
      ForEach([1, 2, 3, 4, 5], (n: number) => {
        Text('★')
          .fontSize(this.starSize)
          .fontColor(n <= this.score ? rateColor(this.score) : Theme.TEXT_FAINT)
          .padding({ left: 1, right: 1 })
          .onClick(() => {
            this.onPick(n);
          })
      }, (n: number) => `star-${n}`)
      if (this.showLabel && this.score > 0) {
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
  }
}
