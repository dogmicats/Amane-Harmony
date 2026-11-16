/**
 * 「候选池条件」→ 查询参数（2026-11-14，Agent3）。
 *
 * 背景：首页顶部大图早就支持「媒体库 / 观看状态 / 年份 / 标签 / 演员」自由组合，
 * 参数是 `plib/ptag/pactor/pyear_from/pyear_to/pmin_score/pstate`，无条件时退回预设 `pool`。
 * 现在**负一屏（刷一刷）**也要按同一套范围取片 —— 两处 endpoint 不同
 * （`/api/user/home` 与 `/api/user/shorts`），但条件串必须**一字不差**：
 * 服务端的池子缓存 key 就是这串参数，拼法一漂移就永远命不中缓存。
 *
 * 所以拼法只留这一份，`HomeTab.homeUrl()` 与 `ShortsView` 的取数都调它。
 * 偏好键沿用既有的 `hero_pool_spec`（JSON）/ `hero_pool`（预设），不新增第二套条件。
 */
import { Store } from './Store';

export class PoolParams {
  /**
   * 条件串（**不带 `?`**，可直接拼在 `?` 或 `&` 后面）。
   * 有自由条件 → `plib=1,2&ptag=中字&...`；没有 → `pool=all` / `pool=fav` 这类预设。
   *
   * 2026-11-15：抽成 `queryFor(specKey, presetKey)` —— 拼法（实现）只有一份，
   * **存哪套条件由调用方决定**：顶部大图用 `hero_pool_spec`，刷一刷用 `shorts_pool_spec`。
   */
  static queryFor(specKey: string, presetKey: string): string {
    const parts: string[] = [];
    const raw: string = Store.I.prefString(specKey, '');
    if (raw.length > 0) {
      try {
        const o = JSON.parse(raw) as Record<string, Object>;
        const libs = o['libs'];
        if (libs !== undefined && libs !== null && (libs as number[]).length > 0) {
          parts.push(`plib=${(libs as number[]).join(',')}`);
        }
        const tags = o['tags'];
        if (tags !== undefined && tags !== null && (tags as string[]).length > 0) {
          parts.push(`ptag=${encodeURIComponent((tags as string[]).join(','))}`);
        }
        const actor: string = String(o['actor'] === undefined ? '' : o['actor']);
        if (actor.length > 0) {
          parts.push(`pactor=${encodeURIComponent(actor)}`);
        }
        const yf: string = String(o['year_from'] === undefined ? '' : o['year_from']);
        if (yf.length > 0 && yf !== '0') {
          parts.push(`pyear_from=${yf}`);
        }
        const yt: string = String(o['year_to'] === undefined ? '' : o['year_to']);
        if (yt.length > 0 && yt !== '0') {
          parts.push(`pyear_to=${yt}`);
        }
        const ms: string = String(o['min_score'] === undefined ? '' : o['min_score']);
        if (ms.length > 0 && ms !== '0') {
          parts.push(`pmin_score=${ms}`);
        }
        const st: string = String(o['state'] === undefined ? '' : o['state']);
        if (st.length > 0 && st !== 'any') {
          parts.push(`pstate=${st}`);
        }
      } catch (e) {
        console.info(`[amane] ${specKey} 解析失败，退回预设池`);
      }
    }
    if (parts.length === 0) {
      parts.push(`pool=${Store.I.prefString(presetKey, 'all')}`);
    }
    return parts.join('&');
  }

  /** 顶部大图的条件串（首页 `/api/user/home`）。 */
  static query(): string {
    return PoolParams.queryFor('hero_pool_spec', 'hero_pool');
  }

  /**
   * 刷一刷的条件串（`/api/user/shorts`）。**自己一套**（2026-11-15 用户要求拆开）：
   * 实现同 `queryFor`，但读写的是 `shorts_pool_spec` / `shorts_pool` ——
   * 改刷一刷的范围不会再动顶部大图，反之亦然。
   */
  static shortsQuery(): string {
    return PoolParams.queryFor('shorts_pool_spec', 'shorts_pool');
  }
}
