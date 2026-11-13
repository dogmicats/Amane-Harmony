import { request } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, hash, picker } from '@kit.CoreFileKit';
import { httpGet, httpGetFresh } from './Http';
import { Store } from './Store';
import { BuildConfig } from './BuildConfig';

/** 偏好键：更新清单地址（留空 = 自动按下面的源顺序找）。 */
const PREF_MANIFEST: string = 'update_manifest_url';
/** 下载目录（沙箱内）。 */
const SUB_DIR: string = 'update';

/**
 * 发布版（public 通道）的权威清单在 GitHub，**两处互为备份**：
 * - Release latest asset：固定指针，永远不带版本号，latest 由 GitHub 判定；
 * - 仓库 main 分支的 updates/update.json：raw / jsDelivr 都能读，主源不通时回退。
 * 地址里绝不能写版本号，否则旧版 App 就永远指向那一份旧清单了。
 */
const GITHUB_REPO: string = 'dogmicats/Amane-Harmony';
const MANIFEST_RELEASE: string =
  `https://github.com/${GITHUB_REPO}/releases/latest/download/update.json`;
const MANIFEST_RAW: string =
  `https://raw.githubusercontent.com/${GITHUB_REPO}/main/updates/update.json`;
const MANIFEST_CDN: string =
  `https://cdn.jsdelivr.net/gh/${GITHUB_REPO}@main/updates/update.json`;

/** 一个源都没读到时给用户的排查提示（人话，不堆错误码）。 */
const CHECK_HINT: string =
  '先用手机浏览器打开同一个地址：打不开就是网络、防火墙或那台电脑没开机，不是 App 的问题。' +
  '也可以点下面「恢复默认」，让 App 自己按顺序去 GitHub / 服务端找。' +
  '若某行是 404，那是地址路径写错了，或服务端还没实现 /api/user/update/manifest。';

/** 最新客户端包的信息（来自清单）。 */
export interface UpdateInfo {
  version: string;
  code: number;
  url: string;
  size: number;
  /** 小写十六进制；空串 = 清单没给，**不下载**（宁可不装也不装来路不明的包）。 */
  sha256: string;
  notes: string;
}

/** 一次检查的全部结果，页面直接拿去渲染，不存全局状态。 */
export interface CheckResult {
  ok: boolean;
  /** 失败原因（ok=false 时有值）。 */
  message: string;
  /** 实际用的清单地址（界面上要显示，方便自己改）。 */
  manifestUrl: string;
  clientNow: string;
  serverNow: string;
  /** 清单里的最新客户端；没有就是空串。 */
  clientLatest: string;
  clientNotes: string;
  /** 清单里的最新服务端；没有就是空串。 */
  serverLatest: string;
  serverNotes: string;
  /** 服务端怎么升（清单 `server.howto` 给的自定义步骤；空串 = 用客户端内置默认步骤）。 */
  serverHowto: string;
  /** 客户端能不能升。 */
  clientUpdatable: boolean;
  /** 服务端能不能升（只提示，不由客户端动手）。 */
  serverUpdatable: boolean;
  /** 待下载包的直链 / 体积 / 校验值。 */
  url: string;
  size: number;
  sha256: string;
  /** 清单自己声明的发布时间（用来判断这份清单有多新）。 */
  publishedAt: string;
  /** 本次检查的本机时间。 */
  checkedAt: string;
  /** 实际读到清单的来源名。 */
  sourceLabel: string;
  /** 是否发生过回退（第一个源没读到，用了后面的源）。 */
  fellBack: boolean;
  /** 每个源的尝试结果，失败时原样给用户看。 */
  attempts: string;
  /** 一个源都没读到时的排查提示。 */
  hint: string;
}

export interface DownloadResult {
  ok: boolean;
  message: string;
  path: string;
}

function emptyInfo(): UpdateInfo {
  return { version: '', code: 0, url: '', size: 0, sha256: '', notes: '' };
}

function emptyCheck(): CheckResult {
  return {
    ok: false, message: '', manifestUrl: '',
    clientNow: BuildConfig.APP_VERSION, serverNow: '', clientLatest: '', clientNotes: '',
    serverLatest: '', serverNotes: '', serverHowto: '', clientUpdatable: false, serverUpdatable: false,
    url: '', size: 0, sha256: '',
    publishedAt: '', checkedAt: '', sourceLabel: '', fellBack: false, attempts: '', hint: ''
  };
}

