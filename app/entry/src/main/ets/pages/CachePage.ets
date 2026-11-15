import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { CliKind, cliReport, cliClear } from '../common/CliStorage';
import { cacheClear, cacheCount, cacheSizeKb } from '../common/PageCache';
import { imgCacheBytes, imgCacheCap, imgCacheClear, imgCacheCount, imgCacheFetched, imgCacheHits, imgCacheSetCap } from '../common/ImgCache';
import { httpGet, httpPost, httpPut } from '../common/Http';
import { Store } from '../common/Store';

/**
 * 设置 → 存储与缓存（2.6.2.1）。
 *
 * 用户 2026-11-13：「每次进 App，本来有的内容尤其图片，还有切页面经常要重新加载」
 * —— 之前只有页面 JSON 有磁盘缓存，**图片完全没有落盘**，杀掉 App 就全丢。
 *
 * 这一页把「App 自己占了多少」摊开给用户看，并把清不清理、留多少交给他：
 *  - 图片缓存：海报/剧照/头像，命中就走本地文件，不再联网；
 *  - 页面数据：首页、媒体库、详情这类 JSON 响应，过期也能先铺出来再刷新；
 *  - 上限：超了按「最久没用」自动淘汰，不会无限长。
 *
 * 和「离线缓存」（`OfflinePage`）的区别：那边是**影片本体**（几百 MB 到几 GB），
 * 这边是 App 自身跑起来要用的图和小数据（几十 KB 一张、几 KB 一条）。
 */
interface CapOpt {
  mb: number;
  label: string;
  sub: string;
}

const CAPS: CapOpt[] = [
  { mb: 200, label: '200 MB', sub: '小' },
  { mb: 500, label: '500 MB', sub: '推荐' },
  { mb: 1024, label: '1 GB', sub: '大' },
  { mb: 0, label: '不限制', sub: '按需长' }
];

/** 服务端一块空间的现状（对应 `core/storage.py` 的 report().kinds 一项）。 */
interface ServerKind {
  key: string;
  label: string;
  used_mb: number;
  files: number;
  budget_mb: number;
  status: string;      // ok / near / over
  cleanable: boolean;
  desc: string;
}

interface ServerReport {
  ok: boolean;
  kinds: ServerKind[];
  total_mb: number;
  total_files: number;
  stale_play_mb: number;
  stale_play_dirs: string[];
  free_mb: number;
}

/** `PUT /api/user/storage` 的回包：清单嵌在 `report` 里，不在顶层。 */
interface SetResp {
  ok: boolean;
  key?: string;
  mb?: number;
  report?: ServerReport;
}

/** 清理接口的回包（清理结果 + 清完的最新统计）。 */
interface CleanResp {  ok: boolean;
  key?: string;
  freed_mb?: number;
  files?: number;
  removed?: string[];
  report?: ServerReport;
}

/** 清理请求体。age_days：-1=不传（用服务端默认），0=全清，7/30=按龄。 */
class CleanReq {
  key: string = '';
  age_days: number = -1;
}

/**
 * 播放缓存分源（服务端 2026-11-15 拆分，agent2 的 `50cd382`）。
 *
 * 以前只有一份 4096MB 的预算，网盘片和本地片共用一个池子，本地片白占预算。
 * 现在网盘片（`PLAY_DISK` → `play-cache/v4`）可调，本地片（`PLAY_DISK_LOCAL` → `v4/_local`）
 * 固定 128MB 不开放。两边的数字**只从 `/api/user/playcache` 读**，不在这里 walk 目录自己算 ——
 * 否则又会出现「页面显示的和预算口径不是一回事」。
 */
interface PlaySplit {
  remote_used_mb?: number;
  remote_budget_mb?: number;
  local_used_mb?: number;
  local_budget_mb?: number;
}

/** 服务端上限的预设档位（和客户端那份语法一致，用户不用记数字）。 */
const SERVER_CAPS: CapOpt[] = [
  { mb: 1024, label: '1 GB', sub: '省' },
  { mb: 2048, label: '2 GB', sub: '小' },
  { mb: 4096, label: '4 GB', sub: '推荐' },
  { mb: 8192, label: '8 GB', sub: '大' },
  { mb: 0, label: '不限制', sub: '按磁盘' }
];

