import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { ActorItem, ActorList, ActorParams, safeActorList } from './ActorTypes';

const PAGE_SIZE: number = 30;

interface Choice {
  key: string;
  label: string;
}

/**
 * 单选 chip 行。必须是子组件：@Builder 按值传参不会刷新，选中态会停在初始值
 * （view/BrowseGrid.ets 里踩过同一个坑）。
 */
@Component
struct ActorFilterChips {
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
      }, (opt: Choice) => `fchip-${opt.key}`)
    }
  }
}

/** 自动换行的单选 chip 组：筛选面板里选项多，不能横向滚出屏幕。 */
@Component
struct ActorWrapChips {
  options: Choice[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.options, (opt: Choice) => {
        Text(opt.label)
          .fontSize(11)
          .fontColor(this.current === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD_HI)
          .borderRadius(11)
          .margin({ right: 6, bottom: 6 })
          .onClick(() => {
            this.onPick(opt.key);
          })
      }, (opt: Choice) => `wchip-${opt.key}`)
    }
    .width('100%')
  }
}

/**
 * 公开扩展 actors：底部「演员」Tab。
 *
 * 排序：作品数 / 名字 / 生日 / 身高 / 胸围 / 腰围 / 臀围 / 罩杯 / 资料更新，
 * 方向由右侧独立的「↓ / ↑」开关控制，而不是靠「再点一次同一个 chip」这种隐式行为。
 * 只传上游 ActorBrowseParams 真实支持的字段，避免客户端排了个假序。
 *
 * 筛选：性别 / 有头像 / 有资料是快筛；面板里是年龄、身高、罩杯、胸围、出生地，
 * 全部映射到上游的 *_min / *_max 区间参数，选中即生效，工具条显示生效条数。
 */
