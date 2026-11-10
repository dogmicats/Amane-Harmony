import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams, MediaItem } from '../../common/Types';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import {
  ActorItem, ActorList, ActorParams, CastFindItem, CastFindList, safeActorList, safeCastFindList
} from './ActorTypes';
import { FacetItem, FacetList, safeFacetList } from '../facets/FacetTypes';

const PAGE: number = 24;

interface Choice {
  key: string;
  label: string;
}

@Component
struct MiniChips {
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
      }, (opt: Choice) => `mc-${opt.key}`)
    }
  }
}

/** 「min2 / eq2」→ [min, max]。 */
function band(key: string): number[] {
  const out: number[] = [0, 99];
  if (key.length < 3) {
    return out;
  }
  // 'eq2' → '2'；'min2' → '2'。
  // 不能统一 substring(2)：min 是三个字母，'min2'.substring(2) === 'n2' → NaN，
  // 函数会提前返回 [0,99]，等于没传条件 —— 这正是「≥ 结果等于全部影片」的原因。
  const n: number = Number(key.startsWith('eq') ? key.substring(2) : key.substring(3));
  if (!isFinite(n)) {
    return out;
  }
  if (key.startsWith('eq')) {
    out[0] = n;
    out[1] = n;
  } else {
    out[0] = n;
  }
  return out;
}

/**
 * 公开扩展 actors：某个演员的作品子界面（从演员详情页进来）。
 *
 * 数据源统一成 `/api/user/cast/find`：它一次返回封面/番号/评分/阵容统计，
 * 既能做「和谁共演」，也能做「这部片里有几个女演员」——上游的
 * `/api/metadata?actor_id=` 只能做「谁参演」，答不了人数。
 * 卡片复用媒体库的 PosterCard，视觉与影片库一致。
 */
@Entry
@Component
struct ActorWorksPage {
  @State works: CastFindItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State sortBy: string = 'release';
  @State order: string = 'desc';
  @State tagId: number = 0;
  @State tagName: string = '';
  @State coId: number = 0;
  @State coName: string = '';
  @State subOnly: boolean = false;
  @State mosaic: string = '';
  @State female: string = '';
  @State male: string = '';
  @State showFilter: boolean = false;
  @State picking: string = '';
  @State query: string = '';
  @State tagHits: FacetItem[] = [];
  @State actorHits: ActorItem[] = [];
  private actorId: number = 0;
  private actorName: string = '';
  private searchTimer: number = -1;
  private sorts: Choice[] = [
    { key: 'release', label: '发行日期' },
    { key: 'score', label: '评分' },
    { key: 'number', label: '番号' },
    { key: 'updated_at', label: '更新' },
    { key: 'random', label: '随机' }
  ];
  private mosaics: Choice[] = [
    { key: '', label: '不限' },
    { key: 'uncensored', label: '无码' },
    { key: 'cracked', label: '破解' },
    { key: 'leaked', label: '流出' }
  ];
  private females: Choice[] = [
    { key: '', label: '女演员不限' },
    { key: 'min2', label: '≥2 女' },
    { key: 'min3', label: '≥3 女' },
    { key: 'min5', label: '≥5 女' },
    { key: 'eq2', label: '恰好 2 女' }
  ];
  private males: Choice[] = [
    { key: '', label: '男演员不限' },
    { key: 'eq0', label: '0 男' },
    { key: 'min1', label: '≥1 男' },
    { key: 'min2', label: '≥2 男' }
  ];

