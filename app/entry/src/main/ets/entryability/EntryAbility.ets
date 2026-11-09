import { AbilityConstant, ConfigurationConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'Amane';

export default class EntryAbility extends UIAbility {
  private observerId: number = -1;
  private crashLog: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.crashLog = `${this.context.filesDir}/crash.log`;
    this.installCrashGuard();

    try {
      // 影院界面只在深色下成立，跟系统设置解耦
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'setColorMode failed');
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  /**
   * 注册 JS 崩溃观察者。注册之后未捕获异常不会再让进程退出，
   * 用户最多丢掉一次交互，而不是整页闪退。同时把栈追加到 crash.log 便于事后定位。
   */
  private installCrashGuard(): void {
    try {
      const observer: errorManager.ErrorObserver = {
        onUnhandledException: (errMsg: string) => {
          hilog.error(DOMAIN, TAG, '未捕获异常（已拦截）: %{public}s', errMsg);
          this.appendCrashLog(errMsg);
        }
      };
      this.observerId = errorManager.on('error', observer);
      hilog.info(DOMAIN, TAG, 'crash guard installed: %{public}d', this.observerId);
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'install crash guard failed');
    }
  }

  private appendCrashLog(text: string): void {
    if (this.crashLog.length === 0) {
      return;
    }
    const stamp: string = new Date().toISOString();
    try {
      const file: fs.File = fs.openSync(this.crashLog,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `\n===== ${stamp} =====\n${text}\n`);
      fs.closeSync(file);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'write crash.log failed');
    }
  }

  onDestroy(): void {
    if (this.observerId >= 0) {
      try {
        errorManager.off('error', this.observerId).catch(() => {});
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'off error observer failed');
      }
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor('#0B0B0F');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'set window background failed');
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
