import { Theme } from '../common/Theme';
import { markColor } from '../common/Util';

/**
 * 影片标记徽标：无码 / 破解 / 流出 / 中字。
 *
 * **硬规范（见 docs/UI_RULES.md）**：所有「影片列表页」的卡片和所有
 * 「影片详情页」的头部都必须用这一个组件渲染标记，不要再各页面手写
 * Text + ForEach —— 之前就是各写一遍，媒体库网格、搜索结果、观看记录
 * 全部漏掉了。
 *
 * 服务端在列表接口里算好 `marks`（/api/user/browse、home、favorites、
 * facets、actors、history）和详情接口（/api/user/item），客户端只管画。
 */
@Component
export struct MarkBadges {
  /** 标记文案，顺序由服务端决定：无码 / 破解 / 流出 / 中字。 */
  marks: string[] = [];
  /** 最多显示几个，超出丢弃（海报卡很窄）。 */
  max: number = 3;
  /** 字号；海报卡 8，详情页 10。 */
  badgeSize: number = 9;
  /** 底色：'dark' 压在海报上，'card' 用在深色信息区。 */
  fill: string = 'card';
  /** 左右排布；列表里居中，卡片里靠右。 */
  center: boolean = false;

  private shown(): string[] {
    if (this.marks === undefined || this.marks === null) {
      return [];
    }
    return this.marks.length > this.max ? this.marks.slice(0, this.max) : this.marks;
  }

  build() {
    Row({ space: 4 }) {
      ForEach(this.shown(), (label: string, index: number) => {
        Text(label)
          .fontSize(this.badgeSize)
          .fontColor(markColor(label))
          .padding({
            left: this.badgeSize <= 8 ? 4 : 6,
            right: this.badgeSize <= 8 ? 4 : 6,
            top: this.badgeSize <= 8 ? 1 : 2,
            bottom: this.badgeSize <= 8 ? 1 : 2
          })
          .backgroundColor(this.fill === 'dark' ? '#CC000000' : Theme.CARD_HI)
          .borderRadius(4)
          .border({
            width: this.badgeSize <= 8 ? 0 : 0.5,
            color: this.fill === 'dark' ? '#26000000' : '#26FFFFFF'
          })
      }, (label: string, index: number) => `mk-${index}-${label}`)
    }
    .justifyContent(this.center ? FlexAlign.Center : FlexAlign.Start)
  }
}
