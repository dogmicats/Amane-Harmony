import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams } from '../../common/Types';
import { MarkBadges } from '../../view/MarkBadges';
import {
  ActorItem, ActorList, CastFindItem, CastFindList, CastMember,
  safeActorList, safeCastFindList, safeCastMember
} from './ActorTypes';

const PAGE: number = 24;

interface Choice {
  key: string;
  label: string;
}

@Component
struct PickChips {
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
      }, (opt: Choice) => `pchip-${opt.key}`)
    }
    .width('100%')
  }
}

/** 把 min2 / eq2 这类标识解析成 [min, max]。 */
function band(minKey: string): number[] {
  const out: number[] = [0, 99];
  if (minKey.length < 3) {
    return out;
  }
  const n: number = Number(minKey.startsWith('eq') ? minKey.substring(2) : minKey.substring(3));
  if (!isFinite(n)) {
    return out;
  }
  if (minKey.startsWith('eq')) {
    out[0] = n;
    out[1] = n;
  } else {
    out[0] = n;
  }
  return out;
}

/**
 * 公开扩展 actors：共演筛选。
 *
 * 两个诉求合在一页：
 *  1. **具体人**：选若干男/女演员，找他们同时出演的片子（上游 actor_id 多值是 AND）；
 *  2. **抽象条件**：「有 N 个女演员」「至少 N 个男演员」这类，上游没有，
 *     走扩展的 /api/user/cast/find 直接对只读库做聚合（女/男/总数三个区间）。
 *
 * 结果卡片直接带阵容统计与头像，不用点进去才知道谁演了谁。
 */
@Entry
@Component
struct CastFinderPage {
  @State picked: CastMember[] = [];
  @State results: CastFindItem[] = [];
  /** 每次查询自增：只按内容做 key 时，两个条件命中同一批首条 + 同样行数
   *  key 会完全一致，ArkUI 判定未变就复用旧节点，看起来像筛选没生效。 */
  @State seq: number = 0;
  @State rows: CastFindItem[][] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State female: string = '';
  @State male: string = '';
  @State castN: string = '';
  @State sortBy: string = 'release';
  @State order: string = 'desc';
  @State onlySub: boolean = false;
  @State mosaic: string = '';
  @State picking: boolean = false;
  @State query: string = '';
  @State genderFilter: string = 'all';
  @State hits: ActorItem[] = [];
  private searchTimer: number = -1;
  private females: Choice[] = [
    { key: '', label: '女演员不限' },
    { key: 'min1', label: '≥1 女' },
    { key: 'min2', label: '≥2 女' },
    { key: 'min3', label: '≥3 女' },
    { key: 'min5', label: '≥5 女' },
    { key: 'eq2', label: '=2 女' },
    { key: 'eq3', label: '=3 女' }
  ];
  private males: Choice[] = [
    { key: '', label: '男演员不限' },
    { key: 'eq0', label: '=0 男' },
    { key: 'min1', label: '≥1 男' },
    { key: 'eq1', label: '=1 男' },
    { key: 'min2', label: '≥2 男' }
  ];
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
  private casts: Choice[] = [
    { key: '', label: '总人数不限' },
    { key: 'min3', label: '≥3 人' },
    { key: 'min4', label: '≥4 人' },
    { key: 'min6', label: '≥6 人' },
    { key: 'min8', label: '≥8 人' }
  ];
  private genders: Choice[] = [
    { key: 'all', label: '全部' },
    { key: 'female', label: '女' },
    { key: 'male', label: '男' }
  ];

