import { LibraryStats, MediaItem, StatKV } from './Types';
import { Store } from './Store';

/**
 * 每日推荐「推荐理由」引擎（2.5.7，客户端 + 服务端统计摘要）。
 *
 * ## 诚实前提
 * 服务端 `build_recommend()` 是按日种子抽样，**不是算法推荐**。所以数据型理由绝不写
 * 「猜你喜欢」，只写一串能被证实的「事实」：这部片本身、它在这批 12 张里的位置、
 * 它在全库 5388 部里的位置、以及用户和它已经发生过的关系。
 * `whim` 族是唯一例外：它明说了自己不是事实（玄学、拟人、气氛、自嘲），
 * 靠语气而不是靠数据成立，所以不会伪装成「算法懂你」。
 *
 * ## 为什么「不像提前写好的」
 * 1. 探测器按族分成 8 组、共 160+ 条事实／说法，每条 1~3 种措辞；
 * 2. 句子里的数字全部来自真实数据（入库天数、全库计数、评分百分位、分钟、名次…），
 *    同一条模板在不同片 / 不同天读起来完全不同；
 * 3. 每天由日期种子决定各族权重，用 `id` 独立的伪随机流打乱候选 —— 同一部片同一天
 *    永远同一句（刷新不穿帮），换一天、换一批就换一种说法；
 * 4. 每族当日配额 + **事实级去重**，12 张卡不会齐刷刷说同一类话；
 * 5. 本地记着「上次翻到它是几天前」「连着第几天翻牌」，日子越用越有新料；
 * 6. 没料就留空。宁可少说，也不写「精选佳片，值得一看」这种废话。
 *
 * ## 全库统计（2.5.7.21）
 * `LibraryStats` 由 /api/user/home 下发，服务端一次全表扫 + 按天缓存，只回传这批
 * 卡片涉及的键。老服务端没有该字段时 `stats` 为 undefined，全库族自动整体跳过，
 * 其余 7 族照常工作 —— 不会因为服务端没升级就报错或写出错数字。
 *
 * ## 详情页（2.5.7.21）
 * 当天 pack 会持久化到偏好，Reason.forId(id) 让**任意入口**进入详情页都能读到
 * 这部片今天的理由；只有当天真的上了推荐位、且开关没关时才返回。
 */

export interface ReasonLine {
  id: number;
  number: string;
  title: string;
  /** 主理由；空串 = 这部今天没找到说法。 */
  reason: string;
  /** 偶尔追加的一句补充，多数时候为空。 */
  extra: string;
}

export interface ReasonPack {
  /** 行级副标题（替换原来那句「每天换一批 · 高清横幅」）。 */
  headline: string;
  /** 抽屉顶部的一句整体说明。 */
  topic: string;
  lines: ReasonLine[];
  /** 今天真的写出了几句（含补充句）。 */
  count: number;
}

interface Cand {
  group: string;
  /** 事实 id：同一天、同一批里只允许出现一次，避免 12 张卡齐刷刷说「没看过」。 */
  fact: string;
  /** 句式 id（同事实的不同说法）。 */
  key: string;
  text: string;
}

interface Ymd {
  y: number;
  m: number;
  d: number;
}

interface SeenEntry {
  id: number;
  day: string;
}

/** 一批卡的统计快照：所有「这批里最…」都从这里取，不重复扫列表。 */
interface BatchCtx {
  n: number;
  scores: number[];
  runtimes: number[];
  years: number[];
  maxScore: number;
  minScore: number;
  avgScore: number;
  maxRuntime: number;
  minRuntime: number;
  maxYear: number;
  minYear: number;
  unseen: number;
  rated: number;
  maxTags: number;
  maxActors: number;
  noMarks: number;
  tags: Map<string, number>;
  actors: Map<string, number>;
  series: Map<string, number>;
  studios: Map<string, number>;
  prefixes: Map<string, number>;
  recent: MediaItem[];
  /** 最近在看那批的集合，用来找「和正在看的…」关联。 */
  recentSeries: Map<string, string>;
  recentActors: Map<string, string>;
  recentTags: Map<string, string>;
  recentStudios: Map<string, string>;
  recentYears: Map<string, string>;
  recentTopScore: number;
  today: Date;
  seed: string;
  seen: Map<number, string>;
  streak: number;
  festival: string;
  season: string;
  weekday: string;
  phase: string;
  dayOfYear: number;
  daysLeft: number;
  /** 全库统计摘要；undefined = 老服务端 / 统计失败，library 族整体跳过。 */
  stats: LibraryStats | undefined;
  libTotal: number;
  libScored: number;
  libAvg: number;
  libMax: number;
  libWatched: number;
  libFav: number;
  libTagKinds: number;
  libActorKinds: number;
  libPrefixKinds: number;
  libMinYear: number;
  libMaxYear: number;
  libScoreBins: number[];
  libRuntimeBins: number[];
  libTags: Map<string, number>;
  libActors: Map<string, number>;
  libSeries: Map<string, number>;
  libStudios: Map<string, number>;
  libPrefixes: Map<string, number>;
  libYears: Map<string, number>;
}

const PREF_ON: string = 'reason_enabled';
const PREF_SEEN: string = 'reason_seen_v1';
const PREF_STREAK: string = 'reason_streak_v1';
/** 当天理由快照：详情页按 id 查，任意入口进详情页都能看到。 */
const PREF_PACK: string = 'reason_pack_v2';
const DEFAULT_SUBTITLE: string = '每天换一批 · 高清横幅';
/** library = 全库级事实；whim = 天马行空 / 气氛组（明说不是事实）。 */
const GROUPS: string[] =
  ['history', 'rank', 'batch', 'behavior', 'meta', 'mood', 'library', 'whim'];

/**
 * 这个库是成人影片库，标签里含露骨词。全库稀有标签探测器只挑能大方念出来的词：
 * 理由要有趣，但不拿露骨标签当噱头，也不复述到气氛组文案里。
 */
const TAG_SKIP: string[] = [
  '乱', '伦', '凌', '辱', 'SM', '痴', '漢', '汉', '强', '姦', '奸', '調教', '调教',
  '中出', '乳交', '口交', '淫', '射', '縛', '缚', '折磨', '凌虐', '侵犯', '睡眠',
  'M女', 'S女', '肛', '潮', '膣', '姦', '痴女', 'レイプ', 'オーガズム', 'アクメ',
  '中亚', '其他癖好'
];

interface SavedPack {
  day: string;
  lines: ReasonLine[];
}

interface Rare {
  k: string;
  n: number;
}

const WEEKDAYS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
const SEASONS: string[] = ['冬', '春', '夏', '秋'];

