import { Theme } from '../../common/Theme';

/**
 * 列表页工具栏上的「抽卡」开关。
 *
 * 做成独立组件而不是 @Builder：@Builder 按值传参不会刷新，选中态会一直停在初始值
 * （媒体库筛选 chip 踩过这个坑）。
 */
@Component
export struct GachaSwitch {
  @Prop on: boolean = false;
  onToggle: (v: boolean) => void = (v: boolean) => {};

  build() {
    Row({ space: 4 }) {
      Text('❖')
        .fontSize(11)
        .fontColor(this.on ? '#FFFFFF' : Theme.ACCENT)
      Text(this.on ? '抽卡中' : '抽卡')
        .fontSize(11)
        .fontColor(this.on ? '#FFFFFF' : Theme.TEXT_DIM)
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .backgroundColor(this.on ? Theme.ACCENT : Theme.CARD)
    .borderRadius(12)
    .onClick(() => {
      this.onToggle(!this.on);
    })
  }
}
