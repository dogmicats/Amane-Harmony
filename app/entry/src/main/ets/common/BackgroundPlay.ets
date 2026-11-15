/**
 * 后台播放（2.6.1.16）。
 *
 * 目标：按 home / 锁屏之后声音还在放。
 * 做法：应用进入后台时向系统申请一条「音频播放」长时任务（continuous task），
 * 系统才不会把进程冻住；回到前台或停止播放就撤掉。
 *
 * 为什么要单独一个类：两个播放器（内嵌的 PlayerView、整页的 PlayerPage）都要用，
 * 而长时任务是**应用级**的，不能各申请一条 —— 这里做成幂等单例。
 *
 * 配置依赖（`entry/src/main/module.json5`）：
 *   - `requestPermissions`: `ohos.permission.KEEP_BACKGROUND_RUNNING`
 *   - ability 的 `backgroundModes: ["audioPlayback"]`
 * 缺这两处，申请会直接抛 9800004/201 之类的错误，表现就是「切后台就没声」。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackAudio } from './BackAudio';
import { AppLog } from './AppLog';

export class BackgroundPlay {
  /** 是否已经申请到长时任务（重复 start 会直接返回）。 */
  private static running: boolean = false;
  private static agent: WantAgent | undefined = undefined;

  static get isRunning(): boolean {
    return BackgroundPlay.running;
  }

  /** 进入后台时调用。失败只记日志，不影响播放本身。 */
  static async start(ctx: common.UIAbilityContext): Promise<void> {
    // 锁屏/息屏不申请（2.6.1.37 用户定：锁屏就是退出）。这条要放在 running 判断之前，
    // 因为「先切桌面、再锁屏」时 running 已经是 true，光看它不会拦。
    if (BackAudio.screenOff()) {
      BackgroundPlay.stop(ctx);
      return;
    }
    if (BackgroundPlay.running) {
      return;
    }
    try {
      // 先要会话：没有 AVSession 时，长时任务申请到了，音频焦点照样会被系统收走
      // （症状就是「进程活着但没声音 / 播放自己停了」）。
      await BackAudio.ensure(ctx, '');
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      BackgroundPlay.agent = agent;
      BackgroundPlay.running = true;
      AppLog.mark('bgplay', 'start ok');
      console.info('[amane] background play: on');
    } catch (err) {
      const e = err as BusinessError;
      // 记进 AppLog：真机上出问题时用户能在「设置 → 关于 → 导出日志」里把它带回来
      AppLog.mark('bgplay', `start FAIL ${e.code} ${e.message}`);
      console.error(`[amane] background play start: ${e.code} ${e.message}`);
    }
  }

  /** 回到前台 / 结束播放 / 离开播放器时调用。 */
  static async stop(ctx: common.UIAbilityContext): Promise<void> {
    if (!BackgroundPlay.running) {
      // 没申请过也要撤会话：否则系统的媒体面板会一直显示「正在播放」
      BackAudio.release();
      return;
    }
    BackgroundPlay.running = false;
    BackgroundPlay.agent = undefined;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      AppLog.mark('bgplay', 'stop');
      console.info('[amane] background play: off');
    } catch (err) {
      const e = err as BusinessError;
      AppLog.mark('bgplay', `stop FAIL ${e.code}`);
      console.error(`[amane] background play stop: ${e.code} ${e.message}`);
    }
    BackAudio.release();
  }
}
