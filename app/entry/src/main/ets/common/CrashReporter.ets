import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { httpPost } from './Http';
import { Store } from './Store';

/**
 * 崩溃日志上报（通用运维能力，不属于任何私有扩展）。
 *
 * 2.0.2 起 EntryAbility 会把未捕获的 JS 异常栈追加到沙箱 files/crash.log，
 * 但以前只能连真机用 hdc 捞。这里在首页启动成功后静默上报到
 * /api/user/crash，成功后删除本地文件；设置页也能手动上传 / 清空。
 * 上报失败一律静默保留，绝不因为诊断逻辑影响正常启动。
 */

const CRASH_FILE: string = 'crash.log';
const MAX_UPLOAD: number = 20000;

export interface CrashInfo {
  exists: boolean;
  bytes: number;
  lines: number;
}

function crashPath(context: common.UIAbilityContext): string {
  return `${context.filesDir}/${CRASH_FILE}`;
}

export function crashInfo(context: common.UIAbilityContext): CrashInfo {
  const empty: CrashInfo = { exists: false, bytes: 0, lines: 0 };
  try {
    const path: string = crashPath(context);
    if (!fileIo.accessSync(path)) {
      return empty;
    }
    const text: string = fileIo.readTextSync(path, { encoding: 'utf-8' });
    let lines: number = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) === 10) {
        lines++;
      }
    }
    return { exists: true, bytes: text.length, lines: lines };
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] crash info: ${e.code} ${e.message}`);
    return empty;
  }
}

/** 返回上报的字符数；0 表示没有日志或上报失败（失败时保留本地文件）。 */
export async function uploadCrashLog(context: common.UIAbilityContext): Promise<number> {
  if (Store.I.user.length === 0) {
    return 0;
  }
  let text: string = '';
  try {
    const path: string = crashPath(context);
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    text = fileIo.readTextSync(path, { encoding: 'utf-8' });
  } catch (err) {
    return 0;
  }
  if (text.length === 0) {
    return 0;
  }
  try {
    await httpPost(`${Store.I.user}/api/user/crash`, Store.I.token,
      JSON.stringify({ text: text.substring(0, MAX_UPLOAD) }));
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] crash upload: ${e.code} ${e.message}`);
    return 0;
  }
  try {
    fileIo.unlinkSync(crashPath(context));
  } catch (err) {
    const e = err as BusinessError;
    console.warn(`[amane] crash cleanup: ${e.code} ${e.message}`);
  }
  return text.length;
}

export function clearCrashLog(context: common.UIAbilityContext): void {
  try {
    const path: string = crashPath(context);
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.warn(`[amane] crash clear: ${e.code} ${e.message}`);
  }
}
