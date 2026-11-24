import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { CliKind, cliReport, cliClear } from '../common/CliStorage';
import { cacheClear, cacheCount, cacheSizeKb } from '../common/PageCache';
import { imgCacheBytes, imgCacheCap, imgCacheClear, imgCacheCount, imgCacheFetched, imgCacheHits, imgCacheSetCap } from '../common/ImgCache';
import { httpGet, httpPost, httpPut } from '../common/Http';
import { Store } from '../common/Store';
import { GlassBack, GlassBox, PageTitle } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsBarSectionTitle, SettingsChevron,
  SettingsIconTile, SettingsRowDivider, VelvetChip
} from '../view/SettingsKit';

interface CapOpt {
  mb: number;
  label: string;
  sub: string;
}

const CAPS: CapOpt[] = [
  { mb: 200, label: '200 MB', sub: '小' },
  { mb: 500, label: '500 MB', sub: '推荐' },
  { mb: 1024, label: '1 GB', sub: '大' },
  { mb: 0, label: '不限', sub: '按需' }
];

interface ServerKind {
  key: string;
  label: string;
  used_mb: number;
  files: number;
  budget_mb: number;
  status: string;
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

interface SetResp {
  ok: boolean;
  key?: string;
  mb?: number;
  report?: ServerReport;
}

interface CleanResp {
  ok: boolean;
  key?: string;
  freed_mb?: number;
  files?: number;
  removed?: string[];
  report?: ServerReport;
}

class CleanReq {
  key: string = '';
  age_days: number = -1;
}

interface PlaySplit {
  remote_used_mb?: number;
  remote_budget_mb?: number;
  local_used_mb?: number;
  local_budget_mb?: number;
}

const SERVER_CAPS: CapOpt[] = [
  { mb: 1024, label: '1 GB', sub: '省' },
  { mb: 2048, label: '2 GB', sub: '小' },
  { mb: 4096, label: '4 GB', sub: '推荐' },
  { mb: 8192, label: '8 GB', sub: '大' },
  { mb: 0, label: '不限', sub: '按盘' }
];

const PLAY_CAPS: CapOpt[] = [
  { mb: 512, label: '512 MB', sub: '热数据' },
  { mb: 1024, label: '1 GB', sub: '省' },
  { mb: 2048, label: '2 GB', sub: '小' },
  { mb: 4096, label: '4 GB', sub: '推荐' },
  { mb: 8192, label: '8 GB', sub: '大' },
  { mb: 0, label: '不限', sub: '按盘' }
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
  @State hits: number = 0;
  @State fetched: number = 0;
  @State serverKinds: ServerKind[] = [];
  @State serverTotalMb: number = 0;
  @State serverFreeMb: number = 0;
  @State stalePlayMb: number = 0;
  @State serverNote: string = '';
  @State pRemoteUsed: number = 0;
  @State pRemoteBudget: number = 0;
  @State pLocalUsed: number = 0;
  @State pLocalBudget: number = 0;
  @State playSplitOk: boolean = false;
  @State capOpen: string = '';
  @State cleanConfirm: string = '';
  @State playAgePick: number = 7;
  @State cliKinds: CliKind[] = [];
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.reloadAll();
  }

  private reloadAll(): void {
    this.refresh();
    this.refreshCli();
    this.loadServer();
  }

