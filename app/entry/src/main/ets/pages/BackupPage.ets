/**
 * 数据导出 / 导入（2.6.1.56）。
 *
 * 导出：收藏 / 评分 / 历史 / 稍后再看 / 清单 + 内容快照，落地成一个 JSON 文件。
 * 导入：**先预览再灌**（`dry_run=1`：只统计不写库），可以只导其中几类；
 *       真正导入前服务端会拍一张快照，搞坏了能「撤销上次导入」整表恢复。
 *
 * 匹配口径是**番号**（`metadata_id` 换库就失效，番号才是稳定主键），匹配不到的列出来，不猜。
 */
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

interface ImportResult {
  ok: boolean;
  mode: string;
  dry_run: boolean;
  applied: Record<string, number>;
  matched: number;
  unmatched: string[];
  unmatched_count: number;
  snapshot: string;
}

interface RollbackInfo {
  available: boolean;
  file: string;
  taken_at: string;
  counts: Record<string, number>;
}

const KIND_KEYS: string[] = ['favorites', 'ratings', 'history', 'watch_later', 'collections'];
const KIND_LABELS: string[] = ['收藏', '评分', '历史', '稍后再看', '清单'];

@Entry
@Component
struct BackupPage {
  @State busy: boolean = false;
  @State note: string = '';
  @State detail: string = '';
  /** 选好但还没灌的备份正文。 */
  @State pickedText: string = '';
  @State pickedName: string = '';
  @State preview: ImportResult | null = null;
  /** 五类各要不要导（默认全要）。 */
  @State kindsOn: boolean[] = [true, true, true, true, true];
  @State rbAvail: boolean = false;
  @State rbText: string = '';

  aboutToAppear(): void {
    this.loadRollback();
  }

  private today(): string {
    const d: Date = new Date();
    const m: string = `${d.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${d.getDate()}`.padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }

  private toast(msg: string): void {
    this.note = msg;
    setTimeout(() => {
      this.note = '';
    }, 2600);
  }

