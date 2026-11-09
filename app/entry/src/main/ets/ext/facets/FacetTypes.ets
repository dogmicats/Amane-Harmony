/**
 * 公开扩展 facets：分类浏览的数据模型与安全解析。
 *
 * 支持的上游分类：tag / series / studio / publisher / user_tag（director 备用）。
 * 与 actors 扩展一样刻意自包含 —— 关掉 ENABLE_FACETS 后核心不残留任何分类类型。
 */

export interface FacetItem {
  id: number;
  name: string;
  count: number;
  /** 系列封面：系列内最近几部的海报，客户端拼四宫格；其他分类为空数组。 */
  posters: string[];
}

export interface FacetList {
  kind: string;
  items: FacetItem[];
  total: number;
  offset: number;
  limit: number;
}

export interface FacetMediaItem {
  id: number;
  number: string;
  title: string;
  release: string;
  score: number;
  poster: string;
  /** 无码 / 破解 / 流出 / 中字 */
  marks: string[];
}

export interface FacetMediaList {
  kind: string;
  id: number;
  items: FacetMediaItem[];
  total: number;
  offset: number;
  limit: number;
}

/** 影片详情的分类归属：系列 / 制片商 / 标签 / 用户标签 / 导演。 */
export interface ItemFacets {
  id: number;
  series: FacetItem;
  studio: FacetItem;
  publisher: FacetItem;
  tags: FacetItem[];
  user_tags: FacetItem[];
  directors: FacetItem[];
}

/** 路由参数：分类列表 → 分类影片页。 */
export interface FacetParams {
  kind: string;
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

export function emptyFacet(): FacetItem {
  const f: FacetItem = { id: 0, name: '', count: 0, posters: [] };
  return f;
}

export function emptyItemFacets(): ItemFacets {
  const d: ItemFacets = {
    id: 0, series: emptyFacet(), studio: emptyFacet(), publisher: emptyFacet(),
    tags: [], user_tags: [], directors: []
  };
  return d;
}

export function safeFacet(raw: FacetItem): FacetItem {
  const f: FacetItem = { id: 0, name: '', count: 0, posters: [] };
  if (raw === undefined || raw === null) {
    return f;
  }
  f.id = Math.trunc(n(raw.id));
  f.name = s(raw.name);
  f.count = Math.trunc(n(raw.count));
  f.posters = Array.isArray(raw.posters) ? raw.posters : [];
  return f;
}

export function safeFacetArray(raw: FacetItem[]): FacetItem[] {
  const out: FacetItem[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const f: FacetItem = safeFacet(raw[i]);
    if (f.id > 0) {
      out.push(f);
    }
  }
  return out;
}

export function safeFacetList(raw: FacetList): FacetList {
  const out: FacetList = { kind: '', items: [], total: 0, offset: 0, limit: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.kind = s(raw.kind);
  out.items = safeFacetArray(raw.items);
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  return out;
}

export function safeFacetMediaList(raw: FacetMediaList): FacetMediaList {
  const out: FacetMediaList = { kind: '', id: 0, items: [], total: 0, offset: 0, limit: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.kind = s(raw.kind);
  out.id = Math.trunc(n(raw.id));
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  const src: FacetMediaItem[] = Array.isArray(raw.items) ? raw.items : [];
  for (let i = 0; i < src.length; i++) {
    const m = src[i];
    out.items.push({
      id: Math.trunc(n(m.id)),
      number: s(m.number),
      title: s(m.title),
      release: s(m.release),
      score: Number(m.score) || 0,
      poster: s(m.poster),
      marks: Array.isArray(m.marks) ? m.marks : []
    });
  }
  return out;
}

export function safeItemFacets(raw: ItemFacets): ItemFacets {
  const d: ItemFacets = emptyItemFacets();
  if (raw === undefined || raw === null) {
    return d;
  }
  d.id = Math.trunc(n(raw.id));
  d.series = safeFacet(raw.series);
  d.studio = safeFacet(raw.studio);
  d.publisher = safeFacet(raw.publisher);
  d.tags = safeFacetArray(raw.tags);
  d.user_tags = safeFacetArray(raw.user_tags);
  d.directors = safeFacetArray(raw.directors);
  return d;
}

/** 分类 kind 的中文名，列表页和详情页共用。 */
export function facetLabel(kind: string): string {
  if (kind === 'series') {
    return '系列';
  }
  if (kind === 'studio') {
    return '制片商';
  }
  if (kind === 'publisher') {
    return '发行商';
  }
  if (kind === 'user_tag') {
    return '我的标签';
  }
  if (kind === 'director') {
    return '导演';
  }
  return '标签';
}
