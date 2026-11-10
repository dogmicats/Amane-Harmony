import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

/**
 * 播放器参数（mpv）。
 *
 * 设计要点：
 * 1. **结构化设置是唯一真相**，存在 preferences 里；`mpv.conf` 由这些设置生成。
 * 2. 设置页只操作结构化字段（开关 / 滑块 / 预设），不需要用户懂 mpv 语法；
 *    「额外参数」留给调试，追加在生成文件末尾（mpv 后出现的键覆盖前面的）。
 * 3. `hwdec` 不走 conf —— PlayerConfig 构造参数优先级更高，写 conf 会被盖掉。
 * 4. 拖动进度条后「缓存中」卡一秒，根因是 cache-pause-wait（恢复播放前要缓冲几秒）。
 *    默认 0.2s：链路本来就快，等 1 秒纯属自找卡顿。
 */

/** 播放参数版本：改默认值或字段含义时 +1，老配置会被重新生成。 */
export const MPV_CONF_VERSION: string = 'amane-conf: 9';

export interface PlayerTuning {
  /** 硬件解码（走 PlayerConfig，不进 conf）。 */
  hwdec: boolean;
  /** 预设 key：smooth / balanced / stable / custom。 */
  preset: string;
  /** 恢复播放前要缓冲多少秒（cache-pause-wait）。越小越跟手。 */
  pauseWait: number;
  /** 预读秒数（demuxer-readahead-secs）。 */
  readahead: number;
  /** 缓存上限 MiB（demuxer-max-bytes）。 */
  maxMiB: number;
  /** 回退缓存 MiB（demuxer-max-back-bytes），决定能往回拖多远不用重新拉。 */
  backMiB: number;
  /** 精确跳转（hr-seek）：关掉落在关键帧上，起播快；开了精确到秒但要多解码。 */
  hrSeek: boolean;
  /** 额外 mpv 参数，逐行追加。 */
  extra: string;
}

export interface PresetOption {
  key: string;
  label: string;
  desc: string;
}

export const PRESETS: PresetOption[] = [
  { key: 'smooth', label: '流畅优先', desc: '缓存小、恢复快，适合局域网' },
  { key: 'balanced', label: '均衡', desc: '默认，兼顾拖动响应与外网稳定' },
  { key: 'stable', label: '弱网优先', desc: '缓存大、多等一会儿，适合外网' }
];

/**
 * ★ 锁定的默认参数（CD2 网盘源真机验证过的那套，改动前先读下面这段）★
 *
 * `cache-pause-wait = 1.0`：
 *   这是「缓存里有多少秒才恢复播放」的阈值。0.2 会让 mpv 一有数据就播、
 *   播两帧又耗尽，于是「播一下→缓存一下」反复循环（用户原话「一下一缓存」）；
 *   1.0 = mpv 自带默认值，等够一秒再开闸，一次播顺。
 *   2.2.9 曾把这里改成 1.0 是对的，但 2.2.11 回滚「流互斥」时连带撤回成了 0.2，
 *   于是卡顿复现 —— **这个值不要再随手改**。
 *
 * 其余：`readahead 20 / maxMiB 64 / backMiB 32 / hr-seek off + stream-buffer 4MiB`。
 *   2.0.16 实测：缓存开大（256MiB）反而让 seek 到未缓存区更慢，别再调大。
 *
 * 改这个函数必须同时升 `TUNING_LOCK` 与 `MPV_CONF_VERSION`，否则老设备上
 * 写脏的值会盖住新默认（`load()` 只在 lock 不匹配时整份重置）。
 */
export const TUNING_LOCK: string = 'lock-v9';

/** 锁定值单独导出：设置页与自检都用它，避免两处写死后对不上。 */
export const LOCKED_PAUSE_WAIT: number = 1.0;

function baseTuning(): PlayerTuning {
  const t: PlayerTuning = {
    hwdec: true,
    preset: 'balanced',
    pauseWait: LOCKED_PAUSE_WAIT,
    readahead: 20,
    maxMiB: 64,
    backMiB: 32,
    hrSeek: false,
    extra: ''
  };
  return t;
}

