/**
 * 后台音频会话（2.6.1.37）
 *
 * 为什么光有长时任务不够：长时任务只保证**进程不被冻结**，音频**焦点**是另一套机制。
 * 没有 AVSession 的应用一进后台，系统就把音频焦点收走（它不知道你在放什么），
 * native 播放器（mpv → OHAudio）随即被静音或暂停 —— 表现就是「切到桌面，播放自己停了」。
 *
 * 所以后台播放要三件齐全：
 *   1. `module.json5` 的 `KEEP_BACKGROUND_RUNNING` 权限 + `backgroundModes: ["audioPlayback"]`；
 *   2. 进入后台时 `startBackgroundRunning(...)`（见 BackgroundPlay）；
 *   3. **本文这个 AVSession**：声明「我在放音频」，系统才会把焦点留给你。
 *
 * 另外提供 `screenOff()`：锁屏（或息屏）时屏幕状态是 OFF，据此判定「该停了」——
 * 用户 19:27 明确要求「不要锁屏的后台播放，锁屏就是退出」。
 */
import { avSession } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

let session: avSession.AVSession | undefined;

export class BackAudio {
  /**
   * 建/复用会话并激活。播放器每次进前台都会调，内部幂等。
   * 失败只记日志：拿不到会话最多是「后台被静音」，不该连前台播放都受影响。
   */
  static async ensure(ctx: common.UIAbilityContext, title: string): Promise<void> {
    if (session !== undefined) {
      return;
    }
    try {
      const s: avSession.AVSession = await avSession.createAVSession(ctx, 'amane_playback', 'audio');
      await s.setAVMetadata({
        assetId: 'amane',
        title: title.length > 0 ? title : 'Amane',
        artist: 'Amane'
      });
      await s.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY
      });
      s.on('play', () => {
      });
      s.on('pause', () => {
      });
      await s.activate();
      session = s;
      console.info('[amane] avsession: on');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] avsession ensure: ${e.code} ${e.message}`);
    }
  }

  /** 播放/暂停状态同步给系统（锁屏控件、耳机线的显示依据）。 */
  static async setPlaying(on: boolean): Promise<void> {
    if (session === undefined) {
      return;
    }
    try {
      await session.setAVPlaybackState({
        state: on ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
      });
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] avsession state: ${e.code}`);
    }
  }

  /** 停播 / 离开播放器时撤掉会话，别让系统的媒体面板一直挂着。 */
  static async release(): Promise<void> {
    const s: avSession.AVSession | undefined = session;
    if (s === undefined) {
      return;
    }
    session = undefined;
    try {
      await s.destroy();
      console.info('[amane] avsession: off');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] avsession release: ${e.code}`);
    }
  }

  /**
   * 屏幕是否已经熄灭（锁屏或自动息屏）。
   *
   * 为什么用它判「锁屏」：`@ohos.screenLock` 是系统接口，普通应用拿不到；
   * 而锁屏必然伴随屏幕 OFF，这条路径对所有设备成立。
   */
  static screenOff(): boolean {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.state === display.DisplayState.STATE_OFF
        || d.state === display.DisplayState.STATE_DOZE
        || d.state === display.DisplayState.STATE_DOZE_SUSPEND;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] display state: ${e.code}`);
      return false;
    }
  }
}
