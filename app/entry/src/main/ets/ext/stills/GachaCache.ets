import { GachaStill } from './GachaTypes';

/**
 * 抽卡墙的「上一批成功结果」缓存（2026-11-16）。
 *
 * 为什么需要它：用户下拉刷新时，`GachaWall` 可能因为父组件重渲染被重建
 * （ArkUI 的 if 分支一换子树就销毁重建），新实例的 `stills` 是空的 ——
 * 于是先看到空提示，再转圈，再等一次网络。真机表现就是
 * 「下拉 → 转一会 → 图没了，回到空提示」（2026-11-16 用户连续报了两次）。
 *
 * 存一份最近成功的批次后：
 *   - 重建时**立刻**把上一批铺出来，不闪空态；
 *   - 网络失败时也有东西可看；
 *   - 只有换了范围（scope / id / extra 变了）才按新 key 取，自然不会串库。
 *
 * 纯内存、不落盘：App 重启就没了，不占空间也不会有过期数据。
 */
export class GachaCache {
  private static stills: Map<string, GachaStill[]> = new Map<string, GachaStill[]>();
  private static urls: Map<string, string[]> = new Map<string, string[]>();
  private static ratios: Map<string, number[]> = new Map<string, number[]>();
  /** 每个范围最多留几个，避免长时间使用堆几十个列表。 */
  private static readonly MAX_KEYS: number = 6;

  static key(scope: string, scopeId: number, extra: string): string {
    return `${scope}:${scopeId}:${extra}`;
  }

  static put(k: string, items: GachaStill[]): void {
    if (items.length === 0) {
      return;                     // 空结果不覆盖好的批次
    }
    const urls: string[] = [];
    const ratios: number[] = [];
    for (let i = 0; i < items.length; i++) {
      urls.push(items[i].url);
      ratios.push(items[i].ratio);
    }
    GachaCache.stills.set(k, items);
    GachaCache.urls.set(k, urls);
    GachaCache.ratios.set(k, ratios);
    GachaCache.trim();
  }

  /** 取一份拷贝：调用方会往里 push，不能让两处共用同一个数组。 */
  static take(k: string): GachaStill[] {
    const hit: GachaStill[] | undefined = GachaCache.stills.get(k);
    return hit === undefined ? [] : hit.slice();
  }

  static urlsOf(k: string): string[] {
    const hit: string[] | undefined = GachaCache.urls.get(k);
    return hit === undefined ? [] : hit.slice();
  }

  static ratiosOf(k: string): number[] {
    const hit: number[] | undefined = GachaCache.ratios.get(k);
    return hit === undefined ? [] : hit.slice();
  }

  private static trim(): void {
    while (GachaCache.stills.size > GachaCache.MAX_KEYS) {
      const first: string | undefined = GachaCache.stills.keys().next().value;
      if (first === undefined) {
        return;
      }
      GachaCache.stills.delete(first);
      GachaCache.urls.delete(first);
      GachaCache.ratios.delete(first);
    }
  }
}
