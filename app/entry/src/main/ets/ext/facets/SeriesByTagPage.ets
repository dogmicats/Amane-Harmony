import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';

/** 一个系列（by-tags 返回的最小集合）。 */
interface SeriesHit {
  id: number;
  name: string;
  count: number;
  poster: string;
}

/** 可选属性（来自热门标签）。 */
interface TagOpt {
  id: number;
  name: string;
}

interface HitList {
  items: SeriesHit[];
}

interface TagPage {
  items: TagOpt[];
}

/**
 * 按属性筛系列。
 *
 * 「含某属性的系列」= 系列里的片同时具备这些标签。服务端 `facets/series/by-tags`
 * 做 AND 聚合，这里只负责选标签与展示；属性候选用热门标签（系列属性本来就是标签）。
 *
 * 多选 = 同时具备（既有 NTR 又有搜查官那类组合也能筛）。
 */
@Entry
@Component
struct SeriesByTagPage {
  @State opts: TagOpt[] = [];
  @State picked: number[] = [];
  @State items: SeriesHit[] = [];
  @State loading: boolean = true;
  @State note: string = '';
  /** 属性搜索：标签上千个，只给前 16 个热门根本不够用。 */
  @State kw: string = '';

  aboutToAppear(): void {
    this.loadOpts();
  }

  private async loadOpts(): Promise<void> {
    try {
      const url: string = Store.I.user + '/api/user/facets/tag?sort_by=count&order=desc&limit=200';
      const text: string = await httpGet(url, Store.I.token);
      const data = JSON.parse(text) as TagPage;
      const src: TagOpt[] = data.items === undefined || data.items === null ? [] : data.items;
      const out: TagOpt[] = [];
      for (let i = 0; i < src.length; i++) {
        out.push({ id: Number(src[i].id), name: String(src[i].name) });
      }
      this.opts = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error('[amane] tag opts: ' + e.message);
    }
    this.loading = false;
  }

  /** 关键字过滤（不区分大小写），空 = 全量。 */
  private filtered(): TagOpt[] {
    const k: string = this.kw.trim().toLowerCase();
    if (k.length === 0) {
      return this.opts;
    }
    const out: TagOpt[] = [];
    for (let i = 0; i < this.opts.length; i++) {
      if (this.opts[i].name.toLowerCase().indexOf(k) >= 0) {
        out.push(this.opts[i]);
      }
    }
    return out;
  }

  private async search(): Promise<void> {
    if (this.picked.length === 0) {
      this.items = [];
      this.note = '选一个或几个属性看看';
      return;
    }
    this.note = '筛选中…';
    try {
      const url: string = Store.I.user + '/api/user/facets/series/by-tags?tags=' +
        this.picked.join(',') + '&limit=60';
      const text: string = await httpGet(url, Store.I.token);
      const data = JSON.parse(text) as HitList;
      const src: SeriesHit[] = data.items === undefined || data.items === null ? [] : data.items;
      const out: SeriesHit[] = [];
      for (let i = 0; i < src.length; i++) {
        const s: SeriesHit = src[i];
        if (Number(s.id) > 0) {
          out.push({ id: Number(s.id), name: String(s.name),
            count: Number(s.count), poster: String(s.poster) });
        }
      }
      this.items = out;
      this.note = out.length === 0 ? '没有同时具备这些属性的系列' : `命中 ${out.length} 个系列`;
    } catch (err) {
      const e = err as BusinessError;
      console.error('[amane] series by tags: ' + e.message);
      this.note = '筛选失败';
    }
  }

  private toggle(id: number): void {
    const next: number[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === id) {
        removed = true;
      } else {
        next.push(this.picked[i]);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.picked = next;
    this.search();
  }

  private open(s: SeriesHit): void {
    const p: Record<string, Object> = { 'kind': 'series', 'id': s.id, 'name': s.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: p }).catch((e: BusinessError) => {
      console.error('[amane] push facet: ' + e.message);
    });
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
        Text('按属性筛系列')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        if (this.picked.length > 0) {
          Text('清空')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.picked = [];
              this.items = [];
              this.note = '';
            })
        }
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })

      // 属性多选
      // 属性多选：候选是全量标签（上限 200），先搜再选
      Row({ space: 8 }) {
        TextInput({ text: this.kw, placeholder: '搜标签，如 NTR / 搜查官' })
          .height(36)
          .fontSize(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onChange((v: string) => {
            this.kw = v;
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.filtered(), (o: TagOpt) => {
            Text(o.name)
              .fontSize(12)
              .fontColor(this.picked.indexOf(o.id) >= 0 ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.picked.indexOf(o.id) >= 0 ? Theme.ACCENT : Theme.CARD)
              .borderRadius(12)
              .margin({ right: 7, bottom: 7 })
              .onClick(() => {
                this.toggle(o.id);
              })
          }, (o: TagOpt) => 'opt-' + o.id)
        }
        .width('100%')
      }
      .height(126)
      .scrollBar(BarState.Off)
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      Text(this.note.length > 0 ? this.note : '多选 = 同时具备这些属性')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 6 })

      if (this.items.length === 0) {
        Column({ space: 8 }) {
          Text(this.loading ? '加载中…' : '还没有结果')
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (s: SeriesHit) => {
            ListItem() {
              Row({ space: 10 }) {
                Image(Store.I.img(s.poster))
                  .width(52)
                  .height(72)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor(Theme.CARD)
                  .borderRadius(8)
                  .alt($r('app.media.placeholder'))
                Column({ space: 4 }) {
                  Text(s.name)
                    .fontSize(13)
                    .fontColor(Theme.TEXT)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(s.count.toString() + ' 部')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('›')
                  .fontSize(18)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.CARD)
              .borderRadius(11)
              .onClick(() => {
                this.open(s);
              })
            }
          }, (s: SeriesHit) => 'sh-' + s.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
