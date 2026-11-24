import { httpGet, httpPost } from './Http';
import { Store } from './Store';

/**
 * 字幕自动化管理中心的客户端 API（2026-11-20 · 2026-11-24 稳定兼容版）。
 *
 * 为什么不写进 Subtitles.ets：那个文件属播放器冻结区（rules/20），字幕搜索/落盘/样式
 * 一律不动。本文件提供全库健康检查（支持分页）、队列管理、自动补任务列表与单任务详情、
 * JAV 会话验证码与版本历史接口；在线下载仍复用 SubtitleClient.save()。
 *
 * 稳定性约束：所有返回对象在此层统一做空值归一化，杜绝 `undefined.length` 等渲染期崩溃。
 */

export interface HealthItem {
  metadata_id: number;
  number: string;
  title: string;
  status: string;          // none / foreign / cn / embedded
  langs: string[];
  detail: string;
  checked_at: string;
  queue_state: string;
}

export interface HealthMeta {
  scanned: number;
  counts: Record<string, number>;
  checked_at: string;
  stale: boolean;
  scanning?: boolean;
  scan_done?: number;
  scan_total?: number;
  scan_error?: string;
  scan_mode?: string;          // 'incremental' | 'full'
  scan_reused?: number;
  scan_rescanned?: number;
  total?: number;
  returned?: number;
}

export interface HealthResult {
  items: HealthItem[];
  meta: HealthMeta;
  started?: boolean;
  states: string[];
  hint: string;
}

export interface QueueCandidate {
  provider: string;
  name: string;
  lang: string;
  ext: string;
  note: string;
  rank: number;
  ref: string;
  lang_tag?: string;
  confidence: number;
  reasons: string[];
}

export interface QueueItem {
  metadata_id: number;
  number: string;
  state: string;               // queued / matched / confirmed / skipped / failed
  lang: string;
  candidates: QueueCandidate[];
  chosen: QueueCandidate | null;
  source: string;
  version: string;
  note: string;
  created_at: string;
  updated_at: string;
}

export interface QueueResult {
  items: QueueItem[];
  counts: Record<string, number>;
}

export interface VersionItem {
  id: number;
  item_id: number;
  filename: string;
  source: string;
  provider: string;
  sid: string;
  action: string;              // added / removed / replaced / restored
  created_at: string;
}

export interface VersionResult {
  items: VersionItem[];
}

export interface SimpleResult {
  ok: boolean;
  removed?: number;
  added_count?: number;
  added?: number[];
  metadata_id?: number;
  action?: string;
  state?: string;
}

export interface AutoChosen {
  provider: string;
  name: string;
  lang: string;
  score: number;
  meta: number;
  content: number;
  reasons: string[];
  detail: Record<string, number>;
}

export interface AutoSourceStatus {
  provider: string;
  name: string;
  found: number;
  ok: boolean;
  error: string;
  captcha?: boolean;
  rate_limited?: boolean;
}

export interface AutoErrorItem {
  provider?: string;
  kind?: string;
  name?: string;
  error?: string;
  captcha?: boolean;
  rate_limited?: boolean;
}

export interface AutoResult {
  ok: boolean;
  auto?: boolean;
  dry_run?: boolean;
  reason?: string;
  tried?: number;
  score?: number;
  meta?: number;
  content?: number;
  reasons?: string[];
  detail?: Record<string, number>;
  chosen: AutoChosen | null;
  ranked?: AutoChosen[];
  errors?: AutoErrorItem[];
  source_status?: AutoSourceStatus[];
  javzimu_hint?: string;
  kind?: string;
  files?: string[];
  lang?: string;
  cues?: number;
  encoding?: string;
  task_id?: number;
  state?: string;
  total?: number;
  hint?: string;
}

export interface AutoTaskRun {
  item_id: number;
  number: string;
  title: string;
  result: AutoResult;
}

