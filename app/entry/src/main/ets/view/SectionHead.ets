/**
 * 分区标题（2.6.1.22）
 *
 * 为什么要有它：详情页十来个功能块，标题原来全是「12px 灰字（TEXT_FAINT）直接贴在黑底上」——
 * 字号、颜色、上下间距完全一样。一屏看下去像一整段连续的说明文字，用户找不到「块」的边界，
 * 所以会有「所有功能都杂糅在一起」的感觉（2026-11-13 用户原话）。
 *
 * 改法只做三件小事，**不动设计语言**：不换底色、不加卡片、不加图标、不加分隔条。
 * 1. 左侧 `3 × 13` 的主色竖标（alpha 0.55）：给每块一个起跑线；颜色取自主题，换主题自动协调；
 * 2. 标题从 `TEXT_FAINT` 提到 `TEXT_DIM`，加 `0.4` 字距、`Medium`：比正文亮一档，但不跟内容抢；
 * 3. 块间距由调用方从 14/16 提到 22 —— 呼吸感是区分度的一半，这一条比竖标更有效。
 *
 * 为什么不给每块加卡片底：详情页一屏已经有封面、按钮、评分、亮点缩略图四层质感，
 * 再套卡片就变成「一堆盒子」，反而更乱。竖标 + 间距是最小代价的分层。
 */
import { Theme } from '../common/Theme';

@Component
export struct SectionHead {
  /** 标题文字。 */
  @Prop title: string = '';
  /** 右侧紧跟的计数/单位（如「12」「3 条」），空串则不画。 */
  @Prop count: string = '';

  build() {
    Row({ space: 6 }) {
      Text(this.title)
        .fontSize(16)
        .fontColor(Theme.TEXT)
        .fontWeight(FontWeight.Bold)
      if (this.count.length > 0) {
        Text(this.count)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}
