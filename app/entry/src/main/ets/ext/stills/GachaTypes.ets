/**
 * 公开扩展 stills：抽卡模式（随机剧照墙）的数据模型与安全解析。
 *
 * 「抽卡」= 把这个列表范围（标签 / 系列 / 制片商 / 导演 / 媒体库 / 收藏…）里的
 * 影片剧照随机铺成瀑布流，点一张直接进那部片的详情页。
 *
 * 与 actors / facets 一样刻意自包含：关掉 ENABLE_GACHA 后核心页面不残留任何类型。
 * 服务端字段可能缺失，进入 UI 之前一律先过 safeGachaPage()。
 */

/** 一张剧照。字段与演员页的 ActorStill 完全一致，迁移时可直接替换。 */
export interface GachaStill {
  /** 所属影片 id —— 点图用它跳详情。 */
  id: number;
  number: string;
  url: string;
  /** 宽高比（w/h）：服务端量过就下发，客户端首帧就能按真实比例摆瀑布流。 */
  ratio: number;
}

export interface GachaPage {
  scope: string;
  id: number;
  items: GachaStill[];
  /**
   * 这个范围里有多少部片「有剧照」。
   * 0 表示真没有（文案说「这个范围还没有剧照」），不是加载失败。
   */
  candidates: number;
}

/** 一个可抽卡的范围。列表页把这三样交给 GachaWall 就够了。 */
export interface GachaScope {
  /** tag / series / studio / publisher / director / user_tag / library / favorite / all / actor */
  scope: string;
  /** 对应实体 id；favorite / all 传 0。 */
  id: number;
  /** 出错与空墙文案里用的范围名（标签名、库名…）。 */
  label: string;
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

export function safeGachaPage(raw: GachaPage): GachaPage {
  const out: GachaPage = { scope: '', id: 0, items: [], candidates: 0 };
  if (raw === undefined || raw === null) {
    return out;
  }
  out.scope = s(raw.scope);
  out.id = Math.trunc(n(raw.id));
  out.candidates = Math.trunc(n(raw.candidates));
  const src: GachaStill[] = Array.isArray(raw.items) ? raw.items : [];
  for (let i = 0; i < src.length; i++) {
    const item: GachaStill = src[i];
    if (item === undefined || item === null) {
      continue;
    }
    const id: number = Math.trunc(n(item.id));
    const url: string = s(item.url);
    if (id > 0 && url.length > 0) {
      out.items.push({ id: id, number: s(item.number), url: url, ratio: n(item.ratio) });
    }
  }
  return out;
}

/** 空范围（页面还没拿到参数时用，避免 undefined 判断散在各处）。 */
export function emptyGachaScope(): GachaScope {
  return { scope: 'all', id: 0, label: '' };
}
