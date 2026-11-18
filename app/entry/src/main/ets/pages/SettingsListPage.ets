import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';

/**
 * 设置 · 列表页（二级页）：抽卡模式的两个参数。
 *
 * 这些是「列表页怎么展示」的偏好，跟连接、数据无关，所以单独成页。
 * 改了立刻落盘（不跟任何「保存」按钮绑定），回列表页就是新值。
 */
@Component
struct Chip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.active ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.active ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(14)
      .onClick(() => {
        this.onTap();
      })
  }
}

@Entry
@Component
struct SettingsListPage {
  @State count: number = Store.I.gachaCount;
  @State auto: boolean = Store.I.gachaAuto;

  private pickCount(n: number): void {
    this.count = n;
    Store.I.gachaCount = n;
    Store.I.save();
  }

  private pickAuto(on: boolean): void {
    this.auto = on;
    Store.I.gachaAuto = on;
    Store.I.save();
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
          router.back();
          }
        })
        PageTitle({ text: '列表与抽卡', fs: 18 })
        Blank()
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  build() {
    Navigation(this.navStack) {
      Column() {

        Scroll() {
          Column({ space: 12 }) {

          // 六十改：标题栏浮在内容之上 —— 首屏落在玻璃下方，一滚动就从玻璃底下穿过去，
          // 材质才有颜色可采样。
          Blank().height(this.barH())
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Text('抽卡模式')
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                  .width(88)
                Chip({ label: '关', active: !this.auto, onTap: () => {
                  this.pickAuto(false);
                } })
                Chip({ label: '开', active: this.auto, onTap: () => {
                  this.pickAuto(true);
                } })
                Blank()
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Text('每轮张数')
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                  .width(88)
                Chip({ label: '6 张', active: this.count === 6, onTap: () => {
                  this.pickCount(6);
                } })
                Chip({ label: '10 张', active: this.count === 10, onTap: () => {
                  this.pickCount(10);
                } })
                Chip({ label: '16 张', active: this.count === 16, onTap: () => {
                  this.pickCount(16);
                } })
                Blank()
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text('抽卡模式 = 把标签 / 系列 / 导演 / 制片商 / 媒体库 / 收藏这些列表页换成随机剧照瀑布流，' +
                '点图直接进那部片的详情。每轮张数越大一次铺得越多；「开」是一进列表页就是剧照墙。')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(17)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            Text('改完立即生效，不需要额外保存。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}