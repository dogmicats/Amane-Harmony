import { router } from '@kit.ArkUI';

/**
 * 已废弃（2.5.4.7）：这里原本是「我的 Tier 图 · 历史」列表页。
 *
 * 为什么留着：用户从「我的」进来时旧入口指的就是这一页，直接删文件会让老路由 404。
 * 现在它的历史、设为展示、删除都已经并进 `pages/TierPage`（那是唯一的主页面：
 * 上面是当前图、下面是历史、页顶是配置与「一键生成」），所以这里只做一次 replaceUrl。
 *
 * **不要再往这个文件里加界面**：加在这儿等于又分裂出第二个 Tier 页，
 * 上次的 bug 就是这么来的（入口指到列表页，用户在那一页里找不到生成和下载）。
 */
@Entry
@Component
struct TierManagePage {
  aboutToAppear(): void {
    router.replaceUrl({ url: 'pages/TierPage' });
  }

  build() {
    // replace 是同步开始的，这里只画一帧空白，避免闪一下列表骨架
    Column() {
    }
    .width('100%')
    .height('100%')
  }
}