export interface AutoTask {
  id: number;
  state: string;               // queued / running / done / cancelled / failed / interrupted
  scope: string;               // single / batch
  total: number;
  done: number;
  ok_count: number;
  /** 注意：GET /auto/tasks 列表不返回此字段，归一化为空数组；详情由 GET /auto/task?id= 填充。 */
  results: AutoTaskRun[];
  note: string;
  error: string;
  created_at: string;
  updated_at: string;
  finished_at: string;
  local?: boolean;
}

export interface AutoTaskList {
  items: AutoTask[];
  active: number;
}

export interface JavStatus {
  verified: boolean;
  remaining: number;
  verified_at: string;
  last_error: string;
  need_captcha: boolean;
  hint: string;
}

export interface SubCaptchaChallenge {
  captchaId: string;
  image: string;
}

export interface SubCaptchaVerify {
  ok: boolean;
  remaining: number;
}

// ---- 防御性归一化工具（防止任意服务端缺字段在 ArkUI build 阶段抛异常） ----

function asStr(v: string | null | undefined): string {
  return typeof v === 'string' ? v : '';
}

function asNum(v: number | null | undefined): number {
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function asStrArr(v: string[] | null | undefined): string[] {
  if (!Array.isArray(v)) {
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < v.length; i++) {
    out.push(asStr(v[i]));
  }
  return out;
}

function normChosen(c: AutoChosen | null | undefined): AutoChosen | null {
  if (c === undefined || c === null) {
    return null;
  }
  return {
    provider: asStr(c.provider),
    name: asStr(c.name),
    lang: asStr(c.lang),
    score: asNum(c.score),
    meta: asNum(c.meta),
    content: asNum(c.content),
    reasons: asStrArr(c.reasons),
    detail: (c.detail !== undefined && c.detail !== null) ? c.detail : {}
  };
}

function normSourceStatuses(list: AutoSourceStatus[] | null | undefined): AutoSourceStatus[] {
  if (!Array.isArray(list)) {
    return [];
  }
  const out: AutoSourceStatus[] = [];
  for (let i = 0; i < list.length; i++) {
    const s = list[i];
    if (s === undefined || s === null) {
      continue;
    }
    out.push({
      provider: asStr(s.provider),
      name: asStr(s.name).length > 0 ? asStr(s.name) : asStr(s.provider),
      found: asNum(s.found),
      ok: s.ok === true,
      error: asStr(s.error),
      captcha: s.captcha === true,
      rate_limited: s.rate_limited === true
    });
  }
  return out;
}

function normErrorItems(list: AutoErrorItem[] | null | undefined): AutoErrorItem[] {
  if (!Array.isArray(list)) {
    return [];
  }
  const out: AutoErrorItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const e = list[i];
    if (e === undefined || e === null) {
      continue;
    }
    out.push({
      provider: asStr(e.provider),
      kind: asStr(e.kind),
      name: asStr(e.name),
      error: asStr(e.error),
      captcha: e.captcha === true,
      rate_limited: e.rate_limited === true
    });
  }
  return out;
}

function normAutoResult(r: AutoResult | null | undefined): AutoResult {
  if (r === undefined || r === null) {
    return { ok: false, chosen: null, ranked: [], source_status: [], errors: [], reasons: [] };
  }
  const rankedRaw = Array.isArray(r.ranked) ? r.ranked : [];
  const ranked: AutoChosen[] = [];
  for (let i = 0; i < rankedRaw.length; i++) {
    const nc = normChosen(rankedRaw[i]);
    if (nc !== null) {
      ranked.push(nc);
    }
  }
  return {
    ok: r.ok === true,
    auto: r.auto,
    dry_run: r.dry_run,
    reason: asStr(r.reason),
    tried: asNum(r.tried),
    score: asNum(r.score),
    meta: asNum(r.meta),
    content: asNum(r.content),
    reasons: asStrArr(r.reasons),
    detail: (r.detail !== undefined && r.detail !== null) ? r.detail : {},
    chosen: normChosen(r.chosen),
    ranked: ranked,
    errors: normErrorItems(r.errors),
    source_status: normSourceStatuses(r.source_status),
    javzimu_hint: asStr(r.javzimu_hint),
    kind: asStr(r.kind),
    files: asStrArr(r.files),
    lang: asStr(r.lang),
    cues: asNum(r.cues),
    encoding: asStr(r.encoding),
    task_id: r.task_id !== undefined ? asNum(r.task_id) : undefined,
    state: r.state !== undefined ? asStr(r.state) : undefined,
    total: r.total !== undefined ? asNum(r.total) : undefined,
    hint: r.hint !== undefined ? asStr(r.hint) : undefined
  };
}