  private refreshCli(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const all: CliKind[] = cliReport(ctx, imgCacheCap());
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

  private humanMb(mb: number): string {
    if (mb <= 0) {
      return '0 MB';
    }
    if (mb >= 1024 * 1024) {
      return `${(mb / (1024 * 1024)).toFixed(2)} TB`;
    }
    if (mb >= 1024) {
      return `${(mb / 1024).toFixed(2)} GB`;
    }
    if (mb >= 10) {
      return `${Math.round(mb)} MB`;
    }
    return `${mb.toFixed(1)} MB`;
  }

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
      const e = err as BusinessError;
      this.serverNote = `取不到服务器空间信息（${e.code === undefined ? '?' : e.code}），较老服务端需升级后支持。`;
    }
  }

  private capsFor(key: string): CapOpt[] {
    return key === 'play' ? PLAY_CAPS : SERVER_CAPS;
  }

  private async loadPlaySplit(): Promise<void> {
    try {
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
      const r: SetResp = JSON.parse(text) as SetResp;
      if (r.report !== undefined && r.report !== null) {
        this.serverKinds = r.report.kinds === undefined ? [] : r.report.kinds;
        this.serverTotalMb = r.report.total_mb === undefined ? 0 : r.report.total_mb;
        this.serverFreeMb = r.report.free_mb === undefined ? 0 : r.report.free_mb;
        this.stalePlayMb = r.report.stale_play_mb === undefined ? 0 : r.report.stale_play_mb;
      }
      if (k.key === 'play') {
        this.loadPlaySplit();
      }
      this.note = mb <= 0 ? `${k.label}上限已设为不限` : `${k.label}上限已改为 ${this.humanMb(mb)}`;
    } catch (err) {
      const e = err as BusinessError;
      this.note = `设置失败（${e.code === undefined ? '?' : e.code}）`;
    }
    this.busy = false;
  }

  private async doCleanServer(key: string, ageDays: number = -1): Promise<void> {
    this.busy = true;
    try {
      const req: CleanReq = new CleanReq();
      req.key = key;
      req.age_days = ageDays;
      const text: string = await httpPost(`${Store.I.user}/api/user/storage/clean`, Store.I.token, JSON.stringify(req));
      const r: CleanResp = JSON.parse(text) as CleanResp;
      if (r.report !== undefined && r.report !== null) {
        this.serverKinds = r.report.kinds === undefined ? [] : r.report.kinds;
        this.serverTotalMb = r.report.total_mb === undefined ? 0 : r.report.total_mb;
        this.serverFreeMb = r.report.free_mb === undefined ? 0 : r.report.free_mb;
        this.stalePlayMb = r.report.stale_play_mb === undefined ? 0 : r.report.stale_play_mb;
      }
      if (key === 'play' || key === 'stale-play') {
        this.loadPlaySplit();
      }
      const freed: number = r.freed_mb === undefined ? 0 : r.freed_mb;
      this.note = freed > 0 ? `已释放 ${this.humanMb(freed)}` : '没有需要清理的文件';
    } catch (err) {
      const e = err as BusinessError;
      this.note = `清理失败（${e.code === undefined ? '?' : e.code}）`;
    }
    this.busy = false;
  }

  private totalText(): string {
    return this.human(this.imgBytes + this.pageKb * 1024);
  }

  private clearAll(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const a: number = imgCacheClear();
    const b: number = cacheClear();
    this.note = `已清掉 ${a} 张图片与 ${b} 条页面快照`;
    this.refresh();
    this.busy = false;
  }

  private pickCap(mb: number): void {
    this.capMb = mb;
    imgCacheSetCap(mb <= 0 ? 1024 * 1024 * 1024 * 8 : mb * 1024 * 1024);
    this.refresh();
    this.note = mb <= 0 ? '图片缓存上限已设为不限制' : `图片缓存上限已改为 ${mb >= 1024 ? mb / 1024 + ' GB' : mb + ' MB'}`;
  }

  private serverBudgetSumMb(): number {
    let sum: number = 0;
    for (let i = 0; i < this.serverKinds.length; i++) {
      if (this.serverKinds[i].budget_mb > 0) {
        sum += this.serverKinds[i].budget_mb;
      }
    }
    return sum;
  }

  private kindUsedMb(key: string): number {
    for (let i = 0; i < this.serverKinds.length; i++) {
      if (this.serverKinds[i].key === key) {
        return this.serverKinds[i].used_mb;
      }
    }
    return 0;
  }

  private otherKindsUsedMb(): number {
    let sum: number = 0;
    for (let i = 0; i < this.serverKinds.length; i++) {
      const k: ServerKind = this.serverKinds[i];
      if (k.key !== 'play' && k.key !== 'frames') {
        sum += k.used_mb;
      }
    }
    return sum;
  }

  private barPct(used: number, budget: number): string {
    if (used <= 0) {
      return '0%';
    }
    if (budget <= 0) {
      return '28%';
    }
    const p: number = Math.min(100, Math.max(4, Math.round((used / budget) * 100)));
    return `${p}%`;
  }

  private stackPct(part: number): string {
    const denom: number = Math.max(this.serverTotalMb, this.serverBudgetSumMb(), 1);
    if (part <= 0) {
      return '0%';
    }
    const p: number = Math.min(100, Math.max(2, Math.round((part / denom) * 100)));
    return `${p}%`;
  }

  private iconForKind(key: string): Resource {
    if (key === 'play') {
      return $r('sys.symbol.play_circle');
    }
    if (key === 'frames') {
      return $r('sys.symbol.layer');
    }
    return $r('sys.symbol.externaldrive');
  }

  @Builder
  ServerHeroCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('服务端缓存总计')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .layoutWeight(1)
        if (this.serverFreeMb > 0) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.externaldrive'))
              .fontSize(11)
              .fontColor(['#8EE6B4'])
            Text(`磁盘剩余 ${this.humanMb(this.serverFreeMb)}`)
              .fontSize(10.5)
              .fontWeight(FontWeight.Medium)
              .fontColor('#8EE6B4')
              .fontFeature('"tnum" 1')
          }
          .padding({ left: 9, right: 10, top: 4, bottom: 4 })
          .backgroundColor('#1A45B075')
          .border({ width: 0.5, color: '#4245B075' })
          .borderRadius(Theme.R_PILL)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text(this.serverKinds.length > 0 ? this.humanMb(this.serverTotalMb) : '读取中…')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .fontFeature('"tnum" 1')
        if (this.serverBudgetSumMb() > 0) {
          Text(`/ ${this.humanMb(this.serverBudgetSumMb())} 预算`)
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
            .fontFeature('"tnum" 1')
            .margin({ bottom: 3 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      // 三段堆积存储条（播放缓存 / 预览与刷一刷 / 其他）
      Row({ space: 2 }) {
        if (this.kindUsedMb('play') > 0) {
          Column()
            .width(this.stackPct(this.kindUsedMb('play')))
            .height(8)
            .borderRadius(4)
            .linearGradient(Theme.ctaGradient())
        }
        if (this.kindUsedMb('frames') > 0) {
          Column()
            .width(this.stackPct(this.kindUsedMb('frames')))
            .height(8)
            .borderRadius(4)
            .backgroundColor('#F4C97E')
        }
        if (this.otherKindsUsedMb() > 0) {
          Column()
            .width(this.stackPct(this.otherKindsUsedMb()))
            .height(8)
            .borderRadius(4)
            .backgroundColor('#9E96C8')
        }
      }
      .width('100%')
      .height(8)
      .backgroundColor('#1AFFFFFF')
      .borderRadius(4)
      .clip(true)

      Row({ space: 12 }) {
        Row({ space: 5 }) {
          Row().width(7).height(7).borderRadius(3.5).backgroundColor(Theme.ACCENT2)
          Text(`播放 ${this.humanMb(this.kindUsedMb('play'))}`)
            .fontSize(10.5)
            .fontColor(Theme.TEXT_DIM)
            .fontFeature('"tnum" 1')
        }
        Row({ space: 5 }) {
          Row().width(7).height(7).borderRadius(3.5).backgroundColor('#F4C97E')
          Text(`预览 ${this.humanMb(this.kindUsedMb('frames'))}`)
            .fontSize(10.5)
            .fontColor(Theme.TEXT_DIM)
            .fontFeature('"tnum" 1')
        }
        if (this.otherKindsUsedMb() > 0) {
          Row({ space: 5 }) {
            Row().width(7).height(7).borderRadius(3.5).backgroundColor('#9E96C8')
            Text(`其他 ${this.humanMb(this.otherKindsUsedMb())}`)
              .fontSize(10.5)
              .fontColor(Theme.TEXT_DIM)
              .fontFeature('"tnum" 1')
          }
        }
      }
      .width('100%')

      if (this.serverNote.length > 0) {
        Text(this.serverNote)
          .fontSize(10.5)
          .fontColor(Theme.GOLD)
          .width('100%')
          .lineHeight(15)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 145,
      colors: [[Theme.accentAlpha(0.12), 0.0], ['#00000000', 0.62]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  ServerBreakdownCard() {
    Column() {
      ForEach(this.serverKinds, (k: ServerKind, idx: number) => {
        Column({ space: 10 }) {
          if (idx > 0) {
            SettingsRowDivider({ indent: 14 })
          }

          Column({ space: 10 }) {
            Row({ space: 10 }) {
              SettingsIconTile({ icon: this.iconForKind(k.key), tileSize: 34, iconSize: 16 })
              Row({ space: 6 }) {
                Text(k.label)
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                if (k.status === 'over') {
                  Text('超限')
                    .fontSize(9.5)
                    .fontColor(Theme.DANGER)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.16))
                    .borderRadius(Theme.R_PILL)
                } else if (k.status === 'near') {
                  Text('接近上限')
                    .fontSize(9.5)
                    .fontColor(Theme.GOLD)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor('#24FFD06B')
                    .borderRadius(Theme.R_PILL)
                }
              }
              .layoutWeight(1)
              .alignItems(VerticalAlign.Center)

              Text(k.budget_mb > 0 && k.key !== 'play'
                ? `${this.humanMb(k.used_mb)} / ${this.humanMb(k.budget_mb)}`
                : this.humanMb(k.used_mb))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(k.status === 'over' ? Theme.DANGER : Theme.ACCENT_INK)
                .fontFeature('"tnum" 1')
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (k.key === 'play' && this.playSplitOk) {
              Column({ space: 7 }) {
                Row({ space: 8 }) {
                  Text('网盘片')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                    .width(72)
                  Stack({ alignContent: Alignment.Start }) {
                    Column().width('100%').height(5).borderRadius(2.5).backgroundColor('#1AFFFFFF')
                    Column()
                      .width(this.barPct(this.pRemoteUsed, this.pRemoteBudget))
                      .height(5)
                      .borderRadius(2.5)
                      .linearGradient(Theme.ctaGradient())
                  }
                  .layoutWeight(1)
                  .height(5)
                  Text(`${this.humanMb(this.pRemoteUsed)} / ${this.pRemoteBudget > 0 ? this.humanMb(this.pRemoteBudget) : '不限'}`)
                    .fontSize(10.5)
                    .fontColor(Theme.TEXT_DIM)
                    .fontFeature('"tnum" 1')
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Row({ space: 8 }) {
                  Text('本地片 · 固定')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                    .width(72)
                  Stack({ alignContent: Alignment.Start }) {
                    Column().width('100%').height(5).borderRadius(2.5).backgroundColor('#1AFFFFFF')
                    Column()
                      .width(this.barPct(this.pLocalUsed, this.pLocalBudget))
                      .height(5)
                      .borderRadius(2.5)
                      .backgroundColor('#B8A8B6')
                  }
                  .layoutWeight(1)
                  .height(5)
                  Text(`${this.humanMb(this.pLocalUsed)} / ${this.pLocalBudget > 0 ? this.humanMb(this.pLocalBudget) : '—'}`)
                    .fontSize(10.5)
                    .fontColor(Theme.TEXT_DIM)
                    .fontFeature('"tnum" 1')
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
            } else if (k.cleanable) {
              Stack({ alignContent: Alignment.Start }) {
                Column().width('100%').height(5).borderRadius(2.5).backgroundColor('#1AFFFFFF')
                Column()
                  .width(this.barPct(k.used_mb, k.budget_mb))
                  .height(5)
                  .borderRadius(2.5)
                  .linearGradient(Theme.ctaGradient())
              }
              .width('100%')
              .height(5)
            }

            Row({ space: 8 }) {
              if (!k.cleanable) {
                Text('用户数据 · 永不自动清理')
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .layoutWeight(1)
              } else if (k.key === 'frames') {
                Text(k.desc)
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Row({ space: 3 }) {
                  Text('去刷一刷改')
                    .fontSize(11.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.ACCENT_INK)
                  SettingsChevron({ glyphSize: 11 })
                }
                .onClick(() => {
                  router.pushUrl({ url: 'pages/ShortsSettingsPage' });
                })
                Text('清理')
                  .fontSize(11)
                  .fontColor(Theme.DANGER)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.14))
                  .border({ width: 0.5, color: Theme.alphaOf(Theme.DANGER, 0.34) })
                  .borderRadius(Theme.R_PILL)
                  .onClick(() => {
                    this.toggleClean(k);
                  })
              } else {
                Row({ space: 5 }) {
                  SymbolGlyph($r('sys.symbol.gearshape'))
                    .fontSize(12)
                    .fontColor([Theme.TEXT_DIM])
                  Text('改上限')
                    .fontSize(11.5)
                    .fontColor(Theme.TEXT)
                }
                .padding({ left: 11, right: 12, top: 6, bottom: 6 })
                .backgroundColor('#16FFFFFF')
                .border({ width: 0.5, color: '#24FFFFFF' })
                .borderRadius(Theme.R_PILL)
                .onClick(() => {
                  this.toggleCap(k);
                })

                Row({ space: 5 }) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(12)
                    .fontColor([Theme.DANGER])
                  Text('清理')
                    .fontSize(11.5)
                    .fontColor(Theme.DANGER)
                }
                .padding({ left: 11, right: 12, top: 6, bottom: 6 })
                .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.14))
                .border({ width: 0.5, color: Theme.alphaOf(Theme.DANGER, 0.34) })
                .borderRadius(Theme.R_PILL)
                .onClick(() => {
                  this.toggleClean(k);
                })
                Blank()
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.capOpen === k.key) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.capsFor(k.key), (c: CapOpt) => {
                  Column() {
                    VelvetChip({
                      label: c.label,
                      active: k.budget_mb === c.mb,
                      padH: 11,
                      padV: 6,
                      fs: 11,
                      onTap: () => {
                        this.applyServerCap(k, c.mb);
                        this.capOpen = '';
                      }
                    })
                  }
                  .margin({ right: 6, bottom: 6 })
                }, (c: CapOpt) => `${k.key}-cap-${c.mb}`)
              }
              .width('100%')
            }

            if (this.cleanConfirm === k.key) {
              if (k.key === 'play') {
                Column({ space: 8 }) {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    Column() {
                      VelvetChip({
                        label: '7 天没看的',
                        active: this.playAgePick === 7,
                        padH: 10,
                        padV: 5,
                        fs: 11,
                        onTap: () => { this.playAgePick = 7; }
                      })
                    }.margin({ right: 6, bottom: 6 })
                    Column() {
                      VelvetChip({
                        label: '30 天没看的',
                        active: this.playAgePick === 30,
                        padH: 10,
                        padV: 5,
                        fs: 11,
                        onTap: () => { this.playAgePick = 30; }
                      })
                    }.margin({ right: 6, bottom: 6 })
                    Column() {
                      VelvetChip({
                        label: '全部清空',
                        active: this.playAgePick === 0,
                        padH: 10,
                        padV: 5,
                        fs: 11,
                        onTap: () => { this.playAgePick = 0; }
                      })
                    }.margin({ right: 6, bottom: 6 })
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Text('取消')
                      .fontSize(11.5)
                      .fontColor(Theme.TEXT_DIM)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .onClick(() => { this.cleanConfirm = ''; })
                    Blank()
                    Text('确认清理')
                      .fontSize(11.5)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ON_ACCENT)
                      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                      .linearGradient(Theme.ctaGradient())
                      .border({ width: 0.5, color: '#38FFFFFF' })
                      .borderRadius(Theme.R_PILL)
                      .onClick(() => {
                        const age: number = this.playAgePick;
                        this.cleanConfirm = '';
                        this.doCleanServer('play', age);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#141114')
                .border({ width: 0.5, color: '#1CFFFFFF' })
                .borderRadius(12)
              } else {
                Row({ space: 8 }) {
                  Text('只清缓存，不动收藏与进度')
                    .fontSize(10.5)
                    .fontColor(Theme.TEXT_FAINT)
                    .layoutWeight(1)
                  Text('取消')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .onClick(() => { this.cleanConfirm = ''; })
                  Text('确认清理')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.ON_ACCENT)
                    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                    .linearGradient(Theme.ctaGradient())
                    .borderRadius(Theme.R_PILL)
                    .onClick(() => {
                      this.cleanConfirm = '';
                      this.doCleanServer(k.key);
                    })
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#141114')
                .border({ width: 0.5, color: '#1CFFFFFF' })
                .borderRadius(12)
              }
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 13, bottom: 13 })
        }
        .width('100%')
      }, (k: ServerKind) => `${k.key}-${k.used_mb}-${k.budget_mb}-${this.capOpen === k.key ? 1 : 0}-${this.cleanConfirm === k.key ? 1 : 0}-${this.playAgePick}`)

      if (this.stalePlayMb > 5) {
        SettingsRowDivider({ indent: 14 })
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(`老版本播放缓存 ${this.humanMb(this.stalePlayMb)}`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.GOLD)
            Text('旧格式残留，可安全释放')
              .fontSize(10.5)
              .fontColor(Theme.TEXT_FAINT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('清掉')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.GOLD)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('#24FFD06B')
            .border({ width: 0.5, color: '#4DFFD06B' })
            .borderRadius(Theme.R_PILL)
            .onClick(() => {
              this.doCleanServer('stale-play');
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.CARD)
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
    .clip(true)
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        PageTitle({ text: '空间管理', fs: 18 })
        Blank()
        GlassBox({
          radius: 20,
          padH: 10,
          padV: 10,
          mat: true,
          onTap: () => {
            this.reloadAll();
          }
        }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([Theme.TEXT])
        }
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

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

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        Scroll() {
          Column({ space: 14 }) {
            Blank().height(this.barH() + 6)

            // 当前服务器
            SettingsBarSectionTitle({ title: '当前服务器' })
            this.ServerHeroCard()
            if (this.serverKinds.length > 0 || this.stalePlayMb > 5) {
              this.ServerBreakdownCard()
            }

            // 这台手机
            SettingsBarSectionTitle({ title: '这台手机' })

            Column() {
              // 总计头行
              Row({ space: 10 }) {
                SettingsIconTile({ icon: $r('sys.symbol.picture'), tileSize: 34, iconSize: 16 })
                Column({ space: 2 }) {
                  Text('图片与页面数据')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text(`本地命中 ${this.hits} 次 · 新下载 ${this.fetched} 张`)
                    .fontSize(10.5)
                    .fontColor(Theme.TEXT_FAINT)
                    .fontFeature('"tnum" 1')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.totalText())
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.ACCENT_INK)
                  .fontFeature('"tnum" 1')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 12 })

              SettingsRowDivider({ indent: 14 })

              // 图片缓存 + 上限档位
              Column({ space: 10 }) {
                Row() {
                  Text('图片缓存（海报 / 剧照 / 头像）')
                    .fontSize(12.5)
                    .fontColor(Theme.TEXT)
                    .layoutWeight(1)
                  Text(`${this.imgCount} 张 · ${this.human(this.imgBytes)}`)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_DIM)
                    .fontFeature('"tnum" 1')
                }
                .width('100%')

                Row({ space: 7 }) {
                  ForEach(CAPS, (o: CapOpt) => {
                    VelvetChip({
                      label: o.label,
                      active: this.capMb === o.mb || (o.mb === 0 && this.capMb > 2048),
                      padH: 11,
                      padV: 6,
                      fs: 11.5,
                      onTap: () => {
                        this.pickCap(o.mb);
                      }
                    })
                  }, (o: CapOpt) => `cap-${o.mb}-${this.capMb}`)
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })

              SettingsRowDivider({ indent: 14 })

              // 页面快照
              Row() {
                Text('页面快照（冷启与切页秒开）')
                  .fontSize(12.5)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                Text(`${this.pageCount} 条 · ${this.humanKb(this.pageKb)}`)
                  .fontSize(12)
                  .fontColor(Theme.TEXT_DIM)
                  .fontFeature('"tnum" 1')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })

              SettingsRowDivider({ indent: 14 })

              // 清理图片与页面缓存
              Row({ space: 10 }) {
                SettingsIconTile({ icon: $r('sys.symbol.trash'), tileSize: 32, iconSize: 15, danger: true })
                Text(this.busy ? '清理中…' : '清理图片与页面缓存')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.DANGER)
                  .layoutWeight(1)
                SettingsChevron({ glyphSize: 13 })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .onClick(() => {
                this.clearAll();
              })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            // 手机上的其他占用（离线影片 / 截图 / 导出图 / 配置）
            if (this.cliKinds.length > 0) {
              Column() {
                ForEach(this.cliKinds, (k: CliKind, idx: number) => {
                  Column() {
                    if (idx > 0) {
                      SettingsRowDivider({ indent: 58 })
                    }
                    Row({ space: 10 }) {
                      SettingsIconTile({
                        icon: k.key === 'offline' ? $r('sys.symbol.download') : $r('sys.symbol.folder'),
                        tileSize: 34,
                        iconSize: 16
                      })
                      Column({ space: 2 }) {
                        Text(k.label)
                          .fontSize(13.5)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(Theme.TEXT)
                        Text(k.cleanable ? `${k.files} 个文件 · ${k.desc}` : '已离线影片 · 永不自动清理')
                          .fontSize(10.5)
                          .fontColor(Theme.TEXT_FAINT)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Text(this.humanBytes(k.bytes))
                        .fontSize(12.5)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.ACCENT_INK)
                        .fontFeature('"tnum" 1')

                      if (k.cleanable) {
                        Text('清理')
                          .fontSize(10.5)
                          .fontColor(Theme.DANGER)
                          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                          .backgroundColor(Theme.alphaOf(Theme.DANGER, 0.14))
                          .border({ width: 0.5, color: Theme.alphaOf(Theme.DANGER, 0.32) })
                          .borderRadius(Theme.R_PILL)
                          .onClick(() => {
                            this.clearCli(k.key, k.label);
                          })
                      } else if (k.key === 'offline') {
                        SettingsChevron({ glyphSize: 13 })
                      }
                    }
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                    .onClick(() => {
                      if (k.key === 'offline') {
                        router.pushUrl({ url: 'pages/OfflinePage' });
                      }
                    })
                  }
                  .width('100%')
                }, (k: CliKind) => `${k.key}-${k.bytes}`)
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)
            }

            if (this.note.length > 0) {
              Text(this.note)
                .fontSize(11)
                .fontColor(Theme.ACCENT_INK)
                .width('100%')
                .padding({ left: 4 })
            }

            Text('超限时按最久未用自动淘汰，不影响正在播放与数据库。')
              .fontSize(10.5)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ left: 4, right: 4 })

            Blank().height(Theme.pageBottomSafe())
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
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