/** 预设只改数值，不改额外参数。 */
export function presetTuning(key: string, current: PlayerTuning): PlayerTuning {
  const t: PlayerTuning = {
    hwdec: current.hwdec,
    preset: key,
    pauseWait: current.pauseWait,
    readahead: current.readahead,
    maxMiB: current.maxMiB,
    backMiB: current.backMiB,
    hrSeek: current.hrSeek,
    extra: current.extra
  };
  if (key === 'smooth') {
    t.pauseWait = 0.1;
    t.readahead = 10;
    t.maxMiB = 48;
    t.backMiB = 16;
    t.hrSeek = false;
  } else if (key === 'stable') {
    t.pauseWait = 1.5;
    t.readahead = 45;
    t.maxMiB = 192;
    t.backMiB = 64;
    t.hrSeek = false;
  } else {
    t.pauseWait = LOCKED_PAUSE_WAIT;
    t.readahead = 20;
    t.maxMiB = 64;
    t.backMiB = 32;
    t.hrSeek = false;
  }
  return t;
}

/** 由结构化设置生成 mpv.conf 全文。 */
export function confText(t: PlayerTuning): string {
  const lines: string[] = [
    `# ${MPV_CONF_VERSION}`,
    '# 本文件由 App「播放器设置」生成，手改会在下次保存时被覆盖。',
    '# 要加自定义参数请用「高级 · 额外参数」，它会追加到文件末尾并覆盖同名项。',
    '',
    '# 视频输出',
    'vo=gpu-next',
    'osc=no',
    'osd-level=0',
    '',
    '# 缓存',
    'cache=yes',
    // mpv 默认 128KiB：网盘源读取是「一阵一阵」的，底层缓冲太小会
    // 把抖动直接暴露给 demuxer，拖动之后尤其明显（一秒一卡）。
    'stream-buffer-size=4MiB',
    `demuxer-max-bytes=${t.maxMiB}MiB`,
    `demuxer-max-back-bytes=${t.backMiB}MiB`,
    `demuxer-readahead-secs=${t.readahead}`,
    'cache-pause=yes',
    `cache-pause-wait=${t.pauseWait}`,
    'demuxer-seekable-cache=yes',
    `hr-seek=${t.hrSeek ? 'yes' : 'no'}`,
    '',
    'demuxer-lavf-probe-info=nostreams'
  ];
  const extra: string = t.extra === undefined || t.extra === null ? '' : t.extra.trim();
  if (extra.length > 0) {
    lines.push('');
    lines.push('# 额外参数');
    lines.push(extra);
  }
  return lines.join('\n');
}

const PREF_STORE: string = 'amane_player';
const PREF_TUNING: string = 'tuning';
const PREF_HWDEC: string = 'hwdec';
const PREF_TUNING_LOCK: string = 'tuning_lock';

/** 生成配置里已有的键，迁移老 conf 时用来识别「用户自己加的」。 */
const KNOWN_KEYS: string[] = [
  'vo', 'osc', 'osd-level', 'cache', 'demuxer-max-bytes', 'demuxer-max-back-bytes',
  'demuxer-readahead-secs', 'cache-pause', 'cache-pause-wait', 'demuxer-seekable-cache',
  'hr-seek', 'demuxer-lavf-probe-info', 'hwdec', 'stream-buffer-size'
];

