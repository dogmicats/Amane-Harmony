import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/**
 * 保存图片到**系统相册**（用户第 10 条）。
 *
 * 之前那个「存到手机」其实是把图落到应用沙箱 `filesDir/picks/` —— 在应用里再存
 * 一份，用户根本看不到。现在改成真正写进媒体库：
 *
 *  - 走 `showAssetsCreationDialog`：系统弹一次「保存到相册」确认（带应用名+图标），
 *    用户点确认后写入，**不需要** `ohos.permission.WRITE_IMAGEVIDEO`
 *    （那是受限权限，普通应用申请不到，硬申请会被安装期拦掉）；
 *  - 返回值是该媒体文件的 URI，写权限永久有效；
 *  - 因为要确认，所以「自动保存」在系统层面也只能是「自动发起 + 一次确认」，
 *    这是平台限制，不是偷懒。
 */
export class Gallery {
  /**
   * @param ctx  UIAbilityContext
   * @param filePath 沙箱里的 jpg 绝对路径
   * @param title 相册里的文件名（不含扩展名）
   * @returns 保存成功返回 true
   */
  static async saveImage(ctx: common.UIAbilityContext, filePath: string,
    title: string): Promise<boolean> {
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      // 沙箱文件要转成 file:// URI；系统允许保存沙箱来源，只是不给预览
      const uri: string = fileUri.getUriFromPath(filePath);
      const cfg: photoAccessHelper.PhotoCreationConfig = {
        title: title.length > 0 ? title : `Amane_${Date.now()}`,
        fileNameExtension: 'jpg',
        photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const created: Array<string> = await helper.showAssetsCreationDialog([uri], [cfg]);
      return created !== undefined && created !== null && created.length > 0;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] gallery save: ${e.code} ${e.message}`);
      return false;
    }
  }
}
