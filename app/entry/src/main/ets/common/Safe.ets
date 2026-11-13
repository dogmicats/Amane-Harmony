import {
  CommentItem, HistoryItem, HomeData, HomeRow, ItemDetail, LibraryInfo, LibraryStats,
  MediaFile, MediaItem, StatKV,
  PosterRef, StreamItem, StreamList, SuggestItem, SuggestResult, SuggestTotals, emptySuggestTotals,
  SearchHistoryItem, SearchHistoryList
} from './Types';

/**
 * 服务端字段有可能是 null / 缺失（scratch 数据、老条目），
 * 而 ArkTS 里 `null.length` 会抛未捕获异常直接把应用打崩。
 * 所有进入 UI 的数据都先过这里，缺什么补什么。
 */

function str(value: string): string {
  return value === undefined || value === null ? '' : value;
}

function num(value: number): number {
  if (value === undefined || value === null) {
    return 0;
  }
  const n: number = Number(value);
  return isFinite(n) ? n : 0;
}

function strList(value: string[]): string[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < value.length; i++) {
    if (typeof value[i] === 'string') {
      out.push(value[i]);
    }
  }
  return out;
}

export function safeItem(raw: MediaItem): MediaItem {
  const item: MediaItem = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    updated_at: '', position: 0, duration: 0
  };
  if (raw === undefined || raw === null) {
    return item;
  }
  item.id = Math.trunc(num(raw.id));
  item.number = str(raw.number);
  item.title = str(raw.title);
  item.plot = str(raw.plot);
  item.actors = strList(raw.actors);
  item.tags = strList(raw.tags);
  item.studio = str(raw.studio);
  item.series = str(raw.series);
  item.release = str(raw.release);
  item.runtime = num(raw.runtime);
  item.content_type = str(raw.content_type);
  item.score = num(raw.score);
  item.poster = str(raw.poster);
  item.fanart = str(raw.fanart);
  item.updated_at = str(raw.updated_at);
  item.position = num(raw.position);
  item.duration = num(raw.duration);
  // 服务端已经算好「无码/破解/流出/中字」，这里必须原样带过来，
  // 否则卡片拿到了数据也不显示（之前收藏页就没标签）。
  item.marks = Array.isArray(raw.marks) ? raw.marks : [];
  // 公开扩展 ratings：列表卡右下角「我的评价」标签用，丢了海报上就不显示
  item.my_rating = Math.trunc(num(raw.my_rating === undefined || raw.my_rating === null
    ? 0 : raw.my_rating));
  // 横幅按真实比例定宽，这个字段必须接住（marks 就踩过一次）
  item.fanart_ratio = num(raw.fanart_ratio === undefined || raw.fanart_ratio === null
    ? 0 : raw.fanart_ratio);
  // 2.5.7.7：文件个数（多版本属性）。老服务端没有 → 0，界面上不显示「N 个版本」。
  item.versions = Math.trunc(num(raw.versions === undefined || raw.versions === null
    ? 0 : raw.versions));
  return item;
}

export function safeItems(list: MediaItem[]): MediaItem[] {
  if (list === undefined || list === null || !Array.isArray(list)) {
    return [];
  }
  const out: MediaItem[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(safeItem(list[i]));
  }
  return out;
}

export function safeFile(raw: MediaFile): MediaFile {
  const file: MediaFile = {
    id: 0, path: '', size: 0, duration: 0, definition: '', mosaic: '',
    has_subtitle_in_name: false, has_external_subtitle: false, library_id: 0
  };
  if (raw === undefined || raw === null) {
    return file;
  }
  file.id = Math.trunc(num(raw.id));
  file.path = str(raw.path);
  file.size = num(raw.size);
  file.duration = num(raw.duration);
  file.definition = str(raw.definition);
  file.mosaic = str(raw.mosaic);
  file.has_subtitle_in_name = Number(raw.has_subtitle_in_name) === 1;
  file.has_external_subtitle = Number(raw.has_external_subtitle) === 1;
  file.library_id = Math.trunc(num(raw.library_id));
  return file;
}



