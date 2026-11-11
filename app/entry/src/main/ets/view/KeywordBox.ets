import { Theme } from '../common/Theme';

/**
 * 清单页通用的关键词搜索框（2.4.6.21）。
 *
 * 为什么单独做一个：媒体库 / 演员 / 标签·系列·导演 三处清单原本两套写法 ——
 * 有的根本没有搜索框，有的有但清不干净（只能一个个删字符）。清单里的搜索是
 * 「在当前列表里缩小范围」，不是独立搜索页，所以交互要轻：
 *   - 输入即搜（300ms 防抖，和原来的手写 setTimeout 一致）；
 *   - 有字才出现 ✕，点一下回到全量；
 *   - 边框在输入时变主题色，一眼看出「现在是筛过的列表」。
 *
 * 相关性排序在服务端做（`amane_rel`）：越精准越靠前，这里只管把词送上去。
 */
@Component
export struct KeywordBox {
  @Prop placeholder: string = '搜索';
  /** 防抖后回调；清空时立即回调空串。 */
  onCommit: (kw: string) => void = () => {};
  @State private text: string = '';
  private timer: number = -1;
  private pending: string = '';

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private emit(value: string): void {
    this.pending = value;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.onCommit(this.pending);
    }, 300);
  }

  /** 清空是明确动作，不等防抖：点了 ✕ 就该立刻看到全量。 */
  private clear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.text = '';
    this.pending = '';
    this.onCommit('');
  }

  build() {
    Row({ space: 4 }) {
      Text('⌕')
        .fontSize(15)
        .fontColor(this.text.length > 0 ? Theme.ACCENT : Theme.TEXT_FAINT)
        .margin({ left: 4 })

      // 用 $$ 双向绑定：受控写法（text: this.text + onChange 回写）在部分版本会
      // 把光标顶到末尾，中文输入法组词时特别明显。
      TextInput({ placeholder: this.placeholder, text: $$this.text })
        .layoutWeight(1)
        .height(36)
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 12 })
        .backgroundColor(Color.Transparent)
        .padding({ left: 2, right: 2 })
        .onChange((value: string) => {
          this.emit(value);
        })

      if (this.text.length > 0) {
        Text('✕')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .borderRadius(13)
          .backgroundColor(Theme.CARD_HI)
          .margin({ right: 4 })
          .onClick(() => {
            this.clear();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
    .border({
      width: this.text.length > 0 ? 1 : 0,
      color: Theme.ACCENT
    })
  }
}