@Component
export struct ActorsTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State items: ActorItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State keyword: string = '';
  @State sortBy: string = 'count';
  @State order: string = 'desc';
  @State onlyImage: boolean = true;
  @State onlyPerson: boolean = false;
  // 默认只看女演员：这是绝大多数时候的意图，省一次点击
  @State gender: string = 'female';
  @State showFilter: boolean = false;
  @State ageBand: string = '';
  @State heightBand: string = '';
  @State cupBand: string = '';
  @State bustBand: string = '';
  @State place: string = '';
  private searchTimer: number = -1;
  private placeTimer: number = -1;
  private sorts: Choice[] = [
    { key: 'count', label: '作品数' },
    { key: 'name', label: '名字' },
    { key: 'birthday', label: '生日' },
    { key: 'height', label: '身高' },
    { key: 'bust', label: '胸围' },
    { key: 'waist', label: '腰围' },
    { key: 'hip', label: '臀围' },
    { key: 'cup', label: '罩杯' },
    { key: 'updated_at', label: '更新' }
  ];
  private genders: Choice[] = [
    { key: '', label: '全部' },
    { key: 'female', label: '女' },
    { key: 'male', label: '男' }
  ];
  private ages: Choice[] = [
    { key: '', label: '不限' },
    { key: '18-24', label: '18-24' },
    { key: '25-29', label: '25-29' },
    { key: '30-34', label: '30-34' },
    { key: '35+', label: '35+' }
  ];
  private heights: Choice[] = [
    { key: '', label: '不限' },
    { key: '0-155', label: '≤155' },
    { key: '156-160', label: '156-160' },
    { key: '161-165', label: '161-165' },
    { key: '166-170', label: '166-170' },
    { key: '171+', label: '171+' }
  ];
  private cups: Choice[] = [
    { key: '', label: '不限' },
    { key: 'A-C', label: 'A-C' },
    { key: 'D-F', label: 'D-F' },
    { key: 'G+', label: 'G+' }
  ];
  private busts: Choice[] = [
    { key: '', label: '不限' },
    { key: '0-84', label: '≤84' },
    { key: '85-89', label: '85-89' },
    { key: '90-94', label: '90-94' },
    { key: '95+', label: '95+' }
  ];

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (this.placeTimer >= 0) {
      clearTimeout(this.placeTimer);
      this.placeTimer = -1;
    }
  }

  onRefresh(): void {
    this.reload();
  }

  // ---- 区间换算 ------------------------------------------------------- //

  /** 「18-24」→ [y-24-01-01, y-18-12-31]（按当前年份倒推）。 */
  private birthdayBounds(): string[] {
    const out: string[] = ['', ''];
    if (this.ageBand.length === 0) {
      return out;
    }
    const y: number = new Date().getFullYear();
    if (this.ageBand === '18-24') {
      out[0] = `${y - 24}-01-01`;
      out[1] = `${y - 18}-12-31`;
    } else if (this.ageBand === '25-29') {
      out[0] = `${y - 29}-01-01`;
      out[1] = `${y - 25}-12-31`;
    } else if (this.ageBand === '30-34') {
      out[0] = `${y - 34}-01-01`;
      out[1] = `${y - 30}-12-31`;
    } else if (this.ageBand === '35+') {
      out[0] = '1900-01-01';
      out[1] = `${y - 35}-12-31`;
    }
    return out;
  }

  /** 「a-b / a+ / 0-b」→ [min, max]。 */
  private bounds(band: string): string[] {
    const out: string[] = ['', ''];
    if (band.length === 0) {
      return out;
    }
    const dash: number = band.indexOf('-');
    if (dash > 0) {
      out[0] = band.substring(0, dash);
      out[1] = band.substring(dash + 1);
    } else if (band.endsWith('+')) {
      out[0] = band.substring(0, band.length - 1);
    }
    return out;
  }

  /** 生效的筛选条数（不含搜索框与性别这类快筛）。 */
  private filterCount(): number {
    let n: number = 0;
    if (this.ageBand.length > 0) {
      n++;
    }
    if (this.heightBand.length > 0) {
      n++;
    }
    if (this.cupBand.length > 0) {
      n++;
    }
    if (this.bustBand.length > 0) {
      n++;
    }
    if (this.place.length > 0) {
      n++;
    }
    return n;
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`,
      `limit=${PAGE_SIZE}`,
      `sort_by=${this.sortBy}`,
      `order=${this.order}`,
      `has_image=${this.onlyImage ? 'true' : 'false'}`
    ];
    if (this.keyword.length > 0) {
      parts.push(`search=${encodeURIComponent(this.keyword)}`);
    }
    if (this.gender.length > 0) {
      parts.push(`gender=${this.gender}`);
    }
    if (this.onlyPerson) {
      parts.push('has_person=true');
    }
    const born: string[] = this.birthdayBounds();
    if (born[0].length > 0) {
      parts.push(`birthday_min=${born[0]}`);
    }
    if (born[1].length > 0) {
      parts.push(`birthday_max=${born[1]}`);
    }
    const h: string[] = this.bounds(this.heightBand);
    if (h[0].length > 0) {
      parts.push(`height_min=${h[0]}`);
    }
    if (h[1].length > 0) {
      parts.push(`height_max=${h[1]}`);
    }
    const b: string[] = this.bounds(this.bustBand);
    if (b[0].length > 0) {
      parts.push(`bust_min=${b[0]}`);
    }
    if (b[1].length > 0) {
      parts.push(`bust_max=${b[1]}`);
    }
    if (this.cupBand.length > 0) {
      parts.push(`cup_min=${this.cupBand.substring(0, 1)}`);
      if (!this.cupBand.endsWith('+')) {
        parts.push(`cup_max=${this.cupBand.substring(2, 3)}`);
      }
    }
    if (this.place.length > 0) {
      parts.push(`birthplace=${encodeURIComponent(this.place)}`);
    }
    return `${Store.I.user}/api/user/actors?${parts.join('&')}`;
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
      const data: ActorList = safeActorList(JSON.parse(text) as ActorList);
      this.items = append ? this.items.concat(data.items) : data.items;
      this.total = data.total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actors: ${e.code} ${e.message}`);
      if (!append) {
        // 老服务端没装 actors 扩展时是 404：给一句能解释清楚的话，而不是「加载失败」
        this.error = e.code === 404
          ? '服务端未启用演员扩展（需 amane-user 1.3.0+）'
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

  private onPlace(value: string): void {
    if (this.placeTimer >= 0) {
      clearTimeout(this.placeTimer);
      this.placeTimer = -1;
    }
    const p: string = value.trim();
    this.placeTimer = setTimeout(() => {
      this.placeTimer = -1;
      if (this.place === p) {
        return;
      }
      this.place = p;
      this.reload();
    }, 500);
  }

  private pickSort(key: string): void {
    if (this.sortBy === key) {
      // 点当前排序 = 快捷切方向；工具条右侧还有显式方向开关
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

  private resetFilters(): void {
    this.gender = '';
    this.onlyPerson = false;
    this.ageBand = '';
    this.heightBand = '';
    this.cupBand = '';
    this.bustBand = '';
    this.place = '';
    this.reload();
  }

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortBy) {
        return this.sorts[i].label;
      }
    }
    return this.sortBy;
  }

  private measureText(a: ActorItem): string {
    if (a.bust > 0 && a.waist > 0 && a.hip > 0) {
      return `B${a.bust} W${a.waist} H${a.hip}`;
    }
    if (a.bust > 0) {
      return `B${a.bust}`;
    }
    return '';
  }

  private subText(a: ActorItem): string {
    let s: string = `${a.count} 部`;
    if (a.height > 0) {
      s += ` · ${a.height}cm`;
    }
    if (a.cup.length > 0) {
      s += ` · ${a.cup}`;
    }
    return s;
  }

  // ---- UI ------------------------------------------------------------- //

  @Builder
  Cell(a: ActorItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (a.avatar.length > 0) {
        Image(Store.I.img(a.avatar))
          .width('100%')
          .aspectRatio(0.8)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.CARD)
          .alt($r('app.media.placeholder'))
      } else {
        Column() {
          Text(a.name.length > 0 ? a.name.substring(0, 1) : '?')
            .fontSize(30)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .aspectRatio(0.8)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.CARD_HI)
      }

      Column()
        .width('100%')
        .height(74)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#E60B0B0F', 1]]
        })

      Column({ space: 2 }) {
        Text(a.name.length > 0 ? a.name : '未命名')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subText(a))
          .fontSize(10)
          .fontColor('#C9C9D2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.measureText(a).length > 0) {
          Text(this.measureText(a))
            .fontSize(9)
            .fontColor('#9C9CA8')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, right: 8, bottom: 7 })
    }
    .width('100%')
    .borderRadius(Theme.RADIUS)
    .clip(true)
    .backgroundColor(Theme.CARD)
    .onClick(() => {
      const params: ActorParams = { id: a.id, name: a.name };
      router.pushUrl({ url: 'ext/actors/ActorDetailPage', params: params });
    })
  }

  @Builder
  SortRow() {
    Row({ space: 8 }) {
      Scroll() {
        ActorFilterChips({
          options: this.sorts,
          current: this.sortBy,
          onPick: (key: string) => {
            this.pickSort(key);
          }
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)

      // 显式方向开关：↓ = 从大到小 / 从晚到早，↑ = 从小到大
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
    }
    .width('100%')
  }

  @Builder
  FilterGroup(label: string, options: Choice[], current: string, onPick: (key: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      ActorWrapChips({
        options: options,
        current: current,
        onPick: onPick
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  FilterPanel() {
    Column({ space: 10 }) {
      this.FilterGroup('年龄', this.ages, this.ageBand, (key: string) => {
        this.ageBand = key;
        this.reload();
      })
      this.FilterGroup('身高 cm', this.heights, this.heightBand, (key: string) => {
        this.heightBand = key;
        this.reload();
      })
      this.FilterGroup('罩杯', this.cups, this.cupBand, (key: string) => {
        this.cupBand = key;
        this.reload();
      })
      this.FilterGroup('胸围 cm', this.busts, this.bustBand, (key: string) => {
        this.bustBand = key;
        this.reload();
      })

      Column({ space: 6 }) {
        Text('出生地')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
        TextInput({ placeholder: '出生地包含匹配，如 東京都 / 大阪', text: this.place })
          .height(34)
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 11 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .width('100%')
          .onChange((value: string) => {
            this.onPlace(value);
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 10 }) {
        Text(`已选 ${this.filterCount()} 项`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text('重置筛选')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(14)
          .onClick(() => {
            this.resetFilters();
          })
        Text('收起')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(14)
          .onClick(() => {
            this.showFilter = false;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  Toolbar() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text('演员')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`${this.total} 位 · ${this.sortLabel()}${this.order === 'desc' ? '↓' : '↑'}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Text('共演')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(11)
          .onClick(() => {
            router.pushUrl({ url: 'ext/actors/CastFinderPage' });
          })
      }
      .width('100%')

      TextInput({ placeholder: '搜索演员名 / 别名' })
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

      this.SortRow()

      Row({ space: 7 }) {
        ActorFilterChips({
          options: this.genders,
          current: this.gender,
          onPick: (key: string) => {
            if (this.gender === key) {
              return;
            }
            this.gender = key;
            this.reload();
          }
        })
        Blank()
        Text('有头像')
          .fontSize(11)
          .fontColor(this.onlyImage ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.onlyImage ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.onlyImage = !this.onlyImage;
            this.reload();
          })
        Text('有资料')
          .fontSize(11)
          .fontColor(this.onlyPerson ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.onlyPerson ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.onlyPerson = !this.onlyPerson;
            this.reload();
          })
        Text(this.filterCount() > 0 ? `筛选 ${this.filterCount()}` : '筛选')
          .fontSize(11)
          .fontColor(this.filterCount() > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(this.filterCount() > 0 ? Theme.ACCENT : Theme.CARD)
          .borderRadius(12)
          .onClick(() => {
            this.showFilter = !this.showFilter;
          })
      }
      .width('100%')

      if (this.showFilter) {
        Scroll() {
          this.FilterPanel()
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 300 })
        .width('100%')
      }
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
          Text('⌁')
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
          Text('☺')
            .fontSize(34)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.keyword.length > 0 ? `没有找到「${this.keyword}」` : '没有符合条件的演员')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text(this.filterCount() > 0 || !this.onlyImage ? '试试放宽筛选条件' : '换个搜索词试试')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          if (this.filterCount() > 0) {
            Text('重置筛选')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(15)
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
          ForEach(this.items, (a: ActorItem) => {
            GridItem() {
              this.Cell(a)
            }
          }, (a: ActorItem) => `actor-${a.id}`)

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
        .columnsGap(9)
        .rowsGap(12)
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