/**
 * 播放缓存的档位多一档 512 MB。
 *
 * 为什么单给它：网盘片那份预算是**唯一**需要按带宽/流量省的块，512MB 是「只想留一点热数据」
 * 的常用值（服务端 `/api/user/playcache/settings` 的合法取值也有 512）。
 * 图片缓存 512 已经是「推荐」档，不用再往下压。
 */
const PLAY_CAPS: CapOpt[] = [
  { mb: 512, label: '512 MB', sub: '只留热数据' },
  { mb: 1024, label: '1 GB', sub: '省' },
  { mb: 2048, label: '2 GB', sub: '小' },
  { mb: 4096, label: '4 GB', sub: '推荐' },
  { mb: 8192, label: '8 GB', sub: '大' },
  { mb: 0, label: '不限制', sub: '按磁盘' }
];

@Entry
@Component
struct CachePage {
  @State imgBytes: number = 0;
  @State imgCount: number = 0;
  @State capMb: number = 500;
  @State pageKb: number = 0;
  @State pageCount: number = 0;
  @State note: string = '';
  @State busy: boolean = false;
  /** 本次运行（进程内）图片缓存命中 / 新下载次数。 */
  @State hits: number = 0;
  @State fetched: number = 0;
  // ---- 服务端（这台 NAS 上的 amane-user）----
  @State serverKinds: ServerKind[] = [];
  @State serverTotalMb: number = 0;
  @State serverFreeMb: number = 0;
  @State stalePlayMb: number = 0;
  @State serverNote: string = '';
  // ---- 播放缓存分源（网盘 / 本地）----
  @State pRemoteUsed: number = 0;
  @State pRemoteBudget: number = 0;
  @State pLocalUsed: number = 0;
  @State pLocalBudget: number = 0;
  /** 老服务端没有 playcache 的分源字段时为 false：那一行退回显示合计，不显示假数据。 */
  @State playSplitOk: boolean = false;
  /** 当前展开档位条的块 key（'' = 都不展开） */
  @State capOpen: string = '';
  /** 当前展开「确认清理」的块 key */
  @State cleanConfirm: string = '';
  // ---- 手机侧其余四块（离线影片 / 抽卡图 / 导出图 / 播放器配置）----
  // 图片缓存与页面数据仍走上面那两张老卡片（它们有各自的淘汰逻辑），
  // 这里只补「原来根本看不到」的那几块。
  @State cliKinds: CliKind[] = [];
  aboutToAppear(): void {
    this.refresh();
    this.refreshCli();
    this.loadServer();
  }