  aboutToAppear(): void {
    const p = router.getParams() as ActorParams;
    if (p !== undefined && p !== null) {
      this.actorId = Number(p.id);
      this.actorName = p.name === undefined || p.name === null ? '' : p.name;
    }
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${PAGE}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`
    ];
    // 本人 + 可选合作演员：多值 actor_id 在服务端是 AND
    const ids: string[] = [`${this.actorId}`];
    if (this.coId > 0) {
      ids.push(`${this.coId}`);
    }
    parts.push(`actor_id=${ids.join(',')}`);
    if (this.tagId > 0) {
      parts.push(`tag_id=${this.tagId}`);
    }
    if (this.subOnly) {
      parts.push('has_subtitle=true');
    }
    if (this.mosaic.length > 0) {
      parts.push(`mosaic=${this.mosaic}`);
    }
    const f: number[] = band(this.female);
    if (f[0] > 0 || f[1] < 99) {
      parts.push(`female_min=${f[0]}`);
      parts.push(`female_max=${f[1]}`);
    }
    const m: number[] = band(this.male);
    if (m[0] > 0 || m[1] < 99) {
      parts.push(`male_min=${m[0]}`);
      parts.push(`male_max=${m[1]}`);
    }
    return `${Store.I.user}/api/user/cast/find?${parts.join('&')}`;
  }

  private reload(): void {
    this.works = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      const text: string = await httpGet(this.buildUrl(offset), Store.I.token);
      const r: CastFindList = safeCastFindList(JSON.parse(text) as CastFindList);
      this.works = append ? this.works.concat(r.items) : r.items;
      this.total = r.total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actor works: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404 ? '服务端未启用演员扩展' : '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.works.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.load(this.works.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private filterCount(): number {
    let n: number = 0;
    if (this.tagId > 0) {
      n++;
    }
    if (this.coId > 0) {
      n++;
    }
    if (this.subOnly) {
      n++;
    }
    if (this.mosaic.length > 0) {
      n++;
    }
    if (this.female.length > 0) {
      n++;
    }
    if (this.male.length > 0) {
      n++;
    }
    return n;
  }

  private onQuery(value: string): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const q: string = value;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.query = q;
      this.doPick();
    }, 320);
  }

  private async doPick(): Promise<void> {
    const kw: string = this.query.trim();
    if (this.picking === 'tag') {
      try {
        const text: string = await httpGet(
          `${Store.I.user}/api/user/facets/tag?search=${encodeURIComponent(kw)}&limit=24&sort_by=count&order=desc`,
          Store.I.token);
        this.tagHits = safeFacetList(JSON.parse(text) as FacetList).items;
      } catch (err) {
        const e = err as BusinessError;
        console.error(`[amane] tag pick: ${e.code} ${e.message}`);
      }
    } else if (this.picking === 'actor') {
      try {
        const text: string = await httpGet(
          `${Store.I.user}/api/user/actors?search=${encodeURIComponent(kw)}&limit=24&has_image=false&sort_by=count&order=desc`,
          Store.I.token);
        const list: ActorList = safeActorList(JSON.parse(text) as ActorList);
        const hits: ActorItem[] = [];
        for (let i = 0; i < list.items.length; i++) {
          if (list.items[i].id !== this.actorId) {
            hits.push(list.items[i]);
          }
        }
        this.actorHits = hits;
      } catch (err) {
        const e = err as BusinessError;
        console.error(`[amane] co-actor pick: ${e.code} ${e.message}`);
      }
    }
  }

  private openPick(kind: string): void {
    this.picking = this.picking === kind ? '' : kind;
    this.query = '';
    this.tagHits = [];
    this.actorHits = [];
    if (this.picking.length > 0) {
      this.doPick();
    }
  }

  private cardOf(x: CastFindItem): MediaItem {
    return posterItem(x.id, x.number, x.title, x.release, x.poster, x.score, x.marks);
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(24)
        .fontColor(Theme.TEXT)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      Column({ space: 3 }) {
        Text(`${this.actorName} · 作品筛选`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.total} 部` + (this.filterCount() > 0 ? ` · 已筛 ${this.filterCount()} 项` : ''))
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 6 })
  }

  @Builder
  PickerPanel() {
    Column({ space: 8 }) {
      Text(this.picking === 'tag' ? '按标签收窄' : '按合作演员收窄（与本人共演）')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      TextInput({ placeholder: this.picking === 'tag' ? '搜索标签' : '搜索演员名', text: this.query })
        .height(34)
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 11 })
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .width('100%')
        .onChange((v: string) => {
          this.onQuery(v);
        })

      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.picking === 'tag') {
          ForEach(this.tagHits, (t: FacetItem) => {
            Text(`${t.name} · ${t.count}`)
              .fontSize(11)
              .fontColor(this.tagId === t.id ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(this.tagId === t.id ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(10)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.tagId = this.tagId === t.id ? 0 : t.id;
                this.tagName = this.tagId > 0 ? t.name : '';
                this.picking = '';
                this.reload();
              })
          }, (t: FacetItem) => `pick-tag-${t.id}`)
        } else {
          ForEach(this.actorHits, (a: ActorItem) => {
            Text(a.name)
              .fontSize(11)
              .fontColor(this.coId === a.id ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(this.coId === a.id ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(10)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.coId = this.coId === a.id ? 0 : a.id;
                this.coName = this.coId > 0 ? a.name : '';
                this.picking = '';
                this.reload();
              })
          }, (a: ActorItem) => `pick-a-${a.id}`)
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  Toolbar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Scroll() {
          MiniChips({
            options: this.sorts,
            current: this.sortBy,
            onPick: (key: string) => {
              if (this.sortBy === key) {
                if (key !== 'random') {
                  this.order = this.order === 'desc' ? 'asc' : 'desc';
                }
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
          .visibility(this.sortBy === 'random' ? Visibility.None : Visibility.Visible)
          .onClick(() => {
            this.order = this.order === 'desc' ? 'asc' : 'desc';
            this.reload();
          })
      }
      .width('100%')

      Row({ space: 7 }) {
        Text(this.tagId > 0 ? `标签·${this.tagName}` : '标签')
          .fontSize(11)
          .fontColor(this.tagId > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 110 })
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.tagId > 0 ? Theme.ACCENT : Theme.CARD)
          .borderRadius(11)
          .onClick(() => {
            this.openPick('tag');
          })
        Text(this.coId > 0 ? `共演·${this.coName}` : '合作演员')
          .fontSize(11)
          .fontColor(this.coId > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 110 })
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.coId > 0 ? Theme.ACCENT : Theme.CARD)
          .borderRadius(11)
          .onClick(() => {
            this.openPick('actor');
          })
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
        Blank()
        Text(this.filterCount() > 0 ? `重置 ${this.filterCount()}` : '重置')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick(() => {
            this.tagId = 0;
            this.tagName = '';
            this.coId = 0;
            this.coName = '';
            this.subOnly = false;
            this.mosaic = '';
            this.female = '';
            this.male = '';
            this.reload();
          })
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('画质')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        MiniChips({
          options: this.mosaics,
          current: this.mosaic,
          onPick: (key: string) => {
            this.mosaic = key;
            this.reload();
          }
        })
      }
      .width('100%')

      // 人数条件：这是上游做不到、只有本项目能筛的维度
      Scroll() {
        Row({ space: 7 }) {
          Text('人数')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
          MiniChips({
            options: this.females,
            current: this.female,
            onPick: (key: string) => {
              this.female = key;
              this.reload();
            }
          })
          MiniChips({
            options: this.males,
            current: this.male,
            onPick: (key: string) => {
              this.male = key;
              this.reload();
            }
          })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)

      if (this.picking.length > 0) {
        this.PickerPanel()
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
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
      } else {
        this.Toolbar()

        if (this.works.length === 0) {
          Column({ space: 10 }) {
            Text('▤')
              .fontSize(32)
              .fontColor(Theme.TEXT_FAINT)
            Text(this.filterCount() > 0 ? '没有符合筛选条件的作品' : '暂无作品')
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.works, (x: CastFindItem) => {
              GridItem() {
                PosterCard({
                  item: this.cardOf(x),
                  fluid: true,
                  onTap: () => {
                    const p: DetailParams = { id: x.id };
                    router.pushUrl({ url: 'pages/DetailPage', params: p });
                  }
                })
              }
            }, (x: CastFindItem) => `aw-${x.id}`)

            if (this.works.length < this.total) {
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
