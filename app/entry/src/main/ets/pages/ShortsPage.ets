/**
 * 刷一刷的**独立页面**（2.6.1.82 起，2.6.2.13 复原）。
 *
 * 为什么不放进 `Index` 的 Swiper：Swiper 会独占横向手势，跟 Tabs 的横滑切页
 * 抢同一个动作，两个方向总有一个失效（详见 2.6.2.13 的 CHANGELOG）。现在：
 *
 *   首页右滑 → push 这个页面；这个页面**左滑** → 回首页（负一屏在左边，符合直觉）。
 *
 * 退出只认左滑 + 系统返回：上下滑留给片段的翻页。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShortsView } from '../view/ShortsView';

@Entry
@Component
struct ShortsPage {
  /** 左滑退出的触摸采样（只观测，不参与手势仲裁）。 */
  private sx0: number = -1;
  private sy0: number = 0;
  private sx1: number = 0;
  private sy1: number = 0;

  aboutToAppear(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext)
      .then((w: window.Window) => {
        w.setWindowLayoutFullScreen(true);
        w.setWindowSystemBarEnable([]);
        w.setPreferredOrientation(window.Orientation.PORTRAIT);
        w.setWindowKeepScreenOn(true).catch(() => {
        });
      })
      .catch((err: BusinessError) => {
        console.info(`[amane] shorts fullscreen: ${err.code}`);
      });
  }

  /**
   * 左滑 = 回首页。
   *
   * 用触摸采样而不是 PanGesture：这一页的主体是竖向 Swiper（上下翻片段），
   * 手势仲裁会把横向一起吞掉；`onTouch` 只是旁听，不抢任何事件。
   * 判定：横向位移 < -96vp 且 |dx| > 2|dy|，向上/下滑动不受影响。
   */
  private track(ev: TouchEvent): void {
    if (ev.type === TouchType.Down) {
      if (ev.touches.length === 1) {
        this.sx0 = ev.touches[0].x;
        this.sy0 = ev.touches[0].y;
        this.sx1 = this.sx0;
        this.sy1 = this.sy0;
      } else {
        this.sx0 = -1;
      }
      return;
    }
    if (ev.type === TouchType.Move) {
      if (ev.touches.length === 1 && this.sx0 >= 0) {
        this.sx1 = ev.touches[0].x;
        this.sy1 = ev.touches[0].y;
      }
      return;
    }
    if (this.sx0 < 0) {
      return;
    }
    const dx: number = this.sx1 - this.sx0;
    const dy: number = this.sy1 - this.sy0;
    this.sx0 = -1;
    if (ev.type === TouchType.Up && dx < -96 && Math.abs(dx) > Math.abs(dy) * 2) {
      router.back();
    }
  }

  /**
   * 转场（2026-11-14 13:07 复原）：**从左侧滑入 / 向左滑出**，不再从右边弹。
   *
   * 为什么必须是左边：负一屏在首页**左边**，用户是「右滑把它拉出来」——
   * 从右边弹进来方向正好相反，看着像「点开了一个新页面」而不是「隔壁那一屏」。
   * `SlideEffect.Start` 在 LTR 下就是起始边（左）：
   *   Enter  从左侧推入（首页顺势右移露出它）
   *   Exit   向左滑回（回首页）
   * 时长压到 220/200ms、用 FastOutSlowIn，比系统默认的「整页 push」更利落。
   */
  pageTransition() {
    PageTransitionEnter({ duration: 220, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left);
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left);
  }

  build() {
    Column() {
      ShortsView({
        onClose: () => {
          router.back();
        }
      })
    }
    .width('100%')
    .height('100%')
    .onTouch((ev: TouchEvent) => {
      this.track(ev);
    })
  }
}
