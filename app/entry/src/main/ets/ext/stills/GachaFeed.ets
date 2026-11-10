import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { httpGet, HttpError } from '../../common/Http';
import { Store } from '../../common/Store';
import { DetailParams, ItemDetail } from '../../common/Types';
import { safeDetail } from '../../common/Safe';
import { GachaPage, GachaStill, safeGachaPage } from './GachaTypes';

/**
 * 抽卡模式的数据层：池子 + 游标 + 轮换。
 *
 * 完全照搬演员详情页那套（真机验证过的节奏），抽出来是为了**以后只改一处**：
 *   - 一次抓 count×3 张存本地（服务端上限 36），点「换一批」先在本地池子里往后
 *     挪一格窗口 → 瞬时出图，不转圈；
 *   - 池子用完才真的发一次请求；
 *   - 服务端已经把每张的宽高比一起下发，所以瀑布流首帧就是最终版式。
 *
 * 纯逻辑类，不碰 UI 状态：调用方把返回的数组塞进 @State 即可。
 */

const POOL_MAX: number = 36;
const POOL_FACTOR: number = 3;

export class StillFeed {
  scope: string = 'all';
  scopeId: number = 0;
  /**
   * 追加的查询串（不带前导 &），用来传「没有实体 id 的范围」的筛选条件 ——
   * 共演筛选结果页就是 `female_n=1,2&exclude_director_id=130`，
   * 服务端把它们交给 actors 扩展的 stills_where 钩子，套同一套 WHERE。
   */
  extra: string = '';
  /** 一轮摆几张。 */
  count: number = 10;
  /** 这个范围里有多少部片有剧照；-1 = 还不知道。 */
  candidates: number = -1;
  /** 最近一次失败的人话说明；空串表示没问题。 */
  error: string = '';

  private pool: GachaStill[] = [];
  private cursor: number = 0;

  constructor(scope: string, scopeId: number, count: number, extra: string = '') {
    this.scope = scope;
    this.scopeId = scopeId;
    this.count = count > 0 ? count : 10;
    this.extra = extra;
  }

  /** 换范围 / 换张数时清空，避免拿上一个标签的图凑数。 */
  reset(scope: string, scopeId: number, count: number, extra: string = ''): void {
    this.scope = scope;
    this.scopeId = scopeId;
    this.count = count > 0 ? count : 10;
    this.extra = extra;
    this.pool = [];
    this.cursor = 0;
    this.candidates = -1;
    this.error = '';
  }

  /** 池子里还够再摆一轮吗。 */
  hasNext(): boolean {
    return this.pool.length >= this.cursor + this.count;
  }

  /**
   * 取下一轮。
   * @param refresh true = 用户点了「再抽一次/换一批」，允许复用本地池；
   *                false = 首次进入或换了范围，必须重新拉（否则会拿到同一批）。
   */
  async next(refresh: boolean): Promise<GachaStill[]> {
    if (refresh && this.hasNext()) {
      const out: GachaStill[] = this.pool.slice(this.cursor, this.cursor + this.count);
      this.cursor += this.count;
      return out;
    }
    const got: GachaStill[] = await this.fetch();
    if (got.length === 0) {
      // 拉失败但池子里还有没用完的：退回轮换，别让画面空掉
      if (this.hasNext()) {
        const out: GachaStill[] = this.pool.slice(this.cursor, this.cursor + this.count);
        this.cursor += this.count;
        return out;
      }
      return [];
    }
    this.pool = got;
    this.cursor = this.count;
    return got.slice(0, this.count);
  }

  private async fetch(): Promise<GachaStill[]> {
    const limit: number = Math.min(POOL_MAX, Math.max(this.count * POOL_FACTOR, this.count));
    let tail: string = '';
    if (this.extra.length > 0) {
      tail = this.extra.startsWith('&') ? this.extra : `&${this.extra}`;
    }
    const url: string = `${Store.I.user}/api/user/stills?scope=${this.scope}` +
      `&id=${this.scopeId}&limit=${limit}${tail}`;
    try {
      const text: string = await httpGet(url, Store.I.token);
      const page: GachaPage = safeGachaPage(JSON.parse(text) as GachaPage);
      this.candidates = page.candidates;
      this.error = '';
      return page.items;
    } catch (err) {
      const e = err as HttpError;
      console.error(`[amane] gacha ${this.scope}/${this.scopeId}: ${e.code} ${e.message}`);
      // 404 = 老服务端没这个端点（1.3.11 才有）。把实际连的地址写出来，
      // 一眼能看出是「服务端没升级」还是「App 连错了端口」。
      this.error = e.code === 404
        ? `服务端未开启抽卡（${Store.I.user}，需 1.3.13+）`
        : '抽卡失败，点「换一批」重试';
      return [];
    }
  }
}

/**
 * 点剧照：先预取详情（详情页命中缓存就不用再转圈），带着图片地址跳过去。
 * 转场动效在详情页里做（heroUrl），这里只管把路铺好。
 */
export function openStill(still: GachaStill): void {
  const p: DetailParams = { id: still.id, heroUrl: still.url };
  prefetchDetail(still.id);
  router.pushUrl({ url: 'pages/DetailPage', params: p });
}

async function prefetchDetail(id: number): Promise<void> {
  try {
    const text: string = await httpGet(`${Store.I.user}/api/user/item/${id}`, Store.I.token);
    Store.I.cacheDetail(safeDetail(JSON.parse(text) as ItemDetail));
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] gacha prefetch: ${e.code} ${e.message}`);
  }
}
