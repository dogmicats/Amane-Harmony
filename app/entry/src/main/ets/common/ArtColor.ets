/**
 * 一片一色：从海报里取主色，让每一部片有自己的氛围色。
 *
 * 为什么需要它：全局只有一个强调色（`Theme.ACCENT`）时，**每部片看起来都一样** ——
 * 幽紫主题下，一部暖色封面的片和一部冷色封面的片，头部渐变、播放键光环、
 * 浮尘颜色全是同一根紫。取色之后「这一页属于这部电影」才成立。
 *
 * 三条硬约束：
 * 1. **取不到就用主题色**。网络失败、图片损坏、画面接近黑白（<5% 有效像素）时
 *    一律返回空串，由调用方退回 `Theme.ACCENT`，绝不返回一个脏颜色把界面染灰。
 * 2. **只在暗部上色**。输出固定压到 `l=0.58` 左右的中亮色，永远不会出现
 *    「亮到压不住白字」或「暗到看不见」的两种情况。
 * 3. **跟着光效档位走**。`ui_fx_level = 0`（用户明确关掉光效）时不下载、不取色 ——
 *    取色只为了上色，没有光效就不该多花这一趟流量。
 *
 * 为什么自己算而不调系统「主色提取」：系统 Palette 类的能力在不同 API 版本上
 * 行为不一致（有的返回面积最大色 = 背景黑边），而我们要的是「画面里最有个性的那团颜色」。
 * 降采样到 24×34 之后自己按色相分桶加权，一行像素一把梭，快且可预测。
 */
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGetBytes } from './Http';
import { Store } from './Store';
import { Theme } from './Theme';
import { Personalize } from './Personalize';

/** 本地缓存键（`Store` 的 prefString 那套，存的是一行一条的纯文本）。 */
const PREF_TINT: string = 'ui_art_tint';
/** 缓存上限：一部片一条，超了从最老的开始丢（场景是最近看过的片子）。 */
const CACHE_MAX: number = 400;
/** 降采样尺寸：24×34 已经能表达「这张图是什么色」，再大只是白烧 CPU。 */
const SAMPLE_W: number = 24;
const SAMPLE_H: number = 34;

/** 内存缓存：URL → 主色。进程内命中最快，避免同一个片子反复解析。 */
const mem: Map<string, string> = new Map();
let loaded: boolean = false;

interface TintRow {
  url: string;
  accent: string;
}

/** 一条缓存行的时间戳缺失也没关系：顺序即新老，parse 时保持原序。 */
let order: string[] = [];

function parseRows(raw: string): void {
  if (raw.length === 0) {
    return;
  }
  const lines: string[] = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    const tab: number = line.indexOf('\t');
    if (tab <= 0) {
      continue;
    }
    const url: string = line.substring(0, tab);
    const accent: string = line.substring(tab + 1).trim();
    if (url.length === 0 || accent.length !== 7) {
      continue;
    }
    mem.set(url, accent);
    order.push(url);
  }
}

function ensureLoaded(): void {
  if (loaded) {
    return;
  }
  loaded = true;
  try {
    parseRows(Store.I.prefString(PREF_TINT, ''));
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] tint load: ${e.code}`);
  }
}

function persist(): void {
  try {
    const rows: TintRow[] = [];
    let start: number = order.length - CACHE_MAX;
    if (start < 0) {
      start = 0;
    }
    for (let i = start; i < order.length; i++) {
      const url: string = order[i];
      const accent: string | undefined = mem.get(url);
      if (accent === undefined) {
        continue;
      }
      const row: TintRow = { url: url, accent: accent };
      rows.push(row);
    }
    const lines: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      lines.push(`${rows[i].url}\t${rows[i].accent}`);
    }
    Store.I.prefSetString(PREF_TINT, lines.join('\n'));
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] tint save: ${e.code}`);
  }
}

