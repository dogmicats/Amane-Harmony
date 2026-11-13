import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/**
 * 保存图片到**系统相册**。
 *
 * 关键事实（2.5.4.9 读 SDK 里 `showAssetsCreationDialog` 的注释后确认）：
 *   > 用户同意后返回「已在媒体库创建、并授予写权限」的 URI 列表，**应用要用这些 URI 去写数据**。
 *
 * 也就是说：这个接口**只建资源记录 + 给写权限**，不会把你传进去的文件内容复制进去。
 * 只传 `srcFileUris` 而不写 → 媒体库里留一条 0 字节的「幽灵照片」：
 * 相册里看不见、图库里也没有（2.5.4.8 用户反馈的正是这个）。
 *
 * 所以这里统一做两件事：
 *   ① 沙箱落一份（对话框要求 `file://` 源）；
 *   ② 拿到返回 URI 后 `openSync(uri, WRITE_ONLY)` 把字节写进去。
 *
 * 另外提供 `saveToPicked()`：相册这条路走不通时，用系统文件选择器让用户自己挑位置
 * （「下载」目录等），文件管理里一定找得到。
 */
export class Gallery {
  /**
   * 把沙箱里的图片存进相册。
   *
   * @param filePath 沙箱绝对路径（**放 filesDir，不要放 cacheDir**）
   * @param title 相册里的文件名（不含扩展名）
   * @param ext 扩展名，不带点
   */
  static async saveImage(ctx: common.UIAbilityContext, filePath: string,
    title: string, ext: string = 'jpg'): Promise<boolean> {
    try {
      const buf: ArrayBuffer = Gallery.readFile(filePath);
      return await Gallery.saveBytes(ctx, buf, title, ext, filePath);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] gallery saveImage: ${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 字节直接存相册（有沙箱文件时把 `srcPath` 一起传，省一次读写）。
   *
   * 返回 true 的判据：系统返回了 URI **且** 我们成功把内容写进去了。
   */
  static async saveBytes(ctx: common.UIAbilityContext, bytes: ArrayBuffer, title: string,
    ext: string = 'jpg', srcPath: string = ''): Promise<boolean> {
    if (bytes === undefined || bytes === null || bytes.byteLength === 0) {
      console.error('[amane] gallery saveBytes: 空内容，不写');
      return false;
    }
    const name: string = title.length > 0 ? title : `Amane_${Date.now()}`;
    try {
      const path: string = srcPath.length > 0
        ? srcPath
        : Gallery.writeSandbox(ctx, bytes, `${name}.${ext}`);
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const cfg: photoAccessHelper.PhotoCreationConfig = {
        title: name,
        fileNameExtension: ext,
        photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const uri: string = fileUri.getUriFromPath(path);
      const created: Array<string> = await helper.showAssetsCreationDialog([uri], [cfg]);
      if (created === undefined || created === null || created.length === 0) {
        console.info('[amane] gallery save: 用户取消（返回空数组）');
        return false;
      }
      const target: string = created[0];
      // 真正决定「相册里有没有这张图」的一步：把字节写进媒体资源
      const dst = fileIo.openSync(target, fileIo.OpenMode.WRITE_ONLY);
      try {
        fileIo.writeSync(dst.fd, bytes);
      } finally {
        fileIo.closeSync(dst);
      }
      console.info(`[amane] gallery save ok ${bytes.byteLength}B -> ${target}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] gallery save: ${e.code} ${e.message} (src=${srcPath})`);
      return false;
    }
  }

  /**
   * 兜底：用系统文件选择器让用户挑保存位置，再把字节写进去。
   * 相册那条路不通时用（文件管理 / 下载目录里一定看得见）。
   */
  static async saveToPicked(ctx: common.UIAbilityContext, bytes: ArrayBuffer,
    fileName: string): Promise<boolean> {
    try {
      const doc = new picker.DocumentViewPicker(ctx);
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [fileName];
      const uris: Array<string> = await doc.save(opts);
      if (uris === undefined || uris === null || uris.length === 0) {
        console.info('[amane] saveToPicked: 用户取消');
        return false;
      }
      const dst = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(dst.fd, bytes);
      } finally {
        fileIo.closeSync(dst);
      }
      console.info(`[amane] saveToPicked ok -> ${uris[0]}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] saveToPicked: ${e.code} ${e.message}`);
      return false;
    }
  }

  /** 落一份到 `filesDir/export` 并返回绝对路径。 */
  private static writeSandbox(ctx: common.UIAbilityContext, bytes: ArrayBuffer, name: string): string {
    const dir: string = `${ctx.filesDir}/export`;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    const path: string = `${dir}/${name}`;
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes);
    } finally {
      fileIo.closeSync(file);
    }
    return path;
  }

  private static readFile(path: string): ArrayBuffer {
    const stat = fileIo.statSync(path);
    const buf: ArrayBuffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buf);
    } finally {
      fileIo.closeSync(file);
    }
    return buf;
  }
}
