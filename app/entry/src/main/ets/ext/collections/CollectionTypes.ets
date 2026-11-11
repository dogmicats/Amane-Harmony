import { httpGet, httpPost, httpPut, httpDelete } from '../../common/Http';
import { Store } from '../../common/Store';
import { ChipOption } from '../../common/BrowseOptions';

/** 收藏夹：用户自创清单。服务端 /api/user/collections。 */
export interface CollectionInfo {
  id: number;
  name: string;
  /** 清单里的影片数。 */
  n: number;
}

export interface CollectionList {
  items: CollectionInfo[];
}

export interface CollectionCreateResult {
  ok: boolean;
  id: number;
  name: string;
}

export interface IdListResult {
  ids: number[];
}

const BASE: string = '/api/user/collections';

/** 重建式白名单：老服务端没有这个扩展时 items 缺失，直接回空数组。 */
export function safeCollections(raw: CollectionList): CollectionInfo[] {
  const out: CollectionInfo[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw.items)) {
    return out;
  }
  for (let i = 0; i < raw.items.length; i++) {
    const it: CollectionInfo = raw.items[i];
    if (it === undefined || it === null) {
      continue;
    }
    out.push({
      id: Math.trunc(Number(it.id) || 0),
      name: typeof it.name === 'string' ? it.name : '',
      n: Math.trunc(Number(it.n) || 0)
    });
  }
  return out;
}

export async function fetchCollections(): Promise<CollectionInfo[]> {
  const text: string = await httpGet(`${Store.I.user}${BASE}`, Store.I.token);
  return safeCollections(JSON.parse(text) as CollectionList);
}

/** 抽屉里「收藏夹」那一组 chip：全部 / 未归类 / 每个清单。取不到就只给前两项。 */
export async function collectionChipOptions(): Promise<ChipOption[]> {
  const out: ChipOption[] = [
    { key: '', label: '全部' },
    { key: 'none', label: '未归类' }
  ];
  try {
    const lists: CollectionInfo[] = await fetchCollections();
    for (let i = 0; i < lists.length; i++) {
      out.push({ key: `${lists[i].id}`, label: lists[i].name });
    }
  } catch (err) {
    // 老服务端 / 没装 collections 扩展：保留「全部 / 未归类」，不让抽屉空着
  }
  return out;
}

export async function fetchItemCollections(mid: number): Promise<number[]> {
  const text: string = await httpGet(`${Store.I.user}${BASE}/of/${mid}`, Store.I.token);
  const data: IdListResult = JSON.parse(text) as IdListResult;
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

export async function createCollection(name: string): Promise<CollectionCreateResult> {
  const text: string = await httpPost(`${Store.I.user}${BASE}`, Store.I.token,
    JSON.stringify({ name: name }));
  return JSON.parse(text) as CollectionCreateResult;
}

/** 改名：服务端 PUT /collections/{id}，重名会 409。 */
export async function renameCollection(id: number, name: string): Promise<void> {
  await httpPut(`${Store.I.user}${BASE}/${id}`, Store.I.token,
    JSON.stringify({ name: name }));
}

/** 删除清单：连同里面的归类关系一起删掉（影片本身不会被取消收藏）。 */
export async function deleteCollection(id: number): Promise<void> {
  await httpDelete(`${Store.I.user}${BASE}/${id}`, Store.I.token);
}

export async function setItemCollections(mid: number, ids: number[]): Promise<void> {
  await httpPut(`${Store.I.user}${BASE}/of/${mid}`, Store.I.token,
    JSON.stringify({ ids: ids }));
}

/** 归类即收藏：先把 favorites 补上，再写清单关联。 */
export async function ensureFavorite(mid: number): Promise<void> {
  await httpPut(`${Store.I.user}/api/user/favorites/${mid}`, Store.I.token, '');
}

/** 取消收藏会触发服务端 favorite_del 钩子，自动清掉所有清单关联。 */
export async function removeFavorite(mid: number): Promise<void> {
  await httpDelete(`${Store.I.user}/api/user/favorites/${mid}`, Store.I.token);
}