export function safeDetail(raw: ItemDetail): ItemDetail {
  const d: ItemDetail = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    favorite: false, position: 0, duration: 0, finished: false, files: [], marks: [], stills: [],
    still_ratios: [], comments: []
  };
  if (raw === undefined || raw === null) {
    return d;
  }
  d.id = Math.trunc(num(raw.id));
  d.number = str(raw.number);
  d.title = str(raw.title);
  d.plot = str(raw.plot);
  d.actors = strList(raw.actors);
  d.tags = strList(raw.tags);
  d.studio = str(raw.studio);
  d.series = str(raw.series);
  d.release = str(raw.release);
  d.runtime = num(raw.runtime);
  d.content_type = str(raw.content_type);
  d.score = num(raw.score);
  d.poster = str(raw.poster);
  d.fanart = str(raw.fanart);
  d.favorite = raw.favorite === true;
  d.position = num(raw.position);
  d.duration = num(raw.duration);
  d.finished = raw.finished === true;

  const files: MediaFile[] = [];
  if (raw.files !== undefined && raw.files !== null && Array.isArray(raw.files)) {
    for (let i = 0; i < raw.files.length; i++) {
      files.push(safeFile(raw.files[i]));
    }
  }
  d.files = files;
  d.marks = Array.isArray(raw.marks) ? raw.marks : [];

  const comments: CommentItem[] = [];
  if (raw.comments !== undefined && raw.comments !== null && Array.isArray(raw.comments)) {
    for (let i = 0; i < raw.comments.length; i++) {
      const c: CommentItem = raw.comments[i];
      if (c === undefined || c === null) {
        continue;
      }
      comments.push({
        id: Math.trunc(num(c.id)),
        body: str(c.body),
        created_at: str(c.created_at),
        updated_at: str(c.updated_at),
        // 我自己写的那条（服务端插在最前并打 mine）：漏了这个字段就高亮不出来
        mine: c.mine === true
      });
    }
  }
  d.comments = comments;

  const stills: string[] = [];
  if (raw.stills !== undefined && raw.stills !== null && Array.isArray(raw.stills)) {
    for (let i = 0; i < raw.stills.length; i++) {
      if (typeof raw.stills[i] === 'string' && raw.stills[i].length > 0) {
        stills.push(raw.stills[i]);
      }
    }
  }
  d.stills = stills;
  // 剧照宽高比：瀑布流靠它给每张图定高，丢了就只能一律按横图排（竖版会被砍头）
  const ratios: number[] = [];
  if (raw.still_ratios !== undefined && raw.still_ratios !== null && Array.isArray(raw.still_ratios)) {
    for (let i = 0; i < raw.still_ratios.length; i++) {
      const r: number = num(raw.still_ratios[i]);
      ratios.push(isFinite(r) && r > 0 ? r : 0);
    }
  }
  d.still_ratios = ratios;
  // 公开扩展 stills：喜欢过的剧照地址（服务端没装扩展时就是空数组）
  d.still_likes = strList(raw.still_likes === undefined ? [] : raw.still_likes);
  // 公开扩展 watch_later：稍后再看状态（没装扩展时恒为 false）
  d.watch_later = raw.watch_later === true;
  // 扩展下发的字段走重建式白名单：不在这里显式接住，详情页会静默丢掉
  d.my_rating = Math.trunc(num(raw.my_rating === undefined ? 0 : raw.my_rating));
  const cids: number[] = [];
  if (raw.collection_ids !== undefined && raw.collection_ids !== null &&
      Array.isArray(raw.collection_ids)) {
    for (let i = 0; i < raw.collection_ids.length; i++) {
      const v: number = Math.trunc(num(raw.collection_ids[i]));
      if (v > 0) {
        cids.push(v);
      }
    }
  }
  d.collection_ids = cids;
  // 没刮削封面时用我截的关键帧兜底（老服务端没这字段就是空串）
  d.frame_cover = raw.frame_cover === undefined || raw.frame_cover === null
    ? '' : String(raw.frame_cover);
  // 我截的帧当剧照：老服务端没有这字段，兜成空数组
  const mine: string[] = [];
  const rawMine = raw.my_stills;
  if (rawMine !== undefined && rawMine !== null && Array.isArray(rawMine)) {
    for (let i = 0; i < rawMine.length; i++) {
      const u: string = String(rawMine[i]);
      if (u.length > 0) {
        mine.push(u);
      }
    }
  }
  d.my_stills = mine;
  // 覆盖层标记：老服务端没有这两个字段，一律按「没改过」处理
  d.poster_is_custom = raw.poster_is_custom === true;
  d.overridden = raw.overridden === true;
  return d;
}

