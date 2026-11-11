import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { httpGetBytes } from './Http';

/**
 * 截帧落到手机（应用沙箱）。
 *
 * 为什么不直接写相册：`ohos.permission.WRITE_IMAGEVIDEO` 是受限权限，
 * 普通应用要 ACL；沙箱写文件不需要任何权限，离线也能看。
 * 需要进系统相册时，从「我的截帧」里长按/分享，让用户在系统面板里选。
 *
 * 目录固定在 `filesDir/picks/<metadata_id>_<ms>.jpg` —— 管理页靠这个命名
 * 判断「这一帧在不在本机」，两边必须一致。
 */

export function pickDir(): string {
  const ctx = getContext() as common.UIAbilityContext;
  return `${ctx.filesDir}/picks`;
}

export function pickName(metadataId: number, ms: number): string {
  return `${metadataId}_${ms}.jpg`;
}

export function pickPath(metadataId: number, ms: number): string {
  return `${pickDir()}/${pickName(metadataId, ms)}`;
}

/** 这一帧是否已经在本机。 */
export function hasLocalPick(metadataId: number, ms: number): boolean {
  try {
    return fs.accessSync(pickPath(metadataId, ms));
  } catch (err) {
    return false;
  }
}

/** 下载一帧到沙箱，返回落盘路径。失败抛异常，调用方自己 toast。 */
export async function savePickLocal(url: string, token: string,
  metadataId: number, ms: number): Promise<string> {
  const dir: string = pickDir();
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] mkdir picks: ${e.code} ${e.message}`);
  }
  const path: string = pickPath(metadataId, ms);
  const bytes: ArrayBuffer = await httpGetBytes(url, token);
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, bytes);
  } finally {
    fs.closeSync(file);
  }
  return path;
}
