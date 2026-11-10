/**
 * 公开扩展 actors：/api/user/actors* 的数据模型与安全解析。
 *
 * 刻意自包含，不往核心 common/Types.ets、common/Safe.ets 里加字段：
 * 关掉扩展后核心不应该残留任何「演员」相关类型。服务端字段可能为 null / 缺失，
 * 所有进入 UI 的数据都要先过 safeXxx()，否则 ArkTS 里 null.length 会直接崩。
 */

export interface ActorItem {
  id: number;
  name: string;
  count: number;
  gender: string;
  birthday: string;
  birthplace: string;
  height: number;
  bust: number;
  waist: number;
  hip: number;
  cup: string;
  avatar: string;
}

export interface ActorDetail {
  id: number;
  name: string;
  count: number;
  gender: string;
  birthday: string;
  height: number;
  cup: string;
  avatar: string;
  aliases: string[];
  overview: string;
  tagline: string;
  birthplace: string;
  bust: number;
  waist: number;
  hip: number;
  avatars: string[];
  updated_at: string;
}

export interface ActorMediaItem {
  id: number;
  number: string;
  title: string;
  release: string;
  poster: string;
  score: number;
  /** 无码 / 破解 / 流出 / 中字 */
  marks: string[];
}

export interface ActorList {
  items: ActorItem[];
  total: number;
  offset: number;
  limit: number;
}

export interface ActorMediaList {
  items: ActorMediaItem[];
  total: number;
  offset: number;
  limit: number;
}

export interface ActorLookup {
  id: number;
  name: string;
}

/** 路由参数：从演员网格或影片详情跳演员详情。 */
export interface ActorParams {
  id: number;
  name: string;
}

function s(v: string): string {
  return v === undefined || v === null ? '' : v;
}

function n(v: number): number {
  if (v === undefined || v === null) {
    return 0;
  }
  const x: number = Number(v);
  return isFinite(x) ? x : 0;
}

function sl(v: string[]): string[] {
  if (v === undefined || v === null || !Array.isArray(v)) {
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < v.length; i++) {
    if (typeof v[i] === 'string') {
      out.push(v[i]);
    }
  }
  return out;
}

export function emptyActorDetail(): ActorDetail {
  const d: ActorDetail = {
    id: 0, name: '', count: 0, gender: '', birthday: '', height: 0, cup: '', avatar: '',
    aliases: [], overview: '', tagline: '', birthplace: '', bust: 0, waist: 0, hip: 0,
    avatars: [], updated_at: ''
  };
  return d;
}

export function safeActor(raw: ActorItem): ActorItem {
  const a: ActorItem = {
    id: 0, name: '', count: 0, gender: '', birthday: '', birthplace: '',
    height: 0, bust: 0, waist: 0, hip: 0, cup: '', avatar: ''
  };
  if (raw === undefined || raw === null) {
    return a;
  }
  a.id = Math.trunc(n(raw.id));
  a.name = s(raw.name);
  a.count = Math.trunc(n(raw.count));
  a.gender = s(raw.gender);
  a.birthday = s(raw.birthday);
  a.birthplace = s(raw.birthplace);
  a.height = Math.trunc(n(raw.height));
  a.bust = Math.trunc(n(raw.bust));
  a.waist = Math.trunc(n(raw.waist));
  a.hip = Math.trunc(n(raw.hip));
  a.cup = s(raw.cup);
  a.avatar = s(raw.avatar);
  return a;
}

