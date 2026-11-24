import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Store } from './Store';

/**
 * 手机侧的空间统计（2026-11-14 新增）。
 *
 * 为什么需要它：`CachePage` 原来只讲两块（图片缓存、页面数据），可 App 沙箱里实际有
 * 六个目录在长胖 —— 离线影片、抽卡截图、导出图、播放器配置都不在视野里。
 * 用户 2026-11-14 22:14：「客户端也有对应的问题吧？怎么没有一起拆解？」
 *
 * 口径：只统计 App 自己的 `filesDir` 子目录，不碰系统缓存。
 * 上限存在 `Store` 偏好里（`cli_cap_<key>`，MB，0=不限），图片缓存仍由 `ImgCache` 自己管，
 * 这里只读它报出来的 cap，避免两套上限打架。
 */

export interface CliKind {
  key: string;
  label: string;
  bytes: number;
  files: number;
  capMb: number;
  /** 是否有「自动淘汰」能力（只有图片缓存有；其余是手动清理） */
  hasCap: boolean;
  /** 能否清（离线影片是用户主动下载的，不给清） */
  cleanable: boolean;
  desc: string;
}

interface KindDef {
  key: string;
  dir: string;
  label: string;
  hasCap: boolean;
  cleanable: boolean;
  desc: string;
}

const KIND_DEFS: KindDef[] = [
  {
    key: 'img', dir: 'img-cache', label: '图片缓存', hasCap: true, cleanable: true,
    desc: '海报、剧照与头像的本地缓存，删后自动重新拉取。'
  },
  {
    key: 'page', dir: 'page-cache', label: '页面数据', hasCap: false, cleanable: true,
    desc: '首页与列表接口快照，用于冷启秒开。'
  },
  {
    key: 'offline', dir: 'offline', label: '离线影片', hasCap: false, cleanable: false,
    desc: '手动下载的离线片，永不自动清理；如需删除请前往「下载管理」。'
  },
  {
    key: 'picks', dir: 'picks', label: '抽卡 / 亮点截图', hasCap: false, cleanable: true,
    desc: '抽卡与亮点页缓存的图片，删后不影响原片。'
  },
  {
    key: 'export', dir: 'export', label: '导出的图片', hasCap: false, cleanable: true,
    desc: '保存到相册时生成的临时副本，不影响相册原图。'
  },
  {
    key: 'mpvconf', dir: 'mpvconf', label: '播放器配置', hasCap: false, cleanable: false,
    desc: 'mpv 运行配置（仅数 KB），受保护不可清理。'
  }
];

/** 递归算一个目录的 (字节, 文件数)。目录不存在返回 (0,0)，不抛。 */
function dirSize(path: string): number[] {
  let total: number = 0;
  let files: number = 0;
  try {
    if (!fs.accessSync(path)) {
      return [0, 0];
    }
  } catch (err) {
    return [0, 0];
  }
  const stack: string[] = [path];
  while (stack.length > 0) {
    const cur: string = stack.pop() as string;
    let names: string[] = [];
    try {
      names = fs.listFileSync(cur);
    } catch (err) {
      continue;
    }
    for (let i = 0; i < names.length; i++) {
      const p: string = `${cur}/${names[i]}`;
      try {
        const st = fs.statSync(p);
        if (st.isDirectory()) {
          stack.push(p);
        } else {
          total += st.size;
          files += 1;
        }
      } catch (err) {
        continue;
      }
    }
  }
  return [total, files];
}

/** 上限（MB）。0 = 不限。图片缓存的上限由 ImgCache 自己持久化，这里不重复存。 */
export function cliCapMb(key: string): number {
  if (key === 'img') {
    return 0;      // 由调用方用 imgCacheCap() 读，避免两套值
  }
  const raw: string = Store.I.prefString(`cli_cap_${key}`, '');
  const n: number = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
}

export function cliSetCap(key: string, mb: number): void {
  Store.I.prefSetString(`cli_cap_${key}`, String(Math.max(0, Math.round(mb))));
}

/** 手机侧全部块。`imgCapBytes` 由调用方传 `imgCacheCap()`，保证和图片缓存模块一致。 */
export function cliReport(ctx: common.UIAbilityContext, imgCapBytes: number): CliKind[] {
  const out: CliKind[] = [];
  for (let i = 0; i < KIND_DEFS.length; i++) {
    const d: KindDef = KIND_DEFS[i];
    const r: number[] = dirSize(`${ctx.filesDir}/${d.dir}`);
    out.push({
      key: d.key,
      label: d.label,
      bytes: r[0],
      files: r[1],
      capMb: d.key === 'img' ? Math.round(imgCapBytes / (1024 * 1024)) : cliCapMb(d.key),
      hasCap: d.hasCap,
      cleanable: d.cleanable,
      desc: d.desc
    });
  }
  return out;
}

/** 清一块。返回释放的字节数。离线影片与播放器配置直接拒绝。 */
export function cliClear(ctx: common.UIAbilityContext, key: string): number {
  for (let i = 0; i < KIND_DEFS.length; i++) {
    const d: KindDef = KIND_DEFS[i];
    if (d.key !== key) {
      continue;
    }
    if (!d.cleanable) {
      return 0;
    }
    const root: string = `${ctx.filesDir}/${d.dir}`;
    let freed: number = 0;
    const stack: string[] = [root];
    while (stack.length > 0) {
      const cur: string = stack.pop() as string;
      let names: string[] = [];
      try {
        names = fs.listFileSync(cur);
      } catch (err) {
        continue;
      }
      for (let j = 0; j < names.length; j++) {
        const p: string = `${cur}/${names[j]}`;
        try {
          const st = fs.statSync(p);
          if (st.isDirectory()) {
            stack.push(p);
          } else {
            freed += st.size;
            fs.unlinkSync(p);
          }
        } catch (err) {
          continue;
        }
      }
    }
    return freed;
  }
  return 0;
}