/** 公历节日（农历节气不硬猜，避免写错日子）。 */
const FESTIVALS: string[] = [
  '1-1:元旦', '2-14:情人节', '3-8:今天', '4-1:愚人节', '5-1:劳动节',
  '6-1:儿童节', '8-15:今天', '10-1:国庆', '10-31:万圣夜',
  '11-11:双十一', '12-24:平安夜', '12-25:圣诞', '12-31:跨年夜'
];

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function ymdStr(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 宽松解析 YYYY-MM-DD / YYYY-MM-DDTHH:mm:ss…，取不到就返回 undefined。 */
function parseYmd(s: string): Ymd | undefined {
  if (s.length < 10) {
    return undefined;
  }
  const y: number = Number(s.substring(0, 4));
  const m: number = Number(s.substring(5, 7));
  const d: number = Number(s.substring(8, 10));
  if (!isFinite(y) || !isFinite(m) || !isFinite(d) || y < 1900 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) {
    return undefined;
  }
  return { y: Math.trunc(y), m: Math.trunc(m), d: Math.trunc(d) };
}

/** 只用年月日算天数差，避开时区和夏令时。 */
function dayNumber(y: number, m: number, d: number): number {
  const yy: number = m <= 2 ? y - 1 : y;
  const era: number = Math.floor(yy / 400);
  const yoe: number = yy - era * 400;
  const mp: number = m + (m > 2 ? -3 : 9);
  const doy: number = Math.floor((153 * mp + 2) / 5) + d - 1;
  const doe: number = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe;
}

function daysFrom(y: Ymd, today: Date): number {
  return dayNumber(today.getFullYear(), today.getMonth() + 1, today.getDate()) - dayNumber(y.y, y.m, y.d);
}

function hash32(s: string): number {
  let h: number = 2166136261 | 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return h >>> 0;
}

/** 线性同余，乘法结果 < 2^53，double 可精确表示，不依赖 Math.imul。 */
function makeRng(seed: number): () => number {
  let s: number = (seed | 0) >>> 0;
  return (): number => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function pickText(a: string[], r: () => number): string {
  return a.length === 0 ? '' : a[Math.floor(r() * a.length) % a.length];
}

function festivalOf(m: number, d: number): string {
  const key: string = `${m}-${d}`;
  for (let i = 0; i < FESTIVALS.length; i++) {
    const parts: string[] = FESTIVALS[i].split(':');
    if (parts[0] === key) {
      return parts[1];
    }
  }
  return '';
}

function seasonOf(m: number): string {
  if (m >= 3 && m <= 5) {
    return SEASONS[1];
  }
  if (m >= 6 && m <= 8) {
    return SEASONS[2];
  }
  if (m >= 9 && m <= 11) {
    return SEASONS[3];
  }
  return SEASONS[0];
}

function phaseOf(h: number): string {
  if (h < 5) {
    return '凌晨';
  }
  if (h < 11) {
    return '早上';
  }
  if (h < 14) {
    return '午间';
  }
  if (h < 18) {
    return '下午';
  }
  if (h < 23) {
    return '夜里';
  }
  return '深夜';
}

function decadeOf(y: number): string {
  return `${Math.floor(y / 10) * 10} 年代`;
}

function prefixOf(number: string): string {
  const i: number = number.indexOf('-');
  return i > 0 ? number.substring(0, i) : (number.length > 3 ? number.substring(0, 3) : number);
}

function shortTitle(t: string): string {
  return t.length > 12 ? `${t.substring(0, 12)}…` : t;
}

function mapInc(m: Map<string, number>, k: string): void {
  if (k.length === 0) {
    return;
  }
  const v: number | undefined = m.get(k);
  m.set(k, v === undefined ? 1 : v + 1);
}

function mapMax(m: Map<string, number>): number {
  let best: number = 0;
  const keys: string[] = Array.from(m.keys());
  for (let i = 0; i < keys.length; i++) {
    const v: number | undefined = m.get(keys[i]);
    if (v !== undefined && v > best) {
      best = v;
    }
  }
  return best;
}

/** 找出「这批里某个维度数量 >= 2」的键，返回次数最多的那个。 */
function topShared(m: Map<string, number>): string {
  let key: string = '';
  let best: number = 1;
  const keys: string[] = Array.from(m.keys());
  for (let i = 0; i < keys.length; i++) {
    const v: number | undefined = m.get(keys[i]);
    if (v !== undefined && v > best) {
      best = v;
      key = keys[i];
    }
  }
  return key;
}

function firstCommon(a: string[], m: Map<string, string>): string {
  for (let i = 0; i < a.length; i++) {
    const t: string | undefined = m.get(a[i]);
    if (t !== undefined) {
      return t;
    }
  }
  return '';
}

/** 命中的那个维度值（标签名 / 演员名），让理由说得出「都带什么」。 */
function firstCommonKey(a: string[], m: Map<string, string>): string {
  for (let i = 0; i < a.length; i++) {
    if (m.has(a[i])) {
      return a[i];
    }
  }
  return '';
}

/** 服务端下发的 [{"k","n"}] 转成可按名字查的 Map。 */
function kvMap(a: StatKV[]): Map<string, number> {
  const m: Map<string, number> = new Map<string, number>();
  if (a === undefined || a === null) {
    return m;
  }
  for (let i = 0; i < a.length; i++) {
    const kv: StatKV = a[i];
    if (kv !== undefined && kv !== null && kv.k.length > 0) {
      m.set(kv.k, kv.n);
    }
  }
  return m;
}

function tagSafe(t: string): boolean {
  for (let i = 0; i < TAG_SKIP.length; i++) {
    if (t.indexOf(TAG_SKIP[i]) >= 0) {
      return false;
    }
  }
  return t.length > 0;
}

/** 这批卡涉及的全库计数里，挑最稀有（且能大方念出来）的一个。 */
function rarestSafe(m: Map<string, number>): Rare {
  const out: Rare = { k: '', n: 0 };
  let best: number = 1000000;
  const keys: string[] = Array.from(m.keys());
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (!tagSafe(k)) {
      continue;
    }
    const v: number | undefined = m.get(k);
    if (v !== undefined && v > 0 && v < best) {
      best = v;
      out.k = k;
      out.n = v;
    }
  }
  return out;
}

/** 从某个分桶开始往高档累加，用来算「全库比它高/长的有多少部」。 */
function sumFrom(bins: number[], from: number): number {
  let s: number = 0;
  const start: number = from < 0 ? 0 : from;
  for (let i = start; i < bins.length; i++) {
    s += bins[i];
  }
  return s;
}

function ratingOf(item: MediaItem): number {
  if (item.my_rating !== undefined && item.my_rating !== null && item.my_rating > 0) {
    return Math.trunc(item.my_rating);
  }
  const marks: string[] = item.marks === undefined ? [] : item.marks;
  for (let i = 0; i < marks.length; i++) {
    if (marks[i].indexOf('★') === 0 && marks[i].length > 1) {
      const n: number = Number(marks[i].substring(1));
      if (isFinite(n) && n > 0) {
        return Math.trunc(n);
      }
    }
  }
  return 0;
}

function seenCountOf(item: MediaItem): number {
  if (item.duration <= 0 && item.position <= 0) {
    return 0;
  }
  if (item.duration <= 0) {
    return 1;
  }
  return Math.min(100, Math.round((item.position * 100) / item.duration));
}

/** 读本地「上次翻到」映射：格式 id:YYYY-MM-DD;… 不用 JSON，省掉 Object.keys 的兼容问题。 */
function loadSeen(): SeenEntry[] {
  const raw: string = Store.I.prefString(PREF_SEEN, '');
  const out: SeenEntry[] = [];
  if (raw.length === 0) {
    return out;
  }
  const parts: string[] = raw.split(';');
  for (let i = 0; i < parts.length; i++) {
    const kv: string[] = parts[i].split(':');
    if (kv.length === 2) {
      const id: number = Number(kv[0]);
      if (isFinite(id) && id > 0 && kv[1].length === 10) {
        out.push({ id: Math.trunc(id), day: kv[1] });
      }
    }
  }
  return out;
}

function saveSeen(entries: SeenEntry[], today: string, items: MediaItem[]): void {
  const now: number = dayNumber(Number(today.substring(0, 4)), Number(today.substring(5, 7)),
    Number(today.substring(8, 10)));
  const keep: SeenEntry[] = [];
  const touched: Map<number, boolean> = new Map<number, boolean>();
  for (let i = 0; i < entries.length; i++) {
    const e: SeenEntry = entries[i];
    const dn: number = dayNumber(Number(e.day.substring(0, 4)), Number(e.day.substring(5, 7)),
      Number(e.day.substring(8, 10)));
    if (now - dn > 120 || now - dn < 0) {
      continue;
    }
    touched.set(e.id, true);
    keep.push(e);
  }
  for (let i = 0; i < items.length; i++) {
    const id: number = items[i].id;
    if (id <= 0) {
      continue;
    }
    let found: boolean = false;
    for (let j = 0; j < keep.length; j++) {
      if (keep[j].id === id) {
        keep[j] = { id: id, day: today };
        found = true;
        break;
      }
    }
    if (!found) {
      keep.push({ id: id, day: today });
    }
  }
  // 只留最近 240 条，避免偏好无限膨胀
  const trimmed: SeenEntry[] = keep.length > 240 ? keep.slice(keep.length - 240) : keep;
  const buf: string[] = [];
  for (let i = 0; i < trimmed.length; i++) {
    buf.push(`${trimmed[i].id}:${trimmed[i].day}`);
  }
  Store.I.prefSetString(PREF_SEEN, buf.join(';'));
}

/** 连续第几天翻牌：同一天重复调用不重复 +1。 */
function readStreak(today: string): number {
  const raw: string = Store.I.prefString(PREF_STREAK, '');
  const parts: string[] = raw.split('|');
  if (parts.length !== 2) {
    Store.I.prefSetString(PREF_STREAK, `${today}|1`);
    return 1;
  }
  const last: string = parts[0];
  const n: number = Number(parts[1]);
  if (last === today) {
    return isFinite(n) && n > 0 ? Math.trunc(n) : 1;
  }
  const a: number = dayNumber(Number(last.substring(0, 4)), Number(last.substring(5, 7)),
    Number(last.substring(8, 10)));
  const b: number = dayNumber(Number(today.substring(0, 4)), Number(today.substring(5, 7)),
    Number(today.substring(8, 10)));
  const next: number = b - a === 1 && isFinite(n) ? Math.trunc(n) + 1 : 1;
  Store.I.prefSetString(PREF_STREAK, `${today}|${next}`);
  return next;
}

function makeCtx(items: MediaItem[], recent: MediaItem[], today: Date, seen: SeenEntry[],
  streak: number, stats: LibraryStats | undefined): BatchCtx {
  const scores: number[] = [];
  const runtimes: number[] = [];
  const years: number[] = [];
  const tags: Map<string, number> = new Map<string, number>();
  const actors: Map<string, number> = new Map<string, number>();
  const series: Map<string, number> = new Map<string, number>();
  const studios: Map<string, number> = new Map<string, number>();
  const prefixes: Map<string, number> = new Map<string, number>();
  const seenMap: Map<number, string> = new Map<number, string>();
  for (let i = 0; i < seen.length; i++) {
    seenMap.set(seen[i].id, seen[i].day);
  }

  let maxScore: number = 0;
  let minScore: number = 999;
  let sumScore: number = 0;
  let scoreN: number = 0;
  let maxRuntime: number = 0;
  let minRuntime: number = 99999;
  let maxYear: number = 0;
  let minYear: number = 9999;
  let unseen: number = 0;
  let rated: number = 0;
  let maxTags: number = 0;
  let maxActors: number = 0;
  let noMarks: number = 0;

  for (let i = 0; i < items.length; i++) {
    const it: MediaItem = items[i];
    scores.push(it.score);
    runtimes.push(it.runtime);
    if (it.score > 0) {
      sumScore += it.score;
      scoreN++;
      if (it.score > maxScore) {
        maxScore = it.score;
      }
      if (it.score < minScore) {
        minScore = it.score;
      }
    }
    if (it.runtime > 0) {
      if (it.runtime > maxRuntime) {
        maxRuntime = it.runtime;
      }
      if (it.runtime < minRuntime) {
        minRuntime = it.runtime;
      }
    }
    const rel: Ymd | undefined = parseYmd(it.release);
    const y: number = rel === undefined ? 0 : rel.y;
    years.push(y);
    if (y > 0) {
      if (y > maxYear) {
        maxYear = y;
      }
      if (y < minYear) {
        minYear = y;
      }
    }
    if (seenCountOf(it) === 0) {
      unseen++;
    }
    if (ratingOf(it) > 0) {
      rated++;
    }
    const tg: string[] = it.tags === undefined ? [] : it.tags;
    const ac: string[] = it.actors === undefined ? [] : it.actors;
    if (tg.length > maxTags) {
      maxTags = tg.length;
    }
    if (ac.length > maxActors) {
      maxActors = ac.length;
    }
    if (it.marks === undefined || it.marks.length === 0) {
      noMarks++;
    }
    for (let j = 0; j < tg.length; j++) {
      mapInc(tags, tg[j]);
    }
    for (let j = 0; j < ac.length; j++) {
      mapInc(actors, ac[j]);
    }
    mapInc(series, it.series);
    mapInc(studios, it.studio);
    mapInc(prefixes, prefixOf(it.number));
  }
  if (minScore === 999) {
    minScore = 0;
  }
  if (minRuntime === 99999) {
    minRuntime = 0;
  }
  if (minYear === 9999) {
    minYear = 0;
  }

  const recentSeries: Map<string, string> = new Map<string, string>();
  const recentActors: Map<string, string> = new Map<string, string>();
  const recentTags: Map<string, string> = new Map<string, string>();
  const recentStudios: Map<string, string> = new Map<string, string>();
  const recentYears: Map<string, string> = new Map<string, string>();
  let recentTopScore: number = 0;
  for (let i = 0; i < recent.length; i++) {
    const r: MediaItem = recent[i];
    const t: string = shortTitle(r.title.length > 0 ? r.title : r.number);
    if (r.series.length > 0) {
      recentSeries.set(r.series, t);
    }
    if (r.studio.length > 0) {
      recentStudios.set(r.studio, t);
    }
    if (r.release.length >= 4) {
      recentYears.set(r.release.substring(0, 4), t);
    }
    if (r.score > recentTopScore) {
      recentTopScore = r.score;
    }
    const ra: string[] = r.actors === undefined ? [] : r.actors;
    const rt: string[] = r.tags === undefined ? [] : r.tags;
    for (let j = 0; j < ra.length; j++) {
      if (!recentActors.has(ra[j])) {
        recentActors.set(ra[j], t);
      }
    }
    for (let j = 0; j < rt.length; j++) {
      if (!recentTags.has(rt[j])) {
        recentTags.set(rt[j], t);
      }
    }
  }

  const m: number = today.getMonth() + 1;
  const d: number = today.getDate();
  const doy: number = dayNumber(today.getFullYear(), m, d) -
    dayNumber(today.getFullYear(), 1, 1) + 1;
  const daysLeft: number = dayNumber(today.getFullYear() + 1, 1, 1) -
    dayNumber(today.getFullYear(), m, d);

  const lt: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.tags);
  const la: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.actors);
  const ls: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.series);
  const lst: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.studios);
  const lp: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.prefixes);
  const ly: Map<string, number> = stats === undefined ? new Map<string, number>() : kvMap(stats.years);
  const sb: number[] = stats === undefined ? [] : stats.score_bins;
  const rb: number[] = stats === undefined ? [] : stats.runtime_bins;

  return {
    n: items.length, scores: scores, runtimes: runtimes, years: years,
    maxScore: maxScore, minScore: minScore, avgScore: scoreN > 0 ? sumScore / scoreN : 0,
    maxRuntime: maxRuntime, minRuntime: minRuntime, maxYear: maxYear, minYear: minYear,
    unseen: unseen, rated: rated, maxTags: maxTags, maxActors: maxActors, noMarks: noMarks,
    tags: tags, actors: actors, series: series, studios: studios, prefixes: prefixes,
    recent: recent, recentSeries: recentSeries, recentActors: recentActors,
    recentTags: recentTags, recentStudios: recentStudios, recentYears: recentYears,
    recentTopScore: recentTopScore,
    today: today, seed: ymdStr(today), seen: seenMap, streak: streak,
    festival: festivalOf(m, d), season: seasonOf(m), weekday: WEEKDAYS[today.getDay()],
    phase: phaseOf(today.getHours()), dayOfYear: doy, daysLeft: daysLeft,
    stats: stats,
    libTotal: stats === undefined ? 0 : stats.total,
    libScored: stats === undefined ? 0 : stats.scored,
    libAvg: stats === undefined ? 0 : stats.avg_score,
    libMax: stats === undefined ? 0 : stats.max_score,
    libWatched: stats === undefined ? 0 : stats.watched,
    libFav: stats === undefined ? 0 : stats.favorites,
    libTagKinds: stats === undefined ? 0 : stats.tag_kinds,
    libActorKinds: stats === undefined ? 0 : stats.actor_kinds,
    libPrefixKinds: stats === undefined ? 0 : stats.prefix_kinds,
    libMinYear: stats === undefined ? 0 : stats.min_year,
    libMaxYear: stats === undefined ? 0 : stats.max_year,
    libScoreBins: sb, libRuntimeBins: rb,
    libTags: lt, libActors: la, libSeries: ls, libStudios: lst, libPrefixes: lp, libYears: ly
  };
}