  aboutToAppear(): void {
    // 不预跑：无条件的全表聚合没意义，还会白等一次
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`, `limit=${PAGE}`,
      `sort_by=${this.sortBy}`, `order=${this.order}`
    ];
    if (this.onlySub) {
      parts.push('has_subtitle=true');
    }
    if (this.mosaic.length > 0) {
      parts.push(`mosaic=${this.mosaic}`);
    }
    if (this.picked.length > 0) {
      const ids: string[] = [];
      for (let i = 0; i < this.picked.length; i++) {
        ids.push(`${this.picked[i].id}`);
      }
      parts.push(`actor_id=${ids.join(',')}`);
    }
    const f: number[] = band(this.female);
    const m: number[] = band(this.male);
    const c: number[] = band(this.castN);
    if (f[0] > 0 || f[1] < 99) {
      parts.push(`female_min=${f[0]}`);
      parts.push(`female_max=${f[1]}`);
    }
    if (m[0] > 0 || m[1] < 99) {
      parts.push(`male_min=${m[0]}`);
      parts.push(`male_max=${m[1]}`);
    }
    if (c[0] > 0 || c[1] < 99) {
      parts.push(`cast_min=${c[0]}`);
      parts.push(`cast_max=${c[1]}`);
    }
    return `${Store.I.user}/api/user/cast/find?${parts.join('&')}`;
  }

  private runQuery(): void {
    this.seq++;
    this.results = [];
    this.total = 0;
    this.error = '';
    this.loading = true;
    this.load(0, false);
  }

  private async load(offset: number, append: boolean): Promise<void> {
    try {
      const text: string = await httpGet(this.buildUrl(offset), Store.I.token);
      const r: CastFindList = safeCastFindList(JSON.parse(text) as CastFindList);
      this.results = append ? this.results.concat(r.items) : r.items;
      this.rows = this.chunk(this.results);
      this.total = r.total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cast find: ${e.code} ${e.message}`);
      if (!append) {
        this.error = e.code === 404 ? '服务端未启用演员扩展' : '查询失败，点这里重试';
      }
    }
    this.loading = false;
    this.loadingMore = false;
  }

  private loadMore(): void {
    if (this.loadingMore || this.loading || this.results.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.load(this.results.length, true).catch(() => {
      this.loadingMore = false;
    });
  }

  private chunk(list: CastFindItem[]): CastFindItem[][] {
    const out: CastFindItem[][] = [];
    let row: CastFindItem[] = [];
    for (let i = 0; i < list.length; i++) {
      row.push(list[i]);
      if (row.length === 2) {
        out.push(row);
        row = [];
      }
    }
    if (row.length > 0) {
      out.push(row);
    }
    return out;
  }

  /**
   * 结果卡上要展示哪些头像：筛了「≥N 女」就只给女演员，
   * 筛了男演员同理；两头都选就按原顺序。
   */
  /**
   * 头像尺寸按人数收缩：1~2 个给足冲击力，3 个自动退到 64dp，
   * 否则 92dp × 3 会顶出卡片右边界（这正是上一版「>2 个就被挤出去」的原因）。
   */
  private avSize(x: CastFindItem): number {
    return this.castToShow(x).length >= 3 ? 64 : 84;
  }

  private avOverlap(x: CastFindItem): number {
    return this.castToShow(x).length >= 3 ? -12 : -16;
  }

  private castToShow(x: CastFindItem): CastMember[] {
    const wantFemale: boolean = this.female.length > 0 && this.male.length === 0;
    const wantMale: boolean = this.male.length > 0 && this.female.length === 0;
    const out: CastMember[] = [];
    for (let i = 0; i < x.cast.length; i++) {
      const c: CastMember = x.cast[i];
      if (wantFemale && c.gender !== 'female') {
        continue;
      }
      if (wantMale && c.gender !== 'male') {
        continue;
      }
      out.push(c);
      if (out.length >= 3) {
        break;
      }
    }
    return out;
  }

  /** 当前查询条件的一句话摘要（用于结果区标题）。 */
  private conditionText(): string {
    const parts: string[] = [];
    if (this.picked.length > 0) {
      const names: string[] = [];
      for (let i = 0; i < this.picked.length; i++) {
        names.push(this.picked[i].name);
      }
      parts.push(names.join('+'));
    }
    if (this.female.length > 0) {
      for (let i = 0; i < this.females.length; i++) {
        if (this.females[i].key === this.female) {
          parts.push(this.females[i].label);
        }
      }
    }
    if (this.male.length > 0) {
      for (let i = 0; i < this.males.length; i++) {
        if (this.males[i].key === this.male) {
          parts.push(this.males[i].label);
        }
      }
    }
    if (this.castN.length > 0) {
      for (let i = 0; i < this.casts.length; i++) {
        if (this.casts[i].key === this.castN) {
          parts.push(this.casts[i].label);
        }
      }
    }
    return parts.length > 0 ? parts.join(' · ') : '全部作品';
  }

  private isPicked(id: number): boolean {
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].id === id) {
        return true;
      }
    }
    return false;
  }

  private toggle(a: ActorItem): void {
    if (this.isPicked(a.id)) {
      const next: CastMember[] = [];
      for (let i = 0; i < this.picked.length; i++) {
        if (this.picked[i].id !== a.id) {
          next.push(this.picked[i]);
        }
      }
      this.picked = next;
    } else {
      if (this.picked.length >= 6) {
        return;
      }
      const m: CastMember = { id: a.id, name: a.name, gender: a.gender, avatar: a.avatar };
      this.picked = this.picked.concat([safeCastMember(m)]);
    }
    this.runQuery();
  }

  private async doSearch(): Promise<void> {
    const kw: string = this.query.trim();
    let url: string = `${Store.I.user}/api/user/actors?search=${encodeURIComponent(kw)}` +
      `&limit=24&has_image=false&sort_by=count&order=desc`;
    if (this.genderFilter !== 'all') {
      url += `&gender=${this.genderFilter}`;
    }
    try {
      const text: string = await httpGet(url, Store.I.token);
      this.hits = safeActorList(JSON.parse(text) as ActorList).items;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cast picker: ${e.code} ${e.message}`);
    }
  }

  private onSearch(value: string): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const q: string = value;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.query = q;
      this.doSearch();
    }, 320);
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
        Text('共演筛选')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(this.total > 0 ? `${this.total} 部符合条件` : '选人 + 人数条件，找共演作品')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 6 })
  }

  @Builder
  Picked() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('指定演员')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Text(`${this.picked.length}/6`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(this.picking ? '收起' : '+ 添加')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(11)
          .onClick(() => {
            this.picking = !this.picking;
            if (this.picking && this.hits.length === 0) {
              this.doSearch();
            }
          })
      }
      .width('100%')

      if (this.picked.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.picked, (m: CastMember) => {
              Column({ space: 3 }) {
                Stack({ alignContent: Alignment.TopEnd }) {
                  if (m.avatar.length > 0) {
                    Image(Store.I.img(m.avatar))
                      .width(44)
                      .height(44)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(22)
                      .backgroundColor(Theme.CARD_HI)
                  } else {
                    Column() {
                      Text(m.name.length > 0 ? m.name.substring(0, 1) : '?')
                        .fontSize(16)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width(44)
                    .height(44)
                    .justifyContent(FlexAlign.Center)
                    .borderRadius(22)
                    .backgroundColor(Theme.CARD_HI)
                  }
                  Text('×')
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .width(15)
                    .height(15)
                    .textAlign(TextAlign.Center)
                    .borderRadius(8)
                    .backgroundColor('#CC444444')
                    .onClick(() => {
                      const next: CastMember[] = [];
                      for (let i = 0; i < this.picked.length; i++) {
                        if (this.picked[i].id !== m.id) {
                          next.push(this.picked[i]);
                        }
                      }
                      this.picked = next;
                      this.runQuery();
                    })
                }
                .width(44)
                .height(44)

                Text(m.name)
                  .fontSize(9)
                  .fontColor(Theme.TEXT_DIM)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(52)
                  .textAlign(TextAlign.Center)
              }
              .width(52)
            }, (m: CastMember) => `picked-${m.id}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)
      }

      if (this.picking) {
        TextInput({ placeholder: '搜索演员名', text: this.query })
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
            this.onSearch(v);
          })

        PickChips({
          options: this.genders,
          current: this.genderFilter,
          onPick: (key: string) => {
            this.genderFilter = key;
            this.doSearch();
          }
        })

        Scroll() {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.hits, (a: ActorItem) => {
              Row({ space: 6 }) {
                if (a.avatar.length > 0) {
                  Image(Store.I.img(a.avatar))
                    .width(26)
                    .height(26)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(13)
                    .backgroundColor(Theme.CARD_HI)
                }
                Text(a.name)
                  .fontSize(11)
                  .fontColor(this.isPicked(a.id) ? '#FFFFFF' : Theme.TEXT_DIM)
                  .maxLines(1)
              }
              .padding({ left: 4, right: 9, top: 3, bottom: 3 })
              .backgroundColor(this.isPicked(a.id) ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(14)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.toggle(a);
              })
            }, (a: ActorItem) => `hit-${a.id}`)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 180 })
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  Conditions() {
    Column({ space: 8 }) {
      Text('按人数找（不看具体是谁）')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
      PickChips({
        options: this.females,
        current: this.female,
        onPick: (key: string) => {
          this.female = key;
          this.runQuery();
        }
      })
      PickChips({
        options: this.males,
        current: this.male,
        onPick: (key: string) => {
          this.male = key;
          this.runQuery();
        }
      })
      PickChips({
        options: this.casts,
        current: this.castN,
        onPick: (key: string) => {
          this.castN = key;
          this.runQuery();
        }
      })

      Row({ space: 8 }) {
        Text('排序')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(this.order === 'desc' ? '↓' : '↑')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .width(26)
          .height(24)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.ACCENT)
          .borderRadius(12)
          .onClick(() => {
            this.order = this.order === 'desc' ? 'asc' : 'desc';
            this.runQuery();
          })
      }
      .width('100%')
      .margin({ top: 2 })

      PickChips({
        options: this.sorts,
        current: this.sortBy,
        onPick: (key: string) => {
          if (this.sortBy === key) {
            this.order = this.order === 'desc' ? 'asc' : 'desc';
          } else {
            this.sortBy = key;
            this.order = key === 'number' ? 'asc' : 'desc';
          }
          this.runQuery();
        }
      })

      Row({ space: 8 }) {
        Text('只看')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(this.onlySub ? '✓ 有字幕' : '有字幕')
          .fontSize(11)
          .fontColor(this.onlySub ? '#FFFFFF' : Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.onlySub ? Theme.ACCENT : Theme.CARD_HI)
          .borderRadius(11)
          .onClick(() => {
            this.onlySub = !this.onlySub;
            this.runQuery();
          })
      }
      .width('100%')

      PickChips({
        options: this.mosaics,
        current: this.mosaic,
        onPick: (key: string) => {
          this.mosaic = key;
          this.runQuery();
        }
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 结果卡：封面当主角，阵容头像压在图下，文字只留番号与人数。 */
  @Builder
  Cell(x: CastFindItem) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(Store.I.img(x.poster))
          .width('100%')
          .aspectRatio(0.704)
          .objectFit(ImageFit.Cover)
          .borderRadius(10)
          .backgroundColor(Theme.CARD_HI)
          .alt($r('app.media.placeholder'))

        // 底部渐变，保证压在图上的番号可读
        Column()
          .width('100%')
          .height(150)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0], ['#B30B0B0F', 0.45], ['#F20B0B0F', 1]]
          })
          .borderRadius({ bottomLeft: 10, bottomRight: 10 })

        // 左上：阵容人数
        Row({ space: 5 }) {
          if (x.female_count > 0) {
            Text(`♀${x.female_count}`)
              .fontSize(9)
              .fontColor('#FF8FB1')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor('#B3000000')
              .borderRadius(5)
          }
          if (x.male_count > 0) {
            Text(`♂${x.male_count}`)
              .fontSize(9)
              .fontColor('#7FB4FF')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor('#B3000000')
              .borderRadius(5)
          }
        }
        .position({ x: 6, y: 6 })

        // 头像占封面下缘：68dp、居中、叠压，遮住一部分封面也没关系 ——
        // 这个页面看的就是「谁跟谁共演」，人必须大到一眼认得出。
        Column({ space: 7 }) {
          if (this.castToShow(x).length > 0) {
            Row() {
              ForEach(this.castToShow(x), (c: CastMember, i: number) => {
                if (c.avatar.length > 0) {
                  Image(Store.I.img(c.avatar))
                    .width(this.avSize(x))
                    .height(this.avSize(x))
                    .objectFit(ImageFit.Cover)
                    .borderRadius(this.avSize(x) / 2)
                    .border({ width: 2, color: '#F20B0B0F' })
                    .shadow({ radius: 10, color: '#B3000000', offsetY: 3 })
                    .backgroundColor(Theme.CARD_HI)
                    .margin({ left: i === 0 ? 0 : this.avOverlap(x) })
                } else {
                  Column() {
                    Text(c.name.length > 0 ? c.name.substring(0, 1) : '?')
                      .fontSize(22)
                      .fontColor(Theme.TEXT_DIM)
                  }
                  .width(this.avSize(x))
                  .height(this.avSize(x))
                  .justifyContent(FlexAlign.Center)
                  .borderRadius(this.avSize(x) / 2)
                  .border({ width: 2, color: '#F20B0B0F' })
                  .backgroundColor(Theme.CARD_HI)
                  .margin({ left: i === 0 ? 0 : this.avOverlap(x) })
                }
              }, (c: CastMember, i: number) => `c-${x.id}-${c.id}-${i}`)
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
          Text(x.number)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
          if (x.marks.length > 0) {
            MarkBadges({ marks: x.marks, max: 3, badgeSize: 8, fill: 'dark', center: true })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .padding({ left: 6, right: 6, bottom: 8 })
      }
      .width('100%')
      .borderRadius(10)
      .clip(true)

      Text(x.title.length > 0 ? x.title : ' ')
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .maxLines(2)
        .lineHeight(14)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(x.release.length >= 10 ? x.release.substring(0, 10) : x.release)
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .onClick(() => {
      const p: DetailParams = { id: x.id };
      router.pushUrl({ url: 'pages/DetailPage', params: p });
    })
  }

  @Builder
  Row2(row: CastFindItem[]) {
    Row({ space: 9 }) {
      ForEach(row, (x: CastFindItem) => {
        this.Cell(x)
      }, (x: CastFindItem) => `cfc-${x.id}`)
      if (row.length < 2) {
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 10 }) {
          this.Picked()
          this.Conditions()

          if (this.loading) {
            Column() {
              LoadingProgress()
                .width(26)
                .height(26)
                .color(Theme.ACCENT)
            }
            .width('100%')
            .height(120)
            .justifyContent(FlexAlign.Center)
          } else if (this.error.length > 0) {
            Text(this.error)
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .padding(20)
              .onClick(() => {
                this.runQuery();
              })
          } else if (this.results.length === 0) {
            Column({ space: 8 }) {
              Text('◎')
                .fontSize(30)
                .fontColor(Theme.TEXT_FAINT)
              Text(this.picked.length === 0 && this.female.length === 0
                && this.male.length === 0 && this.castN.length === 0
                ? '先选人或选一个条件'
                : '没有符合的共演作品')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
            }
            .width('100%')
            .height(140)
            .justifyContent(FlexAlign.Center)
          } else {
            // 条件摘要：改了条件但结果看起来一样时，这行能证明查询确实重发了
            Row({ space: 6 }) {
              Text(this.conditionText())
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(`共 ${this.total} 部`)
                .fontSize(10)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 6 })

            ForEach(this.rows, (row: CastFindItem[], idx: number) => {
              this.Row2(row)
            }, (row: CastFindItem[], idx: number) => `cfr-${this.seq}-${idx}-${row[0].id}`)

            if (this.results.length < this.total) {
              Text(this.loadingMore ? '加载中…' : '加载更多')
                .fontSize(12)
                .fontColor(Theme.ACCENT)
                .padding({ top: 10, bottom: 10 })
                .width('100%')
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.loadMore();
                })
            }
          }
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