export function safeActorList(raw: ActorList): ActorList {
  const out: ActorList = { items: [], total: 0, offset: 0, limit: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  const src: ActorItem[] = Array.isArray(raw.items) ? raw.items : [];
  for (let i = 0; i < src.length; i++) {
    out.items.push(safeActor(src[i]));
  }
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  return out;
}

export function safeActorDetail(raw: ActorDetail): ActorDetail {
  const d: ActorDetail = emptyActorDetail();
  if (raw === undefined || raw === null) {
    return d;
  }
  d.id = Math.trunc(n(raw.id));
  d.name = s(raw.name);
  d.count = Math.trunc(n(raw.count));
  d.gender = s(raw.gender);
  d.birthday = s(raw.birthday);
  d.height = Math.trunc(n(raw.height));
  d.cup = s(raw.cup);
  d.avatar = s(raw.avatar);
  d.aliases = sl(raw.aliases);
  d.overview = s(raw.overview);
  d.tagline = s(raw.tagline);
  d.birthplace = s(raw.birthplace);
  d.bust = Math.trunc(n(raw.bust));
  d.waist = Math.trunc(n(raw.waist));
  d.hip = Math.trunc(n(raw.hip));
  d.avatars = sl(raw.avatars);
  d.updated_at = s(raw.updated_at);
  return d;
}

export function safeActorMediaList(raw: ActorMediaList): ActorMediaList {
  const out: ActorMediaList = { items: [], total: 0, offset: 0, limit: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  const src: ActorMediaItem[] = Array.isArray(raw.items) ? raw.items : [];
  for (let i = 0; i < src.length; i++) {
    const m = src[i];
    out.items.push({
      id: Math.trunc(n(m.id)),
      number: s(m.number),
      title: s(m.title),
      release: s(m.release),
      poster: s(m.poster),
      score: Number(m.score) || 0,
      marks: Array.isArray(m.marks) ? m.marks : []
    });
  }
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  return out;
}

/** 影片出演阵容（带头像），来自 /api/user/item/{id}/cast。 */
export interface CastMember {
  id: number;
  name: string;
  gender: string;
  avatar: string;
}

export interface CastMemberList {
  items: CastMember[];
}

/** 共演筛选结果：一部影片 + 它的阵容统计。 */
export interface CastFindItem {
  id: number;
  number: string;
  title: string;
  release: string;
  runtime: number;
  content_type: string;
  score: number;
  poster: string;
  marks: string[];
  female_count: number;
  male_count: number;
  cast_total: number;
  cast: CastMember[];
  /** 导演名（最多 3 个）：共演页要能一眼看出「这批结果是不是同一个导演包的」。 */
  directors: string[];
}

/** 共演页导演筛选栏的候选项（来自 /api/user/facets/director）。 */
export interface DirectorHit {
  id: number;
  name: string;
  count: number;
}

export interface DirectorHitList {
  items: DirectorHit[];
  total: number;
}

export function safeDirectorHits(raw: DirectorHitList): DirectorHit[] {
  const out: DirectorHit[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const d: DirectorHit = raw.items[i];
    if (d === undefined || d === null) {
      continue;
    }
    const id: number = Math.trunc(n(d.id));
    const name: string = s(d.name);
    if (id > 0 && name.length > 0) {
      out.push({ id: id, name: name, count: Math.trunc(n(d.count)) });
    }
  }
  return out;
}

export interface CastFindList {
  items: CastFindItem[];
  total: number;
  offset: number;
  limit: number;
  /** 服务端回显的 `female_n` / `male_n` / `director_id`。
   *  老服务端（< 1.3.8）不认识这些参数、也不会回显 —— 客户端用它判断
   *  「条件是生效了还是被旧服务端默默忽略了」，否则页面会若无其事地显示全库结果。 */
  female_n: number[];
  male_n: number[];
  director_id: number[];
}

export function safeCastMember(raw: CastMember): CastMember {
  const c: CastMember = { id: 0, name: '', gender: 'unknown', avatar: '' };
  if (raw === undefined || raw === null) {
    return c;
  }
  c.id = Math.trunc(n(raw.id));
  c.name = s(raw.name);
  c.gender = s(raw.gender);
  c.avatar = s(raw.avatar);
  return c;
}

export function safeCastMembers(raw: CastMember[]): CastMember[] {
  const out: CastMember[] = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    out.push(safeCastMember(raw[i]));
  }
  return out;
}

export function safeCastFindList(raw: CastFindList): CastFindList {
  const out: CastFindList = {
    items: [], total: 0, offset: 0, limit: 0,
    female_n: [], male_n: [], director_id: []
  };
  if (raw === undefined || raw === null) {
    return out;
  }
  const src: CastFindItem[] = Array.isArray(raw.items) ? raw.items : [];
  for (let i = 0; i < src.length; i++) {
    const m = src[i];
    out.items.push({
      id: Math.trunc(n(m.id)),
      number: s(m.number),
      title: s(m.title),
      release: s(m.release),
      runtime: Math.trunc(n(m.runtime)),
      content_type: s(m.content_type),
      score: Number(m.score) || 0,
      poster: s(m.poster),
      marks: Array.isArray(m.marks) ? m.marks : [],
      female_count: Math.trunc(n(m.female_count)),
      male_count: Math.trunc(n(m.male_count)),
      cast_total: Math.trunc(n(m.cast_total)),
      cast: safeCastMembers(m.cast),
      directors: Array.isArray(m.directors) ? m.directors : []
    });
  }
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  out.female_n = intList(raw.female_n);
  out.male_n = intList(raw.male_n);
  out.director_id = intList(raw.director_id);
  return out;
}

/** 回显用的整数数组：老服务端没有这个字段时给空数组（不留 undefined）。 */
function intList(raw: number[]): number[] {
  const out: number[] = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const v: number = Math.trunc(Number(raw[i]));
    if (isFinite(v)) {
      out.push(v);
    }
  }
  return out;
}

/** 演员作品里的随机剧照（点图跳对应影片详情）。 */
export interface ActorStill {
  id: number;
  number: string;
  url: string;
  /** 宽高比（w/h）：服务端量过就下发，客户端首帧就能按真实比例摆瀑布流。 */
  ratio: number;
}

export interface ActorStillList {
  items: ActorStill[];
  actor_id: number;
}

export function safeActorStills(raw: ActorStillList): ActorStill[] {
  const out: ActorStill[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const item: ActorStill = raw.items[i];
    if (item === undefined || item === null) {
      continue;
    }
    const id: number = Math.trunc(n(item.id));
    const url: string = s(item.url);
    if (id > 0 && url.length > 0) {
      out.push({ id: id, number: s(item.number), url: url, ratio: n(item.ratio) });
    }
  }
  return out;
}
