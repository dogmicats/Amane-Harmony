import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { Personalize } from '../../common/Personalize';
import { scoreText } from '../../common/Util';
import { rateLabel, rateColor } from '../ratings/RatingStars';
import { DetailParams, LibraryInfo } from '../../common/Types';
import { MarkBadges } from '../../view/MarkBadges';
import { CollectionsBar } from '../collections/CollectionsBar';
import { BottomSheet, SortSheet, ToolPill } from '../../view/ListSheets';
import { SortOption, sortDefOf, ChipOption, VERSION_OPTIONS, MYRATING_OPTIONS } from '../../common/BrowseOptions';
import { CTYPE_OPTIONS, SCORE_OPTIONS, YEAR_OPTIONS } from '../../view/BrowseGrid';
import { BuildConfig } from '../../common/BuildConfig';
import { GachaSwitch } from '../stills/GachaSwitch';
import { GachaWall } from '../stills/GachaWall';
import { GlassBox, GlassCapsule, GlassGlyph, PageTitle, GlassBack } from '../../view/GlassKit';
import {
  ActorItem, ActorList, CastFindItem, CastFindList, CastMember, DirectorHit,
  DirectorHitList, safeActorList, safeCastFindList, safeCastMember, safeDirectorHits
} from './ActorTypes';

const PAGE: number = 24;

/** 联想的候选（只取名字/片数/id，分类列表返回的一堆字段这里用不上）。 */
interface FacetLite {
  id: number;
  name: string;
  count: number;
}

/**
 * 甄选条件的快照（2026-11-20 用户：「每次点进来都要重新选」）。
 *
 * 整页条件一次性序列化存进偏好：进来自动恢复上一次，最近几条还能在筛选抽屉里点回来。
 * `savedAt` 只用于展示，不参与「是不是同一套条件」的比较（否则每次都被当成新的）。
 */
interface CastCond {
  picked: CastMember[];
  femaleN: number[];
  female5: boolean;
  maleN: number[];
  male5: boolean;
  castN: string;
  dirs: DirectorHit[];
  dirExclude: boolean;
  sortBy: string;
  order: string;
  fCtype: string;
  fMulti: string;
  fScore: string;
  fYear: string;
  fSeries: string;
  fStudio: string;
  tagPicks: FacetLite[];
  onlySub: boolean;
  mosaic: string;
  fMyRating: string;
  fCollection: string;
  fLib: string;
  fLibs: number[];
  fSearch: string;
  savedAt: number;
}

/** 偏好键：最后一次条件 / 最近几条历史。 */
const PREF_COND_LAST: string = 'castCondLast';
const PREF_COND_HIST: string = 'castCondHist';
const COND_HIST_MAX: number = 6;

/** `/api/user/facets/{kind}` 的一条（只声明用得到的字段）。 */
interface FacetRow {
  id: number;
  name: string;
  count: number;
}

interface FacetPage {
  total: number;
  items: FacetRow[];
}

const CTYPE_CHOICES: ChipOption[] = CTYPE_OPTIONS;
const VERSION_CHOICES: ChipOption[] = VERSION_OPTIONS;
const SCORE_CHOICES: ChipOption[] = SCORE_OPTIONS;
const YEAR_CHOICES: ChipOption[] = YEAR_OPTIONS;
/**
 * 分类维度：标签 / 系列 / 制片商。
 * 没有「不限」——三个维度现在各自独立，「开哪个维度去搜」这件事总得有一个，
 * 默认是标签；要取消条件请点下面已选胶囊上的 ✕。
 */
const FACET_KINDS: ChipOption[] = [
  { key: 'tag', label: '标签' },
  { key: 'series', label: '系列' },
  { key: 'studio', label: '制片商' }
];
/**
 * 媒体库那排横滑卡的高度。
 *
 * 横向 `Scroll` **必须显式给高度**，否则它在 Column 里会塌成 0（本项目
 * `HighlightStrip.ets:188` 早就踩过同一个坑：「横向 Scroll 不给高度会把下半页挤扁」）。
 * 2026-11-17 媒体库改成横滑卡时漏了这一条，结果是整排卡一张都不显示，
 * 只剩分组标题右边那句「全部库」——用户看到的就是「媒体库里只有全部库、没得选」。
 * 卡内：封面 64 + 间隙 3 + 名字 15 + 间隙 3 + 片数 14 + 上下 padding 4 ≈ 103（留几 vp 余量防字被切）。
 */
const LIB_STRIP_H: number = 108;

/** 字幕：与「有字幕」参数（has_subtitle）对应。 */
const SUB_CHOICES: ChipOption[] = [
  { key: '', label: '不限' },
  { key: '1', label: '有字幕' }
];

/** `/api/user/libraries` 的一条（字段与服务端 `libraries()` 对齐）。 */
interface LibItem {
  id: number;
  name: string;
  count: number;
  /** 用户换过的封面；空串 = 没有，用名字首字兜底（与首页媒体库卡同口径）。 */
  cover: string;
}

interface LibResp {
  items?: LibItem[];
}

/**
 * 抽屉里的一组筛选 —— 与媒体库 `ChipGroup` 同一种设计语言。
 *
 * 2026-11-17 用户第二轮：「设计语言一体化，现在像狗皮膏药一样无序拼贴」。
 * 上一版把每组都套成一张 CARD 底 + 圆角的灰卡片，8 张硬堆在一起 —— 每组都是
 * 一个视觉方块，看着就是拼贴。媒体库那套成熟抽屉（ListSheets.ChipGroup）恰恰
 * **不套卡片**：统一在抽屉底色上，靠「小标题 + 内容 + 细分隔」分区。
 *
 * 于是本组件不再画自己的背景/圆角，只保留：
 *  - 同一条标题基线（小标题 + 右侧已选摘要 + 可选动作胶囊）；
 *  - 内容；
 *  - 组间一条极细分隔线（除末组 by padding 收口外，靠 divider 属性）。
 * 所有内容 Builder（Picked / CountSection / …）一行都不用改，只换这层壳。
 */
