import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { Personalize } from '../../common/Personalize';
import { DetailParams, MediaItem } from '../../common/Types';
import { posterItem } from '../../common/Util';
import { ChipOption, MYRATING_OPTIONS, SortOption, sortDefOf } from '../../common/BrowseOptions';
import { PosterCard } from '../../view/PosterCard';
import { KeywordBox } from '../../view/KeywordBox';
import { BottomSheet, ChipGroup, ChipRow, ListToolbar, SortSheet } from '../../view/ListSheets';
import { collectionChipOptions } from '../collections/CollectionTypes';
import { BuildConfig } from '../../common/BuildConfig';
import {
  ActorParams, CastFindItem, CastFindList, CoActorItem, CoActorList,
  safeCastFindList, safeCoActors
} from './ActorTypes';
import { FacetItem, FacetList, safeFacetList } from '../facets/FacetTypes';

const PAGE: number = 24;

const SUB_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '1', label: '只看有字幕' }
];

const CO_GENDERS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: 'female', label: '女' },
  { key: 'male', label: '男' }
];

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
 *
 * 2.4.6.26 起版式与媒体库统一：搜索框 + 一行工具条（部数 / ⇅ 排序 / ⚙ 筛选），
 * 标签、合作演员、人数、画质、字幕、评分、清单全部收进底部抽屉。合作演员候选
 * 带头像、可按男女收窄（服务端 `/actors/{id}/co-actors?gender=`）。
 */
