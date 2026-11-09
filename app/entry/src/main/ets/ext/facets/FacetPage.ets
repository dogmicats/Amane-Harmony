import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams, MediaItem } from '../../common/Types';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import {
  FacetMediaItem, FacetMediaList, FacetParams, facetLabel, safeFacetMediaList
} from './FacetTypes';

const PAGE_SIZE: number = 30;

interface Choice {
  key: string;
  label: string;
}

@Component
struct SmallChips {
  options: Choice[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Row({ space: 7 }) {
      ForEach(this.options, (opt: Choice) => {
        Text(opt.label)
          .fontSize(11)
          .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
          .borderRadius(11)
          .onClick(() => {
            this.onPick(opt.key);
          })
      }, (opt: Choice) => `sc-${opt.key}`)
    }
  }
}

/**
 * 公开扩展 facets：某个分类（标签 / 系列 / 制片商 / 我的标签）下的影片墙。
 *
 * 这轮补上「筛选 + 排序」：排序支持发行时间 / 番号 / 评分 / 时长，
 * 筛选支持有字幕、无码/破解/流出、4K —— 和影片库同一套口径，全部下推给上游。
 * 系列页额外把前四张海报拼成四宫格放进标题栏，系列一眼能认出来
 * （详情页的系列卡用的是同一套四宫格视觉）。
 */
@Entry
@Component
struct FacetPage {
  @State items: FacetMediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State sortBy: string = 'release';
  @State order: string = 'desc';
  @State subOnly: boolean = false;
  @State mosaic: string = '';
  @State def: string = '';
  private kind: string = 'tag';
  private facetId: number = 0;
  private title: string = '';
  private sorts: Choice[] = [
    { key: 'release', label: '发行时间' },
    { key: 'number', label: '番号' },
    { key: 'score', label: '评分' },
    { key: 'runtime', label: '时长' }
  ];
  private mosaics: Choice[] = [
    { key: '', label: '不限' },
    { key: 'uncensored', label: '无码' },
    { key: 'cracked', label: '破解' },
    { key: 'leaked', label: '流出' }
  ];
  private defs: Choice[] = [
    { key: '', label: '不限' },
    { key: '4K', label: '4K' },
    { key: '1080p', label: '1080p' }
  ];