/** 一条事实的入口：group 用于配额，fact 用于事实去重，a/b/c 是同义说法。 */
function add(out: Cand[], group: string, fact: string, a: string, b: string = '', c: string = ''): void {
  if (a.length > 0) {
    out.push({ group: group, fact: fact, key: `${fact}#0`, text: a });
  }
  if (b.length > 0) {
    out.push({ group: group, fact: fact, key: `${fact}#1`, text: b });
  }
  if (c.length > 0) {
    out.push({ group: group, fact: fact, key: `${fact}#2`, text: c });
  }
}

/**
 * 给一部片收集所有成立的事实。
 * 写在这里的每一条都必须能被 item / ctx 里的某个数字或字段证实，不许凭空编。
 */
function collect(item: MediaItem, index: number, c: BatchCtx): Cand[] {
  const out: Cand[] = [];
  const rel: Ymd | undefined = parseYmd(item.release);
  const upd: Ymd | undefined = parseYmd(item.updated_at);
  const ty: number = c.today.getFullYear();
  const tm: number = c.today.getMonth() + 1;
  const td: number = c.today.getDate();
  const r: number = ratingOf(item);
  const pct: number = seenCountOf(item);
  const rt: number = item.runtime;
  const tags: string[] = item.tags === undefined ? [] : item.tags;
  const acts: string[] = item.actors === undefined ? [] : item.actors;
  const marks: string[] = item.marks === undefined ? [] : item.marks;
  const sc: number = item.score;

  // ── history：历史上的今天、入库、季节、节日、时段、本地记忆 ───────────────
  if (rel !== undefined) {
    const age: number = ty - rel.y;
    if (rel.m === tm && rel.d === td && age > 0) {
      add(out, 'history', 'same-day',
        `${age} 年前的今天，它发行`,
        `发行日正好是今天，${age} 年前`,
        `${rel.y}-${pad2(rel.m)}-${pad2(rel.d)} 发行，和今天同一天`);
    }
    if (rel.m === tm && rel.d !== td && age > 0) {
      add(out, 'history', 'same-month',
        `${rel.y} 年 ${rel.m} 月上架的，也是这个月`,
        `和这个月同月，${age} 年前`);
    }
    if (age >= 10 && age % 10 === 0) {
      add(out, 'history', 'anniversary', `发行满 ${age} 周年`, `整整 ${age} 年了`);
    }
    if (age > 15) {
      add(out, 'history', 'old',
        `${rel.y} 年的片子，比你以为的还老`,
        `${age} 年前的东西，今天翻出来了`);
    } else if (age >= 0 && age <= 2) {
      add(out, 'history', 'new', `才 ${Math.max(1, age)} 年前的东西`, `${rel.y} 年，算新的`);
    }
    if (age > 0) {
      const season: string = seasonOf(rel.m);
      add(out, 'history', 'rel-season', `${age} 年前${season}天发行的`);
    }
    add(out, 'history', 'decade', `${decadeOf(rel.y)}的片子`, `来自 ${rel.y} 年`);
    // 发行纪念日前后 5 天（不跨年）
    if (rel.m === tm) {
      const diff: number = rel.d - td;
      if (diff > 0 && diff <= 5) {
        add(out, 'history', 'soon-anniv', `再过 ${diff} 天就是它的发行纪念日`);
      } else if (diff < 0 && diff >= -5) {
        add(out, 'history', 'past-anniv', `${-diff} 天前刚过发行纪念日`);
      }
    }
  }
  if (upd !== undefined) {
    const days: number = daysFrom(upd, c.today);
    if (days >= 0) {
      if (upd.m === tm && upd.d === td && days >= 365) {
        add(out, 'history', 'in-same-day', `${Math.floor(days / 365)} 年前的今天进的库`);
      }
      if (days > 30) {
        add(out, 'history', 'in-days',
          `在你库里躺了 ${days} 天`,
          `进库 ${days} 天，一直没等到你`,
          `${days} 天前收进来的`);
      } else if (days >= 1) {
        add(out, 'history', 'in-recent', `刚进库 ${days} 天，还热乎`, `本周新来的，进库 ${days} 天`);
      } else {
        add(out, 'history', 'in-today', '今天刚进库');
      }
      if (days >= 365) {
        add(out, 'history', 'in-years', `进库 ${Math.floor(days / 365)} 年多，第一次被翻到`);
      }
      const wd: number = new Date(upd.y, upd.m - 1, upd.d).getDay();
      add(out, 'history', 'in-weekday', `某个${WEEKDAYS[wd]}收进来的`);
    }
  }
  if (c.festival.length > 0) {
    add(out, 'history', 'festival',
      `${c.festival}，翻到一部${rel === undefined ? '' : ` ${rel.y} 年的`}`,
      `${c.festival}夜，来点 ${rt > 0 ? `${rt} 分钟的` : '短的'}`,
      `${c.festival}，今天这批有点应景`);
  }
  add(out, 'history', 'phase', `${c.phase}翻到它`, `${c.phase}的第 ${index + 1} 张`);
  add(out, 'history', 'weekday', `${c.weekday}的推荐位`, `一个${c.weekday}，翻到它`);
  add(out, 'history', 'season-now', `${c.season}天里翻出来的`, `外头是${c.season}天了`);
  add(out, 'history', 'doy', `今年第 ${c.dayOfYear} 天`, `今年还剩 ${c.daysLeft} 天`);
  if (c.streak >= 2) {
    add(out, 'history', 'streak', `连着第 ${c.streak} 天翻牌`, `第 ${c.streak} 天了，还在翻`);
  }
  const last: string | undefined = c.seen.get(item.id);
  if (last !== undefined && last !== c.seed) {
    const a: number = dayNumber(Number(last.substring(0, 4)), Number(last.substring(5, 7)),
      Number(last.substring(8, 10)));
    const b: number = dayNumber(ty, tm, td);
    const gap: number = b - a;
    if (gap > 0 && gap < 120) {
      add(out, 'history', 'last-seen',
        `上次翻到它是 ${gap} 天前`,
        `隔了 ${gap} 天又见面`,
        `${gap} 天前也在推荐位上见过`);
    }
  }

  // ── rank：这批里的相对位置 ─────────────────────────────────────────────
  if (sc > 0) {
    if (sc === c.maxScore && c.n > 2) {
      add(out, 'rank', 'top-score', `今天这批里分最高的`, `${sc.toFixed(1)} 分，这批第一`);
    }
    if (sc === c.minScore && c.n > 3 && c.maxScore - c.minScore > 0.5) {
      add(out, 'rank', 'low-score', `这批里分最低，也翻到了`, `${sc.toFixed(1)} 分，垫底但被选中`);
    }
    let rank: number = 1;
    for (let i = 0; i < c.scores.length; i++) {
      if (c.scores[i] > sc) {
        rank++;
      }
    }
    add(out, 'rank', 'score-rank', `这批 ${c.n} 部里，评分第 ${rank}`);
    if (sc >= 8 && c.avgScore > 0 && sc - c.avgScore >= 0.4) {
      add(out, 'rank', 'above-avg', `比这批平均高 ${(sc - c.avgScore).toFixed(1)} 分`);
    }
    const above8: number = c.scores.filter((v: number) => v >= 8).length;
    if (sc >= 8 && above8 === 1) {
      add(out, 'rank', 'only-8', '这批里唯一上 8 分的');
    }
  }
  if (rt > 0 && c.n > 2) {
    if (rt === c.maxRuntime) {
      add(out, 'rank', 'longest', `这批里最长，${rt} 分钟`, `${rt} 分钟，得挑个整晚`);
    }
    if (rt === c.minRuntime) {
      add(out, 'rank', 'shortest', `这批里最短，${rt} 分钟`, `${rt} 分钟，最好塞进今晚的`);
    }
    let rr: number = 1;
    for (let i = 0; i < c.runtimes.length; i++) {
      if (c.runtimes[i] > rt) {
        rr++;
      }
    }
    add(out, 'rank', 'runtime-rank', `这批里时长第 ${rr}`);
  }
  if (rel !== undefined && c.n > 2) {
    if (rel.y === c.minYear && c.maxYear - c.minYear > 0) {
      add(out, 'rank', 'oldest', `这批里年份最早，${rel.y} 年`);
    }
    if (rel.y === c.maxYear && c.maxYear - c.minYear > 0) {
      add(out, 'rank', 'newest', `这批里年份最晚，${rel.y} 年`);
    }
  }
  if (c.maxScore > 0 && c.minScore > 0 && c.maxScore - c.minScore >= 1.5) {
    add(out, 'rank', 'spread', `这批分差从 ${c.minScore.toFixed(1)} 到 ${c.maxScore.toFixed(1)}`);
  }
  if (c.maxYear - c.minYear >= 10) {
    add(out, 'rank', 'year-span', `这批横跨 ${c.maxYear - c.minYear} 年`);
  }

  // ── batch：这批的共性与稀缺 ────────────────────────────────────────────
  const uniqueTag: string = tags.length > 0 && c.tags.get(tags[0]) === 1 ? tags[0] : '';
  if (uniqueTag.length > 0) {
    add(out, 'batch', 'unique-tag', `这批里唯一带「${uniqueTag}」的`);
  }
  const sharedTag: string = topShared(c.tags);
  if (sharedTag.length > 0) {
    add(out, 'batch', 'shared-tag', `这批里有 ${c.tags.get(sharedTag)} 部都带「${sharedTag}」`);
  }
  if (item.series.length > 0) {
    const k: number | undefined = c.series.get(item.series);
    if (k !== undefined && k >= 2) {
      add(out, 'batch', 'shared-series', `「${item.series}」今天占了 ${k} 张`, `这系列今天翻出 ${k} 部`);
    } else if (k === 1) {
      add(out, 'batch', 'only-series', `这批里唯一的「${item.series}」`);
    }
  }
  if (item.studio.length > 0) {
    const k: number | undefined = c.studios.get(item.studio);
    if (k !== undefined && k >= 2) {
      add(out, 'batch', 'shared-studio', `这批 ${k} 部都出自 ${item.studio}`);
    }
  }
  if (acts.length > 0) {
    const k: number | undefined = c.actors.get(acts[0]);
    if (k !== undefined && k >= 2) {
      add(out, 'batch', 'shared-actor', `${acts[0]}今天占了 ${k} 张`, `这位演员这批出现 ${k} 次`);
    }
  }
  const pre: string = prefixOf(item.number);
  if (pre.length > 0) {
    const k: number | undefined = c.prefixes.get(pre);
    if (k !== undefined && k >= 2) {
      add(out, 'batch', 'shared-prefix', `这批里 ${k} 部都是 ${pre} 开头`);
    }
  }
  if (c.unseen >= 2) {
    add(out, 'batch', 'unseen-many', `这批 ${c.n} 部里，${c.unseen} 部你还没点开`);
    if (c.unseen === 1 && pct === 0) {
      add(out, 'batch', 'only-unseen', '这批里唯一还没点开的');
    }
  }
  if (pct > 0 && c.n - c.unseen === 1) {
    add(out, 'batch', 'only-seen', '这批里只有这部你看过');
  }
  if (r > 0 && c.rated === 1) {
    add(out, 'batch', 'only-rated', '这批里只有这部你打过分');
  }
  if (c.minYear > 0 && c.maxYear > 0 && Math.floor(c.minYear / 10) === Math.floor(c.maxYear / 10)) {
    add(out, 'batch', 'one-decade', `这一批清一色 ${decadeOf(c.minYear)}`);
  }
  if (tags.length > 2 && tags.length === c.maxTags) {
    add(out, 'batch', 'most-tags', `身上挂了 ${tags.length} 个标签，这批最多`);
  }
  if (acts.length > 2 && acts.length === c.maxActors) {
    add(out, 'batch', 'most-actors', `${acts.length} 位演员同台，这批里最热闹`);
  }
  if (marks.length === 0 && c.noMarks === 1) {
    add(out, 'batch', 'only-clean', '干干净净，这批里唯一没标记的');
  }
  if (item.versions !== undefined && item.versions > 1) {
    add(out, 'batch', 'versions', `库里有 ${item.versions} 个版本`);
  }

  // ── behavior：我和这部片已经发生过的事 ──────────────────────────────────
  if (pct === 0) {
    add(out, 'behavior', 'never', '一次都没点开过', '至今没看过', '你还没碰过它');
  } else if (pct < 90) {
    const mins: number = Math.round(item.position / 60);
    const left: number = Math.max(1, Math.round((item.duration - item.position) / 60));
    add(out, 'behavior', 'halfway',
      `上次停在 ${mins} 分钟，还剩 ${left} 分钟`,
      `看了 ${pct}%，没看完`,
      `进度条卡在 ${pct}%`);
  } else {
    const left: number = Math.max(0, Math.round((item.duration - item.position) / 60));
    add(out, 'behavior', 'almost',
      left > 0 ? `就差最后 ${left} 分钟` : '差一点点就看完',
      `已经看到 ${pct}%`,
      '你看完了，今天又翻到');
  }
  if (r > 0) {
    if (r >= 5) {
      add(out, 'behavior', 'rate5', '你给过满分', '标过 ★5', '你自己打的五星');
    } else if (r <= 2) {
      add(out, 'behavior', 'rate-low', `你只给了 ${r} 星，今天又翻到`);
    } else {
      add(out, 'behavior', 'rate-mid', `你给过 ★${r}`);
    }
    if (sc > 0) {
      add(out, 'behavior', 'rate-vs-score', `你给 ★${r}，外面评 ${sc.toFixed(1)} 分`);
    }
  }
  let sLink: string = '';
  if (item.series.length > 0) {
    const v: string | undefined = c.recentSeries.get(item.series);
    sLink = v === undefined ? '' : v;
  }
  if (sLink.length > 0) {
    add(out, 'behavior', 'link-series', `和正在看的《${sLink}》同一个系列`);
  }
  const aLink: string = firstCommon(acts, c.recentActors);
  if (aLink.length > 0) {
    add(out, 'behavior', 'link-actor', `和正在看的《${aLink}》有同一位演员`);
  }
  const tLink: string = firstCommon(tags, c.recentTags);
  const tKey: string = firstCommonKey(tags, c.recentTags);
  if (tLink.length > 0) {
    add(out, 'behavior', 'link-tag',
      `和正在看的《${tLink}》都带「${tKey}」`,
      `和《${tLink}》撞了同一个标签「${tKey}」`);
  }
  let stLink: string = '';
  if (item.studio.length > 0) {
    const v: string | undefined = c.recentStudios.get(item.studio);
    stLink = v === undefined ? '' : v;
  }
  if (stLink.length > 0) {
    add(out, 'behavior', 'link-studio', `和正在看的《${stLink}》同一个厂牌`);
  }
  let yLink: string = '';
  if (rel !== undefined) {
    const v: string | undefined = c.recentYears.get(`${rel.y}`);
    yLink = v === undefined ? '' : v;
  }
  if (yLink.length > 0) {
    add(out, 'behavior', 'link-year', `和正在看的《${yLink}》同年`);
  }
  if (c.recentTopScore > 0 && sc > c.recentTopScore) {
    add(out, 'behavior', 'vs-continue', `比正在看的那部还高 ${(sc - c.recentTopScore).toFixed(1)} 分`);
  }

  // ── meta：纯元数据 ─────────────────────────────────────────────────────
  if (rt > 0) {
    if (rt < 60) {
      add(out, 'meta', 'short', `${rt} 分钟，一杯咖啡的事`, `${rt} 分钟，不用专门留一晚`);
    } else if (rt > 150) {
      add(out, 'meta', 'long', `${rt} 分钟，得留一整晚`, `${rt} 分钟，不是随手能看完的`);
    } else {
      add(out, 'meta', 'mid', `${rt} 分钟，刚好一部的时间`);
    }
  }
  if (sc >= 8.5) {
    add(out, 'meta', 'high-score', `${sc.toFixed(1)} 分，不常见`);
  } else if (sc === 0) {
    add(out, 'meta', 'no-score', '这部还没人打分', '评分栏空着');
  }
  if (tags.length >= 3) {
    add(out, 'meta', 'tag-count', `身上挂了 ${tags.length} 个标签`);
  }
  if (acts.length >= 3) {
    add(out, 'meta', 'actor-count', `${acts.length} 位演员同台`);
  }
  if (item.series.length > 0) {
    add(out, 'meta', 'series', `属于「${item.series}」系列`);
  }
  if (item.studio.length > 0) {
    add(out, 'meta', 'studio', `出自 ${item.studio}`);
  }
  if (pre.length > 0) {
    add(out, 'meta', 'prefix', `番号前缀 ${pre}`);
  }
  if (item.fanart_ratio !== undefined && item.fanart_ratio >= 2.0) {
    add(out, 'meta', 'wide', '这张横图特别宽', `横图比例 ${item.fanart_ratio.toFixed(2)}，比一般宽`);
  }
  if (item.plot.length > item.title.length * 3 && item.title.length > 0) {
    add(out, 'meta', 'plot', '简介写得比片名长得多');
  }
  if (item.title.length > 24) {
    add(out, 'meta', 'long-title', '片名比番号长得多');
  }
  if (item.content_type.length > 0) {
    add(out, 'meta', 'ctype', `类型标的是 ${item.content_type}`);
  }
  if (marks.length === 0) {
    add(out, 'meta', 'no-marks', '卡上一个标记都没有');
  }

  // ── library：全库级事实 ────────────────────────────────────────────────
  // 老服务端没有 library_stats、或统计失败（total=0）时整段跳过，
  // 绝不拿这批 12 张卡去假装成全库数字。
  if (c.stats !== undefined && c.libTotal > 0) {
    const T: number = c.libTotal;

    // 评分百分位：服务端 score_bins 是 0.5 分一档，下标 = round(score*2)
    if (sc > 0 && c.libScored > 0) {
      const bi: number = Math.max(0, Math.min(20, Math.round(sc * 2)));
      const higher: number = sumFrom(c.libScoreBins, bi + 1);
      const pctTop: number = Math.max(1, Math.round((higher * 100) / c.libScored));
      add(out, 'library', 'lib-top-pct',
        `全库 ${c.libScored} 部有评分，它排前 ${pctTop}%`,
        `评分进了全库前 ${pctTop}%`,
        `全库前 ${pctTop}% 的位置`);
      add(out, 'library', 'lib-higher',
        `全库只有 ${higher} 部比它分高`,
        `比它分高的，全库 ${higher} 部`);
      if (c.libAvg > 0 && sc > c.libAvg) {
        add(out, 'library', 'lib-above-avg',
          `全库平均 ${c.libAvg.toFixed(2)} 分，它 ${sc.toFixed(1)}`,
          `比全库平均高 ${(sc - c.libAvg).toFixed(1)} 分`);
      }
      if (c.libMax > 0 && sc >= c.libMax - 0.01) {
        add(out, 'library', 'lib-max-score', `全库最高分 ${sc.toFixed(1)}，就是它`);
      }
      const elite: number = sumFrom(c.libScoreBins, 9);
      if (elite > 0 && sc >= 4.5) {
        add(out, 'library', 'lib-elite', `全库 4.5 分以上只有 ${elite} 部，它算一部`);
      }
    } else if (sc === 0 && c.libScored > 0) {
      add(out, 'library', 'lib-unscored', `全库 ${T - c.libScored} 部没评分，它是其中之一`);
    }

    // 稀有标签：先过滤露骨词，只挑能大方念出来的
    const rareTag: Rare = rarestSafe(c.libTags);
    if (rareTag.k.length > 0) {
      add(out, 'library', 'lib-rare-tag',
        `「${rareTag.k}」这个标签，全库只有 ${rareTag.n} 部`,
        `全库 ${rareTag.n} 部带「${rareTag.k}」`,
        `「${rareTag.k}」是冷门标签，全库 ${rareTag.n} 部`);
      const share: number = Math.max(1, Math.round((rareTag.n * 100) / T));
      add(out, 'library', 'lib-tag-share', `这个标签只占全库 ${share}%`);
    }
    if (c.libTagKinds > 0) {
      add(out, 'library', 'lib-tag-kinds',
        `全库一共 ${c.libTagKinds} 个标签`, `${c.libTagKinds} 个标签里，它挂了几个`);
    }

    if (acts.length > 0) {
      const an: number | undefined = c.libActors.get(acts[0]);
      if (an !== undefined && an > 0) {
        add(out, 'library', 'lib-actor',
          `${acts[0]}在你库里出现 ${an} 次`,
          `这位演员全库 ${an} 部`,
          `全库有 ${an} 部是${acts[0]}的`);
        if (an <= 5) {
          add(out, 'library', 'lib-rare-actor', `${acts[0]}全库只有 ${an} 部，稀客`);
        }
      }
    }
    if (c.libActorKinds > 0) {
      add(out, 'library', 'lib-actor-kinds', `全库 ${c.libActorKinds} 位演员`);
    }
    if (item.series.length > 0) {
      const sn: number | undefined = c.libSeries.get(item.series);
      if (sn !== undefined && sn > 0) {
        add(out, 'library', 'lib-series',
          `「${item.series}」系列全库 ${sn} 部`,
          `这个系列你收了 ${sn} 部`);
        if (sn <= 5) {
          add(out, 'library', 'lib-rare-series', `「${item.series}」全库只有 ${sn} 部`);
        }
      }
    }
    if (item.studio.length > 0) {
      const stn: number | undefined = c.libStudios.get(item.studio);
      if (stn !== undefined && stn > 0) {
        add(out, 'library', 'lib-studio', `${item.studio}的片子，全库 ${stn} 部`);
      }
    }
    if (pre.length > 0) {
      const pn: number | undefined = c.libPrefixes.get(pre);
      if (pn !== undefined && pn > 0) {
        add(out, 'library', 'lib-prefix',
          `${pre} 开头的番号，全库 ${pn} 部`,
          `全库 ${pn} 部都是 ${pre} 开头`);
      }
    }
    if (c.libPrefixKinds > 0) {
      add(out, 'library', 'lib-prefix-kinds', `全库 ${c.libPrefixKinds} 种番号前缀`);
    }
    if (rel !== undefined) {
      const yn: number | undefined = c.libYears.get(`${rel.y}`);
      if (yn !== undefined && yn > 0) {
        add(out, 'library', 'lib-year', `${rel.y} 年的片子，全库只有 ${yn} 部`);
      }
      if (c.libMinYear > 0 && rel.y === c.libMinYear) {
        add(out, 'library', 'lib-oldest', `全库最老的一批，${rel.y} 年`);
      }
      if (c.libMaxYear > 0 && rel.y === c.libMaxYear) {
        add(out, 'library', 'lib-newest', `全库最新的一批，${rel.y} 年`);
      }
    }
    if (c.libMinYear > 0 && c.libMaxYear > c.libMinYear) {
      add(out, 'library', 'lib-year-span',
        `全库从 ${c.libMinYear} 到 ${c.libMaxYear}，横跨 ${c.libMaxYear - c.libMinYear} 年`);
    }
    if (c.libWatched > 0) {
      add(out, 'library', 'lib-watched',
        `全库 ${T} 部，你看过 ${c.libWatched} 部`,
        `全库 ${T} 部，你才碰过 ${c.libWatched} 部`);
    }
    if (c.libFav > 0) {
      add(out, 'library', 'lib-fav', `全库收藏了 ${c.libFav} 部`);
    }
    add(out, 'library', 'lib-share',
      `全库 ${T} 部，今天只翻出 ${c.n} 张`,
      `从 ${T} 部里挑了 ${c.n} 张`);
    if (rt > 0) {
      const rb: number = Math.max(0, Math.min(11, Math.floor(rt / 30)));
      const longer: number = sumFrom(c.libRuntimeBins, rb + 1);
      add(out, 'library', 'lib-longer',
        `全库比它长的只有 ${longer} 部`,
        `比 ${rt} 分钟还长的，全库 ${longer} 部`);
    }
  }

  // ── whim：天马行空 / 气氛组 ────────────────────────────────────────────
  // 这一族明说自己不是事实：玄学、拟人、气氛、自嘲，靠语气成立。
  // 分寸：点到为止，含蓄撩拨，不复述露骨标签、不描写具体行为、不拿人开低俗玩笑。
  const waited: number = upd !== undefined ? daysFrom(upd, c.today) : -1;
  const waitTxt: string = waited > 30 ? `${waited} 天` : '一阵子';
  const lenTxt: string = rt > 0 ? `${rt} 分钟` : '一部片';

  add(out, 'whim', 'whim-almanac',
    '今日宜独自观影，忌开新坑',
    `黄历说：今晚宜 ${lenTxt}，忌快进`,
    '今日宜翻旧片，宜把手机调静音');
  add(out, 'whim', 'whim-fortune',
    '本周运势：宜重看，忌贪多',
    `${c.weekday}运势：宜点开，忌犹豫`,
    '今日宜慢，忌倍速');
  add(out, 'whim', 'whim-persona',
    waited > 30 ? `它在库里等了 ${waitTxt}，今天终于排到号` : '躺了这么久，今天终于轮到它',
    '它大概是今晚最想被点开的一部',
    '别告诉别的片，今天我偏心它');
  add(out, 'whim', 'whim-wait',
    waited > 30 ? `进库 ${waitTxt}，今天第一次被翻到` : '被翻出来也算有个交代',
    '它没催过你，是今天自己排上来的');
  add(out, 'whim', 'whim-tease-light',
    '适合把灯调暗一点再看',
    '建议戴耳机，别问为什么',
    '别在通勤路上点开');
  add(out, 'whim', 'whim-tease-night',
    '今晚别安排别的了',
    `${c.phase}了，留 ${lenTxt} 给它`,
    '看完可能睡不着，慎点');
  add(out, 'whim', 'whim-tease-alone',
    '一个人看比较合适',
    '建议先把手边的事放下',
    '有些片子适合白天，这部不太适合');
  add(out, 'whim', 'whim-heart',
    '心率可能会有点不稳定',
    '别怪我，是它先动的手',
    '气氛组今晚值班');
  add(out, 'whim', 'whim-cosmic',
    '宇宙射线翻转了一个比特，于是它出现了',
    '平行宇宙里，你昨天已经看完了',
    '随机数生成器今天很坚持');
  add(out, 'whim', 'whim-lottery',
    '抽签器说：就是它，别挑了',
    '如果推荐位有情绪，今天它有点上头',
    `第 ${index + 1} 张，手气替你做了决定`);
  add(out, 'whim', 'whim-dare',
    '敢不敢今晚就点开',
    '看完再来评价我眼光',
    '赌五毛你会看到最后');
  add(out, 'whim', 'whim-snark',
    '封面最安静的一部，未必最安分',
    '它不需要理由，它需要你点开',
    '今天这批里，它最不显眼');
  add(out, 'whim', 'whim-honest',
    '算法？没有算法，就是手气',
    '翻到它是运气，不是品味',
    `说不出理由，但它在第 ${index + 1} 张`);
  add(out, 'whim', 'whim-poem',
    `${c.season}天的夜，适合 ${lenTxt} 的它`,
    `${c.weekday}晚上，留 ${lenTxt} 给自己`,
    c.festival.length > 0 ? `${c.festival}，翻到它算应景` : `外头${c.season}天了，屋里正好看片`);

  // ── mood：承认它是随机的，低频出现 ──────────────────────────────────────
  add(out, 'mood', `order-${index}`, `今天第 ${index + 1} 张，翻牌翻到它`, `抽签顺序把它排在第 ${index + 1}`);
  add(out, 'mood', 'shrug', '连翻牌的也没想到会是它', '它自己也不知道为什么在这');
  add(out, 'mood', 'honest', '纯粹是今天手气', '不加理由也行，但既然问了……');
  return out;
}