  /** 手机侧其余四块的大小（图片/页面两块由上面原有的 refresh 管）。 */
  private refreshCli(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const all: CliKind[] = cliReport(ctx, imgCacheCap());
      // 只取本页新增的四块；img/page 有专门卡片，不重复列
      this.cliKinds = all.filter((k: CliKind) => k.key !== 'img' && k.key !== 'page');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] cliReport: ${e.code} ${e.message}`);
      this.cliKinds = [];
    }
  }

  private humanBytes(bytes: number): string {
    return this.human(bytes);
  }

  private clearCli(key: string, label: string): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const freed: number = cliClear(ctx, key);
      this.note = freed > 0 ? `已清掉${label} ${this.humanBytes(freed)}` : `${label}本来就是空的`;
    } catch (err) {
      const e = err as BusinessError;
      this.note = `清理${label}失败：${e.message === undefined ? e.code : e.message}`;
    }
    this.refreshCli();
  }

  private refresh(): void {
    this.imgBytes = imgCacheBytes();
    this.imgCount = imgCacheCount();
    this.capMb = Math.round(imgCacheCap() / (1024 * 1024));
    this.pageKb = cacheSizeKb();
    this.pageCount = cacheCount();
    this.hits = imgCacheHits();
    this.fetched = imgCacheFetched();
  }

  /** 字节 → 人能看的大小。 */
  private human(bytes: number): string {
    if (bytes <= 0) {
      return '0 MB';
    }
    const mb: number = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return `${(mb / 1024).toFixed(2)} GB`;
    }
    if (mb >= 10) {
      return `${Math.round(mb)} MB`;
    }
    if (mb >= 0.1) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }

  private humanKb(kb: number): string {
    return this.human(kb * 1024);
  }

  /** MB → 人能看的大小（服务端报的是 MB）。 */
  private humanMb(mb: number): string {
    if (mb <= 0) {
      return '0 MB';
    }
    if (mb >= 1024) {
      return `${(mb / 1024).toFixed(2)} GB`;
    }
    if (mb >= 10) {
      return `${Math.round(mb)} MB`;
    }
    return `${mb.toFixed(1)} MB`;
  }

  /** 拉服务端的空间清单。失败不弹错，只把提示写进 serverNote（页面不至于整块消失）。 */
  private async loadServer(): Promise<void> {
    if (!Store.I.ready) {
      return;
    }
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/storage`, Store.I.token);
      const r: ServerReport = JSON.parse(text) as ServerReport;
      this.serverKinds = r.kinds === undefined || r.kinds === null ? [] : r.kinds;
      this.serverTotalMb = r.total_mb === undefined ? 0 : r.total_mb;
      this.serverFreeMb = r.free_mb === undefined ? 0 : r.free_mb;
      this.stalePlayMb = r.stale_play_mb === undefined ? 0 : r.stale_play_mb;
      this.serverNote = '';
      this.loadPlaySplit();
    } catch (err) {
      // 老服务端没有这个端点：明确说「服务器版本低」，而不是留空让人以为没数据
      const e = err as BusinessError;
      this.serverNote = `取不到服务器空间信息（${e.code === undefined ? '?' : e.code}）。`
        + '如果是较老的服务端，这一块要升级后才有。';
    }
  }

  /**
   * 拉播放缓存的分源数字（网盘 / 本地）。
   *
   * 为什么单独一次请求：`/api/user/storage` 报的是「整棵 play-cache 目录」的合计，
   * 分源预算只有 playcache 端点知道（它读的是真正在跑的 PLAY_DISK / PLAY_DISK_LOCAL）。
   * 失败不弹错，只把 `playSplitOk` 置 false —— 那一行退回显示合计，不让页面报「读取失败」。
   */
  /** 某一块可选的档位：播放缓存多一档 512 MB（只针对网盘片），其余用默认那套。 */
  private capsFor(key: string): CapOpt[] {
    return key === 'play' ? PLAY_CAPS : SERVER_CAPS;
  }

  private async loadPlaySplit(): Promise<void> {    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/playcache`, Store.I.token);
      const r: PlaySplit = JSON.parse(text) as PlaySplit;
      const hasField: boolean = r.remote_used_mb !== undefined && r.local_used_mb !== undefined;
      this.playSplitOk = hasField;
      if (hasField) {
        this.pRemoteUsed = Number(r.remote_used_mb) || 0;
        this.pRemoteBudget = Number(r.remote_budget_mb) || 0;
        this.pLocalUsed = Number(r.local_used_mb) || 0;
        this.pLocalBudget = Number(r.local_budget_mb) || 0;
      }
    } catch (err) {
      this.playSplitOk = false;
    }
  }

  /**
   * 改某一块的服务端上限：**页内展开档位条**，不弹系统对话框。
   * ArkTS 规定对象字面量必须有明确类型（`arkts-no-untyped-obj-literals`），
   * `AlertDialog.show({...})` / `ActionSheet.show({...})` 在这里编不过；
   * 而且内联选择比弹窗少一层，和这一页原有的「图片上限」交互也一致。
   */
  private toggleCap(k: ServerKind): void {
    this.capOpen = this.capOpen === k.key ? '' : k.key;
    this.cleanConfirm = '';
  }

  private toggleClean(k: ServerKind): void {
    this.cleanConfirm = this.cleanConfirm === k.key ? '' : k.key;
    this.capOpen = '';
  }

  private async applyServerCap(k: ServerKind, mb: number): Promise<void> {
    this.busy = true;
    try {
      const body: string = JSON.stringify({ key: k.key, mb: mb });
      const text: string = await httpPut(`${Store.I.user}/api/user/storage`, Store.I.token, body);
      // PUT 的回包是 {ok, key, mb, settings, report:{kinds,total_mb,...}} —— 清单在 report 里，
      // 不在顶层。2026-11-15 实测：直接读顶层会把列表清空（页面显示「正在读取…」），所以取 report。
      const r = JSON.parse(text) as SetResp;
      const rep: ServerReport | undefined = r.report;
      if (rep !== undefined && rep.kinds !== undefined && rep.kinds !== null) {
        this.serverKinds = rep.kinds;
        this.serverTotalMb = rep.total_mb === undefined ? 0 : rep.total_mb;
        this.stalePlayMb = rep.stale_play_mb === undefined ? 0 : rep.stale_play_mb;
        this.serverNote = '';
      } else {
        await this.loadServer();
      }
      this.loadPlaySplit();
    } catch (err) {
      const e = err as BusinessError;
      this.serverNote = `设置失败：${e.message === undefined ? e.code : e.message}`;
    }
    this.busy = false;
  }

  private async doCleanServer(key: string, ageDays: number = -1): Promise<void> {
    this.busy = true;
    try {
      // ArkTS 不允许裸对象字面量（arkts-no-untyped-obj-literals），用 class 构造
      const req: CleanReq = new CleanReq();
      req.key = key;
      if (ageDays >= 0) {
        req.age_days = ageDays;
      }
      const body: string = JSON.stringify(req);
      const text: string = await httpPost(`${Store.I.user}/api/user/storage/clean`,
        Store.I.token, body);
      // 用显式 interface：ArkTS 不允许把对象字面量当类型（arkts-no-obj-literals-as-types）
      const r: CleanResp = JSON.parse(text) as CleanResp;
      if (r.report !== undefined && r.report !== null) {
        this.serverKinds = r.report.kinds === undefined ? [] : r.report.kinds;
        this.serverTotalMb = r.report.total_mb === undefined ? 0 : r.report.total_mb;
        this.stalePlayMb = r.report.stale_play_mb === undefined ? 0 : r.report.stale_play_mb;
      }
      this.serverNote = `已释放 ${this.humanMb(r.freed_mb === undefined ? 0 : r.freed_mb)}`;
      this.loadPlaySplit();
    } catch (err) {
      const e = err as BusinessError;
      this.serverNote = `清理失败：${e.message === undefined ? e.code : e.message}`;
    }
    this.busy = false;
  }

  private totalText(): string {
    return this.human(this.imgBytes + this.pageKb * 1024);
  }

  private clearImages(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const n: number = imgCacheClear();
    this.note = n > 0 ? `已清掉 ${n} 张图片缓存` : '图片缓存本来就是空的';
    this.refresh();
    this.busy = false;
  }

  private clearPages(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const n: number = cacheClear();
    this.note = n > 0 ? `已清掉 ${n} 条页面数据` : '页面数据本来就是空的';
    this.refresh();
    this.busy = false;
  }

  private clearAll(): void {
    this.busy = true;
    const a: number = imgCacheClear();
    const b: number = cacheClear();
    this.note = `已清掉 ${a} 张图 + ${b} 条页面数据`;
    this.refresh();
    this.busy = false;
  }

  private pickCap(mb: number): void {
    this.capMb = mb;
    // 0 = 不限制：给一个足够大的数，别让 evict 把东西删了
    imgCacheSetCap(mb <= 0 ? 1024 * 1024 * 1024 * 8 : mb * 1024 * 1024);
    this.refresh();
    this.note = mb <= 0 ? '不限制：缓存会一直长，直到手机空间不够' : `上限已改为 ${mb >= 1024 ? mb / 1024 + ' GB' : mb + ' MB'}`;
  }

  /**
   * 注意：卡片标题行**不要**抽成 `@Builder(title, right)`。
   *
   * ArkUI 的 `@Builder` 参数是**按值**传的，`@State` 变了不会让 Builder 里那份字符串
   * 重新求值 —— 第一版就踩了：清完图片缓存，「App 自身占用」掉到 0.2MB，
   * 可「图片缓存」还写着「83 张 · 9.1MB」。带数字的行一律在 build 里内联写。
   */

  @Builder
  CapChip(o: CapOpt) {
    Column({ space: 1 }) {
      Text(o.label)
        .fontSize(12)
        .fontColor(this.capMb === o.mb ? '#FFFFFF' : Theme.TEXT_DIM)
      Text(o.sub)
        .fontSize(9)
        .fontColor(this.capMb === o.mb ? '#D9FFFFFF' : Theme.TEXT_FAINT)
    }
    .width(72)
    .padding({ top: 7, bottom: 7 })
    .backgroundColor(this.capMb === o.mb ? Theme.ACCENT : Theme.CARD_HI)
    .borderRadius(13)
    .margin({ right: 8, bottom: 6 })
    .onClick(() => {
      this.pickCap(o.mb);
    })
  }

  @Builder
  ActionButton(label: string, danger: boolean, act: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(danger ? Theme.DANGER : Theme.TEXT)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(Theme.CARD_HI)
      .borderRadius(9)
      .onClick(() => {
        act();
      })
  }

  @Builder
  ServerBlock() {
    Column({ space: 10 }) {
      Row() {
        Text('当前服务器')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.serverFreeMb > 0 ? `剩余 ${this.humanMb(this.serverFreeMb)}` : '')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      Text(this.serverKinds.length > 0
        ? `共 ${this.humanMb(this.serverTotalMb)}。这一块在 NAS 上，不是你手机里的空间。`
        : '正在读取…')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(15)

      if (this.serverNote.length > 0) {
        Text(this.serverNote)
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .width('100%')
          .lineHeight(15)
      }

      ForEach(this.serverKinds, (k: ServerKind) => {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(k.label)
              .fontSize(13)
              .fontColor(Theme.TEXT)
            if (k.status === 'over') {
              Text('超限')
                .fontSize(9)
                .fontColor('#FF6B6B')
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor('#33FF6B6B')
            } else if (k.status === 'near') {
              Text('接近上限')
                .fontSize(9)
                .fontColor('#FFB84D')
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor('#33FFB84D')
            }
            Blank()
            Text(this.humanMb(k.used_mb))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(k.status === 'over' ? '#FF6B6B' : Theme.ACCENT)
          }
          .width('100%')

          Row({ space: 8 }) {
            if (k.key === 'play' && this.playSplitOk) {
              // 分源显示：网盘那份可调、本地那份固定（没有调节入口）
              Column({ space: 2 }) {
                Row() {
                  Text('网盘片')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_DIM)
                  Blank()
                  Text(`${this.humanMb(this.pRemoteUsed)} / `
                    + `${this.pRemoteBudget > 0 ? this.humanMb(this.pRemoteBudget) : '不限'}`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT)
                }
                .width('100%')

                Row() {
                  Text('本地片 · 固定')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_DIM)
                  Blank()
                  Text(`${this.humanMb(this.pLocalUsed)} / `
                    + `${this.pLocalBudget > 0 ? this.humanMb(this.pLocalBudget) : '—'}`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT)
                }
                .width('100%')
              }
              .layoutWeight(1)
            } else {
              Text(k.cleanable
                // 上限为 0 表示"不限"，别写成 "0 MB"
                ? (k.budget_mb > 0 ? `上限 ${this.humanMb(k.budget_mb)}` : '上限 不限')
                : '用户数据 · 永不自动清理')
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .layoutWeight(1)
            }
            if (k.cleanable) {
              if (k.key === 'frames') {
                // 刷一刷/预览共用的那份上限只在「设置 → 刷一刷」里改（2026-11-15 收敛成一处），
                // 这里给跳转，避免同一个值有两个编辑位。
                Text('去刷一刷改')
                  .fontSize(10)
                  .fontColor(Theme.ACCENT)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(8)
                  .backgroundColor(Theme.accentAlpha(0.12))
                  .onClick(() => {
                    router.pushUrl({ url: 'pages/ShortsSettingsPage' });
                  })
              } else {
                Text('改上限')
                  .fontSize(10)
                  .fontColor(Theme.ACCENT)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(8)
                  .backgroundColor(Theme.accentAlpha(0.12))
                  .onClick(() => {
                    this.toggleCap(k);
                  })
              }
              Text('清理')
                .fontSize(10)
                .fontColor(Theme.TEXT_DIM)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(8)
                .backgroundColor('#14FFFFFF')
                .onClick(() => {
                  this.toggleClean(k);
                })
            }
          }
          .width('100%')

          // 档位条：点开后一行平铺，选完即生效并收起
          if (this.capOpen === k.key) {
            Row({ space: 6 }) {
              ForEach(this.capsFor(k.key), (c: CapOpt) => {
                Text(c.label)
                  .fontSize(10)
                  .fontColor(k.budget_mb === c.mb ? '#FFFFFF' : Theme.TEXT_DIM)
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .borderRadius(9)
                  .backgroundColor(k.budget_mb === c.mb ? Theme.accentAlpha(0.55) : '#14FFFFFF')
                  .onClick(() => {
                    this.applyServerCap(k, c.mb);
                    this.capOpen = '';
                  })
              }, (c: CapOpt) => `${k.key}-cap-${c.mb}`)
            }
            .width('100%')
            .padding({ top: 2, bottom: 2 })
          }

          // 清理：播放缓存给三档（用户 2026-11-14 22:33 要求），其余块一次确认
          if (this.cleanConfirm === k.key) {
            if (k.key === 'play') {
              // 播放缓存三档。全清写在最后并单独标红，因为它最伤体验
              Column({ space: 6 }) {
                Text('清哪些？这块清掉后重看和拖动要重新下载')
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                Row({ space: 6 }) {
                  Text('7 天没看的')
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                    .borderRadius(9)
                    .backgroundColor(Theme.accentAlpha(0.55))
                    .onClick(() => {
                      this.cleanConfirm = '';
                      this.doCleanServer('play', 7);
                    })
                  Text('30 天没看的')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_DIM)
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                    .borderRadius(9)
                    .backgroundColor('#14FFFFFF')
                    .onClick(() => {
                      this.cleanConfirm = '';
                      this.doCleanServer('play', 30);
                    })
                  Text('全部清空')
                    .fontSize(10)
                    .fontColor('#FF8A8A')
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                    .borderRadius(9)
                    .backgroundColor('#26FF6B6B')
                    .onClick(() => {
                      this.cleanConfirm = '';
                      this.doCleanServer('play', 0);
                    })
                  Text('取消')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .onClick(() => {
                      this.cleanConfirm = '';
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding({ top: 4, bottom: 2 })
            } else {
              Row({ space: 8 }) {
                Text('只删缓存，收藏/进度不受影响')
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
                  .layoutWeight(1)
                Text('取消')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.cleanConfirm = '';
                  })
                Text('确认清理')
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                  .borderRadius(9)
                  .backgroundColor('#CCFF6B6B')
                  .onClick(() => {
                    this.cleanConfirm = '';
                    this.doCleanServer(k.key);
                  })
              }
              .width('100%')
              .padding({ top: 2, bottom: 2 })
            }
          }

          Text(k.desc)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(13)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .border({ width: { bottom: 0.5 }, color: '#14FFFFFF' })
      }, (k: ServerKind) => k.key)

      // 分源说明（2026-11-15）：讲清「这份预算是给谁的」，省得用户以为本地片也被卡着
      if (this.playSplitOk) {
        Text('只有把网盘挂成媒体库时才需要在这里分配空间；本地片在 NAS 本地盘上，缓存收益很小，'
          + '用固定的小额度（128 MB），没有调节入口。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(14)
      }

      // 老版本播放缓存：实测 2026-11-14 这块有 1.9 G 完全在预算之外（v4 才受管）
      if (this.stalePlayMb > 5) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(`老版本播放缓存 ${this.humanMb(this.stalePlayMb)}`)
              .fontSize(12)
              .fontColor(Theme.TEXT)
            Text('旧格式留下的，永远不会再用到，可以放心清掉')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('清掉')
            .fontSize(10)
            .fontColor(Theme.ACCENT)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(9)
            .backgroundColor(Theme.accentAlpha(0.16))
            .onClick(() => {
              this.doCleanServer('stale-play');
            })
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor('#14FFB84D')
      }

      // 「超限会怎样 / 为什么留够空间」——用户要求把这两句讲明白
      Column({ space: 3 }) {
        Text('超限了会怎样')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_DIM)
        Text('按「最久没用」先删，正在看的那部不会被删；照片和数据库永远不会被自动清理。'
          + '所以超限不会让功能坏掉，只是下次看旧片要重新缓冲。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(13)
        Text('留够空间的好处')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_DIM)
          .margin({ top: 4 })
        Text('磁盘写满会让整个服务变慢甚至报错（升级备份也会失败）。'
          + '给缓存留出余量，翻列表更快、拖进度不卡、升级时还有空间打快照。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(13)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 6 })
      .border({ width: { top: 0.5 }, color: '#14FFFFFF' })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('空间管理')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          // ---- 服务端（这台 NAS）----
          // 用户 2026-11-14：「服务端已经有六七个 G 了」——之前这一页只讲手机侧，
          // 服务器上那 7 G 在设置里完全看不到，只能登上去 du。
          this.ServerBlock()

          // ---- 这台手机 ----
          Text('这台手机')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .letterSpacing(1)
            .width('100%')

          // 总览
          Column({ space: 6 }) {
            Row() {
              Text('图片与页面数据（小计）')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.totalText())
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text('这一行只是下面两张卡的合计：图片缓存 + 页面数据。不含离线下载的影片，也不含服务器上的空间。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Text(`本次运行：本地图命中 ${this.hits} 次 · 新下载 ${this.fetched} 张`)
              .fontSize(10)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 图片
          Column({ space: 8 }) {
            Row() {
              Text('图片缓存')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(`${this.imgCount} 张 · ${this.human(this.imgBytes)}`)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text('海报、剧照、头像。看过一次就存一份到手机：下次进 App 直接读本地，不再一张张重新下载。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Row({ space: 8 }) {
              this.ActionButton('清理图片缓存', true, () => {
                this.clearImages();
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 上限
          Column({ space: 8 }) {
            Row() {
              Text('缓存上限')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.capMb <= 0 ? '不限制' : `${this.capMb >= 1024 ? this.capMb / 1024 + ' GB' : this.capMb + ' MB'}`)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text('图片缓存超过上限时，自动删「最久没用过」的那些，不会无限占空间。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(CAPS, (o: CapOpt) => {
                this.CapChip(o)
              }, (o: CapOpt) => `cap-${o.mb}`)
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 页面数据
          Column({ space: 8 }) {
            Row() {
              Text('页面数据')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(`${this.pageCount} 条 · ${this.humanKb(this.pageKb)}`)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text('首页、媒体库、详情页这些接口的返回。切页面时先用上次那份铺出来，网络回来再悄悄换新。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Row({ space: 8 }) {
              this.ActionButton('清理页面数据', true, () => {
                this.clearPages();
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 一键全清：范围就是上面两张卡（图片 + 页面数据），紧跟在它们后面，不挨着下面的手机其他占用
          Column({ space: 8 }) {
            Row() {
              Text('清理图片与页面缓存')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.busy ? '清理中…' : '清理')
                .fontSize(12)
                .fontColor(Theme.DANGER)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(9)
                .onClick(() => {
                  this.clearAll();
                })
            }
            .width('100%')
            Text('只清海报/剧照图和接口返回的页面数据；离线下载的影片、服务器上的空间都不动。清掉之后第一次进页面会慢一点。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 手机侧其余四块（2026-11-14 22:14 用户：「客户端也有对应的问题吧？」）
          // 离线影片 / 抽卡截图 / 导出图 / 播放器配置，以前在设置里完全看不到。
          if (this.cliKinds.length > 0) {
            Column({ space: 10 }) {
              Text('手机上的其他占用')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .width('100%')

              ForEach(this.cliKinds, (k: CliKind) => {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(k.label)
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                    Blank()
                    Text(this.humanBytes(k.bytes))
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ACCENT)
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Text(k.cleanable
                      ? `${k.files} 个文件`
                      : '你自己下载的 · 永不自动清理')
                      .fontSize(10)
                      .fontColor(Theme.TEXT_DIM)
                      .layoutWeight(1)
                    if (k.cleanable) {
                      Text('清理')
                        .fontSize(10)
                        .fontColor(Theme.TEXT_DIM)
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .borderRadius(8)
                        .backgroundColor('#14FFFFFF')
                        .onClick(() => {
                          this.clearCli(k.key, k.label);
                        })
                    }
                  }
                  .width('100%')

                  Text(k.desc)
                    .fontSize(9)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                    .lineHeight(13)
                }
                .width('100%')
                .padding({ top: 6, bottom: 6 })
                .border({ width: { bottom: 0.5 }, color: '#14FFFFFF' })
              }, (k: CliKind) => k.key)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
          }

          if (this.note.length > 0) {
            Text(this.note)
              .fontSize(11)
              .fontColor(Theme.ACCENT)
              .width('100%')
              .padding({ left: 4, top: 2 })
          }

          Blank().height(20)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
