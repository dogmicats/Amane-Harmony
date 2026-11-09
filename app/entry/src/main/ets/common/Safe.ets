import { HistoryItem, HomeData, HomeRow, IngestTask, ItemDetail, LibraryInfo, MediaFile, MediaItem } from './Types';

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
  const file: MediaFile = { id: 0, path: '', size: 0, duration: 0, definition: '', mosaic: '', library_id: 0 };
  if (raw === undefined || raw === null) {
    return file;
  }
  file.id = Math.trunc(num(raw.id));
  file.path = str(raw.path);
  file.size = num(raw.size);
  file.duration = num(raw.duration);
  file.definition = str(raw.definition);
  file.mosaic = str(raw.mosaic);
  file.library_id = Math.trunc(num(raw.library_id));
  return file;
}

/** 入库队列条目：message 在库里允许为 NULL，status 也可能缺，全部兜底。 */
export function safeIngest(raw: IngestTask): IngestTask {
  const t: IngestTask = {
    src_lib: 0, dst_lib: 0, status: '', message: '', attempts: 0, updated_at: ''
  };
  if (raw === undefined || raw === null) {
    return t;
  }
  t.src_lib = Math.trunc(num(raw.src_lib));
  t.dst_lib = Math.trunc(num(raw.dst_lib));
  t.status = str(raw.status);
  t.message = str(raw.message);
  t.attempts = Math.trunc(num(raw.attempts));
  t.updated_at = str(raw.updated_at);
  return t;
}

export function safeIngestList(raw: IngestTask[]): IngestTask[] {
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return [];
  }
  const out: IngestTask[] = [];
  for (let i = 0; i < raw.length; i++) {
    out.push(safeIngest(raw[i]));
  }
  return out;
}

export function safeDetail(raw: ItemDetail): ItemDetail {
  const d: ItemDetail = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    favorite: false, position: 0, duration: 0, finished: false, files: [], stills: [], ingest: []
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

  const stills: string[] = [];
  if (raw.stills !== undefined && raw.stills !== null && Array.isArray(raw.stills)) {
    for (let i = 0; i < raw.stills.length; i++) {
      if (typeof raw.stills[i] === 'string' && raw.stills[i].length > 0) {
        stills.push(raw.stills[i]);
      }
    }
  }
  d.stills = stills;
  d.ingest = safeIngestList(raw.ingest);
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
      finished: raw.finished === true
    };
    out.push(item);
  }
  return out;
}

export function safeHome(raw: HomeData): HomeData {  const home: HomeData = { hero: [], continue: [], recommend: [], rows: [], libraries: [], generated_at: '' };
  if (raw === undefined || raw === null) {
    return home;
  }
  home.hero = safeItems(raw.hero);
  home.continue = safeItems(raw.continue);
  home.recommend = safeItems(raw.recommend);
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
