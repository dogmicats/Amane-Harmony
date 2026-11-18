import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';

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

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
          router.back();
          }
        })
        PageTitle({ text: '网页管理', fs: 18 })
        Blank()
        Text('刷新')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.controller.refresh();
          })
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  build() {
    Navigation(this.navStack) {
      Column() {

  // 六十改：让出浮层标题栏的高度
  Blank().height(this.barH())

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
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}