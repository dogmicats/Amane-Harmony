import { AbilityConstant, ConfigurationConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cacheInit } from '../common/PageCache';
import { imgCacheInit } from '../common/ImgCache';

const DOMAIN: number = 0x0000;
const TAG: string = 'Amane';

export default class EntryAbility extends UIAbility {
  private observerId: number = -1;
  private crashLog: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.crashLog = `${this.context.filesDir}/crash.log`;
    this.installCrashGuard();

    // 页面级缓存（用户第 9 条）：越早初始化越好，第一个页面就能读到上次的数据
    cacheInit(this.context);
    // 图片磁盘缓存（2.6.2.1）：索引必须在第一帧之前进内存，不然首屏每张图都当未命中，
    // 白排一轮下载 —— 这里同步读一个小 JSON，几十 KB，几毫秒。
    imgCacheInit(this.context);

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
      // ── 方向：全局锁竖屏，只有播放器例外（2026-11-18 用户：「横屏界面没专门调试过，
      // 先禁止除了播放器以外的所有横屏」）──
      // 以前全局是 AUTO_ROTATION（整个 App 跟重力转），但除播放页外的界面（首页/媒体库/
      // 负一屏/短剧/设置等）从没按横屏调过版式，转过去就会压扁、错位。现在默认锁 PORTRAIT；
      // 播放页进入时由 PlayerView.applyWindowMode 自己切 LANDSCAPE/AUTO，退出时切回 PORTRAIT，
      // 那条路径不动 —— 所以「只有播放器能横屏」。等各页横屏版式调好再放开这里。
      mainWindow.setPreferredOrientation(window.Orientation.PORTRAIT);
      // ── 系统栏透明，跟应用融为一体（2026-11-16 用户：上下还有黑边，要像 hosplayer 那样）──
      // 两根系统栏的底色做成全透明，背后露出窗口背景（#0B0B0F），和 App 深色底一致。
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        // 深色底 → 图标用浅色
        isStatusBarLightIcon: true,
        isNavigationBarLightIcon: true
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'system bar props failed: %{public}s', JSON.stringify(e));
      });
      // 真全屏必须在**页面加载之前**打开（2026-11-16 用户：演员页首屏底部留一条黑边，
      // 手指轻轻一滑才铺满）。放到 `Index.aboutToAppear` 里做，第一次布局已经按
      // 「非全屏」的高度算过一遍，页面得等一次重新布局才铺到底 —— 那一帧就是黑边。
      mainWindow.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'fullscreen failed: %{public}s', JSON.stringify(e));
      });
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
    // 页面靠它区分「被别的页盖住」和「整个应用切后台」——后者走小窗/后台播放，不该弹浮窗
    AppStorage.setOrCreate<boolean>('appBg', false);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    AppStorage.setOrCreate<boolean>('appBg', true);
  }
}
