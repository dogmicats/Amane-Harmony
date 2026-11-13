import { request } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { connection } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import { httpGet } from './Http';
import { Store } from './Store';

/** 一条离线缓存记录（存成一段 JSON 放进偏好里，别为它单开一个表）。 */
export interface OfflineTask {
  mid: number;
  key: string;
  source: string;
  number: string;
  name: string;
  /** 沙箱里的绝对路径；拿到它才算「可离线播放」。 */
  path: string;
  total: number;
  done: number;
  /** waiting（排队中）/ run / pause / done / fail */
  status: string;
  /** 系统下载任务 id（string，空串 = 没有在跑的任务）。 */
  taskId: string;
  updated: number;
  /** 入队序号，小的先下（2.5.7 队列用）。 */
  order: number;
  /** 最后一次播放时间，0 = 从没播过。「按最久没看清理」按它排序（2.5.7）。 */
  lastOpen: number;
}

const PREF_KEY: string = 'offline_tasks';
/** 字幕 id → 本地 VTT 路径（`{subId: path}`）。 */
const SUB_KEY: string = 'offline_subs';
/** 仅 WiFi 下载开关：'1' 开（默认）/ '0' 关。 */
const PREF_WIFI_ONLY: string = 'offline_wifi_only';
/** 缓存上限，单位 GB；'0' = 不限。默认 8。 */
const PREF_MAX_GB: string = 'offline_max_gb';
/** 上次弹「快满了」时的占用字节数，用来避免每次刷新都弹。 */
const PREF_WARN_AT: string = 'offline_warn_at';

/** 同时最多几个在跑（2.5.7 队列）。 */
const MAX_RUN: number = 2;
/** 一次最多能在队列里排几部，防止误点把手机塞满。 */
const MAX_BATCH: number = 20;

/** `enqueue()` 返回这个 = 当前是移动网络，调用方需要弹「继续 / 等 WiFi」。 */
export const NEED_WIFI: string = '__need_wifi__';

/**
 * 离线缓存（2.5.6 起，2.5.7 补队列 / 仅 WiFi / 空间上限 / 完成提示）。
 *
 * 用系统下载代理（`request.agent`）而不是自己 `fileIo` 分块：断点续传、后台下载、
 * 网络切换都由系统管，客户端只保留「谁、哪一版、存在哪、到哪了」。
 *
 * 存哪儿：应用沙箱 `filesDir/offline/`。删 App 一起没，符合预期。
 * 播放时把这个绝对路径交给 mpv（`file://` + 路径）即可，不再经过服务端。
 *
 * 队列：`enqueue()` 只负责排队（`waiting`），`pump()` 按 order 出队，同时在跑 ≤ MAX_RUN。
 * **不要绕过 enqueue 直连系统下载**，否则并发失控。
 */
export class Downloader {
  private static ctx: common.UIAbilityContext | undefined = undefined;
  private static tasks: OfflineTask[] = [];
  private static loaded: boolean = false;
  private static watchers: Array<() => void> = [];
  /** 入队序号自增器（取已有最大值 + 1）。 */
  private static seq: number = 1;
  /** 防止 pump 重入（它里面有 await）。 */
  private static pumping: boolean = false;
  /** 上次写偏好的时间，进度事件很密，落盘要节流。 */
  private static lastPersist: number = 0;
  /** 网络：1 = WiFi/以太网，0 = 移动网络，-1 = 还没问过（默认按允许处理）。 */
  private static netState: number = -1;
  /**
   * 内存里的系统任务句柄。`request.agent.show()` 只回只读的 TaskInfo（不能 pause），
   * 要暂停必须拿着 `create` 返回的那个 Task —— 所以按 `mid_key` 存一份。
   * 进程重启后这里是空的：那时只能改状态，下次出队用 overwrite 重下。
   */
  private static live: Map<string, request.agent.Task> = new Map();

  /** 页面 aboutToAppear 里调一次；重复调是安全的。 */
  static init(ctx: common.UIAbilityContext): void {
    Downloader.ctx = ctx;
    if (!Downloader.loaded) {
      Downloader.load();
    }
    Downloader.reconcile();
  }

  static dir(): string {
    if (Downloader.ctx === undefined) {
      return '';
    }
    return `${Downloader.ctx.filesDir}/offline`;
  }

