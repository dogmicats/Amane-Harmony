import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams } from '../../common/Types';
import { FavoriteEntityView, FavEntity, FavBadge } from '../../view/FavoriteEntityView';
import {
  FacetItem, FacetList, FacetParams, facetLabel, safeFacetList
} from './FacetTypes';

/**
 * 「收藏的分类」——导演 / 标签 / 系列共用（收藏页的分段）。
 *
 * 分类收藏是 amane 自己的 `is_favorite` 列（`POST /facets/{kind}/{id}/favorite`），
 * 与影片收藏、演员收藏都是独立数据；列表直接带 `favorite=true` 问扩展要。
 *
 * 展示与演员收藏统一走 `view/FavoriteEntityView`：左边封面（最近作品海报）、
 * 中间名称 + 片数、右边一排可点海报（`posterItems` 带影片 id，点海报直接进影片）。
 */
@Component
export struct FavoriteFacetsView {
  /** director / tag / series */
  @Prop @Watch('onKindChange') kind: string = 'director';
  /** 外层刷新信号（切回收藏页时递增），变了就重新拉。 */
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** true = 3 列简版；false = 横版大行。 */
  @Prop grid: boolean = false;

  @State entities: FavEntity[] = [];
  @State loading: boolean = true;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onKindChange(): void {
    this.entities = [];
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.entities.length === 0;
    try {
      const url: string = `${Store.I.user}/api/user/facets/${this.kind}` +
        `?favorite=true&sort_by=count&order=desc&limit=200`;
      const text: string = await httpGet(url, Store.I.token);
      const raw: FacetList = JSON.parse(text) as FacetList;
      const list: FacetItem[] = safeFacetList(raw).items;
      const out: FavEntity[] = [];
      for (let i = 0; i < list.length; i++) {
        const f: FacetItem = list[i];
        let cover: string = '';
        if (f.posterItems.length > 0) {
          cover = f.posterItems[0].url;
        } else if (f.posters.length > 0) {
          cover = f.posters[0];
        }
        out.push({
          kind: this.kind,
          id: f.id,
          name: f.name,
          count: f.count,
          cover: cover,
          posters: f.posterItems,
          badges: this.facetBadges(f)
        });
      }
      this.entities = out;
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] favorite facets ${this.kind}: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端未启用分类扩展' : '读取失败，请检查连接';
    }
    this.loading = false;
  }

  /**
   * 横版行里的彩色胶囊。
   *
   * 系列有自己「从标签提炼出来的属性」（服务端按占比给前三个，隐藏标签已排除），
   * 优先展示它们；没有属性的分类退回发行 / 入库日期。
   */
  private facetBadges(f: FacetItem): FavBadge[] {
    const out: FavBadge[] = [];
    if (this.kind === 'series') {
      const colors: string[] = ['#FF8FB1', '#9C8CFF', '#7FE0B0'];
      for (let i = 0; i < f.topTags.length && i < 3; i++) {
        out.push({ text: f.topTags[i].name, color: colors[i] });
      }
    }
    if (out.length === 0) {
      if (f.lastRelease.length > 0) {
        out.push({ text: `发行 ${f.lastRelease}`, color: '#9C8CFF' });
      }
      if (f.lastAdded.length > 0) {
        out.push({ text: `入库 ${f.lastAdded}`, color: '#7FE0B0' });
      }
    }
    return out;
  }

  private open(e: FavEntity): void {
    const p: FacetParams = { kind: this.kind, id: e.id, name: e.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: p });
  }

  private openFilm(id: number): void {
    const p: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  /** 取消收藏：先本地移除，失败再放回。 */
  private async unfavorite(e: FavEntity): Promise<void> {
    const before: FavEntity[] = this.entities;
    const rest: FavEntity[] = [];
    for (let i = 0; i < before.length; i++) {
      if (before[i].id !== e.id) {
        rest.push(before[i]);
      }
    }
    this.entities = rest;
    try {
      await httpPost(`${Store.I.user}/api/user/facets/${this.kind}/${e.id}/favorite`,
        Store.I.token, JSON.stringify({ favorite: false }));
    } catch (err) {
      const ex = err as BusinessError;
      console.error(`[amane] unfavorite facet: ${ex.code} ${ex.message}`);
      this.entities = before;
      this.note = '取消失败，请检查连接';
      setTimeout(() => {
        this.note = '';
      }, 2000);
    }
  }

  build() {
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
    } else if (this.entities.length === 0) {
      Column({ space: 10 }) {
        Text('♥')
          .fontSize(30)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.note.length > 0 ? this.note : `还没有收藏的${facetLabel(this.kind)}`)
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
        if (this.note.length === 0) {
          Text(`在${facetLabel(this.kind)}页面点卡片上的小心心，收藏的会集中到这里。`)
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
      FavoriteEntityView({
        items: this.entities,
        grid: this.grid,
        onOpen: (e: FavEntity) => {
          this.open(e);
        },
        onFilm: (id: number) => {
          this.openFilm(id);
        },
        onUnfav: (e: FavEntity) => {
          this.unfavorite(e);
        }
      })
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    }
  }
}