export function safeHistory(list: HistoryItem[]): HistoryItem[] {
  if (list === undefined || list === null || !Array.isArray(list)) {
    return [];
  }
  const out: HistoryItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw: HistoryItem = list[i];
    if (raw === undefined || raw === null) {
      continue;
    }
    const item: HistoryItem = {
      id: Math.trunc(num(raw.id)),
      number: str(raw.number),
      title: str(raw.title),
      poster: str(raw.poster),
      fanart: str(raw.fanart),
      position: num(raw.position),
      duration: num(raw.duration),
      played_at: str(raw.played_at),
      finished: raw.finished === true,
      marks: Array.isArray(raw.marks) ? raw.marks : [],
      // 历史页要能按「我的评分 / 收藏夹」本地筛选、按我的评分排序
      my_rating: Math.trunc(num(raw.my_rating === undefined || raw.my_rating === null
        ? 0 : raw.my_rating)),
      collection_ids: Array.isArray(raw.collection_ids) ? raw.collection_ids : []
    };
    out.push(item);
  }
  return out;
}

/** 统计键白名单：键名、数量都逐条兜底，避免 null 把首页打崩。 */
function safeStatKVs(value: StatKV[]): StatKV[] {
  const out: StatKV[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return out;
  }
  for (let i = 0; i < value.length && out.length < 160; i++) {
    const src: StatKV = value[i];
    if (src === undefined || src === null) {
      continue;
    }
    const k: string = str(src.k);
    if (k.length > 0) {
      out.push({ k: k, n: Math.trunc(num(src.n)) });
    }
  }
  return out;
}

/** 定长分桶：缺的补 0，多的截断，客户端累加时不会越界。 */
function safeBins(value: number[], size: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < size; i++) {
    let n: number = 0;
    if (value !== undefined && value !== null && Array.isArray(value) && i < value.length) {
      n = Math.trunc(num(value[i]));
    }
    out.push(n > 0 ? n : 0);
  }
  return out;
}

/**
 * 全库统计摘要（2.5.7.21）。重建式白名单：服务端多给的字段不在这里补就会静默丢掉。
 * total<=0 一律返回 undefined —— 老服务端 / 统计失败时，理由引擎跳过全库族。
 */
export function safeLibraryStats(raw: LibraryStats | undefined): LibraryStats | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  const src: LibraryStats = raw;
  if (Math.trunc(num(src.total)) <= 0) {
    return undefined;
  }
  const s: LibraryStats = {
    total: Math.trunc(num(src.total)),
    scored: Math.trunc(num(src.scored)),
    avg_score: num(src.avg_score),
    max_score: num(src.max_score),
    min_year: Math.trunc(num(src.min_year)),
    max_year: Math.trunc(num(src.max_year)),
    watched: Math.trunc(num(src.watched)),
    favorites: Math.trunc(num(src.favorites)),
    tag_kinds: Math.trunc(num(src.tag_kinds)),
    actor_kinds: Math.trunc(num(src.actor_kinds)),
    prefix_kinds: Math.trunc(num(src.prefix_kinds)),
    score_bins: safeBins(src.score_bins, 21),
    runtime_bins: safeBins(src.runtime_bins, 12),
    tags: safeStatKVs(src.tags),
    actors: safeStatKVs(src.actors),
    series: safeStatKVs(src.series),
    studios: safeStatKVs(src.studios),
    prefixes: safeStatKVs(src.prefixes),
    years: safeStatKVs(src.years)
  };
  return s;
}

export function safeHome(raw: HomeData): HomeData {  const home: HomeData = { hero: [], continue: [], recommend: [], banners: [], rows: [], libraries: [], generated_at: '' };
  if (raw === undefined || raw === null) {
    return home;
  }
  home.hero = safeItems(raw.hero);
  home.continue = safeItems(raw.continue);
  home.recommend = safeItems(raw.recommend);
  home.banners = safeItems(raw.banners === undefined || raw.banners === null ? [] : raw.banners);
  home.generated_at = str(raw.generated_at);

  const rows: HomeRow[] = [];
  if (raw.rows !== undefined && raw.rows !== null && Array.isArray(raw.rows)) {
    for (let i = 0; i < raw.rows.length; i++) {
      const src: HomeRow = raw.rows[i];
      if (src === undefined || src === null) {
        continue;
      }
      const row: HomeRow = {
        kind: str(src.kind), id: str(src.id), title: str(src.title),
        library_id: Math.trunc(num(src.library_id)), count: Math.trunc(num(src.count)),
        items: safeItems(src.items)
      };
      if (row.items.length > 0) {
        rows.push(row);
      }
    }
  }
  home.rows = rows;

  const libs: LibraryInfo[] = [];
  if (raw.libraries !== undefined && raw.libraries !== null && Array.isArray(raw.libraries)) {
    for (let i = 0; i < raw.libraries.length; i++) {
      const src: LibraryInfo = raw.libraries[i];
      if (src === undefined || src === null) {
        continue;
      }
      const lib: LibraryInfo = {
        id: Math.trunc(num(src.id)), name: str(src.name), count: Math.trunc(num(src.count))
      };
      libs.push(lib);
    }
  }
  home.libraries = libs;
  const stats: LibraryStats | undefined = safeLibraryStats(raw.library_stats);
  if (stats !== undefined) {
    home.library_stats = stats;
  }
  return home;
}

