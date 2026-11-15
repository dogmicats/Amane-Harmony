/**
 * 桌面卡片的数据缓存（2.6.1.26）
 *
 * 为什么不给卡片单独发请求：卡片跑在 FormExtensionAbility 的进程里，要自己拿
 * 服务器地址、token、还要处理外网/内网切换 —— 那套逻辑在 `Store` 里，而 Store 需要
 * AbilityContext 初始化。卡片里复刻一遍等于把登录态散到第二个进程。
 *
 * 所以：**前台 App 抓到首页数据时顺手把「今天推什么 + 上次看到哪」写进偏好**，
 * 卡片只读这份缓存。代价是卡片内容最多旧到上次打开 App 为止；对「桌面看一眼今天推什么」
 * 这个用途足够，而且永远不会因为断网/切换网络变成一张白卡。
 *
 * 偏好键与 Store 共用同一个库（`amane_pref`），FormExtensionAbility 用同名的
 * preferences 实例读同一个文件。
 */
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { HomeData, MediaItem } from './Types';

/** 和 `Store` 里保持一致（两边必须同一个文件名，否则卡片读不到）。 */
export const PREF_NAME: string = 'amane_pref';
/** 卡片缓存的键。 */
export const KEY_CARD: string = 'widget_card';

/** 卡片需要的全部字段，都是字符串 —— formBindingData 只吃字符串。 */
export interface CardPayload {
  /** 今日推荐的番号。 */
  number: string;
  /** 今日推荐的标题。 */
  title: string;
  /** 海报绝对地址（已带 token，卡片里直接 Image()）。 */
  posterUrl: string;
  /** 为什么推它（首页那句 headline，可为空）。 */
  reason: string;
  /** 继续观看的番号（没有就是空串）。 */
  contNumber: string;
  /** 继续观看的标题。 */
  contTitle: string;
  /** 写入时间 `MM-DD HH:mm`，卡片右下角标一下「什么时候的数据」。 */
  at: string;
}

/** 空缓存：卡片在所有字段都没有时显示「打开 App 同步一次」。 */
export function emptyPayload(): CardPayload {
  return { number: '', title: '', posterUrl: '', reason: '',
    contNumber: '', contTitle: '', at: '' };
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 从首页数据里挑出卡片要的两条。
 * `imgOf` 由调用方传 `Store.I.img` —— 这个模块不依赖 Store，卡片进程也能引用它。
 */
export function payloadOf(home: HomeData, imgOf: (raw: string) => string): CardPayload {
  const pick: MediaItem | undefined =
    home.banners.length > 0 ? home.banners[0]
      : (home.recommend.length > 0 ? home.recommend[0] : undefined);
  const cont: MediaItem | undefined =
    home.continue.length > 0 ? home.continue[0] : undefined;
  const now: Date = new Date();
  const out: CardPayload = emptyPayload();
  if (pick !== undefined) {
    out.number = pick.number;
    out.title = pick.title;
    out.posterUrl = imgOf(pick.poster.length > 0 ? pick.poster : pick.fanart);
  }
  if (cont !== undefined) {
    out.contNumber = cont.number;
    out.contTitle = cont.title;
  }
  out.at = `${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}`;
  return out;
}

/** 卡片侧读取（FormExtensionAbility 用；解析失败返回空串）。 */
export function readRaw(ctx: object): string {
  try {
    const store: preferences.Preferences =
      preferences.getPreferencesSync(ctx as Context, { name: PREF_NAME });
    return store.getSync(KEY_CARD, '') as string;
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] card read: ${e.code}`);
    return '';
  }
}

/** 卡片侧解析成对象（字段缺失一律当空串，UI 自己决定怎么退化）。 */
export function parsePayload(raw: string): CardPayload {
  const out: CardPayload = emptyPayload();
  if (raw.length === 0) {
    return out;
  }
  try {
    const obj: Record<string, string> = JSON.parse(raw) as Record<string, string>;
    out.number = obj['number'] === undefined ? '' : obj['number'];
    out.title = obj['title'] === undefined ? '' : obj['title'];
    out.posterUrl = obj['posterUrl'] === undefined ? '' : obj['posterUrl'];
    out.reason = obj['reason'] === undefined ? '' : obj['reason'];
    out.contNumber = obj['contNumber'] === undefined ? '' : obj['contNumber'];
    out.contTitle = obj['contTitle'] === undefined ? '' : obj['contTitle'];
    out.at = obj['at'] === undefined ? '' : obj['at'];
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] card parse: ${e.code}`);
  }
  return out;
}
