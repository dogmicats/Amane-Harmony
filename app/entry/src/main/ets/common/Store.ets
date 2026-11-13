import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet, httpPut, probe } from './Http';
import { Downloader } from './Downloader';
import { ClientConfig, ItemDetail, LibraryInfo } from './Types';
import { BuildConfig } from './BuildConfig';

const PREF_NAME: string = 'amane_pref';
const KEY_LAN_AMANE: string = 'amane_base';
const KEY_LAN_USER: string = 'user_base';
const KEY_WAN: string = 'wan_base';
/**
 * 外网「用户数据」单独一个地址：外网是一个域名、Caddy 内部按路径分流，
 * 留空 = 沿用外网主地址（旧行为）。
 */
const KEY_WAN_USER: string = 'wan_user_base';
const KEY_TOKEN: string = 'api_token';
const KEY_LEGACY: string = 'server_url';
const KEY_MODE: string = 'net_mode';
const KEY_GACHA_COUNT: string = 'gacha_count';
const KEY_GACHA_AUTO: string = 'gacha_auto';

/**
 * 默认值由 tools/version.py sync --channel <self|public> 生成，不写在源码里：
 * self 注入内网地址与 token，public 全为空（用户首次启动自行填写）。
 * 这样公开发布的包里不会带任何凭据。
 */
export const DEFAULT_AMANE: string = BuildConfig.DEFAULT_AMANE;
export const DEFAULT_USER: string = BuildConfig.DEFAULT_USER;
export const DEFAULT_TOKEN: string = BuildConfig.DEFAULT_TOKEN;
export const DEFAULT_WAN_AMANE: string = BuildConfig.DEFAULT_WAN;

export const MODE_AUTO: string = 'auto';
export const MODE_LAN: string = 'lan';
export const MODE_WAN: string = 'wan';

