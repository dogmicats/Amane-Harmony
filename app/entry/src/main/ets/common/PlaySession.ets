/**
 * 播放会话交接（2.6.2.1）—— 全局小窗的地基。
 *
 * 为什么需要它：播放器长在页面组件里（XComponent + mpv），页面一走就没了。
 * 想「离开详情页还在小窗里播」，只能**记下此刻的播放状态**，交给另一个宿主
 * （浮窗里那个独立播放器）接着放；回来时反向交接一次。
 *
 * 这里不碰播放器参数，只做一件事：一个可读可写的状态包 + 谁在负责交接的登记处。
 */
import { common } from '@kit.AbilityKit';

export interface PlayHandoff {
  /** 条目 id（详情页/播放页都用它）。 */
  mid: number;
  number: string;
  title: string;
  /** f<media_file_id>，空串表示让上游自己挑。 */
  fileKey: string;
  fileName: string;
  /** 看到第几秒。 */
  pos: number;
  speed: number;
  /** 远程字幕 id（服务端那套）；空 = 没选。 */
  subId: string;
  /** 同目录字幕文件名；空 = 没选。 */
  localSub: string;
  /** 音轨下标，-1 = 跟随默认。 */
  audioIndex: number;
  /** 只做小窗档（详情页发起时为 true）；放在会话里是因为 ComponentContent 只收单参。 */
  compact: boolean;
}

export class PlaySession {
  /** 正在浮窗里播的那一份（没有浮窗就是 undefined）。 */
  static active: PlayHandoff | undefined = undefined;
  /**
   * 由 PlayerView 注册：把「此刻我在放什么」导出来。
   * 用回调而不是让浮窗去翻页面状态 —— 页面状态本来就该由页面自己解释。
   */
  static exporter: (() => PlayHandoff | undefined) | undefined = undefined;
  /** 由 DetailPage 注册：浮窗要「回到详情页」时怎么回（带位置）。 */
  static opener: ((h: PlayHandoff) => void) | undefined = undefined;
  /**
   * 由 DetailPage 注册：把当前播放交接给应用内浮窗（点「画中画」按钮走这条）。
   *
   * 为什么不直接让 PlayerView 自己开浮窗：开完还得把页内播放器停掉（同一时刻只能一路音频），
   * 那是宿主页面的事。PlayerView 只负责说「我要交接」，落地由页面决定。
   */
  static handoff: (() => void) | undefined = undefined;

  static empty(): PlayHandoff {
    const h: PlayHandoff = {
      mid: 0, number: '', title: '', fileKey: '', fileName: '',
      pos: 0, speed: 1, subId: '', localSub: '', audioIndex: -1, compact: true
    };
    return h;
  }

  /** 当前状态（导出方没登记就返回空包，调用方据此判断能不能交接）。 */
  static snapshot(): PlayHandoff {
    const fn = PlaySession.exporter;
    if (fn === undefined) {
      return PlaySession.empty();
    }
    const got = fn();
    return got === undefined ? PlaySession.empty() : got;
  }

  static clear(): void {
    PlaySession.active = undefined;
  }
}

/** 浮窗与页面共享的上下文（浮窗里建播放器要用它）。 */
export class PlayEnv {
  static ctx: common.UIAbilityContext | undefined = undefined;

  static set(ctx: common.UIAbilityContext): void {
    PlayEnv.ctx = ctx;
  }
}