  private async loadRollback(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/backup/rollback-info`, Store.I.token);
      const info = JSON.parse(text) as RollbackInfo;
      this.rbAvail = info.available === true;
      if (this.rbAvail) {
        const c: Record<string, number> = info.counts === undefined || info.counts === null
          ? {} : info.counts;
        const at: string = (info.taken_at === undefined ? '' : info.taken_at)
          .replace('T', ' ').substring(0, 16);
        this.rbText = `上一次导入前（${at}）：收藏 ${c['favorites']} · 评分 ${c['ratings']} · ` +
          `历史 ${c['history']} · 稍后再看 ${c['watch_later']}`;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] rollback info: ${e.code}`);
    }
  }

  /** 导出：拉 JSON → 让用户挑保存位置 → 写文件。 */
  private async doExport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.detail = '';
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/backup/export`, Store.I.token);
      const data = JSON.parse(text) as Record<string, Object>;
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [`amane-backup-${this.today()}.json`];
      const ctx = getContext(this) as common.UIAbilityContext;
      const uris: string[] = await new picker.DocumentViewPicker(ctx).save(opts);
      if (uris === undefined || uris.length === 0) {
        this.toast('已取消');
        this.busy = false;
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      const n: number = Number(data['count'] as number);
      this.detail = `已导出 ${isNaN(n) ? '' : n} 条记录`;
      this.toast('导出成功');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] backup export: ${e.code} ${e.message}`);
      this.toast(`导出失败（${e.code}）`);
    }
    this.busy = false;
  }

  /** 第一步：选文件 → 读文本 → dry_run 预览（不写库）。 */
  private async pickAndPreview(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.preview = null;
    this.detail = '';
    try {
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.json'];
      const ctx = getContext(this) as common.UIAbilityContext;
      const uris: string[] = await new picker.DocumentViewPicker(ctx).select(opts);
      if (uris === undefined || uris.length === 0) {
        this.toast('已取消');
        this.busy = false;
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const body = JSON.parse(text) as Record<string, Object>;
      if (body['items'] === undefined) {
        this.toast('文件不像是备份（缺 items）');
        this.busy = false;
        return;
      }
      this.pickedText = text;
      const slash: number = uris[0].lastIndexOf('/');
      this.pickedName = slash >= 0 ? uris[0].substring(slash + 1) : uris[0];
      const resp: string = await httpPost(
        `${Store.I.user}/api/user/backup/import?dry_run=1`, Store.I.token, text);
      this.preview = JSON.parse(resp) as ImportResult;
      this.toast('已预览，确认后才会写入');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] backup preview: ${e.code} ${e.message}`);
      this.toast(`读取失败（${e.code}）`);
    }
    this.busy = false;
  }

  private selectedKinds(): string {
    const out: string[] = [];
    for (let i = 0; i < KIND_KEYS.length; i++) {
      if (this.kindsOn[i]) {
        out.push(KIND_KEYS[i]);
      }
    }
    return out.length === 0 ? '' : out.join(',');
  }

  /** 第二步：确认导入（只带用户勾选的类别）。 */
  private async doImport(): Promise<void> {
    if (this.busy || this.pickedText.length === 0) {
      return;
    }
    const kinds: string = this.selectedKinds();
    if (kinds.length === 0) {
      this.toast('至少选一类');
      return;
    }
    this.busy = true;
    try {
      const resp: string = await httpPost(
        `${Store.I.user}/api/user/backup/import?kinds=${kinds}`, Store.I.token, this.pickedText);
      const r = JSON.parse(resp) as ImportResult;
      const un: string[] = r.unmatched === undefined || r.unmatched === null ? [] : r.unmatched;
      this.detail = `已导入：匹配 ${r.matched} 部` +
        (r.unmatched_count > 0 ? `，没找到 ${r.unmatched_count} 部（${un.slice(0, 3).join('、')}…）` : '') +
        '。搞错了可以点下面的「撤销上次导入」。';
      this.preview = null;
      this.pickedText = '';
      this.pickedName = '';
      this.toast('导入完成');
      this.loadRollback();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] backup import: ${e.code} ${e.message}`);
      this.toast(`导入失败（${e.code}）`);
    }
    this.busy = false;
  }

  /** 撤销：把数据恢复到「上一次导入前」。 */
  private askRollback(): void {
    AlertDialog.show({
      title: '撤销上次导入？',
      message: '会把收藏、评分、历史、稍后再看、清单整体恢复成上一次导入之前的样子。' +
        '这之后你自己新增的记录也会一起丢，确定吗？',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '撤销',
        fontColor: Theme.DANGER,
        action: () => {
          this.doRollback();
        }
      }
    });
  }

  private async doRollback(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const resp: string = await httpPost(
        `${Store.I.user}/api/user/backup/rollback`, Store.I.token, '{}');
      const r = JSON.parse(resp) as Record<string, Object>;
      const c = r['counts'] as Record<string, number>;
      this.detail = `已回滚：收藏 ${c['favorites']} · 评分 ${c['ratings']} · ` +
        `历史 ${c['history']} · 稍后再看 ${c['watch_later']}`;
      this.toast('已恢复到导入前');
      this.loadRollback();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] rollback: ${e.code} ${e.message}`);
      this.toast(`回滚失败（${e.code}）`);
    }
    this.busy = false;
  }

  @Builder
  Entry(title: string, desc: string, action: string, run: () => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT)
        Text(desc)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(14)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(action)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(Theme.ACCENT)
        .borderRadius(14)
        .onClick(() => {
          run();
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  PreviewCard() {
    if (this.preview !== null && this.preview !== undefined) {
      Column({ space: 8 }) {
        Text(`预览：${this.pickedName}`)
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`匹配 ${this.preview.matched} 部` +
          (this.preview.unmatched_count > 0 ? `，没找到 ${this.preview.unmatched_count} 部` : '') +
          `（收藏 ${this.preview.applied['favorites']} · 评分 ${this.preview.applied['ratings']} · ` +
          `历史 ${this.preview.applied['history']} · 稍后再看 ${this.preview.applied['watch_later']} · ` +
          `清单 ${this.preview.applied['collections']}）`)
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
          .lineHeight(15)
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(KIND_LABELS, (label: string, i: number) => {
            Text(`${this.kindsOn[i] ? '✓ ' : ''}${label}`)
              .fontSize(10)
              .fontColor(this.kindsOn[i] ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.kindsOn[i] ? Theme.ACCENT : Theme.CARD)
              .borderRadius(10)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                const next: boolean[] = this.kindsOn.slice();
                next[i] = !next[i];
                this.kindsOn = next;
              })
          }, (label: string) => label)
        }
        .width('100%')
        Row({ space: 8 }) {
          Text('取消')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(Theme.CARD)
            .borderRadius(12)
            .onClick(() => {
              this.preview = null;
              this.pickedText = '';
              this.pickedName = '';
            })
          Blank()
          Text('确认导入')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(12)
            .onClick(() => {
              this.doImport();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor(Theme.CARD)
      .borderRadius(Theme.RADIUS)
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text('‹')
            .fontSize(20)
            .fontColor(Theme.TEXT)
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              router.back();
            })
          Text('数据备份与迁移')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Blank()
          if (this.busy) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(Theme.ACCENT)
          }
        }
        .width('100%')
        .padding({ left: 6, right: Theme.PAGE_PAD, top: 10, bottom: 2 })

        Text(this.note.length > 0 ? this.note : (this.detail.length > 0 ? this.detail : ' '))
          .fontSize(11)
          .fontColor(this.note.length > 0 ? Theme.ACCENT : Theme.TEXT_DIM)
          .lineHeight(15)
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

        Column({ space: 10 }) {
          this.Entry('导出备份', '收藏、评分、历史、稍后再看、清单 + 内容快照，存成一个 JSON 文件',
            '导出', () => {
              this.doExport();
            })
          this.Entry('导入备份', '先预览再导入，可只导其中几类；导入前会自动留一份快照',
            '选文件', () => {
              this.pickAndPreview();
            })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

        Column() {
          this.PreviewCard()
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

        if (this.rbAvail) {
          Column({ space: 8 }) {
            Text('撤销上次导入')
              .fontSize(13)
              .fontColor(Theme.TEXT)
              .width('100%')
            Text(this.rbText)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .lineHeight(14)
              .width('100%')
            Text('恢复到导入前')
              .fontSize(11)
              .fontColor(Theme.DANGER)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(Theme.CARD)
              .borderRadius(12)
              .onClick(() => {
                this.askRollback();
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)
          .margin({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }

        Text('导出文件里只有「番号 + 标题 + 片商」这类快照信息和你自己的数据，不含账号凭据；' +
          '重复导入不会产生重复记录，进度取更靠后的那个。')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(15)
          .width('100%')
          .padding({ left: Theme.PAGE_PAD + 2, right: Theme.PAGE_PAD + 2, bottom: 20 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
