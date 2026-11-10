import {
  CommentItem, HistoryItem, HomeData, HomeRow, ItemDetail, LibraryInfo, MediaFile, MediaItem,
  StreamItem, StreamList, SuggestItem, SuggestResult, SuggestTotals, emptySuggestTotals,
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
  // 横幅按真实比例定宽，这个字段必须接住（marks 就踩过一次）
  item.fanart_ratio = num(raw.fanart_ratio === undefined || raw.fanart_ratio === null
    ? 0 : raw.fanart_ratio);
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
        updated_at: str(c.updated_at)
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
      marks: Array.isArray(raw.marks) ? raw.marks : []
    };
    out.push(item);
  }
  return out;
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