/** 去掉结尾斜杠，避免拼出 //api。 */
export function trimBase(raw: string): string {
  let url: string = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

export function normalizeBase(raw: string, scheme: string): string {
  let url: string = raw.trim();
  if (url.length === 0) {
    return '';
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = `${scheme}://${url}`;
  }
  return trimBase(url);
}

/**
 * 全局状态：服务器地址、token、图片 token、收藏 id 集合。
 * 页面之间共享，写操作就地更新（收藏的心形不用重新拉列表）。
 *
 * 地址分两套：
 *   lanAmane / lanUser —— 家里两个端口（8000 媒体、8770 用户数据）
 *   wanAmane           —— 出门只有一个域名，反向代理按路径分流到两个端口
 * amane / user 是「当前生效值」，由 resolve() 决定，页面只读这两个。
 */
export class Store {
  static I: Store = new Store();

  lanAmane: string = DEFAULT_AMANE;
  lanUser: string = DEFAULT_USER;
  wanAmane: string = DEFAULT_WAN_AMANE;
  /** 外网的用户数据地址；留空 = 与 wanAmane 相同（走域名分流）。 */
  wanUser: string = '';

  amane: string = DEFAULT_AMANE;
  user: string = DEFAULT_USER;
  token: string = DEFAULT_TOKEN;
  imageToken: string = '';
  playbackSource: string = 'nas.local';
  libraries: LibraryInfo[] = [];
  favIds: Set<number> = new Set<number>();
  /**
   * 分类页的「脏」标记：在分类影片墙里改了收藏 / 隐藏，返回列表时要知道该重拉。
   * 只用一个布尔，不让每个页面各自维护一套回调。
   */
  facetDirty: boolean = false;
  /**
   * 影片被删掉的「脏」标记：详情页把某个条目的最后一份可播文件删掉后，
   * 返回列表时媒体库/搜索里那张卡必须消失。与 facetDirty 分开，避免重拉标签列表。
   */
  itemRemoved: boolean = false;
  /**
   * 「元数据 / 封面被改过」的脏标记（2.5.5.7）。
   *
   * 详情页换了封面或改了字段之后置位，Index 回到前台时据此重拉**媒体库那条链**
   * —— 之前只刷了首页和收藏，媒体库 Tab 还挂着旧封面，看着就是「只有详情页变了」。
   */
  coverDirty: boolean = false;
  /**
   * 详情页预取缓存：点剧照时先把 /api/user/item/{id} 拿到，
   * 详情页 `takeDetail` 命中就能立刻渲染，不再闪一次加载圈。
   * 一次性使用（取走即删），避免脏数据长期驻留。
   */
  private detailCache: Map<number, ItemDetail> = new Map<number, ItemDetail>();
  mode: string = MODE_AUTO;
  ready: boolean = false;
  /** 本次启动是否走了外网，仅用于界面提示。 */
  onWan: boolean = false;
  /**
   * 抽卡模式：一轮摆几张剧照（6 / 10 / 16）。
   * 放在全局是为了「设置页调一次、所有列表页一起生效」；服务端上限 36，
   * 客户端一次会抓 3 倍做本地池子，所以 16 → 一次 36 张、够两轮。
   */
  gachaCount: number = 10;
  /** 打开列表页时是否直接进抽卡模式（默认关：列表还是列表）。 */
  gachaAuto: boolean = false;

  private store: preferences.Preferences | undefined = undefined;

  init(context: common.UIAbilityContext): void {
    try {
      this.store = preferences.getPreferencesSync(context, { name: PREF_NAME });
      const legacy: string = this.store.getSync(KEY_LEGACY, DEFAULT_AMANE) as string;
      this.lanAmane = trimBase(this.store.getSync(KEY_LAN_AMANE, legacy) as string);
      this.lanUser = trimBase(this.store.getSync(KEY_LAN_USER, DEFAULT_USER) as string);
      this.wanAmane = trimBase(this.store.getSync(KEY_WAN, DEFAULT_WAN_AMANE) as string);
      this.wanUser = trimBase(this.store.getSync(KEY_WAN_USER, '') as string);
      this.token = this.store.getSync(KEY_TOKEN, DEFAULT_TOKEN) as string;
      this.mode = this.store.getSync(KEY_MODE, MODE_AUTO) as string;
      const gc: number = Number(this.store.getSync(KEY_GACHA_COUNT, 10) as number);
      this.gachaCount = gc >= 4 && gc <= 24 ? Math.trunc(gc) : 10;
      this.gachaAuto = this.store.getSync(KEY_GACHA_AUTO, false) as boolean;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] read prefs: ${err.code} ${err.message}`);
    }
    this.useLan();
  }

  save(): void {
    if (this.store === undefined) {
      return;
    }
    try {
      this.store.putSync(KEY_LAN_AMANE, this.lanAmane);
      this.store.putSync(KEY_LAN_USER, this.lanUser);
      this.store.putSync(KEY_WAN, this.wanAmane);
      this.store.putSync(KEY_WAN_USER, this.wanUser);
      this.store.putSync(KEY_TOKEN, this.token);
      this.store.putSync(KEY_MODE, this.mode);
      this.store.putSync(KEY_GACHA_COUNT, this.gachaCount);
      this.store.putSync(KEY_GACHA_AUTO, this.gachaAuto);
      this.store.flush().catch((error: BusinessError) => {
        console.error(`[amane] flush: ${error.code} ${error.message}`);
      });
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] save prefs: ${err.code} ${err.message}`);
    }
  }

  /**
   * 通用小偏好读写：页面自己的开关（例如搜索范围多选）不必各建一套 Preferences。
   * 键名一律以页面名开头，避免和网络配置那套 KEY_* 撞车。
   */
  prefString(key: string, def: string): string {
    if (this.store === undefined) {
      return def;
    }
    try {
      const v: string = this.store.getSync(key, def) as string;
      return v === undefined || v === null ? def : v;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] read pref ${key}: ${err.code} ${err.message}`);
      return def;
    }
  }

  prefSetString(key: string, value: string): void {
    if (this.store === undefined) {
      return;
    }
    try {
      this.store.putSync(key, value);
      this.store.flush().catch((error: BusinessError) => {
        console.error(`[amane] flush pref: ${error.code} ${error.message}`);
      });
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] save pref ${key}: ${err.code} ${err.message}`);
    }
  }

  useLan(): void {
    this.amane = this.lanAmane;
    this.user = this.lanUser;
    this.onWan = false;
  }

  /**
   * 播放前再试一次内网。
   *
   * 即便启动时被判成外网，只要此刻能连上局域网，就让播放回落到内网 ——
   * 本地/局域网片源走隧道回环是没必要的，也是卡顿的主因。
   * 返回 true 表示这次做了切换。
   */
  async preferLanForPlay(): Promise<boolean> {
    if (!this.onWan || this.lanUser.length === 0) {
      return false;
    }
    const ok: boolean = await probe(`${this.lanUser}/api/user/ping`, 1200);
    if (ok) {
      this.useLan();
      return true;
    }
    return false;
  }

  /**
   * 外网：媒体走 /api/*，用户数据走 /api/user/* 和 /img，默认由 Caddy 按路径分流到同一个域名。
   * 填了 `wanUser` 就用它（外网想连另一台/另一个端口时，域名 + 端口是唯一能表达的方式）。
   */
  useWan(): void {
    this.amane = this.wanAmane;
    this.user = this.wanUser.length > 0 ? this.wanUser : this.wanAmane;
    this.onWan = true;
  }

  /** 启动时选路：自动模式先探局域网，探不到就试外网地址。 */
  async resolve(): Promise<string> {
    // 公开版四个默认值全为空：未配置时直接返回，不发任何请求。
    if (this.lanAmane.length === 0 && this.wanAmane.length === 0) {
      this.useLan();
      return '';
    }
    if (this.mode === MODE_LAN) {
      this.useLan();
      return this.amane;
    }
    if (this.mode === MODE_WAN) {
      this.useWan();
      return this.amane;
    }
    // 探测顺序与超时很关键：
    // 以前只探 8000 的 /api/health、超时 1500ms，Wi-Fi 首次握手稍慢就判成「不在家」，
    // 于是播放走 VPS 隧道 —— 文件明明在本机 NAS 上，却被绕到外网再回来，
    // 1~2MB/s 正好卡在 8Mbps 的临界，表现就是「播一下停一下、拖动要重新加载」。
    const lanOk: boolean = (this.lanUser.length > 0
      ? await probe(`${this.lanUser}/api/user/ping`, 3500)
      : false)
      || (this.lanAmane.length > 0 && await probe(`${this.lanAmane}/api/health`, 2500));
    if (lanOk || this.wanAmane.length === 0) {
      this.useLan();
    } else {
      this.useWan();
    }
    return this.amane;
  }

  /** 拉一次服务端配置：图片 token、播放源、库列表。 */
  async loadConfig(): Promise<void> {
    const text: string = await httpGet(`${this.user}/api/user/config`, this.token);
    const cfg: ClientConfig = JSON.parse(text) as ClientConfig;
    this.imageToken = cfg.image_token;
    this.playbackSource = cfg.playback_source;
    this.libraries = cfg.libraries;
    this.ready = true;
  }

  async loadFavIds(): Promise<void> {
    const text: string = await httpGet(`${this.user}/api/user/favorites/ids`, this.token);
    const obj: Record<string, number[]> = JSON.parse(text) as Record<string, number[]>;
    const ids: Set<number> = new Set<number>();
    const list: number[] = obj.ids;
    for (let i = 0; i < list.length; i++) {
      ids.add(list[i]);
    }
    this.favIds = ids;
  }

  cacheDetail(detail: ItemDetail): void {
    if (detail.id > 0) {
      this.detailCache.set(detail.id, detail);
    }
  }

  takeDetail(id: number): ItemDetail | undefined {
    const hit: ItemDetail | undefined = this.detailCache.get(id);
    if (hit !== undefined) {
      this.detailCache.delete(id);
    }
    return hit;
  }

  isFav(id: number): boolean {
    return this.favIds.has(id);
  }

  /** 切换收藏，返回新状态。失败时抛出，由调用方提示。 */
  async toggleFav(id: number): Promise<boolean> {
    const on: boolean = this.favIds.has(id);
    if (on) {
      await httpDelete(`${this.user}/api/user/favorites/${id}`, this.token);
      this.favIds.delete(id);
      return false;
    }
    await httpPut(`${this.user}/api/user/favorites/${id}`, this.token, '{}');
    this.favIds.add(id);
    return true;
  }

  /**
   * 播放地址：走 amane-user 的流代理，token 放在 query 里。
   * 不能直连 amane 的 /api/playback —— @mpv-ohos/mpv-arkts 1.0.0 的 httpHeaders
   * 会把 "Authorization" 编成 "%65%authorization" 发出去，服务端一律 401；
   * 而 amane 的播放接口又不认 ?token=。由代理补正确请求头，见 server.py 的 play()。
   */
  playUrl(metadataId: number, fileKey: string = ''): string {
    const base: string = `${this.user}/api/user/play/${this.playbackSource}/${metadataId}`;
    let url: string = `${base}?token=${encodeURIComponent(this.token)}`;
    // 指定版本：key 形如 f<文件id>，服务端据此转发到 /streams/{key}
    if (fileKey.length > 0) {
      url += `&key=${encodeURIComponent(fileKey)}`;
    }
    return url;
  }

  /**
   * 播放源：离线缓存优先（2.5.6）。
   *
   * 有本地文件就返回 `file://` 路径给 mpv，完全不经网络；没有才回落到代理地址。
   * 放在这里而不是塞进 `playUrl()`：后者是纯拼串，`Downloader` 又反过来读偏好，
   * 两边互相 import 容易绕成环。播放页只调这一个入口。
   */
  playSource(metadataId: number, fileKey: string = ''): string {
    if (fileKey.length > 0) {
      const local: string = Downloader.localPathOf(metadataId, fileKey);
      if (local.length > 0) {
        // 记一笔「什么时候看的」，离线页的「按最久没看清理」要用（2.5.7）
        Downloader.markOpened(metadataId, fileKey);
        return `file://${local}`;
      }
    }
    return this.playUrl(metadataId, fileKey);
  }

  /**
   * 离线字幕的本地地址（2.5.6）：`{subId: 绝对路径}` 写在偏好 `offline_subs` 里，
   * 下载视频时顺手存好。命中了返回 `file://` 路径，播放页直接用，断网也有字幕。
   */
  localSubtitle(id: string): string {
    if (id.length === 0) {
      return '';
    }
    const raw: string = this.prefString('offline_subs', '');
    if (raw.length === 0) {
      return '';
    }
    try {
      const map = JSON.parse(raw) as Record<string, string>;
      const p = map[id];
      if (p === undefined || p === null || p.length === 0) {
        return '';
      }
      return `file://${p}`;
    } catch (err) {
      return '';
    }
  }

  /** 图片地址：资源走 amane（带图片 token），外链走本服务的代理。 */  img(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    if (raw.startsWith('/img?')) {
      return `${this.user}${raw}`;
    }
    // 写真库上传的图在旁挂服务下，token 也必须用旁挂的
    if (raw.startsWith('/api/user/')) {
      const sep: string = raw.indexOf('?') >= 0 ? '&' : '?';
      return `${this.user}${raw}${sep}token=${this.token}`;
    }
    if (raw.startsWith('/api/')) {
      const sep: string = raw.indexOf('?') >= 0 ? '&' : '?';
      return `${this.amane}${raw}${sep}token=${this.imageToken}`;
    }
    return raw;
  }
}
