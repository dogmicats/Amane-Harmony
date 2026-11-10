import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams, MediaItem } from '../../common/Types';
import { posterItem } from '../../common/Util';
import { PosterCard } from '../../view/PosterCard';
import { BuildConfig } from '../../common/BuildConfig';
import { GachaSwitch } from '../stills/GachaSwitch';
import { GachaWall } from '../stills/GachaWall';
import {
  FacetFavoriteResult, FacetItem, FacetMediaItem, FacetMediaList, FacetParams,
  emptyFacet, facetLabel, safeFacetMediaList
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
  /** 随机排序时服务端随机开的窗口起点：翻页要续接这个窗口，而不是从 0 重新数。 */
  @State baseOffset: number = 0;
  @State subOnly: boolean = false;
  @State mosaic: string = '';
  @State def: string = '';
  /** 分类自己的收藏位：只写 amane 的 is_favorite，与「影片收藏 → 自动入库」无关。 */
  @State facet: FacetItem = emptyFacet();
  @State tip: string = '';
  /** 抽卡模式：把这款分类下的影片剧照随机铺成瀑布流，替代海报网格。 */
  @State gachaOn: boolean = false;
  private kind: string = 'tag';
  private facetId: number = 0;
  private title: string = '';
  private sorts: Choice[] = [
    { key: 'release', label: '发行时间' },
    { key: 'number', label: '番号' },
    { key: 'score', label: '评分' },
    { key: 'runtime', label: '时长' },
    { key: 'random', label: '随机' }
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
    // 默认进不进抽卡模式由设置页决定（列表页仍是默认视图）
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
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
      this.baseOffset = r.offset;
      this.facet = r.facet;
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
    // 随机排序时 items 是「随机窗口」里的一段，绝对 offset = 窗口起点 + 已加载数
    this.load(this.baseOffset + this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private open(item: FacetMediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  /**
   * 收藏这个分类。乐观更新 + 失败回滚：服务端动作是「置为」而不是「取反」，
   * 所以每次都把目标值显式带上。
   */
  private async toggleFav(): Promise<void> {
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0) {
      return;
    }
    const want: boolean = !this.facet.isFavorite;
    this.setFav(want);
    try {
      const text: string = await httpPost(
        `${Store.I.user}/api/user/facets/${this.kind}/${id}/favorite`,
        Store.I.token, JSON.stringify({ favorite: want }));
      const r: FacetFavoriteResult = JSON.parse(text) as FacetFavoriteResult;
      this.setFav(r.favorite === true);
      Store.I.facetDirty = true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet favorite: ${e.code} ${e.message}`);
      this.setFav(!want);
      this.tip = e.code === 404 ? `服务端未启用分类收藏（${Store.I.user}，需 1.3.3+）` : '收藏失败，请重试';
    }
  }

  private setFav(fav: boolean): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, isFavorite: fav,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: this.facet.isHidden
    };
  }

  /**
   * 隐藏 / 恢复这个标签。写旁挂服务的 facet_hidden 表，与 amane 的库和刮削规则无关；
   * 成功后打 Store.I.facetDirty，返回列表时那一页会自动重拉。
   */
  private async toggleHide(): Promise<void> {
    const id: number = this.facet.id > 0 ? this.facet.id : this.facetId;
    if (id <= 0) {
      return;
    }
    const want: boolean = !this.facet.isHidden;
    this.setHidden(want);
    try {
      await httpPost(`${Store.I.user}/api/user/facets/${this.kind}/${id}/hide`,
        Store.I.token, JSON.stringify({ hidden: want }));
      Store.I.facetDirty = true;
      this.tip = want ? '已隐藏，标签列表里不再显示' : '已恢复显示';
      this.clearTipLater();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet hide: ${e.code} ${e.message}`);
      this.setHidden(!want);
      // 404 有两种可能：服务端太旧，或者 App 连错端口（测试版 8771 / 正式版 8770）——
      // 把实际连的地址打出来，一眼能看出是哪个
      this.tip = e.code === 404 ? `服务端未启用隐藏（${Store.I.user}，需 1.3.5+）` : '操作失败，请重试';
      this.clearTipLater();
    }
  }

  private clearTipLater(): void {
    setTimeout(() => {
      this.tip = '';
    }, 2600);
  }

  private setHidden(hidden: boolean): void {
    this.facet = {
      id: this.facet.id, name: this.facet.name, count: this.facet.count,
      posters: this.facet.posters, isFavorite: this.facet.isFavorite,
      lastRelease: this.facet.lastRelease, lastAdded: this.facet.lastAdded,
      isHidden: hidden
    };
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

  /**
   * 系列页标题左侧的封面：三张海报横向并列、不裁剪（2:3 原比例）。
   * 之前是四宫格截图式裁切，看不出海报原貌，换掉。
   */
  @Builder
  Cover() {
    Row({ space: 2 }) {
      ForEach([0, 1, 2], (i: number) => {
        Image(this.posterAt(i).length > 0 ? Store.I.img(this.posterAt(i)) : '')
          .width(this.items.length >= 2 ? 31 : 40)
          .height(46)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.CARD_HI)
          .alt($r('app.media.placeholder'))
          .visibility(this.posterAt(i).length > 0 ? Visibility.Visible : Visibility.None)
      }, (i: number) => `cv-${i}`)
    }
    .height(46)
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

      // 分类收藏：与详情页的影片收藏是两条链路，这里只写 amane 的 is_favorite 位
      if (this.kind !== 'user_tag') {
        Column({ space: 1 }) {
          Text(this.facet.isFavorite ? '♥' : '♡')
            .fontSize(17)
            .fontColor(this.facet.isFavorite ? Theme.ACCENT : Theme.TEXT_DIM)
          Text(this.facet.isFavorite ? '已收藏' : '收藏')
            .fontSize(8)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(40)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleFav();
        })
      }

      // 隐藏：只在标签上开。隐藏只是不在「标签」列表里列出来，
      // 不删标签、不动刮削规则 —— 用户明确说懒得因此改刮削设置。
      if (this.kind === 'tag') {
        Column({ space: 1 }) {
          Text(this.facet.isHidden ? '⊘' : '◎')
            .fontSize(16)
            .fontColor(this.facet.isHidden ? Theme.GOLD : Theme.TEXT_DIM)
          Text(this.facet.isHidden ? '已隐藏' : '隐藏')
            .fontSize(8)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(40)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleHide();
        })
      }
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
                // 随机排序重复点同一个 chip = 重新开一扇随机窗口
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

        // 抽卡模式：把这一页换成随机剧照墙（不改变筛选/排序，只是换一种看法）
        if (BuildConfig.ENABLE_GACHA) {
          GachaSwitch({
            on: this.gachaOn,
            onToggle: (v: boolean) => {
              this.gachaOn = v;
            }
          })
        }
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

  /**
   * 抽卡模式下的精简工具条：只留开关 + 一句说明。
   * 开关必须一直看得见 —— 否则进了抽卡模式就退不出来了。
   */
  @Builder
  GachaBar() {
    Row({ space: 8 }) {
      GachaSwitch({
        on: this.gachaOn,
        onToggle: (v: boolean) => {
          this.gachaOn = v;
        }
      })
      Blank()
      Text('随机剧照 · 点图看详情')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 8 })
  }

  build() {
    Column() {
      this.Header()

      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(10)
          .fontColor(Theme.DANGER)
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
      }

      if (this.gachaOn) {
        this.GachaBar()
        Scroll() {
          Column() {
            GachaWall({
              scope: this.kind,
              scopeId: this.facetId,
              label: this.title,
              count: 0
            })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 24 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else if (this.loading) {
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
