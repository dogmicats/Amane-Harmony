/**
 * 适感握持（2026-11-16）—— 可复用模块。
 *
 * 系统能力：`@kit.MultimodalAwarenessKit` 的 `motion.on('holdingHandChanged')`
 * （API 15+，需要权限 `ohos.permission.ACTIVITY_MOTION` 或 `DETECT_GESTURE`）。
 * 手机自己判断用户是左手还是右手握着，我们据此把贴边的控件挪到顺手那一侧。
 *
 * 设计要点（为的是「以后别处也能直接用」）：
 *   - 不碰任何页面逻辑：只对外给 `hand()` 和 `subscribe(fn)`，谁用谁订阅；
 *   - **订阅计数**：多个页面同时用也只开一个系统监听，最后一个退订时才 `off`，
 *     避免各页面自己 on/off 互相打断（系统对重复订阅/漏退订很敏感）；
 *   - 拿不到能力（老机器 / 权限没给 / 801）就静默降级为「不知道」，
 *     调用方按默认值排版，绝不弹窗、绝不崩。
 *
 * 用法：
 *   GripSense.get().subscribe((hand: GripHand) => { this.leftHanded = hand === GripHand.LEFT; });
 *   GripSense.get().unsubscribe(token);          // 页面销毁时
 *   GripSense.get().hand()                        // 随时读当前值
 */
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 握持手。UNKNOWN = 拿不到（老机器 / 权限没给 / 系统还没判出来）。 */
export enum GripHand {
  UNKNOWN = 0,
  LEFT = 1,
  RIGHT = 2
}

export type GripListener = (hand: GripHand) => void;

interface Sub {
  token: number;
  fn: GripListener;
}

export class GripSense {
  private static shared: GripSense | undefined = undefined;

  static get(): GripSense {
    if (GripSense.shared === undefined) {
      GripSense.shared = new GripSense();
    }
    return GripSense.shared;
  }

  private cur: GripHand = GripHand.UNKNOWN;
  /** 系统这次到底有没有在监听：失败过就不再重试，免得每次进页面都报错。 */
  private listening: boolean = false;
  private broken: boolean = false;
  private usingHolding: boolean = false;
  private subs: Sub[] = [];
  private seq: number = 0;
  private callback: ((status: motion.HoldingHandStatus) => void) | undefined = undefined;
  private opCallback: ((status: motion.OperatingHandStatus) => void) | undefined = undefined;
  /** 系统能力不可用时的兜底判据：最近几次触摸落在屏幕哪一侧。 */
  private leftTouches: number = 0;
  private rightTouches: number = 0;
  /** 诊断用：最后一次失败原因（on/off 的 code），排查时打日志能直接看到。 */
  private diag: string = '';

  /** 当前握持手；没监听/没判出来时是 UNKNOWN。 */
  hand(): GripHand {
    return this.cur;
  }

  /** 是否左手握持（UNKNOWN 视为否，调用方按右手默认排版）。 */
  leftHanded(): boolean {
    return this.cur === GripHand.LEFT;
  }

  /**
   * 订阅。返回 token，页面销毁时用 `unsubscribe(token)` 退订。
   * 第一个订阅者会真正去开系统监听；开不起来也会立刻回调一次 UNKNOWN，
   * 这样调用方不用管「有没有回调」的差异。
   */
  subscribe(fn: GripListener): number {
    this.seq++;
    const token: number = this.seq;
    this.subs.push({ token: token, fn: fn });
    if (!this.listening && !this.broken) {
      this.start();
    }
    // 立刻给一次当前值：新页面不必等系统下一次判定才有正确排版
    try {
      fn(this.cur);
    } catch (e) {
      console.info('[amane] grip listener error');
    }
    return token;
  }

  unsubscribe(token: number): void {
    const rest: Sub[] = [];
    for (let i = 0; i < this.subs.length; i++) {
      if (this.subs[i].token !== token) {
        rest.push(this.subs[i]);
      }
    }
    this.subs = rest;
    if (this.subs.length === 0) {
      this.stop();
    }
  }

