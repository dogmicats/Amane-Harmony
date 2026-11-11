import { httpDelete, httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';

/**
 * 公开扩展 watch_later：稍后再看的客户端入口。
 *
 * 三个动作都很薄：列表只拿 id（判断状态 / 页头计数），加入与移出是幂等的。
 * 真正的列表数据走核心 browse（`?watchlater=1`），这样标记、我的评分、
 * 播放进度这些字段都由核心照常补齐，不用在这里再拼一套影片卡片的数据。
 */
export interface WatchLaterIds {
  ids: number[];
  total: number;
}

const BASE: string = '/api/user/watch_later';

/** 队列里的影片 id（最近加入在前）。 */
export async function fetchWatchLaterIds(): Promise<number[]> {
  const text: string = await httpGet(`${Store.I.user}${BASE}`, Store.I.token);
  const data: WatchLaterIds = JSON.parse(text) as WatchLaterIds;
  const out: number[] = [];
  if (data === undefined || data === null || !Array.isArray(data.ids)) {
    return out;
  }
  for (let i = 0; i < data.ids.length; i++) {
    const v: number = Math.trunc(Number(data.ids[i]) || 0);
    if (v > 0) {
      out.push(v);
    }
  }
  return out;
}

export async function addWatchLater(id: number): Promise<void> {
  if (id <= 0) {
    return;
  }
  await httpPost(`${Store.I.user}${BASE}/${id}`, Store.I.token, '{}');
}

export async function removeWatchLater(id: number): Promise<void> {
  if (id <= 0) {
    return;
  }
  await httpDelete(`${Store.I.user}${BASE}/${id}`, Store.I.token);
}
