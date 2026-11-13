import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 客户端运行日志（临时诊断用，2.5.6.1 起）。
 *
 * 为什么需要它：出问题时只能靠 `hdc hilog` 抓日志，用户手上不一定有电脑。
 * 所以这里在内存里留一个环形缓冲，玩家在「设置 → 导出日志」一键存成 txt，
 * 再自己发出来即可。
 *
 * 只记**我们主动 mark 的事件**（播放器挂载/重建/seek/缓冲/报错），
 * 不去截 console —— 截 console 在 ArkTS 里不可靠，而且日志量太大没法看。
 */

const CAP: number = 3000;
const lines: string[] = [];
let installed: boolean = false;

function stamp(): string {
  const d: Date = new Date();
  const p2 = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  const p3 = (n: number): string => n < 10 ? `00${n}` : (n < 100 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())} ` +
    `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}.${p3(d.getMilliseconds())}`;
}

export class AppLog {
  static mark(tag: string, msg: string): void {
    lines.push(`${stamp()} [${tag}] ${msg}`);
    while (lines.length > CAP) {
      lines.shift();
    }
    // 同时打到 hilog，接电脑时两边都能看
    console.info(`[amane] [${tag}] ${msg}`);
  }

  static dump(): string {
    return lines.length === 0 ? '(还没有记录)' : lines.join('\n');
  }

  static count(): number {
    return lines.length;
  }

  /**
   * 导出：弹系统「保存到文件」，用户自己选位置（默认落在下载目录）。
   * 用户取消不算错误，安静返回即可。
   */
  static async export(ctx: common.UIAbilityContext): Promise<string> {
    const text: string = `# amane 运行日志 ${stamp()}\n${'# '.padEnd(2)}共 ${lines.length} 行\n\n` +
      AppLog.dump() + '\n';
    const name: string = `amane-log-${Date.now()}.txt`;
    try {
      const saver = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await saver.save({ newFileNames: [name] });
      if (uris === undefined || uris.length === 0) {
        return '已取消';
      }
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
      return `已保存：${name}（${lines.length} 行）`;
    } catch (err) {
      const e = err as BusinessError;
      // 退路：写进应用沙箱，至少不会丢
      try {
        const dir: string = ctx.filesDir;
        const path: string = `${dir}/${name}`;
        const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fileIo.writeSync(f.fd, text);
        fileIo.closeSync(f);
        return `保存失败（${e.message}），已存到沙箱：${path}`;
      } catch (err2) {
        const e2 = err2 as BusinessError;
        return `导出失败：${e2.message}`;
      }
    }
  }
}

/** 预留：将来若要整体安装（截 console），从这里挂。现在只 mark。 */
export function installAppLog(): boolean {
  installed = true;
  return installed;
}
