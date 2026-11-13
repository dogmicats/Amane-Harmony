import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { PlayerParams } from '../common/Types';
import { PlayerView } from '../view/PlayerView';

/**
 * Emby 模式播放页（薄壳）。
 *
 * 为什么另起一个文件、不直接改 `pages/PlayerPage.ets`：
 * 并行会话的 `emu-verify` 会把 `PlayerPage.ets` 还原成它备份的旧实现（916 行的
 * 自包含播放器），改十次被盖十次 —— Emby 模式于是绕过 `view/PlayerView`，
 * 返回键、弹幕、缓存、相册全部失效。这个文件不在它的备份清单里，稳定。
 *
 * 职责只有三件：
 *  1. 读一次路由参数；
 *  2. 渲染 `PlayerView`（pageHost = true）；
 *  3. 返回键：横屏先退全屏，竖屏才退出页面（回详情页）。
 */
@Entry
@ComponentV2
struct PlayerHostPage {
  @Local ready: boolean = false;
  @Local mid: number = 0;
  @Local num: string = '';
  @Local ttl: string = '';
  @Local fkey: string = '';
  @Local fname: string = '';
  @Local pos: number = 0;
  /** Emby 进来就是横屏铺满。 */
  @Local mode: string = 'landscape';
  /** PlayerView 上报的当前形态，返回键据此决定「先退全屏」还是「退出页面」。 */
  @Local curMode: string = 'landscape';
  /** 请求 PlayerView 退出全屏（自增信号）。 */
  @Local exitSig: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as PlayerParams;
    if (params !== undefined && params !== null) {
      this.mid = params.id === undefined || params.id === null ? 0 : Number(params.id);
      this.num = params.number === undefined || params.number === null ? '' : String(params.number);
      this.ttl = params.title === undefined || params.title === null ? '' : String(params.title);
      this.fkey = params.fileKey === undefined || params.fileKey === null ? '' : String(params.fileKey);
      this.fname = params.fileName === undefined || params.fileName === null ? ''
        : String(params.fileName);
      const p: number = params.position === undefined || params.position === null
        ? 0 : Number(params.position);
      this.pos = p > 5 ? p : 0;
    }
    // 「跳播放页」只服务 Emby 模式；B 站模式不会走到这里（播放器长在详情页顶部）。
    // 形态固定 'landscape'：竖屏全屏（portraitFull）这个中间态已废弃 ——
    // 它会和窗口方向互相拉扯（横竖来回切、surface 反复重建），是多个播放 bug 的源头。
    this.mode = 'landscape';
    this.curMode = this.mode;
    this.ready = true;
  }

  onBackPress(): boolean {
    if (this.curMode !== 'portrait') {
      this.exitSig = this.exitSig + 1;
      return true;
    }
    return false;
  }

  build() {
    Stack() {
      if (this.ready) {
        PlayerView({
          metaIdParam: this.mid,
          numberParam: this.num,
          titleParam: this.ttl,
          keyParam: this.fkey,
          nameParam: this.fname,
          posParam: this.pos,
          modeParam: this.mode,
          autoplay: true,
          pageHost: true,
          exitSignal: this.exitSig,
          onModeChange: (m: string) => {
            this.curMode = m;
          },
          onExited: () => {
            if (this.curMode !== 'portrait') {
              this.exitSig = this.exitSig + 1;
              return;
            }
            router.back();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