function remember(url: string, accent: string): void {
  if (url.length === 0 || accent.length === 0) {
    return;
  }
  if (!mem.has(url)) {
    order.push(url);
    if (order.length > CACHE_MAX + 80) {
      const drop: string[] = order.splice(0, order.length - CACHE_MAX);
      for (let i = 0; i < drop.length; i++) {
        mem.delete(drop[i]);
      }
    }
  }
  mem.set(url, accent);
  persist();
}

/** h: 0–360, s/l: 0–1。分开写是因为 ArkTS 不支持返回元组。 */
class Hsl {
  h: number = 0;
  s: number = 0;
  l: number = 0;
}

function toHsl(r: number, g: number, b: number): Hsl {
  const rf: number = r / 255;
  const gf: number = g / 255;
  const bf: number = b / 255;
  const max: number = Math.max(rf, Math.max(gf, bf));
  const min: number = Math.min(rf, Math.min(gf, bf));
  const out: Hsl = new Hsl();
  out.l = (max + min) / 2;
  const d: number = max - min;
  if (d < 0.0001) {
    out.h = 0;
    out.s = 0;
    return out;
  }
  out.s = out.l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number = 0;
  if (max === rf) {
    h = (gf - bf) / d + (gf < bf ? 6 : 0);
  } else if (max === gf) {
    h = (bf - rf) / d + 2;
  } else {
    h = (rf - gf) / d + 4;
  }
  out.h = h * 60;
  return out;
}

/** 固定亮度的中亮色：保证压得住白字、也看得见，不跟原图一起变亮变暗。 */
function toHex(h: number, s: number, l: number): string {
  const hh: number = ((h % 360) + 360) % 360;
  const c: number = (1 - Math.abs(2 * l - 1)) * s;
  const x: number = c * (1 - Math.abs((hh / 60) % 2 - 1));
  const m: number = l - c / 2;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (hh < 60) {
    r = c;
    g = x;
  } else if (hh < 120) {
    r = x;
    g = c;
  } else if (hh < 180) {
    g = c;
    b = x;
  } else if (hh < 240) {
    g = x;
    b = c;
  } else if (hh < 300) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  const ri: number = Math.round((r + m) * 255);
  const gi: number = Math.round((g + m) * 255);
  const bi: number = Math.round((b + m) * 255);
  const hex: string = `#${ri.toString(16).padStart(2, '0')}${gi.toString(16).padStart(2, '0')}${bi.toString(16).padStart(2, '0')}`;
  return hex.toUpperCase();
}

/**
 * 从降采样后的像素里挑「最有个性的色相」。
 *
 * 做法：按 12 个色相桶累加 `饱和度 × 亮度`，黑边/白字/灰底自动权重极低；
 * 取权重最大的桶，桶内像素做平均，再按桶内平均饱和度平滑一次。
 * 返回空串表示「这张图没有可取的颜色」（有效像素不足 5%）。
 */
