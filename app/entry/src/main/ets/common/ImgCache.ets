import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 图片磁盘缓存（2.6.2.1）。
 *
 * 为什么需要：App 里所有海报/剧照/头像都是远程图，而网络层是**完全关掉系统缓存**的
 * （`usingCache: false` + `no-cache`，为了不吃反代的旧 JSON）。于是图片只剩 ArkUI 的
 * 进程内内存缓存 —— **杀掉 App 再进来，几十上百张图全部重新下载**，首页和列表页
 * 看着就是「明明看过，还要再转一次圈」。
 *
 * 做法：
 *  - `img(raw)` 拼出 URL 之后过这里：命中就返回 `file://` 本地路径（同步，几乎零成本）；
 *    未命中返回原 URL，并**排一个后台下载**，下次进来就是本地图。
 *  - 索引 `index.json` 在启动时读一次到内存，之后 `img()` 只查 Map，不做 IO。
 *  - 容量上限（默认 500MB）按「最久没被用」淘汰，索引里有 `at`。
 *
 * 注意：只缓存图片本体，不缓存 JSON（JSON 走 PageCache）。
 */

interface ImgMeta {
  /** 原始 URL（当 key 用，便于淘汰时回写） */
  k: string;
  /** 文件名（不含目录） */
  f: string;
  /** 最近一次被用到的时间（淘汰按它升序） */
  at: number;
  /** 字节数 */
  n: number;
}

interface ImgIndex {
  v: number;
  cap: number;
  items: ImgMeta[];
}

const DEFAULT_CAP: number = 500 * 1024 * 1024;
/** 同时下载几张：太大手机会被自己拖慢，太小首页铺不满。 */
const MAX_PARALLEL: number = 4;

let dir: string = '';
let indexFile: string = '';
let cap: number = DEFAULT_CAP;
let total: number = 0;
const byKey: Map<string, ImgMeta> = new Map();
const pending: Set<string> = new Set();
const queue: string[] = [];
let running: number = 0;
let dirty: boolean = false;
let flushTimer: number = -1;
let inited: boolean = false;
/** 本次运行（进程内）的命中 / 下载计数：给「存储与缓存」页显示，也便于真机验证。 */
let hits: number = 0;
let fetched: number = 0;

/** 在 EntryAbility.onCreate 里调一次。 */
export function imgCacheInit(ctx: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  dir = `${ctx.filesDir}/img-cache`;
  indexFile = `${dir}/index.json`;
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] imgcache dir: ${e.code} ${e.message}`);
    return;
  }
  loadIndex();
}

function loadIndex(): void {
  try {
    if (!fs.accessSync(indexFile)) {
      return;
    }
    const text: string = fs.readTextSync(indexFile);
    const obj = JSON.parse(text) as ImgIndex;
    if (obj === null || obj === undefined || obj.items === undefined || obj.items === null) {
      return;
    }
    if (Number(obj.cap) > 0) {
      cap = Number(obj.cap);
    }
    const items: ImgMeta[] = obj.items;
    let broken: number = 0;
    for (let i = 0; i < items.length; i++) {
      const it: ImgMeta = items[i];
      if (it === null || it === undefined || it.f === undefined || it.f === null) {
        continue;
      }
      // 索引里有、文件没了：说明被系统清过或写了一半 —— 直接丢掉，别留下死路径
      let exists: boolean = false;
      try {
        exists = fs.accessSync(`${dir}/${it.f}`);
      } catch (err) {
        exists = false;
      }
      if (!exists) {
        broken++;
        continue;
      }
      byKey.set(it.k, it);
      total += Number(it.n) || 0;
    }
    if (broken > 0) {
      console.info(`[amane] imgcache: 清理 ${broken} 条失效索引`);
      dirty = true;
      scheduleFlush();
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] imgcache index: ${e.code} ${e.message}`);
  }
}

function scheduleFlush(): void {
  dirty = true;
  if (flushTimer >= 0) {
    return;
  }
  flushTimer = setTimeout(() => {
    flushTimer = -1;
    flushIndex();
  }, 1500);
}

function flushIndex(): void {
  if (!dirty || dir.length === 0) {
    return;
  }
  dirty = false;
  const items: ImgMeta[] = [];
  byKey.forEach((v: ImgMeta) => {
    items.push(v);
  });
  const obj: ImgIndex = { v: 1, cap: cap, items: items };
  try {
    const f = fs.openSync(indexFile, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, JSON.stringify(obj));
    } finally {
      fs.closeSync(f);
    }
  } catch (err) {
    const e = err as BusinessError;
    console.error(`[amane] imgcache flush: ${e.code} ${e.message}`);
  }
}

function fnv(key: string): string {
  let h: number = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    h = h ^ key.charCodeAt(i);
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0;
  }
  return h.toString(16);
}

/** 扩展名只是给自己看的：Image 组件不看后缀，留一个便于用户/排查识别。 */
function extOf(url: string): string {
  const q: number = url.indexOf('?');
  const path: string = q >= 0 ? url.substring(0, q) : url;
  const dot: number = path.lastIndexOf('.');
  if (dot < 0) {
    return '.img';
  }
  const ext: string = path.substring(dot).toLowerCase();
  return ext.length <= 6 ? ext : '.img';
}