/** 本机时间 YYYY-MM-DD HH:MM，用来显示「这次是什么时候检查的」。 */
function stamp(): string {
  const d = new Date();
  const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 把 `2.5.7.8` 拆成数字数组；非法段按 0。 */
function verParts(v: string): number[] {
  const out: number[] = [];
  const seg: string[] = v.split('.');
  for (let i = 0; i < seg.length && i < 4; i++) {
    const n: number = Number(seg[i]);
    out.push(n >= 0 ? n : 0);
  }
  while (out.length < 4) {
    out.push(0);
  }
  return out;
}

/** a 比 b 新返回 true（逐段比，缺位补 0）。 */
export function isNewer(a: string, b: string): boolean {
  if (a.length === 0 || b.length === 0) {
    return false;
  }
  const x: number[] = verParts(a);
  const y: number[] = verParts(b);
  for (let i = 0; i < 4; i++) {
    if (x[i] > y[i]) {
      return true;
    }
    if (x[i] < y[i]) {
      return false;
    }
  }
  return false;
}

function str(o: Record<string, Object>, k: string): string {
  const v = o[k];
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}

function num(o: Record<string, Object>, k: string): number {
  const v = o[k];
  if (v === undefined || v === null) {
    return 0;
  }
  const n: number = Number(`${v}`);
  return n >= 0 ? n : 0;
}

/**
 * 更新检查与拉取（2.5.7）。
 *
 * **平台事实**：HarmonyOS 的公开 SDK 里没有第三方可用的安装接口
 * （`@ohos.bundle.installer` 不在 SDK 里，`INSTALL_BUNDLE` 是系统应用级权限），
 * 侧载的 hap 无法由 App 自己静默安装。所以本模块只做到：
 * **检查 → 下载 → sha256 校验 → 另存到手机**，最后一步安装由用户点系统里那个文件完成。
 *
 * 清单来源（按顺序试，第一个读到就用）：
 *   手填地址（测试版用）→ public 通道的 GitHub Release latest / 仓库 raw / jsDelivr
 *   → 自有服务端 `/api/user/update/manifest`（契约见 `docs/ai-context/API_CONTRACTS.md`）。
 * 全失败也不抛，返回「每个源分别怎么了」+ 一句能照着做的排查提示。
 *
 * **不要把 token 发给外部源**：只有 URL 以自己配置的服务端地址开头时才带 Bearer，
 * 否则一份私人凭据会被送到 GitHub / 别人填的任意主机上。
 */
export class Updater {
  private static ctx: common.UIAbilityContext | undefined = undefined;
  private static live: request.agent.Task | undefined = undefined;

  static init(ctx: common.UIAbilityContext): void {
    Updater.ctx = ctx;
  }

  static defaultManifestUrl(): string {
    return `${Store.I.user}/api/user/update/manifest`;
  }

  /** 首选项里手填的地址（空串 = 没填）。 */
  static customManifestUrl(): string {
    return Store.I.prefString(PREF_MANIFEST, '');
  }

  static manifestUrl(): string {
    const custom: string = Updater.customManifestUrl();
    return custom.length > 0 ? custom : Updater.defaultManifestUrl();
  }

  /** 候选源。public 通道把 GitHub 的两个位置都排上，互为备份。 */
  static sources(): string[] {
    const out: string[] = [];
    const custom: string = Updater.customManifestUrl();
    if (custom.length > 0) {
      out.push(custom);
    }
    if (BuildConfig.CHANNEL === 'public') {
      out.push(MANIFEST_RELEASE, MANIFEST_RAW, MANIFEST_CDN);
    }
    out.push(Updater.defaultManifestUrl());
    return out;
  }

  private static labelOf(u: string): string {
    if (u === MANIFEST_RELEASE) {
      return 'GitHub Release（主源）';
    }
    if (u === MANIFEST_RAW) {
      return 'GitHub 仓库镜像';
    }
    if (u === MANIFEST_CDN) {
      return 'GitHub CDN 镜像';
    }
    if (u === Updater.defaultManifestUrl()) {
      return '自有服务端';
    }
    return '手填地址';
  }

  /** 服务端当前版本（`/ping` 就回这个；老服务端没有该字段时为空串）。 */
  static async serverVersion(): Promise<string> {
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/ping`, Store.I.token);
      const o = JSON.parse(raw) as Record<string, Object>;
      return str(o, 'version');
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] update ping: ${e.code} ${e.message}`);
      return '';
    }
  }

  /**
   * 清单里「服务端怎么升」的步骤：支持 `howto` 一个多行字符串，也支持 `steps` 字符串数组
   * （数组更清楚，页面会按行渲染）。都没有就返回空串，页面用内置默认步骤。
   */
  private static readHowto(s: Record<string, Object>): string {
    const direct: string = str(s, 'howto');
    if (direct.length > 0) {
      return direct;
    }
    const arr = s['steps'];
    if (arr === undefined || arr === null) {
      return '';
    }
    try {
      const list = arr as string[];
      const out: string[] = [];
      for (let i = 0; i < list.length; i++) {
        out.push(`${list[i]}`);
      }
      return out.join('\n');
    } catch (err) {
      return '';
    }
  }

  /**
   * 读清单并比对。多源串行回退；网络/格式/缺字段全部降级成 ok=false + 原因，不抛。
   *
   * 每次检查都重新取，**不缓存、不落地**：App 里没有清单，只有一个固定地址，
   * 所以「清单有多新」等于「最后发布那份有多新」，跟 App 自己是哪一版无关。
   */
  static async check(): Promise<CheckResult> {
    const out: CheckResult = emptyCheck();
    out.checkedAt = stamp();
    out.serverNow = await Updater.serverVersion();

    const urls: string[] = Updater.sources();
    const tried: string[] = [];
    const base: string = Store.I.user;
    let raw: string = '';
    let used: string = '';
    for (let i = 0; i < urls.length; i++) {
      const u: string = urls[i];
      const label: string = Updater.labelOf(u);
      // 只给自己的服务端带 token，别把凭据送给 GitHub 或手填的任意主机
      const token: string = base.length > 0 && u.indexOf(base) === 0 ? Store.I.token : '';
      try {
        const text: string = await httpGetFresh(u, token);
        JSON.parse(text);  // 先确认是 JSON，别把代理/门户页的 HTML 当清单
        raw = text;
        used = u;
        tried.push(`${label}：读到`);
        break;
      } catch (err) {
        const e = err as BusinessError;
        console.info(`[amane] update manifest ${label}: ${e.code} ${e.message}`);
        tried.push(`${label}：${e.message}`);
      }
    }
    out.attempts = tried.join('\n');
    if (used.length === 0) {
      out.manifestUrl = urls.length > 0 ? urls[0] : '';
      out.sourceLabel = '没读到';
      // 明细放在页面单独的 attempts 行里，这里只给一句结论，别重复渲染
      out.message = '清单一个源都没读到';
      out.hint = CHECK_HINT;
      return out;
    }
    out.manifestUrl = used;
    out.sourceLabel = Updater.labelOf(used);
    out.fellBack = urls.length > 1 && used !== urls[0];

    try {
      const o = JSON.parse(raw) as Record<string, Object>;
      out.publishedAt = str(o, 'published_at');
      const c = o.client as Record<string, Object> | undefined;
      if (c !== undefined && c !== null) {
        out.clientLatest = str(c, 'version');
        out.clientNotes = str(c, 'notes');
        out.url = str(c, 'url');
        out.size = num(c, 'size');
        out.sha256 = str(c, 'sha256').toLowerCase();
        out.clientUpdatable = isNewer(out.clientLatest, out.clientNow);
      }
      const s = o.server as Record<string, Object> | undefined;
      if (s !== undefined && s !== null) {
        out.serverLatest = str(s, 'version');
        out.serverNotes = str(s, 'notes');
        out.serverHowto = Updater.readHowto(s);
        out.serverUpdatable = isNewer(out.serverLatest, out.serverNow);
      }
    } catch (err) {
      out.message = '清单格式不对（不是 JSON）';
      return out;
    }

    if (out.clientLatest.length === 0 && out.serverLatest.length === 0) {
      out.message = '清单里既没有 client 也没有 server';
      return out;
    }
    out.ok = true;
    return out;
  }

  static dir(): string {
    if (Updater.ctx === undefined) {
      return '';
    }
    return `${Updater.ctx.filesDir}/${SUB_DIR}`;
  }

  private static ensureDir(): boolean {
    const d: string = Updater.dir();
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
      console.info(`[amane] update mkdir: ${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 下载新包到沙箱并校验 sha256。
   *
   * 校验不通过 = 删掉文件并返回失败（不留半个包）。
   * 清单里没有 sha256 直接拒下：自签名包本来就靠这个确认来源。
   */
  static async download(version: string, url: string, size: number, sha256: string,
    onProgress: (pct: number) => void): Promise<DownloadResult> {
    const ctx = Updater.ctx;
    if (ctx === undefined) {
      return { ok: false, message: '还没准备好（页面没初始化）', path: '' };
    }
    if (url.length === 0) {
      return { ok: false, message: '清单里没有下载地址', path: '' };
    }
    if (sha256.length !== 64) {
      return { ok: false, message: '清单里没有 sha256，拒绝下载（无法确认包没被换过）', path: '' };
    }
    if (!Updater.ensureDir()) {
      return { ok: false, message: '建下载目录失败', path: '' };
    }
    const safe: string = version.replace(/[^\w.-]/g, '_');
    const path: string = `${Updater.dir()}/Amane-${safe}.hap`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 删不掉就让 overwrite 覆盖
    }

    try {
      const config: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: url,
        saveas: path,
        overwrite: true,
        network: request.agent.Network.ANY,
        gauge: true,
        mode: request.agent.Mode.BACKGROUND
      };
      const task: request.agent.Task = await request.agent.create(ctx, config);
      Updater.live = task;
      const done = new Promise<void>((resolve: () => void) => {
        task.on('progress', (p: request.agent.Progress) => {
          const total: number = p.sizes[0] === undefined || p.sizes[0] <= 0 ? size : p.sizes[0];
          onProgress(total <= 0 ? -1 : Math.floor((p.processed * 100) / total));
        });
        task.on('completed', () => {
          resolve();
        });
        task.on('failed', () => {
          resolve();
        });
      });
      await task.start();
      await done;
      Updater.live = undefined;

      if (!fs.accessSync(path)) {
        return { ok: false, message: '下载没落盘（网络或空间问题）', path: '' };
      }
      const got: number = fs.statSync(path).size;
      if (size > 0 && got !== size) {
        return { ok: false, message: `包大小不对（期望 ${size}，实际 ${got}）`, path: '' };
      }
      const sum: string = await hash.hash(path, 'sha256');
      if (sum.toLowerCase() !== sha256) {
        try {
          fs.unlinkSync(path);
        } catch (err) {
          // 删不掉也把结果报成失败
        }
        return { ok: false, message: 'sha256 校验不通过，已删掉这个包', path: '' };
      }
      onProgress(100);
      return { ok: true, message: '下载完成，校验通过', path: path };
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] update download: ${e.code} ${e.message}`);
      Updater.live = undefined;
      return { ok: false, message: `下载失败：${e.message}`, path: '' };
    }
  }

  /** 取消正在进行的下载。 */
  static async cancel(): Promise<void> {
    const t = Updater.live;
    if (t === undefined) {
      return;
    }
    try {
      await t.pause();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] update cancel: ${e.code} ${e.message}`);
    }
    Updater.live = undefined;
  }

  /**
   * 把沙箱里的包另存到手机（系统保存对话框选位置）。
   *
   * 沙箱路径用户碰不到，必须走这一步；返回保存到的 URI，失败返回空串。
   */
  static async saveToPhone(path: string, version: string): Promise<string> {
    const ctx = Updater.ctx;
    if (ctx === undefined) {
      return '';
    }
    try {
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`Amane-${version}.hap`];
      opt.fileSuffixChoices = ['.hap'];
      const p = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await p.save(opt);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      const uri: string = uris[0];
      const src = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const dst = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(src.fd, dst.fd);
      fs.closeSync(src);
      fs.closeSync(dst);
      return uri;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] update save: ${e.code} ${e.message}`);
      return '';
    }
  }
}
