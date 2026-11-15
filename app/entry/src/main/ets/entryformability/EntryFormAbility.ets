/**
 * 桌面服务卡片的数据源（2.6.1.26）
 *
 * 只做一件事：把 App 写好的缓存转成 formBindingData。**不发请求**（理由见 CardCache）。
 *
 * `onAddForm` 第一次上桌面、`onUpdateForm` 系统定时刷新（form_config 里配了 30 分钟一次）
 * 都走同一条路：读缓存 → 组装 → 返回。读不到就给空字段，卡片自己显示「打开 App 同步一次」。
 */
import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardPayload, parsePayload, readRaw } from '../common/CardCache';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 组装当前卡片该显示的内容。 */
  private build(): CardPayload {
    return parsePayload(readRaw(this.context));
  }

  onAddForm(_want: Want): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData(this.build() as object);
  }

  onUpdateForm(formId: string): void {
    const data: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(this.build() as object);
    formProvider.updateForm(formId, data).catch((err: BusinessError) => {
      console.info(`[amane] form update: ${err.code}`);
    });
  }

  /** 卡片里没有按钮走 message 动作，这里留空实现即可（点击走 router 直达 App）。 */
  onFormEvent(_formId: string, _message: string): void {
  }

  onRemoveForm(_formId: string): void {
  }
}
