/**
 * 更新提示（2026-11-14，Agent3）。
 *
 * 用户要的是：**打开 App 就后台静默检测**；有新版就在「我的」右上角点两个小红点，
 * 并且能给一个「本次更新不提醒」。
 *
 * 为什么单独一个类、而不是塞进 `Updater`：
 * `Updater.check()` 是多源串行（public 通道还要试 GitHub 三处），带网络等待，
 * 属于「用户主动点检查」的路径；这里要的是**静默、限流、失败不出声**，
 * 两个入口共用同一次检查结果，但触发时机与错误处理完全不同。
 *
 * 状态放 `AppStorage`（红点要在「我的」页跨组件响应），
 * 静音与「上次检查时间」落偏好（重启后仍然有效）。
 */
import { Updater, CheckResult } from './Updater';
import { Store } from './Store';

/** 静音签名：`客户端新版本|服务端新版本`。任一侧换版本 → 签名变 → 红点重新出现。 */
const PREF_MUTED: string = 'update_muted_sig';
/** 上次检查时间（毫秒）。用于限流，避免每次切前台都打一遍清单。 */
const PREF_LAST: string = 'update_last_check_ms';

/** 两次静默检测的最小间隔（10 分钟）。 */
const MIN_GAP_MS: number = 10 * 60 * 1000;
/** 启动后延迟：让首页先拿满数据，别和首屏请求抢带宽。 */
const START_DELAY_MS: number = 4000;

export class UpdateWatch {
  /** AppStorage 键：客户端有新包 / 服务端有新版本。 */
  static readonly KEY_CLIENT: string = 'update_dot_client';
  static readonly KEY_SERVER: string = 'update_dot_server';
  /** AppStorage 键：新版本号（菜单里显示用）。 */
  static readonly KEY_CLIENT_VER: string = 'update_ver_client';
  static readonly KEY_SERVER_VER: string = 'update_ver_server';

  private static started: boolean = false;
  private static running: boolean = false;

  /** 启动一次静默检测（幂等）。App 起来调一次即可。 */
  static ensureStarted(): void {
    if (UpdateWatch.started) {
      return;
    }
    UpdateWatch.started = true;
    setTimeout(() => {
      UpdateWatch.quietCheck();
    }, START_DELAY_MS);
  }

  /** 静音签名（当前该被静音的那一组版本）。 */
  private static sigOf(clientVer: string, serverVer: string): string {
    return `${clientVer}|${serverVer}`;
  }

  static mutedSig(): string {
    return Store.I.prefString(PREF_MUTED, '');
  }

  /** 「本次更新不提醒」：记住当前这一组版本，红点立即消失；出了更新的版本会再次提示。 */
  static mute(): void {
    const clientVer: string = `${AppStorage.get<string>(UpdateWatch.KEY_CLIENT_VER) ?? ''}`;
    const serverVer: string = `${AppStorage.get<string>(UpdateWatch.KEY_SERVER_VER) ?? ''}`;
    Store.I.prefSetString(PREF_MUTED, UpdateWatch.sigOf(clientVer, serverVer));
    UpdateWatch.publish(false, false, clientVer, serverVer);
  }

  /** 恢复提醒（设置里给用户留的后路；暂时只由 UpdatePage 的按钮调用）。 */
  static unmute(): void {
    Store.I.prefSetString(PREF_MUTED, '');
  }

  private static publish(dotClient: boolean, dotServer: boolean,
    clientVer: string, serverVer: string): void {
    AppStorage.setOrCreate<boolean>(UpdateWatch.KEY_CLIENT, dotClient);
    AppStorage.setOrCreate<boolean>(UpdateWatch.KEY_SERVER, dotServer);
    AppStorage.setOrCreate<string>(UpdateWatch.KEY_CLIENT_VER, clientVer);
    AppStorage.setOrCreate<string>(UpdateWatch.KEY_SERVER_VER, serverVer);
  }

  /**
   * 静默检测本体：**任何失败都不出声**（没有网、清单 404、格式变了都只是「没检测到」）。
   *
   * 只有 `Store` 已就绪（知道服务端地址与 token）才有意义；未就绪时延后重试一次 ——
   * 冷启动时 `Store.init()` 与这里是并行的，谁先谁后不确定。
   */
  static async quietCheck(retry: boolean = true): Promise<void> {
    if (UpdateWatch.running) {
      return;
    }
    if (!Store.I.ready) {
      if (retry) {
        setTimeout(() => {
          UpdateWatch.quietCheck(false);
        }, 5000);
      }
      return;
    }
    const last: number = Number(Store.I.prefString(PREF_LAST, '0'));
    const now: number = Date.now();
    if (last > 0 && now - last < MIN_GAP_MS) {
      return;                    // 限流：刚查过就别再打，红点状态保持上次结果
    }
    UpdateWatch.running = true;
    try {
      const r: CheckResult = await Updater.check();
      // 只有**真读到清单**才记时间：失败（没网 / 清单 404 / 格式变了）不写，
      // 否则一次没网就把后面十分钟的检测全压住，用户会觉得"怎么从来不提示"。
      if (!r.ok) {
        return;
      }
      Store.I.prefSetString(PREF_LAST, `${now}`);
      const clientVer: string = r.clientUpdatable ? r.clientLatest : '';
      const serverVer: string = r.serverUpdatable ? r.serverLatest : '';
      const hasAny: boolean = clientVer.length > 0 || serverVer.length > 0;
      const muted: boolean = hasAny && UpdateWatch.mutedSig() === UpdateWatch.sigOf(clientVer, serverVer);
      UpdateWatch.publish(hasAny && !muted && clientVer.length > 0,
        hasAny && !muted && serverVer.length > 0, clientVer, serverVer);
      console.info(`[amane] update watch: client=${clientVer || '-'} server=${serverVer || '-'} muted=${muted}`);
    } catch (err) {
      // 静默：这条路径不该让用户看到任何东西
      console.info('[amane] update watch skipped');
    } finally {
      UpdateWatch.running = false;
    }
  }
}