export class PlayerPrefs {
  /** mpv 配置目录（沙箱内，确保存在）。 */
  static dir(ctx: common.UIAbilityContext): string {
    const dir: string = `${ctx.filesDir}/mpvconf`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
    } catch (e) {
      console.error(`[amane] mkdir mpvconf: ${JSON.stringify(e)}`);
    }
    return dir;
  }

  static confPath(ctx: common.UIAbilityContext): string {
    return `${PlayerPrefs.dir(ctx)}/mpv.conf`;
  }

  private static readText(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const stat = fileIo.statSync(path);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      console.error(`[amane] read ${path}: ${JSON.stringify(e)}`);
      return '';
    }
  }

  private static writeText(path: string, text: string): void {
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (e) {
      console.error(`[amane] write ${path}: ${JSON.stringify(e)}`);
    }
  }

  static confFileText(ctx: common.UIAbilityContext): string {
    return PlayerPrefs.readText(PlayerPrefs.confPath(ctx));
  }

  /** 读结构化设置；没有就用默认值（并从老 conf 里继承用户自定义项）。 */
  static load(ctx: common.UIAbilityContext): PlayerTuning {
    const t: PlayerTuning = baseTuning();
    let stored: string = '';
    let lock: string = '';
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: PREF_STORE });
      stored = store.getSync(PREF_TUNING, '') as string;
      lock = store.getSync(PREF_TUNING_LOCK, '') as string;
      t.hwdec = store.getSync(PREF_HWDEC, true) === true;
    } catch (e) {
      console.error(`[amane] load tuning: ${JSON.stringify(e)}`);
    }
    // 默认参数锁定：版本不符说明设备上还留着旧值（可能是历史调参/别的版本写脏的），
    // 直接回到 baseTuning，并把锁版本记下来。以后真要改默认，就升 TUNING_LOCK。
    if (lock !== TUNING_LOCK) {
      try {
        const store: preferences.Preferences =
          preferences.getPreferencesSync(ctx, { name: PREF_STORE });
        store.putSync(PREF_TUNING_LOCK, TUNING_LOCK);
        store.putSync(PREF_TUNING, JSON.stringify(t));
        store.flush();
      } catch (e) {
        console.error(`[amane] lock tuning: ${JSON.stringify(e)}`);
      }
      return t;
    }
    if (stored === undefined || stored === null || stored.length === 0) {
      // 首次升级：把老 mpv.conf 里用户手写的行保留成「额外参数」
      t.extra = PlayerPrefs.legacyExtra(ctx);
      return t;
    }
    try {
      const raw = JSON.parse(stored) as PlayerTuning;
      if (raw !== undefined && raw !== null) {
        t.preset = raw.preset === undefined || raw.preset === null ? 'custom' : raw.preset;
        t.pauseWait = raw.pauseWait === undefined || raw.pauseWait === null ? t.pauseWait : Number(raw.pauseWait);
        t.readahead = raw.readahead === undefined || raw.readahead === null ? t.readahead : Number(raw.readahead);
        t.maxMiB = raw.maxMiB === undefined || raw.maxMiB === null ? t.maxMiB : Number(raw.maxMiB);
        t.backMiB = raw.backMiB === undefined || raw.backMiB === null ? t.backMiB : Number(raw.backMiB);
        t.hrSeek = raw.hrSeek === true;
        t.extra = raw.extra === undefined || raw.extra === null ? '' : raw.extra;
        // 均衡档就是锁定值：设备上残留的 0.2 之类一律拉回，防止「改对了又被顶掉」
        if (t.preset === 'balanced' && t.pauseWait < LOCKED_PAUSE_WAIT) {
          t.pauseWait = LOCKED_PAUSE_WAIT;
        }
      }
    } catch (e) {
      console.error(`[amane] parse tuning: ${JSON.stringify(e)}`);
    }
    return t;
  }

  /** 老版本 mpv.conf 里不属于生成模板的行（用户自己加的），收进额外参数。 */
  private static legacyExtra(ctx: common.UIAbilityContext): string {
    const text: string = PlayerPrefs.readText(PlayerPrefs.confPath(ctx));
    if (text.length === 0) {
      return '';
    }
    const out: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      const eq: number = line.indexOf('=');
      const key: string = (eq > 0 ? line.substring(0, eq) : line).trim();
      if (KNOWN_KEYS.indexOf(key) >= 0) {
        continue;
      }
      out.push(line);
    }
    return out.join('\n');
  }

  /** 保存 + 立即重写 conf（下次进播放页生效）。 */
  static save(ctx: common.UIAbilityContext, t: PlayerTuning): void {
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: PREF_STORE });
      store.putSync(PREF_HWDEC, t.hwdec);
      store.putSync(PREF_TUNING, JSON.stringify(t));
      store.flush();
    } catch (e) {
      console.error(`[amane] save tuning: ${JSON.stringify(e)}`);
    }
    PlayerPrefs.writeText(PlayerPrefs.confPath(ctx), confText(t));
  }

  /**
   * 播放页入口：读设置 → 确保 conf 是当前版本 → 回写一次。
   * 版本不一致（老安装包升级上来）时直接按新默认重生成。
   */
  static apply(ctx: common.UIAbilityContext): PlayerTuning {
    const t: PlayerTuning = PlayerPrefs.load(ctx);
    const existing: string = PlayerPrefs.readText(PlayerPrefs.confPath(ctx));
    if (existing.indexOf(MPV_CONF_VERSION) < 0) {
      PlayerPrefs.writeText(PlayerPrefs.confPath(ctx), confText(t));
    }
    return t;
  }

  /** 硬解单独取（PlayerConfig 构造参数要用，得同步）。 */
  static hwdecSync(ctx: common.UIAbilityContext): boolean {
    return PlayerPrefs.load(ctx).hwdec;
  }

  static setHwdecSync(ctx: common.UIAbilityContext, on: boolean): void {
    const t: PlayerTuning = PlayerPrefs.load(ctx);
    t.hwdec = on;
    PlayerPrefs.save(ctx, t);
  }
}
