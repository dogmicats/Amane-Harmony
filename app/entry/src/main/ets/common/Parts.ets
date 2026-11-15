/**
 * 分段（分碟）与版本的区分（2.6.1.14）。
 *
 * 现实：同一部片常被切成 `...-cd1.mp4` / `...-cd2.mp4`（碟片容量所限），
 * 或者 `...-C-1.mp4` / `...-C-2.mp4`。它们在库里就是**同一条目的多个 media_file**，
 * 于是详情页和播放器把它们当成「N 个版本」平铺 —— 用户看到「版本（3）」，
 * 实际是 1 个版本 + 3 段（用户 2026-11-13 报的就是这个）。
 *
 * 判定**保守**：同一目录 + 去掉尾缀后同名 + 至少两段，才算一组分段。
 * 单看「文件名里带数字」不下结论 —— `ABP-123-2.mp4` 可能只是另一部的编号。
 */

/** 尾部分段标记：cd1 / part2 / pt3 / disc1 / -2 / _2。 */
const PART_TAIL: RegExp = /(?:[-_ ]?(?:cd|part|pt|disc)[-_ ]?(\d{1,2})|[-_ ](\d{1,2}))$/i;

/** 文件名（含扩展名）。 */
export function baseNameOf(path: string): string {
  const i: number = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

/** 所在目录：只有同目录的两个文件才可能是「同一版本的两段」。 */
export function dirOf(path: string): string {
  const i: number = path.lastIndexOf('/');
  return i > 0 ? path.substring(0, i) : '';
}

function stemBase(path: string): string {
  const base: string = baseNameOf(path);
  const dot: number = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

/** 分段号；识别不到返回 0。 */
export function partNoOf(path: string): number {
  const m: RegExpMatchArray | null = stemBase(path).match(PART_TAIL);
  if (m === null) {
    return 0;
  }
  const d1: string | undefined = m[1];
  const d2: string | undefined = m[2];
  const digits: string = d1 !== undefined ? d1 : (d2 !== undefined ? d2 : '');
  if (digits.length === 0) {
    return 0;
  }
  const n: number = Number(digits);
  return n > 0 && n < 100 ? n : 0;
}

/** 去掉分段尾缀后的名字（分组键的一半）。 */
export function stemOf(path: string): string {
  return stemBase(path).replace(PART_TAIL, '').toLowerCase();
}

/**
 * 分组键 = 去掉分段尾缀后的文件名（**不含目录**）。
 *
 * 实测（NHDTB-324）：同一部的 cd1 / cd2 分别躺在两个名字略有差异的目录里
 * （`…中出特别编-下` 与 `…中出 特别编-下`，只差一个空格），按目录分组会漏掉。
 * 反过来「不同目录同名」也不会误判 —— 下面还要求段号去重后至少两个。
 */
export function groupKeyOf(path: string): string {
  return stemOf(path);
}

/**
 * 在一批文件里找出哪些分组键属于「分段组」：
 * 至少两个文件、每个都能读出段号、**且段号去重后仍有 ≥2 个**。
 *
 * 最后一条是防「同一段的两个副本」（两个库里各存一份 cd1）：那样去重后只剩 1 个段号，
 * 不是分段，不该显示成「分集 · 2 段」。
 */
export function partGroupKeys(paths: string[]): string[] {
  const keys: string[] = [];
  const counts: Map<string, number> = new Map<string, number>();
  const segs: Map<string, number[]> = new Map<string, number[]>();
  for (let i = 0; i < paths.length; i++) {
    const p: string = paths[i];
    const n: number = partNoOf(p);
    if (n === 0) {
      continue; // 不带段号的文件不参与分段判定
    }
    const k: string = groupKeyOf(p);
    const cv: number | undefined = counts.get(k);
    counts.set(k, (cv === undefined ? 0 : cv) + 1);
    const arr: number[] | undefined = segs.get(k);
    if (arr === undefined) {
      segs.set(k, [n]);
      if (keys.indexOf(k) < 0) {
        keys.push(k);
      }
    } else {
      if (arr.indexOf(n) < 0) {
        arr.push(n);
      }
    }
  }
  const out: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    const arr2: number[] | undefined = segs.get(k);
    const distinct: number = arr2 === undefined ? 0 : arr2.length;
    const cv2: number | undefined = counts.get(k);
    const total: number = cv2 === undefined ? 0 : cv2;
    if (distinct >= 2 && total >= 2) {
      out.push(k);
    }
  }
  return out;
}

/** 是否属于某个分段组。 */
export function inPartGroup(path: string, partKeys: string[]): boolean {
  return partKeys.indexOf(groupKeyOf(path)) >= 0;
}

/** 提示文案：分段组的说明（详情页 / 面板共用，避免两处写不一样）。 */
export function partsHint(count: number): string {
  return `${count} 段 · 同一部片被切开的分段，按顺序看`;
}