function normTaskRuns(list: AutoTaskRun[] | null | undefined): AutoTaskRun[] {
  if (!Array.isArray(list)) {
    return [];
  }
  const out: AutoTaskRun[] = [];
  for (let i = 0; i < list.length; i++) {
    const x = list[i];
    if (x === undefined || x === null) {
      continue;
    }
    out.push({
      item_id: asNum(x.item_id),
      number: asStr(x.number),
      title: asStr(x.title),
      result: normAutoResult(x.result)
    });
  }
  return out;
}

function normTask(t: AutoTask | null | undefined): AutoTask {
  if (t === undefined || t === null) {
    return {
      id: 0, state: '', scope: 'single', total: 0, done: 0, ok_count: 0,
      results: [], note: '', error: '', created_at: '', updated_at: '', finished_at: ''
    };
  }
  return {
    id: asNum(t.id),
    state: asStr(t.state),
    scope: asStr(t.scope).length > 0 ? asStr(t.scope) : 'single',
    total: asNum(t.total),
    done: asNum(t.done),
    ok_count: asNum(t.ok_count),
    results: normTaskRuns(t.results),
    note: asStr(t.note),
    error: asStr(t.error),
    created_at: asStr(t.created_at),
    updated_at: asStr(t.updated_at),
    finished_at: asStr(t.finished_at),
    local: t.local === true
  };
}

function normHealthResult(raw: HealthResult | null | undefined): HealthResult {
  const itemsRaw = (raw !== undefined && raw !== null && Array.isArray(raw.items)) ? raw.items : [];
  const items: HealthItem[] = [];
  for (let i = 0; i < itemsRaw.length; i++) {
    const it = itemsRaw[i];
    if (it === undefined || it === null) {
      continue;
    }
    items.push({
      metadata_id: asNum(it.metadata_id),
      number: asStr(it.number),
      title: asStr(it.title),
      status: asStr(it.status),
      langs: asStrArr(it.langs),
      detail: asStr(it.detail),
      checked_at: asStr(it.checked_at),
      queue_state: asStr(it.queue_state)
    });
  }
  const m = (raw !== undefined && raw !== null && raw.meta !== undefined && raw.meta !== null) ? raw.meta : null;
  const meta: HealthMeta = {
    scanned: m !== null ? asNum(m.scanned) : items.length,
    counts: (m !== null && m.counts !== undefined && m.counts !== null) ? m.counts : {},
    checked_at: m !== null ? asStr(m.checked_at) : '',
    stale: m !== null && m.stale === true,
    scanning: m !== null && m.scanning === true,
    scan_done: m !== null ? asNum(m.scan_done) : 0,
    scan_total: m !== null ? asNum(m.scan_total) : 0,
    scan_error: m !== null ? asStr(m.scan_error) : '',
    scan_mode: m !== null ? asStr(m.scan_mode) : '',
    scan_reused: m !== null ? asNum(m.scan_reused) : 0,
    scan_rescanned: m !== null ? asNum(m.scan_rescanned) : 0,
    total: (m !== null && m.total !== undefined) ? asNum(m.total) : undefined,
    returned: (m !== null && m.returned !== undefined) ? asNum(m.returned) : undefined
  };
  return {
    items: items,
    meta: meta,
    started: raw !== undefined && raw !== null && raw.started === true,
    states: raw !== undefined && raw !== null ? asStrArr(raw.states) : [],
    hint: raw !== undefined && raw !== null ? asStr(raw.hint) : ''
  };
}

