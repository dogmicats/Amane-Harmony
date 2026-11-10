/**
 * 公开扩展 trailers —— 数据层（本轮只有类型与解析，UI 等源站能通再做）。
 *
 * 为什么先把这一层落下来：`GET /api/user/trailers` 与详情页的 `trailers` 字段都是
 * snake/camel 混着的服务端产物，解析时少接一个字段就会在界面上静默消失（marks 踩过一次）。
 * 这一层没有 @Component、没有页面入口，编译进包里也不产生任何可见 UI。
 *
 * 服务端契约见 `extensions/public/trailers/README.md`：
 *   GET /api/user/trailers?scope=&id=&limit=&exclude=
 *     → { scope, id, items: [{id, number, title, runtime, poster, trailer, count}], total, excluded }
 *   GET /api/user/trailer/{mid}?i=N   → 视频流（Range 透传）
 */

/** 盲盒里的一支预告片（卡片数据）。 */
export interface TrailerItem {
  /** metadata id，点「看正片 / 详情」用它。 */
  id: number;
  number: string;
  title: string;
  /** 正片片长（分钟），0 = 服务端没有。 */
  runtime: number;
  /** 已过图片代理的封面（相对路径，走 Store.img）。 */
  poster: string;
  /** 预告片地址（相对路径，如 `/api/user/trailer/123?i=0`），由 Store 补宿主与 token。 */
  trailer: string;
  /** 这部片有几支预告片。 */
  count: number;
}

export interface TrailerPage {
  scope: string;
  id: number;
  items: TrailerItem[];
  /** 该范围里一共有多少部片带预告片；0 = 一支都抽不到，空墙文案要用。 */
  total: number;
  /** 客户端这次传过去的排除数，回显用。 */
  excluded: number;
}

// 与 common/Safe.ets 同一套写法：服务端字段可能是 null / 缺失，
// 而 ArkTS 里 `null.length` 会抛未捕获异常直接把应用打崩。
function num(value: number): number {
  if (value === undefined || value === null) {
    return 0;
  }
  const n: number = Number(value);
  return isFinite(n) ? n : 0;
}

function text(value: string): string {
  return value === undefined || value === null ? '' : value;
}

/** 服务端字段一律按白名单取：多一个字段不带进来，少一个字段给默认值。 */
export function safeTrailerPage(raw: TrailerPage): TrailerPage {
  const out: TrailerPage = { scope: 'all', id: 0, items: [], total: 0, excluded: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.scope = text(raw.scope).length > 0 ? text(raw.scope) : 'all';
  out.id = num(raw.id);
  out.total = num(raw.total);
  out.excluded = num(raw.excluded);
  if (raw.items !== undefined && raw.items !== null && Array.isArray(raw.items)) {
    for (let i = 0; i < raw.items.length; i++) {
      const it: TrailerItem = raw.items[i];
      if (it === undefined || it === null) {
        continue;
      }
      const url: string = text(it.trailer);
      // 没有播放地址的条目直接丢掉：卡片画出来却点不动，比少一张更糟
      if (url.length === 0) {
        continue;
      }
      out.items.push({
        id: num(it.id),
        number: text(it.number),
        title: text(it.title),
        runtime: num(it.runtime),
        poster: text(it.poster),
        trailer: url,
        count: num(it.count)
      });
    }
  }
  return out;
}

/**
 * 详情页的 `trailers` 字段（`item_extra` 钩子下发）→ 可播地址列表。
 *
 * 老服务端没有这个字段，或者这个扩展被关掉时是空数组 —— 两种情况都返回空，
 * 调用方据此整块隐藏入口。
 */
export function safeTrailerUrls(raw: string[]): string[] {
  const out: string[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const url: string = text(raw[i]);
    if (url.length > 0) {
      out.push(url);
    }
  }
  return out;
}
