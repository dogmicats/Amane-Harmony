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
  /** 公开扩展 ratings：我给这部片打的分，0 = 没打过（老服务端没这字段）。 */
  my_rating?: number;
  /** 横图真实宽高比（宽/高）：每日推荐桶幅按它定宽，不再强行 16:9。 */
  fanart_ratio?: number;
  /** 该片在库里有多少个文件（= 几个版本）。2.5.7.7 起服务端随列表一起给。 */
  versions?: number;
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
  /**
   * 公开扩展 stills：这部片里已经被我「喜爱」的剧照地址（老服务端没这字段）。
   * 与 `stills` 里的元素逐字比对，决定心形是实心还是空心。
   */
  still_likes?: string[];
  /** 公开扩展 watch_later：这部片在不在「稍后再看」队列里（老服务端没这字段）。 */
  watch_later?: boolean;
  comments: CommentItem[];
  /** 公开扩展 ratings：我给这部片打的分，0 = 没打过（老服务端没这字段）。 */
  my_rating?: number;
  /** 公开扩展 collections：所属的自创清单 id（老服务端没这字段）。 */
  collection_ids?: number[];
  /**
   * 公开扩展 highlights：没有刮削封面时，拿我截的关键帧当封面（R25）。
   * 只在 scraped poster 为空时兜底，不覆盖已有封面。
   */
  frame_cover?: string;
  /** 公开扩展 highlights：我自己截的帧（当剧照用），排在刮削剧照前面。 */
  my_stills?: string[];
  /** 服务端覆盖层：这张海报是本地换过的（不是库里的原图），据此才给「恢复原封面」。 */
  poster_is_custom?: boolean;
  /** 服务端覆盖层：这部片有任何本地改动（字段或封面）。 */
  overridden?: boolean;
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
  /** 用户换过的媒体库封面（站内相对路径）；空 = 客户端用海报拼贴（2.5.5.4）。 */
  cover?: string;
}

/** 全库计数里的一个键（只下发这批推荐涉及的键，不塞全库字典）。 */
export interface StatKV {
  k: string;
  n: number;
}

/**
 * 全库统计摘要（2.5.7.21）：由 /api/user/home 下发，给推荐理由提供「全库级」事实。
 * 老服务端没有这个字段时 whole 为 undefined，理由引擎自动跳过全库族。
 */
export interface LibraryStats {
  total: number;
  /** 有评分的片数（算百分位的分母）。 */
  scored: number;
  avg_score: number;
  max_score: number;
  min_year: number;
  max_year: number;
  watched: number;
  favorites: number;
  tag_kinds: number;
  actor_kinds: number;
  prefix_kinds: number;
  /** 0.5 分一档，下标 = round(score*2)，共 21 档。 */
  score_bins: number[];
  /** 30 分钟一档，下标 = floor(runtime/30)，共 12 档。 */
  runtime_bins: number[];
  tags: StatKV[];
  actors: StatKV[];
  series: StatKV[];
  studios: StatKV[];
  prefixes: StatKV[];
  years: StatKV[];
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
  /** 全库统计摘要；老服务端不下发，客户端按 undefined 处理。 */
  library_stats?: LibraryStats;
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
  /** 公开扩展 ratings / collections：历史记录页按这两项本地筛选排序（不分页，一次 120 条）。 */
  my_rating?: number;
  collection_ids?: number[];
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
  /**
   * 进来就开播（观看记录 / 我的弹幕 / 截帧管理点进来的跳转）。
   * 详情页顶部直接起播放器，切回竖屏时下面仍然是完整详情页。
   */
  autoplay?: boolean;
  position?: number;
  fileKey?: string;
  fileName?: string;
}

/** amane 的「评价」：网友推荐 / 官方评价摘录。 */
export interface CommentItem {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
  /** 我自己写的那条（存 user.db，详情接口插在最前）。 */
  mine?: boolean;
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

/**
 * 一张可点击的海报：影片 id + 已代理的图片地址。
 *
 * 分类列表与演员收藏都用它（服务端的 `posterItems` / `posters`），
 * 这样「点海报直接进那部片」不需要客户端再按 URL 反查 id。
 */
export interface PosterRef {
  id: number;
  url: string;
}

export interface BrowseParams {
  libraryId: number;
  title: string;
  /** 从详情页点「N 岁」进来：预置出演年龄分桶，key 见 common/BrowseOptions.ets。 */
  ageBand?: string;
  /** 预置排序键，例如 cast_age；缺省用 BrowseGrid 默认的最近更新。 */
  sort?: string;
  /** 预置年龄性别（female / male）；缺省读全局偏好，默认 female。 */
  ageGender?: string;
  /** 只看某个清单的片（2.5.5.25）：清单页 / 详情页跳进来时给。 */
  collectionId?: number;
}

/**
 * 搜索联想里的一条（/api/user/suggest，tier：1 精确 / 2 相关 / 3 扩大）。
 *
 * `type` 决定这一行是什么、点了去哪：
 *   film     影片 —— number/title/poster 有值，点进详情页
 *   actor    演员 —— name/count/image，点进演员作品列表
 *   director / tag / series / studio —— 分类，点进分类影片墙
 * 老服务端（< 1.3.11）只会给影片，`type` 缺失时一律按 film 处理。
 */
export interface SuggestItem {
  type: string;
  id: number;
  number: string;
  title: string;
  poster: string;
  release: string;
  /** 实体（演员/标签/…）的名字；影片行为空。 */
  name: string;
  /** 实体的影片数，卡片上用来判断「值不值得点进去」；影片行为 0。 */
  count: number;
  /** 实体的头像 / 封面；影片行用 poster。 */
  image: string;
  /** 仅演员有：female / male / unknown（服务端已统一小写）。 */
  gender: string;
  /**
   * 仅演员有：这次是按「别名」命中的才带出来（如搜「蕾」命中「つぼみ」）。
   * 名字自己命中时为空，卡片上就不写「别名 xxx」。
   */
  alias: string;
  tier: number;
}

/** 各类型命中总数：联想每类只回几条，结果页的「共 N 个」靠它。 */
export interface SuggestTotals {
  actor: number;
  director: number;
  tag: number;
  series: number;
  studio: number;
}

export function emptySuggestTotals(): SuggestTotals {
  const t: SuggestTotals = { actor: 0, director: 0, tag: 0, series: 0, studio: 0 };
  return t;
}

/**
 * `supported` 缺失 = 老服务端（不认识 types 参数，只会回影片）。
 * 客户端据此提示「升级服务端才能按类型搜」，而不是假装筛过了。
 */
export interface SuggestResult {
  items: SuggestItem[];
  q: string;
  types: string[];
  supported: string[];
  totals: SuggestTotals;
  legacy: boolean;
}

/** 搜索历史里的一条（/api/user/search/history）。服务端按「最近使用」倒序给。 */
export interface SearchHistoryItem {
  /** 关键词原文（最后一次输入的写法）。 */
  q: string;
  /** 搜过几次。 */
  hits: number;
  /** 最近一次搜索时间，ISO 字符串；客户端只用来排序，不展示。 */
  usedAt: string;
}

export interface SearchHistoryList {
  items: SearchHistoryItem[];
  total: number;
}
