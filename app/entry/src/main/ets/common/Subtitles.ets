import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { httpDelete, httpGet, httpPost, httpPut } from './Http';
import { Store } from './Store';

/**
 * 外挂字幕客户端。
 *
 * 所有来源（同目录 / 手机导入 / 手动 URL / 在线搜索）最终都拿到一个 subtitle_id，
 * 播放页只负责把 streamUrl() 交给 SubtitleTrack.uri()，不必关心字幕从哪来。
 */

export interface SubtitleItem {
  id: string;
  name: string;
  source: string;
  lang: string;
  size: number;
}

/** 在线搜索结果的一条。`ref` 是「怎么下载」的不透明凭证，原样交给 save()。 */
export interface OnlineSubtitle {
  provider: string;
  name: string;
  lang: string;
  ext: string;
  note: string;
  rank: number;
  ref: string;
  /** 服务端算好的落盘语言后缀（chs / cht / eng…），用来和「已下载」对号。 */
  lang_tag?: string;
}

export interface ProviderError {
  provider: string;
  error: string;
  /** 这个源是「要验证码」才失败的 —— 客户端据此给一个应用内验证入口。 */
  captcha: boolean;
}

export interface CaptchaChallenge {
  captchaId: string;
  /** data URI（image/svg+xml;base64,...），直接交给 Image 显示。 */
  image: string;
}

export interface CaptchaVerifyResult {
  ok: boolean;
  remaining: number;
}

export interface OnlineSubtitleResult {
  q: string;
  items: OnlineSubtitle[];
  total: number;
  errors: ProviderError[];
}

/** 已下载到资源库的（旁挂自己写的）。只有这些能被删。 */
export interface OwnedSubtitle {
  filename: string;
  source: string;
  provider: string;
  created_at: string;
  exists: boolean;
  /** 语言后缀（chs / cht / eng…）：用来和在线搜索结果对号，避免同一份出现两遍。 */
  lang?: string;
  /** 解析出来的 cue 条数（0 = 这个文件解析不出字幕，不是控件问题）。 */
  cues?: number;
  /** 首句，判断内容对不对/是不是乱码用。 */
  sample?: string;
  /** 服务端实际采用的编码（GBK / UTF-16LE / BIG5…），排查乱码用。 */
  encoding?: string;
}

/** 该片上次选的字幕（服务端记住的），播放页一打开就用它恢复。
 *
 * 只声明真正要用的字段：ArkTS 对同名属性要求「声明修饰符一致」，
 * 这里再写 `item_id` / `updated_at` 会和 OwnedListResult 撞上（编译期报错）。
 */

export interface OwnedListResult {
  item_id: number;
  items: OwnedSubtitle[];
  dirs: number;
  hint: string;
}

export interface SaveSubtitleResult {
  ok: boolean;
  /** library = 已写进视频目录（跨设备、Emby 也认）；cache = 卷不可写，只在服务端缓存。 */
  kind: string;
  files: string[];
  reason: string;
  subtitle_id: string;
  lang: string;
  name: string;
  /** 解析出的 cue 条数：0 说明这条字幕本身解析不出内容（不是控件问题）。 */
  cues?: number;
  /** 首句预览。 */
  sample?: string;
  /** 实际采用的编码。 */
  encoding?: string;
}

export interface LocalCandidate {
  name: string;
  size: number;
  lang: string;
}

/** 服务端记住的「这片用哪条字幕」。**只增可选字段**，别再新开同名 interface。 */
export interface SubtitleChoice {
  item_id: number;
  subtitle_id: string;
}

export interface SubtitleListResult {
  local: LocalCandidate[];
  cached: SubtitleItem[];
  choice: SubtitleChoice | null;
  providers: string[];
  /** 本地候选为空时的原因（没配路径映射 / 目录不可读 / 没有同名文件）。 */
  hint?: string;
}

export interface DedupSubtitleLists {
  local: LocalCandidate[];
  cached: SubtitleItem[];
}

function subExtLower(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot).toLowerCase() : '';
}

function subNormName(name: string): string {
  return name.trim().toLowerCase();
}

/**
 * 统一去重：下载后更名存到视频旁边的字幕、以及点过「同目录」进服务端缓存的字幕，
 * 都会同时出现在 `local` 与 `cached` 里（甚至 `cached` 里自带原名+同目录名两条）。
 *
 * 策略：
 *  1) `cached` 内部先按 id 去重，再按「规范化文件名」及「同体积 + 同后缀（更名落盘）」去重，
 *     冲突时优先保留当前激活的 `activeId`（否则保留更干净的本地/后入项）；
 *  2) `local` 里凡是已在 `cached` 出现（同名，或同体积 + 同后缀）的条目全部合并到 `cached` 那一条，
 *     避免一份字幕在列表里显示两遍。
 */
