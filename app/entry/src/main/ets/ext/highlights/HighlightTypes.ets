/**
 * 「影片亮点」数据结构（对应服务端扩展 highlights，scope=public）。
 *
 * 服务端在片长里均匀撒点抽帧，按时间升序回一串缩略图；`t` 就是那一帧的秒数，
 * 点一下直接把它当起播位置交给播放页 —— 缩略图和在哪儿起播必须是同一个数，
 * 否则「点了第 3 张却从第 5 张的位置开始」这种错位极难查。
 */

export interface HighlightItem {
  /** 起播位置（秒，一位小数）。 */
  t: number;
  /** 同一个位置的毫秒值，也是缩略图 URL 里的 key。 */
  ms: number;
  /** `/api/user/highlights/<file_id>/<ms>.jpg`，用 Store.I.img() 补 host + token。 */
  url: string;
}

export interface HighlightList {
  ok: boolean;
  id: number;
  file_id: number;
  /** 播放页认的版本 key（f<文件id>），点亮点时原样带过去。 */
  file_key: string;
  duration: number;
  count: number;
  seed: number;
  items: HighlightItem[];
  /** >0 = 还有几张在后台抽，等一会儿再来一次。 */
  pending: number;
  reason: string;
}

function str(value: string | null | undefined): string {
  return typeof value === 'string' ? value : '';
}

function num(value: number | null | undefined): number {
  const n: number = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function safeItems(raw: HighlightItem[] | null | undefined): HighlightItem[] {
  const out: HighlightItem[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const it: HighlightItem = raw[i];
    if (it === undefined || it === null) {
      continue;
    }
    const url: string = str(it.url);
    if (url.length === 0) {
      continue;
    }
    out.push({ t: num(it.t), ms: Math.trunc(num(it.ms)), url: url });
  }
  return out;
}

/** 服务端缺字段 / 老服务端 404 时也不能让详情页塌掉：一律收敛成「没有亮点」。 */
export function safeHighlights(raw: HighlightList | null | undefined): HighlightList {
  const empty: HighlightList = {
    ok: false, id: 0, file_id: 0, file_key: '', duration: 0,
    count: 0, seed: 0, items: [], pending: 0, reason: ''
  };
  if (raw === undefined || raw === null) {
    return empty;
  }
  return {
    ok: raw.ok === true,
    id: Math.trunc(num(raw.id)),
    file_id: Math.trunc(num(raw.file_id)),
    file_key: str(raw.file_key),
    duration: num(raw.duration),
    count: Math.trunc(num(raw.count)),
    seed: Math.trunc(num(raw.seed)),
    items: safeItems(raw.items),
    pending: Math.trunc(num(raw.pending)),
    reason: str(raw.reason)
  };
}