function normQueueResult(raw: QueueResult | null | undefined): QueueResult {
  const itemsRaw = (raw !== undefined && raw !== null && Array.isArray(raw.items)) ? raw.items : [];
  const items: QueueItem[] = [];
  for (let i = 0; i < itemsRaw.length; i++) {
    const q = itemsRaw[i];
    if (q === undefined || q === null) {
      continue;
    }
    const candsRaw = Array.isArray(q.candidates) ? q.candidates : [];
    const cands: QueueCandidate[] = [];
    for (let j = 0; j < candsRaw.length; j++) {
      const c = candsRaw[j];
      if (c === undefined || c === null) {
        continue;
      }
      cands.push({
        provider: asStr(c.provider),
        name: asStr(c.name),
        lang: asStr(c.lang),
        ext: asStr(c.ext),
        note: asStr(c.note),
        rank: asNum(c.rank),
        ref: asStr(c.ref),
        lang_tag: c.lang_tag !== undefined ? asStr(c.lang_tag) : undefined,
        confidence: asNum(c.confidence),
        reasons: asStrArr(c.reasons)
      });
    }
    items.push({
      metadata_id: asNum(q.metadata_id),
      number: asStr(q.number),
      state: asStr(q.state),
      lang: asStr(q.lang),
      candidates: cands,
      chosen: (q.chosen !== undefined && q.chosen !== null) ? q.chosen : null,
      source: asStr(q.source),
      version: asStr(q.version),
      note: asStr(q.note),
      created_at: asStr(q.created_at),
      updated_at: asStr(q.updated_at)
    });
  }
  return {
    items: items,
    counts: (raw !== undefined && raw !== null && raw.counts !== undefined && raw.counts !== null) ? raw.counts : {}
  };
}

export class SubtitleOps {
  private static q(): string {
    return `token=${encodeURIComponent(Store.I.token)}`;
  }

