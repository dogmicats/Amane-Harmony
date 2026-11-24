import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { DetailParams } from '../common/Types';
import { OnlineSubtitle, SubtitleClient } from '../common/Subtitles';
import {
  AutoChosen, AutoErrorItem, AutoResult, AutoSourceStatus, AutoTask, AutoTaskList, AutoTaskRun,
  HealthItem, HealthResult, JavStatus, QueueCandidate, QueueItem, QueueResult,
  SubCaptchaChallenge, SubCaptchaVerify, SubtitleOps, VersionItem
} from '../common/SubtitleOps';
import { GlassBack, GlassCapsule, PageTitle } from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

/**
 * 字幕管理中心（2026-11-24 重构稳定版）。
 *
 * 核心闭环：
 *   1. 批量选片下载：4 格统计即筛选器 + 番号/片名搜索 + 选前10/前30/全选快选 + 吸底批量自动补；
 *   2. 按影片合并查看结果：自动拉取最近任务逐部结果并按 item_id 归并，同一部影片只占一张卡，
 *      默认显示最终结论与尝试次数，展开看历次任务记录与候选打分明细；支持「全部 / 已补上 / 未落库」筛选；
 *   3. 全链路跳转详情：选片列表、按片合并结果、任务明细、手动队列、下载记录每条均可一键直达 DetailPage；
 *   4. 常驻手动验证码：顶栏常驻「JAV 验证」玻璃胶囊 + 结果卡遇验证码直连「填验证码」，随时拉起应用内 Web 抽屉；
 *   5. 稳定性：首屏错峰加载 + 瞬时异常自动重试 + 任务详情按需拉取并缓存终态 + 全字段零 undefined 渲染崩溃。
 */

interface TabDef {
  key: string;
  label: string;
}

/** 某部影片在一次自动补任务中的单次尝试。 */
interface FilmAttempt {
  taskId: number;
  taskTime: string;
  result: AutoResult;
}

/** 按 item_id 合并后的影片级结果卡片数据（同一部片历次尝试合并为一条）。 */
interface MergedFilmResult {
  itemId: number;
  number: string;
  title: string;
  succeeded: boolean;
  bestAttempt: FilmAttempt;
  latestAttempt: FilmAttempt;
  attempts: FilmAttempt[];
  hasCaptcha: boolean;
}

/** 按影片合并后的下载记录卡片数据（同一部片历次下载/替换/移除合并为一条）。 */
interface MergedVersionFilm {
  key: string;
  itemId: number;
  number: string;
  title: string;
  latest: VersionItem;
  records: VersionItem[];
}

const HEALTH_PAGE: number = 500;
/** 自动聚合结果时最多拉取最近多少条服务端任务的详情（兼顾完整度与请求轻量）。 */
const MERGE_TASK_LIMIT: number = 12;

function safeText(v: string | null | undefined): string {
  return typeof v === 'string' ? v : '';
}

