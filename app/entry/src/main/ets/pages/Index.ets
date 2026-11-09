import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { HomeTab } from './HomeTab';
import { LibraryTab } from './LibraryTab';
import { FavoritesTab } from './FavoritesTab';
import { ProfileTab } from './ProfileTab';

@Entry
@Component
struct Index {
  @State booting: boolean = true;
  @State bootText: string = '正在连接服务器…';
  @State failMsg: string = '';
  @State currentTab: number = 0;
  @State homeRefresh: number = 0;
  @State favRefresh: number = 0;
  @State libRefresh: number = 0;
  private tabs: TabsController = new TabsController();

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      Store.I.init(context);
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] init: ${err.code} ${err.message}`);
    }
    this.boot();
  }

  private async boot(): Promise<void> {
    this.booting = true;
    this.failMsg = '';
    this.bootText = Store.I.mode === 'auto' ? '正在探测局域网…' : '正在连接…';
    try {
      await Store.I.resolve();
      this.bootText = Store.I.onWan ? '正在连接外网…' : '正在读取媒体库…';
      try {
        await this.connect();
      } catch (error) {
        // 自动模式下探活可能误判（比如刚换了网段），局域网拉不到数据就退到外网再试一次
        if (Store.I.mode === 'auto' && !Store.I.onWan && Store.I.wanAmane.length > 0) {
          console.info('[amane] lan failed, fallback to wan');
          this.bootText = '局域网连不上，改用外网…';
          Store.I.useWan();
          await this.connect();
        } else {
          throw error as Error;
        }
      }
      this.booting = false;
      this.refreshTabs();
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] boot failed: ${err.code} ${err.message}`);
      this.booting = false;
      this.failMsg = `已尝试 ${Store.I.onWan ? '外网' : '局域网'} 地址：${Store.I.user}`;
    }
  }

  private async connect(): Promise<void> {
    await Store.I.loadConfig();
    await Store.I.loadFavIds();
  }

  private refreshTabs(): void {
    this.homeRefresh++;
    this.libRefresh++;
    this.favRefresh++;
  }

  onPageShow(): void {
    // 从播放页 / 详情页返回：首页的「继续观看」和收藏状态可能变了
    if (!this.booting && this.failMsg.length === 0) {
      this.homeRefresh++;
      this.favRefresh++;
    }
  }

  @Builder
  TabBarItem(index: number, label: string, glyph: string) {
    Column({ space: 3 }) {
      Text(glyph)
        .fontSize(18)
        .fontColor(this.currentTab === index ? Theme.ACCENT : Theme.TEXT_FAINT)
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? Theme.TEXT : Theme.TEXT_FAINT)
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      if (this.booting) {
        Column({ space: 14 }) {
          Text('Amane')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.ACCENT)
          Text(this.bootText)
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failMsg.length > 0) {
        Column({ space: 14 }) {
          Text('连不上服务器')
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(this.failMsg)
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 40, right: 40 })
          Row({ space: 12 }) {
            Button('重试')
              .height(40)
              .padding({ left: 24, right: 24 })
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(14)
              .onClick(() => {
                this.boot();
              })
            Button('设置地址')
              .height(40)
              .padding({ left: 24, right: 24 })
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(14)
              .onClick(() => {
                router.pushUrl({ url: 'pages/SettingsPage' });
              })
          }
          .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Tabs({ barPosition: BarPosition.End, controller: this.tabs, index: this.currentTab }) {
          TabContent() {
            HomeTab({ refreshKey: this.homeRefresh })
          }
          .tabBar(this.TabBarItem(0, '首页', '⌂'))
          .backgroundColor(Theme.BG)

          TabContent() {
            LibraryTab({ refreshKey: this.libRefresh })
          }
          .tabBar(this.TabBarItem(1, '媒体库', '▤'))
          .backgroundColor(Theme.BG)

          TabContent() {
            FavoritesTab({ refreshKey: this.favRefresh })
          }
          .tabBar(this.TabBarItem(2, '收藏', '♥'))
          .backgroundColor(Theme.BG)

          TabContent() {
            ProfileTab({ refreshKey: this.homeRefresh })
          }
          .tabBar(this.TabBarItem(3, '我的', '☺'))
          .backgroundColor(Theme.BG)
        }
        .barHeight(54)
        .barBackgroundColor('#0F0F14')
        .scrollable(false)
        .animationDuration(0)
        .onChange((index: number) => {
          this.currentTab = index;
          if (index === 0) {
            this.homeRefresh++;
          } else if (index === 1) {
            this.libRefresh++;
          } else if (index === 2) {
            this.favRefresh++;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
