import { Store } from './Store';

/**
 * 刷一刷的「**喜爱**」—— 和正片的「收藏」是两回事（用户 2026-11-14 23:53 要求可查看，
 * 且表达上要能区分）。
 *
 * - 收藏：服务端 favorites（详情页那颗红心），跨设备、影响入库与筛选；
 * - 喜爱：只在**本机**，记录「刷一刷里点过心的片段」，连**片段起点**一起记，
 *   所以点进去能回到那一秒，而不是从头放整片。
 *
 * 存两份：
 *   `shorts_likes`       —— 旧的逗号串（meta_id 列表），爱心亮不亮看它，别动格式；
 *   `shorts_like_items`  —— 快照数组（本文件），带番号/标题/海报/起点，供列表页直接渲染。
 */
export interface LikedClip {
  id: number;
  number: string;
  title: string;
  poster: string;
  start: number;
  dur: number;
  actor: string;
  actorImg: string;
  /** 点心的时刻（毫秒），列表按它倒序。 */
  at: number;
}

const LIKED_KEY: string = 'shorts_like_items';

/** 读快照（坏数据一律当空表，不让列表页因为一条脏 JSON 整页白掉）。 */
export function readLiked(): LikedClip[] {
  const raw: string = Store.I.prefString(LIKED_KEY, '');
  if (raw.length === 0) {
    return [];
  }
  try {
    const arr = JSON.parse(raw) as LikedClip[];
    if (!Array.isArray(arr)) {
      return [];
    }
    return arr.filter((x: LikedClip) => x !== undefined && x !== null && x.id > 0);
  } catch (err) {
    return [];
  }
}

function writeLiked(list: LikedClip[]): void {
  Store.I.prefSetString(LIKED_KEY, JSON.stringify(list));
}

/** 点心了：写快照（同 id 覆盖，保证「最近点的在最前」）。 */
export function addLiked(c: LikedClip): void {
  const list: LikedClip[] = readLiked().filter((x: LikedClip) => x.id !== c.id);
  list.push(c);
  writeLiked(list);
}

/** 取消喜爱：连快照一起删，列表页下次打开就没了。 */
export function removeLiked(id: number): void {
  writeLiked(readLiked().filter((x: LikedClip) => x.id !== id));
}

/** 列表页用：按点心时间倒序。 */
export function likedSorted(): LikedClip[] {
  const list: LikedClip[] = readLiked();
  list.sort((a: LikedClip, b: LikedClip) => b.at - a.at);
  return list;
}