function pickAccent(px: Uint8Array, w: number, h: number): string {
  const buckets: number[] = [];
  const rs: number[] = [];
  const gs: number[] = [];
  const bs: number[] = [];
  const counts: number[] = [];
  for (let i = 0; i < 36; i++) {
    buckets.push(0);
    rs.push(0);
    gs.push(0);
    bs.push(0);
    counts.push(0);
  }
  let valid: number = 0;
  let total: number = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const off: number = (y * w + x) * 4;
      if (off + 3 >= px.length) {
        continue;
      }
      total++;
      const a: number = px[off + 3];
      if (a < 200) {
        continue;
      }
      const r: number = px[off];
      const g: number = px[off + 1];
      const b: number = px[off + 2];
      const hsl: Hsl = toHsl(r, g, b);
      // 近黑（<0.10）、近白（>0.92）、灰（饱和度 <0.18）都算不上「个性色」
      if (hsl.l < 0.10 || hsl.l > 0.92 || hsl.s < 0.18) {
        continue;
      }
      valid++;
      const idx: number = Math.floor(hsl.h / 10) % 36;
      // 权重：饱和度说话，亮度做微调（太暗的色块贡献低一点）
      const weight: number = hsl.s * (0.55 + hsl.l * 0.45);
      buckets[idx] = buckets[idx] + weight;
      rs[idx] = rs[idx] + r * weight;
      gs[idx] = gs[idx] + g * weight;
      bs[idx] = bs[idx] + b * weight;
      counts[idx] = counts[idx] + 1;
    }
  }
  if (total === 0 || valid * 20 < total) {
    return '';
  }
  let best: number = -1;
  let bestW: number = 0;
  for (let i = 0; i < buckets.length; i++) {
    if (buckets[i] > bestW) {
      bestW = buckets[i];
      best = i;
    }
  }
  if (best < 0 || counts[best] === 0) {
    return '';
  }
  const r: number = rs[best] / bestW;
  const g: number = gs[best] / bestW;
  const b: number = bs[best] / bestW;
  const hsl: Hsl = toHsl(Math.round(r), Math.round(g), Math.round(b));
  // 饱和度收在 0.42–0.78：太低显脏（像旧的 UI 灰），太高在深底上刺眼
  let s: number = hsl.s;
  if (s < 0.42) {
    s = 0.42;
  } else if (s > 0.78) {
    s = 0.78;
  }
  return toHex(hsl.h, s, 0.58);
}

export class ArtColor {
  /** 同步读缓存：首帧就能用上「上次算出来的色」，不用等网络。 */
  static cached(url: string): string {
    ensureLoaded();
    const hit: string | undefined = mem.get(url);
    return hit === undefined ? '' : hit;
  }

  /**
   * 取一部片子的主色（`#RRGGBB`）。失败一律返回空串 —— 调用方退回主题色。
   *
   * `url` 传 `Store.I.img(...)` 拼好的完整地址，`token` 传 `Store.I.token`。
   */
  static async of(url: string, token: string): Promise<string> {
    if (url.length === 0) {
      return '';
    }
    ensureLoaded();
    const hit: string | undefined = mem.get(url);
    if (hit !== undefined) {
      return hit;
    }
    if (Personalize.fx() <= 0) {
      return '';
    }
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    try {
      const bytes: ArrayBuffer = await httpGetBytes(url, token);
      src = image.createImageSource(bytes);
      const opts: image.DecodingOptions = {
        desiredSize: { width: SAMPLE_W, height: SAMPLE_H },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opts);
      const info: image.ImageInfo = pm.getImageInfoSync();
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w <= 0 || h <= 0) {
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
      pm.readPixelsToBufferSync(buf);
      const accent: string = pickAccent(new Uint8Array(buf), w, h);
      if (accent.length > 0) {
        remember(url, accent);
      }
      return accent;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] tint: ${e.code} ${e.message}`);
      return '';
    } finally {
      try {
        if (pm !== undefined) {
          await pm.release();
        }
        if (src !== undefined) {
          await src.release();
        }
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] tint release: ${e.code}`);
      }
    }
  }

  /** 同族的第二色（渐变终点用）：色相转 14°、更亮一档。 */
  static second(accent: string): string {
    if (accent.length !== 7) {
      return Theme.ACCENT2;
    }
    const r: number = parseInt(accent.substring(1, 3), 16);
    const g: number = parseInt(accent.substring(3, 5), 16);
    const b: number = parseInt(accent.substring(5, 7), 16);
    if (r !== r || g !== g || b !== b) {
      return Theme.ACCENT2;
    }
    const hsl: Hsl = toHsl(r, g, b);
    return toHex(hsl.h + 14, Math.min(0.82, hsl.s + 0.06), 0.70);
  }

  /** 清空缓存（设置页「清理缓存」和换主题时不用调，换片子 URL 本来就会变）。 */
  static clear(): void {
    mem.clear();
    order = [];
    loaded = true;
    try {
      Store.I.prefSetString(PREF_TINT, '');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] tint clear: ${e.code}`);
    }
  }
}
