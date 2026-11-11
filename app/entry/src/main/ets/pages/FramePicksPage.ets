import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { httpDelete, httpGet, httpGetBytes, httpPut } from '../common/Http';
import { Gallery } from '../common/Gallery';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams } from '../common/Types';
import { clock } from '../common/Util';

/**
 * 我的截帧（R25 管理页）。
 *
 * 播放时随手截的那几帧，散在各部片里找不到，所以单独一页：
 * 看、跳（回到那一秒）、删（连剧照/封面关联一起清）、**存到相册**。
 *
 * 「存到相册」（用户第 10 条）= 下载 1280 大图 → 用系统的
 * `showAssetsCreationDialog` 写进媒体库（弹一次系统确认，不需要受限权限）。
 * 不再判断「是不是已经存过」——存没存是用户的事，按钮就是「再存一次」。
 */
interface PickRow {
  metadata_id: number;
  file_id: number;
  ms: number;
  t: number;
  still: boolean;
  created_at: string;
  url: string;
  number: string;
  title: string;
  poster: string;
}

function str(v: string | null | undefined): string {
  return typeof v === 'string' ? v : '';
}

function num(v: number | null | undefined): number {
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function safeRows(raw: PickRow[] | null | undefined): PickRow[] {
  const out: PickRow[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const it = raw[i];
    if (it === undefined || it === null) {
      continue;
    }
    out.push({
      metadata_id: Math.trunc(num(it.metadata_id)),
      file_id: Math.trunc(num(it.file_id)),
      ms: Math.trunc(num(it.ms)),
      t: num(it.t),
      still: it.still === true,
      created_at: str(it.created_at),
      url: str(it.url),
      number: str(it.number),
      title: str(it.title),
      poster: str(it.poster)
    });
  }
  return out;
}

@Entry
@Component
struct FramePicksPage {
  @State items: PickRow[] = [];
  @State loading: boolean = true;
  @State note: string = '';
  /** 截帧时是否同时存一份到相册（默认关，用户点名默认关）。 */
  @State saveLocal: boolean = false;
  /** 下载中/写相册中的条目（避免连点）。 */
  @State busyKey: string = '';

  aboutToAppear(): void {
    this.saveLocal = Store.I.prefString('frame_save_local', '0') === '1';
    this.load();
    this.ensureDir();
  }

  private keyOf(it: PickRow): string {
    return `${it.metadata_id}_${it.ms}.jpg`;
  }

  private pickDir(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return `${ctx.filesDir}/picks`;
  }

  /** 下载中转目录，必须有（沙箱里存一下才能交给系统写相册）。 */
  private ensureDir(): void {
    try {
      const dir: string = this.pickDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] scan picks: ${e.code} ${e.message}`);
    }
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/highlights/picks?limit=300`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.items = safeRows(obj.items as PickRow[]);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] picks: ${e.code} ${e.message}`);
      this.note = '读取失败';
    }
    this.loading = false;
  }

  private flash(t: string): void {
    this.note = t;
    setTimeout(() => {
      if (this.note === t) {
        this.note = '';
      }
    }, 1800);
  }

  private jump(it: PickRow): void {
    const p: DetailParams = {
      id: it.metadata_id,
      autoplay: true,
      position: it.t,
      fileKey: '',
      fileName: ''
    };
    router.pushUrl({ url: 'pages/DetailPage', params: p }).catch((err: BusinessError) => {
      console.error(`[amane] jump pick: ${err.code} ${err.message}`);
    });
  }

  /** 「这张算不算剧照」由用户自己定（R25 第 9 条）：改了立刻回写 still_likes。 */
  private async toggleStill(it: PickRow): Promise<void> {
    const want: boolean = !it.still;
    try {
      await httpPut(
        `${Store.I.user}/api/user/highlights/${it.metadata_id}/snap/${it.ms}`,
        Store.I.token, JSON.stringify({ still: want }));
      const next: PickRow[] = [];
      for (let i = 0; i < this.items.length; i++) {
        const x: PickRow = this.items[i];
        if (x.metadata_id === it.metadata_id && x.ms === it.ms) {
          next.push({
            metadata_id: x.metadata_id, file_id: x.file_id, ms: x.ms, t: x.t,
            still: want, created_at: x.created_at, url: x.url,
            number: x.number, title: x.title, poster: x.poster
          });
        } else {
          next.push(x);
        }
      }
      this.items = next;
      this.flash(want ? '已设为剧照' : '已移出剧照');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] toggle still: ${e.code} ${e.message}`);
      this.flash('改失败');
    }
  }

  /** 截帧抽卡：随机抽一张，全屏看（用现成的图片查看器）。 */
  private gacha(): void {
    if (this.items.length === 0) {
      return;
    }
    const idx: number = Math.floor(Math.random() * this.items.length);
    const urls: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      urls.push(this.items[i].url);
    }
    router.pushUrl({
      url: 'pages/ImageViewerPage',
      params: { urls: urls, index: idx }
    }).catch((err: BusinessError) => {
      console.error(`[amane] gacha picks: ${err.code} ${err.message}`);
    });
  }

  private askDelete(it: PickRow): void {
    AlertDialog.show({
      title: '删掉这一帧？',
      message: '亮点条里这张会消失；如果它同时进了剧照，也会一起移除。影片本身不受影响。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.DANGER,
        action: () => {
          this.remove(it);
        }
      }
    });
  }

  private async remove(it: PickRow): Promise<void> {
    try {
      await httpDelete(
        `${Store.I.user}/api/user/highlights/${it.metadata_id}/snap/${it.ms}`, Store.I.token);
      this.items = this.items.filter((x: PickRow) => !(x.metadata_id === it.metadata_id && x.ms === it.ms));
      this.flash('已删除');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] del pick: ${e.code} ${e.message}`);
      this.flash('删除失败');
    }
  }

  /** 下载一帧到沙箱（交给系统相册前的中转，也顺便留个本地副本）。 */
  private async downloadToLocal(it: PickRow): Promise<string> {
    const dir: string = this.pickDir();
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const path: string = `${dir}/${this.keyOf(it)}`;
    const bytes: ArrayBuffer = await httpGetBytes(Store.I.img(it.url), Store.I.token);
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes);
    } finally {
      fs.closeSync(file);
    }
    return path;
  }

  /**
   * 「保存到相册」（用户第 10 条）。
   *
   * 不等判断有没有存过：按钮就是「现在存一次」，系统每次都会弹确认。
   * 文件名带上番号和秒数，相册里一眼能认出来。
   */
  private async saveOne(it: PickRow): Promise<void> {
    if (this.busyKey.length > 0) {
      return;
    }
    this.busyKey = this.keyOf(it);
    this.flash('正在保存…');
    try {
      const path: string = await this.downloadToLocal(it);
      const ctx = getContext(this) as common.UIAbilityContext;
      const base: string = it.number.length > 0 ? it.number : 'Amane';
      const title: string = `${base}_${clock(it.t).replace(':', '-')}`;
      const ok: boolean = await Gallery.saveImage(ctx, path, title);
      this.flash(ok ? '已保存到相册' : '已取消');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] save pick: ${e.code} ${e.message}`);
      this.flash('保存失败');
    }
    this.busyKey = '';
  }

  @Builder
  PickItemView(it: PickRow) {
    Row({ space: 10 }) {
      // 缩略图用**这一帧本身**，不是影片海报 —— 管理页要能一眼认出是哪一帧
      Stack({ alignContent: Alignment.TopStart }) {
        Image(Store.I.img(it.url))
          .width(96)
          .height(54)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .backgroundColor(Theme.CARD)
        Text(clock(it.t))
          .fontSize(8)
          .fontColor('#FFFFFF')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor('#A6000000')
          .borderRadius(3)
          .margin(3)
      }
      .width(96)
      .height(54)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(it.number.length > 0 ? it.number : '未知番号')
            .fontSize(12)
            .fontColor(Theme.TEXT)
            .maxLines(1)
          Text(it.title)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text(it.still ? '已进剧照' : '设为剧照')
            .fontSize(9)
            .fontColor(it.still ? Theme.ACCENT : Theme.TEXT_DIM)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(it.still ? Theme.ACCENT_SOFT : Theme.CARD_HI)
            .borderRadius(6)
            .onClick(() => {
              this.toggleStill(it);
            })
          if (this.busyKey === this.keyOf(it)) {
            Text('保存中…')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
          } else {
            Text('存到相册')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(6)
              .onClick(() => {
                this.saveOne(it);
              })
          }
          Text('跳转')
            .fontSize(9)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(6)
            .onClick(() => {
              this.jump(it);
            })
          Blank()
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(9)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
    .border({ width: 0.5, color: '#14FFFFFF' })
    .onClick(() => {
      this.jump(it);
    })
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
        Text('我的截帧')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('抽一张')
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(9)
          .margin({ right: 8 })
          .onClick(() => {
            this.gacha();
          })
        Text(`${this.items.length} 张`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      // 自动保存开关（默认关）：开了之后每次截帧都直接写进系统相册
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('截帧自动存到相册')
            .fontSize(13)
            .fontColor(Theme.TEXT)
          Text(this.saveLocal
            ? '每次截帧后自动发起保存，系统会弹一次「保存到相册」确认'
            : '只存在服务端，需要时再手动存到相册（默认）')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .lineHeight(14)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.saveLocal })
          .selectedColor(Theme.ACCENT)
          .onChange((v: boolean) => {
            this.saveLocal = v;
            Store.I.prefSetString('frame_save_local', v ? '1' : '0');
          })
      }
      .width('100%')
      .padding(12)
      .margin({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
      .backgroundColor(Theme.CARD)
      .borderRadius(12)

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .padding({ left: Theme.PAGE_PAD, bottom: 4 })
          .width('100%')
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 8 }) {
          Text('还没有截过帧')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('播放时点底栏的「截帧」，那一帧会进亮点，也可能进剧照')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 40, right: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (it: PickRow) => {
            ListItem() {
              this.PickItemView(it)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.DeleteButton(it)
                }
              }
            })
          }, (it: PickRow) => `pick-${it.metadata_id}-${it.ms}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  @Builder
  DeleteButton(it: PickRow) {
    Column() {
      Text('删除')
        .fontSize(12)
        .fontColor('#FFFFFF')
    }
    .width(74)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.DANGER)
    .borderRadius(12)
    .onClick(() => {
      this.askDelete(it);
    })
  }
}