export function safeSuggest(raw: SuggestResult): SuggestItem[] {
  const out: SuggestItem[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const m = raw.items[i];
    if (m === undefined || m === null) {
      continue;
    }
    const id: number = Math.trunc(Number(m.id)) || 0;
    if (id <= 0) {
      continue;
    }
    // 老服务端不发 type：那是影片，别当成空类型在 UI 里消失
    const type: string = str(m.type).length > 0 ? str(m.type) : 'film';
    out.push({
      type: type,
      id: id,
      number: str(m.number),
      title: str(m.title),
      poster: str(m.poster),
      release: str(m.release),
      name: str(m.name),
      count: Math.trunc(num(m.count)),
      image: str(m.image),
      gender: str(m.gender),
      alias: str(m.alias),
      tier: Math.trunc(Number(m.tier)) || 0
    });
  }
  return out;
}

/** 联想结果的完整解析：带 supported / totals，并判断服务端是否认识 types 参数。 */
export function safeSuggestResult(raw: SuggestResult): SuggestResult {
  const out: SuggestResult = {
    items: [], q: '', types: [], supported: [], totals: emptySuggestTotals(), legacy: true
  };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.items = safeSuggest(raw);
  out.q = str(raw.q);
  out.types = strList(raw.types);
  // supported 缺席 = 老服务端把 types 当陌生参数丢了，只可能回影片
  if (Array.isArray(raw.supported)) {
    out.supported = strList(raw.supported);
    out.legacy = false;
  }
  if (raw.totals !== undefined && raw.totals !== null) {
    const t: SuggestTotals = emptySuggestTotals();
    t.actor = Math.trunc(num(raw.totals.actor));
    t.director = Math.trunc(num(raw.totals.director));
    t.tag = Math.trunc(num(raw.totals.tag));
    t.series = Math.trunc(num(raw.totals.series));
    t.studio = Math.trunc(num(raw.totals.studio));
    out.totals = t;
  }
  return out;
}

/** 搜索历史：空关键词的条目直接丢掉（服务端不该写进来，客户端也别画出一颗空胶囊）。 */
export function safeSearchHistory(raw: SearchHistoryList): SearchHistoryItem[] {
  const out: SearchHistoryItem[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const it = raw.items[i];
    if (it === undefined || it === null) {
      continue;
    }
    const q: string = str(it.q).trim();
    if (q.length === 0) {
      continue;
    }
    out.push({ q: q, hits: Math.trunc(num(it.hits)), usedAt: str(it.usedAt) });
  }
  return out;
}

export function safeStreams(raw: StreamList): StreamItem[] {
  const out: StreamItem[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const s: StreamItem = raw.items[i];
    if (s === undefined || s === null) {
      continue;
    }
    out.push({
      key: str(s.key),
      file_id: Math.trunc(num(s.file_id)),
      name: str(s.name),
      size: Math.trunc(num(s.size)),
      duration: Number(s.duration) || 0,
      definition: str(s.definition),
      has_subtitle: s.has_subtitle === true,
      library: str(s.library),
      content_type: str(s.content_type),
      available: s.available === true,
      detail: str(s.detail)
    });
  }
  return out;
}

/**
 * 可点击海报列表（分类列表的 `posterItems`、演员收藏的 `posters`）。
 * 缺 id 或缺地址的条目直接丢掉 —— 点了没反应比少一张图更难受。
 */
export function safePosterRefs(raw: PosterRef[]): PosterRef[] {
  const out: PosterRef[] = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const p = raw[i];
    if (p === undefined || p === null) {
      continue;
    }
    const id: number = Math.trunc(num(p.id));
    const url: string = str(p.url);
    if (id > 0 && url.length > 0) {
      out.push({ id: id, url: url });
    }
  }
  return out;
}