@Entry
@Component
struct ActorWorksPage {
  /** 海报列数：设置页与双指捏合共用同一个值（2.5.2）。 */
  @StorageProp('amaneCols') posterCols: number = 3;
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
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  /** 我的评分 / 收藏夹：走服务端 cast_find 的同名参数（与媒体库同口径）。 */
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State collectionOptions: ChipOption[] = [];
  @State picking: string = '';
  @State query: string = '';
  /** 这一页自己的关键词（搜 TA 的作品，不跳全库搜索页）。 */
  @State keyword: string = '';
  /** 合作演员候选只看女 / 只看男 / 全部。 */
  @State coGender: string = 'female';
  @State tagHits: FacetItem[] = [];
  @State coHits: CoActorItem[] = [];
  private actorId: number = 0;
  private actorName: string = '';
  private sorts: SortOption[] = [
    { key: 'release', label: '发行日期', def: 'desc' },
    { key: 'score', label: '评分', def: 'desc' },
    { key: 'number', label: '番号', def: 'asc' },
    { key: 'updated_at', label: '更新时间', def: 'desc' },
    { key: 'myrating', label: '我的评分', def: 'desc' },
    { key: 'random', label: '随机', def: 'desc' }
  ];
  private mosaics: ChipOption[] = [
    { key: '', label: '不限' },
    { key: 'uncensored', label: '无码' },
    { key: 'cracked', label: '破解' },
    { key: 'leaked', label: '流出' }
  ];
  private females: ChipOption[] = [
    { key: '', label: '不限' },
    { key: 'min2', label: '≥2 女' },
    { key: 'min3', label: '≥3 女' },
    { key: 'min5', label: '≥5 女' },
    { key: 'eq2', label: '恰好 2 女' }
  ];
  private males: ChipOption[] = [
    { key: '', label: '不限' },
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
    this.loadCollections();
    this.reload();
  }

  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    this.collectionOptions = await collectionChipOptions();
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
    if (this.fMyRating.length > 0) {
      parts.push(`myrating=${this.fMyRating}`);
    }
    if (this.fCollection.length > 0) {
      parts.push(`collection=${this.fCollection}`);
    }
    if (this.keyword.length > 0) {
      parts.push(`search=${encodeURIComponent(this.keyword)}`);
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
    if (this.fMyRating.length > 0) {
      n++;
    }
    if (this.fCollection.length > 0) {
      n++;
    }
    return n;
  }

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortBy) {
        return this.sorts[i].label;
      }
    }
    return '发行日期';
  }

  private resetFilters(): void {
    this.tagId = 0;
    this.tagName = '';
    this.coId = 0;
    this.coName = '';
    this.subOnly = false;
    this.mosaic = '';
    this.female = '';
    this.male = '';
    this.fMyRating = '';
    this.fCollection = '';
    this.reload();
  }

  /** 抽屉里「标签 / 合作演员」这种二级候选：点开才展开搜索与候选。 */
  private openPick(kind: string): void {
    this.picking = this.picking === kind ? '' : kind;
    this.query = '';
    this.tagHits = [];
    this.coHits = [];
    if (this.picking.length > 0) {
      this.doPick('');
    }
  }

  private async doPick(kw: string): Promise<void> {
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
      // 合作演员候选走扩展自己的聚合接口：一次带出「与本人共演几部」+ 头像 + 性别，
      // 不用先拉一堆演员卡再逐个算（3 万行演员表上那是 24 次查询）。
      try {
        let url: string = `${Store.I.user}/api/user/actors/${this.actorId}/co-actors` +
          `?search=${encodeURIComponent(kw)}&limit=36`;
        if (this.coGender.length > 0) {
          url += `&gender=${this.coGender}`;
        }
        const text: string = await httpGet(url, Store.I.token);
        this.coHits = safeCoActors(JSON.parse(text) as CoActorList);
      } catch (err) {
        const e = err as BusinessError;
        console.error(`[amane] co-actor pick: ${e.code} ${e.message}`);
        this.coHits = [];
      }
    }
  }

  private cardOf(x: CastFindItem): MediaItem {
    return posterItem(x.id, x.number, x.title, x.release, x.poster, x.score, x.marks,
      x.my_rating === undefined ? 0 : x.my_rating);
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
        Text(this.filterCount() > 0 ? `${this.total} 部 · 已筛 ${this.filterCount()} 项` : `${this.total} 部`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 4 })
  }

  /** 合作演员候选：有头像的给头像圈（女演员没头像也给占位圈，位置不跳），
   *  男演员没头像就只留名字 —— 男优头像库里本来就少，留空圈反而更乱。 */
  @Builder
  CoActorChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.coHits, (a: CoActorItem) => {
        Row({ space: 6 }) {
          if (a.avatar.length > 0) {
            Image(Store.I.img(a.avatar))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
              .backgroundColor(Theme.CARD)
          } else if (a.gender !== 'male') {
            Column() {
              Text(a.name.length > 0 ? a.name.substring(0, 1) : '?')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width(24)
            .height(24)
            .justifyContent(FlexAlign.Center)
            .borderRadius(12)
            .backgroundColor(Theme.CARD)
          }
          Text(a.name)
            .fontSize(11)
            .fontColor(this.coId === a.id ? '#FFFFFF' : Theme.TEXT_DIM)
            .maxLines(1)
          Text(`${a.shared}`)
            .fontSize(10)
            .fontColor(this.coId === a.id ? '#FFFFFF' : Theme.TEXT_FAINT)
        }
        .padding({ left: 4, right: 10, top: 3, bottom: 3 })
        .backgroundColor(this.coId === a.id ? Theme.ACCENT : Theme.CARD_HI)
        .borderRadius(14)
        .margin({ right: 7, bottom: 7 })
        .onClick(() => {
          this.coId = this.coId === a.id ? 0 : a.id;
          this.coName = this.coId > 0 ? a.name : '';
          this.reload();
        })
      }, (a: CoActorItem) => `pick-a-${a.id}-${a.shared}-${a.avatar.length > 0 ? 1 : 0}`)
    }
    .width('100%')
  }

  /** 二级候选面板（抽屉里）：标签 / 合作演员共用，只是候选内容与性别条不同。 */
  @Builder
  PickerPanel() {
    Column({ space: 8 }) {
      if (this.picking === 'tag') {
        KeywordBox({
          placeholder: '搜索标签',
          onCommit: (kw: string) => {
            this.query = kw.trim();
            this.doPick(this.query);
          }
        })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tagHits, (t: FacetItem) => {
            Text(`${t.name} · ${t.count}`)
              .fontSize(11)
              .fontColor(this.tagId === t.id ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .backgroundColor(this.tagId === t.id ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(11)
              .margin({ right: 6, bottom: 6 })
              .maxLines(1)
              .onClick(() => {
                this.tagId = this.tagId === t.id ? 0 : t.id;
                this.tagName = this.tagId > 0 ? t.name : '';
                this.picking = '';
                this.reload();
              })
          }, (t: FacetItem) => `pick-tag-${t.id}`)
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Text('性别')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
          ChipRow({
            options: CO_GENDERS,
            current: this.coGender,
            onPick: (key: string) => {
              this.coGender = key;
              this.doPick(this.query);
            }
          })
          Blank()
        }
        .width('100%')

        KeywordBox({
          placeholder: '搜索演员名',
          onCommit: (kw: string) => {
            this.query = kw.trim();
            this.doPick(this.query);
          }
        })

        this.CoActorChips()

        Text('数字 = 与本人共演过几部；点一下筛，再点一下取消')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: '筛选',
      actionLabel: '重置',
      onAction: () => {
        this.resetFilters();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      sheetHeight: '86%'
    }) {
      // 标签 / 合作演员：入口一行，展开后才是候选
      Row({ space: 8 }) {
        Text(this.tagId > 0 ? `标签 · ${this.tagName}` : '标签')
          .fontSize(11)
          .fontColor(this.tagId > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 150 })
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .backgroundColor(this.tagId > 0 ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.openPick('tag');
          })
        Text(this.coId > 0 ? `共演 · ${this.coName}` : '合作演员')
          .fontSize(11)
          .fontColor(this.coId > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 150 })
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .backgroundColor(this.coId > 0 ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.openPick('actor');
          })
        Blank()
      }
      .width('100%')

      if (this.picking.length > 0) {
        this.PickerPanel()
      }

      ChipGroup({
        title: '画质 / 片源', options: this.mosaics, current: this.mosaic,
        onPick: (key: string) => {
          this.mosaic = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '字幕', options: SUB_OPTIONS, current: this.subOnly ? '1' : '',
        onPick: (key: string) => {
          this.subOnly = key === '1';
          this.reload();
        }
      })
      // 人数条件：这是上游做不到、只有本项目能筛的维度
      ChipGroup({
        title: '女演员人数', options: this.females, current: this.female,
        onPick: (key: string) => {
          this.female = key;
          this.reload();
        }
      })
      ChipGroup({
        title: '男演员人数', options: this.males, current: this.male,
        onPick: (key: string) => {
          this.male = key;
          this.reload();
        }
      })
      if (BuildConfig.ENABLE_RATINGS) {
        ChipGroup({
          title: '我的评分', options: MYRATING_OPTIONS, current: this.fMyRating,
          onPick: (key: string) => {
            this.fMyRating = key;
            this.reload();
          }
        })
      }
      if (BuildConfig.ENABLE_COLLECTIONS && this.collectionOptions.length > 0) {
        ChipGroup({
          title: '收藏夹', options: this.collectionOptions, current: this.fCollection,
          onPick: (key: string) => {
            this.fCollection = key;
            this.reload();
          }
        })
      }
      Blank().height(20)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Header()

        Row() {
          KeywordBox({
            placeholder: '在 TA 的作品里搜番号 / 标题',
            onCommit: (kw: string) => {
              const next: string = kw.trim();
              if (next === this.keyword) {
                return;
              }
              this.keyword = next;
              this.reload();
            }
          })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 4 })

        ListToolbar({
          label: this.keyword.length > 0 ? `「${this.keyword}」${this.total} 部` : `${this.total} 部`,
          sortLabel: `${this.sortLabel()}${this.sortBy === 'random' ? '' : (this.order === 'asc' ? ' ↑' : ' ↓')}`,
          filterCount: this.filterCount(),
          showFilter: true,
          onSort: () => {
            this.showSort = true;
          },
          onFilter: () => {
            this.showFilter = true;
          }
        })

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
        } else if (this.works.length === 0) {
          Column({ space: 10 }) {
            Text('▤')
              .fontSize(32)
              .fontColor(Theme.TEXT_FAINT)
            Text(this.filterCount() > 0 ? '没有符合筛选条件的作品' : '暂无作品')
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
                  this.resetFilters();
                })
            }
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
          .columnsTemplate(Personalize.colsTemplate(this.posterCols))
          .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
            Personalize.zoom(event.scale);
          }))
          .columnsGap(8)
          .rowsGap(14)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
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

      if (this.showSort || this.showFilter) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .onClick(() => {
            this.showSort = false;
            this.showFilter = false;
          })

        if (this.showSort) {
          SortSheet({
            options: this.sorts,
            current: this.sortBy,
            order: this.order,
            tabInset: 0,
            onPick: (key: string) => {
              // 随机再点一次 = 重摇一批（服务端每次回不同窗口）；其余项只是切换
              if (this.sortBy !== key) {
                this.sortBy = key;
                this.order = sortDefOf(key);
              }
              this.reload();
              this.showSort = false;
            },
            onToggleOrder: () => {
              this.order = this.order === 'asc' ? 'desc' : 'asc';
              this.reload();
            },
            onClose: () => {
              this.showSort = false;
            }
          })
        }
        if (this.showFilter) {
          this.FilterSheet()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