  private static ensureDir(): boolean {
    const d = Downloader.dir();
    if (d.length === 0) {
      return false;
    }
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d, true);
      }
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline mkdir: ${e.code} ${e.message}`);
      return false;
    }
  }

  private static nextOrder(): number {
    let max: number = 0;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const o = Downloader.tasks[i].order;
      if (o > max) {
        max = o;
      }
    }
    Downloader.seq = max + 1;
    return Downloader.seq;
  }

  private static load(): void {
    Downloader.loaded = true;
    const raw: string = Store.I.prefString(PREF_KEY, '');
    if (raw.length === 0) {
      Downloader.tasks = [];
      return;
    }
    try {
      const parsed = JSON.parse(raw) as OfflineTask[];
      Downloader.tasks = Array.isArray(parsed) ? parsed : [];
    } catch (err) {
      Downloader.tasks = [];
    }
    // 老记录补两个 2.5.7 的字段（JSON 里没有就是 undefined，用大小比较兜住）
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t = Downloader.tasks[i];
      if (!(t.order > 0)) {
        t.order = i + 1;
      }
      if (!(t.lastOpen >= 0)) {
        t.lastOpen = 0;
      }
      // 进程被杀时正在跑的，标回 pause，避免列表一直转圈（对账时再按文件判定）
      if (t.status === 'run') {
        t.status = 'pause';
        t.taskId = '';
      }
      if (t.status === 'waiting' && t.taskId.length > 0) {
        t.taskId = '';
      }
    }
    Downloader.nextOrder();
  }

  /**
   * 冷启动对账（2.5.7）：系统下载在后台跑完了、但我们的状态没来得及更新 ——
   * 这种情况很常见（后台下完 → 用户第二天才打开 App）。
   * 判据只看文件：**大小够 = done，文件在但不够 = 继续排队，文件没了 = 按状态降级**。
   */
  static reconcile(): void {
    if (!Downloader.loaded) {
      Downloader.load();
    }
    if (Downloader.dir().length === 0) {
      return;
    }
    let changed: boolean = false;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t = Downloader.tasks[i];
      if (t.path.length === 0 || t.status === 'run') {
        continue;
      }
      let size: number = -1;
      try {
        size = fs.accessSync(t.path) ? fs.statSync(t.path).size : -1;
      } catch (err) {
        size = -1;
      }
      if (size < 0) {
        // 文件被系统清了或者根本没落盘
        if (t.status === 'done') {
          t.status = 'fail';
          t.done = 0;
          changed = true;
        }
        continue;
      }
      const need: number = t.total > 0 ? t.total : size;
      if (size >= need) {
        if (t.status !== 'done' || t.done !== size) {
          t.status = 'done';
          t.done = size;
          t.total = size;
          t.taskId = '';
          changed = true;
        }
      } else if (t.status === 'done') {
        // 记着下完了，但文件不完整（被截断/被清了一半）→ 重下一遍
        t.status = 'waiting';
        changed = true;
      }
    }
    if (changed) {
      Downloader.persist();
    }
  }

  /** 只通知页面刷新，不写盘（进度事件走这条，省 IO）。 */
  private static notify(): void {
    for (let i = 0; i < Downloader.watchers.length; i++) {
      Downloader.watchers[i]();
    }
  }

  private static persist(): void {
    Downloader.lastPersist = Date.now();
    try {
      Store.I.prefSetString(PREF_KEY, JSON.stringify(Downloader.tasks));
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline persist: ${e.code} ${e.message}`);
    }
    Downloader.notify();
  }

  /** 页面订阅变化（列表要跟着进度动）。返回取消订阅的函数。 */
  static watch(cb: () => void): () => void {
    Downloader.watchers.push(cb);
    return () => {
      const next: Array<() => void> = [];
      for (let i = 0; i < Downloader.watchers.length; i++) {
        if (Downloader.watchers[i] !== cb) {
          next.push(Downloader.watchers[i]);
        }
      }
      Downloader.watchers = next;
    };
  }

  static list(): OfflineTask[] {
    if (!Downloader.loaded) {
      Downloader.load();
    }
    const out: OfflineTask[] = [];
    for (let i = 0; i < Downloader.tasks.length; i++) {
      out.push(Downloader.tasks[i]);
    }
    return out;
  }

  static find(mid: number, key: string): OfflineTask | undefined {
    if (!Downloader.loaded) {
      Downloader.load();
    }
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t = Downloader.tasks[i];
      if (t.mid === mid && t.key === key) {
        return t;
      }
    }
    return undefined;
  }

  static runningCount(): number {
    let n: number = 0;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].status === 'run') {
        n++;
      }
    }
    return n;
  }

  static waitingCount(): number {
    let n: number = 0;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].status === 'waiting') {
        n++;
      }
    }
    return n;
  }

  /** 在排队里排第几位（1 起）；不在排队返回 0。 */
  static waitingPos(mid: number, key: string): number {
    const waits: OfflineTask[] = Downloader.waitingSorted();
    for (let i = 0; i < waits.length; i++) {
      if (waits[i].mid === mid && waits[i].key === key) {
        return i + 1;
      }
    }
    return 0;
  }

  private static waitingSorted(): OfflineTask[] {
    const out: OfflineTask[] = [];
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].status === 'waiting') {
        out.push(Downloader.tasks[i]);
      }
    }
    out.sort((a: OfflineTask, b: OfflineTask) => a.order - b.order);
    return out;
  }

  /** 已经下完、文件还在的本地路径；否则空串。播放前问它。 */
  static localPathOf(mid: number, key: string): string {
    const t = Downloader.find(mid, key);
    if (t === undefined || t.status !== 'done' || t.path.length === 0) {
      return '';
    }
    try {
      if (fs.accessSync(t.path)) {
        return t.path;
      }
    } catch (err) {
      // 文件被系统清了：把记录标回 fail，让它能重下
    }
    t.status = 'fail';
    t.done = 0;
    Downloader.persist();
    return '';
  }

  /** 播放本地文件时记一笔「什么时候看的」，清理策略要用（2.5.7）。 */
  static markOpened(mid: number, key: string): void {
    const t = Downloader.find(mid, key);
    if (t === undefined) {
      return;
    }
    t.lastOpen = Date.now();
    Downloader.persist();
  }

  /**
   * 实际占用字节。
   *
   * 2.5.7 修正：原来只累加 `done` 状态的 `total`，于是「下到 2.5G 但还没下完」时
   * 界面显示「已用 —」。半成品文件是真的占了盘，必须算进去 —— 否则空间上限与预警
   * 全是空的，形同没做（模拟器实测：盘上 2.5G、界面 0%）。
   */
  static totalBytes(): number {
    let sum: number = 0;
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const t = Downloader.tasks[i];
      sum += t.status === 'done' ? Math.max(t.total, t.done) : t.done;
    }
    return sum;
  }

  // ---------- 设置（2.5.7）：仅 WiFi / 上限 ----------

  static wifiOnly(): boolean {
    return Store.I.prefString(PREF_WIFI_ONLY, '1') === '1';
  }

  static setWifiOnly(on: boolean): void {
    Store.I.prefSetString(PREF_WIFI_ONLY, on ? '1' : '0');
    Downloader.notify();
    if (on) {
      Downloader.pump();
    }
  }

  /** 上限（GB）；0 = 不限。 */
  static maxGb(): number {
    const raw: string = Store.I.prefString(PREF_MAX_GB, '8');
    const v: number = Number(raw);
    if (!(v >= 0)) {
      return 8;
    }
    return v;
  }

  static maxBytes(): number {
    const gb: number = Downloader.maxGb();
    return gb <= 0 ? 0 : gb * 1073741824;
  }

  static setMaxGb(gb: number): void {
    Store.I.prefSetString(PREF_MAX_GB, `${gb}`);
    Downloader.notify();
  }

  /** 占用比例 0–1；不限上限时返回 0。 */
  static usageRatio(): number {
    const cap: number = Downloader.maxBytes();
    if (cap <= 0) {
      return 0;
    }
    const r: number = Downloader.totalBytes() / cap;
    return r > 1 ? 1 : r;
  }

  static overSoftLimit(): boolean {
    return Downloader.usageRatio() >= 0.9;
  }

  static fullBlocked(): boolean {
    const cap: number = Downloader.maxBytes();
    return cap > 0 && Downloader.totalBytes() >= cap;
  }

  /**
   * 「快满了」只提醒一次（同一占用水位不重复弹）：占用再涨 5% 以上才允许再弹。
   * 由页面在进入/刷新时调，返回 true = 这次该弹了。
   */
  static takeWarnSlot(): boolean {
    if (!Downloader.overSoftLimit()) {
      return false;
    }
    const used: number = Downloader.totalBytes();
    const last: number = Number(Store.I.prefString(PREF_WARN_AT, '0'));
    const step: number = Math.floor(Downloader.maxBytes() * 0.05);
    if (last > 0 && used - last < step) {
      return false;
    }
    Store.I.prefSetString(PREF_WARN_AT, `${used}`);
    return true;
  }

  /** 清到 80% 以下要删几部、腾多少字节（先算再问，不直接删）。 */
  static purgePlan(): OfflineTask[] {
    const cap: number = Downloader.maxBytes();
    if (cap <= 0) {
      return [];
    }
    const target: number = Math.floor(cap * 0.8);
    const done: OfflineTask[] = [];
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].status === 'done') {
        done.push(Downloader.tasks[i]);
      }
    }
    // 最久没看的先删；从没播过的（lastOpen = 0）排最前
    done.sort((a: OfflineTask, b: OfflineTask) => a.lastOpen - b.lastOpen);
    const plan: OfflineTask[] = [];
    let cur: number = Downloader.totalBytes();
    for (let i = 0; i < done.length; i++) {
      if (cur <= target) {
        break;
      }
      plan.push(done[i]);
      cur -= done[i].total;
    }
    return plan;
  }

  /** 按上次的计划真删。返回删掉的部数。 */
  static purgeOldest(): number {
    const plan: OfflineTask[] = Downloader.purgePlan();
    for (let i = 0; i < plan.length; i++) {
      Downloader.remove(plan[i].mid, plan[i].key);
    }
    return plan.length;
  }

  // ---------- 网络 ----------

  /** 问一次当前是不是 WiFi/以太网，顺便更新缓存状态。异常时按「允许」处理。 */
  static async refreshNet(): Promise<boolean> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      if (net === undefined || net === null || net.netId === 0) {
        Downloader.netState = 0;
        return false;
      }
      const cap: connection.NetCapabilities = await connection.getNetCapabilities(net);
      const types = cap.bearerTypes;
      let wifi: boolean = false;
      for (let i = 0; i < types.length; i++) {
        const b = types[i];
        if (b === connection.NetBearType.BEARER_WIFI || b === connection.NetBearType.BEARER_ETHERNET) {
          wifi = true;
        }
      }
      Downloader.netState = wifi ? 1 : 0;
      return wifi;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline net: ${e.code} ${e.message}`);
      // 问不到就别拦着用户下载
      Downloader.netState = 1;
      return true;
    }
  }

  static netKnown(): number {
    return Downloader.netState;
  }

  // ---------- 队列 ----------

  /**
   * 排进队列（2.5.7）。**这是唯一入口**。
   *
   * 返回：'' 正常入队；`NEED_WIFI` 现在是移动网络且开了「仅 WiFi」——
   * 调用方弹「继续下载 / 等 WiFi」，用户选继续时再调本方法并传 `force = true`。
   */
  static async enqueue(mid: number, key: string, source: string, number: string,
    name: string, force: boolean = false): Promise<string> {
    if (Downloader.ctx === undefined) {
      return '还没准备好（页面没初始化）';
    }
    if (!Downloader.ensureDir()) {
      return '建缓存目录失败';
    }
    const old = Downloader.find(mid, key);
    if (old !== undefined && old.status === 'done') {
      return 'done';
    }
    if (old !== undefined && (old.status === 'run' || old.status === 'waiting')) {
      return 'queued';
    }
    if (Downloader.runningCount() + Downloader.waitingCount() >= MAX_BATCH) {
      return `排队已满（最多 ${MAX_BATCH} 部），先等前面的下完`;
    }
    if (!force && Downloader.wifiOnly()) {
      const wifi: boolean = await Downloader.refreshNet();
      if (!wifi) {
        return NEED_WIFI;
      }
    }
    if (Downloader.fullBlocked() && !force) {
      return '缓存空间已到上限，先去「离线缓存」清一点';
    }
    const task: OfflineTask = {
      mid: mid, key: key, source: source, number: number, name: name,
      path: '', total: 0, done: 0, status: 'waiting', taskId: '',
      updated: Date.now(), order: Downloader.nextOrder(),
      lastOpen: old === undefined ? 0 : old.lastOpen
    };
    if (old !== undefined) {
      task.total = old.total;
      task.done = old.done;
    }
    Downloader.upsert(task);
    await Downloader.pump();
    return '';
  }

  /** 按 order 出队，同时最多 MAX_RUN 个在跑。切网/限流/空间满时只停止出队，不打断在跑的。 */
  static async pump(): Promise<void> {
    if (Downloader.pumping) {
      return;
    }
    Downloader.pumping = true;
    try {
      let running: number = Downloader.runningCount();
      const waits: OfflineTask[] = Downloader.waitingSorted();
      if (waits.length === 0 || running >= MAX_RUN) {
        return;
      }
      if (Downloader.wifiOnly()) {
        const wifi: boolean = await Downloader.refreshNet();
        if (!wifi) {
          return;
        }
      }
      if (Downloader.fullBlocked()) {
        return;
      }
      for (let i = 0; i < waits.length && running < MAX_RUN; i++) {
        await Downloader.runNow(waits[i]);
        running++;
      }
    } finally {
      Downloader.pumping = false;
    }
  }

  /** 真正交给系统下载代理。只该由 `pump()` 调。 */
  private static async runNow(t: OfflineTask): Promise<void> {
    const ctx = Downloader.ctx;
    if (ctx === undefined) {
      return;
    }
    const mid: number = t.mid;
    const key: string = t.key;
    const safe: string = `${t.number.length > 0 ? t.number : mid}_${key}`.replace(/[^\w.-]/g, '_');
    const savePath: string = `${Downloader.dir()}/${safe}.mp4`;
    const url: string = `${Store.I.user}/api/user/play/${encodeURIComponent(t.source)}/${mid}` +
      `?key=${encodeURIComponent(key)}&token=${encodeURIComponent(Store.I.token)}`;

    t.status = 'run';
    t.path = '';
    t.updated = Date.now();
    Downloader.persist();

    try {
      const config: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: url,
        saveas: savePath,
        overwrite: true,
        network: request.agent.Network.ANY,
        gauge: true,
        mode: request.agent.Mode.BACKGROUND
      };
      const task: request.agent.Task = await request.agent.create(ctx, config);
      Downloader.live.set(`${mid}_${key}`, task);
      const cur = Downloader.find(mid, key);
      if (cur !== undefined) {
        cur.taskId = `${task.tid}`;
        Downloader.persist();
      }

      task.on('progress', (p: request.agent.Progress) => {
        const now = Downloader.find(mid, key);
        if (now === undefined) {
          return;
        }
        now.done = p.processed;
        now.total = p.sizes[0] === undefined ? now.total : p.sizes[0];
        now.status = 'run';
        now.updated = Date.now();
        // 进度事件很密（几百毫秒一次），页面要动但不必每次都写盘
        if (Date.now() - Downloader.lastPersist >= 1200) {
          Downloader.persist();
        } else {
          Downloader.notify();
        }
      });

      task.on('completed', () => {
        const now = Downloader.find(mid, key);
        if (now === undefined) {
          return;
        }
        now.status = 'done';
        now.path = savePath;
        now.done = now.total;
        now.taskId = '';
        now.updated = Date.now();
        Downloader.persist();
        Downloader.notifyDone(now);
        // 字幕跟着视频一起落地（失败不影响视频）
        Downloader.cacheSubtitles(mid, safe);
        Downloader.pump();
      });

      task.on('failed', () => {
        const now = Downloader.find(mid, key);
        if (now === undefined) {
          return;
        }
        now.status = 'fail';
        now.taskId = '';
        now.updated = Date.now();
        Downloader.persist();
        Downloader.pump();
      });

      await task.start();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline start: ${e.code} ${e.message}`);
      const now = Downloader.find(mid, key);
      if (now !== undefined) {
        now.status = 'fail';
        now.taskId = '';
        Downloader.persist();
      }
    }
  }

  /** 下完给一句提示（应用内 toast，不申请通知权限）。 */
  private static notifyDone(t: OfflineTask): void {
    const label: string = t.number.length > 0 ? t.number : t.name;
    const msg: string = label.length > 0
      ? `${label} 已缓存，断网也能看`
      : '已缓存，断网也能看';
    try {
      promptAction.showToast({ message: msg, duration: 2500 });
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline toast: ${e.code} ${e.message}`);
    }
  }

  /**
   * 把这部片的字幕（转好的 VTT）也存到本地（2.5.6）。
   *
   * 只处理服务端已经缓存过的（`subtitles.cached`）；同目录外挂字幕要先 loadLocal 才有 id，
   * 那是打开播放页才会发生的事，下载时不必强求。**失败一律不影响视频下载本身。**
   */
  private static async cacheSubtitles(mid: number, tag: string): Promise<void> {
    if (Downloader.ctx === undefined || !Downloader.ensureDir()) {
      return;
    }
    try {
      const q: string = `token=${encodeURIComponent(Store.I.token)}`;
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/subtitles?item_id=${mid}&${q}`, Store.I.token);
      const obj = JSON.parse(raw) as Record<string, Object>;
      const cached = obj.cached as Record<string, Object>[] | undefined;
      if (cached === undefined || cached === null || cached.length === 0) {
        return;
      }
      const map: Record<string, string> = {};
      const old: string = Store.I.prefString(SUB_KEY, '');
      if (old.length > 0) {
        try {
          const parsed = JSON.parse(old) as Record<string, string>;
          if (parsed !== null && parsed !== undefined) {
            Object.keys(parsed).forEach((k: string) => {
              map[k] = parsed[k];
            });
          }
        } catch (err) {
          // 老数据坏了就丢掉，下面重建
        }
      }
      for (let i = 0; i < cached.length; i++) {
        const sid: string = `${cached[i].id}`;
        if (sid.length === 0 || sid === 'undefined') {
          continue;
        }
        const known = map[sid];
        if (known !== undefined && known.length > 0) {
          continue;
        }
        const vtt: string = await httpGet(
          `${Store.I.user}/api/user/subtitle/${sid}?item_id=${mid}&${q}&format=vtt`,
          Store.I.token);
        if (vtt.length === 0) {
          continue;
        }
        const path: string = `${Downloader.dir()}/${tag}_sub_${sid}.vtt`;
        const file = fs.openSync(path,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, vtt);
        fs.closeSync(file);
        map[sid] = path;
      }
      Store.I.prefSetString(SUB_KEY, JSON.stringify(map));
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] offline subtitles: ${e.code} ${e.message}`);
    }
  }

  private static upsert(task: OfflineTask): void {
    for (let i = 0; i < Downloader.tasks.length; i++) {
      if (Downloader.tasks[i].mid === task.mid && Downloader.tasks[i].key === task.key) {
        Downloader.tasks[i] = task;
        Downloader.persist();
        return;
      }
    }
    Downloader.tasks.push(task);
    Downloader.persist();
  }

  /** 暂停：保留已下好的部分（下次出队会从断点续）。 */
  static async pause(mid: number, key: string): Promise<void> {
    const t = Downloader.find(mid, key);
    if (t === undefined) {
      return;
    }
    if (t.status === 'waiting') {
      // 还在排队：直接从队列摘掉，不占位
      t.status = 'pause';
      Downloader.persist();
      return;
    }
    const handle = `${mid}_${key}`;
    const task: request.agent.Task | undefined = Downloader.live.get(handle);
    if (task !== undefined) {
      try {
        await task.pause();
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] offline pause: ${e.code} ${e.message}`);
      }
      Downloader.live.delete(handle);
    } else {
      // 进程重启过：系统任务已经脱离我们的句柄，这里只能把状态改掉，
      // 下次「继续」会重新出队（overwrite 覆盖，不会两份）。
      console.info('[amane] offline pause: 无内存句柄，仅改状态');
    }
    t.status = 'pause';
    t.taskId = '';
    Downloader.persist();
    Downloader.pump();
  }

  /** 继续：重新排进队列（保持原来的先后位置）。 */
  static async resume(mid: number, key: string): Promise<string> {
    const t = Downloader.find(mid, key);
    if (t === undefined) {
      return '没有这条记录';
    }
    if (t.status === 'run' || t.status === 'waiting') {
      return '';
    }
    t.status = 'waiting';
    t.updated = Date.now();
    if (!(t.order > 0)) {
      t.order = Downloader.nextOrder();
    }
    Downloader.persist();
    await Downloader.pump();
    return '';
  }

  /** 删掉缓存（连文件一起）。 */
  static remove(mid: number, key: string): void {
    const t = Downloader.find(mid, key);
    if (t !== undefined && t.path.length > 0) {
      try {
        if (fs.accessSync(t.path)) {
          fs.unlinkSync(t.path);
        }
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] offline unlink: ${e.code} ${e.message}`);
      }
    }
    const next: OfflineTask[] = [];
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const cur = Downloader.tasks[i];
      if (!(cur.mid === mid && cur.key === key)) {
        next.push(cur);
      }
    }
    Downloader.tasks = next;
    Downloader.persist();
  }

  static clearAll(): void {
    for (let i = 0; i < Downloader.tasks.length; i++) {
      const p = Downloader.tasks[i].path;
      if (p.length > 0) {
        try {
          if (fs.accessSync(p)) {
            fs.unlinkSync(p);
          }
        } catch (err) {
          // 删不掉就留着，记录先清
        }
      }
    }
    Downloader.tasks = [];
    // 字幕表一起清（单个删除时留着，重下同片能直接复用）
    Store.I.prefSetString(SUB_KEY, '');
    Downloader.persist();
  }
}