/** 今天各族的权重：由日期种子决定，让每天气质不同。 */
function groupWeights(seed: string): Map<string, number> {
  const r: () => number = makeRng(hash32(`w|${seed}`));
  const m: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < GROUPS.length; i++) {
    let base: number = 0.75 + r() * 0.9;
    if (GROUPS[i] === 'mood') {
      // 自嘲句刻意压低：偶尔出现才有意思
      base = 0.28;
    } else if (GROUPS[i] === 'library') {
      // 全库级事实是这次的主角，每天得有几条
      base = 1.1 + r() * 0.7;
    } else if (GROUPS[i] === 'whim') {
      // 气氛组要有存在感，但不压过事实族
      base = 0.85 + r() * 0.6;
    }
    m.set(GROUPS[i], base);
  }
  return m;
}

function chooseFor(items: MediaItem[], c: BatchCtx): string[] {
  const rDay: () => number = makeRng(hash32(`d|${c.seed}`));
  const weights: Map<string, number> = groupWeights(c.seed);
  const baseQuota: number = Math.max(2, Math.ceil(items.length / GROUPS.length) + 1);
  const used: Map<string, number> = new Map<string, number>();
  const usedKeys: Map<string, boolean> = new Map<string, boolean>();
  const usedFacts: Map<string, boolean> = new Map<string, boolean>();
  const out: string[] = [];
  const extras: string[] = [];
  for (let g = 0; g < GROUPS.length; g++) {
    used.set(GROUPS[g], 0);
  }

  for (let i = 0; i < items.length; i++) {
    const it: MediaItem = items[i];
    const r: () => number = makeRng(hash32(`${c.seed}|${it.id}|${i}`));
    const cands: Cand[] = collect(it, i, c);
    // 先按 group 归拢，过滤掉配额满 / 句式用过的
    const byGroup: Map<string, Cand[]> = new Map<string, Cand[]>();
    for (let g = 0; g < GROUPS.length; g++) {
      byGroup.set(GROUPS[g], []);
    }
    for (let j = 0; j < cands.length; j++) {
      const cd: Cand = cands[j];
      if (usedKeys.has(cd.key) || usedFacts.has(cd.fact)) {
        continue;
      }
      const n: number | undefined = used.get(cd.group);
      const q: number = (cd.group === 'library' || cd.group === 'whim') ? baseQuota + 1 : baseQuota;
      if (n !== undefined && n >= q) {
        continue;
      }
      const bucket: Cand[] | undefined = byGroup.get(cd.group);
      if (bucket !== undefined) {
        bucket.push(cd);
      }
    }
    // 轮盘赌：权重 × 用得越少越容易中
    const pool: string[] = [];
    const score: number[] = [];
    let total: number = 0;
    for (let g = 0; g < GROUPS.length; g++) {
      const name: string = GROUPS[g];
      const bucket: Cand[] | undefined = byGroup.get(name);
      if (bucket === undefined || bucket.length === 0) {
        continue;
      }
      const w: number | undefined = weights.get(name);
      const usedN: number | undefined = used.get(name);
      const s: number = (w === undefined ? 1 : w) / (1 + (usedN === undefined ? 0 : usedN) * 0.55) +
        (rDay() + r()) * 0.14;
      pool.push(name);
      score.push(s);
      total += s;
    }
    let chosen: string = '';
    let extra: string = '';
    if (total > 0) {
      let x: number = r() * total;
      let idx: number = 0;
      for (let k = 0; k < pool.length; k++) {
        x -= score[k];
        if (x <= 0) {
          idx = k;
          break;
        }
      }
      const gname: string = pool[idx];
      const bucket: Cand[] | undefined = byGroup.get(gname);
      if (bucket !== undefined && bucket.length > 0) {
        const cd: Cand = bucket[Math.floor(r() * bucket.length) % bucket.length];
        chosen = cd.text;
        usedKeys.set(cd.key, true);
        usedFacts.set(cd.fact, true);
        const n: number | undefined = used.get(gname);
        used.set(gname, (n === undefined ? 0 : n) + 1);
      }
      // 约 1/5 的卡再补一句不同族的短句，制造「话没说完」的层次
      if (r() < 0.22 && pool.length > 1) {
        let alt: number = Math.floor(r() * pool.length) % pool.length;
        if (pool[alt] === gname) {
          alt = (alt + 1) % pool.length;
        }
        if (pool[alt] !== gname) {
          const b2: Cand[] | undefined = byGroup.get(pool[alt]);
          if (b2 !== undefined && b2.length > 0) {
            const cd2: Cand = b2[Math.floor(r() * b2.length) % b2.length];
            const n2: number | undefined = used.get(pool[alt]);
            const q2: number = (pool[alt] === 'library' || pool[alt] === 'whim')
              ? baseQuota + 1 : baseQuota;
            if (!usedKeys.has(cd2.key) && !usedFacts.has(cd2.fact) &&
              (n2 === undefined || n2 < q2)) {
              extra = cd2.text;
              usedKeys.set(cd2.key, true);
              usedFacts.set(cd2.fact, true);
              used.set(pool[alt], (n2 === undefined ? 0 : n2) + 1);
            }
          }
        }
      }
    }
    out.push(chosen);
    extras.push(extra);
  }
  for (let i = 0; i < extras.length; i++) {
    if (extras[i].length > 0 && out[i].length > 0) {
      out[i] = `${out[i]}｜${extras[i]}`;
    }
  }
  return out;
}

