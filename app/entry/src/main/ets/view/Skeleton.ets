/**
 * 骨架屏（2.6.1.18）：把「转圈」换成「这一页正在长出来」。
 *
 * 为什么不用 `LoadingProgress`：转圈只说明「在等」，骨架说明「等的是什么东西」——
 * 详情页一进来就能看出「上面一张大图、下面四行信息、再下面一排按钮」，
 * 视觉锚点先落位，数据到了只是把灰块填成实内容，不会整屏跳一下。
 *
 * 呼吸用 0.38–0.70 的透明度来回，900ms 一次：比粒子慢、比呼吸灯弱，
 * 目的是「有生命感」而不是「吸引注意」。光效关掉（`amaneFx=0`）时**仍然保留**，
 * 因为它属于加载状态而不是装饰 —— 但会跟着 `amaneFxLow` 一起静止，省电优先。
 */
import { Theme } from '../common/Theme';

@Component
export struct SkeletonBlock {
  /** 宽度：'100%' / '60%' 这种百分比字符串，或 '120' 这种定宽。 */
  @Prop w: string = '100%';
  @Prop h: number = 14;
  @Prop radius: number = 6;
  /** 起始透明度错开，几块灰条不会像一块整体在闪。 */
  @Prop lag: number = 0;
  @State private phase: number = 0.5;
  @StorageProp('amaneFxLow') private lowPower: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      this.phase = this.phase > 0.62 ? 0.38 : 0.7;
    }, 900 + this.lag);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Column()
      .width(this.w)
      .height(this.h)
      .borderRadius(this.radius)
      .backgroundColor(Theme.CARD_HI)
      .opacity(this.lowPower === 1 ? 0.5 : this.phase)
      .animation({ duration: 900, curve: Curve.EaseInOut })
  }
}