  aboutToAppear(): void {
    const p = router.getParams() as FacetParams;
    if (p !== undefined && p !== null) {
      this.kind = p.kind === undefined || p.kind === null ? 'tag' : p.kind;
      this.facetId = Number(p.id);
      this.title = p.name === undefined || p.name === null ? '' : p.name;
    }
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    if (this.facetId <= 0) {
      this.error = '分类不存在';
      this.loading = false;
      return;
    }
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${PAGE_SIZE}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`
    ];
    if (this.subOnly) {
      parts.push('has_subtitle=true');
    }
    if (this.mosaic.length > 0) {
      parts.push(`mosaic=${this.mosaic}`);
    }
    if (this.def.length > 0) {
      parts.push(`definition=${this.def}`);
    }
    const url: string = `${Store.I.user}/api/user/facets/${this.kind}/${this.facetId}/media?` + parts.join('&');
    try {
      const text: string = await httpGet(url, Store.I.token);
      const r: FacetMediaList = safeFacetMediaList(JSON.parse(text) as FacetMediaList);
      this.items = append ? this.items.concat(r.items) : r.items;
      this.total = r.total;
      this.error = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet media: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404 ? '服务端未启用分类扩展' : '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private reload(): void {
    this.items = [];
    this.total = 0;
    this.loading = true;
    this.load(0, false);
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.items.length >= this.total || this.total <= 0) {
      return;
    }
    this.loadingMore = true;
    this.load(this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private open(item: FacetMediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private posterAt(i: number): string {
    return i < this.items.length ? this.items[i].poster : '';
  }

  private filterCount(): number {
    let n: number = 0;
    if (this.subOnly) {
      n++;
    }
    if (this.mosaic.length > 0) {
      n++;
    }
    if (this.def.length > 0) {
      n++;
    }
    return n;
  }

  /** 系列页标题左侧的四宫格封面：直接拿当前页前四张海报拼，不再多发请求。 */
  @Builder
  Cover() {
    Stack() {
      if (this.items.length >= 2) {
        if (this.posterAt(0).length > 0) {
          Image(Store.I.img(this.posterAt(0)))
            .width(30).height(30).objectFit(ImageFit.TOP)
            .position({ x: 0, y: 0 }).backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(1).length > 0) {
          Image(Store.I.img(this.posterAt(1)))
            .width(30).height(30).objectFit(ImageFit.TOP)
            .position({ x: 32, y: 0 }).backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(2).length > 0) {
          Image(Store.I.img(this.posterAt(2)))
            .width(30).height(30).objectFit(ImageFit.TOP)
            .position({ x: 0, y: 32 }).backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(3).length > 0) {
          Image(Store.I.img(this.posterAt(3)))
            .width(30).height(30).objectFit(ImageFit.TOP)
            .position({ x: 32, y: 32 }).backgroundColor(Theme.CARD_HI)
        }
      } else if (this.posterAt(0).length > 0) {
        Image(Store.I.img(this.posterAt(0)))
          .width('100%').height('100%').objectFit(ImageFit.TOP)
          .backgroundColor(Theme.CARD_HI)
      }
    }
    .width(62)
    .height(62)
    .borderRadius(8)
    .clip(true)
    .backgroundColor(Theme.CARD_HI)
    .margin({ right: 10 })
  }

  @Builder
  Header() {
    Row() {
      Text('‹')
        .fontSize(24)
        .fontColor(Theme.TEXT)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      if (this.kind === 'series' && this.items.length > 0) {
        this.Cover()
      }
      Column({ space: 3 }) {
        Text(this.title.length > 0 ? this.title : facetLabel(this.kind))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${facetLabel(this.kind)} · ${this.total} 部`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Toolbar() {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Scroll() {
          SmallChips({
            options: this.sorts,
            current: this.sortBy,
            onPick: (key: string) => {
              if (this.sortBy === key) {
                this.order = this.order === 'desc' ? 'asc' : 'desc';
              } else {
                this.sortBy = key;
                this.order = key === 'number' ? 'asc' : 'desc';
              }
              this.reload();
            }
          })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Start)

        Text(this.order === 'desc' ? '↓' : '↑')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(30)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.order === 'desc' ? Theme.ACCENT : Theme.CARD_HI)
          .borderRadius(13)
          .onClick(() => {
            this.order = this.order === 'desc' ? 'asc' : 'desc';
            this.reload();
          })
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('有字幕')
          .fontSize(11)
          .fontColor(this.subOnly ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.subOnly ? Theme.ACCENT : Theme.CARD)
          .borderRadius(11)
          .onClick(() => {
            this.subOnly = !this.subOnly;
            this.reload();
          })
        SmallChips({
          options: this.mosaics,
          current: this.mosaic,
          onPick: (key: string) => {
            this.mosaic = key;
            this.reload();
          }
        })
        Blank()
        if (this.filterCount() > 0) {
          Text('重置')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .onClick(() => {
              this.subOnly = false;
              this.mosaic = '';
              this.def = '';
              this.reload();
            })
        }
      }
      .width('100%')

      Row({ space: 7 }) {
        SmallChips({
          options: this.defs,
          current: this.def,
          onPick: (key: string) => {
            this.def = key;
            this.reload();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
  }

  private cardOf(m: FacetMediaItem): MediaItem {
    return posterItem(m.id, m.number, m.title, m.release, m.poster, m.score, m.marks);
  }

  /** 与媒体库完全同一张卡：封面 + 评分角标 + 番号 + 标题。 */
  @Builder
  Cell(m: FacetMediaItem) {
    PosterCard({
      item: this.cardOf(m),
      fluid: true,
      onTap: () => {
        const p: DetailParams = { id: m.id };
        router.pushUrl({ url: 'pages/DetailPage', params: p });
      }
    })
  }

  build() {
    Column() {
      this.Header()

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 10 }) {
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.loading = true;
              this.load(0, false);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('▤')
            .fontSize(32)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.filterCount() > 0 ? '没有符合筛选条件的影片' : '这个分类下还没有影片')
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
          if (this.filterCount() > 0) {
            Text('重置筛选')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(14)
              .onClick(() => {
                this.subOnly = false;
                this.mosaic = '';
                this.def = '';
                this.reload();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.Toolbar()
        Grid() {
          ForEach(this.items, (m: FacetMediaItem) => {
            GridItem() {
              this.Cell(m)
            }
          }, (m: FacetMediaItem) => `fm-${m.id}`)

          if (this.items.length < this.total) {
            GridItem() {
              Column() {
                if (this.loadingMore) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(Theme.TEXT_FAINT)
                } else {
                  Text('加载更多')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
              }
              .width('100%')
              .height(120)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.loadMore();
              })
            }
          }
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(14)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 16 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
