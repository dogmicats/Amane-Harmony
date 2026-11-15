/**
 * 触感反馈（2.6.1.18）：让「收藏成功 / 删除确认 / 拖拽落位」摸得到。
 *
 * 三条约定：
 * 1. **只有三档**，语义固定，不允许各处自创时长 —— 手感一旦不一致，
 *    用户会觉得「有时有震有时没震」，比完全没有更差。
 *    - `tap()`   16ms：收藏、打分、点赞这种「点到了」；
 *    - `thud()`  28ms：删除、移除这种「做出了不可逆动作」；
 *    - `snap()`  40ms：拖拽落位、吸附这种「东西归位了」。
 * 2. **可关**。设置 → 外观 → 触感反馈（偏好 `ui_haptic`，默认开）。
 * 3. **失败不报错**。模拟器没有马达、部分设备禁用了振动服务，
 *    这属于「没有就没有」，绝不能在界面上弹提示。
 */
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from './Store';

/** 偏好键：`1` 开 / `0` 关。 */
export const PREF_HAPTIC: string = 'ui_haptic';
/** AppStorage 键：设置页切换后立刻生效，不用重启。 */
export const KEY_HAPTIC: string = 'amaneHaptic';

function enabled(): boolean {
  const v: number | undefined = AppStorage.get<number>(KEY_HAPTIC);
  if (v !== undefined) {
    return v === 1;
  }
  try {
    return Store.I.prefString(PREF_HAPTIC, '1') !== '0';
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] haptic pref: ${e.code}`);
    return true;
  }
}

function buzz(duration: number): void {
  if (!enabled()) {
    return;
  }
  try {
    vibrator.startVibration({ type: 'time', duration: duration }, { id: 0, usage: 'touch' })
      .catch((err: BusinessError) => {
        console.info(`[amane] haptic: ${err.code}`);
      });
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] haptic call: ${e.code}`);
  }
}

export class Haptics {
  /** 初始化：把偏好灌进 AppStorage（`Personalize.init()` 里调一次）。 */
  static init(): void {
    let on: boolean = true;
    try {
      on = Store.I.prefString(PREF_HAPTIC, '1') !== '0';
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] haptic init: ${e.code}`);
    }
    AppStorage.setOrCreate<number>(KEY_HAPTIC, on ? 1 : 0);
  }

  static isOn(): boolean {
    return enabled();
  }

  /** 改开关：立刻生效 + 落盘；打开时自己震一下作为演示。 */
  static setOn(on: boolean): void {
    AppStorage.setOrCreate<number>(KEY_HAPTIC, on ? 1 : 0);
    try {
      Store.I.prefSetString(PREF_HAPTIC, on ? '1' : '0');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] haptic set: ${e.code}`);
    }
    if (on) {
      buzz(16);
    }
  }

  /** 点到了（收藏 / 评分 / 选中）。 */
  static tap(): void {
    buzz(16);
  }

  /** 做出了动作（删除 / 移出）。 */
  static thud(): void {
    buzz(28);
  }

  /** 归位了（拖拽落位 / 吸附）。 */
  static snap(): void {
    buzz(40);
  }
}