/** 行级策展词：一句话说清「今天这批是什么气质」，替换掉原来那句没信息量的副标题。 */
function makeHeadline(items: MediaItem[], c: BatchCtx): string {
  const r: () => number = makeRng(hash32(`h|${c.seed}|${items.length}`));
  const pool: string[] = [];
  const ty: number = c.today.getFullYear();
  let sameDay: number = 0;
  let old: number = 0;
  let short: number = 0;
  for (let i = 0; i < items.length; i++) {
    const rel: Ymd | undefined = parseYmd(items[i].release);
    if (rel !== undefined) {
      if (rel.m === c.today.getMonth() + 1 && rel.d === c.today.getDate() && ty - rel.y > 0) {
        sameDay++;
      }
      if (ty - rel.y >= 15) {
        old++;
      }
    }
    if (items[i].runtime > 0 && items[i].runtime < 80) {
      short++;
    }
  }
  if (sameDay > 0) {
    pool.push(`今天有 ${sameDay} 部是「历史上的今天」`, `巧了，${sameDay} 部跟今天同月同日发行`);
  }
  if (old >= Math.ceil(c.n / 3)) {
    pool.push('今天翻出来的，年份都挺早', '这一批偏老，压箱底的那种', '今天走怀旧路线');
  }
  if (c.unseen >= Math.ceil(c.n * 0.4)) {
    pool.push('这批里，大半你还没点开', '今天多是没碰过的', '一堆生面孔');
  }
  if (c.avgScore >= 7.0) {
    pool.push('今天这批，分都不低', '手气不错，评分都挺高');
  }
  if (short >= Math.ceil(c.n / 3)) {
    pool.push('今晚这批都不长', '都是能一口气看完的长度');
  }
  const sh: string = topShared(c.series);
  if (sh.length > 0) {
    pool.push(`今天像是「${sh}」系列专场`);
  }
  if (c.maxYear > 0 && c.minYear > 0 && c.maxYear - c.minYear >= 15) {
    pool.push(`从 ${c.minYear} 到 ${c.maxYear}，跨度有点大`);
  }
  if (c.festival.length > 0) {
    pool.push(`${c.festival}，翻一批应景的`, `${c.festival}的推荐位`);
  }
  if (c.streak >= 3) {
    pool.push(`连着第 ${c.streak} 天翻牌`, `第 ${c.streak} 天，照例换一批`);
  }
  if (c.phase === '深夜' || c.phase === '凌晨') {
    pool.push('这个点，适合短片', '深夜档，随便翻翻');
  }
  if (c.weekday === '周六' || c.weekday === '周日') {
    pool.push('周末，翻一批没看过的', '休息日，慢慢挑');
  }
  if (c.season.length > 0) {
    pool.push(`${c.season}天的这一批`);
  }
  if (c.daysLeft <= 30 && c.daysLeft > 0) {
    pool.push(`今年还剩 ${c.daysLeft} 天`);
  }
  // 带具体数字的候选：即使没触发上面的「气质」判断，这句话也不是空话
  if (c.unseen >= 2) {
    if (c.unseen === c.n) {
      pool.push(`今天这 ${c.n} 部，你一部都没看过`, `全是生面孔，${c.n} 部`, `这批清一色没点开过`);
    } else {
      pool.push(`这批 ${c.n} 部里，${c.unseen} 部是生面孔`, `${c.unseen} 部没看过，${c.n - c.unseen} 部见过`);
    }
  }
  if (c.maxScore > 0 && c.minScore > 0 && c.maxScore - c.minScore >= 0.8) {
    pool.push(`评分从 ${c.minScore.toFixed(1)} 到 ${c.maxScore.toFixed(1)}`);
  }
  if (c.maxYear > 0 && c.minYear > 0 && c.maxYear - c.minYear >= 5) {
    pool.push(`从 ${c.minYear} 到 ${c.maxYear}，横跨 ${c.maxYear - c.minYear} 年`);
  }
  if (c.maxRuntime > 0 && c.minRuntime > 0 && c.maxRuntime - c.minRuntime >= 40) {
    pool.push(`最短 ${c.minRuntime} 分钟，最长 ${c.maxRuntime} 分钟`);
  }
  const shTag: string = topShared(c.tags);
  if (shTag.length > 0) {
    const tagN: number | undefined = c.tags.get(shTag);
    if (tagN !== undefined && tagN >= 2) {
      pool.push(`这批 ${tagN} 部都带「${shTag}」`);
    }
  }
  if (c.streak >= 2) {
    pool.push(`连着第 ${c.streak} 天翻牌`);
  }
  pool.push(c.unseen === c.n ? `今天 ${c.n} 部，全是没看过的` : `今天 ${c.n} 部，${c.unseen} 部是生面孔`,
    `${c.n} 部，换个手气`, '今天这批，慢慢看');
  return pickText(pool, r);
}

