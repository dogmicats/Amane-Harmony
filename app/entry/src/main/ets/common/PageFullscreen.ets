import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/**
 * 页面级「窗口全屏」（七十二改统一入口）。
 *
 * 背景：`Index` 在 `onPageHide` 里会把 `setWindowLayoutFullScreen(false)` 关掉，
 * 所以二级页一进去，**窗口本身就避让了状态栏/手势条** —— 内容再怎么 `expandSafeArea`
 * 也画不出窗口边界，表现就是用户反复报的「上下两条系统黑边」。
 *
 * 结论（踩过三轮才定下来）：
 *   ① 想要真全屏，必须**窗口层**开全屏，内容层 `expandSafeArea` 只是第二步；
 *   ② 开在 `onPageShow`，**离开本页不要关**：路由返回时 `onPageHide` 是后触发的，
 *      在这里关会把上一页（`Index.onPageShow`）刚设好的状态又改回 false ——
 *      表现就是「从详情页返回，整个 tab 页往下掉一个状态栏的高度」；
 *   ③ 真的需要让位的只有「去一个没有让位逻辑的页面」（影片详情这类），
 *      在**跳转之前**用 `after` 回调串起来关。
 */
export function setPageFullScreen(ctx: common.Context, on: boolean, after?: () => void): void {
  const done: () => void = () => {
    if (after !== undefined) {
      after();
    }
  };
  window.getLastWindow(ctx).then((w: window.Window) => {
    w.setWindowLayoutFullScreen(on).then(() => {
      done();
    }).catch((err: BusinessError) => {
      console.info(`[amane] page fullscreen=${on}: ${err.code} ${err.message}`);
      done();
    });
  }).catch((err: BusinessError) => {
    console.info(`[amane] page window: ${err.code} ${err.message}`);
    done();
  });
}
