/**
 * 全局小窗的壳：把 `FloatPlayerCard` 挂到窗口顶层（OverlayManager），页面怎么翻它都在。
 *
 * 为什么用顶层浮层而不是子窗口：子窗口要建 window、管生命周期、还要自己处理
 * 与主页面的层级/焦点；浮层直接长在同一个窗口上，导航不影响它，改动面最小。
 * 真机若发现浮层与列表手势打架，再考虑换子窗口（接口不用变）。
 */
import { ComponentContent, UIContext, router } from '@kit.ArkUI';
import { FloatPlayerCard } from '../view/FloatPlayerCard';
import { PlayHandoff, PlaySession } from './PlaySession';
import { PlayerParams } from './Types';

@Builder
function floatCardBuilder(session: PlayHandoff) {
  // 外层自定义组件节点必须设为 HitTestMode.None：
  // OverlayManager 里的 CustomNode 默认 HitTestMode.Default，配合内部 100% Stack 会拦掉整页触摸；
  // 设成 None 后外层不参与命中、也不阻断子卡片和底下页面，卡片外空白区 100% 穿透给 App 页面。
  FloatPlayerCard({ session: session })
    .hitTestBehavior(HitTestMode.None)
}

export class FloatBox {
  private static content: ComponentContent<PlayHandoff> | undefined = undefined;
  private static ui: UIContext | undefined = undefined;

  static get isOpen(): boolean {
    return FloatBox.content !== undefined;
  }

  /**
   * 打开浮窗（已在开就先关掉旧的，避免两份音频）。返回是否真的挂上去了。
   *
   * `compact = true`：只做小窗档（详情页发起时用 —— 详情页本身已经有 16:9 播放器，
   * 这时候给它一根宽条没有意义，用户 2026-11-13 反馈「详情页里不该是宽条」）。
   */
  static open(ui: UIContext, session: PlayHandoff, compact: boolean = true): boolean {
    FloatBox.close(ui);
    session.compact = compact;
    try {
      const c: ComponentContent<PlayHandoff> =
        new ComponentContent(ui, wrapBuilder(floatCardBuilder), session);
      FloatBox.ui = ui;
      FloatBox.content = c;
      PlaySession.active = session;
      ui.getOverlayManager().addComponentContent(c);
      console.info(`[amane] float open mid=${session.mid} pos=${session.pos.toFixed(0)} compact=${compact}`);
      return true;
    } catch (err) {
      console.error(`[amane] float open failed: ${JSON.stringify(err)}`);
      FloatBox.content = undefined;
      FloatBox.ui = undefined;
      PlaySession.clear();
      return false;
    }
  }

  /** 关掉浮窗（不停播也不跳页 —— 具体由调用方的 request* 决定）。 */
  static close(ui?: UIContext): void {
    const context: UIContext | undefined = ui === undefined ? FloatBox.ui : ui;
    const c: ComponentContent<PlayHandoff> | undefined = FloatBox.content;
    if (context === undefined || c === undefined) {
      FloatBox.content = undefined;
      FloatBox.ui = undefined;
      PlaySession.clear();
      return;
    }
    try {
      context.getOverlayManager().removeComponentContent(c);
    } catch (err) {
      console.info(`[amane] float close: ${JSON.stringify(err)}`);
    }
    FloatBox.content = undefined;
    FloatBox.ui = undefined;
    PlaySession.clear();
  }

  /** × ：停播，留在当前页。 */
  static requestClose(): void {
    FloatBox.close();
  }

  /** 放大：进全屏播放页，从浮窗当前进度接着放。 */
  static requestExpand(h: PlayHandoff): void {
    FloatBox.close();
    const params: PlayerParams = {
      id: h.mid,
      number: h.number,
      title: h.title,
      position: h.pos,
      fileKey: h.fileKey,
      fileName: h.fileName
    };
    try {
      router.pushUrl({ url: 'pages/PlayerPage', params: params });
    } catch (err) {
      console.error(`[amane] float expand: ${JSON.stringify(err)}`);
    }
  }

  /** 回详情页：栈里有就退回去（保留那一页的滚动位置），没有就重新打开。
   *
   * 之前用 `router.back({url})` 直接退，栈里匹配不到实例时是**静默失败** ——
   * 表现就是「点了回详情页没反应」（2026-11-13 真机反馈）。
   * 现在先用 `getStateByUrl` 查一遍再决定，两条路都会给出落点。
   *
   * **关键：这里不要先 close 浮窗**（2026-11-13 用户反馈「回详情页是停止状态、小窗还在放」）。
   * 详情页的 `onPageShow` 里靠 `FloatBox.isOpen == true` + `PlaySession.active` 把画面接回页面内；
   * 先 close 会清掉 `PlaySession.active`，接回逻辑直接失效，播放就卡在浮窗里了。
   * 关闭浮窗交给详情页接手后做（它拿到交接数据再 close）。
   */
  static requestBackDetail(h: PlayHandoff): void {
    if (h.mid <= 0) {
      FloatBox.close();
      return;
    }
    // 详情页还活着（浮窗只是盖在它上面）：直接让页面接手。
    // 这条优先于路由 —— 本页从没离开栈，`router.back` 是原地不动（2.6.1.59 真机踩到）。
    const opener: ((h: PlayHandoff) => void) | undefined = PlaySession.opener;
    if (opener !== undefined) {
      try {
        opener(h);
        return;
      } catch (err) {
        console.info(`[amane] float opener failed: ${JSON.stringify(err)}`);
      }
    }
    const params: Record<string, Object> = {
      'id': h.mid,
      'fileKey': h.fileKey,
      'position': h.pos
    };
    let inStack: boolean = false;
    try {
      const states: router.RouterState[] = router.getStateByUrl('pages/DetailPage');
      inStack = states !== undefined && states !== null && states.length > 0;
    } catch (err) {
      console.info(`[amane] float state: ${JSON.stringify(err)}`);
    }
    if (inStack) {
      try {
        router.back({ url: 'pages/DetailPage', params: params });
        return;
      } catch (err) {
        console.info(`[amane] float back failed: ${JSON.stringify(err)}`);
      }
    }
    // 栈里没有（或 back 抛错）：直接开一页新的详情，进度从交接里带过去
    try {
      router.pushUrl({ url: 'pages/DetailPage', params: params });
    } catch (err) {
      console.error(`[amane] float push detail: ${JSON.stringify(err)}`);
    }
  }
}
