import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 观看统计（2.5.3 · 报表 v1）。
 *
 * 五个块竖排：概览 / 趋势 / 时段与星期 / 最热片段 / 偏好榜。
 * 字段名以服务端 1.4.x 的实现为准（`amane-user/server.py` 的 `stats_*` 路由），
 * 契约同步写在 `docs/TASKS/2.5.3-report.md`。**任何统计口径都不许写进页面**：
 * 页面只渲染、只做百分比归一，改算法要改服务端并 +1 `STATS_VERSION`。
 *
 * 三条设计约束（任务书要求，改之前先读）：
 *   1. 每块自己负责空态：服务端 `ok:false` 显示它的 `reason`；端点不存在（老服务端 / 404）
 *      显示「服务端还没开统计」。**任何情况都不许把 0 当结果摆出来**；
 *   2. 五块互不阻塞：任意一块失败只影响自己；
 *   3. 图全部原生画（柱 = Row + 高度百分比，折线 = Polyline，热度 = 分段色块），不引图表库。
 *
 * **@Builder 传参不会因参数变化重跑**（2.5.1.18 / 2.5.1.20 两次踩坑）：本页所有会变的内容
 * 都在 builder 内部读 `this.xxx`，外层只传静态 key。
 *
 * **ForEach 的 key 必须包含「会变的状态」**（2.5.2.4 踩坑）：胶囊高亮原本只由
 * `c.picked` 决定，而 key 是 `hp-${id}` —— 点了以后数据换了、节点却按同一个 key 复用了，
 * 于是内容切换、高亮不切。key 里带上 picked，状态一变就重建节点。
 *
 * 顶部两个筛选（2.5.2.4）：**时间范围**（全部 / 近 7·30·90 天 / 自定义）与**数据口径**
 * （真实 / 测试）。只有「口径版本 ≥ 2」的服务端才认这两个参数，老服务端自动隐藏这一条。
 */

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';
/** 服务端说「还在积累」（`ok:false`）或数据为 0。 */
const ST_EMPTY: string = 'empty';
/** 端点不存在 / 网络失败：老服务端还没这组接口。 */
const ST_OFF: string = 'off';

const TREND_WEEKS: number = 12;
const TREND_H: number = 120;
const TOP_LIMIT: number = 10;

/** 服务端口径版本：≥2 才认 `from` / `to` / `scope`（1.4.0 是第一版）。 */
const MIN_STATS_VER_FILTER: number = 2;

/** 跳演员作品页的参数（与 `SearchPage` 里那份同形，别跨页 import）。 */
interface ActorNav {
  id: number;
  name: string;
}

/** 跳分类影片墙的参数。 */
interface FacetNav {
  kind: string;
  id: number;
  name: string;
}

/** 跳详情页的参数（`pages/DetailPage` 只认 `id`）。 */
interface FilmNav {
  id: number;
}

interface OverviewData {
  films: number;
  finished: number;
  seconds: number;
  days: number;
  /** 当前连续天数（只在这两天有记录时才非 0）。 */
  streak: number;
  /** 最长连续天数。 */
  longest_streak: number;
  samples: number;
  suspicious: number;
  dropped: number;
  from: string;
  to: string;
  /** 不受筛选影响的可用范围（「你的数据从哪到哪」）。1.4.1 起才有。 */
  available_from: string;
  available_to: string;
  /** 两个口径各多少条采样：测试版切口径时用来显示「测试数据 36 条」。 */
  scope_samples: ScopeSamples;
}

interface ScopeSamples {
  real: number;
  test: number;
}

/** 服务端回显的本次筛选（null 表示没限制）。 */
interface StatsRange {
  from: string;
  to: string;
}

interface OverviewRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  /** 有 `range` 字段 = 服务端认 from/to/scope（口径版本 ≥ 2）。 */
  range?: StatsRange;
  scope?: string;
  data: OverviewData;
}

interface TrendWeek {
  week: string;
  from: string;
  to: string;
  films: number;
  finished: number;
  /** 完成率 0–1（服务端算好的，客户端不再除）。 */
  rate: number;
  seconds: number;
  hours: number;
}

interface TrendData {
  weeks: TrendWeek[];
  weeks_count: number;
  films: number;
}

interface TrendRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: TrendData;
}

interface WhenData {
  /** 每个小时看了多少**秒**（不是部数）。 */
  hours: number[];
  hours_samples: number[];
  weekdays: number[];
  weekday_samples: number[];
  peak_hour: number;
  peak_weekday: number;
  unknown_samples: number;
}

interface WhenRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: WhenData;
}

interface HeatData {
  mid: number;
  /** 已按峰值归一到 0–1，客户端直接当强度用。 */
  buckets: number[];
  secs: number[];
  total_secs: number;
  peak_bucket: number;
  /** 一个桶占多少百分比（20 桶 → 5.0）。 */
  bucket_pct: number;
}

interface HeatRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: HeatData;
}

interface TopItem {
  id: number;
  name: string;
  films: number;
  seconds: number;
  hours: number;
}

interface TopData {
  kind: string;
  items: TopItem[];
  films: number;
}

interface TopRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: TopData;
}

/** 热力条上「挑一部」的候选：来自现成的观看记录接口，不新增服务端依赖。 */
interface HeatPick {
  id: number;
  label: string;
}

interface HistoryLite {
  id: number;
  number: string;
  title: string;
}

interface HistoryRes {
  items: HistoryLite[];
}

/** 制片商没有 id（服务端 `nid = 0`），点的时候现查一次拿 id 再跳。 */
interface FacetItem {
  id: number;
  name: string;
}

interface FacetListRes {
  items: FacetItem[];
}

/** 偏好榜 / 热度条上的胶囊。 */
interface PickChip {
  id: number;
  label: string;
  picked: boolean;
}

/** 「该隐藏的标签」候选（服务端 `stats/tag-hygiene`）。 */
interface HygieneItem {
  id: number;
  name: string;
  films: number;
  coverage: number;
  reason: string;
}

interface HygieneData {
  items: HygieneItem[];
  hidden: number;
}

interface HygieneRes {
  ok: boolean;
  version: number;
  data: HygieneData;
}

interface PurgeRes {
  ok: boolean;
  removed: number;
}

interface TestDataRes {
  ok: boolean;
  films: number;
  samples: number;
  removed: number;
}

// ---- v2（2.5.3 延续）：弃片 / 吃灰 / 漏斗 / 评分冲突 ------------------------
// 字段以服务端 1.4.2 的实际实现为准（`stats_dropoff` 等五个路由），
// 契约回填在 `docs/TASKS/2.5.3-report-v2.md` §2。页面只渲染，口径全在服务端。

interface DropItem {
  id: number;
  name: string;
  /** 打开过的部数（累计观看 ≥60s）。 */
  opened: number;
  dropped: number;
  /** 弃片率 0–1（服务端算好的）。 */
  rate: number;
}

interface DropData {
  kind: string;
  items: DropItem[];
  /** 全部实体合计：打开多少部、弃了多少部。 */
  opened: number;
  dropped: number;
  cutoff: string;
  min_sample: number;
}

interface DropRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: DropData;
}

interface DropCurveData {
  /** 10 个桶：最后停在那一档的**部数**（直方图）。 */
  buckets: number[];
  /** 10 个桶：撑到这一档的**累计比例**（0–1），服务端说明「最后一项≈完成率」。 */
  reached: number[];
  films: number;
  avg_runtime_secs: number;
}

interface DropCurveRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: DropCurveData;
}

interface IdleFilm {
  id: number;
  number: string;
  title: string;
  /** 收藏时间（服务端只给这个，没有「放了几天」）。 */
  fav_at: string;
}

interface IdleActor {
  id: number;
  name: string;
  /** 收藏了几部他的片（都没打开）。 */
  films: number;
}

interface IdleStudio {
  name: string;
  films: number;
}

interface IdleData {
  items: IdleFilm[];
  total: number;
  days: number;
  cold_actors: IdleActor[];
  cold_studios: IdleStudio[];
}

interface IdleRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: IdleData;
}

interface FunnelData {
  /** 窗口内新增的收藏数（三段的分母）。 */
  favorited: number;
  opened: number;
  finished: number;
  /** 打开 / 收藏。 */
  open_rate: number;
  /** 看完 / 打开。 */
  finish_rate: number;
  /** 看完 / 收藏 —— 漏斗总转化，页面标「收藏 → 看完」用这个。 */
  overall: number;
  days: number;
  cutoff: string;
}

interface FunnelRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: FunnelData;
}

interface ConflictFilm {
  id: number;
  score: number;
  /** 完成率 0–1（字段名是 ratio，不是 rate）。 */
  ratio: number;
  secs: number;
  number: string;
  title: string;
}

interface RepeatFilm {
  id: number;
  /** 重看次数（字段名是 replays）。 */
  replays: number;
  secs: number;
  number: string;
  title: string;
}

interface UpstreamCmp {
  count: number;
  /** 我（5 星 ×2 = 10 分制）减上游分的均值。 */
  mean_diff: number;
  /** 比大众严的比例 0–1。 */
  harsh: number;
  /** 差距 > 1.5 分的比例 0–1。 */
  gap: number;
}

interface ConflictData {
  high_low: ConflictFilm[];
  repeats: RepeatFilm[];
  vs_upstream: UpstreamCmp;
  opened: number;
}

interface ConflictRes {
  ok: boolean;
  version: number;
  confidence: string;
  reason: string;
  data: ConflictData;
}

// ---- 2.5.4 Tier 图：统计页那块卡片 -----------------------------------------
// 只读 `/tier/current`（服务端挑好的那张）+ 渲染前几张缩略图与各档人数。

interface TierCurItem {
  id: number;
  kind: string;
  name: string;
  number: string;
  image: string;
  score: number;
}

interface TierCurRow {
  score: number;
  title: string;
  items: TierCurItem[];
  more: number;
}

interface TierCurData {
  id: number;
  created_at: string;
  total: number;
  tiers: TierCurRow[];
}

interface TierCurRes {
  ok: boolean;
  version: number;
  reason: string;
  data: TierCurData;
}


/** `Date` → `YYYY-MM-DD`（按本地时区，别用 toISOString —— 那是 UTC，晚上会差一天）。 */
function ymd(d: Date): string {
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
}

/** `YYYY-MM-DD` → `Date`（解析失败给今天，别把页面搞崩）。 */
function parseYmd(raw: string): Date {
  const parts: string[] = raw.split('-');
  if (parts.length !== 3) {
    return new Date();
  }
  const y: number = Number(parts[0]);
  const m: number = Number(parts[1]);
  const d: number = Number(parts[2]);
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) {
    return new Date();
  }
  return new Date(y, m - 1, d);
}