function safeNum(v: number | null | undefined): number {
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function nowStamp(): string {
  const d: Date = new Date();
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function delayMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

@Entry
@Component
struct SubtitleManagerPage {
  // 主导航：pick（选片补字幕） / tasks（任务与结果） / history（下载记录）
  @State tab: string = 'pick';
  // 「任务与结果」子切页：merged（按影片合并结果） / progress（任务进度） / manual（手动队列）
  @State taskSub: string = 'merged';
  // 「按影片合并结果」筛选：'' 全部 / 'ok' 已补上 / 'fail' 未落库
  @State resultFilter: string = '';
  // 未落库细类筛选：'' 全部 / 'captcha' / 'low_score' / 'no_cand' / 'download' / 'other'
  @State reasonCategory: string = '';
  // 未落库原因查看页（非空时覆盖全屏展示详细诊断页）
  @State inspectReasonFilm: MergedFilmResult | null = null;

  // ---- 全库健康状态与筛选 ----
  @State health: HealthResult | null = null;
  @State healthItems: HealthItem[] = [];
  @State healthMore: boolean = false;
  @State loadingMore: boolean = false;
  @State healthErr: string = '';
  @State statusFilter: string = '';
  @State searchText: string = '';
  @State picked: number[] = [];
  /** 选片页是否隐藏已搜失败/已标无字幕的沉底项（默认沉到底部，可一键隐藏）。 */
  @State hideSunkInPick: boolean = false;
  /** 手动队列是否切到查看「已沉底/跳过」列表（默认只看活跃手动队列，不被自动沉底项污染）。 */
  @State showSunkQueue: boolean = false;

  // ---- 后台扫库状态 ----
  @State scanning: boolean = false;
  @State scanDone: number = 0;
  @State scanTotal: number = 0;
  @State scanError: string = '';
  @State scanMode: string = '';
  @State scanReused: number = 0;
  @State scanRescanned: number = 0;

  // ---- 自动补任务与按影片合并结果 ----
  @State serverTasks: AutoTask[] = [];
  @State localTasks: AutoTask[] = [];
  @State mergedFilms: MergedFilmResult[] = [];
  @State loadingResults: boolean = false;
  @State serverTaskCapable: boolean = true;
  /** 按影片结果视图中展开的影片 itemId（0 = 全部折叠）。 */
  @State expandedFilmId: number = 0;
  /** 任务进度视图中展开的任务 ID（0 = 全部折叠）。 */
  @State expandedTaskId: number = 0;
  /** 正在拉取详情的任务 ID。 */
  @State loadingTaskId: number = 0;
  /** 已缓存的终态任务详情（taskId -> runs），避免重复请求。 */
  private taskRunsCache: Map<number, AutoTaskRun[]> = new Map<number, AutoTaskRun[]>();
  private taskFinalCached: Set<number> = new Set<number>();
  private autoSyncedFailIds: Set<number> = new Set<number>();
  private syncingFails: boolean = false;
  private nextLocalTaskId: number = -1;
  private localCancelFlag: boolean = false;
  private tasksLoadedOnce: boolean = false;
  private alive: boolean = true;

  // ---- 手动搜索队列 ----
  @State queue: QueueResult | null = null;
  @State expandedQueueId: number = 0;
  @State queueCands: QueueCandidate[] = [];
  @State workingQueueId: number = 0;

  // ---- 下载记录（按影片合并） ----
  @State versions: VersionItem[] = [];
  @State mergedVersions: MergedVersionFilm[] = [];
  @State expandedHistoryKey: string = '';

  // ---- JAV 验证码会话与弹窗 ----
  @State javRemaining: number = 0;
  @State javNeedCaptcha: boolean = false;
  @State showCaptcha: boolean = false;
  @State captchaLoading: boolean = false;
  @State captchaSubmitting: boolean = false;
  @State captchaImage: string = '';
  @State captchaId: string = '';
  @State captchaAnswer: string = '';
  @State captchaTip: string = '';
  private captchaCtrl: webview.WebviewController = new webview.WebviewController();

  // ---- 全局状态 ----
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State note: string = '';
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();
  private scanTimer: number = 0;
  private taskPollTimer: number = 0;

  private mainTabs: TabDef[] = [
    { key: 'pick', label: '选片补字幕' },
    { key: 'tasks', label: '任务与结果' },
    { key: 'history', label: '下载记录' }
  ];

  aboutToAppear(): void {
    this.alive = true;
    this.bootLoad();
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopScanPoll();
    this.stopTaskPoll();
  }

  onBackPress(): boolean {
    if (this.showCaptcha) {
      this.showCaptcha = false;
      return true;
    }
    if (this.inspectReasonFilm !== null) {
      this.inspectReasonFilm = null;
      return true;
    }
    return false;
  }

  // ---- 顶栏几何 -------------------------------------------------------

  private barH(): number {
    return this.topInset + 46;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  private javCapsuleLabel(): string {
    if (this.javRemaining > 0) {
      return `JAV 剩${this.javRemaining}`;
    }
    return this.javNeedCaptcha ? 'JAV 需验证' : 'JAV 验证';
  }

  private scanCapsuleLabel(): string {
    if (this.scanning) {
      return this.scanTotal > 0 ? `扫 ${this.scanDone}/${this.scanTotal}` : '扫描中';
    }
    return '扫描';
  }

  @Builder
  TitleBar() {
    Column() {
      if (this.inspectReasonFilm !== null) {
        Row({ space: 6 }) {
          GlassBack({
            mat: true,
            onTap: () => {
              this.inspectReasonFilm = null;
            }
          })
          PageTitle({ text: '未落库原因', fs: 18 })
          Blank()
          GlassCapsule({
            label: '影片详情 ›',
            active: false,
            fs: 11,
            padH: 10,
            padV: 6,
            radius: 12,
            mat: true,
            onTap: () => {
              if (this.inspectReasonFilm !== null) {
                this.openDetail(this.inspectReasonFilm.itemId);
              }
            }
          })
        }
        .height(46)
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .padding({ left: 8, right: Theme.PAGE_PAD })
      } else {
        Row({ space: 6 }) {
          GlassBack({
            mat: true,
            onTap: () => {
              router.back();
            }
          })
          PageTitle({ text: '字幕管理', fs: 18 })
          Blank()
          GlassCapsule({
            label: this.javCapsuleLabel(),
            active: this.javRemaining > 0,
            fs: 11,
            padH: 10,
            padV: 6,
            radius: 12,
            mat: true,
            onTap: () => {
              this.openCaptcha();
            }
          })
          GlassCapsule({
            label: this.scanCapsuleLabel(),
            active: this.scanning,
            fs: 11,
            padH: 10,
            padV: 6,
            radius: 12,
            mat: true,
            onTap: () => {
              if (!this.scanning) {
                this.doScan(false);
              }
            }
          })
        }
        .height(46)
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .padding({ left: 8, right: Theme.PAGE_PAD })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  // ---- 错峰启动加载 + 瞬时失败自动重试（根治首次加载异常） --------------

  private async bootLoad(): Promise<void> {
    this.loading = true;
    this.healthErr = '';
    // 1) 首屏优先只拉主列表（不 5 路并发轰炸冷连接/预热扫描），瞬时异常自动重试 1 次
    let ok: boolean = await this.loadHealth(false, true);
    if (!ok && this.alive) {
      await delayMs(450);
      ok = await this.loadHealth(false, false);
    }
    if (!this.alive) {
      return;
    }
    this.loading = false;
    if (this.scanning) {
      this.startScanPoll();
    }
    // 2) 首屏已呈现，再温和错峰加载次要数据（互不影响主界面）
    await this.loadJav();
    if (!this.alive) {
      return;
    }
    await this.loadTasks(true);
    if (!this.alive) {
      return;
    }
    await this.loadQueue();
    if (!this.alive) {
      return;
    }
    await this.loadVersions();
  }

  private syncScan(h: HealthResult | null): void {
    if (h === null) {
      return;
    }
    this.scanning = h.meta.scanning === true;
    this.scanDone = safeNum(h.meta.scan_done);
    this.scanTotal = safeNum(h.meta.scan_total);
    this.scanError = safeText(h.meta.scan_error);
    this.scanMode = safeText(h.meta.scan_mode);
    this.scanReused = safeNum(h.meta.scan_reused);
    this.scanRescanned = safeNum(h.meta.scan_rescanned);
  }

  private applyFirstPage(res: HealthResult, clearPicked: boolean): void {
    this.health = res;
    this.healthItems = res.items;
    const total: number = res.meta.total !== undefined ? res.meta.total : res.meta.scanned;
    const returned: number = res.meta.returned !== undefined ? res.meta.returned : res.items.length;
    this.healthMore = returned > 0 && this.healthItems.length < total;
    this.healthErr = '';
    this.syncScan(res);
    if (clearPicked) {
      this.picked = [];
    }
    if (this.versions.length > 0) {
      this.rebuildMergedVersions();
    }
    if (this.mergedFilms.length > 0) {
      this.syncFailedAutoToServer();
    }
  }

  private async loadHealth(refresh: boolean, silentErr: boolean = false): Promise<boolean> {
    try {
      const res: HealthResult = await SubtitleOps.health(refresh, HEALTH_PAGE, 0);
      if (!this.alive) {
        return false;
      }
      this.applyFirstPage(res, refresh);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      if (!silentErr && this.alive) {
        this.healthErr = safeText(e.message).length > 0 ? safeText(e.message) : '读取全库状态失败';
      }
      return false;
    }
  }

  private async loadMoreHealth(): Promise<void> {
    if (!this.healthMore || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const res: HealthResult = await SubtitleOps.health(false, HEALTH_PAGE, this.healthItems.length);
      if (!this.alive) {
        return;
      }
      this.healthItems = [...this.healthItems, ...res.items];
      const total: number = res.meta.total !== undefined ? res.meta.total : res.meta.scanned;
      const returned: number = res.meta.returned !== undefined ? res.meta.returned : 0;
      this.healthMore = returned > 0 && this.healthItems.length < total;
      if (this.versions.length > 0) {
        this.rebuildMergedVersions();
      }
    } catch (err) {
      const e = err as BusinessError;
      this.note = `加载更多失败：${safeText(e.message)}`;
    } finally {
      this.loadingMore = false;
    }
  }

  private startScanPoll(): void {
    if (this.scanTimer !== 0) {
      return;
    }
    this.scanTimer = setInterval(() => {
      // 只拉 1 条看扫描进度，绝不用该小响应覆盖 this.health 主快照
      SubtitleOps.health(false, 1, 0).then((res: HealthResult) => {
        if (!this.alive) {
          return;
        }
        this.syncScan(res);
        if (!this.scanning) {
          this.stopScanPoll();
          this.loadHealth(false, false);
          this.loadQueue();
          this.note = this.scanError.length > 0
            ? `扫描失败：${this.scanError}`
            : `扫描完成，共 ${res.meta.scanned} 部`;
        }
      }).catch(() => { /* 轮询失败下轮重试 */ });
    }, 1800);
  }

  private stopScanPoll(): void {
    if (this.scanTimer !== 0) {
      clearInterval(this.scanTimer);
      this.scanTimer = 0;
    }
  }

  private async loadQueue(): Promise<void> {
    try {
      const res: QueueResult = await SubtitleOps.queue('');
      if (this.alive) {
        this.queue = res;
      }
    } catch (err) {
      // 次要数据静默容错，不阻断主界面
    }
  }

  private async loadVersions(): Promise<void> {
    try {
      const res = await SubtitleOps.versions(0);
      if (this.alive) {
        this.versions = res.items;
        this.rebuildMergedVersions();
      }
    } catch (err) {
      // 次要数据静默容错
    }
  }

  /** 将下载记录按影片（item_id，兜底 filename）归并，每部片只占一张卡片并反查番号/片名。 */
  private rebuildMergedVersions(): void {
    const numMap: Map<number, string> = new Map<number, string>();
    const titleMap: Map<number, string> = new Map<number, string>();
    for (let i = 0; i < this.healthItems.length; i++) {
      const h: HealthItem = this.healthItems[i];
      if (h.metadata_id > 0) {
        if (h.number.length > 0) {
          numMap.set(h.metadata_id, h.number);
        }
        if (h.title.length > 0) {
          titleMap.set(h.metadata_id, h.title);
        }
      }
    }
    for (let i = 0; i < this.mergedFilms.length; i++) {
      const f: MergedFilmResult = this.mergedFilms[i];
      if (f.itemId > 0) {
        if (!numMap.has(f.itemId) && f.number.length > 0) {
          numMap.set(f.itemId, f.number);
        }
        if (!titleMap.has(f.itemId) && f.title.length > 0) {
          titleMap.set(f.itemId, f.title);
        }
      }
    }

    const order: string[] = [];
    const map: Map<string, MergedVersionFilm> = new Map<string, MergedVersionFilm>();
    for (let i = 0; i < this.versions.length; i++) {
      const v: VersionItem = this.versions[i];
      const key: string = v.item_id > 0 ? `id-${v.item_id}` : `fn-${v.filename}`;
      const exist: MergedVersionFilm | undefined = map.get(key);
      if (exist === undefined) {
        const num: string = v.item_id > 0 ? safeText(numMap.get(v.item_id)) : '';
        const title: string = v.item_id > 0 ? safeText(titleMap.get(v.item_id)) : '';
        map.set(key, {
          key: key,
          itemId: v.item_id,
          number: num,
          title: title,
          latest: v,
          records: [v]
        });
        order.push(key);
      } else {
        exist.records.push(v);
      }
    }

    const out: MergedVersionFilm[] = [];
    for (let i = 0; i < order.length; i++) {
      const g: MergedVersionFilm | undefined = map.get(order[i]);
      if (g !== undefined) {
        out.push(g);
      }
    }
    this.mergedVersions = out;
  }

  private async loadJav(): Promise<void> {
    try {
      const st: JavStatus = await SubtitleOps.javStatus();
      if (!this.alive) {
        return;
      }
      this.javRemaining = st.verified ? safeNum(st.remaining) : 0;
      this.javNeedCaptcha = st.need_captcha === true;
    } catch (err) {
      // 老服务端无 /javzimu/status 端点时保留常驻顶栏「JAV 验证」入口
    }
  }

  // ---- 任务列表、详情按需拉取与「按影片合并结果」 ----------------------

  private isTaskTerminal(state: string): boolean {
    return state === 'done' || state === 'cancelled' || state === 'failed' || state === 'interrupted';
  }

  private taskRunsOf(t: AutoTask): AutoTaskRun[] {
    if (t.local === true) {
      return Array.isArray(t.results) ? t.results : [];
    }
    const cached: AutoTaskRun[] | undefined = this.taskRunsCache.get(t.id);
    if (cached !== undefined) {
      return cached;
    }
    return Array.isArray(t.results) ? t.results : [];
  }

  /** 拉取单条服务端任务的逐部 results（终态任务只拉一次并缓存）。 */
  private async fetchTaskDetail(t: AutoTask, force: boolean = false): Promise<AutoTaskRun[]> {
    if (t.local === true) {
      return Array.isArray(t.results) ? t.results : [];
    }
    if (!force && this.taskFinalCached.has(t.id)) {
      const hit: AutoTaskRun[] | undefined = this.taskRunsCache.get(t.id);
      if (hit !== undefined) {
        return hit;
      }
    }
    try {
      const full: AutoTask = await SubtitleOps.autoTask(t.id);
      const runs: AutoTaskRun[] = Array.isArray(full.results) ? full.results : [];
      this.taskRunsCache.set(t.id, runs);
      if (this.isTaskTerminal(full.state)) {
        this.taskFinalCached.add(t.id);
      }
      return runs;
    } catch (err) {
      const old: AutoTaskRun[] | undefined = this.taskRunsCache.get(t.id);
      return old !== undefined ? old : [];
    }
  }

  /** 拉取服务端任务列表，并补齐最近任务详情后归并影片级结果。 */
  private async loadTasks(hydrateDetails: boolean): Promise<void> {
    if (!this.serverTaskCapable) {
      this.rebuildMergedFilms();
      return;
    }
    try {
      const prevActive: boolean = this.hasActiveServerTask();
      const list: AutoTaskList = await SubtitleOps.autoTasks(30);
      if (!this.alive) {
        return;
      }
      this.serverTasks = list.items;
      this.tasksLoadedOnce = true;

      if (hydrateDetails) {
        await this.hydrateRecentTaskDetails();
      }
      this.rebuildMergedFilms();

      const nowActive: boolean = this.hasActiveServerTask();
      if (nowActive) {
        this.startTaskPoll();
      } else {
        this.stopTaskPoll();
        if (prevActive && list.items.length > 0) {
          const top: AutoTask = list.items[0];
          // 任务刚结束：强制拉一次最新完整结果并刷新库状态
          await this.fetchTaskDetail(top, true);
          this.rebuildMergedFilms();
          this.note = `自动补已完成：成功 ${safeNum(top.ok_count)}/${safeNum(top.total)}，已刷新库状态`;
          this.loadHealth(false, true);
          this.loadQueue();
          this.loadVersions();
          this.loadJav();
        }
      }
    } catch (err) {
      // 老服务端无 /auto/tasks 端点 → 降级为本地同步任务记录
      this.serverTaskCapable = false;
      this.stopTaskPoll();
      this.rebuildMergedFilms();
    }
  }

  /** 为最近最多 MERGE_TASK_LIMIT 个任务拉取详情（已缓存终态的 0 请求跳过）。 */
  private async hydrateRecentTaskDetails(): Promise<void> {
    const targets: AutoTask[] = [];
    const cap: number = Math.min(this.serverTasks.length, MERGE_TASK_LIMIT);
    for (let i = 0; i < cap; i++) {
      const t: AutoTask = this.serverTasks[i];
      const active: boolean = t.state === 'running' || t.state === 'queued';
      if (active || !this.taskFinalCached.has(t.id)) {
        if (active || safeNum(t.done) > 0 || safeNum(t.ok_count) > 0) {
          targets.push(t);
        } else {
          this.taskRunsCache.set(t.id, []);
          if (this.isTaskTerminal(t.state)) {
            this.taskFinalCached.add(t.id);
          }
        }
      }
    }
    if (targets.length === 0) {
      return;
    }
    this.loadingResults = true;
    try {
      // 串行/温和拉取，避免瞬时并发把服务端打慢
      for (let i = 0; i < targets.length; i++) {
        if (!this.alive) {
          return;
        }
        await this.fetchTaskDetail(targets[i], targets[i].state === 'running');
      }
    } finally {
      if (this.alive) {
        this.loadingResults = false;
      }
    }
  }

  private async toggleExpandTask(t: AutoTask): Promise<void> {
    if (this.expandedTaskId === t.id) {
      this.expandedTaskId = 0;
      return;
    }
    this.expandedTaskId = t.id;
    if (t.local !== true && !this.taskFinalCached.has(t.id)) {
      this.loadingTaskId = t.id;
      await this.fetchTaskDetail(t, true);
      if (this.alive) {
        this.loadingTaskId = 0;
        this.rebuildMergedFilms();
      }
    }
  }

  /**
   * 核心聚合：把所有任务（本地 + 服务端）中属于同一部影片（同 item_id）的结果合并为一张卡片。
   * 任务顺序已按时间倒序（最新在前），因此每部片的 attempts[0] 即最新一次尝试。
   */
  private rebuildMergedFilms(): void {
    const tasks: AutoTask[] = this.allTasks();
    const order: number[] = [];
    const map: Map<number, MergedFilmResult> = new Map<number, MergedFilmResult>();

    for (let ti = 0; ti < tasks.length; ti++) {
      const t: AutoTask = tasks[ti];
      const runs: AutoTaskRun[] = this.taskRunsOf(t);
      const tTime: string = safeText(t.created_at);
      // 同一任务内如果倒序看，后面的尝试可能更新；按原顺序或倒序均可，这里倒序保证同任务内后跑的在前
      for (let ri = runs.length - 1; ri >= 0; ri--) {
        const run: AutoTaskRun = runs[ri];
        const iid: number = safeNum(run.item_id);
        if (iid <= 0) {
          continue;
        }
        const attempt: FilmAttempt = {
          taskId: t.id,
          taskTime: tTime,
          result: run.result
        };
        const isOk: boolean = run.result.ok === true && run.result.chosen !== null;
        const exist: MergedFilmResult | undefined = map.get(iid);
        if (exist === undefined) {
          const entry: MergedFilmResult = {
            itemId: iid,
            number: safeText(run.number),
            title: safeText(run.title),
            succeeded: isOk,
            bestAttempt: attempt,
            latestAttempt: attempt,
            attempts: [attempt],
            hasCaptcha: this.runHasCaptcha(run.result)
          };
          map.set(iid, entry);
          order.push(iid);
        } else {
          if (exist.number.length === 0 && safeText(run.number).length > 0) {
            exist.number = safeText(run.number);
          }
          if (exist.title.length === 0 && safeText(run.title).length > 0) {
            exist.title = safeText(run.title);
          }
          exist.attempts.push(attempt);
          // 只要历次中有成功落库记录，且当前 bestAttempt 还没成功，就提升为成功记录作为主展示
          if (isOk && !exist.succeeded) {
            exist.succeeded = true;
            exist.bestAttempt = attempt;
          }
        }
      }
    }

    const out: MergedFilmResult[] = [];
    for (let i = 0; i < order.length; i++) {
      const m: MergedFilmResult | undefined = map.get(order[i]);
      if (m !== undefined) {
        out.push(m);
      }
    }
    this.mergedFilms = out;
    if (this.versions.length > 0) {
      this.rebuildMergedVersions();
    }
    if (this.inspectReasonFilm !== null) {
      const curId: number = this.inspectReasonFilm.itemId;
      const fresh: MergedFilmResult | undefined = out.find((x: MergedFilmResult) => x.itemId === curId);
      if (fresh !== undefined) {
        this.inspectReasonFilm = fresh;
      }
    }
    this.syncFailedAutoToServer();
  }

  private startTaskPoll(): void {
    if (this.taskPollTimer !== 0 || !this.serverTaskCapable) {
      return;
    }
    this.taskPollTimer = setInterval(() => {
      this.loadTasks(true);
    }, 2500);
  }

  private stopTaskPoll(): void {
    if (this.taskPollTimer !== 0) {
      clearInterval(this.taskPollTimer);
      this.taskPollTimer = 0;
    }
  }

  // ---- 跳转影片详情 ---------------------------------------------------

  private openDetail(id: number): void {
    if (id <= 0) {
      return;
    }
    const params: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  // ---- 选片与过滤逻辑 -------------------------------------------------

  private healthCount(key: string): number {
    if (this.health === null) {
      return 0;
    }
    return safeNum(this.health.meta.counts[key]);
  }

  private canQueue(item: HealthItem): boolean {
    return item.status === 'none' || item.status === 'foreign';
  }

  private mergedFilmMap(): Map<number, MergedFilmResult> {
    const m: Map<number, MergedFilmResult> = new Map<number, MergedFilmResult>();
    for (let i = 0; i < this.mergedFilms.length; i++) {
      m.set(this.mergedFilms[i].itemId, this.mergedFilms[i]);
    }
    return m;
  }

  private queueStateOf(itemId: number): string {
    if (this.queue !== null) {
      for (let i = 0; i < this.queue.items.length; i++) {
        if (this.queue.items[i].metadata_id === itemId) {
          return this.queue.items[i].state;
        }
      }
    }
    for (let i = 0; i < this.healthItems.length; i++) {
      if (this.healthItems[i].metadata_id === itemId) {
        return this.healthItems[i].queue_state;
      }
    }
    return '';
  }

  private isFilmSkipped(itemId: number): boolean {
    return this.queueStateOf(itemId) === 'skipped';
  }

  /**
   * 选片智能排序优先级（越小越靠前）：
   *   0    未尝试的无字幕片（最优先）
   *   1000 未尝试的只外文片
   *   2000 仅因 JAV 验证码被挡住的片（填码后值得优先重试）
   *   3000+ 已搜过仍未落库 / failed 的片（自动沉底，失败次数越多越靠后）
   *   4000 用户明确标记「无字幕 / 跳过」的片（沉到缺字幕区最底）
   *   5000 已有中文
   *   6000 内嵌字幕
   */
  private pickSortRank(item: HealthItem, mfMap: Map<number, MergedFilmResult>): number {
    if (item.status === 'cn') {
      return 5000;
    }
    if (item.status === 'embedded') {
      return 6000;
    }
    const qs: string = item.queue_state;
    if (qs === 'skipped') {
      return 4000;
    }
    const mf: MergedFilmResult | undefined = mfMap.get(item.metadata_id);
    if (qs === 'failed' || (mf !== undefined && !mf.succeeded && !mf.hasCaptcha)) {
      const tries: number = mf !== undefined ? Math.min(mf.attempts.length, 99) : 1;
      return 3000 + tries;
    }
    if (mf !== undefined && !mf.succeeded && mf.hasCaptcha) {
      return 2000;
    }
    return item.status === 'none' ? 0 : 1000;
  }

  private healthSunkCount(): number {
    const mfMap: Map<number, MergedFilmResult> = this.mergedFilmMap();
    let n: number = 0;
    for (let i = 0; i < this.healthItems.length; i++) {
      const r: number = this.pickSortRank(this.healthItems[i], mfMap);
      if (r >= 3000 && r < 5000) {
        n++;
      }
    }
    return n;
  }

  private healthFailBadge(item: HealthItem): string {
    if (item.queue_state === 'skipped') {
      return '已标无字幕';
    }
    for (let i = 0; i < this.mergedFilms.length; i++) {
      const f: MergedFilmResult = this.mergedFilms[i];
      if (f.itemId === item.metadata_id && !f.succeeded) {
        if (f.hasCaptcha) {
          return '需验证码';
        }
        return f.attempts.length > 1 ? `未落库 ×${f.attempts.length}` : '已搜未中';
      }
    }
    if (item.queue_state === 'failed') {
      return '已搜未中';
    }
    return '';
  }

  private patchLocalQueueState(ids: number[], newState: string): void {
    if (ids.length === 0) {
      return;
    }
    const idSet: Set<number> = new Set<number>(ids);
    let changed: boolean = false;
    const next: HealthItem[] = [];
    for (let i = 0; i < this.healthItems.length; i++) {
      const it: HealthItem = this.healthItems[i];
      if (idSet.has(it.metadata_id) && it.queue_state !== newState) {
        changed = true;
        next.push({
          metadata_id: it.metadata_id,
          number: it.number,
          title: it.title,
          status: it.status,
          langs: it.langs,
          detail: it.detail,
          checked_at: it.checked_at,
          queue_state: newState
        });
      } else {
        next.push(it);
      }
    }
    if (changed) {
      this.healthItems = next;
    }
  }

  /**
   * 自动补非验证码原因未落库的影片，温和同步为服务端 failed 状态：
   * 后端 _health_rows 会将其真正沉到全库队尾，跨分页、跨重启都不再反复占队首。
   */
  private async syncFailedAutoToServer(): Promise<void> {
    if (this.syncingFails || !this.alive || this.healthItems.length === 0 || this.mergedFilms.length === 0) {
      return;
    }
    const healthMap: Map<number, HealthItem> = new Map<number, HealthItem>();
    for (let i = 0; i < this.healthItems.length; i++) {
      healthMap.set(this.healthItems[i].metadata_id, this.healthItems[i]);
    }
    const toSync: number[] = [];
    for (let i = 0; i < this.mergedFilms.length; i++) {
      const f: MergedFilmResult = this.mergedFilms[i];
      if (f.succeeded || f.hasCaptcha || this.autoSyncedFailIds.has(f.itemId)) {
        continue;
      }
      const h: HealthItem | undefined = healthMap.get(f.itemId);
      if (h !== undefined && this.canQueue(h) && h.queue_state.length === 0) {
        toSync.push(f.itemId);
        if (toSync.length >= 30) {
          break;
        }
      }
    }
    if (toSync.length === 0) {
      return;
    }
    for (let i = 0; i < toSync.length; i++) {
      this.autoSyncedFailIds.add(toSync[i]);
    }
    this.syncingFails = true;
    try {
      await SubtitleOps.enqueue(toSync, 'chs');
      for (let i = 0; i < toSync.length; i++) {
        if (!this.alive) {
          return;
        }
        try {
          await SubtitleOps.set(toSync[i], 'fail');
        } catch (err) {
          // 单条容错，不阻断其余沉底
        }
      }
      if (this.alive) {
        this.patchLocalQueueState(toSync, 'failed');
        this.loadQueue();
      }
    } catch (err) {
      // 服务端同步失败时，客户端智能排序仍会将其沉底
    } finally {
      this.syncingFails = false;
    }
  }

  /** 用户确认无字幕/跳过：持久化为 skipped 永久沉底，快选跳过、全库沉尾。 */
  private async markFilmSkipped(itemId: number, label: string): Promise<void> {
    if (this.busy || itemId <= 0) {
      return;
    }
    this.busy = true;
    this.note = '';
    try {
      await SubtitleOps.enqueue([itemId], 'chs');
      await SubtitleOps.set(itemId, 'skip');
      this.patchLocalQueueState([itemId], 'skipped');
      this.picked = this.picked.filter((x: number) => x !== itemId);
      await this.loadQueue();
      this.loadHealth(false, true);
      this.note = `已将 ${label} 标为无字幕并沉底（选前10/30将自动跳过）`;
    } catch (err) {
      const e = err as BusinessError;
      this.note = `标记失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  /** 将已沉底/跳过的影片恢复到正常待补队列。 */
  private async restoreFilm(itemId: number, label: string): Promise<void> {
    if (this.busy || itemId <= 0) {
      return;
    }
    this.busy = true;
    this.note = '';
    try {
      await SubtitleOps.set(itemId, 'remove');
      this.autoSyncedFailIds.delete(itemId);
      this.patchLocalQueueState([itemId], '');
      await this.loadQueue();
      this.loadHealth(false, true);
      this.note = `已恢复 ${label} 到待补队列`;
    } catch (err) {
      const e = err as BusinessError;
      this.note = `恢复失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  private filteredHealthItems(): HealthItem[] {
    const kw: string = this.searchText.trim().toLowerCase();
    const mfMap: Map<number, MergedFilmResult> = this.mergedFilmMap();
    const out: HealthItem[] = [];
    for (let i = 0; i < this.healthItems.length; i++) {
      const it: HealthItem = this.healthItems[i];
      if (this.statusFilter.length > 0 && it.status !== this.statusFilter) {
        continue;
      }
      if (this.hideSunkInPick) {
        const rank: number = this.pickSortRank(it, mfMap);
        if (rank >= 3000 && rank < 5000) {
          continue;
        }
      }
      if (kw.length > 0) {
        const numLow: string = safeText(it.number).toLowerCase();
        const titleLow: string = safeText(it.title).toLowerCase();
        if (numLow.indexOf(kw) < 0 && titleLow.indexOf(kw) < 0) {
          continue;
        }
      }
      out.push(it);
    }
    out.sort((a: HealthItem, b: HealthItem) =>
      this.pickSortRank(a, mfMap) - this.pickSortRank(b, mfMap));
    return out;
  }

  private classifyFailReason(film: MergedFilmResult): string {
    const res: AutoResult = film.latestAttempt.result;
    if (film.hasCaptcha || this.runHasCaptcha(res)) {
      return 'captcha';
    }
    const r: string = safeText(res.reason);
    const rankedLen: number = Array.isArray(res.ranked) ? res.ranked.length : 0;
    if (r.indexOf('低于阈值') >= 0 || rankedLen > 0) {
      return 'low_score';
    }
    if (r.indexOf('下载失败') >= 0) {
      return 'download';
    }
    if (Array.isArray(res.errors)) {
      for (let i = 0; i < res.errors.length; i++) {
        if (safeText(res.errors[i].kind) === 'download') {
          return 'download';
        }
      }
    }
    if (r.indexOf('没') >= 0 && r.indexOf('候选') >= 0) {
      return 'no_cand';
    }
    return 'other';
  }

  private failCategoryLabel(cat: string): string {
    if (cat === 'captcha') {
      return '需验证码';
    }
    if (cat === 'low_score') {
      return '分低未达标';
    }
    if (cat === 'no_cand') {
      return '来源无候选';
    }
    if (cat === 'download') {
      return '下载失败';
    }
    return '执行异常';
  }

  private failCategoryCount(cat: string): number {
    let n: number = 0;
    for (let i = 0; i < this.mergedFilms.length; i++) {
      const f: MergedFilmResult = this.mergedFilms[i];
      if (!f.succeeded && this.classifyFailReason(f) === cat) {
        n++;
      }
    }
    return n;
  }

  private openReasonPage(film: MergedFilmResult): void {
    this.inspectReasonFilm = film;
  }

  private openReasonFromRun(t: AutoTask, run: AutoTaskRun): void {
    const hit: MergedFilmResult | undefined =
      this.mergedFilms.find((x: MergedFilmResult) => x.itemId === run.item_id);
    if (hit !== undefined) {
      this.inspectReasonFilm = hit;
      return;
    }
    const att: FilmAttempt = {
      taskId: t.id,
      taskTime: safeText(t.created_at),
      result: run.result
    };
    this.inspectReasonFilm = {
      itemId: run.item_id,
      number: safeText(run.number),
      title: safeText(run.title),
      succeeded: run.result.ok === true && run.result.chosen !== null,
      bestAttempt: att,
      latestAttempt: att,
      attempts: [att],
      hasCaptcha: this.runHasCaptcha(run.result)
    };
  }

  private async sendFilmToManualQueue(film: MergedFilmResult): Promise<void> {
    if (this.busy || film.itemId <= 0) {
      return;
    }
    this.inspectReasonFilm = null;
    this.busy = true;
    this.note = '';
    try {
      await SubtitleOps.enqueue([film.itemId], 'chs');
      await this.loadQueue();
      this.tab = 'tasks';
      this.taskSub = 'manual';
      const target: QueueItem | undefined = this.queue === null
        ? undefined
        : this.queue.items.find((x: QueueItem) => x.metadata_id === film.itemId);
      if (target !== undefined) {
        this.busy = false;
        await this.doSearch(target);
      } else {
        this.note = '已加入手动队列，请在手动队列中点「搜候选」挑选';
      }
    } catch (err) {
      const e = err as BusinessError;
      this.note = `转手动队列失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  private errorKindLabel(kind: string | undefined): string {
    const k: string = safeText(kind);
    if (k === 'download') {
      return '下载';
    }
    if (k === 'ref') {
      return '解析地址';
    }
    if (k === 'search') {
      return '检索';
    }
    return '异常';
  }

  private formatChosenDetail(detail: Record<string, number> | undefined): string {
    if (detail === undefined || detail === null) {
      return '';
    }
    const parts: string[] = [];
    const cues: number = safeNum(detail['cues']);
    if (cues > 0) {
      parts.push(`条数 ${cues}`);
    }
    const segHits: number = safeNum(detail['seg_hits']);
    if (segHits > 0) {
      parts.push(`分段 ${segHits}/10`);
    }
    const emptyRun: number = safeNum(detail['seg_empty_run']);
    if (emptyRun >= 2) {
      parts.push(`连续空段 ${emptyRun}`);
    }
    const cnRatio: number = safeNum(detail['cn_cue_ratio']);
    if (cnRatio > 0) {
      parts.push(`中文 ${Math.round(cnRatio * 100)}%`);
    }
    const span: number = safeNum(detail['span']);
    const film: number = safeNum(detail['film']);
    if (span > 0 && film > 0) {
      parts.push(`跨度 ${Math.round(span / 60)}m / 片长 ${Math.round(film / 60)}m`);
    }
    const siteDur: number = safeNum(detail['site_duration']);
    if (siteDur > 0) {
      parts.push(`站点片长 ${Math.round(siteDur / 60)}m`);
    }
    return parts.join(' · ');
  }

  private filteredMergedFilms(): MergedFilmResult[] {
    const out: MergedFilmResult[] = [];
    for (let i = 0; i < this.mergedFilms.length; i++) {
      const f: MergedFilmResult = this.mergedFilms[i];
      if (this.resultFilter === 'ok' && !f.succeeded) {
        continue;
      }
      if (this.resultFilter === 'fail') {
        if (f.succeeded) {
          continue;
        }
        if (this.reasonCategory.length > 0 && this.classifyFailReason(f) !== this.reasonCategory) {
          continue;
        }
      }
      out.push(f);
    }
    // 已确认无字幕（skipped）的影片在结果列表里也沉底，不霸占顶部
    out.sort((a: MergedFilmResult, b: MergedFilmResult) => {
      const sa: number = this.isFilmSkipped(a.itemId) ? 1 : 0;
      const sb: number = this.isFilmSkipped(b.itemId) ? 1 : 0;
      return sa - sb;
    });
    return out;
  }

  private mergedOkCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.mergedFilms.length; i++) {
      if (this.mergedFilms[i].succeeded) {
        n++;
      }
    }
    return n;
  }

  private toggleStatusFilter(key: string): void {
    this.statusFilter = this.statusFilter === key ? '' : key;
  }

  private togglePick(item: HealthItem): void {
    if (!this.canQueue(item)) {
      this.openDetail(item.metadata_id);
      return;
    }
    if (this.picked.indexOf(item.metadata_id) >= 0) {
      this.picked = this.picked.filter((x: number) => x !== item.metadata_id);
    } else {
      this.picked = [...this.picked, item.metadata_id];
    }
  }

  private pickFirst(limit: number): void {
    const list: HealthItem[] = this.filteredHealthItems();
    const mfMap: Map<number, MergedFilmResult> = this.mergedFilmMap();
    const ids: number[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: HealthItem = list[i];
      if (!this.canQueue(it)) {
        continue;
      }
      // 快选自动避开已搜失败和已标无字幕的沉底项（仍可手动勾选重试）
      if (this.pickSortRank(it, mfMap) >= 3000) {
        continue;
      }
      if (ids.indexOf(it.metadata_id) < 0) {
        ids.push(it.metadata_id);
        if (limit > 0 && ids.length >= limit) {
          break;
        }
      }
    }
    this.picked = ids;
    this.note = ids.length > 0
      ? `已选 ${ids.length} 部未尝试过的缺字幕影片（已自动跳过沉底项）`
      : '当前筛选下已无未尝试的影片（已沉底项可手动勾选重试）';
  }

  private clearPicked(): void {
    this.picked = [];
  }

  private async doScan(full: boolean): Promise<void> {
    this.note = '';
    try {
      const res: HealthResult = await SubtitleOps.health(full ? 'full' : true, HEALTH_PAGE, 0);
      if (!this.alive) {
        return;
      }
      this.applyFirstPage(res, true);
      if (this.scanning) {
        this.note = full ? `已开始全量重扫 ${this.scanTotal} 部` : `已开始增量扫描 ${this.scanTotal} 部`;
        this.startScanPoll();
      } else if (this.scanError.length > 0) {
        this.note = `扫描失败：${this.scanError}`;
      } else {
        this.note = `扫描完成（共 ${res.meta.scanned} 部，仅读本地目录未联网）`;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.note = `扫描失败：${safeText(e.message)}`;
    }
  }

  private async doEnqueue(): Promise<void> {
    if (this.picked.length === 0) {
      this.note = '先勾选要补字幕的影片';
      return;
    }
    this.busy = true;
    this.note = '';
    try {
      const res = await SubtitleOps.enqueue(this.picked, 'chs');
      const n: number = res.added_count === undefined ? 0 : res.added_count;
      this.picked = [];
      await this.loadQueue();
      this.tab = 'tasks';
      this.taskSub = 'manual';
      this.note = `已加入手动队列 ${n} 部（入队不联网）`;
    } catch (err) {
      const e = err as BusinessError;
      this.note = `加入队列失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  // ---- 自动补执行（新旧服务端双模） ------------------------------------

  private allTasks(): AutoTask[] {
    const merged: AutoTask[] = [];
    for (let i = 0; i < this.localTasks.length; i++) {
      merged.push(this.localTasks[i]);
    }
    for (let i = 0; i < this.serverTasks.length; i++) {
      merged.push(this.serverTasks[i]);
    }
    return merged;
  }

  private hasActiveServerTask(): boolean {
    for (let i = 0; i < this.serverTasks.length; i++) {
      const st: string = safeText(this.serverTasks[i].state);
      if (st === 'running' || st === 'queued') {
        return true;
      }
    }
    return false;
  }

  private activeTaskCount(): number {
    let n: number = 0;
    const tasks: AutoTask[] = this.allTasks();
    for (let i = 0; i < tasks.length; i++) {
      const st: string = safeText(tasks[i].state);
      if (st === 'running' || st === 'queued') {
        n++;
      }
    }
    return n;
  }

  private activeTopTask(): AutoTask | null {
    const tasks: AutoTask[] = this.allTasks();
    for (let i = 0; i < tasks.length; i++) {
      const st: string = safeText(tasks[i].state);
      if (st === 'running' || st === 'queued') {
        return tasks[i];
      }
    }
    return null;
  }

  private metaLabelOf(id: number): AutoTaskRun {
    let numText: string = '';
    let titleText: string = '';
    if (this.queue !== null) {
      const q: QueueItem | undefined = this.queue.items.find((x: QueueItem) => x.metadata_id === id);
      if (q !== undefined) {
        numText = safeText(q.number);
      }
    }
    const h: HealthItem | undefined = this.healthItems.find((x: HealthItem) => x.metadata_id === id);
    if (h !== undefined) {
      if (numText.length === 0) {
        numText = safeText(h.number);
      }
      titleText = safeText(h.title);
    }
    const emptyRes: AutoResult = { ok: false, chosen: null, ranked: [], source_status: [], errors: [], reasons: [] };
    return { item_id: id, number: numText, title: titleText, result: emptyRes };
  }

  private updateLocalTask(updated: AutoTask): void {
    const next: AutoTask[] = [];
    for (let i = 0; i < this.localTasks.length; i++) {
      next.push(this.localTasks[i].id === updated.id ? updated : this.localTasks[i]);
    }
    this.localTasks = next;
    this.rebuildMergedFilms();
  }

  private cloneTask(src: AutoTask, state: string, done: number, okCount: number,
    results: AutoTaskRun[], note: string, error: string): AutoTask {
    const stamp: string = nowStamp();
    return {
      id: src.id,
      state: state,
      scope: src.scope,
      total: src.total,
      done: done,
      ok_count: okCount,
      results: results,
      note: note,
      error: error,
      created_at: src.created_at,
      updated_at: stamp,
      finished_at: (state === 'done' || state === 'cancelled' || state === 'failed') ? stamp : '',
      local: src.local
    };
  }

  private async runAutoIds(ids: number[], lang: string): Promise<void> {
    if (ids.length === 0) {
      this.note = '先勾选要补字幕的影片';
      return;
    }
    this.busy = true;
    this.note = '';
    this.tab = 'tasks';
    this.taskSub = 'merged';
    try {
      const firstReply: AutoResult = await SubtitleOps.autoDispatch(ids, lang, 3, 60);
      if (!this.alive) {
        return;
      }
      // 1) 新服务端：异步后台任务
      if (firstReply.task_id !== undefined && firstReply.task_id > 0) {
        this.serverTaskCapable = true;
        this.note = `已提交任务 #${firstReply.task_id}（${ids.length} 部），后台执行中`;
        await this.loadTasks(true);
        this.startTaskPoll();
        return;
      }

      // 2) 老服务端（2.8.1 同步接口）：本地顺序推进并实时归并结果
      const taskId: number = this.nextLocalTaskId;
      this.nextLocalTaskId -= 1;
      this.localCancelFlag = false;
      const firstMeta: AutoTaskRun = this.metaLabelOf(ids[0]);
      firstMeta.result = firstReply;
      let okCount: number = (firstReply.ok && firstReply.chosen !== null) ? 1 : 0;
      const runs: AutoTaskRun[] = [firstMeta];
      const doneFirst: boolean = ids.length === 1;
      const stamp: string = nowStamp();

      let task: AutoTask = {
        id: taskId,
        state: doneFirst ? 'done' : 'running',
        scope: ids.length > 1 ? 'batch' : 'single',
        total: ids.length,
        done: 1,
        ok_count: okCount,
        results: [...runs],
        note: doneFirst ? '' : `正在补第 2/${ids.length} 部…`,
        error: '',
        created_at: stamp,
        updated_at: stamp,
        finished_at: doneFirst ? stamp : '',
        local: true
      };
      this.localTasks = [task, ...this.localTasks];
      this.rebuildMergedFilms();

      if (this.runHasCaptcha(firstReply)) {
        this.javNeedCaptcha = true;
      }

      for (let i = 1; i < ids.length; i++) {
        if (!this.alive) {
          return;
        }
        if (this.localCancelFlag) {
          task = this.cloneTask(task, 'cancelled', i, okCount, [...runs], '已手动停止剩余条目', '');
          this.updateLocalTask(task);
          break;
        }
        const curId: number = ids[i];
        const meta: AutoTaskRun = this.metaLabelOf(curId);
        try {
          const r: AutoResult = await SubtitleOps.autoSingle(curId, lang, 3, 60);
          meta.result = r;
          if (r.ok && r.chosen !== null) {
            okCount++;
          }
          if (this.runHasCaptcha(r)) {
            this.javNeedCaptcha = true;
          }
        } catch (err) {
          const e = err as BusinessError;
          meta.result = {
            ok: false, chosen: null, reason: `请求失败：${safeText(e.message)}`,
            ranked: [], source_status: [], errors: [], reasons: []
          };
        }
        runs.push(meta);
        const finished: boolean = i === ids.length - 1;
        task = this.cloneTask(
          task,
          finished ? 'done' : 'running',
          i + 1,
          okCount,
          [...runs],
          finished ? '' : `正在补第 ${i + 2}/${ids.length} 部…`,
          ''
        );
        this.updateLocalTask(task);
      }

      if (this.alive) {
        this.note = `自动补结束：成功 ${okCount}/${ids.length} 部`;
        this.loadHealth(false, true);
        this.loadQueue();
        this.loadVersions();
        this.loadJav();
      }
    } catch (err) {
      const e = err as BusinessError;
      this.note = `自动补提交失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  private async doAutoBatchFromPick(): Promise<void> {
    if (this.picked.length === 0) {
      this.note = '先勾选要补字幕的影片';
      return;
    }
    const ids: number[] = [...this.picked];
    this.picked = [];
    await this.runAutoIds(ids, 'chs');
  }

  private async cancelTask(t: AutoTask): Promise<void> {
    if (t.local === true) {
      this.localCancelFlag = true;
      this.note = '将在当前这部完成后停止';
      return;
    }
    try {
      await SubtitleOps.autoCancel(t.id);
      this.note = `已请求取消任务 #${t.id}`;
      await this.loadTasks(true);
    } catch (err) {
      const e = err as BusinessError;
      this.note = `取消失败：${safeText(e.message)}`;
    }
  }

  private runHasCaptcha(res: AutoResult): boolean {
    if (Array.isArray(res.source_status)) {
      for (let i = 0; i < res.source_status.length; i++) {
        if (res.source_status[i].captcha === true) {
          return true;
        }
      }
    }
    if (Array.isArray(res.errors)) {
      for (let i = 0; i < res.errors.length; i++) {
        const e: AutoErrorItem = res.errors[i];
        if (e !== undefined && e !== null) {
          if (e.captcha === true) {
            return true;
          }
          const msg: string = safeText(e.error);
          if (msg.indexOf('验证') >= 0 || msg.toLowerCase().indexOf('captcha') >= 0) {
            return true;
          }
        }
      }
    }
    const hint: string = safeText(res.javzimu_hint);
    return hint.indexOf('验证') >= 0;
  }

  // ---- 手动搜索队列交互 -----------------------------------------------

  private async doSearch(item: QueueItem): Promise<void> {
    this.busy = true;
    this.workingQueueId = item.metadata_id;
    this.note = '';
    try {
      const res = await SubtitleClient.search(item.metadata_id, '');
      const found: OnlineSubtitle[] =
        res.items === undefined || res.items === null ? [] : res.items;
      if (Array.isArray(res.errors)) {
        for (let i = 0; i < res.errors.length; i++) {
          if (res.errors[i].captcha === true) {
            this.javNeedCaptcha = true;
          }
        }
      }
      if (found.length === 0) {
        this.note = this.javNeedCaptcha
          ? '未搜到候选（JAV 字幕需填验证码，点右上角「JAV 验证」后再试）'
          : '各来源均未搜到候选，可稍后重试';
        this.queueCands = [];
      } else {
        await SubtitleOps.match(item.metadata_id, found as Object[]);
        await this.loadQueue();
        const fresh: QueueItem | undefined = (this.queue === null)
          ? undefined
          : this.queue.items.find((x: QueueItem) => x.metadata_id === item.metadata_id);
        this.queueCands = fresh === undefined ? [] : fresh.candidates;
        this.expandedQueueId = item.metadata_id;
        this.note = `找到 ${this.queueCands.length} 条候选，展开确认后下载`;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.note = `搜索失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
      this.workingQueueId = 0;
    }
  }

  private async doConfirm(item: QueueItem, cand: QueueCandidate): Promise<void> {
    if (cand.confidence < 40) {
      this.note = '匹配置信度 <40，不建议下载，请换一条高分候选';
      return;
    }
    this.busy = true;
    this.workingQueueId = item.metadata_id;
    this.note = '';
    try {
      const saved = await SubtitleClient.save(item.metadata_id, cand as OnlineSubtitle);
      await SubtitleOps.confirm(item.metadata_id, cand as Object,
        `${cand.provider}-${saved.subtitle_id}`);
      this.note = saved.kind === 'library'
        ? `已存入片库：${saved.files.join(' / ')}`
        : `已缓存（媒体目录不可写：${saved.reason}）`;
      this.expandedQueueId = 0;
      this.queueCands = [];
      this.loadQueue();
      this.loadVersions();
      this.loadHealth(false, true);
    } catch (err) {
      const e = err as BusinessError;
      this.note = `下载失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
      this.workingQueueId = 0;
    }
  }

  private async doQueueSet(item: QueueItem, action: string): Promise<void> {
    this.busy = true;
    try {
      await SubtitleOps.set(item.metadata_id, action);
      if (this.expandedQueueId === item.metadata_id) {
        this.expandedQueueId = 0;
        this.queueCands = [];
      }
      await this.loadQueue();
    } catch (err) {
      const e = err as BusinessError;
      this.note = `操作失败：${safeText(e.message)}`;
    } finally {
      this.busy = false;
    }
  }

  private activeQueueItems(): QueueItem[] {
    if (this.queue === null) {
      return [];
    }
    const out: QueueItem[] = [];
    for (let i = 0; i < this.queue.items.length; i++) {
      const st: string = this.queue.items[i].state;
      if (st !== 'failed' && st !== 'skipped') {
        out.push(this.queue.items[i]);
      }
    }
    return out;
  }

  private sunkQueueItems(): QueueItem[] {
    if (this.queue === null) {
      return [];
    }
    const out: QueueItem[] = [];
    for (let i = 0; i < this.queue.items.length; i++) {
      const st: string = this.queue.items[i].state;
      if (st === 'failed' || st === 'skipped') {
        out.push(this.queue.items[i]);
      }
    }
    return out;
  }

  private activeQueueCount(): number {
    return this.activeQueueItems().length;
  }

  private deadQueueCount(): number {
    return this.sunkQueueItems().length;
  }

  private async doClearDead(): Promise<void> {
    if (this.queue === null) {
      return;
    }
    this.busy = true;
    try {
      const res = await SubtitleOps.clearDead();
      this.autoSyncedFailIds.clear();
      await this.loadQueue();
      await this.loadHealth(false, true);
      this.showSunkQueue = false;
      this.note = `已重置 ${safeNum(res.removed)} 条沉底/跳过记录`;
    } catch (err) {
      let removed: number = 0;
      for (let i = 0; i < this.queue.items.length; i++) {
        const it: QueueItem = this.queue.items[i];
        if (it.state === 'failed' || it.state === 'skipped') {
          try {
            await SubtitleOps.set(it.metadata_id, 'remove');
            removed++;
          } catch (e) { /* 忽略单条失败 */ }
        }
      }
      this.autoSyncedFailIds.clear();
      await this.loadQueue();
      await this.loadHealth(false, true);
      this.showSunkQueue = false;
      this.note = `已重置 ${removed} 条沉底/跳过记录`;
    } finally {
      this.busy = false;
    }
  }

  // ---- JAV 手动验证码模块 ---------------------------------------------

  private async openCaptcha(): Promise<void> {
    this.showCaptcha = true;
    this.captchaLoading = true;
    this.captchaTip = '';
    this.captchaAnswer = '';
    try {
      const ch: SubCaptchaChallenge = await SubtitleOps.captchaChallenge();
      if (!this.alive) {
        return;
      }
      this.captchaId = ch.captchaId;
      this.captchaImage = ch.image;
      if (this.captchaImage.length > 0) {
        try {
          this.captchaCtrl.loadUrl(this.captchaPage());
        } catch (err) {
          // 首次挂载由 Web src 读取
        }
      } else {
        this.captchaTip = '服务端未返回验证码图片，请点「换一张」重试';
      }
    } catch (err) {
      const e = err as BusinessError;
      this.captchaTip = `获取验证码失败：${safeText(e.message)}`;
    } finally {
      this.captchaLoading = false;
    }
  }

  private async submitCaptcha(): Promise<void> {
    const ans: string = this.captchaAnswer.trim();
    if (ans.length === 0) {
      this.captchaTip = '请先输入图中的验证码字符';
      return;
    }
    this.captchaSubmitting = true;
    this.captchaTip = '';
    try {
      const res: SubCaptchaVerify = await SubtitleOps.captchaVerify(this.captchaId, ans);
      if (!this.alive) {
        return;
      }
      if (res.ok) {
        this.showCaptcha = false;
        this.javRemaining = safeNum(res.remaining);
        this.javNeedCaptcha = false;
        this.note = `JAV 验证通过（本会话约可搜 ${this.javRemaining} 次），现在自动补与搜候选都会纳入 JAV 源`;
        this.loadJav();
      } else {
        this.captchaTip = '验证码不正确，已自动刷新一张';
        await this.openCaptcha();
      }
    } catch (err) {
      const e = err as BusinessError;
      this.captchaTip = `验证失败：${safeText(e.message)}`;
    } finally {
      this.captchaSubmitting = false;
    }
  }

  private captchaPage(): string {
    const html: string = '<html><head><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<style>html,body{margin:0;padding:0;background:#fff;height:100%;display:flex;align-items:center;justify-content:center;overflow:hidden}' +
      'img{display:block;max-width:100%;max-height:100%;object-fit:contain}</style></head>' +
      `<body><img src="${this.captchaImage}"></body></html>`;
    return 'data:text/html;charset=utf-8,' + encodeURIComponent(html);
  }

  // ---- 文案与配色工具 -------------------------------------------------

  private statusLabel(status: string): string {
    if (status === 'none') {
      return '无字幕';
    }
    if (status === 'foreign') {
      return '只外文';
    }
    if (status === 'cn') {
      return '有中文';
    }
    return '内嵌';
  }

  private statusColor(status: string): ResourceStr {
    if (status === 'none') {
      return Theme.DANGER;
    }
    if (status === 'foreign') {
      return Theme.GOLD;
    }
    if (status === 'cn') {
      return Theme.ACCENT_INK;
    }
    return Theme.TEXT_DIM;
  }

  private queueStateLabel(state: string): string {
    if (state === 'queued') {
      return '待搜索';
    }
    if (state === 'matched') {
      return '有候选';
    }
    if (state === 'confirmed') {
      return '已下载';
    }
    if (state === 'skipped') {
      return '已跳过';
    }
    if (state === 'failed') {
      return '失败';
    }
    return '';
  }

  private taskStateLabel(t: AutoTask): string {
    const s: string = safeText(t.state);
    if (s === 'queued') {
      return '排队中';
    }
    if (s === 'running') {
      return `进行中 ${safeNum(t.done)}/${safeNum(t.total)}`;
    }
    if (s === 'done') {
      return `完成 · 成功 ${safeNum(t.ok_count)}/${safeNum(t.total)}`;
    }
    if (s === 'cancelled') {
      return `已停止 · 成功 ${safeNum(t.ok_count)}/${safeNum(t.total)}`;
    }
    if (s === 'interrupted') {
      return '已中断（可重提）';
    }
    if (s === 'failed') {
      return '失败';
    }
    return s;
  }

  private taskStateColor(t: AutoTask): ResourceStr {
    const s: string = safeText(t.state);
    if (s === 'done') {
      return safeNum(t.ok_count) > 0 ? '#8EE6B4' : Theme.TEXT_DIM;
    }
    if (s === 'running' || s === 'queued') {
      return Theme.GOLD;
    }
    if (s === 'failed' || s === 'interrupted') {
      return Theme.DANGER;
    }
    return Theme.TEXT_DIM;
  }

  private confColor(score: number): ResourceStr {
    if (score >= 80) {
      return Theme.ACCENT_INK;
    }
    if (score >= 60) {
      return Theme.GOLD;
    }
    return Theme.DANGER;
  }

  private actionLabel(action: string): string {
    if (action === 'added') {
      return '已下载';
    }
    if (action === 'replaced') {
      return '已替换';
    }
    if (action === 'removed') {
      return '已移除';
    }
    if (action === 'restored') {
      return '已恢复';
    }
    return action;
  }

  private scanBriefText(): string {
    const scanned: number = this.health === null ? 0 : this.health.meta.scanned;
    if (scanned === 0) {
      return '尚未扫描（首次进入自动预热）';
    }
    if (this.scanMode.length > 0) {
      const m: string = this.scanMode === 'full' ? '全量' : '增量';
      return `已扫 ${scanned} 部 · ${m}重扫 ${this.scanRescanned}/沿用 ${this.scanReused}`;
    }
    return `已扫 ${scanned} 部${this.health !== null && this.health.meta.stale ? '（较旧）' : ''}`;
  }

  private sourceSummaryText(res: AutoResult): string {
    if (!Array.isArray(res.source_status) || res.source_status.length === 0) {
      return this.runHasCaptcha(res) ? 'JAV 字幕源需要验证码（已跳过）' : '';
    }
    const parts: string[] = [];
    for (let i = 0; i < res.source_status.length; i++) {
      const st: AutoSourceStatus = res.source_status[i];
      if (!st.ok) {
        if (st.captcha === true) {
          parts.push(`${st.name}：需填验证码`);
        } else if (st.rate_limited === true) {
          parts.push(`${st.name}：限流跳过`);
        } else {
          parts.push(`${st.name}：${st.error.length > 0 ? st.error : '失败'}`);
        }
      } else {
        parts.push(`${st.name}：${st.found} 条`);
      }
    }
    return parts.join(' ｜ ');
  }

  private switchMainTab(key: string): void {
    this.tab = key;
    if (key === 'tasks' && !this.tasksLoadedOnce && this.serverTaskCapable) {
      this.loadTasks(true);
    } else if (key === 'history' && this.versions.length === 0) {
      this.loadVersions();
    }
  }

  // ---- 顶部主分段条 + 按需轻量横幅 -------------------------------------

  @Builder
  SegmentBar() {
    Row({ space: 4 }) {
      ForEach(this.mainTabs, (t: TabDef) => {
        Row({ space: 5 }) {
          Text(t.label)
            .fontSize(12.5)
            .fontWeight(this.tab === t.key ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.tab === t.key ? Theme.ACCENT_INK : Theme.TEXT_DIM)
          if (t.key === 'tasks' && this.activeTaskCount() > 0) {
            Text(`${this.activeTaskCount()}`)
              .fontSize(9.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.ON_ACCENT)
              .fontFeature('"tnum" 1')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .linearGradient(Theme.ctaGradient())
              .borderRadius(Theme.R_PILL)
          }
        }
        .layoutWeight(1)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.tab === t.key ? Theme.accentAlpha(0.22) : Color.Transparent)
        .border({
          width: this.tab === t.key ? 0.75 : 0,
          color: this.tab === t.key ? Theme.inkAlpha(0.52) : Color.Transparent
        })
        .borderRadius(Theme.R_PILL)
        .onClick(() => {
          this.switchMainTab(t.key);
        })
      }, (t: TabDef) => `seg-${t.key}-${this.tab === t.key ? 1 : 0}-${t.key === 'tasks' ? this.activeTaskCount() : 0}`)
    }
    .width('100%')
    .padding(4)
    .backgroundColor('#141114')
    .border({ width: 0.5, color: '#1AFFFFFF' })
    .borderRadius(Theme.R_PILL)
    .margin({ bottom: 10 })
  }

  @Builder
  LiveBanners() {
    Column({ space: 6 }) {
      if (this.scanning) {
        Column({ space: 4 }) {
          Row() {
            Text('正在扫描本地字幕…')
              .fontSize(11)
              .fontColor(Theme.ACCENT_INK)
              .layoutWeight(1)
            Text(this.scanTotal > 0 ? `${this.scanDone}/${this.scanTotal}` : '准备中')
              .fontSize(11)
              .fontColor(Theme.ACCENT_INK)
          }
          .width('100%')
          Progress({
            value: this.scanTotal > 0 ? this.scanDone : 0,
            total: this.scanTotal > 0 ? this.scanTotal : 100,
            type: ProgressType.Linear
          })
            .width('100%')
            .height(3)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
      }

      if (this.activeTopTask() !== null) {
        Row({ space: 8 }) {
          Text(`自动补进行中 ${safeNum(this.activeTopTask()!.done)}/${safeNum(this.activeTopTask()!.total)}（成功 ${safeNum(this.activeTopTask()!.ok_count)}）`)
            .fontSize(11)
            .fontColor(Theme.GOLD)
            .layoutWeight(1)
          if (this.tab !== 'tasks') {
            Text('看结果 ›')
              .fontSize(11)
              .fontColor(Theme.ACCENT_INK)
          } else {
            Text('停止')
              .fontSize(11)
              .fontColor(Theme.DANGER)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
              .onClick(() => {
                const top: AutoTask | null = this.activeTopTask();
                if (top !== null) {
                  this.cancelTask(top);
                }
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
        .onClick(() => {
          if (this.tab !== 'tasks') {
            this.tab = 'tasks';
            this.taskSub = 'merged';
          }
        })
      }

      if (this.note.length > 0) {
        Row({ space: 8 }) {
          Text(this.note)
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .layoutWeight(1)
            .maxLines(2)
          Text('✕')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ left: 6, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.note = '';
            })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(10)
      }
    }
    .width('100%')
    .margin({ bottom: (this.scanning || this.activeTopTask() !== null || this.note.length > 0) ? 8 : 0 })
  }

  // ---- Tab 1：选片补字幕 ----------------------------------------------

  @Builder
  FilterStatCell(key: string, label: string, color: ResourceStr) {
    Column({ space: 3 }) {
      Text(`${this.healthCount(key)}`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .fontFeature('"tnum" 1')
      Text(label)
        .fontSize(10.5)
        .fontColor(this.statusFilter === key ? Theme.TEXT : Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .backgroundColor(this.statusFilter === key ? Theme.accentAlpha(0.18) : Theme.CARD)
    .borderRadius(14)
    .border({
      width: this.statusFilter === key ? 0.75 : 0.5,
      color: this.statusFilter === key ? Theme.inkAlpha(0.52) : Theme.STROKE
    })
    .onClick(() => {
      this.toggleStatusFilter(key);
    })
  }

  @Builder
  PickTabView() {
    Column({ space: 0 }) {
      Row({ space: 6 }) {
        this.FilterStatCell('none', '无字幕', Theme.DANGER)
        this.FilterStatCell('foreign', '只外文', Theme.GOLD)
        this.FilterStatCell('cn', '有中文', Theme.ACCENT_INK)
        this.FilterStatCell('embedded', '内嵌', Theme.TEXT_DIM)
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row({ space: 6 }) {
        TextInput({ placeholder: '搜番号、片名', text: this.searchText })
          .layoutWeight(1)
          .height(36)
          .fontSize(12.5)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 11.5 })
          .caretColor(Theme.ACCENT_INK)
          .backgroundColor('#141114')
          .border({ width: 0.75, color: '#1EFFFFFF' })
          .borderRadius(18)
          .padding({ left: 10, right: 10 })
          .onChange((v: string) => {
            this.searchText = v;
          })
        if (this.searchText.length > 0) {
          Text('清词')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 8, right: 8, top: 7, bottom: 7 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(10)
            .onClick(() => {
              this.searchText = '';
            })
        }
      }
      .width('100%')
      .margin({ bottom: 6 })

      Row({ space: 6 }) {
        Text('选前10')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.pickFirst(10); })
        Text('选前30')
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.pickFirst(30); })
        Text('全选可补')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.pickFirst(0); })
        if (this.picked.length > 0) {
          Text('清空')
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            .onClick(() => { this.clearPicked(); })
        }
        Blank()
        if (this.healthSunkCount() > 0) {
          Text(this.hideSunkInPick ? `显示沉底(${this.healthSunkCount()})` : '隐藏沉底')
            .fontSize(10)
            .fontColor(this.hideSunkInPick ? Theme.ACCENT_INK : Theme.TEXT_FAINT)
            .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            .backgroundColor(this.hideSunkInPick ? Theme.CARD_HI : Color.Transparent)
            .borderRadius(8)
            .onClick(() => { this.hideSunkInPick = !this.hideSunkInPick; })
        }
        Text('全量重扫')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .padding({ left: 6, right: 2, top: 5, bottom: 5 })
          .onClick(() => {
            if (!this.scanning) {
              this.doScan(true);
            }
          })
      }
      .width('100%')
      .margin({ bottom: 6 })

      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.ACCENT)
          Text('正在读取全库字幕状态…')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.healthErr.length > 0 && this.healthItems.length === 0) {
        Column({ space: 10 }) {
          Text(`加载失败：${this.healthErr}`)
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
          Text('点此重试')
            .fontSize(12)
            .fontColor(Theme.ON_ACCENT)
            .padding({ left: 18, right: 18, top: 8, bottom: 8 })
            .backgroundColor(Color.Transparent)
            .linearGradient(Theme.ctaGradient())
            .border({ width: 0.75, color: '#38FFFFFF' })
            .borderRadius(Theme.R_PILL)
            .onClick(() => { this.bootLoad(); })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.filteredHealthItems().length > 0) {
        List({ space: 6 }) {
          ListItem() {
            Text(`${this.scanBriefText()} · 显示 ${this.filteredHealthItems().length} 部${
              this.healthSunkCount() > 0 ? `（失败/跳过 ${this.healthSunkCount()} 部已沉底）` : ''}`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ left: 2, bottom: 2 })
          }

          ForEach(this.filteredHealthItems(), (item: HealthItem) => {
            ListItem() {
              this.HealthRow(item)
            }
          }, (item: HealthItem) =>
            `h-${item.metadata_id}-${item.status}-${item.queue_state}-${this.healthFailBadge(item)}-${this.picked.indexOf(item.metadata_id) >= 0 ? 1 : 0}`)

          if (this.healthMore) {
            ListItem() {
              Row() {
                Text(this.loadingMore ? '加载中…' :
                  `加载更多（已加载 ${this.healthItems.length} / 共 ${this.health === null ? 0 : (this.health.meta.total !== undefined ? this.health.meta.total : this.health.meta.scanned)} 部）`)
                  .fontSize(12)
                  .fontColor(Theme.ACCENT_INK)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 11, bottom: 11 })
              }
              .width('100%')
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(12)
              .onClick(() => { this.loadMoreHealth(); })
            }
          }

          ListItem() {
            Column().height(6)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 8 }) {
          Text(this.scanning ? '正在扫描媒体目录，结果稍后显示…' : '当前筛选下没有影片')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
          if (this.statusFilter.length > 0 || this.searchText.length > 0) {
            Text('重置筛选')
              .fontSize(11)
              .fontColor(Theme.ACCENT_INK)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(Theme.CARD)
              .borderRadius(10)
              .onClick(() => {
                this.statusFilter = '';
                this.searchText = '';
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }

      // 吸底悬浮批量操作栏
      Column({ space: 6 }) {
        if (this.javNeedCaptcha && this.javRemaining <= 0) {
          Row({ space: 8 }) {
            Text('JAV 字幕源需验证码（未验证将只走其余源）')
              .fontSize(10.5)
              .fontColor(Theme.GOLD)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('填验证码 ›')
              .fontSize(10.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.GOLD)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#24FFD06B')
              .border({ width: 0.5, color: '#4DFFD06B' })
              .borderRadius(Theme.R_PILL)
              .onClick(() => { this.openCaptcha(); })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.CARD)
          .border({ width: 0.5, color: '#38FFD06B' })
          .borderRadius(12)
        }

        Row({ space: 8 }) {
          Row() {
            Text(this.picked.length > 0 ? `自动补字幕（已选 ${this.picked.length}）` : '勾选影片后自动补字幕')
              .fontSize(13)
              .fontColor(this.picked.length > 0 ? Theme.ON_ACCENT : Theme.TEXT_DIM)
              .fontWeight(FontWeight.Medium)
              .fontFeature('"tnum" 1')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 11, bottom: 11 })
          }
          .layoutWeight(1.5)
          .backgroundColor(this.picked.length > 0 ? Color.Transparent : Theme.CARD_HI)
          .linearGradient(this.picked.length > 0 ? Theme.ctaGradient() : { angle: 132, colors: [[Theme.CARD_HI, 0.0], [Theme.CARD_HI, 1.0]] })
          .border({ width: 0.75, color: this.picked.length > 0 ? '#38FFFFFF' : '#18FFFFFF' })
          .borderRadius(21)
          .onClick(() => {
            if (!this.busy) {
              this.doAutoBatchFromPick();
            }
          })

          Row() {
            Text('手动队列')
              .fontSize(12.5)
              .fontColor(this.picked.length > 0 ? Theme.TEXT : Theme.TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 11, bottom: 11 })
          }
          .layoutWeight(0.8)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .backgroundColor('#1EFFFFFF')
          .border({ width: 0.75, color: '#2AFFFFFF' })
          .borderRadius(21)
          .onClick(() => {
            if (!this.busy) {
              this.doEnqueue();
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ top: 8, bottom: Theme.pageBottomSafe() })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  HealthRow(item: HealthItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.canQueue(item)) {
          if (this.picked.indexOf(item.metadata_id) >= 0) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor([Theme.ON_ACCENT])
            }
            .width(20)
            .height(20)
            .borderRadius(10)
            .linearGradient(Theme.ctaGradient())
          } else {
            Row()
              .width(20)
              .height(20)
              .borderRadius(10)
              .border({ width: 1.25, color: '#3BFFFFFF' })
          }
        } else {
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(item.status === 'cn' ? Theme.ACCENT_INK : Theme.TEXT_FAINT)
        }
      }
      .width(26)
      .height(36)
      .onClick(() => { this.togglePick(item); })

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(item.number.length > 0 ? item.number : `#${item.metadata_id}`)
            .fontSize(13.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
            .maxLines(1)
          Text(this.statusLabel(item.status))
            .fontSize(9.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.statusColor(item.status))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(item.status === 'none'
              ? Theme.alphaOf(Theme.DANGER, 0.16)
              : (item.status === 'foreign' ? '#24FFD06B' : Theme.accentAlpha(0.16)))
            .border({
              width: 0.5,
              color: item.status === 'none'
                ? Theme.alphaOf(Theme.DANGER, 0.36)
                : (item.status === 'foreign' ? '#48FFD06B' : Theme.inkAlpha(0.36))
            })
            .borderRadius(Theme.R_PILL)
          if (this.healthFailBadge(item).length > 0) {
            Text(this.healthFailBadge(item))
              .fontSize(9.5)
              .fontColor(this.healthFailBadge(item) === '需验证码' ? Theme.GOLD : Theme.TEXT_DIM)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(Theme.R_PILL)
          } else if (item.queue_state.length > 0 && this.queueStateLabel(item.queue_state).length > 0) {
            Text(this.queueStateLabel(item.queue_state))
              .fontSize(9.5)
              .fontColor(Theme.TEXT_DIM)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(Theme.R_PILL)
          }
        }
        .width('100%')

        Text(item.title.length > 0 ? item.title : (item.detail.length > 0 ? item.detail : '—'))
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => { this.togglePick(item); })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.TEXT_FAINT])
        .padding({ left: 6, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          this.openDetail(item.metadata_id);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor(Theme.CARD)
    .border({ width: 0.75, color: this.picked.indexOf(item.metadata_id) >= 0 ? Theme.inkAlpha(0.42) : Theme.STROKE })
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
  }

  // ---- Tab 2：任务与结果（按影片合并结果 / 任务进度 / 手动队列） --------

  @Builder
  TasksTabView() {
    Column({ space: 8 }) {
      // 三态精简子切页
      Row({ space: 6 }) {
        Text(`按片结果 (${this.mergedFilms.length})`)
          .fontSize(11)
          .fontWeight(this.taskSub === 'merged' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.taskSub === 'merged' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
          .padding({ left: 9, right: 9, top: 6, bottom: 6 })
          .backgroundColor(this.taskSub === 'merged' ? Theme.CARD_HI : Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.taskSub = 'merged'; })

        Text(`任务 (${this.allTasks().length})`)
          .fontSize(11)
          .fontWeight(this.taskSub === 'progress' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.taskSub === 'progress' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
          .padding({ left: 9, right: 9, top: 6, bottom: 6 })
          .backgroundColor(this.taskSub === 'progress' ? Theme.CARD_HI : Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.taskSub = 'progress'; })

        Text(`手动队列 (${this.activeQueueCount()})`)
          .fontSize(11)
          .fontWeight(this.taskSub === 'manual' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.taskSub === 'manual' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
          .padding({ left: 9, right: 9, top: 6, bottom: 6 })
          .backgroundColor(this.taskSub === 'manual' ? Theme.CARD_HI : Theme.CARD)
          .borderRadius(10)
          .onClick(() => { this.taskSub = 'manual'; })

        Blank()

        if (this.taskSub === 'manual' && this.showSunkQueue && this.deadQueueCount() > 0) {
          Text('重置沉底')
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor(Theme.CARD)
            .borderRadius(10)
            .onClick(() => {
              if (!this.busy) {
                this.doClearDead();
              }
            })
        } else {
          Text('刷新')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 6, right: 2, top: 5, bottom: 5 })
            .onClick(() => {
              this.loadTasks(true);
              this.loadQueue();
              this.loadJav();
            })
        }
      }
      .width('100%')

      if (this.taskSub === 'merged') {
        this.MergedResultsView()
      } else if (this.taskSub === 'progress') {
        this.TaskProgressListView()
      } else {
        this.ManualQueueList()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 子视图 A：按影片合并的自动补结果（同片历次尝试归并到同一张卡）。 */
  @Builder
  MergedResultsView() {
    Column({ space: 8 }) {
      // 结果状态快筛：全部 / 已补上 / 未落库
      if (this.mergedFilms.length > 0) {
        Row({ space: 6 }) {
          Text(`全部 ${this.mergedFilms.length}`)
            .fontSize(10)
            .fontColor(this.resultFilter === '' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(this.resultFilter === '' ? Theme.accentAlpha(0.20) : Theme.CARD)
            .border({ width: this.resultFilter === '' ? 0.75 : 0.5, color: this.resultFilter === '' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
            .borderRadius(10)
            .onClick(() => {
              this.resultFilter = '';
              this.reasonCategory = '';
            })

          Text(`已补上 ${this.mergedOkCount()}`)
            .fontSize(10)
            .fontColor(this.resultFilter === 'ok' ? Theme.ACCENT_INK : Theme.ACCENT)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(this.resultFilter === 'ok' ? Theme.accentAlpha(0.20) : Theme.CARD)
            .border({ width: this.resultFilter === 'ok' ? 0.75 : 0.5, color: this.resultFilter === 'ok' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
            .borderRadius(10)
            .onClick(() => {
              this.resultFilter = 'ok';
              this.reasonCategory = '';
            })

          Text(`未落库 ${this.mergedFilms.length - this.mergedOkCount()}`)
            .fontSize(10)
            .fontColor(this.resultFilter === 'fail' ? Theme.ACCENT_INK : Theme.DANGER)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(this.resultFilter === 'fail' ? Theme.accentAlpha(0.20) : Theme.CARD)
            .border({ width: this.resultFilter === 'fail' ? 0.75 : 0.5, color: this.resultFilter === 'fail' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
            .borderRadius(10)
            .onClick(() => {
              this.resultFilter = 'fail';
              this.reasonCategory = '';
            })

          Blank()
          if (this.loadingResults) {
            Text('同步结果中…')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
          }
        }
        .width('100%')

        // 切到「未落库」时，给出按未落库原因分类的快筛条
        if (this.resultFilter === 'fail' && (this.mergedFilms.length - this.mergedOkCount()) > 0) {
          Scroll() {
            Row({ space: 6 }) {
              Text('全部原因')
                .fontSize(9)
                .fontColor(this.reasonCategory === '' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(this.reasonCategory === '' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === '' ? 0.75 : 0.5, color: this.reasonCategory === '' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                .borderRadius(8)
                .onClick(() => { this.reasonCategory = ''; })

              if (this.failCategoryCount('captcha') > 0) {
                Text(`需验证码 ${this.failCategoryCount('captcha')}`)
                  .fontSize(9)
                  .fontColor(this.reasonCategory === 'captcha' ? Theme.ACCENT_INK : Theme.GOLD)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(this.reasonCategory === 'captcha' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === 'captcha' ? 0.75 : 0.5, color: this.reasonCategory === 'captcha' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                  .borderRadius(8)
                  .onClick(() => { this.reasonCategory = this.reasonCategory === 'captcha' ? '' : 'captcha'; })
              }

              if (this.failCategoryCount('low_score') > 0) {
                Text(`分低未达标 ${this.failCategoryCount('low_score')}`)
                  .fontSize(9)
                  .fontColor(this.reasonCategory === 'low_score' ? Theme.ACCENT_INK : Theme.TEXT)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(this.reasonCategory === 'low_score' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === 'low_score' ? 0.75 : 0.5, color: this.reasonCategory === 'low_score' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                  .borderRadius(8)
                  .onClick(() => { this.reasonCategory = this.reasonCategory === 'low_score' ? '' : 'low_score'; })
              }

              if (this.failCategoryCount('no_cand') > 0) {
                Text(`无候选 ${this.failCategoryCount('no_cand')}`)
                  .fontSize(9)
                  .fontColor(this.reasonCategory === 'no_cand' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(this.reasonCategory === 'no_cand' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === 'no_cand' ? 0.75 : 0.5, color: this.reasonCategory === 'no_cand' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                  .borderRadius(8)
                  .onClick(() => { this.reasonCategory = this.reasonCategory === 'no_cand' ? '' : 'no_cand'; })
              }

              if (this.failCategoryCount('download') > 0) {
                Text(`下载失败 ${this.failCategoryCount('download')}`)
                  .fontSize(9)
                  .fontColor(this.reasonCategory === 'download' ? Theme.ACCENT_INK : Theme.DANGER)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(this.reasonCategory === 'download' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === 'download' ? 0.75 : 0.5, color: this.reasonCategory === 'download' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                  .borderRadius(8)
                  .onClick(() => { this.reasonCategory = this.reasonCategory === 'download' ? '' : 'download'; })
              }

              if (this.failCategoryCount('other') > 0) {
                Text(`其他 ${this.failCategoryCount('other')}`)
                  .fontSize(9)
                  .fontColor(this.reasonCategory === 'other' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(this.reasonCategory === 'other' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
            .border({ width: this.reasonCategory === 'other' ? 0.75 : 0.5, color: this.reasonCategory === 'other' ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
                  .borderRadius(8)
                  .onClick(() => { this.reasonCategory = this.reasonCategory === 'other' ? '' : 'other'; })
              }
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
      }

      if (this.filteredMergedFilms().length > 0) {
        List({ space: 8 }) {
          ForEach(this.filteredMergedFilms(), (film: MergedFilmResult) => {
            ListItem() {
              this.MergedFilmCard(film)
            }
          }, (film: MergedFilmResult) =>
            `mf-${film.itemId}-${film.succeeded ? 1 : 0}-${film.attempts.length}-${this.isFilmSkipped(film.itemId) ? 1 : 0}-${this.expandedFilmId === film.itemId ? 1 : 0}`)

          ListItem() {
            Column().height(Theme.pageBottomSafe())
          }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else if (this.loadingResults) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(Theme.ACCENT)
          Text('正在汇总各次任务结果…')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 8 }) {
          Text(this.mergedFilms.length > 0 ? '该筛选下没有影片' : '还没有自动补结果')
            .fontSize(13)
            .fontColor(Theme.TEXT)
          Text(this.mergedFilms.length > 0
            ? '切换上方「全部 / 已补上 / 未落库」查看其余结果。'
            : '在「选片补字幕」勾选影片并点「一键自动补」，结果会按影片合并汇总在这里。')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          if (this.mergedFilms.length === 0) {
            Text('去选片补字幕')
              .fontSize(12)
              .fontColor(Theme.ON_ACCENT)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(Color.Transparent)
              .linearGradient(Theme.ctaGradient())
              .border({ width: 0.75, color: '#38FFFFFF' })
              .borderRadius(Theme.R_PILL)
              .onClick(() => { this.tab = 'pick'; })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  MergedFilmCard(film: MergedFilmResult) {
    Column({ space: 7 }) {
      // 头部：番号 + 合并状态徽标 + 尝试次数 + 直达详情
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(film.number.length > 0 ? film.number : `#${film.itemId}`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
            Text(film.succeeded ? '已落库' : '未落库')
              .fontSize(9.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(film.succeeded ? '#8EE6B4' : Theme.DANGER)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor(film.succeeded ? '#1A45B075' : Theme.alphaOf(Theme.DANGER, 0.16))
              .border({ width: 0.5, color: film.succeeded ? '#4245B075' : Theme.alphaOf(Theme.DANGER, 0.36) })
              .borderRadius(Theme.R_PILL)
            if (film.attempts.length > 1) {
              Text(`试过 ${film.attempts.length} 次`)
                .fontSize(9)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(6)
            }
            if (!film.succeeded && this.isFilmSkipped(film.itemId)) {
              Text('已标无字幕')
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(6)
            }
          }
          if (film.title.length > 0) {
            Text(film.title)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => { this.openDetail(film.itemId); })

        Text('详情 ›')
          .fontSize(10)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => { this.openDetail(film.itemId); })
      }
      .width('100%')

      // 主结论区（合并后的最终有效结果）
      if (film.succeeded && film.bestAttempt.result.chosen !== null) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(`${film.bestAttempt.result.chosen.provider} · ${film.bestAttempt.result.chosen.name}`)
              .fontSize(11)
              .fontColor(Theme.TEXT)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${film.bestAttempt.result.chosen.score}分`)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.confColor(film.bestAttempt.result.chosen.score))
          }
          .width('100%')

          Text(`元数据 ${film.bestAttempt.result.chosen.meta} · 内容 ${film.bestAttempt.result.chosen.content}${
            film.bestAttempt.result.chosen.reasons.length > 0 ? ` · ${film.bestAttempt.result.chosen.reasons.join('；')}` : ''}`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(2)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor(Theme.BG_RAISED)
        .borderRadius(10)
      } else {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(this.failCategoryLabel(this.classifyFailReason(film)))
                .fontSize(9)
                .fontColor(film.hasCaptcha ? Theme.GOLD : Theme.DANGER)
                .fontWeight(FontWeight.Medium)
              Text(safeText(film.latestAttempt.result.reason).length > 0
                ? safeText(film.latestAttempt.result.reason) : '未找到达标字幕')
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .maxLines(2)
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .onClick(() => { this.openReasonPage(film); })

            Text('看原因 ›')
              .fontSize(10)
              .fontColor(Theme.ACCENT_INK)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .backgroundColor(Theme.accentAlpha(0.20))
              .border({ width: 0.75, color: Theme.inkAlpha(0.48) })
              .borderRadius(Theme.R_PILL)
              .onClick(() => { this.openReasonPage(film); })

            Text('重试')
              .fontSize(10)
              .fontColor(Theme.ACCENT_INK)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
              .onClick(() => {
                if (!this.busy) {
                  this.runAutoIds([film.itemId], 'chs');
                }
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 8 }) {
            Text(this.isFilmSkipped(film.itemId)
              ? '已沉底至队尾，不再参与「选前10/30」'
              : '确认暂无字幕时可沉底，避免反复排在队首')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.isFilmSkipped(film.itemId) ? '恢复待补' : '标无字幕')
              .fontSize(9)
              .fontColor(this.isFilmSkipped(film.itemId) ? Theme.ACCENT : Theme.TEXT_DIM)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(7)
              .onClick(() => {
                const label: string = film.number.length > 0 ? film.number : `#${film.itemId}`;
                if (this.isFilmSkipped(film.itemId)) {
                  this.restoreFilm(film.itemId, label);
                } else {
                  this.markFilmSkipped(film.itemId, label);
                }
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor(Theme.BG_RAISED)
        .borderRadius(10)
      }

      // 来源状态与验证码一键入口
      if (this.sourceSummaryText(film.latestAttempt.result).length > 0) {
        Row({ space: 6 }) {
          Text(this.sourceSummaryText(film.latestAttempt.result))
            .fontSize(9)
            .fontColor(film.hasCaptcha ? Theme.GOLD : Theme.TEXT_FAINT)
            .layoutWeight(1)
            .maxLines(2)
          if (film.hasCaptcha) {
            Text('填验证码')
              .fontSize(10)
              .fontColor(Theme.ACCENT_INK)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(Theme.accentAlpha(0.20))
              .border({ width: 0.75, color: Theme.inkAlpha(0.48) })
              .borderRadius(Theme.R_PILL)
              .onClick(() => { this.openCaptcha(); })
          }
        }
        .width('100%')
      }

      // 展开查看该片历次尝试 & 候选打分明细
      Row() {
        Text(this.expandedFilmId === film.itemId
          ? `收起详情 (${film.attempts.length} 次尝试) ▴`
          : (film.attempts.length > 1
            ? `展开全部 ${film.attempts.length} 次尝试与候选打分 ▾`
            : '展开候选打分明细 ▾'))
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.expandedFilmId = this.expandedFilmId === film.itemId ? 0 : film.itemId;
          })
        Blank()
        Text(film.latestAttempt.taskTime)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      if (this.expandedFilmId === film.itemId) {
        Column({ space: 6 }) {
          ForEach(film.attempts, (att: FilmAttempt, aIdx: number) => {
            this.AttemptDetailBox(film.itemId, att, aIdx)
          }, (att: FilmAttempt, aIdx: number) => `att-${film.itemId}-${att.taskId}-${aIdx}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  @Builder
  AttemptDetailBox(itemId: number, att: FilmAttempt, aIdx: number) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(att.taskId > 0 ? `任务 #${att.taskId}` : '本次会话')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_DIM)
        Text(att.taskTime)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(att.result.ok && att.result.chosen !== null
          ? `成功 · ${att.result.chosen.score}分`
          : '未落库')
          .fontSize(10)
          .fontColor(att.result.ok && att.result.chosen !== null ? Theme.ACCENT : Theme.DANGER)
      }
      .width('100%')

      if (!att.result.ok && safeText(att.result.reason).length > 0) {
        Text(safeText(att.result.reason))
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .maxLines(2)
      }

      if (Array.isArray(att.result.ranked) && att.result.ranked.length > 0) {
        ForEach(att.result.ranked, (c: AutoChosen, cIdx: number) => {
          Column({ space: 1 }) {
            Row({ space: 6 }) {
              Text(`${cIdx + 1}. ${c.provider} · ${c.name}`)
                .fontSize(10)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${c.score}分`)
                .fontSize(10)
                .fontColor(this.confColor(c.score))
            }
            .width('100%')
            Text(`元数据 ${c.meta} · 内容 ${c.content}${c.reasons.length > 0 ? ` · ${c.reasons.join('；')}` : ''}`)
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .maxLines(2)
              .width('100%')
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }, (c: AutoChosen, cIdx: number) => `rk-${itemId}-${att.taskId}-${aIdx}-${cIdx}-${c.provider}`)
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius(8)
  }

  /** 子视图 B：后台任务列表与进度管理（按需拉取单任务明细）。 */
  @Builder
  TaskProgressListView() {
    if (this.allTasks().length > 0) {
      List({ space: 8 }) {
        ForEach(this.allTasks(), (t: AutoTask) => {
          ListItem() {
            this.TaskSummaryCard(t)
          }
        }, (t: AutoTask) =>
          `ts-${t.id}-${t.state}-${t.done}-${t.ok_count}-${this.expandedTaskId === t.id ? 1 : 0}-${this.loadingTaskId === t.id ? 1 : 0}`)

        ListItem() {
          Column().height(Theme.pageBottomSafe())
        }
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(8)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    } else {
      Column({ space: 6 }) {
        Text('还没有后台自动补任务')
          .fontSize(13)
          .fontColor(Theme.TEXT)
        Text('在「选片补字幕」提交自动补后，每批任务的执行进度都会记录在这里。')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  TaskSummaryCard(t: AutoTask) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(`${t.id > 0 ? `任务 #${t.id}` : '本次会话'} · ${t.scope === 'batch' ? `批量 ${safeNum(t.total)} 部` : '单部'}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(safeText(t.created_at))
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.taskStateLabel(t))
          .fontSize(10)
          .fontColor(this.taskStateColor(t))
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
      }
      .width('100%')

      if (safeNum(t.total) > 0 && (t.state === 'running' || t.state === 'queued')) {
        Row({ space: 8 }) {
          Progress({ value: safeNum(t.done), total: safeNum(t.total), type: ProgressType.Linear })
            .layoutWeight(1)
            .height(5)
            .color(Theme.ACCENT)
            .backgroundColor(Theme.CARD_HI)
          Text(`${safeNum(t.done)}/${safeNum(t.total)}`)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
        }
        .width('100%')
      }

      if (safeText(t.error).length > 0) {
        Text(safeText(t.error))
          .fontSize(10)
          .fontColor(Theme.DANGER)
          .width('100%')
          .maxLines(2)
      }

      Row({ space: 10 }) {
        Text(this.expandedTaskId === t.id ? '收起本批清单 ▴' : '展开本批清单 ▾')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .onClick(() => {
            this.toggleExpandTask(t);
          })
        Blank()
        if (t.state === 'running' || t.state === 'queued') {
          Text('停止任务')
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
            .onClick(() => { this.cancelTask(t); })
        }
      }
      .width('100%')

      if (this.expandedTaskId === t.id) {
        if (this.loadingTaskId === t.id) {
          Text('正在读取本批明细…')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ top: 4, bottom: 4 })
        } else if (this.taskRunsOf(t).length === 0) {
          Text('本批暂无单部记录')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ top: 4, bottom: 4 })
        } else {
          Column({ space: 5 }) {
            ForEach(this.taskRunsOf(t), (run: AutoTaskRun, idx: number) => {
              Row({ space: 6 }) {
                Text(run.number.length > 0 ? run.number : `#${run.item_id}`)
                  .fontSize(11)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => { this.openDetail(run.item_id); })
                if (run.result.ok && run.result.chosen !== null) {
                  Text(`✓ ${run.result.chosen.score}分`)
                    .fontSize(10)
                    .fontColor(Theme.ACCENT_INK)
                } else {
                  Text('看原因')
                    .fontSize(10)
                    .fontColor(Theme.DANGER)
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .backgroundColor(Theme.CARD_HI)
                    .borderRadius(6)
                    .onClick(() => { this.openReasonFromRun(t, run); })
                }
                Text('详情 ›')
                  .fontSize(10)
                  .fontColor(Theme.ACCENT_INK)
                  .padding({ left: 4, right: 2, top: 3, bottom: 3 })
                  .onClick(() => { this.openDetail(run.item_id); })
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(8)
            }, (run: AutoTaskRun, idx: number) => `tr-${t.id}-${run.item_id}-${idx}`)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(16)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  /** 子视图 C：手动搜候选队列（默认只看活跃手动项，已沉底/跳过单独折叠查看）。 */
  @Builder
  ManualQueueList() {
    Column({ space: 8 }) {
      if (this.deadQueueCount() > 0) {
        Row({ space: 6 }) {
          Text(`待处理 (${this.activeQueueCount()})`)
            .fontSize(10)
            .fontColor(!this.showSunkQueue ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(!this.showSunkQueue ? Theme.accentAlpha(0.20) : Theme.CARD)
            .border({ width: !this.showSunkQueue ? 0.75 : 0.5, color: !this.showSunkQueue ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
            .borderRadius(10)
            .onClick(() => { this.showSunkQueue = false; })

          Text(`已沉底/无字幕 (${this.deadQueueCount()})`)
            .fontSize(10)
            .fontColor(this.showSunkQueue ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(this.showSunkQueue ? Theme.accentAlpha(0.20) : Theme.CARD)
            .border({ width: this.showSunkQueue ? 0.75 : 0.5, color: this.showSunkQueue ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
            .borderRadius(10)
            .onClick(() => { this.showSunkQueue = true; })
          Blank()
        }
        .width('100%')
      }

      if ((this.showSunkQueue ? this.sunkQueueItems() : this.activeQueueItems()).length > 0) {
        List({ space: 8 }) {
          ForEach(this.showSunkQueue ? this.sunkQueueItems() : this.activeQueueItems(), (item: QueueItem) => {
            ListItem() {
              this.QueueRow(item)
            }
          }, (item: QueueItem) =>
            `q-${this.showSunkQueue ? 1 : 0}-${item.metadata_id}-${item.state}-${item.candidates.length}-${this.expandedQueueId === item.metadata_id ? 1 : 0}-${this.workingQueueId === item.metadata_id && this.busy ? 1 : 0}`)

          ListItem() {
            Column().height(Theme.pageBottomSafe())
          }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 6 }) {
          Text(this.showSunkQueue ? '还没有已沉底或跳过的影片' : '手动队列是空的')
            .fontSize(13)
            .fontColor(Theme.TEXT)
          Text(this.showSunkQueue
            ? '自动补未落库或手动标为「无字幕」的影片会收纳在这里，可随时恢复。'
            : '想逐条查看在线候选再手动挑选时，在「选片补字幕」勾选后点「手动队列」。')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  QueueRow(item: QueueItem) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(item.number.length > 0 ? item.number : `#${item.metadata_id}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(`${this.queueStateLabel(item.state)} · 目标 ${item.lang}${item.state === 'confirmed' ? ` · ${item.source}` : ''}`)
            .fontSize(10)
            .fontColor(item.state === 'confirmed' ? Theme.ACCENT : Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => { this.openDetail(item.metadata_id); })

        Text('详情 ›')
          .fontSize(10)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => { this.openDetail(item.metadata_id); })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.workingQueueId === item.metadata_id && this.busy ? '处理中…' : '自动补')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(Theme.accentAlpha(0.20))
          .border({ width: 0.75, color: Theme.inkAlpha(0.48) })
          .borderRadius(Theme.R_PILL)
          .onClick(() => {
            if (!this.busy) {
              this.runAutoIds([item.metadata_id], item.lang);
            }
          })

        Text('搜候选')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(10)
          .onClick(() => {
            if (!this.busy) {
              this.doSearch(item);
            }
          })

        if (item.candidates.length > 0) {
          Text(this.expandedQueueId === item.metadata_id ? '收起候选' : `候选 (${item.candidates.length})`)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            .onClick(() => {
              if (this.expandedQueueId === item.metadata_id) {
                this.expandedQueueId = 0;
              } else {
                this.expandedQueueId = item.metadata_id;
                this.queueCands = item.candidates;
              }
            })
        }

        Blank()

        Text(item.state === 'skipped' || item.state === 'failed' ? '恢复待补' : '跳过')
          .fontSize(10)
          .fontColor(item.state === 'skipped' || item.state === 'failed' ? Theme.ACCENT : Theme.TEXT_DIM)
          .padding({ left: 4, right: 4, top: 4, bottom: 4 })
          .onClick(() => {
            if (item.state === 'skipped' || item.state === 'failed') {
              const label: string = item.number.length > 0 ? item.number : `#${item.metadata_id}`;
              this.restoreFilm(item.metadata_id, label);
            } else {
              this.doQueueSet(item, 'skip');
            }
          })

        Text('移除')
          .fontSize(10)
          .fontColor(Theme.DANGER)
          .padding({ left: 4, right: 2, top: 4, bottom: 4 })
          .onClick(() => { this.doQueueSet(item, 'remove'); })
      }
      .width('100%')

      if (this.expandedQueueId === item.metadata_id) {
        if (this.queueCands.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.queueCands, (cand: QueueCandidate, idx: number) => {
              this.CandidateRow(item, cand, idx)
            }, (cand: QueueCandidate, idx: number) =>
              `c-${item.metadata_id}-${idx}-${cand.provider}-${cand.name}-${cand.confidence}`)
          }
          .width('100%')
          .padding(8)
          .backgroundColor(Theme.BG_RAISED)
          .borderRadius(10)
        } else {
          Text('暂无候选，点「搜候选」查询在线源')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(16)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  CandidateRow(item: QueueItem, cand: QueueCandidate, idx: number) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(`${cand.provider} · ${cand.name}`)
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${cand.confidence}分`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.confColor(cand.confidence))
      }
      .width('100%')

      Progress({ value: cand.confidence, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(3)
        .color(this.confColor(cand.confidence))

      Row({ space: 8 }) {
        Text(cand.reasons.join(' · '))
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (cand.confidence >= 40) {
          Text('确认下载')
            .fontSize(10)
            .fontColor(Theme.ON_ACCENT)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(Color.Transparent)
            .linearGradient(Theme.ctaGradient())
            .border({ width: 0.5, color: '#38FFFFFF' })
            .borderRadius(Theme.R_PILL)
            .onClick(() => {
              if (!this.busy) {
                this.doConfirm(item, cand);
              }
            })
        } else {
          Text('分低不建议')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  // ---- Tab 3：下载记录（按影片合并） ------------------------------------

  @Builder
  HistoryTabView() {
    Column({ space: 8 }) {
      if (this.mergedVersions.length > 0) {
        Row({ space: 8 }) {
          Text(`共 ${this.mergedVersions.length} 部影片 · ${this.versions.length} 条记录`)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .layoutWeight(1)
          Text('刷新')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 6, right: 2, top: 3, bottom: 3 })
            .onClick(() => { this.loadVersions(); })
        }
        .width('100%')

        List({ space: 8 }) {
          ForEach(this.mergedVersions, (g: MergedVersionFilm) => {
            ListItem() {
              this.MergedVersionCard(g)
            }
          }, (g: MergedVersionFilm) =>
            `hv-${g.key}-${g.records.length}-${g.latest.id}-${g.number.length}-${this.expandedHistoryKey === g.key ? 1 : 0}`)

          ListItem() {
            Column().height(Theme.pageBottomSafe())
          }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 6 }) {
          Text(this.loading ? '正在加载记录…' : '还没有字幕下载或移除记录')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  MergedVersionCard(g: MergedVersionFilm) {
    Column({ space: 7 }) {
      // 头部：番号/主文件名 + 最新动作徽标 + 合并条数 + 直达详情
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(g.number.length > 0
              ? g.number
              : (g.latest.filename.length > 0 ? g.latest.filename : `影片 #${g.itemId}`))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.actionLabel(g.latest.action))
              .fontSize(9)
              .fontColor(g.latest.action === 'removed' ? Theme.DANGER : Theme.ACCENT)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(6)
            if (g.records.length > 1) {
              Text(`共 ${g.records.length} 条`)
                .fontSize(9)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(6)
            }
          }
          .width('100%')

          if (g.title.length > 0) {
            Text(g.title)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          if (g.itemId > 0) {
            this.openDetail(g.itemId);
          }
        })

        if (g.itemId > 0) {
          Text('详情 ›')
            .fontSize(10)
            .fontColor(Theme.ACCENT_INK)
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
            .onClick(() => { this.openDetail(g.itemId); })
        }
      }
      .width('100%')

      // 最新一条版本摘要
      Column({ space: 2 }) {
        Text(g.latest.filename.length > 0 ? g.latest.filename : `影片 #${g.itemId}`)
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${g.latest.source || '—'} · ${g.latest.provider || '—'} · ${g.latest.created_at}`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius(10)

      // 多条记录时可展开查看该片全部版本历史
      if (g.records.length > 1) {
        Row() {
          Text(this.expandedHistoryKey === g.key
            ? `收起历史记录 (${g.records.length} 条) ▴`
            : `展开全部 ${g.records.length} 条历史记录 ▾`)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.expandedHistoryKey = this.expandedHistoryKey === g.key ? '' : g.key;
            })
          Blank()
        }
        .width('100%')

        if (this.expandedHistoryKey === g.key) {
          Column({ space: 5 }) {
            ForEach(g.records, (v: VersionItem, rIdx: number) => {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text(v.filename.length > 0 ? v.filename : `记录 #${v.id}`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.actionLabel(v.action))
                    .fontSize(9)
                    .fontColor(v.action === 'removed' ? Theme.DANGER : Theme.ACCENT)
                }
                .width('100%')

                Text(`${v.source || '—'} · ${v.provider || '—'} · ${v.created_at}`)
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                  .maxLines(1)
                  .width('100%')
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(8)
            }, (v: VersionItem, rIdx: number) => `hvr-${g.key}-${v.id}-${rIdx}`)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  // ---- 独立全屏：未落库原因查看页 ---------------------------------------

  @Builder
  UnlandedReasonPage(film: MergedFilmResult) {
    Column({ space: 0 }) {
      Blank().height(this.barH() + 4)

      Scroll() {
        Column({ space: 10 }) {
          // 1) 影片概览卡
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text(film.number.length > 0 ? film.number : `#${film.itemId}`)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.failCategoryLabel(this.classifyFailReason(film)))
                .fontSize(10)
                .fontColor(film.hasCaptcha ? Theme.GOLD : Theme.DANGER)
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
            }
            .width('100%')

            if (film.title.length > 0) {
              Text(film.title)
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
                .maxLines(2)
                .width('100%')
            }

            Text(`共尝试 ${film.attempts.length} 次 · 最近一次 ${film.latestAttempt.taskTime || '—'}`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(14)

          // 2) 未落库核心结论卡（不截断完整原因）
          Column({ space: 8 }) {
            Text('未落库结论')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
              .width('100%')

            Text(safeText(film.latestAttempt.result.reason).length > 0
              ? safeText(film.latestAttempt.result.reason)
              : '自动补未找到达到落库阈值的中文字幕')
              .fontSize(13)
              .fontColor(Theme.DANGER)
              .width('100%')

            Row({ space: 6 }) {
              Text(`尝试候选 ${safeNum(film.latestAttempt.result.tried)} 条`)
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(8)
              Text(`进入打分 ${Array.isArray(film.latestAttempt.result.ranked) ? film.latestAttempt.result.ranked.length : 0} 条`)
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(8)
              Text(`报错 ${Array.isArray(film.latestAttempt.result.errors) ? film.latestAttempt.result.errors.length : 0} 条`)
                .fontSize(10)
                .fontColor((Array.isArray(film.latestAttempt.result.errors) && film.latestAttempt.result.errors.length > 0)
                  ? Theme.DANGER : Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(8)
            }
            .width('100%')

            if (film.hasCaptcha || safeText(film.latestAttempt.result.javzimu_hint).length > 0) {
              Row({ space: 8 }) {
                Text(safeText(film.latestAttempt.result.javzimu_hint).length > 0
                  ? safeText(film.latestAttempt.result.javzimu_hint)
                  : 'JAV 字幕源当前因验证码被拦截跳过；请先验证一次再重试。')
                  .fontSize(11)
                  .fontColor(Theme.GOLD)
                  .layoutWeight(1)
                Text('去填验证码 ›')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.GOLD)
                  .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                  .backgroundColor('#24FFD06B')
                  .border({ width: 0.75, color: '#4DFFD06B' })
                  .borderRadius(Theme.R_PILL)
                  .onClick(() => { this.openCaptcha(); })
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(10)
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(14)

          // 3) 各字幕源检索状态
          if (Array.isArray(film.latestAttempt.result.source_status) &&
            film.latestAttempt.result.source_status.length > 0) {
            Column({ space: 7 }) {
              Text('各字幕源检索状态')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT)
                .width('100%')

              ForEach(film.latestAttempt.result.source_status, (st: AutoSourceStatus, sIdx: number) => {
                Column({ space: 3 }) {
                  Row({ space: 8 }) {
                    Text(st.name.length > 0 ? st.name : st.provider)
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.TEXT)
                      .layoutWeight(1)
                    Text(st.ok
                      ? `正常 · 搜到 ${st.found} 条`
                      : (st.captcha ? '需填验证码' : (st.rate_limited ? '限流跳过' : '检索失败')))
                      .fontSize(10)
                      .fontColor(st.ok ? Theme.ACCENT : (st.captcha || st.rate_limited ? Theme.GOLD : Theme.DANGER))
                      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                      .backgroundColor(Theme.CARD_HI)
                      .borderRadius(6)
                  }
                  .width('100%')

                  if (!st.ok && st.error.length > 0) {
                    Text(st.error)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                      .width('100%')
                  }
                }
                .width('100%')
                .padding(9)
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(10)
              }, (st: AutoSourceStatus, sIdx: number) => `urs-${film.itemId}-${st.provider}-${sIdx}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }

          // 4) 下载与解析报错明细
          if (Array.isArray(film.latestAttempt.result.errors) &&
            film.latestAttempt.result.errors.length > 0) {
            Column({ space: 7 }) {
              Text(`下载与解析异常 (${film.latestAttempt.result.errors.length})`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT)
                .width('100%')

              ForEach(film.latestAttempt.result.errors, (er: AutoErrorItem, eIdx: number) => {
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(`${safeText(er.provider) || '未知源'} · ${this.errorKindLabel(er.kind)}`)
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(er.captcha || er.rate_limited ? Theme.GOLD : Theme.DANGER)
                      .layoutWeight(1)
                    if (er.captcha === true) {
                      Text('验证码')
                        .fontSize(9)
                        .fontColor(Theme.GOLD)
                    } else if (er.rate_limited === true) {
                      Text('429限流')
                        .fontSize(9)
                        .fontColor(Theme.GOLD)
                    }
                  }
                  .width('100%')

                  if (safeText(er.name).length > 0) {
                    Text(safeText(er.name))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                      .width('100%')
                  }
                  if (safeText(er.error).length > 0) {
                    Text(safeText(er.error))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                  }
                }
                .width('100%')
                .padding(9)
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(10)
              }, (er: AutoErrorItem, eIdx: number) => `ure-${film.itemId}-${eIdx}-${safeText(er.provider)}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }

          // 5) 候选打分与未达标原因明细
          if (Array.isArray(film.latestAttempt.result.ranked) &&
            film.latestAttempt.result.ranked.length > 0) {
            Column({ space: 7 }) {
              Text(`候选打分明细（落库阈值 60 分 · 共 ${film.latestAttempt.result.ranked.length} 条）`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT)
                .width('100%')

              ForEach(film.latestAttempt.result.ranked, (c: AutoChosen, cIdx: number) => {
                Column({ space: 5 }) {
                  Row({ space: 8 }) {
                    Text(`#${cIdx + 1} ${c.provider} · ${c.name}`)
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.TEXT)
                      .layoutWeight(1)
                      .maxLines(2)
                    Text(`${c.score}分`)
                      .fontSize(13)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.confColor(c.score))
                  }
                  .width('100%')

                  Progress({ value: c.score, total: 100, type: ProgressType.Linear })
                    .width('100%')
                    .height(4)
                    .color(this.confColor(c.score))
                    .backgroundColor(Theme.CARD_HI)

                  Text(`元数据 ${c.meta} 分 · 内容 ${c.content} 分${c.lang.length > 0 ? ` · 语言 ${c.lang}` : ''}`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT_DIM)
                    .width('100%')

                  if (this.formatChosenDetail(c.detail).length > 0) {
                    Text(this.formatChosenDetail(c.detail))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                  }

                  if (c.reasons.length > 0) {
                    Text(`评分依据：${c.reasons.join('；')}`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                      .width('100%')
                  }
                }
                .width('100%')
                .padding(10)
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(10)
              }, (c: AutoChosen, cIdx: number) => `urr-${film.itemId}-${cIdx}-${c.provider}-${c.score}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }

          // 6) 历次未落库尝试对比（多次尝试时展示）
          if (film.attempts.length > 1) {
            Column({ space: 7 }) {
              Text(`历次尝试记录 (${film.attempts.length} 次)`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT)
                .width('100%')

              ForEach(film.attempts, (att: FilmAttempt, aIdx: number) => {
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(att.taskId > 0 ? `任务 #${att.taskId}` : '本次会话')
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.TEXT)
                    Text(att.taskTime)
                      .fontSize(9)
                      .fontColor(Theme.TEXT_FAINT)
                    Blank()
                    Text(att.result.ok && att.result.chosen !== null
                      ? `成功 ${att.result.chosen.score}分` : '未落库')
                      .fontSize(10)
                      .fontColor(att.result.ok && att.result.chosen !== null ? Theme.ACCENT : Theme.DANGER)
                  }
                  .width('100%')

                  if (safeText(att.result.reason).length > 0) {
                    Text(safeText(att.result.reason))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                      .width('100%')
                  }
                  if (this.sourceSummaryText(att.result).length > 0) {
                    Text(this.sourceSummaryText(att.result))
                      .fontSize(9)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                  }
                }
                .width('100%')
                .padding(9)
                .backgroundColor(Theme.BG_RAISED)
                .borderRadius(10)
              }, (att: FilmAttempt, aIdx: number) => `ura-${film.itemId}-${att.taskId}-${aIdx}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }

          Column().height(8)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 底部操作栏
      Row({ space: 6 }) {
        Row() {
          Text(this.isFilmSkipped(film.itemId) ? '恢复待补' : '标无字幕')
            .fontSize(11)
            .fontColor(this.isFilmSkipped(film.itemId) ? Theme.ACCENT : Theme.TEXT_DIM)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
        }
        .layoutWeight(0.9)
        .backgroundColor(Theme.CARD)
        .borderRadius(16)
        .border({ width: 0.75, color: Theme.STROKE })
        .onClick(() => {
          const label: string = film.number.length > 0 ? film.number : `#${film.itemId}`;
          if (this.isFilmSkipped(film.itemId)) {
            this.restoreFilm(film.itemId, label);
          } else {
            this.markFilmSkipped(film.itemId, label);
          }
        })

        Row() {
          Text('转手动候选')
            .fontSize(11)
            .fontColor(Theme.TEXT)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
        }
        .layoutWeight(1)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(12)
        .onClick(() => {
          if (!this.busy) {
            this.sendFilmToManualQueue(film);
          }
        })

        Row() {
          Text('重新自动补')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ON_ACCENT)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
        }
        .layoutWeight(1.1)
        .backgroundColor(Color.Transparent)
        .linearGradient(Theme.ctaGradient())
        .border({ width: 0.75, color: '#38FFFFFF' })
        .borderRadius(21)
        .onClick(() => {
          if (!this.busy) {
            const id: number = film.itemId;
            this.inspectReasonFilm = null;
            this.runAutoIds([id], 'chs');
          }
        })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8, bottom: Theme.pageBottomSafe() })
      .backgroundColor(Theme.BG)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  // ---- JAV 手动验证码抽屉 ---------------------------------------------

  @Builder
  CaptchaSheet() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('JAV 字幕手动验证')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(this.javRemaining > 0
            ? `当前会话已验证（约剩 ${this.javRemaining} 次），如需刷新可重新提交`
            : '输一次验证码即可在本会话启用 JAV 字幕源（不绕过验证码）')
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('关闭')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 8, right: 4, top: 4, bottom: 4 })
          .onClick(() => { this.showCaptcha = false; })
      }
      .width('100%')

      Stack({ alignContent: Alignment.Center }) {
        if (this.captchaImage.length > 0) {
          Web({ src: this.captchaPage(), controller: this.captchaCtrl })
            .width('100%')
            .height(92)
            .backgroundColor('#FFFFFF')
            .borderRadius(10)
            .domStorageAccess(false)
            .javaScriptAccess(false)
        } else {
          Column() {
            Text(this.captchaLoading ? '正在加载验证码…' : '暂未获取到验证码图，点下方「换一张」')
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
          }
          .width('100%')
          .height(92)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(10)
        }
      }
      .width('100%')

      TextInput({ placeholder: '请输入图中的字符（不区分大小写）', text: this.captchaAnswer })
        .fontSize(14)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_FAINT)
        .height(42)
        .width('100%')
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.captchaAnswer = v;
        })
        .onSubmit(() => {
          if (!this.captchaSubmitting) {
            this.submitCaptcha();
          }
        })

      if (this.captchaTip.length > 0) {
        Text(this.captchaTip)
          .fontSize(11)
          .fontColor(Theme.GOLD)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('换一张')
          .fontSize(13)
          .height(40)
          .layoutWeight(1)
          .backgroundColor(Theme.CARD_HI)
          .fontColor(Theme.TEXT)
          .enabled(!this.captchaLoading && !this.captchaSubmitting)
          .onClick(() => { this.openCaptcha(); })

        Button(this.captchaSubmitting ? '验证中…' : '提交验证')
          .fontSize(13)
          .height(40)
          .layoutWeight(1.4)
          .backgroundColor(Color.Transparent)
          .linearGradient(Theme.ctaGradient())
          .border({ width: 0.75, color: '#38FFFFFF' })
          .borderRadius(20)
          .fontColor(Theme.ON_ACCENT)
          .enabled(!this.captchaLoading && !this.captchaSubmitting)
          .onClick(() => { this.submitCaptcha(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: Theme.pageBottomSafe() })
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  // ---- 页面根布局 -----------------------------------------------------

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.Top }) {
          SettingsAmbientGlow()

          Column() {
            Blank().height(this.barH() + 4)

            this.SegmentBar()
            this.LiveBanners()

            if (this.tab === 'pick') {
              this.PickTabView()
            } else if (this.tab === 'tasks') {
              this.TasksTabView()
            } else {
              this.HistoryTabView()
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.BG)

        if (this.inspectReasonFilm !== null) {
          ForEach([this.inspectReasonFilm], (film: MergedFilmResult) => {
            this.UnlandedReasonPage(film)
          }, (film: MergedFilmResult) =>
            `urp-${film.itemId}-${film.attempts.length}-${film.succeeded ? 1 : 0}-${this.isFilmSkipped(film.itemId) ? 1 : 0}`)
        }

        if (this.showCaptcha) {
          Column() {
            Blank()
              .layoutWeight(1)
              .onClick(() => { this.showCaptcha = false; })
            this.CaptchaSheet()
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
        }
      }
      .width('100%')
      .height('100%')
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
