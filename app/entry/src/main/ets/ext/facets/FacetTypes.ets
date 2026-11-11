/**
 * 公开扩展 facets：分类浏览的数据模型与安全解析。
 *
 * 支持的上游分类：tag / series / studio / publisher / user_tag（director 备用）。
 * 与 actors 扩展一样刻意自包含 —— 关掉 ENABLE_FACETS 后核心不残留任何分类类型。
 */
import { PosterRef } from '../../common/Types';
import { safePosterRefs } from '../../common/Safe';

/** 分类自带的属性：占比最高的标签（系列用，2.4.5.19 起随列表下发）。 */
export interface TagShare {
  id: number;
  name: string;
  /** 该标签片数 / 分类总片数（0–1）。 */
  ratio: number;
}

export interface FacetItem {
  id: number;
  name: string;
  count: number;
  /** 系列 / 标签封面：最近几部的海报，客户端拼四宫格；其他分类为空数组。 */
  posters: string[];
  /** 与 posters 对应的影片 id（收藏页点海报直接进影片，2.4.5.11 起下发）。 */
  posterItems: PosterRef[];
  /** 系列的「属性」：占比最高的三个标签（已排除隐藏标签）。 */
  topTags: TagShare[];
  /** 分类自己的收藏位。与「影片收藏」无关：不写收藏表、不触发入库。 */
  isFavorite: boolean;
  /** 分类内最晚的发行日，YYYY-MM-DD；没有影片时为空。 */
  lastRelease: string;
  /** 分类内最新一条媒体文件的入库日，YYYY-MM-DD。 */
  lastAdded: string;
  /** 是否被用户隐藏（只在分类浏览列表里过滤，不影响影片与刮削）。 */
  isHidden: boolean;
  /**
   * 制片商 / 发行商的番号前缀 TOP3（如 ["SPSD","GHKQ","THZ"]）。
   * 日文厂牌名认不出来时，这串字母是更快的识别锚点；其他分类恒为空数组。
   */
  prefixes: string[];
}

export interface FacetList {
  kind: string;
  items: FacetItem[];
  total: number;
  offset: number;
  limit: number;
  /** 随机排序的种子：翻页必须带回去，否则每页重摇会重复。 */
  seed: number;
  /** 当前是否把隐藏项也列出来了。 */
  includeHidden: boolean;
  /** 这个分类一共隐藏了多少条（按钮上显示数字）。 */
  hiddenCount: number;
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
  /** 公开扩展 ratings：我给这部片打的分（0 = 没打过）。 */
  my_rating?: number;
}

export interface FacetMediaList {
  kind: string;
  id: number;
  /** 分类头部：名字 / 收藏位 / 缩略图。影片墙标题栏与收藏按钮用。 */
  facet: FacetItem;
  items: FacetMediaItem[];
  total: number;
  offset: number;
  limit: number;
}

/** 分类收藏的返回：favorite 是写入后的目标值。 */
export interface FacetFavoriteResult {
  kind: string;
  id: number;
  favorite: boolean;
}

/** 同番号前缀列表的参数（`pages/PrefixPage`）。 */
export interface PrefixParams {
  prefix: string;
}

/** 影片详情的分类归属：系列 / 制片商 / 标签 / 用户标签 / 导演。 */
export interface ItemFacets {
  id: number;
  /** 本部番号的前缀（`SPSD-14` → `SPSD`），详情页「同番号」标签用；认不出为空串。 */
  prefix: string;
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
  const f: FacetItem = {
    id: 0, name: '', count: 0, posters: [], posterItems: [], topTags: [], isFavorite: false,
    lastRelease: '', lastAdded: '', isHidden: false, prefixes: []
  };
  return f;
}

export function emptyItemFacets(): ItemFacets {
  const d: ItemFacets = {
    id: 0, prefix: '', series: emptyFacet(), studio: emptyFacet(), publisher: emptyFacet(),
    tags: [], user_tags: [], directors: []
  };
  return d;
}

/**
 * 多选时选中的分类。
 *
 * 为什么不是只存 id：选中的项可能散在列表两头，而且一换搜索词、一翻页，
 * 当前 this.items 里就没有它了 —— 只存 id 的话名字和作品数都还原不出来。
 * 所以选中那一刻就把名字和作品数一起带上，与当前列表解耦。
 */
export interface FacetPick {
  id: number;
  name: string;
  count: number;
}

export function pickOf(f: FacetItem): FacetPick {
  const p: FacetPick = { id: f.id, name: f.name, count: f.count };
  return p;
}

export function safeFacet(raw: FacetItem): FacetItem {
  const f: FacetItem = emptyFacet();
  if (raw === undefined || raw === null) {
    return f;
  }
  f.id = Math.trunc(n(raw.id));
  f.name = s(raw.name);
  f.count = Math.trunc(n(raw.count));
  f.posters = Array.isArray(raw.posters) ? raw.posters : [];
  f.posterItems = safePosterRefs(raw.posterItems);
  f.topTags = safeTagShares(raw.topTags);
  f.isFavorite = raw.isFavorite === true;
  f.lastRelease = s(raw.lastRelease);
  f.lastAdded = s(raw.lastAdded);
  f.isHidden = raw.isHidden === true;
  f.prefixes = Array.isArray(raw.prefixes) ? raw.prefixes : [];
  return f;
}

/** 系列属性：只留有名有字的，ratio 夹到 0–1（服务端已算好，这里只做兜底）。 */
export function safeTagShares(raw: TagShare[]): TagShare[] {
  const out: TagShare[] = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const t = raw[i];
    if (t === undefined || t === null) {
      continue;
    }
    const name: string = s(t.name);
    if (name.length === 0) {
      continue;
    }
    const r: number = n(t.ratio);
    out.push({
      id: Math.trunc(n(t.id)),
      name: name,
      ratio: r > 1 ? 1 : (r < 0 ? 0 : r)
    });
  }
  return out;
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
  const out: FacetList = {
    kind: '', items: [], total: 0, offset: 0, limit: 0,
    seed: 0, includeHidden: false, hiddenCount: 0
  };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.kind = s(raw.kind);
  out.items = safeFacetArray(raw.items);
  out.total = Math.trunc(n(raw.total));
  out.offset = Math.trunc(n(raw.offset));
  out.limit = Math.trunc(n(raw.limit));
  out.seed = Math.trunc(n(raw.seed));
  out.includeHidden = raw.includeHidden === true;
  out.hiddenCount = Math.trunc(n(raw.hiddenCount));
  return out;
}

export function safeFacetMediaList(raw: FacetMediaList): FacetMediaList {
  const out: FacetMediaList = {
    kind: '', id: 0, facet: emptyFacet(), items: [], total: 0, offset: 0, limit: 0
  };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.kind = s(raw.kind);
  out.id = Math.trunc(n(raw.id));
  out.facet = safeFacet(raw.facet);
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
      marks: Array.isArray(m.marks) ? m.marks : [],
      // 海报卡右下角的「我的评价」标签
      my_rating: Math.trunc(m.my_rating === undefined || m.my_rating === null
        ? 0 : Number(m.my_rating))
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
  d.prefix = s(raw.prefix);
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