function num(v: number): number {
  if (v === undefined || v === null) {
    return 0;
  }
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function str(v: string): string {
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}

function nums(v: number[]): number[] {
  const out: number[] = [];
  if (v === undefined || v === null) {
    return out;
  }
  for (let i = 0; i < v.length; i++) {
    out.push(num(v[i]));
  }
  return out;
}

/** 秒 → 「6 小时 12 分」；不足 1 小时给分钟。 */
function fmtDur(sec: number): string {
  const s: number = num(sec);
  if (s <= 0) {
    return '0 分钟';
  }
  if (s >= 3600) {
    const hh: number = Math.floor(s / 3600);
    const mm: number = Math.round((s - hh * 3600) / 60);
    return mm > 0 ? `${hh} 小时 ${mm} 分` : `${hh} 小时`;
  }
  return `${Math.max(1, Math.round(s / 60))} 分钟`;
}

/** 概览格子里的大数字：小时给一位小数，分钟取整。 */
function bigNum(sec: number): string {
  const s: number = num(sec);
  if (s >= 3600) {
    return (s / 3600).toFixed(1);
  }
  return `${Math.max(0, Math.round(s / 60))}`;
}

function bigUnit(sec: number): string {
  return num(sec) >= 3600 ? '小时' : '分钟';
}

/** `2026-08-24` → `8/24`；认不出来就原样回。 */
function mdOf(date: string): string {
  const s: string = str(date);
  const parts: string[] = s.split('-');
  if (parts.length !== 3) {
    return s;
  }
  const m: number = Number(parts[1]);
  const d: number = Number(parts[2]);
  if (!Number.isFinite(m) || !Number.isFinite(d)) {
    return s;
  }
  return `${m}/${d}`;
}

function maxOf(list: number[]): number {
  let max: number = 0;
  for (let i = 0; i < list.length; i++) {
    if (list[i] > max) {
      max = list[i];
    }
  }
  return max;
}

function emptyOverview(): OverviewData {
  const d: OverviewData = {
    films: 0, finished: 0, seconds: 0, days: 0, streak: 0, longest_streak: 0,
    samples: 0, suspicious: -1, dropped: -1, from: '', to: '',
    available_from: '', available_to: '',
    scope_samples: { real: 0, test: 0 }
  };
  return d;
}

@Entry
@Component
struct StatsPage {
  @State ovSt: string = ST_LOADING;
  @State ov: OverviewData = emptyOverview();
  /** 概览这块的空态文案（服务端 `ok:false` 时给的 reason）。 */
  @State ovNote: string = '';
  @State srvVer: number = 0;
  @State srvConf: string = '';

  @State trSt: string = ST_LOADING;
  @State tr: TrendWeek[] = [];
  @State trNote: string = '';
  /** 图表实测宽度：折线要按真像素算点，`Polyline.points` 只吃 vp 数值。 */
  @State trendW: number = 0;
  /** 点了哪一周（-1 = 没点）。 */
  @State trPick: number = -1;

  @State whenSt: string = ST_LOADING;
  @State hours: number[] = [];
  @State weekdays: number[] = [];
  @State peakHour: number = -1;
  @State peakDay: number = -1;
  @State whenNote: string = '';

  @State heatSt: string = ST_LOADING;
  @State buckets: number[] = [];
  @State heatTotal: number = 0;
  @State heatPeakBucket: number = -1;
  @State heatBucketPct: number = 5;
  @State heatMid: number = 0;
  @State heatTitle: string = '';
  @State heatNote: string = '';
  @State picks: HeatPick[] = [];

  @State topSt: string = ST_LOADING;
  @State topKind: string = 'actor';
  @State topItems: TopItem[] = [];
  @State topNote: string = '';

  // ---- 顶部筛选（2.5.2.4）：时间范围 + 数据口径 --------------------------
  /** `all` / `7` / `30` / `90` / `custom`。 */
  @State rangeKey: string = 'all';
  @State rangeFrom: string = '';
  @State rangeTo: string = '';
  /** `real` / `test`。 */
  @State scopeKey: string = 'real';
  /** 服务端认不认这几个参数（口径版本 ≥2）；老服务端整条筛选隐藏。 */
  @State srvFlags: boolean = false;
  @State scopeSamples: ScopeSamples = { real: 0, test: 0 };
  @State availFrom: string = '';
  @State availTo: string = '';
  @State busy: boolean = false;
  /** 标签清理建议（只在标签榜里出现，避免每块都塞一条）。 */
  @State hygiene: HygieneItem[] = [];
  @State hygieneHidden: number = 0;
  @State hygieneSheet: boolean = false;

  // ---- v2 四块（2.5.3 延续）----
  @State dropSt: string = ST_LOADING;
  /** `actor` / `tag`：弃片榜按演员还是标签看。 */
  @State dropKind: string = 'actor';
  @State dropItems: DropItem[] = [];
  @State dropOpened: number = 0;
  @State dropDropped: number = 0;
  @State dropNote: string = '';

  @State curveSt: string = ST_LOADING;
  /** 撑到第 i 档的累计比例（画柱子用这个，不是直方图）。 */
  @State curveReached: number[] = [];
  /** 直方图（最后停在哪档的部数），只用来找「掉得最狠」的那一档。 */
  @State curveBuckets: number[] = [];
  @State curveFilms: number = 0;
  @State curveNote: string = '';

  @State idleSt: string = ST_LOADING;
  @State idleDays: number = 30;
  @State idleTotal: number = 0;
  @State idleFilms: IdleFilm[] = [];
  @State idleActors: IdleActor[] = [];
  @State idleStudios: IdleStudio[] = [];
  @State idleNote: string = '';

  @State funSt: string = ST_LOADING;
  @State funFav: number = 0;
  @State funOpened: number = 0;
  @State funFinished: number = 0;
  @State funOpenRate: number = 0;
  @State funOverall: number = 0;
  @State funDays: number = 90;
  @State funNote: string = '';

  @State cfSt: string = ST_LOADING;
  @State cfHigh: ConflictFilm[] = [];
  @State cfRepeat: RepeatFilm[] = [];
  @State cfCount: number = 0;
  @State cfMeanDiff: number = 0;
  @State cfHarsh: number = 0;
  @State cfGap: number = 0;
  @State cfNote: string = '';

  // ---- 2.5.4 Tier 图那块 ------------------------------------------------
  @State tierSt: string = ST_LOADING;
  @State tierTotal: number = 0;
  @State tierRows: TierCurRow[] = [];
  /** 预览用的几张缩略图（按档从高到低取）。 */
  @State tierThumbs: string[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.loadOverview();
    this.loadTrend();
    this.loadWhen();
    this.loadHeat(this.heatMid);
    this.loadTop(this.topKind);
    this.loadTier();
    this.loadDropoff(this.dropKind);
    this.loadDropCurve();
    this.loadIdle(this.idleDays);
    this.loadFunnel(this.funDays);
    this.loadConflict();
    if (this.picks.length === 0) {
      this.loadPicks();
    }
  }

  // ---------------------------------------------------------------- 取数

  /**
   * 统一的筛选串。**五个块都走这里**，否则会出现「概览按 7 天、榜单按全部」这种
   * 自相矛盾的页面。`scope` 只在服务端认的时候才带，老服务端会把它当未知参数忽略，
   * 但没必要发。
   */
  private filterQs(extra: string): string {
    const parts: string[] = [];
    if (this.rangeFrom.length > 0) {
      parts.push(`from=${this.rangeFrom}`);
    }
    if (this.rangeTo.length > 0) {
      parts.push(`to=${this.rangeTo}`);
    }
    if (this.srvFlags) {
      parts.push(`scope=${this.scopeKey}`);
    }
    if (extra.length > 0) {
      parts.push(extra);
    }
    return parts.length > 0 ? `?${parts.join('&')}` : '';
  }

  private async loadOverview(): Promise<void> {
    this.ovSt = ST_LOADING;
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/stats/overview${this.filterQs('')}`, Store.I.token);
      const res: OverviewRes = JSON.parse(raw) as OverviewRes;
      if (res.data === undefined || res.data === null) {
        this.ovSt = ST_OFF;
        return;
      }
      // 有 range / scope_samples = 服务端是 1.4.1+（口径版本 ≥2），顶部筛选才有意义
      const flags: boolean = res.range !== undefined || res.data.scope_samples !== undefined;
      const d: OverviewData = res.data;
      const next: OverviewData = {
        films: num(d.films),
        finished: num(d.finished),
        seconds: num(d.seconds),
        days: num(d.days),
        streak: num(d.streak),
        longest_streak: num(d.longest_streak),
        samples: num(d.samples),
        suspicious: num(d.suspicious),
        dropped: num(d.dropped),
        from: str(d.from),
        to: str(d.to),
        available_from: str(d.available_from),
        available_to: str(d.available_to),
        scope_samples: {
          real: d.scope_samples === undefined || d.scope_samples === null
            ? 0 : num(d.scope_samples.real),
          test: d.scope_samples === undefined || d.scope_samples === null
            ? 0 : num(d.scope_samples.test)
        }
      };
      this.srvFlags = flags;
      this.ov = next;
      this.srvVer = num(res.version);
      this.srvConf = str(res.confidence);
      this.ovNote = str(res.reason);
      if (flags) {
        this.scopeSamples = next.scope_samples;
        this.availFrom = next.available_from;
        this.availTo = next.available_to;
      }
      // 服务端 `ok:false` 时也会回一份填 0 的 data；只有真的看过片才当它有数
      const hasData: boolean = res.ok === true && next.films > 0;
      this.ovSt = hasData ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/overview: ${e.code} ${e.message}`);
      this.ovSt = ST_OFF;
    }
  }

  private async loadTrend(): Promise<void> {
    this.trSt = ST_LOADING;
    try {
      const url: string = `${Store.I.user}/api/user/stats/trend${this.filterQs(`weeks=${TREND_WEEKS}`)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: TrendRes = JSON.parse(raw) as TrendRes;
      if (res.data === undefined || res.data === null || res.data.weeks === undefined) {
        this.trSt = ST_OFF;
        return;
      }
      const src: TrendWeek[] = res.data.weeks;
      const out: TrendWeek[] = [];
      if (src !== undefined && src !== null) {
        for (let i = 0; i < src.length; i++) {
          const w: TrendWeek = src[i];
          const row: TrendWeek = {
            week: str(w.week),
            from: str(w.from),
            to: str(w.to),
            films: num(w.films),
            finished: num(w.finished),
            rate: num(w.rate),
            seconds: num(w.seconds),
            hours: num(w.hours)
          };
          out.push(row);
        }
      }
      this.tr = out;
      this.trPick = -1;
      this.trNote = str(res.reason);
      this.trSt = res.ok === true && maxOf(this.filmCounts(out)) > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/trend: ${e.code} ${e.message}`);
      this.trSt = ST_OFF;
    }
  }

  private filmCounts(list: TrendWeek[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(list[i].films);
    }
    return out;
  }

  private async loadWhen(): Promise<void> {
    this.whenSt = ST_LOADING;
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/stats/when${this.filterQs('')}`, Store.I.token);
      const res: WhenRes = JSON.parse(raw) as WhenRes;
      if (res.data === undefined || res.data === null) {
        this.whenSt = ST_OFF;
        return;
      }
      this.hours = nums(res.data.hours);
      this.weekdays = nums(res.data.weekdays);
      this.peakHour = num(res.data.peak_hour);
      if (res.data.peak_hour === undefined || res.data.peak_hour === null) {
        this.peakHour = -1;
      }
      this.peakDay = num(res.data.peak_weekday);
      if (res.data.peak_weekday === undefined || res.data.peak_weekday === null) {
        this.peakDay = -1;
      }
      this.whenNote = str(res.reason);
      this.whenSt = res.ok === true && maxOf(this.hours) > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/when: ${e.code} ${e.message}`);
      this.whenSt = ST_OFF;
    }
  }

  private async loadHeat(mid: number): Promise<void> {
    this.heatSt = ST_LOADING;
    try {
      const extra: string = mid > 0 ? `mid=${mid}` : '';
      const url: string = `${Store.I.user}/api/user/stats/heat${this.filterQs(extra)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: HeatRes = JSON.parse(raw) as HeatRes;
      if (res.data === undefined || res.data === null) {
        this.heatSt = ST_OFF;
        return;
      }
      this.buckets = nums(res.data.buckets);
      this.heatTotal = num(res.data.total_secs);
      this.heatBucketPct = num(res.data.bucket_pct) > 0 ? num(res.data.bucket_pct) : 5;
      this.heatPeakBucket = res.data.peak_bucket === undefined || res.data.peak_bucket === null
        ? -1 : num(res.data.peak_bucket);
      this.heatNote = str(res.reason);
      this.heatSt = res.ok === true && maxOf(this.buckets) > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/heat: ${e.code} ${e.message}`);
      this.heatSt = ST_OFF;
    }
  }

  private async loadTop(kind: string): Promise<void> {
    this.topKind = kind;
    this.topSt = ST_LOADING;
    try {
      const url: string =
        `${Store.I.user}/api/user/stats/top${this.filterQs(`kind=${kind}&limit=${TOP_LIMIT}`)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: TopRes = JSON.parse(raw) as TopRes;
      if (res.data === undefined || res.data === null || res.data.items === undefined) {
        this.topSt = ST_OFF;
        return;
      }
      const src: TopItem[] = res.data.items;
      const out: TopItem[] = [];
      if (src !== undefined && src !== null) {
        for (let i = 0; i < src.length; i++) {
          const it: TopItem = src[i];
          const row: TopItem = {
            id: num(it.id),
            name: str(it.name),
            films: num(it.films),
            seconds: num(it.seconds),
            hours: num(it.hours)
          };
          if (row.name.length > 0) {
            out.push(row);
          }
        }
      }
      this.topItems = out;
      this.topNote = str(res.reason);
      this.topSt = res.ok === true && out.length > 0 ? ST_OK : ST_EMPTY;
      // 标签榜：顺手拉一次「该隐藏哪些标签」的建议（同页只出现一次，不占别的块）
      if (kind === 'tag') {
        this.loadHygiene();
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/top ${kind}: ${e.code} ${e.message}`);
      this.topSt = ST_OFF;
    }
  }

  /** 热度条上「挑一部最近看的」：复用现成记录接口，不新增服务端依赖。 */
  private async loadPicks(): Promise<void> {
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/history?limit=6`, Store.I.token);
      const res: HistoryRes = JSON.parse(raw) as HistoryRes;
      const src: HistoryLite[] = res.items;
      const out: HeatPick[] = [];
      if (src !== undefined && src !== null) {
        for (let i = 0; i < src.length && out.length < 3; i++) {
          const it: HistoryLite = src[i];
          const id: number = num(it.id);
          if (id <= 0) {
            continue;
          }
          const label: string = str(it.number).length > 0 ? str(it.number) : str(it.title);
          if (label.length > 0) {
            out.push({ id: id, label: label });
          }
        }
      }
      this.picks = out;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats picks: ${e.code} ${e.message}`);
    }
  }

  // ---------------------------------------------------------------- 筛选动作

  /** 切换时间范围：预设直接算日期（含今天），自定义走两次日期选择。 */
  // ---- v2 四块的取数（弃片 / 流失曲线 / 吃灰 / 漏斗 / 冲突）----------------

  /**
   * Tier 图那块：只读服务端挑好的那张（`/tier/current`）。
   * 404 / `ok:false` → 整块不渲染（老服务端没有这个功能，不占位、不报错）。
   */
  private async loadTier(): Promise<void> {
    this.tierSt = ST_LOADING;
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/tier/current`, Store.I.token);
      const res: TierCurRes = JSON.parse(raw) as TierCurRes;
      if (res.data === undefined || res.data === null || res.data.tiers === undefined) {
        this.tierSt = ST_OFF;
        return;
      }
      const rows: TierCurRow[] = [];
      const thumbs: string[] = [];
      const src: TierCurRow[] = res.data.tiers;
      for (let i = 0; i < src.length; i++) {
        const r: TierCurRow = src[i];
        const items: TierCurItem[] = [];
        const rawItems: TierCurItem[] = r.items;
        if (rawItems !== undefined && rawItems !== null) {
          for (let j = 0; j < rawItems.length; j++) {
            const it: TierCurItem = rawItems[j];
            items.push({
              id: num(it.id),
              kind: str(it.kind),
              name: str(it.name),
              number: str(it.number),
              image: str(it.image),
              score: num(it.score)
            });
            if (thumbs.length < 6 && str(it.image).length > 0) {
              thumbs.push(str(it.image));
            }
          }
        }
        rows.push({ score: num(r.score), title: str(r.title), items: items, more: num(r.more) });
      }
      this.tierRows = rows;
      this.tierThumbs = thumbs;
      this.tierTotal = num(res.data.total);
      this.tierSt = res.ok === true && this.tierTotal > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] tier/current: ${e.code} ${e.message}`);
      this.tierSt = ST_OFF;
    }
  }

  private async loadDropoff(kind: string): Promise<void> {
    this.dropKind = kind;
    this.dropSt = ST_LOADING;
    try {
      const url: string =
        `${Store.I.user}/api/user/stats/dropoff${this.filterQs(`kind=${kind}&limit=10`)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: DropRes = JSON.parse(raw) as DropRes;
      if (res.data === undefined || res.data === null || res.data.items === undefined) {
        this.dropSt = ST_OFF;
        return;
      }
      const src: DropItem[] = res.data.items;
      const out: DropItem[] = [];
      if (src !== undefined && src !== null) {
        for (let i = 0; i < src.length; i++) {
          const it: DropItem = src[i];
          const row: DropItem = {
            id: num(it.id),
            name: str(it.name),
            opened: num(it.opened),
            dropped: num(it.dropped),
            rate: num(it.rate)
          };
          if (row.name.length > 0 && row.opened > 0) {
            out.push(row);
          }
        }
      }
      this.dropItems = out;
      this.dropOpened = num(res.data.opened);
      this.dropDropped = num(res.data.dropped);
      this.dropNote = str(res.reason);
      this.dropSt = res.ok === true && out.length > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/dropoff: ${e.code} ${e.message}`);
      this.dropSt = ST_OFF;
    }
  }

  private async loadDropCurve(): Promise<void> {
    this.curveSt = ST_LOADING;
    try {
      const url: string = `${Store.I.user}/api/user/stats/dropcurve${this.filterQs('')}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: DropCurveRes = JSON.parse(raw) as DropCurveRes;
      if (res.data === undefined || res.data === null) {
        this.curveSt = ST_OFF;
        return;
      }
      this.curveReached = nums(res.data.reached);
      this.curveBuckets = nums(res.data.buckets);
      this.curveFilms = num(res.data.films);
      this.curveNote = str(res.reason);
      this.curveSt = res.ok === true && maxOf(this.curveReached) > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/dropcurve: ${e.code} ${e.message}`);
      this.curveSt = ST_OFF;
    }
  }

  private async loadIdle(days: number): Promise<void> {
    this.idleDays = days;
    this.idleSt = ST_LOADING;
    try {
      const url: string = `${Store.I.user}/api/user/stats/idle${this.filterQs(`days=${days}`)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: IdleRes = JSON.parse(raw) as IdleRes;
      if (res.data === undefined || res.data === null) {
        this.idleSt = ST_OFF;
        return;
      }
      const films: IdleFilm[] = [];
      const srcF: IdleFilm[] = res.data.items;
      if (srcF !== undefined && srcF !== null) {
        for (let i = 0; i < srcF.length; i++) {
          const it: IdleFilm = srcF[i];
          films.push({
            id: num(it.id),
            number: str(it.number),
            title: str(it.title),
            fav_at: str(it.fav_at)
          });
        }
      }
      const actors: IdleActor[] = [];
      const srcA: IdleActor[] = res.data.cold_actors;
      if (srcA !== undefined && srcA !== null) {
        for (let i = 0; i < srcA.length; i++) {
          actors.push({ id: num(srcA[i].id), name: str(srcA[i].name), films: num(srcA[i].films) });
        }
      }
      const studios: IdleStudio[] = [];
      const srcS: IdleStudio[] = res.data.cold_studios;
      if (srcS !== undefined && srcS !== null) {
        for (let i = 0; i < srcS.length; i++) {
          studios.push({ name: str(srcS[i].name), films: num(srcS[i].films) });
        }
      }
      this.idleFilms = films;
      this.idleActors = actors;
      this.idleStudios = studios;
      this.idleTotal = num(res.data.total);
      this.idleNote = str(res.reason);
      this.idleSt = res.ok === true && this.idleTotal > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/idle: ${e.code} ${e.message}`);
      this.idleSt = ST_OFF;
    }
  }

  private async loadFunnel(days: number): Promise<void> {
    this.funDays = days;
    this.funSt = ST_LOADING;
    try {
      const url: string = `${Store.I.user}/api/user/stats/funnel${this.filterQs(`days=${days}`)}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: FunnelRes = JSON.parse(raw) as FunnelRes;
      if (res.data === undefined || res.data === null) {
        this.funSt = ST_OFF;
        return;
      }
      this.funFav = num(res.data.favorited);
      this.funOpened = num(res.data.opened);
      this.funFinished = num(res.data.finished);
      this.funOpenRate = num(res.data.open_rate);
      this.funOverall = num(res.data.overall);
      this.funNote = str(res.reason);
      this.funSt = res.ok === true && this.funFav > 0 ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/funnel: ${e.code} ${e.message}`);
      this.funSt = ST_OFF;
    }
  }

  private async loadConflict(): Promise<void> {
    this.cfSt = ST_LOADING;
    try {
      const url: string = `${Store.I.user}/api/user/stats/conflict${this.filterQs('')}`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: ConflictRes = JSON.parse(raw) as ConflictRes;
      if (res.data === undefined || res.data === null) {
        this.cfSt = ST_OFF;
        return;
      }
      const high: ConflictFilm[] = [];
      const srcH: ConflictFilm[] = res.data.high_low;
      if (srcH !== undefined && srcH !== null) {
        for (let i = 0; i < srcH.length; i++) {
          high.push({
            id: num(srcH[i].id),
            score: num(srcH[i].score),
            ratio: num(srcH[i].ratio),
            secs: num(srcH[i].secs),
            number: str(srcH[i].number),
            title: str(srcH[i].title)
          });
        }
      }
      const repeat: RepeatFilm[] = [];
      const srcR: RepeatFilm[] = res.data.repeats;
      if (srcR !== undefined && srcR !== null) {
        for (let i = 0; i < srcR.length; i++) {
          repeat.push({
            id: num(srcR[i].id),
            replays: num(srcR[i].replays),
            secs: num(srcR[i].secs),
            number: str(srcR[i].number),
            title: str(srcR[i].title)
          });
        }
      }
      this.cfHigh = high;
      this.cfRepeat = repeat;
      const up: UpstreamCmp = res.data.vs_upstream;
      if (up !== undefined && up !== null) {
        this.cfCount = num(up.count);
        this.cfMeanDiff = num(up.mean_diff);
        this.cfHarsh = num(up.harsh);
        this.cfGap = num(up.gap);
      } else {
        this.cfCount = 0;
      }
      this.cfNote = str(res.reason);
      this.cfSt = res.ok === true && (high.length > 0 || repeat.length > 0 || this.cfCount > 0)
        ? ST_OK : ST_EMPTY;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/conflict: ${e.code} ${e.message}`);
      this.cfSt = ST_OFF;
    }
  }

  private dropKindChips(): PickChip[] {    const out: PickChip[] = [];
    out.push({ id: 1, label: '演员', picked: this.dropKind === 'actor' });
    out.push({ id: 2, label: '标签', picked: this.dropKind === 'tag' });
    return out;
  }

  private dropKindOf(id: number): string {
    return id === 2 ? 'tag' : 'actor';
  }

  /**
   * v2 那几块（弃片 / 吃灰 / 漏斗 / 冲突）的「端点还没上线」文案。
   * 和 v1 分开写：v1 有顶部横幅统一说明「需要 1.4.0」，v2 是 1.4.x 又加的一批，
   * 混在一句里会把人说糊涂。
   */
  private v2OffText(): string {
    return '这个统计还没上线（服务端还没更新到这一批）';
  }

  private dropNoteText(): string {
    if (this.dropSt === ST_OFF) {
      return this.v2OffText();
    }
    return this.dropNote.length > 0 ? this.dropNote : '还在积累 —— 至少各打开几部';
  }

  private curveNoteText(): string {
    if (this.curveSt === ST_OFF) {
      return this.v2OffText();
    }
    return this.curveNote.length > 0 ? this.curveNote : '还在积累 —— 看完几部才有曲线';
  }

  private idleNoteText(): string {
    if (this.idleSt === ST_OFF) {
      return this.v2OffText();
    }
    return this.idleNote.length > 0 ? this.idleNote : '没有吃灰的，收得很克制';
  }

  private funNoteText(): string {
    if (this.funSt === ST_OFF) {
      return this.v2OffText();
    }
    return this.funNote.length > 0 ? this.funNote : `近 ${this.funDays} 天还没有新收藏`;
  }

  private cfNoteText(): string {
    if (this.cfSt === ST_OFF) {
      return this.v2OffText();
    }
    return this.cfNote.length > 0 ? this.cfNote : '还没出现明显的评分冲突';
  }

  /** 点弃片榜一行：演员进作品页、标签进影片墙（与偏榜一致）。 */
  private openDrop(it: DropItem): void {
    if (it.id <= 0) {
      return;
    }
    if (this.dropKind === 'actor') {
      const a: ActorNav = { id: it.id, name: it.name };
      router.pushUrl({ url: 'ext/actors/ActorWorksPage', params: a });
      return;
    }
    const f: FacetNav = { kind: 'tag', id: it.id, name: it.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: f });
  }

  private openFilm(id: number): void {
    if (id <= 0) {
      return;
    }
    const p: FilmNav = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  /**
   * 流失曲线的柱高：画的是**累计到达率** `reached[i]`（撑到第 i 档的片子占比），
   * 所以柱子从高到低走 —— 这是「多少人还留着」，不是直方图。
   */
  private curvePct(v: number): number {
    const r: number = num(v);
    const pct: number = r * 100;
    return pct < 3 ? 3 : pct;
  }

  /** 掉得最狠的那一档（相邻两个 reaching 的差值最大处）。没数据返回 -1。 */
  private curveDropBin(): number {
    if (this.curveReached.length < 2) {
      return -1;
    }
    let best: number = -1;
    let idx: number = -1;
    for (let i = 0; i < this.curveReached.length - 1; i++) {
      const fall: number = this.curveReached[i] - this.curveReached[i + 1];
      if (fall > best) {
        best = fall;
        idx = i;
      }
    }
    return best > 0 ? idx : -1;
  }

  /** 「最多人在 30%–40% 之间走掉」。 */
  private curveVerdict(): string {
    if (this.curveSt !== ST_OK) {
      return '';
    }
    const bin: number = this.curveDropBin();
    if (bin < 0) {
      return '';
    }
    const from: number = bin * 10;
    return `掉得最狠在 ${from}%–${from + 10}% 之间`;
  }

  /** 漏斗每段的宽度（以收藏为 100%）。 */
  private funnelPct(v: number): number {
    if (this.funFav <= 0) {
      return 0;
    }
    const pct: number = (num(v) / this.funFav) * 100;
    return pct > 100 ? 100 : pct;
  }

  /** 「我 vs 大众」那句：差异是 10 分制（我的 5 星 ×2）。 */
  private upstreamText(): string {
    if (this.cfCount <= 0) {
      return '';
    }
    const diff: number = this.cfMeanDiff;
    const abs: number = Math.abs(diff);
    let text: string = `${this.cfCount} 部有双评分，你平均比大众${diff >= 0 ? '高' : '低'} ${abs.toFixed(1)} 分`;
    if (this.cfHarsh > 0) {
      text += `；${Math.round(this.cfHarsh * 100)}% 的片子你给得更低`;
    }
    if (this.cfGap > 0) {
      text += `；${Math.round(this.cfGap * 100)}% 的片子差了 1.5 分以上`;
    }
    return text;
  }

  private applyRange(key: string): void {
    if (key === 'custom') {
      this.pickRange();
      return;
    }
    this.rangeKey = key;
    if (key === 'all') {
      this.rangeFrom = '';
      this.rangeTo = '';
    } else {
      const days: number = key === '7' ? 7 : (key === '30' ? 30 : 90);
      const to: Date = new Date();
      const from: Date = new Date(to.getTime() - (days - 1) * 86400000);
      this.rangeFrom = ymd(from);
      this.rangeTo = ymd(to);
    }
    this.reload();
  }

  /** 自定义范围：先选起、再选止；第二步取消就整体放弃，不留半截状态。 */
  private pickRange(): void {
    const start: Date = this.rangeFrom.length > 0
      ? parseYmd(this.rangeFrom) : new Date(Date.now() - 29 * 86400000);
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: start,
      onAccept: (v: DatePickerResult) => {
        const from: string = ymd(new Date(Number(v.year), Number(v.month), Number(v.day)));
        const end: Date = this.rangeTo.length > 0 ? parseYmd(this.rangeTo) : new Date();
        DatePickerDialog.show({
          start: parseYmd(from),
          end: new Date(2100, 11, 31),
          selected: end,
          onAccept: (v2: DatePickerResult) => {
            const to: string = ymd(new Date(Number(v2.year), Number(v2.month), Number(v2.day)));
            this.rangeKey = 'custom';
            this.rangeFrom = from <= to ? from : to;
            this.rangeTo = from <= to ? to : from;
            this.reload();
          }
        });
      }
    });
  }

  /** 切换数据口径：真实 / 测试。测试口径是验收用的模拟数据，两头物理分开。 */
  private switchScope(key: string): void {
    if (this.scopeKey === key) {
      return;
    }
    this.scopeKey = key;
    this.reload();
  }

  /** 清除某段采样 —— 真数据删了就回不来，所以必须二次确认且必须有范围。 */
  private confirmPurge(): void {
    if (this.rangeFrom.length === 0 || this.rangeTo.length === 0) {
      promptAction.showToast({ message: '先选一段范围才能清除', duration: 1800 });
      return;
    }
    const what: string = this.scopeKey === 'test' ? '测试数据' : '真实观看记录';
    AlertDialog.show({
      title: '清除这段统计？',
      message: `${this.rangeFrom} ~ ${this.rangeTo} 的${what}会被删掉，删了无法恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: Theme.ACCENT,
        action: () => {
          this.purgeRange();
        }
      }
    });
  }

  private async purgeRange(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const body: string = JSON.stringify({
        from: this.rangeFrom,
        to: this.rangeTo,
        scope: this.scopeKey === 'test' ? 'test' : 'real'
      });
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/stats/purge`, Store.I.token, body);
      const res: PurgeRes = JSON.parse(raw) as PurgeRes;
      promptAction.showToast({ message: `已清除 ${num(res.removed)} 条采样`, duration: 1800 });
      this.reload();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/purge: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '清除失败，稍后再试', duration: 1800 });
    } finally {
      this.busy = false;
    }
  }

  /** 生成一批模拟采样（只写测试口径），验收看图用。 */
  private async genTestData(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/stats/testdata`, Store.I.token,
        JSON.stringify({ films: 6, days: 28 }));
      const res: TestDataRes = JSON.parse(raw) as TestDataRes;
      promptAction.showToast({
        message: `已生成 ${num(res.films)} 部 / ${num(res.samples)} 条测试采样`,
        duration: 2000
      });
      this.scopeKey = 'test';
      this.reload();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/testdata: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '生成失败：服务端可能还是旧版', duration: 2000 });
    } finally {
      this.busy = false;
    }
  }

  /** 清空全部测试采样（不动真实数据）。 */
  private async purgeTestData(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/stats/purge`, Store.I.token,
        JSON.stringify({ scope: 'test' }));
      const res: PurgeRes = JSON.parse(raw) as PurgeRes;
      promptAction.showToast({ message: `已清空 ${num(res.removed)} 条测试采样`, duration: 1800 });
      this.reload();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/test purge: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '清空失败', duration: 1800 });
    } finally {
      this.busy = false;
    }
  }

  /** 标签清理建议：只在看标签榜时拉，避免每次进页面都多打一次请求。 */
  private async loadHygiene(): Promise<void> {
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/stats/tag-hygiene?limit=12`, Store.I.token);
      const res: HygieneRes = JSON.parse(raw) as HygieneRes;
      if (res.data === undefined || res.data === null || res.data.items === undefined) {
        this.hygiene = [];
        return;
      }
      const src: HygieneItem[] = res.data.items;
      const out: HygieneItem[] = [];
      for (let i = 0; i < src.length; i++) {
        const it: HygieneItem = src[i];
        const row: HygieneItem = {
          id: num(it.id),
          name: str(it.name),
          films: num(it.films),
          coverage: num(it.coverage),
          reason: str(it.reason)
        };
        if (row.id > 0 && row.name.length > 0) {
          out.push(row);
        }
      }
      this.hygiene = out;
      this.hygieneHidden = num(res.data.hidden);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] stats/tag-hygiene: ${e.code} ${e.message}`);
      this.hygiene = [];
    }
  }

  /** 隐藏一个标签：写的是 facets 的 `facet_hidden`，列表/筛选/统计用的是同一张表。 */
  private async hideTag(it: HygieneItem): Promise<void> {
    try {
      await httpPost(`${Store.I.user}/api/user/facets/tag/${it.id}/hide`,
        Store.I.token, JSON.stringify({ hidden: true }));
      const left: HygieneItem[] = [];
      for (let i = 0; i < this.hygiene.length; i++) {
        if (this.hygiene[i].id !== it.id) {
          left.push(this.hygiene[i]);
        }
      }
      this.hygiene = left;
      this.hygieneHidden = this.hygieneHidden + 1;
      promptAction.showToast({ message: `已隐藏「${it.name}」`, duration: 1600 });
      this.loadTop('tag');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] facet hide: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '隐藏失败', duration: 1600 });
    }
  }

  private hygieneReason(reason: string): string {
    if (reason === 'near_all') {
      return '几乎每部都有，没有区分度';
    }
    if (reason === 'studio_name') {
      return '和厂牌同名，多半是刮削塞进来的';
    }
    return '像编号或站点名，不是内容标签';
  }

  // ---------------------------------------------------------------- 计算

  /** 「数据够 / 数据少 / 只能估算」；full 不标（标了反而噪音）。 */
  private confLabel(): string {
    if (this.srvConf === 'sparse') {
      return '数据少';
    }
    if (this.srvConf === 'estimate') {
      return '只能估算';
    }
    return '';
  }

  private offText(): string {
    return '还没开启';
  }

  /** 任意一块命中「端点不存在」→ 顶部给一条横幅说明一次，不用五块各喊一遍。 */
  private offAny(): boolean {
    return this.ovSt === ST_OFF || this.trSt === ST_OFF || this.whenSt === ST_OFF
      || this.heatSt === ST_OFF || this.topSt === ST_OFF;
  }

  private ovNoteText(): string {
    if (this.ovSt === ST_OFF) {
      return this.offText();
    }
    return this.ovNote.length > 0 ? this.ovNote : '还没有观看记录，看几部再回来';
  }

  private trNoteText(): string {
    if (this.trSt === ST_OFF) {
      return this.offText();
    }
    return this.trNote.length > 0 ? this.trNote : '还没有足够的记录画趋势';
  }

  private whenNoteText(): string {
    if (this.whenSt === ST_OFF) {
      return this.offText();
    }
    return this.whenNote.length > 0 ? this.whenNote : '还没有足够的记录看时段';
  }

  private heatNoteText(): string {
    if (this.heatSt === ST_OFF) {
      return this.offText();
    }
    return this.heatNote.length > 0 ? this.heatNote : '这部片的观看位置还在积累';
  }

  private topNoteText(): string {
    if (this.topSt === ST_OFF) {
      return this.offText();
    }
    return this.topNote.length > 0 ? this.topNote : '还没有足够记录排榜';
  }

  /** 柱高百分比：按最大值归一，最小给 4% 让空周也有个底。 */
  private barPct(v: number): number {
    const max: number = Math.max(1, maxOf(this.filmCounts(this.tr)));
    const pct: number = (num(v) / max) * 100;
    return pct < 4 ? 4 : pct;
  }

  /**
   * 完成率折线的点。本周没有片（`films = 0`）就跳过 —— 连过去会画出一条假线段。
   * `Polyline.points` 吃的是 vp 数值，所以必须等 `onAreaChange` 量到宽度。
   */
  private ratePoints(): number[][] {
    const pts: number[][] = [];
    const n: number = this.tr.length;
    if (n < 2 || this.trendW <= 1) {
      return pts;
    }
    const step: number = this.trendW / (n - 1);
    for (let i = 0; i < n; i++) {
      const w: TrendWeek = this.tr[i];
      if (num(w.films) <= 0) {
        continue;
      }
      let rate: number = num(w.rate);
      if (rate > 1) {
        rate = 1;
      }
      if (rate < 0) {
        rate = 0;
      }
      pts.push([i * step, TREND_H - rate * TREND_H]);
    }
    return pts;
  }

  private hourPct(v: number): number {
    const max: number = Math.max(1, maxOf(this.hours));
    const pct: number = (num(v) / max) * 100;
    return pct < 4 ? 4 : pct;
  }

  private dayPct(v: number): number {
    const max: number = Math.max(1, maxOf(this.weekdays));
    const pct: number = (num(v) / max) * 100;
    return pct < 4 ? 4 : pct;
  }

  private dayName(i: number): string {
    const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
    if (i < 0 || i >= names.length) {
      return '';
    }
    return names[i];
  }

  /** 一条结论句，比让人自己读 24 根柱子好用。 */
  private whenVerdict(): string {
    if (this.whenSt !== ST_OK) {
      return '';
    }
    let text: string = '';
    if (this.peakHour >= 0) {
      text = `最常在 ${this.peakHour} 点`;
    }
    if (this.peakDay >= 0) {
      text += text.length > 0 ? `、周${this.dayName(this.peakDay)}` : `最常在周${this.dayName(this.peakDay)}`;
    }
    return text.length > 0 ? `${text}看片` : '';
  }

  /** 热度桶已是 0–1，直接用；防御脏数据。 */
  private heatIntensity(v: number): number {
    const r: number = num(v);
    if (r < 0) {
      return 0;
    }
    return r > 1 ? 1 : r;
  }

  /** 最热那一段的百分比区间。 */
  private heatPeakText(): string {
    if (this.heatSt !== ST_OK || this.heatPeakBucket < 0) {
      return '';
    }
    const from: number = Math.round(this.heatPeakBucket * this.heatBucketPct);
    const to: number = Math.round((this.heatPeakBucket + 1) * this.heatBucketPct);
    return `最常停在 ${from}%–${to}% 这段`;
  }

  private heatChips(): PickChip[] {
    const out: PickChip[] = [];
    out.push({ id: 0, label: '全库平均', picked: this.heatMid <= 0 });
    for (let i = 0; i < this.picks.length; i++) {
      const p: HeatPick = this.picks[i];
      out.push({ id: p.id, label: p.label, picked: this.heatMid === p.id });
    }
    return out;
  }

  private kindChips(): PickChip[] {
    const out: PickChip[] = [];
    out.push({ id: 1, label: '演员', picked: this.topKind === 'actor' });
    out.push({ id: 2, label: '标签', picked: this.topKind === 'tag' });
    out.push({ id: 3, label: '厂牌', picked: this.topKind === 'studio' });
    return out;
  }

  private kindOf(id: number): string {
    if (id === 2) {
      return 'tag';
    }
    if (id === 3) {
      return 'studio';
    }
    return 'actor';
  }

  private pickHeat(mid: number, label: string): void {
    if (mid === this.heatMid) {
      return;
    }
    this.heatMid = mid;
    this.heatTitle = mid > 0 ? label : '';
    this.loadHeat(mid);
  }

  /**
   * 偏好榜点一行。
   *
   * 演员 / 标签有真 id，直接跳；**制片商服务端给的是 `id = 0`**（metadata 上只存名字），
   * 所以点的时候现查一次 id 再跳，查不到就提示，不把人带进一个空页面。
   */
  private openTop(it: TopItem): void {
    if (this.topKind === 'actor' || this.topKind === 'tag') {
      if (it.id <= 0) {
        promptAction.showToast({ message: '这条没有可跳转的 id', duration: 1500 });
        return;
      }
      const f: FacetNav = { kind: this.topKind, id: it.id, name: it.name };
      if (this.topKind === 'actor') {
        const a: ActorNav = { id: it.id, name: it.name };
        router.pushUrl({ url: 'ext/actors/ActorWorksPage', params: a });
        return;
      }
      router.pushUrl({ url: 'ext/facets/FacetPage', params: f });
      return;
    }
    this.openStudio(it.name);
  }

  private async openStudio(name: string): Promise<void> {
    try {
      const url: string = `${Store.I.user}/api/user/facets/studio?search=${encodeURIComponent(name)}&limit=1`;
      const raw: string = await httpGet(url, Store.I.token);
      const res: FacetListRes = JSON.parse(raw) as FacetListRes;
      const list: FacetItem[] = res.items;
      if (list === undefined || list === null || list.length === 0 || num(list[0].id) <= 0) {
        promptAction.showToast({ message: `找不到「${name}」的分类页`, duration: 1600 });
        return;
      }
      const f: FacetNav = { kind: 'studio', id: num(list[0].id), name: str(list[0].name) };
      router.pushUrl({ url: 'ext/facets/FacetPage', params: f });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] studio resolve: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '打不开这个厂牌', duration: 1600 });
    }
  }

  // ---------------------------------------------------------------- 视图 · 筛选

  private rangeChips(): PickChip[] {
    const out: PickChip[] = [];
    out.push({ id: 1, label: '全部', picked: this.rangeKey === 'all' });
    out.push({ id: 2, label: '近 7 天', picked: this.rangeKey === '7' });
    out.push({ id: 3, label: '近 30 天', picked: this.rangeKey === '30' });
    out.push({ id: 4, label: '近 90 天', picked: this.rangeKey === '90' });
    out.push({ id: 5, label: '自定义', picked: this.rangeKey === 'custom' });
    return out;
  }

  private rangeKeyOf(id: number): string {
    if (id === 1) {
      return 'all';
    }
    if (id === 2) {
      return '7';
    }
    if (id === 3) {
      return '30';
    }
    if (id === 4) {
      return '90';
    }
    return 'custom';
  }

  private scopeChips(): PickChip[] {
    const out: PickChip[] = [];
    out.push({ id: 1, label: `真实 ${this.scopeSamples.real} 条`, picked: this.scopeKey === 'real' });
    out.push({ id: 2, label: `测试 ${this.scopeSamples.test} 条`, picked: this.scopeKey === 'test' });
    return out;
  }

  /** 当前生效的范围说明：有筛选写筛选，没筛选写「数据从哪到哪」。 */
  private rangeText(): string {
    if (this.rangeFrom.length > 0 && this.rangeTo.length > 0) {
      return `${this.rangeFrom} ~ ${this.rangeTo}`;
    }
    if (this.availFrom.length > 0) {
      return `全部记录 · ${this.availFrom} ~ ${this.availTo.length > 0 ? this.availTo : '今天'}`;
    }
    return '全部记录';
  }

  /**
   * 顶部筛选条：时间范围 + 数据口径 + 清除。
   *
   * 为什么要这两排：统计一改范围结果就该变，不能所有历史一股脑堆进来；测试版还要能
   * 在「真实」与「模拟」之间切，否则验收时看到的数字和真实情况永远是两回事。
   * 老服务端（口径版本 <2）没有这两个参数，整条隐藏 —— 给了控件却不起作用更糟。
   */
  @Builder
  FilterBar() {
    if (this.srvFlags) {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          ForEach(this.rangeChips(), (c: PickChip) => {
            Text(c.label)
              .fontSize(10)
              .fontColor(c.picked ? Theme.ON_ACCENT : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(c.picked ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(11)
              .maxLines(1)
              .onClick(() => {
                this.applyRange(this.rangeKeyOf(c.id));
              })
          }, (c: PickChip) => `rg-${c.id}-${c.label}-${c.picked ? 1 : 0}`)
        }
        .width('100%')

        Row({ space: 6 }) {
          ForEach(this.scopeChips(), (c: PickChip) => {
            Text(c.label)
              .fontSize(10)
              .fontColor(c.picked ? Theme.ON_ACCENT : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(c.picked ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(11)
              .maxLines(1)
              .onClick(() => {
                this.switchScope(c.id === 2 ? 'test' : 'real');
              })
          }, (c: PickChip) => `sc-${c.id}-${c.label}-${c.picked ? 1 : 0}`)
          Blank()
        }
        .width('100%')

        Row({ space: 8 }) {
          Text(this.rangeText())
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .layoutWeight(1)
            .maxLines(1)
          if (this.rangeFrom.length > 0) {
            Text('清除这段')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(9)
              .backgroundColor(Theme.alphaOf(Theme.ACCENT, 0.14))
              .onClick(() => {
                this.confirmPurge();
              })
          }
        }
        .width('100%')

        if (this.scopeKey === 'test') {
          Row({ space: 8 }) {
            Text('模拟采样 · 不是你看的片，验收用完记得清')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
            Text(this.busy ? '…' : '重新生成')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .onClick(() => {
                this.genTestData();
              })
            Text('清空')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .onClick(() => {
                this.purgeTestData();
              })
          }
          .width('100%')
        } else if (this.scopeSamples.test === 0 && this.scopeSamples.real === 0) {
          Row({ space: 8 }) {
            Text('还没有数据。想先看页面长什么样？')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
            Text('生成测试数据')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .onClick(() => {
                this.genTestData();
              })
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor(Theme.CARD)
      .borderRadius(12)
    }
  }

  /** 「该隐藏哪些标签」的抽屉：一条一条给理由，点一下才隐藏。 */
  @Builder
  HygieneSheet() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('该隐藏的标签')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
          Text(`已隐藏 ${this.hygieneHidden} 个 · 隐藏后列表、筛选、统计都不会再出现`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('关闭')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.hygieneSheet = false;
          })
      }
      .width('100%')

      if (this.hygiene.length === 0) {
        Text('暂时没有建议。标签列表干净，或者已经全藏好了。')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.hygiene, (it: HygieneItem) => {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(it.name)
                    .fontSize(12)
                    .fontColor(Theme.TEXT)
                    .maxLines(1)
                  Text(`${num(it.films)} 部 · ${this.hygieneReason(it.reason)}`)
                    .fontSize(9)
                    .fontColor(Theme.TEXT_FAINT)
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('隐藏')
                  .fontSize(10)
                  .fontColor(Theme.ON_ACCENT)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(11)
                  .onClick(() => {
                    this.hideTag(it);
                  })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(10)
            }, (it: HygieneItem) => `hy-${it.id}`)
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 360 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 14, bottom: 24 })
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('观看统计')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('只算这台设备看到的，看越多越准')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text('⟳')
        .fontSize(17)
        .fontColor(Theme.TEXT_DIM)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.reload();
        })
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })
  }

  /** 块标题：左边名字，右边一句小字（可信度 / 采样）。静态读 this，不吃传参。 */
  @Builder
  SectionHead(title: string, kind: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Blank()
      if (this.metaOf(kind).length > 0) {
        Text(this.metaOf(kind))
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .width('100%')
  }

  private metaOf(kind: string): string {
    if (kind === 'ov') {
      return this.confLabel();
    }
    if (kind === 'tr') {
      return this.rangeFrom.length > 0 ? '按所选范围' : `近 ${TREND_WEEKS} 周`;
    }
    if (kind === 'heat') {
      if (this.heatSt !== ST_OK) {
        return '';
      }
      return `共 ${fmtDur(this.heatTotal)}`;
    }
    return '';
  }

  /** 概览的一个格子（大数字 + 单位 + 说明）。 */
  @Builder
  BigCell(kind: string, label: string) {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        Text(this.bigValue(kind))
          .fontSize(23)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(this.bigSuffix(kind))
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
          .margin({ top: 8 })
      }
      .alignItems(VerticalAlign.Top)
      Text(label)
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
    }
    .layoutWeight(1)
    .height(72)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(10)
  }

  private bigValue(kind: string): string {
    if (kind === 'films') {
      return `${num(this.ov.films)}`;
    }
    if (kind === 'hours') {
      return bigNum(this.ov.seconds);
    }
    if (kind === 'days') {
      return `${num(this.ov.days)}`;
    }
    return `${num(this.ov.longest_streak)}`;
  }

  private bigSuffix(kind: string): string {
    if (kind === 'films') {
      return '部';
    }
    if (kind === 'hours') {
      return bigUnit(this.ov.seconds);
    }
    return '天';
  }

  @Builder
  OverviewBlock() {
    Column({ space: 12 }) {
      this.SectionHead('概览', 'ov')

      if (this.ovSt === ST_OK) {
        Row({ space: 10 }) {
          this.BigCell('films', '看过')
          this.BigCell('hours', '累计观看')
        }
        .width('100%')

        Row({ space: 10 }) {
          this.BigCell('days', '有记录的天数')
          this.BigCell('streak', '最长连续')
        }
        .width('100%')

        if (this.footNote().length > 0) {
          Text(this.footNote())
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
        }
        // 数据质量摊开写：可疑 = 拖动/回拖，丢弃 = 时长为 0 / 找不到影片。
        // 筛了范围或切了口径时服务端给 -1（这类计数不按日存），那就整行不显示 —— 
        // 摆一个「-1」比不显示更像 bug。
        if (num(this.ov.samples) > 0 && num(this.ov.suspicious) >= 0) {
          Text(`采样 ${num(this.ov.samples)} 条 · 可疑 ${num(this.ov.suspicious)} · 丢弃 ${num(this.ov.dropped)}`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
        }
        if (this.scopeKey === 'test' && this.srvFlags) {
          Text('当前是测试口径：这些数字来自模拟采样，不是真实观看记录。')
            .fontSize(9)
            .fontColor(Theme.GOLD)
            .width('100%')
        }
      } else if (this.ovSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.ovNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  private footNote(): string {
    let text: string = '';
    if (this.rangeFrom.length > 0 && this.rangeTo.length > 0) {
      text = `范围 ${this.rangeFrom} ~ ${this.rangeTo}`;
    } else if (this.ov.to.length > 0) {
      text = `统计截至 ${this.ov.to}`;
    }
    if (this.srvVer > 0) {
      text += text.length > 0 ? ` · 口径 v${this.srvVer}` : `口径 v${this.srvVer}`;
    }
    if (num(this.ov.finished) > 0) {
      text += text.length > 0 ? ` · 看完 ${num(this.ov.finished)} 部` : `看完 ${num(this.ov.finished)} 部`;
    }
    return text;
  }

  /** 柱子渐变：选中那周用亮色，其余压暗（不要在 build 里写三元数组字面量，类型推不出来）。 */
  private barColors(i: number): Array<[string, number]> {
    if (this.trPick === i) {
      return [[Theme.ACCENT2, 0.0], [Theme.ACCENT, 1.0]];
    }
    return [[Theme.ACCENT, 0.0], [Theme.accentAlpha(0.42), 1.0]];
  }

  @Builder
  TrendBlock() {
    Column({ space: 10 }) {
      this.SectionHead('趋势', 'tr')

      if (this.trSt === ST_OK) {
        // 柱 = 每周看了几部；折线 = 那一周的完成率。叠着看才有意义：
        // 「看得多但都弃了」和「看得少但都看完了」是两种人。
        Stack({ alignContent: Alignment.BottomStart }) {
          Row({ space: 3 }) {
            ForEach(this.tr, (w: TrendWeek, i: number) => {
              Column() {
                Column()
                  .width('100%')
                  .height(`${this.barPct(w.films)}%`)
                  .borderRadius(3)
                  .linearGradient({
                    angle: 180,
                    colors: this.barColors(i)
                  })
              }
              .layoutWeight(1)
              .height('100%')
              .justifyContent(FlexAlign.End)
              .onClick(() => {
                this.trPick = this.trPick === i ? -1 : i;
              })
            }, (w: TrendWeek, i: number) => `tw-${i}`)
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Bottom)

          if (this.trendW > 1 && this.ratePoints().length > 1) {
            Polyline()
              .width('100%')
              .height('100%')
              .points(this.ratePoints())
              .stroke(Theme.GOLD)
              .strokeWidth(1.5)
              .fill('#00000000')
              .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .height(TREND_H)
        .onAreaChange((_old: Area, now: Area) => {
          const w: number = Number(now.width);
          if (w > 1 && Math.abs(w - this.trendW) > 1) {
            this.trendW = w;
          }
        })

        Row() {
          ForEach(this.tr, (w: TrendWeek, i: number) => {
            Text(i % 3 === 0 ? mdOf(w.from) : '')
              .fontSize(8)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }, (w: TrendWeek, i: number) => `tl-${i}`)
        }
        .width('100%')

        Row({ space: 6 }) {
          Text('▮')
            .fontSize(9)
            .fontColor(Theme.ACCENT)
          Text('每周部数')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
          Text('—')
            .fontSize(9)
            .fontColor(Theme.GOLD)
          Text('完成率')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
          Blank()
          Text(this.trPick >= 0 ? '再点一次收起' : '点一根看细节')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')

        if (this.trPick >= 0 && this.trPick < this.tr.length) {
          Text(this.weekDetail(this.tr[this.trPick]))
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
        }
      } else if (this.trSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.trNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  private weekDetail(w: TrendWeek): string {
    const rate: number = Math.round(num(w.rate) * 100);
    return `${mdOf(w.from)} 那周：${num(w.films)} 部 · ${fmtDur(w.seconds)} · 完成 ${rate}%`;
  }

  @Builder
  WhenBlock() {
    Column({ space: 12 }) {
      this.SectionHead('时段与星期', 'when')

      if (this.whenSt === ST_OK) {
        Column({ space: 6 }) {
          Text('一天里（按观看时长）')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Row({ space: 2 }) {
            ForEach(this.hours, (v: number, i: number) => {
              Column()
                .layoutWeight(1)
                .height(`${this.hourPct(v)}%`)
                .backgroundColor(i === this.peakHour
                  ? Theme.ACCENT
                  : Theme.alphaOf(Theme.ACCENT, 0.26))
                .borderRadius(2)
            }, (v: number, i: number) => `hh-${i}`)
          }
          .width('100%')
          .height(56)
          .alignItems(VerticalAlign.Bottom)

          Row() {
            ForEach([0, 6, 12, 18, 23], (h: number) => {
              Text(`${h} 点`)
                .fontSize(8)
                .fontColor(Theme.TEXT_FAINT)
                .layoutWeight(1)
                .textAlign(h === 0 ? TextAlign.Start : (h === 23 ? TextAlign.End : TextAlign.Center))
            }, (h: number) => `hl-${h}`)
          }
          .width('100%')
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('一周里')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Row({ space: 4 }) {
            ForEach(this.weekdays, (v: number, i: number) => {
              Column() {
                Column()
                  .width('100%')
                  .height(`${this.dayPct(v)}%`)
                  .backgroundColor(i === this.peakDay
                    ? Theme.ACCENT
                    : Theme.alphaOf(Theme.ACCENT, 0.26))
                  .borderRadius(2)
              }
              .layoutWeight(1)
              .height(40)
              .justifyContent(FlexAlign.End)
            }, (v: number, i: number) => `wd-${i}`)
          }
          .width('100%')

          Row() {
            ForEach([0, 1, 2, 3, 4, 5, 6], (i: number) => {
              Text(this.dayName(i))
                .fontSize(9)
                .fontColor(i === this.peakDay ? Theme.TEXT : Theme.TEXT_FAINT)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            }, (i: number) => `dl-${i}`)
          }
          .width('100%')
        }
        .width('100%')

        if (this.whenVerdict().length > 0) {
          Text(this.whenVerdict())
            .fontSize(11)
            .fontColor(Theme.ACCENT)
            .width('100%')
        }
      } else if (this.whenSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.whenNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  @Builder
  HeatBlock() {
    Column({ space: 10 }) {
      this.SectionHead(this.heatTitle.length > 0 ? `最热片段 · ${this.heatTitle}` : '最热片段', 'heat')

      // 挑一部：全库平均之外还能看单片，数据来自现成的观看记录接口
      if (this.heatChips().length > 1) {
        Row({ space: 6 }) {
          ForEach(this.heatChips(), (c: PickChip) => {
            Text(c.label)
              .fontSize(10)
              .fontColor(c.picked ? Theme.ON_ACCENT : Theme.TEXT_DIM)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(c.picked ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(11)
              .maxLines(1)
              .onClick(() => {
                this.pickHeat(c.id, c.label);
              })
          }, (c: PickChip) => `hp-${c.id}-${c.picked ? 1 : 0}`)
        }
        .width('100%')
      }

      if (this.heatSt === ST_OK) {
        Row({ space: 2 }) {
          ForEach(this.buckets, (v: number, i: number) => {
            Column()
              .layoutWeight(1)
              .height(10 + 30 * this.heatIntensity(v))
              .backgroundColor(Theme.alphaOf(Theme.ACCENT, 0.16 + 0.84 * this.heatIntensity(v)))
              .borderRadius(2)
          }, (v: number, i: number) => `hb-${i}`)
        }
        .width('100%')
        .height(42)
        .alignItems(VerticalAlign.Bottom)

        Row() {
          ForEach([0, 25, 50, 75, 100], (p: number) => {
            Text(`${p}%`)
              .fontSize(8)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
              .textAlign(p === 0 ? TextAlign.Start : (p === 100 ? TextAlign.End : TextAlign.Center))
          }, (p: number) => `hx-${p}`)
        }
        .width('100%')

        if (this.heatPeakText().length > 0) {
          Text(this.heatPeakText())
            .fontSize(11)
            .fontColor(Theme.ACCENT)
            .width('100%')
        }
      } else if (this.heatSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.heatNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  @Builder
  TopBlock() {
    Column({ space: 10 }) {
      this.SectionHead('偏好榜', 'top')

      Row({ space: 6 }) {
        ForEach(this.kindChips(), (c: PickChip) => {
          Text(c.label)
            .fontSize(11)
            .fontColor(c.picked ? Theme.ON_ACCENT : Theme.TEXT_DIM)
            .padding({ left: 11, right: 11, top: 4, bottom: 4 })
            .backgroundColor(c.picked ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(11)
            .onClick(() => {
              if (this.topKind !== this.kindOf(c.id)) {
                this.loadTop(this.kindOf(c.id));
              }
            })
        }, (c: PickChip) => `tc-${c.id}-${c.picked ? 1 : 0}`)
        Blank()
      }
      .width('100%')

      if (this.topSt === ST_OK) {
        Column() {
          ForEach(this.topItems, (it: TopItem, i: number) => {
            Row({ space: 10 }) {
              Text(`${i + 1}`)
                .fontSize(11)
                .fontWeight(i < 3 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(i < 3 ? Theme.ACCENT : Theme.TEXT_FAINT)
                .width(18)
                .textAlign(TextAlign.Center)
              Text(it.name)
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .maxLines(1)
                .layoutWeight(1)
              Text(`${num(it.films)} 部 · ${fmtDur(it.seconds)}`)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
              Text('›')
                .fontSize(14)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .padding({ top: 9, bottom: 9 })
            .onClick(() => {
              this.openTop(it);
            })

            if (i < this.topItems.length - 1) {
              Divider()
                .strokeWidth(0.5)
                .color('#14FFFFFF')
            }
          }, (it: TopItem) => `ti-${it.id}-${it.name}-${it.films}`)
        }
        .width('100%')
      } else if (this.topSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.topNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }

      Text('按看过的部数排，时长作参考；点一行进那个演员 / 标签 / 厂牌的影片墙。')
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')

      // 标签榜才提「清理建议」：用户在这里最容易看出哪些标签没意义，
      // 而且隐藏之后这一块立刻变干净 —— 比在设置里凭记忆维护强。
      if (this.topKind === 'tag' && this.hygiene.length > 0) {
        Row({ space: 8 }) {
          Text(`有 ${this.hygiene.length} 个标签可能没意义（几乎每部都有 / 像编号名），藏掉后这一块更准`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .layoutWeight(1)
            .maxLines(3)
          Text('去处理')
            .fontSize(9)
            .fontColor(Theme.ON_ACCENT)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.hygieneSheet = true;
            })
        }
        .width('100%')
        .padding({ left: 9, right: 9, top: 8, bottom: 8 })
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(10)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  private ratePct(r: number): number {
    const p: number = num(r) * 100;
    if (p < 2) {
      return 2;
    }
    return p > 100 ? 100 : p;
  }

  /** 弃片榜 + 开头流失曲线：同一件事的两面（谁让我弃 / 我在第几分钟弃）。 */
  @Builder
  DropBlock() {
    Column({ space: 10 }) {
      this.SectionHead('弃片榜', 'drop')

      Row({ space: 6 }) {
        ForEach(this.dropKindChips(), (c: PickChip) => {
          Text(c.label)
            .fontSize(11)
            .fontColor(c.picked ? Theme.ON_ACCENT : Theme.TEXT_DIM)
            .padding({ left: 11, right: 11, top: 4, bottom: 4 })
            .backgroundColor(c.picked ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(11)
            .onClick(() => {
              const k: string = this.dropKindOf(c.id);
              if (this.dropKind !== k) {
                this.loadDropoff(k);
              }
            })
        }, (c: PickChip) => `dk-${c.id}-${c.picked ? 1 : 0}`)
        Blank()
      }
      .width('100%')

      if (this.dropSt === ST_OK) {
        Text(`打开 ${this.dropOpened} 部，弃了 ${this.dropDropped} 部`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')

        Column() {
          ForEach(this.dropItems, (it: DropItem, i: number) => {
            Row({ space: 10 }) {
              Text(`${i + 1}`)
                .fontSize(11)
                .fontColor(i < 3 ? Theme.TEXT : Theme.TEXT_FAINT)
                .width(16)
                .textAlign(TextAlign.Center)
              Column({ space: 4 }) {
                Text(it.name)
                  .fontSize(13)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                Stack({ alignContent: Alignment.Start }) {
                  Column()
                    .width('100%')
                    .height(3)
                    .borderRadius(2)
                    .backgroundColor('#1FFFFFFF')
                  Column()
                    .width(`${this.ratePct(it.rate)}%`)
                    .height(3)
                    .borderRadius(2)
                    .backgroundColor(Theme.DANGER)
                }
                .width('100%')
                .height(3)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 2 }) {
                Text(`${Math.round(num(it.rate) * 100)}%`)
                  .fontSize(12)
                  .fontColor(Theme.DANGER)
                Text(`${num(it.dropped)}/${num(it.opened)} 部`)
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width(56)
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              this.openDrop(it);
            })
          }, (it: DropItem) => `dp-${it.id}-${it.dropped}-${it.opened}`)
        }
        .width('100%')
      } else if (this.dropSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.dropNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }

      Divider()
        .strokeWidth(0.5)
        .color('#14FFFFFF')

      Text('看到百分之多少就不看了（柱 = 还留着的人）')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')

      if (this.curveSt === ST_OK) {
        Row({ space: 3 }) {
          ForEach(this.curveReached, (v: number, i: number) => {
            Column()
              .layoutWeight(1)
              .height(`${this.curvePct(v)}%`)
              .backgroundColor(i === this.curveDropBin()
                ? Theme.DANGER
                : Theme.alphaOf(Theme.DANGER, 0.3))
              .borderRadius(2)
          }, (v: number, i: number) => `cv-${i}-${i === this.curveDropBin() ? 1 : 0}`)
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Bottom)

        Row() {
          ForEach([0, 50, 100], (p: number) => {
            Text(`${p}%`)
              .fontSize(8)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
              .textAlign(p === 0 ? TextAlign.Start : (p === 100 ? TextAlign.End : TextAlign.Center))
          }, (p: number) => `cx-${p}`)
        }
        .width('100%')

        if (this.curveVerdict().length > 0) {
          Text(this.curveVerdict())
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
        }
      } else if (this.curveSt === ST_LOADING) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(Theme.ACCENT)
      } else {
        Text(this.curveNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  /** 吃灰清单：收藏了却一次没打开；顺带「冷落演员 / 冷落厂牌」。 */
  @Builder
  IdleBlock() {
    Column({ space: 10 }) {
      this.SectionHead('吃灰清单', 'idle')

      if (this.idleSt === ST_OK) {
        // 服务端 ok 的条件是「有收藏」，但可能一部都没吃灰；这时别摆一个 0 当结果
        if (this.idleTotal > 0) {
          Row({ space: 5 }) {
            Text(`${this.idleTotal}`)
              .fontSize(23)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            Text(`部收藏超过 ${this.idleDays} 天没打开`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .margin({ top: 8 })
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
        } else {
          Text('没有吃灰的，收得很克制')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
        }

        if (this.idleFilms.length > 0) {
          Column() {
            ForEach(this.idleFilms, (it: IdleFilm) => {
              Row({ space: 8 }) {
                Text(it.number.length > 0 ? it.number : it.title)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .layoutWeight(1)
                Text(it.fav_at.length >= 10 ? `${it.fav_at.substring(0, 10)} 收藏` : '')
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                Text('›')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ top: 7, bottom: 7 })
              .onClick(() => {
                this.openFilm(it.id);
              })
            }, (it: IdleFilm) => `idle-${it.id}-${it.fav_at}`)
          }
          .width('100%')
        }

        if (this.idleActors.length > 0) {
          Column({ space: 6 }) {
            Text('冷落演员 · 收了他的片却一部没看')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.idleActors, (a: IdleActor) => {
                Text(`${a.name} ${a.films}`)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(11)
                  .margin({ right: 6, bottom: 6 })
                  .onClick(() => {
                    const nav: ActorNav = { id: a.id, name: a.name };
                    router.pushUrl({ url: 'ext/actors/ActorWorksPage', params: nav });
                  })
              }, (a: IdleActor) => `ia-${a.id}-${a.films}`)
            }
            .width('100%')
          }
          .width('100%')
        }

        if (this.idleStudios.length > 0) {
          Column({ space: 6 }) {
            Text('冷落厂牌 · 收了他的片却一部没看')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.idleStudios, (s: IdleStudio) => {
                Text(`${s.name} ${s.films}`)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(11)
                  .margin({ right: 6, bottom: 6 })
                  .onClick(() => {
                    this.openStudio(s.name);
                  })
              }, (s: IdleStudio) => `is-${s.name}-${s.films}`)
            }
            .width('100%')
          }
          .width('100%')
        }
      } else if (this.idleSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.idleNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  /** 收藏转化漏斗：收藏 → 打开 → 看完，三段都以收藏为 100%。 */
  @Builder
  FunnelBlock() {
    Column({ space: 10 }) {
      this.SectionHead('收藏转化漏斗', 'funnel')

      if (this.funSt === ST_OK) {
        Text(`近 ${this.funDays} 天新增的收藏`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')

        Column({ space: 8 }) {
          ForEach(['fav', 'opened', 'finished'], (kind: string) => {
            Row({ space: 10 }) {
              Text(this.funnelLabel(kind))
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
                .width(40)
              Stack({ alignContent: Alignment.Start }) {
                Column()
                  .width('100%')
                  .height(14)
                  .borderRadius(4)
                  .backgroundColor(Theme.CARD_HI)
                Column()
                  .width(`${this.funnelPct(this.funnelValue(kind))}%`)
                  .height(14)
                  .borderRadius(4)
                  .backgroundColor(kind === 'fav' ? Theme.accentAlpha(0.9)
                    : (kind === 'opened' ? Theme.accentAlpha(0.62) : Theme.accentAlpha(0.36)))
              }
              .layoutWeight(1)
              .height(14)
              Text(`${this.funnelValue(kind)}`)
                .fontSize(12)
                .fontColor(Theme.TEXT)
                .width(46)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }, (kind: string) => `fn-${kind}`)
        }
        .width('100%')

        Row({ space: 12 }) {
          Text(`收藏 → 打开 ${Math.round(num(this.funOpenRate) * 100)}%`)
            .fontSize(10)
            .fontColor(Theme.ACCENT)
          Text(`收藏 → 看完 ${Math.round(num(this.funOverall) * 100)}%`)
            .fontSize(10)
            .fontColor(Theme.GOLD)
        }
        .width('100%')
      } else if (this.funSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.funNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  private funnelLabel(kind: string): string {
    if (kind === 'fav') {
      return '收藏';
    }
    return kind === 'opened' ? '打开' : '看完';
  }

  private funnelValue(kind: string): number {
    if (kind === 'fav') {
      return this.funFav;
    }
    return kind === 'opened' ? this.funOpened : this.funFinished;
  }

  /** 评分冲突：高分没看完 / 没分反复看 / 与大众的差距。 */
  @Builder
  ConflictBlock() {
    Column({ space: 10 }) {
      this.SectionHead('评分冲突', 'conflict')

      if (this.cfSt === ST_OK) {
        if (this.cfHigh.length > 0) {
          Text('打了高分却没看完')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Column() {
            ForEach(this.cfHigh, (it: ConflictFilm) => {
              Row({ space: 8 }) {
                Text(it.number.length > 0 ? it.number : it.title)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .layoutWeight(1)
                Text(`★ ${num(it.score)}`)
                  .fontSize(10)
                  .fontColor(Theme.GOLD)
                Text(`只看了 ${Math.round(num(it.ratio) * 100)}%`)
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                Text('›')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ top: 7, bottom: 7 })
              .onClick(() => {
                this.openFilm(it.id);
              })
            }, (it: ConflictFilm) => `ch-${it.id}-${it.ratio}`)
          }
          .width('100%')
        }

        if (this.cfRepeat.length > 0) {
          Text('没打分却反复看')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Column() {
            ForEach(this.cfRepeat, (it: RepeatFilm) => {
              Row({ space: 8 }) {
                Text(it.number.length > 0 ? it.number : it.title)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .layoutWeight(1)
                Text(`重看 ${num(it.replays)} 次`)
                  .fontSize(9)
                  .fontColor(Theme.ACCENT)
                Text('›')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ top: 7, bottom: 7 })
              .onClick(() => {
                this.openFilm(it.id);
              })
            }, (it: RepeatFilm) => `cr-${it.id}-${it.replays}`)
          }
          .width('100%')
        }

        if (this.upstreamText().length > 0) {
          Text(this.upstreamText())
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .width('100%')
            .padding({ left: 9, right: 9, top: 7, bottom: 7 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
        }
      } else if (this.cfSt === ST_LOADING) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.ACCENT)
      } else {
        Text(this.cfNoteText())
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  /** 2.5.4：「从夯到拉」入口卡 —— 缩略图带 + 五档人数，点进去做新图。 */
  @Builder
  TierBlock() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('从夯到拉')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text('Tier 图')
          .fontSize(9)
          .fontColor(Theme.ON_ACCENT)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(5)
        Blank()
        Text('›')
          .fontSize(14)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      if (this.tierSt === ST_OK) {
        if (this.tierThumbs.length > 0) {
          Row({ space: 5 }) {
            ForEach(this.tierThumbs, (u: string) => {
              Image(u)
                .width(38)
                .height(50)
                .objectFit(ImageFit.Cover)
                .borderRadius(5)
                .backgroundColor(Theme.CARD_HI)
            }, (u: string) => `tt-${u}`)
          }
          .width('100%')
        }

        Row({ space: 6 }) {
          ForEach(this.tierRows, (r: TierCurRow) => {
            Column({ space: 2 }) {
              Text(`${r.items.length}`)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.TEXT)
              Text(r.title)
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .maxLines(1)
            }
            .layoutWeight(1)
            .padding({ top: 6, bottom: 6 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
          }, (r: TierCurRow) => `tier-${r.score}-${r.items.length}`)
        }
        .width('100%')

        Text(`共 ${this.tierTotal} 个 · 点一下做一张新的`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      } else if (this.tierSt === ST_EMPTY) {
        Text('还没有打过星的片，打几部就能排座次')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      } else {
        Text('加载中…')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
    .onClick(() => {
      router.pushUrl({ url: 'pages/TierPage' });
    })
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 12 }) {
          // 老服务端（< 1.4.0）没有这组端点：说一次就够，别让五个块各喊一遍
          if (this.offAny()) {
            Row({ space: 8 }) {
              Text('!')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.ON_ACCENT)
                .width(16)
                .height(16)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
              Text('这台服务端还没有统计接口（需要 1.4.0 以上），升级后回来就有数了。')
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(10)
          }

          this.FilterBar()
          this.OverviewBlock()
          this.TrendBlock()
          this.WhenBlock()
          this.HeatBlock()
          this.TopBlock()
          // 2.5.4：老服务端没有 tier 端点就整块不渲染（不占位、不报错）
          if (this.tierSt !== ST_OFF) {
            this.TierBlock()
          }
          // v2（2.5.3 延续）：四块新统计，各自独立取数与空态
          this.DropBlock()
          this.IdleBlock()
          this.FunnelBlock()
          this.ConflictBlock()

          Text('数据只来自这台设备的观看记录；「看完」= 看到 95% 以上。')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .padding({ top: 4, bottom: 24 })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    .bindSheet($$this.hygieneSheet, this.HygieneSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG_RAISED
    })
  }
}
