import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams } from '../../common/Types';
import { StillsWall } from '../../view/StillsWall';
import { LikedStill, LikedStillPage, likedTotal, safeLikedStills } from './GachaTypes';

/**
 * 「喜爱的剧照」内容区（不含标题栏与返回键）。
 *
 * 2.4.5.10 起收藏页用它替换原来的独立页面：收藏页顶部切成「剧照」标签就是这一块，
 * 所以这里只管数据 + 瀑布流，滚动交给外层页面。
 *
 * 瀑布流用 view/StillsWall：宽高比在喜欢那一刻就存下来了，首帧就是最终版式。
 * 点图**进那部影片的详情页**（这是收藏页里「点剧照」的语义：先看是哪部片），
 * 点心形就地取消。
 */
@Component
export struct LikedStillsView {
  /** 外层刷新信号（切回收藏页 / 从详情页回来时递增），变了就重新拉。 */
  @Prop @Watch('onRefresh') refreshKey: number = 0;

  @State items: LikedStill[] = [];
  @State urls: string[] = [];
  @State ratios: number[] = [];
  /** 全部为 true（这一块里的每一张都是已喜欢的），只为让心形实心。 */
  @State flags: boolean[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/stills/liked?limit=200&order=random`, Store.I.token);
      const raw: LikedStillPage = JSON.parse(text) as LikedStillPage;
      this.items = safeLikedStills(raw);
      this.total = likedTotal(raw, this.items.length);
      this.note = '';
      this.relayout();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] liked stills: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端还没有这个功能（需 1.3.25+）' : '读取失败，请检查连接';
    }
    this.loading = false;
  }

  /** 把 items 摊成瀑布流要的三个平行数组。 */
  private relayout(): void {
    const urls: string[] = [];
    const ratios: number[] = [];
    const flags: boolean[] = [];
    for (let i = 0; i < this.items.length; i++) {
      urls.push(this.items[i].url);
      ratios.push(this.items[i].ratio);
      flags.push(true);
    }
    this.urls = urls;
    this.ratios = ratios;
    this.flags = flags;
  }

  /** 点图：进这张剧照所属影片的详情页（收藏页的点击语义，不是看大图）。 */
  private open(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    const p: DetailParams = { id: this.items[index].id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  /** 点心形 = 取消喜爱：先本地移除（立刻有反馈），失败再放回去。 */
  private async unlike(index: number): Promise<void> {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    const target: LikedStill = this.items[index];
    const before: LikedStill[] = this.items;
    const rest: LikedStill[] = [];
    for (let i = 0; i < before.length; i++) {
      if (i !== index) {
        rest.push(before[i]);
      }
    }
    this.items = rest;
    this.total = Math.max(0, this.total - 1);
    this.relayout();
    try {
      await httpPost(`${Store.I.user}/api/user/stills/like`, Store.I.token,
        JSON.stringify({ id: target.id, url: target.url, liked: false }));
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] unlike still: ${e.code} ${e.message}`);
      this.items = before;
      this.total = this.total + 1;
      this.relayout();
      this.note = '取消失败，请检查连接';
      setTimeout(() => {
        this.note = '';
      }, 2000);
    }
  }

  build() {
    Column({ space: 10 }) {
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .height(180)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('♥')
            .fontSize(30)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.note.length > 0 ? this.note : '还没有喜爱的剧照')
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .textAlign(TextAlign.Center)
          if (this.note.length === 0) {
            Text('在影片详情页的剧照上点右上角的 ♡，喜欢过的场景都会集中到这里。')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
        }
        .width('100%')
        .height(260)
        .justifyContent(FlexAlign.Center)
      } else {
        StillsWall({
          urls: this.urls,
          ratios: this.ratios,
          showLike: true,
          liked: this.flags,
          onLike: (index: number) => {
            this.unlike(index);
          },
          onPick: (index: number) => {
            this.open(index);
          }
        })
        Text(`${this.total} 张 · 点图进影片 · 点右上角 ♥ 取消喜爱`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
  }
}
