import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import {
  FacetItem, FacetList, FacetParams, facetLabel, safeFacetList
} from './FacetTypes';

const PAGE_SIZE: number = 40;

interface Choice {
  key: string;
  label: string;
}

/** chip 必须是子组件：@Builder 按值传参不刷新，选中态会停在初始值。 */
@Component
struct FacetChoiceChips {
  options: Choice[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Row({ space: 7 }) {
      ForEach(this.options, (opt: Choice) => {
        Text(opt.label)
          .fontSize(11)
          .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.onPick(opt.key);
          })
      }, (opt: Choice) => `fchoice-${opt.key}`)
    }
  }
}

/**
 * 公开扩展 facets：底部「标签」Tab —— 分类浏览入口。
 *
 * 为什么要单独一页：影片详情里的标签以前只是死文本，媒体库只能按库翻，
 * 想「顺着一个标签看下去」没有入口。这里把上游统一的 facet 体系
 * （标签 / 系列 / 制片商 / 我的标签）做成同一套网格，点进去就是该分类的影片墙。
 *
 * 阅览体验取舍：
 *  - 默认按「作品数」倒序，先看到真正有内容的大分类，而不是名字排序的头几个生僻词；
 *  - 两个卡片一行，名字最多两行，尾部固定显示「N 部」，长名字不会把网格撑歪；
 *  - 搜索防抖 350ms，切换分类立即重载，触底自动续页。
 */
@Component
export struct FacetsTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State items: FacetItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State keyword: string = '';
  @State kind: string = 'tag';
  @State sortBy: string = 'count';
  @State order: string = 'desc';
  @State onlyFav: boolean = false;
  private searchTimer: number = -1;
  private kinds: Choice[] = [
    { key: 'tag', label: '标签' },
    { key: 'series', label: '系列' },
    { key: 'studio', label: '制片商' },
    { key: 'user_tag', label: '我的标签' }
  ];
  private sorts: Choice[] = [
    { key: 'count', label: '作品数' },
    { key: 'name', label: '名称' }
  ];

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  onRefresh(): void {
    this.reload();
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${PAGE_SIZE}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`
    ];
    if (this.keyword.length > 0) {
      parts.push(`search=${encodeURIComponent(this.keyword)}`);
    }
    // 上游只有 tag/series/studio/publisher 支持 favorite；user_tag 传了会 400
    if (this.onlyFav && this.kind !== 'user_tag') {
      parts.push('favorite=true');
    }
    return `${Store.I.user}/api/user/facets/${this.kind}?${parts.join('&')}`;
  }

  private reload(): void {
    this.items = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      const text: string = await httpGet(this.buildUrl(offset), Store.I.token);
      const data: FacetList = safeFacetList(JSON.parse(text) as FacetList);
      this.items = append ? this.items.concat(data.items) : data.items;
      this.total = data.total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facets: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404
          ? '服务端未启用分类扩展（需 amane-user 1.3.0+）'
          : '加载失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.items.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.load(this.items.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private onKeyword(value: string): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const kw: string = value;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.keyword = kw;
      this.reload();
    }, 350);
  }

  private pickSort(key: string): void {
    if (this.sortBy === key) {
      this.order = this.order === 'desc' ? 'asc' : 'desc';
    } else {
      this.sortBy = key;
      this.order = key === 'name' ? 'asc' : 'desc';
    }
    this.reload();
  }

  private toggleOrder(): void {
    this.order = this.order === 'desc' ? 'asc' : 'desc';
    this.reload();
  }

  private sortLabel(): string {
    // 作品数用「从多到少」更好懂，名称用「A→Z / Z→A」
    if (this.sortBy === 'name') {
      return this.order === 'asc' ? '名称 A→Z' : '名称 Z→A';
    }
    return this.order === 'desc' ? '作品数 多→少' : '作品数 少→多';
  }

  private open(f: FacetItem): void {
    const params: FacetParams = { kind: this.kind, id: f.id, name: f.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: params });
  }

  @Builder
  Cell(f: FacetItem) {
    Column({ space: 6 }) {
      Text(f.name.length > 0 ? f.name : '未命名')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .maxLines(2)
        .lineHeight(18)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Blank()
      Text(`${f.count} 部`)
        .fontSize(10)
        .fontColor(f.count > 0 ? Theme.ACCENT : Theme.TEXT_FAINT)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height(78)
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
    .border({ width: 0.5, color: '#14FFFFFF' })
    .onClick(() => {
      this.open(f);
    })
  }

  @Builder
  Toolbar() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(facetLabel(this.kind))
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`${this.total} 项 · ${this.sortLabel()}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      Scroll() {
        FacetChoiceChips({
          options: this.kinds,
          current: this.kind,
          onPick: (key: string) => {
            if (this.kind === key) {
              return;
            }
            this.kind = key;
            // user_tag 不支持 favorite 筛选，切过去时清掉，避免按钮消失但条件还生效
            if (key === 'user_tag') {
              this.onlyFav = false;
            }
            this.reload();
          }
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)

      TextInput({ placeholder: `搜索${facetLabel(this.kind)}名` })
        .height(38)
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 12 })
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((value: string) => {
          this.onKeyword(value);
        })

      Row({ space: 8 }) {
        FacetChoiceChips({
          options: this.sorts,
          current: this.sortBy,
          onPick: (key: string) => {
            this.pickSort(key);
          }
        })
        Blank()

        // 显式方向开关：↓ = 多到少 / Z→A，↑ = 少到多 / A→Z
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
            this.toggleOrder();
          })

        if (this.kind !== 'user_tag') {
          Text('收藏')
            .fontSize(11)
            .fontColor(this.onlyFav ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.onlyFav ? Theme.ACCENT : Theme.CARD)
            .borderRadius(12)
            .onClick(() => {
              this.onlyFav = !this.onlyFav;
              this.reload();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 12, bottom: 8 })
  }

  build() {
    Column() {
      this.Toolbar()

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
          Text('⌗')
            .fontSize(32)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.error)
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('⌗')
            .fontSize(34)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.keyword.length > 0 ? `没有找到「${this.keyword}」` : `还没有${facetLabel(this.kind)}数据`)
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text(this.keyword.length > 0 ? '换个关键字试试' : '先去媒体库刮削几部影片')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.items, (f: FacetItem) => {
            GridItem() {
              this.Cell(f)
            }
          }, (f: FacetItem) => `facet-${this.kind}-${f.id}`)

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
              .height(78)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.loadMore();
              })
            }
          }
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(9)
        .rowsGap(9)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 12 })
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