@Component
struct SheetSection {
  @Prop title: string = '';
  /** 标题右侧的状态文案（「不指定」「已选 2 个库」之类）；空串 = 不显示。 */
  @Prop value: string = '';
  /** 有生效条件时状态文案用主题色，肉眼能扫出「哪几组设过了」。 */
  @Prop active: boolean = false;
  /** 右上角的动作胶囊（「+ 添加」）；空串 = 不显示。 */
  @Prop actionLabel: string = '';
  /** 末组不画分隔线，避免抽屉底部悬一条线。 */
  @Prop divider: boolean = true;
  onAction: () => void = () => {};
  @BuilderParam content: () => void;

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.title)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.active ? Theme.ACCENT : Theme.TEXT)
        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(10)
            .fontColor(this.active ? Theme.ACCENT : Theme.TEXT_FAINT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank()
        }
        if (this.actionLabel.length > 0) {
          Text(this.actionLabel)
            .fontSize(11)
            .fontColor(this.actionLabel.startsWith('+') ? Theme.ON_ACCENT : Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.actionLabel.startsWith('+') ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(Theme.R_PILL)
            .onClick(() => {
              this.onAction();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
    .border(this.divider ? { width: { bottom: 1 }, color: Theme.STROKE } : { width: 0 })
  }
}

/**
 * 一个大段头（「找谁 / 按什么条件 / 我的偏好」）。
 *
 * 扁平化后组与组之间只靠细线分，8 组平铺还是看不出层次；用三个 uppercase 风格
 * 的小段头把它们归成三段，视线才有落点。段头本身不可点，纯视觉锚。
 */
@Component
struct SectionHead {
  @Prop index: string = '01';
  @Prop label: string = '';

  build() {
    Row({ space: 8 }) {
      Text(this.index)
        .fontSize(10)
        .fontColor(Theme.ACCENT)
        .fontWeight(FontWeight.Medium)
      Text(this.label)
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .letterSpacing(0.8)
    }
    .width('100%')
    .margin({ top: 6, bottom: 2 })
  }
}

/**
 * 一行 chip：可选小标题 + 自动换行。
 *
 * 尺寸与媒体库 `ChipGroup` 对齐（12vp 字 / 12×7 内边距 / 圆角 14 / 8 间距），
 * 之前这里是 11vp + 圆角 11 + 6 间距，同一个抽屉里两种 chip 混着出现，就是「大小不一致」。
 */
@Component
struct PickChips {
  @Prop title: string = '';
  options: ChipOption[] = [];
  @Prop current: string = '';
  onPick: (key: string) => void = () => {};

  build() {
    Column({ space: 8 }) {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (opt: ChipOption) => {
          Text(opt.label)
            .fontSize(12)
            .fontColor(this.current === opt.key ? Theme.ON_ACCENT : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.current === opt.key ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onPick(opt.key);
            })
        }, (opt: ChipOption) => `pchip-${this.title}-${opt.key}-${this.current === opt.key ? 1 : 0}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 人数选择条。
 *
 * 形状就是语义，别再靠颜色区分（颜色已经被「选中/未选中」占了）：
 *  - **方形 = 多选**：「1女 / 2女 / 3女 / 4女」可以同时勾，表示「这几个数量里的任意一个」；
 *  - **圆形 = 单选**：「≥5女」是一个阈值，勾上会自动清空前面的方形多选。
 * 菜单也不再一个数量列一个 chip（以前 ≥1/≥2/≥3/≥5/=2/=3 七个挤成两行，还是看不全）。
 */
@Component
struct CountPicker {
  @Prop label: string = '女';
  @Prop unit: string = '女';
  /** 多选从几开始：女是 1（0 个女演员没有意义），男是 0（单人片很常见）。 */
  @Prop floor: number = 1;
  @Prop multi: number[] = [];
  @Prop radioOn: boolean = false;
  onToggle: (v: number) => void = () => {};
  onRadio: () => void = () => {};
  onClear: () => void = () => {};

  private has(v: number): boolean {
    return this.multi.indexOf(v) >= 0;
  }

  private list(): number[] {
    const out: number[] = [];
    for (let i = this.floor; i <= 4; i++) {
      out.push(i);
    }
    return out;
  }

  build() {
    // 整行必须放得进一屏：chip 里只放数字（行首已有「女演员 / 男演员」），
    // 否则「0男 … 4男 + ≥5男」六个 chip 一定会折行，最后那个圆形单选掉到下一行
    // 看起来就像「≥5」是个孤立的选项。
    Flex({ wrap: FlexWrap.Wrap }) {
      Text(this.label)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .margin({ right: 8, bottom: 8 })

      Text(`不限`)
        .fontSize(12)
        .fontColor(this.multi.length === 0 && !this.radioOn ? Theme.ON_ACCENT : Theme.TEXT_DIM)
        .padding({ left: 11, right: 11, top: 6, bottom: 6 })
        .backgroundColor(this.multi.length === 0 && !this.radioOn ? Theme.ACCENT : Theme.CARD_HI)
        .borderRadius(14)
        .margin({ right: 6, bottom: 8 })
        .onClick(() => {
          this.onClear();
        })

      // 方形多选
      ForEach(this.list(), (v: number) => {
        Row({ space: 3 }) {
          Stack() {
            if (this.has(v)) {
              Text('✓')
                .fontSize(7)
                .fontColor(Theme.ON_ACCENT)
            }
          }
          .width(10)
          .height(10)
          .borderRadius(2)
          .border({ width: 1, color: this.has(v) ? Theme.ON_ACCENT : Theme.TEXT_FAINT })

          Text(`${v}`)
            .fontSize(12)
            .fontColor(this.has(v) ? Theme.ON_ACCENT : Theme.TEXT_DIM)
        }
        .padding({ left: 8, right: 9, top: 6, bottom: 6 })
        .backgroundColor(this.has(v) ? Theme.ACCENT : Theme.CARD_HI)
        .borderRadius(8)
        .margin({ right: 6, bottom: 8 })
        .onClick(() => {
          this.onToggle(v);
        })
      }, (v: number) => `cp-${this.unit}-${v}-${this.has(v) ? 1 : 0}`)

      // 圆形单选：≥5
      Row({ space: 3 }) {
        Stack() {
          if (this.radioOn) {
            Column()
              .width(4)
              .height(4)
              .borderRadius(2)
              .backgroundColor(Theme.ON_ACCENT)
          }
        }
        .width(10)
        .height(10)
        .borderRadius(5)
        .border({ width: 1, color: this.radioOn ? Theme.ON_ACCENT : Theme.TEXT_FAINT })

        Text(`≥5`)
          .fontSize(12)
          .fontColor(this.radioOn ? Theme.ON_ACCENT : Theme.TEXT_DIM)
      }
      .padding({ left: 8, right: 11, top: 6, bottom: 6 })
      .backgroundColor(this.radioOn ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(14)
      .margin({ right: 6, bottom: 8 })
      .onClick(() => {
        this.onRadio();
      })
    }
    .width('100%')
  }
}

/** 把 min2 / eq2 这类标识解析成 [min, max]。 */function band(minKey: string): number[] {
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
  /**
   * 结果页列数（2026-11-17 用户：「给结果页也加上列数」）。与媒体库页共用
   * 同一个偏好 `amaneCols` —— 在媒体库里捏合调过，这里自动跟着变，反之亦然。
   * 变化后重新切分 rows，而不是只改 columnsTemplate（这里用的是 Row 分组不是 Grid）。
   */
  @StorageProp('amaneCols') @Watch('onColsChange') posterCols: number = 3;
  @State total: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State femaleN: number[] = [];
  @State female5: boolean = false;
  @State maleN: number[] = [];
  @State male5: boolean = false;
  @State castN: string = '';
  /** 导演筛选：默认「只看这几位」，可切成「排除这几位」。 */
  @State dirs: DirectorHit[] = [];
  @State dirExclude: boolean = false;
  @State dirPicking: boolean = false;
  @State dirHits: DirectorHit[] = [];
  @State dirQuery: string = '';
  /** 服务端版本不够时的提示：旧服务端会静默忽略导演 / 人数集合参数。 */
  @State capsWarn: string = '';
  private dirTimer: number = -1;
  @State sortBy: string = 'release';
  @State order: string = 'desc';
  /** 条件抽屉与排序抽屉（2.4.6.26 起与媒体库同一套形状）。 */
  @State showSort: boolean = false;
  @State showFilter: boolean = false;
  /** 最近用过的条件（原始 JSON，最新的在前）；进页面自动恢复第一条。 */
  @State condHist: string[] = [];
  // ── 高级筛选：把媒体库那些筛选项搬进来（2026-11-17）────────────────────
  // 用户要求：「做一个专门的高级筛选，把筛选功能归一 —— 直接在原有的共演筛选这页做增量」。
  // 所以这里加的是 browse 有、共演页还没有的那几项，参数名与 browse 完全一致，
  // 服务端 `_cast_filter` 已经在 2.7.3.0 批次里补齐了同样的名字。
  @State fCtype: string = '';
  @State fMulti: string = '';
  @State fScore: string = '';
  @State fYear: string = '';
  /**
   * 分类维度（2026-11-17 重做）：标签 / 系列 / 制片商**互相独立、同时生效**。
   *
   * 之前只有一对 `facet_kind` + `facet_name`，选了标签就不能再选系列 —— 用户直接报
   * 「标签、系列、制片商应该是与的关系」。现在：
   *  - 标签：多选集合（一部片多个标签，`tag_id=` 多值 AND）；
   *  - 系列 / 制片商：各留一个名字槽（一部片只属于一个，单选即可）；
   * 三者一起下发，服务端 `_cast_filter` 里是并列的 where（AND）。
   */
  @State fSeries: string = '';
  @State fStudio: string = '';
  /** 联想搜索当前针对哪个维度：tag / series / studio。 */
  @State fKind: string = 'tag';
  /** 搜索框里的文字（与「已选」分开：打了字还没点候选时不算条件）。 */
  @State fKeyword: string = '';
  /**
   * 结果内关键词（2026-11-17 用户：「加个搜索框，在搜索结果里筛选符合条件的项」）。
   * 与 `fKeyword` 是两个东西：那个搜标签/系列候选，这个按番号/标题过滤**结果本身**。
   * 服务端 `_cast_filter` 已支持 `search=`（amane_rel 归一化：全角、大小写、缺连字符都能命中），
   * 这里只负责收词 + 去抖 + 下发，不用客户端自己做过滤（那样只滤到第一页）。
   */
  @State fSearch: string = '';
  @State onlySub: boolean = false;
  @State mosaic: string = '';
  @State picking: boolean = false;
  @State query: string = '';
  @State genderFilter: string = 'all';
  @State hits: ActorItem[] = [];
  /** 抽卡模式：按当前这套筛选条件抽随机剧照，替代结果列表。 */
  @State gachaOn: boolean = false;
  /** 我的评分 / 收藏夹：走服务端 cast_find 的同名参数。 */
  @State fMyRating: string = '';
  @State fCollection: string = '';
  // 2.6.1.78（用户 23:51）：「在某个指定媒体库搜共演」。
  // 服务端 `_cast_filter` 已支持 `library_id`（同时也让抽卡墙的 scope=cast 一起生效）。
  @State fLib: string = '';
  /** 媒体库多选（AND：同时出现在每个所选库里），2026-11-17 用户要求。 */
  @State fLibs: number[] = [];
  // ── 标签/系列/制片商 联想（2026-11-17）───────────────────────────────
  // 手输精确名太难用；改成输入即搜（`/api/user/facets/{kind}?search=`），
  // 候选点一下即选中。列表面板里不再要求「必须完全打对」。
  @State facetHits: FacetLite[] = [];
  /** 已选标签（点候选加入、点 chip 删除；发 `tag_id=` 多值 AND）。 */
  @State tagPicks: FacetLite[] = [];
  @State facetBusy: boolean = false;
  private facetTimer: number = -1;
  /** 结果内关键词去抖定时器（与 facet 联想的分开，避免互相清掉）。 */
  private resultSearchTimer: number = -1;
  @State libChoices: ChipOption[] = [{ key: '', label: '全部库' }];
  /** 媒体库卡片的数据（比一串文字 chips 直观：有封面、有片数）。 */
  @State libCards: LibItem[] = [];
  private searchTimer: number = -1;
  private sorts: SortOption[] = [
    { key: 'release', label: '发行时间', def: 'desc' },
    { key: 'number', label: '番号', def: 'asc' },
    { key: 'score', label: '评分', def: 'desc' },
    { key: 'runtime', label: '时长', def: 'desc' },
    { key: 'myrating', label: '我的评分', def: 'desc' }
  ];
  private mosaics: ChipOption[] = [
    { key: '', label: '不限' },
    { key: 'uncensored', label: '无码' },
    { key: 'cracked', label: '破解' },
    { key: 'leaked', label: '流出' }
  ];
  private casts: ChipOption[] = [
    { key: '', label: '总人数不限' },
    { key: 'min3', label: '≥3 人' },
    { key: 'min4', label: '≥4 人' },
    { key: 'min6', label: '≥6 人' },
    { key: 'min8', label: '≥8 人' }
  ];
  private genders: ChipOption[] = [
    { key: 'all', label: '全部' },
    { key: 'female', label: '女' },
    { key: 'male', label: '男' }
  ];

  aboutToAppear(): void {
    // 不预跑：无条件的全表聚合没意义，还会白等一次
    // 抽卡模式默认关（设置页开了「默认开启」才进）：这页本来就靠条件筛，
    // 无条件时抽卡等于抽全库，不适合当默认视图。
    this.gachaOn = BuildConfig.ENABLE_GACHA && Store.I.gachaAuto;
    // 上次的条件先恢复（2026-11-20）：用户报「每次点进来都要重新选」，
    // 这里把整页条件找回来，有条件就直接出结果，抽屉也不用自己弹出来。
    this.loadCondHist();
    this.restoreLast();
    // 2026-11-17 用户：「点进甄选、里面没有筛选项时，应该默认就把抽屉拉开，
    // 不要每次还要手动点一次按钮」。这个页面正就是为了筛东西才进来的，
    // 空条件时结果必然是全库（没价值），先让用户看到筛选面板才是对的。
    // 已有条件时保持收起——那种情况是回来改/看结果，不该再弹一次。
    this.showFilter = this.filterCount() === 0;
    this.seedLibsFromStore();
    this.loadLibs();
    // 恢复出来的条件直接查一次（否则界面停在「还没查」的空态）
    if (this.filterCount() > 0) {
      this.runQuery();
    }
  }

  // ─────────────────────────────── 条件记忆（2026-11-20）
  private condSnapshot(): CastCond {
    return {
      picked: this.picked,
      femaleN: this.femaleN,
      female5: this.female5,
      maleN: this.maleN,
      male5: this.male5,
      castN: this.castN,
      dirs: this.dirs,
      dirExclude: this.dirExclude,
      sortBy: this.sortBy,
      order: this.order,
      fCtype: this.fCtype,
      fMulti: this.fMulti,
      fScore: this.fScore,
      fYear: this.fYear,
      fSeries: this.fSeries,
      fStudio: this.fStudio,
      tagPicks: this.tagPicks,
      onlySub: this.onlySub,
      mosaic: this.mosaic,
      fMyRating: this.fMyRating,
      fCollection: this.fCollection,
      fLib: this.fLib,
      fLibs: this.fLibs,
      fSearch: this.fSearch,
      savedAt: Date.now()
    };
  }

  /** 判断「是不是同一套条件」的指纹：savedAt 不参与，否则每次都算新的。 */
  private condKey(c: CastCond): string {
    const ids = (arr: CastMember[]): string => {
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(`${arr[i].id}`);
      }
      return out.join(',');
    };
    const tagIds = (arr: FacetLite[]): string => {
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(`${arr[i].id}`);
      }
      return out.join(',');
    };
    const dirIds = (arr: DirectorHit[]): string => {
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(`${arr[i].id}`);
      }
      return out.join(',');
    };
    return [
      ids(c.picked), c.femaleN.join(','), `${c.female5}`,
      c.maleN.join(','), `${c.male5}`, c.castN,
      dirIds(c.dirs), `${c.dirExclude}`,
      c.fCtype, c.fMulti, c.fScore, c.fYear, c.fSeries, c.fStudio,
      tagIds(c.tagPicks), `${c.onlySub}`, c.mosaic,
      c.fMyRating, c.fCollection, c.fLib, c.fLibs.join(','), c.fSearch
    ].join('|');
  }

  /** 把当前条件记住（只在「有条件」时记，免得把上次那套好条件顶掉）。 */
  private saveCond(): void {
    if (this.filterCount() === 0 && this.fSearch.length === 0) {
      return;
    }
    const c: CastCond = this.condSnapshot();
    const key: string = this.condKey(c);
    const items: string[] = [JSON.stringify(c)];
    for (let i = 0; i < this.condHist.length && items.length < COND_HIST_MAX; i++) {
      try {
        const old: CastCond = JSON.parse(this.condHist[i]) as CastCond;
        if (this.condKey(old) !== key) {
          items.push(this.condHist[i]);
        }
      } catch (e) {
        // 坏数据直接丢
      }
    }
    Store.I.prefSetString(PREF_COND_LAST, JSON.stringify(c));
    Store.I.prefSetString(PREF_COND_HIST, JSON.stringify(items));
    this.condHist = items;
  }

  private applyCond(c: CastCond): void {
    this.picked = c.picked === undefined || c.picked === null ? [] : c.picked;
    this.femaleN = c.femaleN === undefined || c.femaleN === null ? [] : c.femaleN;
    this.female5 = c.female5 === true;
    this.maleN = c.maleN === undefined || c.maleN === null ? [] : c.maleN;
    this.male5 = c.male5 === true;
    this.castN = c.castN === undefined || c.castN === null ? '' : c.castN;
    this.dirs = c.dirs === undefined || c.dirs === null ? [] : c.dirs;
    this.dirExclude = c.dirExclude === true;
    this.sortBy = c.sortBy === undefined || c.sortBy === null ? 'release' : c.sortBy;
    this.order = c.order === undefined || c.order === null ? 'desc' : c.order;
    this.fCtype = c.fCtype === undefined || c.fCtype === null ? '' : c.fCtype;
    this.fMulti = c.fMulti === undefined || c.fMulti === null ? '' : c.fMulti;
    this.fScore = c.fScore === undefined || c.fScore === null ? '' : c.fScore;
    this.fYear = c.fYear === undefined || c.fYear === null ? '' : c.fYear;
    this.fSeries = c.fSeries === undefined || c.fSeries === null ? '' : c.fSeries;
    this.fStudio = c.fStudio === undefined || c.fStudio === null ? '' : c.fStudio;
    this.tagPicks = c.tagPicks === undefined || c.tagPicks === null ? [] : c.tagPicks;
    this.onlySub = c.onlySub === true;
    this.mosaic = c.mosaic === undefined || c.mosaic === null ? '' : c.mosaic;
    this.fMyRating = c.fMyRating === undefined || c.fMyRating === null ? '' : c.fMyRating;
    this.fCollection = c.fCollection === undefined || c.fCollection === null ? '' : c.fCollection;
    this.fLib = c.fLib === undefined || c.fLib === null ? '' : c.fLib;
    this.fLibs = c.fLibs === undefined || c.fLibs === null ? [] : c.fLibs;
    this.fSearch = c.fSearch === undefined || c.fSearch === null ? '' : c.fSearch;
  }

  private restoreLast(): void {
    const raw: string = Store.I.prefString(PREF_COND_LAST, '');
    if (raw.length === 0) {
      return;
    }
    try {
      this.applyCond(JSON.parse(raw) as CastCond);
    } catch (e) {
      // 格式变了就当没存过
    }
  }

  private loadCondHist(): void {
    const raw: string = Store.I.prefString(PREF_COND_HIST, '');
    if (raw.length === 0) {
      this.condHist = [];
      return;
    }
    try {
      const arr: CastCond[] = JSON.parse(raw) as CastCond[];
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(JSON.stringify(arr[i]));
      }
      this.condHist = out;
    } catch (e) {
      this.condHist = [];
    }
  }

  /** 抽屉里那颗 chip 的文字：只挑最能说明问题的那几项。 */
  private condLabel(c: CastCond): string {
    const parts: string[] = [];
    if (c.picked !== undefined && c.picked !== null && c.picked.length > 0) {
      const extra: number = c.picked.length - 1;
      parts.push(extra > 0 ? `${c.picked[0].name}+${extra}` : c.picked[0].name);
    }
    if (c.female5 === true) {
      parts.push('女≥5');
    } else if (c.femaleN !== undefined && c.femaleN !== null && c.femaleN.length > 0) {
      parts.push(`女${c.femaleN.join('/')}`);
    }
    if (c.male5 === true) {
      parts.push('男≥5');
    } else if (c.maleN !== undefined && c.maleN !== null && c.maleN.length > 0) {
      parts.push(`男${c.maleN.join('/')}`);
    }
    if (c.castN !== undefined && c.castN !== null && c.castN.length > 0) {
      parts.push(`共演${c.castN}`);
    }
    if (c.onlySub === true) {
      parts.push('有字幕');
    }
    if (c.mosaic !== undefined && c.mosaic !== null && c.mosaic.length > 0) {
      parts.push(c.mosaic === 'uncensored' ? '无码' : (c.mosaic === 'cracked' ? '破解' : '流出'));
    }
    if (c.fSeries !== undefined && c.fSeries !== null && c.fSeries.length > 0) {
      parts.push(c.fSeries);
    }
    if (c.fStudio !== undefined && c.fStudio !== null && c.fStudio.length > 0) {
      parts.push(c.fStudio);
    }
    if (c.tagPicks !== undefined && c.tagPicks !== null && c.tagPicks.length > 0) {
      parts.push(`标签${c.tagPicks.length}`);
    }
    if (c.dirs !== undefined && c.dirs !== null && c.dirs.length > 0) {
      parts.push(`导${c.dirs.length}`);
    }
    if (c.fSearch !== undefined && c.fSearch !== null && c.fSearch.length > 0) {
      parts.push(`“${c.fSearch}”`);
    }
    return parts.length === 0 ? '无条件' : parts.join(' · ');
  }

  /**
   * 先用 config 里那份库列表铺上（首页 / 媒体库页用的就是它）。
   *
   * 联网那次请求只用来补封面与片数：**请求失败时不能让这排卡全空**——
   * 2026-11-17 用户报「高级筛选页里只有全部库」，根子是横滑 Scroll 没给高度；
   * 这里顺带把这个页面唯一的网络依赖也去掉，别让一个可选的刷新决定能不能选库。
   */
  private seedLibsFromStore(): void {
    const src: LibraryInfo[] = Store.I.libraries;
    if (src.length === 0) {
      return;
    }
    const out: LibItem[] = [];
    for (let i = 0; i < src.length; i++) {
      const it: LibraryInfo = src[i];
      out.push({
        id: it.id,
        name: it.name,
        count: it.count,
        cover: it.cover === undefined ? '' : it.cover
      });
    }
    this.libCards = out;
  }

  /** 媒体库列表（给「在哪个库里搜共演」用）。失败就保持只有「全部库」，不影响主流程。 */
  private async loadLibs(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/libraries`, Store.I.token);
      const r = JSON.parse(text) as LibResp;
      const items: LibItem[] = r.items === undefined || r.items === null ? [] : r.items;
      // 空响应不要覆盖 seedLibsFromStore() 铺好的那份（封面是可选信息，不能反过来把库弄没）
      if (items.length > 0) {
        this.libCards = items;
      }
      const out: ChipOption[] = [{ key: '', label: '全部库' }];
      for (let i = 0; i < items.length; i++) {
        const it: LibItem = items[i];
        out.push({ key: `${it.id}`, label: `${it.name}` });
      }
      this.libChoices = out;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] cast libs: ${e.code}`);
    }
  }

  /**
   * 一张媒体库卡（2.6.1.83 · 用户 23:59：「参照媒体库那套布局」）。
   *
   * 之前是一行文字 chips，塞在男女演员人数和总人数中间，看着像又一个数字条件，
   * 完全看不出「这是先选哪个库」。改成和首页媒体库同一种卡：**封面 / 首字 + 名字 + 片数**，
   * 选中描一圈金色 —— 一眼就知道自己在哪个库里找。
   */
  @Builder
  LibTile(id: number, name: string, count: number, cover: string) {
    Column() {
      // 2026-11-17 用户：「库这里很好，但留了封面图的位置又没有封面图」——
      // 之前无论有没有封面都先摆一个 64dp 方块，没封面就塞个首字，看着像「空图位」。
      // 现在：有真封面才渲染图片；没有就整块不出现，卡片退化成居中的「✓名字 / 片数」
      // 文字卡，外层统一描边和圆角，横排高度一致、也不再有空方块。
      if (cover.length > 0) {
        Column({ space: 3 }) {
          Stack() {
            Image(Store.I.img(cover))
              .width('100%')
              .height(64)
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
            if (id > 0 && this.libOn(id)) {
              Text('✓')
                .fontSize(9)
                .fontColor(Theme.ON_ACCENT)
                .width(16)
                .height(16)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
                .position({ x: 58, y: 2 })
            }
          }
          .width('100%')
          .height(64)
          Text(name)
            .fontSize(11)
            .fontColor(this.libOn(id) ? Theme.GOLD : Theme.TEXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
          Text(count > 0 ? `${count}` : '空')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      } else {
        Column({ space: 3 }) {
          Row({ space: 3 }) {
            if (id > 0 && this.libOn(id)) {
              Text('✓')
                .fontSize(10)
                .fontColor(Theme.ON_ACCENT)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(7)
                .padding({ left: 4, right: 4 })
            }
            Text(name)
              .fontSize(11)
              .fontWeight(this.libOn(id) ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.libOn(id) ? Theme.GOLD : Theme.TEXT)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          Text(count > 0 ? `${count}` : '空')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(78)
    .height(LIB_STRIP_H - 12)
    .padding(6)
    .borderRadius(10)
    .backgroundColor(cover.length > 0 ? Color.Transparent : Theme.CARD_HI)
    .border({
      width: this.libOn(id) ? 2 : 1,
      color: this.libOn(id) ? Theme.ACCENT : '#1FFFFFFF'
    })
    .onClick(() => {
      if (id <= 0) {
        // 「全部库」= 清空多选
        this.fLibs = [];
      } else {
        const next: number[] = [];
        let hit: boolean = false;
        for (let i = 0; i < this.fLibs.length; i++) {
          if (this.fLibs[i] === id) {
            hit = true;
          } else {
            next.push(this.fLibs[i]);
          }
        }
        if (!hit) {
          next.push(id);
        }
        this.fLibs = next;
      }
      this.runQuery();
    })
  }

  /** 标签集合：点候选加入、再点取消；发 `tag_id=` 多值（服务端按 AND 求交）。 */
  private toggleTag(f: FacetLite): void {
    const next: FacetLite[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.tagPicks.length; i++) {
      if (this.tagPicks[i].id === f.id) {
        hit = true;
      } else {
        next.push(this.tagPicks[i]);
      }
    }
    if (!hit) {
      next.push(f);
    }
    this.tagPicks = next;
    // 候选列表**留着**（2026-11-17）：标签是多选，加完一个常常要接着加下一个，
    // 每次清空就得重新打字。系列/制片商是单选，在 pickFacet 里才清。
    this.runQuery();
  }

  private tagOn(id: number): boolean {
    for (let i = 0; i < this.tagPicks.length; i++) {
      if (this.tagPicks[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 点联想候选（2026-11-17 统一入口）。
   *
   * 三个维度的行为不同，但都收在同一个抽屉里：
   *  - 标签：加入 / 移出集合（一部片多个标签，语义是「同时带这几个」）；
   *  - 系列、制片商：覆盖那一个名字槽（一部片只属于一个），再点同一个则取消。
   */
  private pickFacet(f: FacetLite): void {
    if (this.fKind === 'tag') {
      this.toggleTag(f);
      return;
    }
    if (this.fKind === 'series') {
      this.fSeries = this.fSeries === f.name ? '' : f.name;
    } else if (this.fKind === 'studio') {
      this.fStudio = this.fStudio === f.name ? '' : f.name;
    }
    this.facetHits = [];
    this.fKeyword = '';
    this.runQuery();
  }

  /** 已选的分类条数（标签算多条，系列/制片商各一条）—— 面板标题上回显用。 */
  private facetPickedCount(): number {
    let n: number = this.tagPicks.length;
    if (this.fSeries.length > 0) {
      n++;
    }
    if (this.fStudio.length > 0) {
      n++;
    }
    return n;
  }

  /** 三个维度都没选时，标题右侧显示「不限」。 */
  private facetSummary(): string {
    const n: number = this.facetPickedCount();
    return n > 0 ? `已选 ${n} 项 · 同时满足` : '不限';
  }

  /** 联想候选里这一条是否已经被选中（三种维度各自的判断）。 */
  private facetOn(f: FacetLite): boolean {
    if (this.fKind === 'tag') {
      return this.tagOn(f.id);
    }
    if (this.fKind === 'series') {
      return this.fSeries === f.name;
    }
    return this.fStudio === f.name;
  }

  /** 搜索框提示语跟着维度变，不然用户不知道现在在搜什么。 */
  private facetPlaceholder(): string {
    if (this.fKind === 'series') {
      return '搜系列名，点候选选中（可与标签同时用）';
    }
    if (this.fKind === 'studio') {
      return '搜制片商名，点候选选中（可与标签同时用）';
    }
    return '搜标签名，点候选加入（可多选，同时满足）';
  }

  /** 某个 chip 组的 key 对应文案（摘要回显用）。 */
  private labelOf(opts: ChipOption[], key: string): string {
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].key === key) {
        return opts[i].label;
      }
    }
    return '';
  }

  /** 人数摘要：「1/2女 · ≥3人」。 */
  private castSummary(): string {
    const bits: string[] = [];
    if (this.female5) {
      bits.push('≥5女');
    } else if (this.femaleN.length > 0) {
      bits.push(`${this.femaleN.join('/')}女`);
    }
    if (this.male5) {
      bits.push('≥5男');
    } else if (this.maleN.length > 0) {
      bits.push(`${this.maleN.join('/')}男`);
    }
    if (this.castN.length > 0) {
      bits.push(this.labelOf(this.casts, this.castN));
    }
    return bits.length > 0 ? bits.join(' · ') : '不限';
  }

  /** 「更多条件」摘要：类型/版本/评分/年份里设过的那些。 */
  private moreSummary(): string {
    const bits: string[] = [];
    if (this.fCtype.length > 0) {
      bits.push(this.labelOf(CTYPE_CHOICES, this.fCtype));
    }
    if (this.fMulti.length > 0) {
      bits.push(this.labelOf(VERSION_CHOICES, this.fMulti));
    }
    if (this.fScore.length > 0) {
      bits.push(this.labelOf(SCORE_CHOICES, this.fScore));
    }
    if (this.fYear.length > 0) {
      bits.push(this.labelOf(YEAR_CHOICES, this.fYear));
    }
    return bits.length > 0 ? bits.join(' · ') : '不限';
  }

  /** 这个库是否被选中（多选 AND，2026-11-17）。 */  private libOn(id: number): boolean {
    if (id <= 0) {
      return this.fLibs.length === 0;
    }
    for (let i = 0; i < this.fLibs.length; i++) {
      if (this.fLibs[i] === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 分类输入：停下来 220ms 再去搜（每敲一个字就请求会把服务端打爆，也拖手）。
   * 空输入直接清候选，避免「刚清空又弹一堆」。
   */
  private onFacetInput(v: string): void {
    this.fKeyword = v;
    if (this.facetTimer >= 0) {
      clearTimeout(this.facetTimer);
      this.facetTimer = -1;
    }
    if (v.trim().length === 0) {
      this.facetHits = [];
      return;
    }
    this.facetTimer = setTimeout(() => {
      this.facetTimer = -1;
      this.searchFacet();
    }, 220);
  }

  /**
   * 结果内关键词：输入即筛，350ms 去抖（和联想一致的手感，别每敲一个字打一次库）。
   * 走 runQuery() 整页重查 —— search 参数在服务端 WHERE 里，必须让 total / 分页一起变。
   */
  private onResultSearch(v: string): void {
    this.fSearch = v;
    if (this.resultSearchTimer >= 0) {
      clearTimeout(this.resultSearchTimer);
      this.resultSearchTimer = -1;
    }
    this.resultSearchTimer = setTimeout(() => {
      this.resultSearchTimer = -1;
      this.runQuery();
    }, 350);
  }

  /** 按当前维度 + 关键词去拉候选（走扩展的 facets 列表，支持 search）。 */
  private async searchFacet(): Promise<void> {
    const kind: string = this.fKind;
    if (kind.length === 0) {
      return;
    }
    const kw: string = this.fKeyword.trim();
    if (kw.length === 0) {
      this.facetHits = [];
      return;
    }
    this.facetBusy = true;
    try {
      const url: string = `${Store.I.user}/api/user/facets/${kind}` +
        `?search=${encodeURIComponent(kw)}&limit=12&sort_by=count&order=desc`;
      const text: string = await httpGet(url, Store.I.token);
      const data: FacetPage = JSON.parse(text) as FacetPage;
      const rows: FacetRow[] = data.items === undefined ? [] : data.items;
      const out: FacetLite[] = [];
      for (let i = 0; i < rows.length; i++) {
        out.push({ id: rows[i].id, name: rows[i].name, count: rows[i].count });
      }
      this.facetHits = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet suggest: ${e.code} ${e.message}`);
      this.facetHits = [];
    }
    this.facetBusy = false;
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (this.dirTimer >= 0) {
      clearTimeout(this.dirTimer);
      this.dirTimer = -1;
    }
    if (this.resultSearchTimer >= 0) {
      clearTimeout(this.resultSearchTimer);
      this.resultSearchTimer = -1;
    }
  }

  /** 女/男人数条件：多选集合走 female_n/male_n（「或」），≥5 走区间。 */
  private hasFemale(): boolean {
    return this.femaleN.length > 0 || this.female5;
  }

  private hasMale(): boolean {
    return this.maleN.length > 0 || this.male5;
  }

  /**
   * 只拼筛选条件（不含分页 / 排序）。
   * 结果列表与抽卡墙共用这一份 —— 页面上筛了什么，抽卡就抽什么。
   */
  private filterQuery(): string {
    const parts: string[] = [];
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
    // 导演：包含 / 排除二选一，多选用「或」（选两个导演 = 这两人的片子合集）
    if (this.dirs.length > 0) {
      const ids: string[] = [];
      for (let i = 0; i < this.dirs.length; i++) {
        ids.push(`${this.dirs[i].id}`);
      }
      parts.push(`${this.dirExclude ? 'exclude_director_id' : 'director_id'}=${ids.join(',')}`);
    }
    if (this.female5) {
      parts.push('female_min=5');
      parts.push('female_max=99');
    } else if (this.femaleN.length > 0) {
      parts.push(`female_n=${this.femaleN.join(',')}`);
    }
    if (this.male5) {
      parts.push('male_min=5');
      parts.push('male_max=99');
    } else if (this.maleN.length > 0) {
      parts.push(`male_n=${this.maleN.join(',')}`);
    }
    const c: number[] = band(this.castN);
    if (c[0] > 0 || c[1] < 99) {
      parts.push(`cast_min=${c[0]}`);
      parts.push(`cast_max=${c[1]}`);
    }
    if (this.fMyRating.length > 0) {
      parts.push(`myrating=${this.fMyRating}`);
    }
    if (this.fCollection.length > 0) {
      parts.push(`collection=${this.fCollection}`);
    }
    if (this.fLibs.length > 0) {
      // 多选 AND（与媒体库同一语义）：每加一个库结果只会更少
      const ids: string[] = [];
      for (let i = 0; i < this.fLibs.length; i++) {
        ids.push(`${this.fLibs[i]}`);
      }
      parts.push(`libs=${ids.join(',')}`);
      // 兼容老服务端（< 2.8.0）：它们只认单库 `library_id`，遇到 `libs` 不报错、
      // 直接把条件丢掉，界面看起来就是「筛了还是全部影片」（2026-11-18 实测 8770）。
      // 单选时两个参数一起发 —— 新服务端按 AND 求交，同一个库结果不变；老服务端认后一个。
      if (this.fLibs.length === 1) {
        parts.push(`library_id=${this.fLibs[0]}`);
      }
    } else if (this.fLib.length > 0) {
      parts.push(`library_id=${this.fLib}`);
    }
    // 与媒体库同一套（2026-11-17 补齐）
    if (this.fCtype.length > 0) {
      parts.push(`ctype=${this.fCtype}`);
    }
    if (this.fMulti.length > 0) {
      parts.push(`multi=${this.fMulti}`);
    }
    if (this.fScore.length > 0) {
      parts.push(`min_score=${this.fScore}`);
    }
    if (this.fYear === 'old') {
      parts.push('year_to=2023');
    } else if (this.fYear.length > 0) {
      parts.push(`year_from=${this.fYear}`);
    }
    // 标签 / 系列 / 制片商：三个维度**各自独立、同时生效（AND）**（2026-11-17）
    if (this.tagPicks.length > 0) {
      const ids: string[] = [];
      for (let i = 0; i < this.tagPicks.length; i++) {
        ids.push(`${this.tagPicks[i].id}`);
      }
      parts.push(`tag_id=${ids.join(',')}`);
    }
    if (this.fSeries.length > 0) {
      parts.push(`series_name=${encodeURIComponent(this.fSeries)}`);
    }
    if (this.fStudio.length > 0) {
      parts.push(`studio_name=${encodeURIComponent(this.fStudio)}`);
    }
    // 结果内关键词：番号 / 标题（服务端 amane_rel 归一化匹配，与其余条件 AND）
    const kw: string = this.fSearch.trim();
    if (kw.length > 0) {
      parts.push(`search=${encodeURIComponent(kw)}`);
    }
    return parts.join('&');
  }

  private buildUrl(offset: number): string {
    const parts: string[] = [
      `offset=${offset}`, `limit=${PAGE}`,
      `sort_by=${this.sortBy}`, `order=${this.order}`
    ];
    const filter: string = this.filterQuery();
    if (filter.length > 0) {
      parts.push(filter);
    }
    return `${Store.I.user}/api/user/cast/find?${parts.join('&')}`;
  }

  private runQuery(): void {
    this.seq++;
    // 每次真正查询前记一套条件：下次进页面自动恢复，抽屉里也能点回最近几套
    this.saveCond();
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
      this.checkCaps(r);
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

  /**
   * 老服务端（< 1.3.8）不认识 `director_id` / `female_n` / `male_n`，
   * 不会报错、也不会回显，只会把条件丢掉返回全库 —— 页面看起来就像「筛选没生效」。
   * 用回显字段判断一次，直接把话说清楚，别让人怀疑是客户端坏了。
   */
  private checkCaps(r: CastFindList): void {
    const needDir: boolean = this.dirs.length > 0;
    const needSet: boolean = this.femaleN.length > 0 || this.maleN.length > 0;
    const dirIgnored: boolean = needDir && r.director_id.length === 0;
    const setIgnored: boolean = needSet && r.female_n.length === 0 && r.male_n.length === 0;
    this.capsWarn = (dirIgnored || setIgnored)
      ? '当前服务端 < 1.3.8：导演筛选与人数多选被忽略了，下面是全库结果（升级服务端后自动生效）'
      : '';
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

  /** 列数偏好变了：按新列数重切已加载的结果，不用重新发请求。 */
  private onColsChange(): void {
    this.rows = this.chunk(this.results);
  }

  private chunk(list: CastFindItem[]): CastFindItem[][] {
    const out: CastFindItem[][] = [];
    let row: CastFindItem[] = [];
    // 2026-11-17：跟媒体库共用列数偏好（2/3/4）。边界夹一下，
    // 免得 AppStorage 里残留异常值导致每行 0 个、结果全不渲染。
    const n: number = Math.min(4, Math.max(2, this.posterCols));
    for (let i = 0; i < list.length; i++) {
      row.push(list[i]);
      if (row.length === n) {
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
   * 头像尺寸按人数 + 列数收缩。
   * 2026-11-17 用户：「演员头像调小一点点」——原来 84/64 dp 在两列大卡上还行，
   * 现在列数可切到 3/4，卡变窄，头像跟着列数递减，才不会挤爆卡片。
   * 人数多（≥3）再降一档，避免一排头像顶出右边界。
   */
  private avSize(x: CastFindItem): number {
    const n: number = this.castToShow(x).length;
    const cols: number = Math.min(4, Math.max(2, this.posterCols));
    // 基准：2 列 72、3 列 60、4 列 52；人多再减 10。
    const base: number = cols >= 4 ? 52 : (cols >= 3 ? 60 : 72);
    return n >= 3 ? base - 10 : base;
  }

  private avOverlap(x: CastFindItem): number {
    return this.castToShow(x).length >= 3 ? -10 : -13;
  }

  /** 我给这部片打的分（0 = 没打过）；老服务端不返回该字段，兜成 0。 */
  private cellMyRating(x: CastFindItem): number {
    const v: number = x.my_rating === undefined ? 0 : x.my_rating;
    return v > 0 ? Math.min(5, Math.trunc(v)) : 0;
  }

  private castToShow(x: CastFindItem): CastMember[] {
    const wantFemale: boolean = this.hasFemale() && !this.hasMale();
    const wantMale: boolean = this.hasMale() && !this.hasFemale();
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
    if (this.female5) {
      parts.push('≥5女');
    } else if (this.femaleN.length > 0) {
      const nums: string[] = [];
      for (let i = 0; i < this.femaleN.length; i++) {
        nums.push(`${this.femaleN[i]}女`);
      }
      parts.push(nums.join('/'));
    }
    if (this.male5) {
      parts.push('≥5男');
    } else if (this.maleN.length > 0) {
      const nums: string[] = [];
      for (let i = 0; i < this.maleN.length; i++) {
        nums.push(`${this.maleN[i]}男`);
      }
      parts.push(nums.join('/'));
    }
    if (this.castN.length > 0) {
      for (let i = 0; i < this.casts.length; i++) {
        if (this.casts[i].key === this.castN) {
          parts.push(this.casts[i].label);
        }
      }
    }
    if (this.dirs.length > 0) {
      const names: string[] = [];
      for (let i = 0; i < this.dirs.length; i++) {
        names.push(this.dirs[i].name);
      }
      parts.push(`${this.dirExclude ? '排除导演' : '只看导演'} ${names.join('/')}`);
    }
    // 字幕 / 版本也是筛选条件，摘要里必须出现：
    // 抽卡墙把这段文字当范围标题，漏了就会「明明勾了有字幕，标题只写 1女/2女」
    if (this.onlySub) {
      parts.push('有字幕');
    }
    if (this.mosaic.length > 0) {
      for (let i = 0; i < this.mosaics.length; i++) {
        if (this.mosaics[i].key === this.mosaic) {
          parts.push(this.mosaics[i].label);
        }
      }
    }
    return parts.length > 0 ? parts.join(' · ') : '全部作品';
  }

  /** 方形多选：勾上就加，再点取消；勾多选时 ≥5 的圆形会自动弹起。 */
  private toggleSize(list: number[], v: number): number[] {
    const next: number[] = [];
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i] === v) {
        found = true;
      } else {
        next.push(list[i]);
      }
    }
    if (!found) {
      next.push(v);
    }
    next.sort((a: number, b: number) => a - b);
    return next;
  }

  private pickFemale(v: number): void {
    this.femaleN = this.toggleSize(this.femaleN, v);
    this.female5 = false;
    this.runQuery();
  }

  private pickMale(v: number): void {
    this.maleN = this.toggleSize(this.maleN, v);
    this.male5 = false;
    this.runQuery();
  }

  private pickFemale5(): void {
    this.female5 = !this.female5;
    if (this.female5) {
      this.femaleN = [];
    }
    this.runQuery();
  }

  private pickMale5(): void {
    this.male5 = !this.male5;
    if (this.male5) {
      this.maleN = [];
    }
    this.runQuery();
  }

  private isDirPicked(id: number): boolean {
    for (let i = 0; i < this.dirs.length; i++) {
      if (this.dirs[i].id === id) {
        return true;
      }
    }
    return false;
  }

  private toggleDir(d: DirectorHit): void {
    if (this.isDirPicked(d.id)) {
      const next: DirectorHit[] = [];
      for (let i = 0; i < this.dirs.length; i++) {
        if (this.dirs[i].id !== d.id) {
          next.push(this.dirs[i]);
        }
      }
      this.dirs = next;
    } else {
      if (this.dirs.length >= 8) {
        return;
      }
      this.dirs = this.dirs.concat([d]);
    }
    this.runQuery();
  }

  /** 导演候选来自分类接口（/api/user/facets/director），演员接口里没有导演。 */
  private async doDirSearch(): Promise<void> {
    const kw: string = this.dirQuery.trim();
    const url: string = `${Store.I.user}/api/user/facets/director` +
      `?limit=20&sort_by=count&order=desc&search=${encodeURIComponent(kw)}`;
    try {
      const text: string = await httpGet(url, Store.I.token);
      this.dirHits = safeDirectorHits(JSON.parse(text) as DirectorHitList);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] director picker: ${e.code} ${e.message}`);
    }
  }

  private onDirSearch(value: string): void {
    if (this.dirTimer >= 0) {
      clearTimeout(this.dirTimer);
      this.dirTimer = -1;
    }
    const q: string = value;
    this.dirTimer = setTimeout(() => {
      this.dirTimer = -1;
      this.dirQuery = q;
      this.doDirSearch();
    }, 320);
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
      const m: CastMember = { id: a.id, name: a.name, gender: a.gender, avatar: a.avatar, age: 0 };
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
      GlassBack({
        onTap: () => {
        router.back();
        }
      })
      Column({ space: 3 }) {
        PageTitle({ text: '甄选', fs: 18 })
        Text(this.total > 0 ? `${this.total} 部符合条件` : '演员 / 人数 / 标签 / 番号… 一处全筛')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: 10, bottom: 2 })
  }

  private sortLabel(): string {
    for (let i = 0; i < this.sorts.length; i++) {
      if (this.sorts[i].key === this.sortBy) {
        return this.sorts[i].label;
      }
    }
    return '发行时间';
  }

  private filterCount(): number {
    let n: number = 0;
    if (this.picked.length > 0) {
      n++;
    }
    if (this.hasFemale()) {
      n++;
    }
    if (this.hasMale()) {
      n++;
    }
    if (this.castN.length > 0) {
      n++;
    }
    if (this.dirs.length > 0) {
      n++;
    }
    if (this.onlySub) {
      n++;
    }
    if (this.mosaic.length > 0) {
      n++;
    }
    if (this.fMyRating.length > 0) {
      n++;
    }
    if (this.fCollection.length > 0) {
      n++;
    }
    // 2026-11-17：补上「更多条件」与分类/媒体库 —— 之前它们生效了但不计数，
    // 看着像「筛选了却显示 0」，用户没法确认条件有没有下发。
    if (this.fCtype.length > 0) {
      n++;
    }
    if (this.fMulti.length > 0) {
      n++;
    }
    if (this.fScore.length > 0) {
      n++;
    }
    if (this.fYear.length > 0) {
      n++;
    }
    if (this.fLibs.length > 0) {
      n++;
    }
    if (this.fSearch.trim().length > 0) {
      n++;
    }
    n += this.facetPickedCount();
    return n;
  }

  private clearAll(): void {
    this.picked = [];
    this.femaleN = [];
    this.female5 = false;
    this.maleN = [];
    this.male5 = false;
    this.castN = '';
    this.dirs = [];
    this.onlySub = false;
    this.mosaic = '';
    this.fMyRating = '';
    this.fCollection = '';
    this.fCtype = '';
    this.fMulti = '';
    this.fScore = '';
    this.fYear = '';
    this.fSeries = '';
    this.fStudio = '';
    this.fKeyword = '';
    this.facetHits = [];
    this.tagPicks = [];
    this.fLibs = [];
    this.fSearch = '';
    if (this.resultSearchTimer >= 0) {
      clearTimeout(this.resultSearchTimer);
      this.resultSearchTimer = -1;
    }
    this.runQuery();
  }

  @Builder
  Toolbar() {
    Row({ space: 8 }) {
      Text(this.total > 0 ? `${this.total} 部符合条件` : '设定条件，开始甄选')
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
        .maxLines(1)
        .layoutWeight(1)

      if (BuildConfig.ENABLE_GACHA) {
        GachaSwitch({
          on: this.gachaOn,
          onToggle: (v: boolean) => {
            this.gachaOn = v;
          }
        })
      }

      ToolPill({
        label: `⇅ ${this.sortLabel()}${this.order === 'asc' ? ' ↑' : ' ↓'}`,
        onTap: () => {
          this.showSort = true;
        }
      })

      ToolPill({
        label: this.filterCount() > 0 ? `甄选 ${this.filterCount()}` : '甄选',
        active: this.filterCount() > 0,
        onTap: () => {
          this.showFilter = true;
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 2, bottom: 8 })
  }

  @Builder
  FilterSheet() {
    BottomSheet({
      title: '甄选',
      actionLabel: '清空',
      onAction: () => {
        this.clearAll();
      },
      onConfirm: () => {
        this.showFilter = false;
      },
      sheetHeight: '88%'
    }) {
      // 三段归序（2026-11-17 一体化）：找谁 / 按什么条件 / 我的偏好。
      // 原来是 8 组无归类地平铺，用户说「无序拼贴、使用起来很不对劲」。
      // 最近用过的条件放最上面（2026-11-20）：一进来就能点回上次那套，不用重选。
      this.CondHist()
      SectionHead({ index: '01', label: '找谁 · 范围' })
      this.Picked()
      this.DirectorBar()
      this.LibSection()

      SectionHead({ index: '02', label: '按什么条件' })
      this.ResultSearch()
      this.CountSection()
      this.FacetSection()
      this.MoreSection()
      this.ExtraSection()

      SectionHead({ index: '03', label: '我的偏好' })
      this.MineSection()
      Blank().height(20)
    }
  }

  /**
   * 指定演员。
   *
   * 外壳统一交给 `SheetSection`（同一张卡片、同一个标题基线、同一个「+ 添加」胶囊），
   * 这里只画内容：已选头像 + 选人抽屉。
   */
  /**
   * 最近用过的条件（2026-11-20 用户：「每次点进来都要重新选」）。
   *
   * 放在筛选抽屉最上面：点一条就把整套条件装回来并立刻重查 —— 比重新一项项点快得多。
   * 进页面时已经自动恢复最后一条，这里主要是给「想换个之前用过的组合」用。
   */
  @Builder
  CondHist() {
    if (this.condHist.length > 0) {
      Column({ space: 6 }) {
        Text('最近用过的条件')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.condHist, (json: string) => {
            Text(this.condLabel(JSON.parse(json) as CastCond))
              .fontSize(11)
              .fontColor(Theme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ right: 6, bottom: 6 })
              .borderRadius(9)
              .backgroundColor(Theme.CARD_HI)
              .onClick(() => {
                this.applyCond(JSON.parse(json) as CastCond);
                this.runQuery();
                this.showFilter = false;
              })
          }, (json: string) => json)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 6 })
    }
  }

  @Builder
  Picked() {
    SheetSection({
      title: '指定演员',
      value: this.picked.length > 0 ? `${this.picked.length}/6 · 同时出演` : '不指定',
      active: this.picked.length > 0,
      actionLabel: this.picking ? '收起' : '+ 添加',
      onAction: () => {
        this.picking = !this.picking;
        if (this.picking && this.hits.length === 0) {
          this.doSearch();
        }
      }
    }) {
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
          .height(36)
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 11 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
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
                    .width(24)
                    .height(24)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(12)
                    .backgroundColor(Theme.CARD_HI)
                }
                Text(a.name)
                  .fontSize(12)
                  .fontColor(this.isPicked(a.id) ? Theme.ON_ACCENT : Theme.TEXT_DIM)
                  .maxLines(1)
              }
              .padding({ left: 5, right: 10, top: 4, bottom: 4 })
              .backgroundColor(this.isPicked(a.id) ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
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
      } else if (this.picked.length === 0) {
        Text('选几位演员，找他们同时出演的片；不选则只按下面的条件筛')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
  }

  /**
   * 结果内关键词：在已筛出的结果里按番号 / 标题再搜一遍。
   *
   * 与顶部「搜索演员名」分工：那个找演员（点进来是选人），这个过滤结果本身。
   * 放在「按什么条件」第一段 —— 用户打完字，下面所有条件都在这个子集上叠加。
   */
  @Builder
  ResultSearch() {
    SheetSection({
      title: '番号 / 标题',
      value: this.fSearch.trim().length > 0 ? this.fSearch.trim() : '在结果里再搜',
      active: this.fSearch.trim().length > 0
    }) {
      TextInput({ text: this.fSearch, placeholder: '输入番号或标题，边打边筛' })
        .height(36)
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 11 })
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((v: string) => {
          this.onResultSearch(v);
        })
    }
  }

  /** 人数：女 / 男 / 总计（方形=多选、圆形=≥5 阈值，语义见 CountPicker）。 */
  @Builder
  CountSection() {
    SheetSection({
      title: '按人数找',
      value: this.castSummary(),
      active: this.hasFemale() || this.hasMale() || this.castN.length > 0
    }) {
      CountPicker({
        label: '女演员',
        unit: '女',
        floor: 1,
        multi: this.femaleN,
        radioOn: this.female5,
        onToggle: (v: number) => {
          this.pickFemale(v);
        },
        onRadio: () => {
          this.pickFemale5();
        },
        onClear: () => {
          this.femaleN = [];
          this.female5 = false;
          this.runQuery();
        }
      })

      CountPicker({
        label: '男演员',
        unit: '男',
        floor: 0,
        multi: this.maleN,
        radioOn: this.male5,
        onToggle: (v: number) => {
          this.pickMale(v);
        },
        onRadio: () => {
          this.pickMale5();
        },
        onClear: () => {
          this.maleN = [];
          this.male5 = false;
          this.runQuery();
        }
      })

      PickChips({
        title: '总人数',
        options: this.casts,
        current: this.castN,
        onPick: (key: string) => {
          this.castN = key;
          this.runQuery();
        }
      })
    }
  }

  /** 媒体库（多选 AND：同时出现在每个所选库里）。 */
  @Builder
  LibSection() {
    SheetSection({
      title: '在哪个库里找',
      value: this.fLibs.length > 0 ? `已选 ${this.fLibs.length} 个库 · 同时拥有` : '全部库',
      active: this.fLibs.length > 0
    }) {
      Scroll() {
        Row({ space: 8 }) {
          this.LibTile(0, '全部库', 0, '')
          ForEach(this.libCards, (it: LibItem) => {
            this.LibTile(it.id, it.name, it.count, it.cover)
          }, (it: LibItem) => `${it.id}`)
        }
        .padding({ right: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      // 必须给高度，否则整排卡塌成 0（只剩标题右边的「全部库」文案）
      .height(LIB_STRIP_H)
    }
  }

  /**
   * 分类：标签 / 系列 / 制片商。
   *
   * 2026-11-17 用户要求「三者是与的关系」——所以不是一个维度下拉 + 一个名字框，
   * 而是三个维度各自记条件、同时下发；上面选维度只决定「搜索框在搜谁」，
   * 下面那一排已选胶囊才是真正的条件（点即删）。
   */
  @Builder
  FacetSection() {
    SheetSection({
      title: '标签 / 系列 / 制片商',
      value: this.facetSummary(),
      active: this.facetPickedCount() > 0
    }) {
      PickChips({
        options: FACET_KINDS,
        current: this.fKind,
        onPick: (key: string) => {
          this.fKind = key;
          this.fKeyword = '';
          this.facetHits = [];
        }
      })

      TextInput({ text: this.fKeyword, placeholder: this.facetPlaceholder() })
        .height(36)
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .placeholderFont({ size: 11 })
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((v: string) => {
          this.onFacetInput(v);
        })

      if (this.facetHits.length > 0) {
        Column({ space: 2 }) {
          ForEach(this.facetHits, (f: FacetLite) => {
            Row({ space: 8 }) {
              Text(f.name)
                .fontSize(12)
                .fontColor(this.facetOn(f) ? '#FFFFFF' : Theme.TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(`${f.count}`)
                .fontSize(10)
                .fontColor(this.facetOn(f) ? '#E6FFFFFF' : Theme.TEXT_FAINT)
              Text(this.facetOn(f) ? '✓' : '+')
                .fontSize(11)
                .fontColor(this.facetOn(f) ? '#FFFFFF' : Theme.TEXT_FAINT)
            }
            .width('100%')
            .height(36)
            .padding({ left: 10, right: 10 })
            .borderRadius(10)
            .backgroundColor(this.facetOn(f) ? Theme.accentAlpha(0.28) : Theme.CARD_HI)
            .margin({ bottom: 4 })
            .onClick(() => {
              this.pickFacet(f);
            })
          }, (f: FacetLite) => `fs-${this.fKind}-${f.id}`)
        }
        .width('100%')
      } else if (this.facetBusy) {
        Text('搜索中…')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }

      if (this.facetPickedCount() > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tagPicks, (t: FacetLite) => {
            Text(`标签·${t.name} ✕`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.accentAlpha(0.35))
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
              .maxLines(1)
              .onClick(() => {
                this.toggleTag(t);
              })
          }, (t: FacetLite) => `tp-${t.id}`)

          if (this.fSeries.length > 0) {
            Text(`系列·${this.fSeries} ✕`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.accentAlpha(0.35))
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
              .maxLines(1)
              .onClick(() => {
                this.fSeries = '';
                this.runQuery();
              })
          }
          if (this.fStudio.length > 0) {
            Text(`制片商·${this.fStudio} ✕`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.accentAlpha(0.35))
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
              .maxLines(1)
              .onClick(() => {
                this.fStudio = '';
                this.runQuery();
              })
          }
        }
        .width('100%')
      } else {
        Text('三个维度可以同时用：选两个标签 + 一个系列 = 同时满足')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
  }

  /** 与媒体库一致的常规筛选：类型 / 多版本 / 评分 / 年份。 */
  @Builder
  MoreSection() {
    SheetSection({
      title: '更多条件',
      value: this.moreSummary(),
      active: this.fCtype.length > 0 || this.fMulti.length > 0
        || this.fScore.length > 0 || this.fYear.length > 0
    }) {
      PickChips({
        title: '类型',
        options: CTYPE_CHOICES,
        current: this.fCtype,
        onPick: (key: string) => {
          this.fCtype = key;
          this.runQuery();
        }
      })
      PickChips({
        title: '版本',
        options: VERSION_CHOICES,
        current: this.fMulti,
        onPick: (key: string) => {
          this.fMulti = key;
          this.runQuery();
        }
      })
      PickChips({
        title: '评分',
        options: SCORE_CHOICES,
        current: this.fScore,
        onPick: (key: string) => {
          this.fScore = key;
          this.runQuery();
        }
      })
      PickChips({
        title: '年份',
        options: YEAR_CHOICES,
        current: this.fYear,
        onPick: (key: string) => {
          this.fYear = key;
          this.runQuery();
        }
      })
    }
  }

  /** 我的评分 / 收藏夹（已迁出废弃 MyFilterBar，改用本页 PickChips + CollectionsBar）。 */
  @Builder
  MineSection() {
    SheetSection({
      title: '我的',
      value: this.fMyRating.length > 0 || this.fCollection.length > 0 ? '已设置' : '不限',
      active: this.fMyRating.length > 0 || this.fCollection.length > 0,
      divider: false
    }) {
      if (BuildConfig.ENABLE_RATINGS) {
        PickChips({
          title: '我的评分',
          options: MYRATING_OPTIONS,
          current: this.fMyRating,
          onPick: (k: string) => {
            this.fMyRating = k;
            this.runQuery();
          }
        })
      }
      if (BuildConfig.ENABLE_COLLECTIONS) {
        Row({ space: 7 }) {
          Text('收藏夹')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          CollectionsBar({
            current: this.fCollection,
            showManage: false,
            onPick: (k: string) => {
              this.fCollection = k;
              this.runQuery();
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  /** 其它：字幕 / 马赛克。 */
  @Builder
  ExtraSection() {
    SheetSection({
      title: '其它',
      value: this.onlySub || this.mosaic.length > 0 ? '已设置' : '不限',
      active: this.onlySub || this.mosaic.length > 0
    }) {
      PickChips({
        title: '字幕',
        options: SUB_CHOICES,
        current: this.onlySub ? '1' : '',
        onPick: (key: string) => {
          this.onlySub = key === '1';
          this.runQuery();
        }
      })
      PickChips({
        title: '马赛克',
        options: this.mosaics,
        current: this.mosaic,
        onPick: (key: string) => {
          this.mosaic = key;
          this.runQuery();
        }
      })
    }
  }

  /**
   * 导演筛选。
   *
   * 两种模式，默认**只看**（收窄），可一键切成**排除**（减法）：
   *  - 只看：这批结果里只保留这几位导演的片子（选两位 = 两人的片子合集）；
   *  - 排除：把这几位导演的片子整片剔掉 —— 同一位导演一个月出十部一样的片子，
   *    配上「n女n男」会占满第一屏，所以要能把他剔出去。
   * 文案必须把两种模式都说到，不能只写「排除」（默认明明是只看，只说排除会误导）。
   */
  @Builder
  DirectorBar() {
    SheetSection({
      title: '导演',
      value: this.dirs.length > 0
        ? `${this.dirExclude ? '排除' : '只看'} ${this.dirs.length} 位`
        : '不限',
      active: this.dirs.length > 0,
      actionLabel: this.dirPicking ? '收起' : '+ 添加导演',
      onAction: () => {
        this.dirPicking = !this.dirPicking;
        if (this.dirPicking && this.dirHits.length === 0) {
          this.doDirSearch();
        }
      }
    }) {
      if (this.dirs.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.dirs, (d: DirectorHit) => {
            Text(`${d.name} ✕`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.dirExclude ? '#8C3A1414' : Theme.accentAlpha(0.35))
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.toggleDir(d);
              })
          }, (d: DirectorHit) => `dir-${d.id}`)
        }
        .width('100%')

        Text(this.dirExclude ? '✕ 排除这几位' : '✓ 只看这几位')
          .fontSize(11)
          .fontColor(this.dirExclude ? '#FFFFFF' : Theme.ON_ACCENT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.dirExclude ? Theme.DANGER : Theme.ACCENT)
          .borderRadius(14)
          .onClick(() => {
            this.dirExclude = !this.dirExclude;
            this.runQuery();
          })
      } else if (!this.dirPicking) {
        // 2026-11-17 用户：「导演下那句话有歧义，可以不留，观众选的时候自己
        // 就知道这里能切只看/不看」。那句「也可切成排除（把 n女n男+导演 整片剔掉）」
        // 反而把人绕晕，直接删掉，靠下面那个「✓只看/✕排除」按钮自解释。
      }

      if (this.dirPicking) {
        TextInput({ placeholder: '搜索导演名', text: this.dirQuery })
          .height(36)
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 11 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .width('100%')
          .onChange((v: string) => {
            this.onDirSearch(v);
          })

        Scroll() {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.dirHits, (d: DirectorHit) => {
              Text(d.count > 0 ? `${d.name} · ${d.count}` : d.name)
                .fontSize(12)
                .fontColor(this.isDirPicked(d.id) ? Theme.ON_ACCENT : Theme.TEXT_DIM)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.isDirPicked(d.id) ? Theme.ACCENT : Theme.CARD_HI)
                .borderRadius(14)
                .margin({ right: 8, bottom: 8 })
                .maxLines(1)
                .onClick(() => {
                  this.toggleDir(d);
                })
            }, (d: DirectorHit) => `dhit-${d.id}-${this.isDirPicked(d.id) ? 1 : 0}`)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 150 })
        .width('100%')
      }
    }
  }


  /**
   * 结果卡（2026-11-17 对齐媒体库海报卡）：封面当主角，阵容头像压在图下，
   * 番号移到海报**外面**当文字行；破解/中字/评分统一挪到海报右上角。
   */
  @Builder
  Cell(x: CastFindItem) {
    Column({ space: 5 }) {
      // 外层 TopEnd：右上角「标记 + 刮削评分 / 我的评分」，与媒体库 PosterCard 同一套
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Image(Store.I.img(x.poster))
            .width('100%')
            .aspectRatio(0.704)
            .objectFit(ImageFit.Cover)
            .borderRadius(10)
            .backgroundColor(Theme.CARD_HI)
            .alt($r('app.media.placeholder'))

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

          // 头像压在封面下缘、居中叠压；尺寸按人数 + 列数收缩（见 avSize）
          Column({ space: 6 }) {
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
                        .fontSize(Math.round(this.avSize(x) * 0.42))
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
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .padding({ left: 6, right: 6, bottom: 8 })
        }
        .width('100%')
        .borderRadius(10)
        .clip(true)

        // 右上角标记 + 评分（媒体库 PosterCard 同款）
        if (scoreText(x.score).length > 0 || x.marks.length > 0 ||
          this.cellMyRating(x) > 0) {
          Column({ space: 3 }) {
            if (scoreText(x.score).length > 0 || x.marks.length > 0) {
              Row({ space: 3 }) {
                if (x.marks.length > 0) {
                  MarkBadges({ marks: x.marks, max: 2, badgeSize: 8, fill: 'dark' })
                }
                if (scoreText(x.score).length > 0) {
                  Text(scoreText(x.score))
                    .fontSize(10)
                    .fontColor(Theme.GOLD)
                    .fontWeight(FontWeight.Medium)
                    .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                    .backgroundColor('#B3000000')
                    .borderRadius(6)
                }
              }
            }
            if (this.cellMyRating(x) > 0) {
              Text(rateLabel(this.cellMyRating(x)))
                .fontSize(9)
                .fontColor(rateColor(this.cellMyRating(x)))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .backgroundColor('#B3000000')
                .borderRadius(6)
            }
          }
          .alignItems(HorizontalAlign.End)
          .margin(6)
        }
      }
      .width('100%')

      // 番号移到海报外面：与媒体库一致，第一行就是番号（白话标题退到下一行）
      Text(x.number)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

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

      // 导演名：排除导演时得看得见「这部是谁拍的」，否则不知道排除有没有生效
      if (x.directors.length > 0) {
        Text(`导 ${x.directors.join(' / ')}`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
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
      // Cell 自己带 layoutWeight(1)，几个都会等分填满这一行，不用补白。
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 导航栈（七十二改）：整页套 Navigation，只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 标题栏实际高度。46 第一行 + 42 第二行。 */
  private barH(): number {
    return this.topInset + 88;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 88 + this.topInset
    };
  }

  @Builder
  TitleBar() {
    // 七十二改：原来压在内容上的 Header / Toolbar 两条一并搬进标题栏 ——
    // 第一行「返回 + 标题 + 排序 + 筛选」，第二行「条件说明 + 抽卡开关」。
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        GlassBox({ radius: 23, padH: 14, padV: 9, mat: true }) {
          PageTitle({ text: '共演筛选', fs: 18 })
        }
        Blank()
        GlassCapsule({
          label: `${this.sortLabel()}`,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          maxW: 100,
          mat: true,
          onTap: () => {
            this.showSort = true;
          }
        })
        GlassCapsule({
          label: this.filterCount() > 0 ? `筛选 ${this.filterCount()}` : '筛选',
          active: this.filterCount() > 0,
          fs: 12,
          padH: 11,
          padV: 7,
          radius: 12,
          mat: true,
          onTap: () => {
            this.showFilter = true;
          }
        })
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      Row({ space: 6 }) {
        Text(this.total > 0 ? `${this.total} 部符合条件` : '选人 + 人数条件，找共演作品')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .layoutWeight(1)
        if (BuildConfig.ENABLE_GACHA) {
          GachaSwitch({
            mat: true,
            on: this.gachaOn,
            onToggle: (v: boolean) => {
              this.gachaOn = v;
            }
          })
        }
      }
      .height(42)
      .alignItems(VerticalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: Theme.PAGE_PAD, top: this.topInset - 8 })
  }

  /** 真·全屏（七十二改）：窗口铺到系统栏后面；离开本页不关，见 common/PageFullscreen。 */
  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          // 七十二改：Header / Toolbar 已搬进标题栏，这里只剩内容；让位在滚动容器自己的 padding 里。

        // 旧服务端把导演/人数集合参数静默丢掉时，必须显式说出来 ——
        // 否则「只看导演 X 却出现全库 5000 多部」会被当成功能坏了。
        if (this.capsWarn.length > 0) {
          Text(this.capsWarn)
            .fontSize(10)
            .fontColor('#FFB74D')
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor('#26FFB74D')
            .borderRadius(8)
            .margin({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
        }

        Scroll() {
          Column({ space: 10 }) {
            if (this.gachaOn) {
              // 抽卡墙按同一套筛选条件抽片：extra 就是 filterQuery，
              // 条件一变（字符串变了）GachaWall 会自己重抽。
              GachaWall({
                scope: 'cast',
                scopeId: 0,
                label: this.conditionText(),
                count: 0,
                extra: this.filterQuery(),
                gachaOn: this.gachaOn,
                onToggleGacha: (v: boolean) => {
                  this.gachaOn = v;
                }
              })
            } else if (this.loading) {
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
                Text(this.filterCount() === 0
                  ? '点右上角「甄选」设定筛选条件'
                  : '没有符合条件的片子')
                  .fontSize(12)
                  .fontColor(Theme.TEXT_DIM)
                if (this.filterCount() > 0) {
                  Text('清空条件')
                    .fontSize(12)
                    .fontColor(Theme.ACCENT)
                    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                    .backgroundColor(Theme.ACCENT_SOFT)
                    .borderRadius(14)
                    .onClick(() => {
                      this.clearAll();
                    })
                }
              }
              .width('100%')
              .height(180)
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
              .padding({ left: 4, right: 4, bottom: 2 })

              // key 必须带列数：切列走 onColsChange 重切 rows，seq 不变，
              // 而首行 row[0] 始终是 results[0]（重切后还是那部片）——
              // 不带列数时首行 key 不变，ArkUI 复用旧节点，仍显示旧列数（首行固定 3 列）。
              // 带上列数后切列时每行 key 都失效重建。
              ForEach(this.rows, (row: CastFindItem[], idx: number) => {
                this.Row2(row)
              }, (row: CastFindItem[], idx: number) => `cfr-${this.seq}-${this.posterCols}-${idx}-${row[0].id}`)

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
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: this.barH() + 6, bottom: 20 })
        }
        .width('100%')
        .layoutWeight(1)
        // 2026-11-17：与媒体库同一套捏合切列数（偏好共用 amaneCols）
        .gesture(PinchGesture({ fingers: 2 }).onActionEnd((event: GestureEvent) => {
          Personalize.zoom(event.scale);
        }))
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)

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
              if (this.sortBy !== key) {
                this.sortBy = key;
                this.order = sortDefOf(key);
              }
              this.runQuery();
              this.showSort = false;
            },
            onToggleOrder: () => {
              this.order = this.order === 'asc' ? 'desc' : 'asc';
              this.runQuery();
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
