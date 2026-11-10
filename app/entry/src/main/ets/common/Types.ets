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
  /** 无码 / 破解 / 流出 / 中字，服务端汇总好直接给。 */
  marks?: string[];
  /** 横图真实宽高比（宽/高）：每日推荐桶幅按它定宽，不再强行 16:9。 */
  fanart_ratio?: number;
}

export interface MediaFile {
  id: number;
  path: string;
  size: number;
  duration: number;
  definition: string;
  mosaic: string;
  has_subtitle_in_name: boolean;
  has_external_subtitle: boolean;
  library_id: number;
}

/** 一个条目下的可播版本（amane-user /api/user/streams）。 */
export interface StreamItem {
  key: string;
  file_id: number;
  name: string;
  size: number;
  duration: number;
  definition: string;
  has_subtitle: boolean;
  library: string;
  content_type: string;
  /** 浏览器口径的可解码性；客户端用 mpv，不可用项仍可尝试。 */
  available: boolean;
  detail: string;
}

export interface StreamList {
  items: StreamItem[];
  source: string;
  metadata_id: number;
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
  /** 无码 / 破解 / 流出 / 中字，服务端按文件汇总，详情页头部直接画。 */
  marks: string[];
  stills: string[];
  /** 与 stills 等长的宽高比（w/h）；0 = 服务端也没量过，由详情页按图片实测补。 */
  still_ratios: number[];
  comments: CommentItem[];
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
  /** 每日推荐桶幅：服务端已校验过的真横图（宽≥720、宽高比≥1.25），带 fanart_ratio。 */
  banners: MediaItem[];
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
  /** 观看记录同样是影片列表，标记必须带上。 */
  marks?: string[];
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
  /** 从盲盒点进来的那张剧照；详情页用它做「从中心放大铺满 → 扩散淡出」的转场。 */
  heroUrl?: string;
}

/** amane 的「评价」：网友推荐 / 官方评价摘录。 */
export interface CommentItem {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
}

export interface PlayerParams {
  id: number;
  number: string;
  title: string;
  position: number;
  /** 指定版本：/api/user/streams 返回的 key（f<文件id>）；缺省表示让上游自己挑。 */
  fileKey?: string;
  /** 版本显示名，播放页顶栏用。 */
  fileName?: string;
}

export interface BrowseParams {
  libraryId: number;
  title: string;
}

/** 搜索联想里的一条（/api/user/suggest，tier：1 精确 / 2 相关 / 3 扩大）。 */
export interface SuggestItem {
  id: number;
  number: string;
  title: string;
  poster: string;
  release: string;
  tier: number;
}

export interface SuggestResult {
  items: SuggestItem[];
  q: string;
}
