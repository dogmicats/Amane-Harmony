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
   */
  static query(): string {
    const parts: string[] = [];
    const raw: string = Store.I.prefString('hero_pool_spec', '');
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
        console.info('[amane] hero_pool_spec 解析失败，退回预设池');
      }
    }
    if (parts.length === 0) {
      parts.push(`pool=${Store.I.prefString('hero_pool', 'all')}`);
    }
    return parts.join('&');
  }

  /**
   * 负一屏是否跟随同一套条件（设置 → 首页内容 里的开关，偏好 `shorts_pool_follow_hero`）。
   * 默认开：用户在一处设的范围，刷一刷也认这个范围。
   */
  static shortsFollow(): boolean {
    return Store.I.prefString('shorts_pool_follow_hero', '1') !== '0';
  }

  /** 负一屏用的条件串：跟随开关关掉时明确回全库（`pool=all`）。 */
  static shortsQuery(): string {
    return PoolParams.shortsFollow() ? PoolParams.query() : 'pool=all';
  }
}
