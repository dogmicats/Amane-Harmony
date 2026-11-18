import { GlassCapsule } from '../../view/GlassKit';

/**
 * 列表页工具栏上的「抽卡」开关。
 *
 * 做成独立组件而不是 @Builder：@Builder 按值传参不会刷新，选中态会一直停在初始值
 * （媒体库筛选 chip 踩过这个坑）。
 *
 * 2026-11-18 四十一改：原来是一块 `Theme.ACCENT` 实心胶囊（开着）/ `Theme.CARD`（关着），
 * 现在换成**视觉基底**的玻璃胶囊 —— 与顶栏那四块同一套，开着时靠 30% 主题色着色表达状态。
 * 文案合成一个字符串（`❖ 抽卡`）而不是两个 Text：玻璃胶囊只有一段文字，
 * 拆成两个字重不同的 Text 会破坏胶囊的内部节奏。
 */
@Component
export struct GachaSwitch {
  @Prop on: boolean = false;
  /** 只在 Navigation 标题栏里传 true（五十五改）：那里 systemMaterial 才真出像素。 */
  @Prop mat: boolean = false;
  onToggle: (v: boolean) => void = (v: boolean) => {};

  build() {
    GlassCapsule({
      label: this.on ? '❖ 抽卡中' : '❖ 抽卡',
      active: this.on,
      mat: this.mat,
      fs: 12,
      padH: 11,
      padV: 6,
      radius: 12,
      onTap: () => {
        this.onToggle(!this.on);
      }
    })
  }
}
