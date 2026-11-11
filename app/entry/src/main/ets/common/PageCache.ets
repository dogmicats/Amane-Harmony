import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 页面级数据缓存（用户第 9 条）。
 *
 * 目标：**同一个页面第二次进来不该再转圈**。
 *
 *  - 内存命中 → 同步返回，页面第一帧就有内容；
 *  - 内存没有 → 同步读一个磁盘小文件（几毫秒，只读命中的那一个，不扫目录）；
 *  - 请求回来 → 写内存 + 异步落盘，退出 App 再进来还在；
 *  - 每条带 TTL：过期数据仍然给（`cacheReadStale`），页面先用旧数据渲染、
 *    再后台刷新，这就是 stale-while-revalidate。
 *
 * ★ 用模块级函数而不是 class static ★
 *   ArkTS 的 `arkts-no-standalone-this` 不允许在静态方法里用 this，
 *   写成模块变量 + 导出函数最省事，调用方也短。
 *
 * 只缓存「读接口」的响应体字符串，写操作一律不缓存。
 */
interface CacheMeta {
  at: number;
  ttl: number;
  body: string;
}

const mem: Map<string, CacheMeta> = new Map();
const CAP: number = 80;
let baseDir: string = '';

/** 在 EntryAbility.onCreate 里调一次，之后读写才可用。 */
export function cacheInit(ctx: common.Context): void {
  if (baseDir.length > 0) {
    return;
  }
  baseDir = `${ctx.filesDir}/page-cache`;
  try {
    if (!fs.accessSync(baseDir)) {
      fs.mkdirSync(baseDir, true);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] pagecache dir: ${e.code} ${e.message}`);
  }
}

/** key 太长不适合当文件名：FNV-1a 32 位。 */
function fileName(key: string): string {
  let h: number = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    h = h ^ key.charCodeAt(i);
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0;
  }
  return `c${h.toString(16)}.json`;
}

function filePath(key: string): string {
  return `${baseDir}/${fileName(key)}`;
}

function loadMeta(key: string): CacheMeta | undefined {
  const hit: CacheMeta | undefined = mem.get(key);
  if (hit !== undefined) {
    return hit;
  }
  if (baseDir.length === 0) {
    return undefined;
  }
  try {
    const p: string = filePath(key);
    if (!fs.accessSync(p)) {
      return undefined;
    }
    const text: string = fs.readTextSync(p);
    const obj = JSON.parse(text) as CacheMeta;
    if (obj === null || obj === undefined || obj.body === undefined || obj.body === null) {
      return undefined;
    }
    const meta: CacheMeta = {
      at: Number(obj.at) || 0,
      ttl: Number(obj.ttl) || 0,
      body: String(obj.body)
    };
    mem.set(key, meta);
    return meta;
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] pagecache read: ${e.code} ${e.message}`);
    return undefined;
  }
}

/** 未过期才返回（页面首屏渲染用）。 */
export function cacheRead(key: string): string | undefined {
  const meta: CacheMeta | undefined = loadMeta(key);
  if (meta === undefined) {
    return undefined;
  }
  if (meta.ttl > 0 && Date.now() - meta.at > meta.ttl) {
    return undefined;
  }
  return meta.body;
}

/** 过期也给（网络失败或后台刷新期间兜底）。 */
export function cacheReadStale(key: string): string | undefined {
  const meta: CacheMeta | undefined = loadMeta(key);
  return meta === undefined ? undefined : meta.body;
}

/** 写缓存：ttlMs 默认 10 分钟。 */
export function cachePut(key: string, body: string, ttlMs: number = 600000): void {
  if (baseDir.length === 0 || body.length === 0) {
    return;
  }
  const meta: CacheMeta = { at: Date.now(), ttl: ttlMs, body: body };
  mem.set(key, meta);
  if (mem.size > CAP) {
    const keys: string[] = Array.from(mem.keys());
    for (let i = 0; i < keys.length - CAP; i++) {
      mem.delete(keys[i]);
    }
  }
  const p: string = filePath(key);
  const text: string = JSON.stringify(meta);
  // 落盘放到下一轮事件循环：不占当前这一帧，写失败只是没有跨进程缓存
  setTimeout(() => {
    try {
      const f = fs.openSync(p, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] pagecache write: ${e.code} ${e.message}`);
    }
  }, 0);
}

/** 让某一条失效（打分/收藏之后调）。 */
export function cacheDrop(key: string): void {
  mem.delete(key);
  if (baseDir.length === 0) {
    return;
  }
  try {
    const p: string = filePath(key);
    if (fs.accessSync(p)) {
      fs.unlinkSync(p);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] pagecache drop: ${e.code} ${e.message}`);
  }
}

/** 全部清掉（设置页「清理页面缓存」），返回清掉的文件数。 */
export function cacheClear(): number {
  mem.clear();
  if (baseDir.length === 0) {
    return 0;
  }
  let n: number = 0;
  try {
    const list: string[] = fs.listFileSync(baseDir);
    for (let i = 0; i < list.length; i++) {
      fs.unlinkSync(`${baseDir}/${list[i]}`);
      n++;
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] pagecache clear: ${e.code} ${e.message}`);
  }
  return n;
}

/** 当前磁盘占用（KB），给设置页显示。 */
export function cacheSizeKb(): number {
  if (baseDir.length === 0) {
    return 0;
  }
  let total: number = 0;
  try {
    const list: string[] = fs.listFileSync(baseDir);
    for (let i = 0; i < list.length; i++) {
      try {
        total += fs.statSync(`${baseDir}/${list[i]}`).size;
      } catch (err) {
        continue;
      }
    }
  } catch (err) {
    return 0;
  }
  return Math.round(total / 1024);
}
