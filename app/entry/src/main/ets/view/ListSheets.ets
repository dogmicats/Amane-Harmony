import { ChipOption, SortOption } from '../common/BrowseOptions';
import { Theme } from '../common/Theme';

/**
 * 清单页的「工具条胶囊 + 底部抽屉」公共件（2.4.6.24）。
 *
 * 媒体库那一套（一行搜索框、一行工具条、点开底部抽屉改排序/筛选）原来只活在
 * `BrowseGrid` 里；演员、标签/系列/导演/制片商各写了一套内联 chip 行 —— 同样的
 * 事情三种手感，同一个 App 里切个 Tab 就像换了个人做的。
 *
 * 这里只放**壳**，不放业务：抽屉里有哪些组、排序有哪些项，仍由各页面自己决定，
 * 所以各页独有的筛选项（演员的共演、标签的显示隐藏、系列的按属性筛）不会丢。
 */
@Component
export struct ToolPill {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.active ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.active ? Theme.ACCENT : Theme.CARD)
      .borderRadius(12)
      .onClick(() => {
        this.onTap();
      })
  }
}

/**
 * 抽屉里的一组筛选 chip：小标题 + 自动换行的选项。
 * 必须是子组件：@Builder 按值传参不会刷新，选中态会一直停在初始值。
 */
@Component
export struct ChipGroup {
  @Prop title: string = '';
  @Prop options: ChipOption[] = [];
  @Prop current: string = '';
  /** 标题右侧的小开关文案；空串 = 不显示（目前只有出演年龄用它切性别）。 */
  @Prop trailing: string = '';
  onPick: (key: string) => void = () => {};
  onTrailing: () => void = () => {};

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.title)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        if (this.trailing.length > 0) {
          Text(this.trailing)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.CARD)
            .borderRadius(9)
            .onClick(() => {
              this.onTrailing();
            })
        }
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (opt: ChipOption) => {
          Text(opt.label)
            .fontSize(12)
            .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onPick(opt.key);
            })
        }, (opt: ChipOption) => `${this.title}-${opt.key}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 清单页的那一行工具条：左边一条数/摘要，右边「⇅ 排序」「⚙ 筛选 N」两个胶囊。
 *
 * 媒体库、演员、标签三页已经统一成这个形状（2.4.6.24），观看记录 / 稍后再看 /
 * 同号前缀 / 收藏页 / 演员作品 / 分类墙 / 共演筛选也按它收口 —— 这些页原来把
 * 排序和筛选项直接铺在页面上（三到六行），屏幕上半截全是 chip，实际内容没几部。
 * 抽卡开关这类页面独有的东西仍由各页自己摆在工具条外面。
 */
@Component
export struct ListToolbar {
  /** 左侧摘要：通常是「38 部」或「「关键词」12 部」。 */
  @Prop label: string = '';
  @Prop sortLabel: string = '排序';
  /** 生效中的筛选条数：>0 时筛选胶囊点亮并显示数字。 */
  @Prop filterCount: number = 0;
  /** 这一页没有可筛项时（比如「我的标签」）关掉筛选入口。 */
  @Prop showFilter: boolean = true;
  onSort: () => void = () => {};
  onFilter: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      ToolPill({
        label: `⇅ ${this.sortLabel}`,
        onTap: () => {
          this.onSort();
        }
      })

      if (this.showFilter) {
        ToolPill({
          label: this.filterCount > 0 ? `⚙ 筛选 ${this.filterCount}` : '⚙ 筛选',
          active: this.filterCount > 0,
          onTap: () => {
            this.onFilter();
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4, bottom: 8 })
  }
}

/**
 * 横向一排 chip（不换行）：页面级的「切换大类」用它，比如标签/系列/导演/制片商。
 * 外层自己套 Scroll，宽度不够时可以滑，而不是折成两行把页面顶下去。
 */
@Component
export struct ChipRow {
  @Prop options: ChipOption[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Row({ space: 7 }) {
      ForEach(this.options, (opt: ChipOption) => {
        Text(opt.label)
          .fontSize(11)
          .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.onPick(opt.key);
          })
      }, (opt: ChipOption) => `chiprow-${opt.key}`)
    }
  }
}

/**
 * 底部抽屉外壳：标题 + 右上角动作（重置）+ 可滚动内容 + 底部主按钮。
 *
 * 内容用尾随闭包传（`BottomSheet({...}) { ChipGroup(...) }`），所以壳子完全不知道
 * 里面是什么 —— 媒体库放 9 组，标签页放 2 组，演员页放 8 组，长得都一样。
 * 悬浮 Tab 导航栏会盖住贴底的面板，`tabInset` 把整块内容抬到栏上方。
 */
@Component
export struct BottomSheet {
  @Prop title: string = '';
  /** 右上角的文字动作（通常是「重置」）；空串 = 不显示。 */
  @Prop actionLabel: string = '';
  onAction: () => void = () => {};
  @Prop confirmLabel: string = '完成';
  onConfirm: () => void = () => {};
  @Prop sheetHeight: string = '84%';
  @Prop tabInset: number = 0;
  @BuilderParam content: () => void;

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        if (this.actionLabel.length > 0) {
          Text(this.actionLabel)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.onAction();
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          this.content()
          Blank().height(10)
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Row() {
        Button(this.confirmLabel)
          .width('100%')
          .height(42)
          .backgroundColor(Theme.ACCENT)
          .fontColor('#FFFFFF')
          .fontSize(14)
          .onClick(() => {
            this.onConfirm();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 18 })
    }
    .width('100%')
    .height(this.sheetHeight)
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius({ topLeft: 18, topRight: 18 })
    .padding({ bottom: this.tabInset })
  }
}

/**
 * 排序抽屉：一行一个排序键，当前选中的那行右边带「↑ 正序 / ↓ 倒序」开关。
 *
 * 方向不靠「再点一次同一个选项」这种隐式行为（那是上一版的做法，没人发现得了），
 * 而是当前行显式给一个可点的方向胶囊。随机排序没有方向，所以那行不显示。
 */
@Component
export struct SortSheet {
  @Prop options: SortOption[] = [];
  @Prop current: string = '';
  @Prop order: string = 'desc';
  /** 没有方向的排序键（随机）。 */
  @Prop noOrderKey: string = 'random';
  @Prop tabInset: number = 0;
  onPick: (key: string) => void = () => {};
  onToggleOrder: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('排序方式')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('关闭')
          .fontSize(13)
          .fontColor(Theme.TEXT_FAINT)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 6 })

      ForEach(this.options, (opt: SortOption) => {
        Row() {
          Text(opt.label)
            .fontSize(14)
            .fontColor(this.current === opt.key ? Theme.ACCENT : Theme.TEXT)
            .layoutWeight(1)
          if (this.current === opt.key && opt.key !== this.noOrderKey) {
            Text(this.order === 'asc' ? '↑ 正序' : '↓ 倒序')
              .fontSize(11)
              .fontColor(Theme.TEXT)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
              .onClick(() => {
                this.onToggleOrder();
              })
          }
        }
        .width('100%')
        .height(46)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.onPick(opt.key);
        })
      }, (opt: SortOption) => `sort-${opt.key}`)

      Blank().height(20)
    }
    .width('100%')
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius({ topLeft: 18, topRight: 18 })
    .padding({ bottom: this.tabInset })
  }
}