function localPathOf(meta: ImgMeta): string {
  return `${dir}/${meta.f}`;
}

/**
 * 给 `Store.img()` 用：命中返回本地路径，未命中返回原 URL 并后台缓存。
 *
 * **必须足够便宜** —— 它会在每个 Image 的 build 里被调用，一帧可能几十上百次。
 * 所以只做 Map 查询 + 一次字符串拼接，绝对不做同步 IO。
 */
export function imgCacheUrl(url: string): string {
  if (url.length === 0 || !url.startsWith('http')) {
    return url;
  }
  const hit: ImgMeta | undefined = byKey.get(url);
  if (hit !== undefined) {
    hit.at = Date.now();
    hits++;
    return `file://${localPathOf(hit)}`;
  }
  prefetch(url);
  return url;
}

function prefetch(url: string): void {
  if (!inited || dir.length === 0 || pending.has(url)) {
    return;
  }
  pending.add(url);
  queue.push(url);
  pump();
}

function pump(): void {
  while (running < MAX_PARALLEL && queue.length > 0) {
    const url: string = queue.shift() as string;
    running++;
    download(url).then(() => {
      running--;
      pending.delete(url);
      pump();
    }).catch(() => {
      running--;
      pending.delete(url);
      pump();
    });
  }
}

async function download(url: string): Promise<void> {
  const req = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 8000,
      readTimeout: 25000,
      usingCache: false,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    if (resp.responseCode !== 200 || !(resp.result instanceof ArrayBuffer)) {
      return;
    }
    const buf = resp.result as ArrayBuffer;
    if (buf.byteLength === 0) {
      return;
    }
    const name: string = `${fnv(url)}${extOf(url)}`;
    const p: string = `${dir}/${name}`;
    const f = fs.openSync(p, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, buf);
    } finally {
      fs.closeSync(f);
    }
    const old: ImgMeta | undefined = byKey.get(url);
    if (old !== undefined) {
      total -= Number(old.n) || 0;
    }
    const meta: ImgMeta = { k: url, f: name, at: Date.now(), n: buf.byteLength };
    byKey.set(url, meta);
    total += buf.byteLength;
    fetched++;
    scheduleFlush();
    evictIfNeeded();
  } catch (err) {
    const e = err as BusinessError;
    console.info(`[amane] imgcache dl: ${e.code} ${e.message}`);
  } finally {
    req.destroy();
  }
}

function evictIfNeeded(): void {
  if (total <= cap) {
    return;
  }
  const items: ImgMeta[] = [];
  byKey.forEach((v: ImgMeta) => {
    items.push(v);
  });
  items.sort((a: ImgMeta, b: ImgMeta) => a.at - b.at);
  // 淘汰到 80%：避免「删一张又满」的抖动
  const target: number = Math.floor(cap * 0.8);
  for (let i = 0; i < items.length && total > target; i++) {
    const it: ImgMeta = items[i];
    try {
      const p: string = localPathOf(it);
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (err) {
      // 删不掉就从索引里移除，反正也读不到
    }
    byKey.delete(it.k);
    total -= Number(it.n) || 0;
  }
  scheduleFlush();
}

/** 图片缓存占用（字节）。 */
export function imgCacheBytes(): number {
  return total;
}

/** 图片缓存张数。 */
export function imgCacheCount(): number {
  return byKey.size;
}

/** 当前上限（字节）。 */
export function imgCacheCap(): number {
  return cap;
}

/** 改上限并立刻按新上限收缩。 */
export function imgCacheSetCap(bytes: number): void {
  cap = bytes > 0 ? bytes : DEFAULT_CAP;
  scheduleFlush();
  evictIfNeeded();
}

/** 本次运行读了多少次本地图（用于判断缓存到底有没有起作用）。 */
export function imgCacheHits(): number {
  return hits;
}

/** 本次运行新下载了多少张。 */
export function imgCacheFetched(): number {
  return fetched;
}

/** 全部清掉（设置页「清图片缓存」）。 */
export function imgCacheClear(): number {
  let n: number = 0;
  byKey.forEach((v: ImgMeta) => {
    try {
      const p: string = localPathOf(v);
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
        n++;
      }
    } catch (err) {
      // 忽略单张失败
    }
  });
  byKey.clear();
  total = 0;
  scheduleFlush();
  return n;
}

/**
 * 预取一组图片（首页/列表首屏铺完之后调）。
 *
 * 传的是**已经拼好的完整 URL**（`Store.imgPlain()` 的结果）—— 这里刻意不 import Store，
 * 免得 Store → ImgCache → Store 绕成循环依赖。
 *
 * 不是必须的：每张图渲染时自己会排下载。但对「一屏 30 张、用户只划了 5 张」的场景，
 * 提前把下一屏排进队列，滚动时才不会一片灰。
 */
export function imgCacheWarm(urls: string[]): void {
  for (let i = 0; i < urls.length; i++) {
    const url: string = urls[i];
    if (url.length > 0 && url.startsWith('http')) {
      prefetch(url);
    }
  }
}