function makeTopic(pack: ReasonPack, c: BatchCtx): string {
  const base: string = `今天这 ${c.n} 部是从库里随机翻出来的，不是按你的口味算的。`;
  if (c.stats !== undefined && c.libTotal > 0) {
    return base + `下面多数句子是全库 ${c.libTotal} 部里真实存在的小事，` +
      `也有几句纯粹是气氛话 —— 翻到它就是缘分，别太当真。`;
  }
  return base + `下面每句都是这批数据里真实存在的小事 —— 有些是它自己，有些是你和它。`;
}

export class Reason {
  static readonly DEFAULT_SUBTITLE: string = DEFAULT_SUBTITLE;

  static enabled(): boolean {
    return Store.I.prefString(PREF_ON, '1') !== '0';
  }

  static setEnabled(on: boolean): void {
    Store.I.prefSetString(PREF_ON, on ? '1' : '0');
  }

  /**
   * 生成整批理由。同一天、同一批 id 反复调用结果一致（本地记忆只按天推进）。
   * `stats` 为 undefined 时（老服务端）全库族整体跳过，其余理由不受影响。
   */
  static build(items: MediaItem[], recent: MediaItem[], stats: LibraryStats | undefined): ReasonPack {
    const today: Date = new Date();
    const seed: string = ymdStr(today);
    const seen: SeenEntry[] = loadSeen();
    const streak: number = readStreak(seed);
    const ctx: BatchCtx = makeCtx(items, recent, today, seen, streak, stats);
    const picks: string[] = chooseFor(items, ctx);
    const lines: ReasonLine[] = [];
    let count: number = 0;
    for (let i = 0; i < items.length; i++) {
      const raw: string = picks[i];
      const bar: number = raw.indexOf('｜');
      const main: string = bar >= 0 ? raw.substring(0, bar) : raw;
      const extra: string = bar >= 0 ? raw.substring(bar + 1) : '';
      if (main.length > 0) {
        count++;
      }
      if (extra.length > 0) {
        count++;
      }
      lines.push({
        id: items[i].id,
        number: items[i].number,
        title: items[i].title.length > 0 ? items[i].title : items[i].number,
        reason: main,
        extra: extra
      });
    }
    // 先生成、再写记忆：这样「上次翻到」永远指上一个不同的日子，不会把自己算进去
    saveSeen(seen, seed, items);
    // 当天快照：详情页按 id 查，不必改十几个跳转入口的传参
    Reason.savePack(seed, lines);
    const pack: ReasonPack = {
      headline: makeHeadline(items, ctx), topic: '', lines: lines, count: count
    };
    pack.topic = makeTopic(pack, ctx);
    return pack;
  }