  static async health(refresh: boolean | 'full', limit: number = 0,
    offset: number = 0): Promise<HealthResult> {
    const flag: string = refresh === 'full' ? '&refresh=full'
      : (refresh ? '&refresh=1' : '');
    const page: string = limit > 0 ? `&limit=${limit}&offset=${offset}` : '';
    const url: string =
      `${Store.I.user}/api/user/subtitles/health?${SubtitleOps.q()}${flag}${page}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as HealthResult;
    return normHealthResult(raw);
  }

  static async queue(state: string): Promise<QueueResult> {
    const filter: string = state.length > 0
      ? `&state=${encodeURIComponent(state)}` : '';
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue?${SubtitleOps.q()}${filter}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as QueueResult;
    return normQueueResult(raw);
  }

  static async enqueue(ids: number[], lang: string): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue/add?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ ids: ids, lang: lang }))) as SimpleResult;
  }

  static async set(metadataId: number, action: string): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue/set?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ metadata_id: metadataId, action: action }))) as SimpleResult;
  }

  static async clearDead(): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue/clear-dead?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ states: ['failed', 'skipped'] }))) as SimpleResult;
  }

  static async match(metadataId: number, items: Object[]): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue/match?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ metadata_id: metadataId, items: items }))) as SimpleResult;
  }

  static async confirm(metadataId: number, chosen: Object, version: string): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/queue/confirm?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ metadata_id: metadataId, chosen: chosen, version: version }))) as SimpleResult;
  }

  static async autoDispatch(itemIds: number[], lang: string, perSource: number,
    minScore: number): Promise<AutoResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/auto?${SubtitleOps.q()}`;
    const firstId: number = itemIds.length > 0 ? itemIds[0] : 0;
    const raw = JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({
        item_ids: itemIds,
        item_id: firstId,
        lang: lang,
        per_source: perSource,
        min_score: minScore
      }))) as AutoResult;
    return normAutoResult(raw);
  }

  static async autoSingle(itemId: number, lang: string, perSource: number,
    minScore: number): Promise<AutoResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/auto?${SubtitleOps.q()}`;
    const raw = JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({
        item_id: itemId,
        lang: lang,
        per_source: perSource,
        min_score: minScore
      }))) as AutoResult;
    return normAutoResult(raw);
  }

  /** 任务摘要列表（不含 results，需要逐部结果时调用 autoTask(id)）。 */
  static async autoTasks(limit: number = 30): Promise<AutoTaskList> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/auto/tasks?${SubtitleOps.q()}&limit=${limit}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as AutoTaskList;
    const itemsRaw = (raw !== undefined && raw !== null && Array.isArray(raw.items)) ? raw.items : [];
    const items: AutoTask[] = [];
    for (let i = 0; i < itemsRaw.length; i++) {
      items.push(normTask(itemsRaw[i]));
    }
    return { items: items, active: raw !== undefined && raw !== null ? asNum(raw.active) : 0 };
  }

  /** 单任务完整详情（含 results 逐部结果）。 */
  static async autoTask(id: number): Promise<AutoTask> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/auto/task?${SubtitleOps.q()}&id=${id}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as AutoTask;
    return normTask(raw);
  }

  static async autoCancel(id: number): Promise<SimpleResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/auto/task/cancel?${SubtitleOps.q()}`;
    return JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ task_id: id }))) as SimpleResult;
  }

  static async javStatus(): Promise<JavStatus> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/javzimu/status?${SubtitleOps.q()}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as JavStatus;
    return {
      verified: raw !== undefined && raw !== null && raw.verified === true,
      remaining: raw !== undefined && raw !== null ? asNum(raw.remaining) : 0,
      verified_at: raw !== undefined && raw !== null ? asStr(raw.verified_at) : '',
      last_error: raw !== undefined && raw !== null ? asStr(raw.last_error) : '',
      need_captcha: raw !== undefined && raw !== null && raw.need_captcha === true,
      hint: raw !== undefined && raw !== null ? asStr(raw.hint) : ''
    };
  }

  static async captchaChallenge(): Promise<SubCaptchaChallenge> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/captcha?${SubtitleOps.q()}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as SubCaptchaChallenge;
    return {
      captchaId: raw !== undefined && raw !== null ? asStr(raw.captchaId) : '',
      image: raw !== undefined && raw !== null ? asStr(raw.image) : ''
    };
  }

  static async captchaVerify(captchaId: string, answer: string): Promise<SubCaptchaVerify> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/captcha?${SubtitleOps.q()}`;
    const raw = JSON.parse(await httpPost(url, Store.I.token,
      JSON.stringify({ captchaId: captchaId, answer: answer }))) as SubCaptchaVerify;
    return {
      ok: raw !== undefined && raw !== null && raw.ok === true,
      remaining: raw !== undefined && raw !== null ? asNum(raw.remaining) : 0
    };
  }

  static async versions(itemId: number): Promise<VersionResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/versions?item_id=${itemId}&${SubtitleOps.q()}`;
    const raw = JSON.parse(await httpGet(url, Store.I.token)) as VersionResult;
    const itemsRaw = (raw !== undefined && raw !== null && Array.isArray(raw.items)) ? raw.items : [];
    const items: VersionItem[] = [];
    for (let i = 0; i < itemsRaw.length; i++) {
      const v = itemsRaw[i];
      if (v === undefined || v === null) {
        continue;
      }
      items.push({
        id: asNum(v.id),
        item_id: asNum(v.item_id),
        filename: asStr(v.filename),
        source: asStr(v.source),
        provider: asStr(v.provider),
        sid: asStr(v.sid),
        action: asStr(v.action),
        created_at: asStr(v.created_at)
      });
    }
    return { items: items };
  }
}