export function dedupSubtitles(
  local: LocalCandidate[],
  cached: SubtitleItem[],
  activeId: string = '',
  ownedNames: string[] = []
): DedupSubtitleLists {
  const rawCached: SubtitleItem[] = cached === undefined || cached === null ? [] : cached;
  const rawLocal: LocalCandidate[] = local === undefined || local === null ? [] : local;

  const byId: Map<string, SubtitleItem> = new Map<string, SubtitleItem>();
  for (let i = 0; i < rawCached.length; i++) {
    const it: SubtitleItem = rawCached[i];
    if (it === undefined || it === null || it.id.length === 0) {
      continue;
    }
    if (!byId.has(it.id)) {
      byId.set(it.id, it);
    }
  }

  const uniqueCached: SubtitleItem[] = [];
  const nameToIdx: Map<string, number> = new Map<string, number>();
  const sigToIdx: Map<string, number> = new Map<string, number>();
  const allById: SubtitleItem[] = Array.from(byId.values());
  for (let i = 0; i < allById.length; i++) {
    const it: SubtitleItem = allById[i];
    const nk: string = subNormName(it.name);
    const ext: string = subExtLower(it.name);
    const sk: string = it.size > 0 && ext.length > 0 ? `${it.size}|${ext}` : '';
    let existingIdx: number = -1;
    if (nk.length > 0 && nameToIdx.has(nk)) {
      existingIdx = nameToIdx.get(nk) as number;
    } else if (sk.length > 0 && sigToIdx.has(sk)) {
      existingIdx = sigToIdx.get(sk) as number;
    }
    if (existingIdx >= 0) {
      const prev: SubtitleItem = uniqueCached[existingIdx];
      // 若新项正是当前选中的字幕，优先保留它
      if (activeId.length > 0 && it.id === activeId && prev.id !== activeId) {
        uniqueCached[existingIdx] = it;
        if (nk.length > 0) {
          nameToIdx.set(nk, existingIdx);
        }
        if (sk.length > 0) {
          sigToIdx.set(sk, existingIdx);
        }
      }
      continue;
    }
    const idx: number = uniqueCached.length;
    uniqueCached.push(it);
    if (nk.length > 0) {
      nameToIdx.set(nk, idx);
    }
    if (sk.length > 0) {
      sigToIdx.set(sk, idx);
    }
  }

  const ownedSet: Set<string> = new Set<string>();
  for (let i = 0; i < ownedNames.length; i++) {
    const on: string = subNormName(ownedNames[i]);
    if (on.length > 0) {
      ownedSet.add(on);
    }
  }

  const uniqueLocal: LocalCandidate[] = [];
  const seenLocal: Set<string> = new Set<string>();
  for (let i = 0; i < rawLocal.length; i++) {
    const lc: LocalCandidate = rawLocal[i];
    if (lc === undefined || lc === null || lc.name.length === 0) {
      continue;
    }
    const nk: string = subNormName(lc.name);
    if (seenLocal.has(nk)) {
      continue;
    }
    const ext: string = subExtLower(lc.name);
    const sk: string = lc.size > 0 && ext.length > 0 ? `${lc.size}|${ext}` : '';
    // 已在 cached 里（同名 或 下载更名落盘同体积同后缀），或者已被 owned 记录且 cached 非空时合并去重
    if (nameToIdx.has(nk) || (sk.length > 0 && sigToIdx.has(sk))) {
      continue;
    }
    if (ownedSet.has(nk) && uniqueCached.length > 0) {
      continue;
    }
    seenLocal.add(nk);
    uniqueLocal.push(lc);
  }

  return { local: uniqueLocal, cached: uniqueCached };
}

/** 字幕来源的友好中文标签。 */
export function subSourceLabel(source: string): string {
  if (source === 'local') {
    return '同目录';
  }
  if (source === 'online') {
    return '片库 / 在线';
  }
  if (source === 'import') {
    return '手机导入';
  }
  if (source === 'url') {
    return '手动链接';
  }
  return source.length > 0 ? source : '外挂';
}

export class SubtitleClient {
  private static q(): string {
    return `token=${encodeURIComponent(Store.I.token)}`;
  }

  /** 给 mpv 的字幕地址。asVtt=true 时服务端把 SRT 转成 WebVTT 兜底。 */
  static streamUrl(id: string, asVtt: boolean): string {
    // 离线优先（2.5.6）：下载视频时字幕也存了一份，断网照样能挂上
    const local: string = Store.I.localSubtitle(id);
    if (local.length > 0) {
      return local;
    }
    const fmt: string = asVtt ? '&format=vtt' : '';
    return `${Store.I.user}/api/user/subtitle/${id}?${SubtitleClient.q()}${fmt}`;
  }

