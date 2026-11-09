import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/** 网页兜底：刮削、入库、任务队列等管理动作仍在 amane 自己的页面上做。 */
@Entry
@Component
struct WebPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State progress: number = 0;
  private url: string = '';

  aboutToAppear(): void {
    this.url = `${Store.I.amane}/`;
    // 网页端登录靠 amane_token cookie，这里直接种进去，省一次手动登录
    try {
      webview.WebCookieManager.configCookieSync(this.url, `amane_token=${Store.I.token}`);
    } catch (error) {
      console.error(`[amane] set web cookie: ${error}`);
    }
  }

  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (error) {
      console.error(`[amane] web backward: ${error}`);
    }
    return false;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('网页管理')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('刷新')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.controller.refresh();
          })
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      if (this.progress < 100) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(Theme.ACCENT)
      }

      Web({ src: this.url, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .mixedMode(MixedMode.All)
        .zoomAccess(false)
        .onProgressChange((event) => {
          this.progress = event.newProgress;
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
