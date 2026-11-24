import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsIconTile, SettingsRowDivider, VelvetChip
} from '../view/SettingsKit';

@Entry
@Component
struct SettingsListPage {
  @State count: number = Store.I.gachaCount;
  @State auto: boolean = Store.I.gachaAuto;
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

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

  private barH(): number {
    return this.topInset + 46;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        Scroll() {
          Column({ space: 14 }) {
            Blank().height(this.barH() + 6)

            Column() {
              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.rectangle_stack'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('默认开启抽卡墙')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('进入列表页直接以随机剧照瀑布流展示')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.auto })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.pickAuto(v);
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 13 })

              SettingsRowDivider()

              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  SettingsIconTile({ icon: $r('sys.symbol.picture'), tileSize: 36, iconSize: 17 })
                  Column({ space: 2 }) {
                    Text('每轮张数')
                      .fontSize(14.5)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.TEXT)
                    Text('每次抽卡铺开的剧照数量')
                      .fontSize(11)
                      .fontColor(Theme.TEXT_FAINT)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')

                Row({ space: 8 }) {
                  VelvetChip({
                    label: '6 张',
                    active: this.count === 6,
                    padH: 16,
                    padV: 7,
                    onTap: () => {
                      this.pickCount(6);
                    }
                  })
                  VelvetChip({
                    label: '10 张',
                    active: this.count === 10,
                    padH: 16,
                    padV: 7,
                    onTap: () => {
                      this.pickCount(10);
                    }
                  })
                  VelvetChip({
                    label: '16 张',
                    active: this.count === 16,
                    padH: 16,
                    padV: 7,
                    onTap: () => {
                      this.pickCount(16);
                    }
                  })
                }
                .width('100%')
                .padding({ left: 48 })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 14 })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            Text('适用于媒体库、收藏、标签、系列与导演列表，改完即刻生效。')
              .fontSize(10.5)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