  /** 当天 pack 落到偏好里；只存 id + 文案，不存整份 home 数据。 */
  private static savePack(day: string, lines: ReasonLine[]): void {
    const slim: ReasonLine[] = [];
    for (let i = 0; i < lines.length; i++) {
      const l: ReasonLine = lines[i];
      slim.push({ id: l.id, number: l.number, title: l.title, reason: l.reason, extra: l.extra });
    }
    const data: SavedPack = { day: day, lines: slim };
    try {
      Store.I.prefSetString(PREF_PACK, JSON.stringify(data));
    } catch (err) {
      console.info('[amane] reason pack save failed');
    }
  }

  /**
   * 这部片今天上了推荐位才有理由。跨天、开关关掉、老快照一律返回 undefined。
   * 详情页在 load() 里调它，所以从收藏 / 搜索 / 演员页进来也能看到。
   */
  static forId(id: number): ReasonLine | undefined {
    if (!Reason.enabled() || id <= 0) {
      return undefined;
    }
    const raw: string = Store.I.prefString(PREF_PACK, '');
    if (raw.length === 0) {
      return undefined;
    }
    try {
      const data: SavedPack = JSON.parse(raw) as SavedPack;
      if (data === undefined || data === null || data.day !== ymdStr(new Date())) {
        return undefined;
      }
      const lines: ReasonLine[] = data.lines === undefined || data.lines === null ? [] : data.lines;
      for (let i = 0; i < lines.length; i++) {
        const l: ReasonLine = lines[i];
        if (l !== undefined && l !== null && l.id === id && l.reason.length > 0) {
          return l;
        }
      }
    } catch (err) {
      console.info('[amane] reason pack parse failed');
    }
    return undefined;
  }
}
