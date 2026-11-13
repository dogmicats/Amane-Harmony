import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router, uiMaterial } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { uploadCrashLog } from '../common/CrashReporter';
import { HomeTab } from './HomeTab';
import { LibraryTab } from './LibraryTab';
import { FavoritesTab } from './FavoritesTab';
import { ProfileTab } from './ProfileTab';
import { BuildConfig } from '../common/BuildConfig';
import { ActorsTab } from '../ext/actors/ActorsTab';
import { FacetsTab } from '../ext/facets/FacetsTab';

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
  @State actorsRefresh: number = 0;
  @State facetsRefresh: number = 0;
  /**
   * 主题版本号（2.5.2）：设置页换色时 +1。
   *
   * `Theme.ACCENT` 是静态字段，子组件不会因为它变了就重绘（颜色都是 build 时读走的）。
   * 所以这里靠「if/else 换分支」把整棵 Tab 树销毁重建一次 —— 换主题是一次性的低频操作，
   * 重建几十毫秒，比让 30 多个组件各自订阅状态要省心得多，也不会漏掉任何一处颜色。
   */
  @StorageProp('amaneThemeEpoch') themeEpoch: number = 0;
  private tabs: TabsController = new TabsController();
  // 「我的」永远固定在最后：扩展开关会把前面的 Tab 数量改掉，
  // 用写死的 index 判断会把「我的」和 extension Tab 混在一起。
  private readonly actorIndex: number = 3;
  private readonly facetIndex: number = BuildConfig.ENABLE_ACTORS ? 4 : 3;
  private readonly profileIndex: number = 3
    + (BuildConfig.ENABLE_ACTORS ? 1 : 0)
    + (BuildConfig.ENABLE_FACETS ? 1 : 0);

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      Store.I.init(context);
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] init: ${err.code} ${err.message}`);
    }
    // 主题色 / 列数要赶在第一次 build 之前生效；放在 try 外面，
    // 万一上面读偏好抛错，这里仍会按默认值把 AppStorage 铺好（不至于白屏）。
    Personalize.init();
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
      // 连接就绪后静默回传上次的崩溃栈；失败会保留本地文件，不影响启动
      const ctx = getContext(this) as common.UIAbilityContext;
      uploadCrashLog(ctx).catch(() => {});
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
    this.actorsRefresh++;
    this.facetsRefresh++;
  }

  onPageShow(): void {
    // 从播放页 / 详情页返回：首页的「继续观看」和收藏状态可能变了
    if (!this.booting && this.failMsg.length === 0) {
      this.homeRefresh++;
      this.favRefresh++;
      // 详情页把本地文件夹删了：媒体库 / 搜索里那张卡要跟着消失
      if (Store.I.itemRemoved) {
        Store.I.itemRemoved = false;
        this.libRefresh++;
      }
      // 改过元数据 / 换过封面：媒体库与标签列表都得重拉，否则还是旧图旧名
      if (Store.I.coverDirty) {
        Store.I.coverDirty = false;
        this.libRefresh++;
        this.facetsRefresh++;
      }
      // 分类页里改了收藏 / 隐藏才重拉标签列表：无条件重拉会把滚动位置也一起清掉
      if (Store.I.facetDirty) {
        Store.I.facetDirty = false;
        this.facetsRefresh++;
      }
    }
  }

  @Builder
  TabBarItem(index: number, label: string, icon: Resource) {
    Column() {
      // 选中项做成一块玻璃胶囊：半透明白底 + 0.5 高光描边，压在毛玻璃底栏上
      Column({ space: 3 }) {
        Image(icon)
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
          // 未选中也要看得清：原来用 TEXT_FAINT(#6C6C78) 在深底上几乎糊成一团，
          // 提到接近白的灰（选中才用紫色）
          .fillColor(this.currentTab === index ? Theme.ACCENT : Theme.TAB_IDLE)
        Text(label)
          .fontSize(9)
          .fontColor(this.currentTab === index ? Theme.TEXT : Theme.TAB_IDLE)
      }
      .width(56)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      // 选中胶囊也吃主题色（以前是纯白 15%）：整条底栏跟着换，视觉上才像一个整体
      .backgroundColor(this.currentTab === index ? Theme.accentAlpha(0.18) : '#00FFFFFF')
      .border({
        width: this.currentTab === index ? 0.5 : 0,
        color: Theme.accentAlpha(0.32)
      })
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 整棵 Tab 树。单独抽成 Builder 是为了换主题时能一口气重建：
   * `build()` 里用 `themeEpoch` 的奇偶切换 if/else 分支，分支一换子树就销毁重建，
   * 静态读走的 `Theme.ACCENT` 才会全部按新颜色重新画。
   */
  @Builder
  TabsRoot() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabs, index: this.currentTab }) {
      TabContent() {
        HomeTab({ refreshKey: this.homeRefresh })
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home')))
      .backgroundColor(Theme.BG)

      TabContent() {
        LibraryTab({ refreshKey: this.libRefresh })
      }
      .tabBar(this.TabBarItem(1, '媒体库', $r('app.media.ic_tab_lib')))
      .backgroundColor(Theme.BG)

      TabContent() {
        FavoritesTab({ refreshKey: this.favRefresh })
      }
      .tabBar(this.TabBarItem(2, '收藏', $r('app.media.ic_tab_fav')))
      .backgroundColor(Theme.BG)

      // 公开扩展 actors：演员网格。关掉 ENABLE_ACTORS 时后面的 Tab index 会自动前移
      if (BuildConfig.ENABLE_ACTORS) {
        TabContent() {
          ActorsTab({ refreshKey: this.actorsRefresh })
        }
        .tabBar(this.TabBarItem(this.actorIndex, '演员', $r('app.media.ic_tab_actor')))
        .backgroundColor(Theme.BG)
      }

      // 公开扩展 facets：标签 / 系列 / 制片商 分类浏览
      if (BuildConfig.ENABLE_FACETS) {
        TabContent() {
          FacetsTab({ refreshKey: this.facetsRefresh })
        }
        .tabBar(this.TabBarItem(this.facetIndex, '标签', $r('app.media.ic_tab_tag')))
        .backgroundColor(Theme.BG)
      }

      TabContent() {
        ProfileTab({ refreshKey: this.homeRefresh })
      }
      .tabBar(this.TabBarItem(this.profileIndex, '我的', $r('app.media.ic_tab_me')))
      .backgroundColor(Theme.BG)
    }
    // 悬浮玻璃功能栏：内容从栏下穿过，材质交给系统沉浸光感（TabBar 是官方
    // 明确支持 systemMaterial 的位置），带圆角胶囊、随系统深浅色/算力自适应。
    .barHeight(58)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 12,
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: '#2E000000'
      })
    })
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
      } else if (index === this.actorIndex) {
        this.actorsRefresh++;
      } else if (index === this.facetIndex) {
        this.facetsRefresh++;
      }
    })
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
      } else if (this.themeEpoch % 2 === 0) {
        // 换主题后走到 else 分支：子树整体重建，颜色才会全部换成新的
        this.TabsRoot()
      } else {
        this.TabsRoot()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
