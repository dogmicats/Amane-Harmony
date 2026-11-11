/**
 * 画中画的全局登记处（同一时刻只允许一个小窗）。
 *
 * 为什么要它：小窗靠播放页里的 XComponent controller 活着。用户在软件里又开了
 * 另一部片（新的播放页实例）时，旧小窗必须被主动关掉，否则两个窗口抢同一个
 * surface，画面会乱。新页面拿不到旧页面的实例，只能通过这个静态表互相通知。
 */
export class PipHub {
  private static owner: string = '';
  private static stopFn: (() => void) | undefined = undefined;

  /** 声明「这个小窗是我的」：先把别人的关掉。 */
  static claim(owner: string, stopFn: () => void): void {
    if (PipHub.owner.length > 0 && PipHub.owner !== owner && PipHub.stopFn !== undefined) {
      try {
        PipHub.stopFn();
      } catch (err) {
        console.error(`[amane] pip hub stop: ${JSON.stringify(err)}`);
      }
    }
    PipHub.owner = owner;
    PipHub.stopFn = stopFn;
  }

  /** 有新播放开始时调用：把正在放的小窗关掉。 */
  static stopOthers(owner: string): void {
    if (PipHub.owner.length > 0 && PipHub.owner !== owner && PipHub.stopFn !== undefined) {
      try {
        PipHub.stopFn();
      } catch (err) {
        console.error(`[amane] pip hub stop: ${JSON.stringify(err)}`);
      }
    }
    if (PipHub.owner !== owner) {
      PipHub.owner = '';
      PipHub.stopFn = undefined;
    }
  }

  static release(owner: string): void {
    if (PipHub.owner === owner) {
      PipHub.owner = '';
      PipHub.stopFn = undefined;
    }
  }
}
