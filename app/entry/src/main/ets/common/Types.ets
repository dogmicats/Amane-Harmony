/** 与 amane-user / amane 交互的数据模型。字段名与服务端 JSON 一一对应。 */

export interface MediaItem {
  id: number;
  number: string;
  title: string;
  plot: string;
  actors: string[];
  tags: string[];
  studio: string;
  series: string;
  release: string;
  runtime: number;
  content_type: string;
  score: number;
  poster: string;
  fanart: string;
  updated_at: string;
  position: number;
  duration: number;
}

export interface MediaFile {
  id: number;
  path: string;
  size: number;
  duration: number;
  definition: string;
  mosaic: string;
  library_id: number;
}

/** 收藏自动入库队列里的一条待办（amane-user /api/user/ingest）。 */
export interface IngestTask {
  src_lib: number;
  dst_lib: number;
  status: string;
  message: string;
  attempts: number;
  updated_at: string;
}

export interface IngestList {
  items: IngestTask[];
  counts: Record<string, number>;
}

export interface ItemDetail {
  id: number;
  number: string;
  title: string;
  plot: string;
  actors: string[];
  tags: string[];
  studio: string;
  series: string;
  release: string;
  runtime: number;
  content_type: string;
  score: number;
  poster: string;
  fanart: string;
  favorite: boolean;
  position: number;
  duration: number;
  finished: boolean;
  files: MediaFile[];
  stills: string[];
  ingest: IngestTask[];
}

export interface HomeRow {
  kind: string;
  id: string;
  title: string;
  library_id: number;
  count: number;
  items: MediaItem[];
}

export interface LibraryInfo {
  id: number;
  name: string;
  count: number;
}

export interface HomeData {
  hero: MediaItem[];
  continue: MediaItem[];
  recommend: MediaItem[];
  rows: HomeRow[];
  libraries: LibraryInfo[];
  generated_at: string;
}

export interface BrowseResult {
  items: MediaItem[];
  total: number;
  offset: number;
  limit: number;
}

export interface FavList {
  items: MediaItem[];
  total: number;
}

export interface ClientConfig {
  version: string;
  image_token: string;
  playback_source: string;
  libraries: LibraryInfo[];
}

export interface HistoryItem {
  id: number;
  number: string;
  title: string;
  poster: string;
  fanart: string;
  position: number;
  duration: number;
  played_at: string;
  finished: boolean;
}

export interface HistoryList {
  items: HistoryItem[];
  total: number;
}

export interface StatsInfo {
  favorites: number;
  history: number;
  finished: number;
  library_items: number;
}

export interface DetailParams {
  id: number;
}

export interface PlayerParams {
  id: number;
  number: string;
  title: string;
  position: number;
}

export interface BrowseParams {
  libraryId: number;
  title: string;
}