  /**
   * 兜底判据（2026-11-16 真机「没反应」后加的）：系统给不了握持手时，
   * 用「用户手指常落在屏幕哪一侧」推断。
   * 不追求精确 —— 只要连续几次都按在同一侧，就认为那只手是主力手。
   * `x` 是触摸点横坐标（px），`w` 是屏幕宽（px）。
   */
  noteTouch(x: number, w: number): void {
    if (this.listening || w <= 0) {
      return;   // 系统在说话就听系统的，别自己猜
    }
    if (x < w * 0.38) {
      this.leftTouches++;
      this.rightTouches = Math.max(0, this.rightTouches - 1);
    } else if (x > w * 0.62) {
      this.rightTouches++;
      this.leftTouches = Math.max(0, this.leftTouches - 1);
    } else {
      return;
    }
    if (this.leftTouches >= 3 && this.leftTouches > this.rightTouches + 1) {
      this.setHand(GripHand.LEFT, 'touch-heuristic');
    } else if (this.rightTouches >= 3 && this.rightTouches > this.leftTouches + 1) {
      this.setHand(GripHand.RIGHT, 'touch-heuristic');
    }
  }

  /** 当前诊断串（排查用，不进 UI）。 */
  diagText(): string {
    return `grip diag: ${this.diag}, listening=${this.listening}, hand=${this.cur}`;
  }

  private start(): void {
    this.tryStart('holdingHandChanged');
  }

  /**
   * 两级尝试：
   *   ① `holdingHandChanged`（HoldingHandStatus）—— 最贴「握持」；
   *   ② `operatingHandChanged`（OperatingHandStatus）—— 老的「操作手」，权限口径不同。
   * 两个都 801/201 就认为系统给不了，交给 `noteTouch` 的兜底。
   */
  private tryStart(kind: string): void {
    // 官方文档要求先判能力：canIUse('SystemCapability.MultimodalAwareness.Motion')。
    // 不支持就别调 on()，省得每次都抛 801 走异常路径。
    try {
      if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        this.diag = 'capability 不支持';
        console.info('[amane] grip: 本机没有 Motion 能力');
        if (kind === 'holdingHandChanged') {
          this.tryStart('operatingHandChanged');
        } else {
          this.broken = true;
        }
        return;
      }
    } catch (e) {
      this.diag = 'canIUse 异常';
      this.broken = true;
      return;
    }
    try {
      if (kind === 'holdingHandChanged') {
        if (this.callback === undefined) {
          this.callback = (status: motion.HoldingHandStatus) => {
            this.applyHolding(status);
          };
        }
        motion.on('holdingHandChanged', this.callback);
        this.usingHolding = true;
      } else {
        if (this.opCallback === undefined) {
          this.opCallback = (status: motion.OperatingHandStatus) => {
            this.applyOperating(status);
          };
        }
        motion.on('operatingHandChanged', this.opCallback);
        this.usingHolding = false;
      }
      this.listening = true;
      this.diag = `${kind} ok`;
      console.info(`[amane] grip: 已开始监听 ${kind}`);
    } catch (err) {
      const e = err as BusinessError;
      this.diag = `${kind} 失败 ${e.code}`;
      console.info(`[amane] grip: ${kind} 失败（${e.code}）`);
      if (kind === 'holdingHandChanged') {
        this.tryStart('operatingHandChanged');
      } else {
        this.broken = true;
        console.info('[amane] grip: 系统不支持，改用触摸侧向兜底');
      }
    }
  }

  private stop(): void {
    if (!this.listening) {
      return;
    }
    try {
      if (this.usingHolding && this.callback !== undefined) {
        motion.off('holdingHandChanged', this.callback);
      } else if (!this.usingHolding && this.opCallback !== undefined) {
        motion.off('operatingHandChanged', this.opCallback);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] grip: off 失败 ${e.code}`);
    }
    this.listening = false;
    this.cur = GripHand.UNKNOWN;
  }

  private applyHolding(status: motion.HoldingHandStatus): void {
    let next: GripHand = GripHand.UNKNOWN;
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      next = GripHand.LEFT;
    } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      next = GripHand.RIGHT;
    }
    console.info(`[amane] grip: holding status=${status} → ${next}`);
    this.setHand(next, 'holding');
  }

  private applyOperating(status: motion.OperatingHandStatus): void {
    let next: GripHand = GripHand.UNKNOWN;
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      next = GripHand.LEFT;
    } else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      next = GripHand.RIGHT;
    }
    console.info(`[amane] grip: operating status=${status} → ${next}`);
    this.setHand(next, 'operating');
  }

  private setHand(next: GripHand, from: string): void {
    if (next === this.cur) {
      return;
    }
    this.cur = next;
    this.diag = `${from} → ${next}`;
    for (let i = 0; i < this.subs.length; i++) {
      try {
        this.subs[i].fn(next);
      } catch (e) {
        console.info('[amane] grip listener error');
      }
    }
  }
}