  static async list(itemId: number): Promise<SubtitleListResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles?item_id=${itemId}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as SubtitleListResult;
  }

  /** 把视频同目录的字幕读进服务端缓存，返回统一的 subtitle_id。 */
  static async loadLocal(itemId: number, name: string): Promise<SubtitleItem> {
    const url: string = `${Store.I.user}/api/user/subtitles/local` +
      `?item_id=${itemId}&name=${encodeURIComponent(name)}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 手机文件选择器 → 读字节 → base64 上传 → 服务端缓存。 */
  static async importFromPhone(ctx: common.UIAbilityContext, itemId: number): Promise<SubtitleItem> {
    const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    // 只列字幕后缀，省得在文件管理器里翻；不设置时鸿蒙默认显示全部文件。
    opts.fileSuffixFilters = ['.srt', '.ass', '.ssa', '.vtt', '.sub'];
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await view.select(opts);
    if (uris.length === 0) {
      throw new Error('未选择文件');
    }
    const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer;
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    const b64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
    const parts: string[] = uris[0].split('/');
    const name: string = parts.length > 0 ? parts[parts.length - 1] : 'phone-subtitle.srt';
    const url: string = `${Store.I.user}/api/user/subtitles/import?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ filename: name, content: b64 });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 手动字幕 URL：由服务端抓取（带超时与体积上限），不直接交给播放器。 */
  static async addUrl(subUrl: string, itemId: number): Promise<SubtitleItem> {
    const url: string = `${Store.I.user}/api/user/subtitles/url?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ url: subUrl, item_id: itemId });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 记住该片上次选的字幕。 */
  static async remember(itemId: number, subId: string): Promise<void> {
    const url: string = `${Store.I.user}/api/user/subtitles/choice?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ item_id: itemId, subtitle_id: subId });
    await httpPut(url, Store.I.token, body);
  }

  /**
   * 读回该片上次选的字幕（2.6.1.7）。
   *
   * 播放页一打开就该用它把字幕挂上 —— 以前只在「打开字幕面板」时才读，
   * 所以详情页选好了、进播放页还得再点一下面板才生效。
   */
  static async choice(itemId: number): Promise<SubtitleChoice> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/choice?item_id=${itemId}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as SubtitleChoice;
  }

  // ---- 在线搜索 ---------------------------------------------------------
  // 服务端并发查多个源（迅雷 / JAV字幕 / 字幕猫），单源失败只进 errors[]。

  static async search(itemId: number, q: string): Promise<OnlineSubtitleResult> {
    const url: string = `${Store.I.user}/api/user/subtitles/search` +
      `?item_id=${itemId}&q=${encodeURIComponent(q)}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as OnlineSubtitleResult;
  }

  /** 落盘：优先进视频同目录（跨设备、Emby 也认），写不进就落服务端缓存。 */
  static async save(itemId: number, item: OnlineSubtitle): Promise<SaveSubtitleResult> {
    const url: string = `${Store.I.user}/api/user/subtitles/save?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({
      item_id: itemId, provider: item.provider, ref: item.ref,
      name: item.name, lang: item.lang
    });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as SaveSubtitleResult;
  }

  /** 已下载到库里的（只列旁挂写的，用户自己的不会出现）。 */
  static async owned(itemId: number): Promise<OwnedSubtitle[]> {
    const url: string =
      `${Store.I.user}/api/user/subtitles/owned?item_id=${itemId}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    const parsed = JSON.parse(text) as OwnedListResult;
    return parsed.items === undefined || parsed.items === null ? [] : parsed.items;
  }

  static async removeOwned(itemId: number, filename: string): Promise<void> {
    const url: string = `${Store.I.user}/api/user/subtitles/owned` +
      `?item_id=${itemId}&name=${encodeURIComponent(filename)}&${SubtitleClient.q()}`;
    await httpDelete(url, Store.I.token);
  }

  /**
   * 验证码：服务端把 javzimu 的挑战转回来（SVG data URI），用户在我们的界面里输一次，
   * 之后窗口内（约 5 次搜索）都能用 —— 不用跳浏览器。
   */
  static async captcha(): Promise<CaptchaChallenge> {
    const url: string = `${Store.I.user}/api/user/subtitles/captcha?${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as CaptchaChallenge;
  }

  static async verifyCaptcha(captchaId: string, answer: string): Promise<CaptchaVerifyResult> {
    const url: string = `${Store.I.user}/api/user/subtitles/captcha?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ captchaId: captchaId, answer: answer });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as CaptchaVerifyResult;
  }
}
