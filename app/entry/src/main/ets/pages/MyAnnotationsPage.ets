import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams } from '../common/Types';
import { clock } from '../common/Util';

/**
 * 我的弹幕（R23 汇总页，两级）。
 *
 * 一级按**影片**分组：左边海报，右边一行影片（番号 + 弹幕数 + 前几条缩略）。
 * 点影片进二级：上面钉住影片信息，下面列这部片的所有弹幕，点一条跳到那个时间点。
 * 二级里支持左滑删除单条。
 *
 * 之所以不一条弹幕一行：几百条平铺根本找不到片，「我要看某部片的弹幕」
 * 才是真实需求（2026-11-11 用户要求）。
 */
interface AnnoRow {
  id: number;
  metadata_id: number;
  /** 这条弹幕属于哪个文件（版本/集）。同一部片的第 1 集和第 2 集不能串。 */
  file_key: string;
  file_name: string;
  t_ms: number;
  body: string;
  created_at: string;
  number: string;
  title: string;
  poster: string;
}

/** 二级里再按文件分组：一部片有多个版本时，弹幕要分开看。 */
interface AnnoFileGroup {
  file_key: string;
  file_name: string;
  items: AnnoRow[];
}

interface AnnoGroup {
  metadata_id: number;
  number: string;
  title: string;
  poster: string;
  items: AnnoRow[];
}

function str(v: string | null | undefined): string {
  return typeof v === 'string' ? v : '';
}

function num(v: number | null | undefined): number {
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function safeRows(raw: AnnoRow[] | null | undefined): AnnoRow[] {
  const out: AnnoRow[] = [];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const it = raw[i];
    if (it === undefined || it === null) {
      continue;
    }
    out.push({
      id: Math.trunc(num(it.id)),
      metadata_id: Math.trunc(num(it.metadata_id)),
      file_key: str(it.file_key),
      file_name: str(it.file_name),
      t_ms: Math.trunc(num(it.t_ms)),
      body: str(it.body),
      created_at: str(it.created_at),
      number: str(it.number),
      title: str(it.title),
      poster: str(it.poster)
    });
  }
  return out;
}

@Entry
@Component
struct MyAnnotationsPage {
  @State items: AnnoRow[] = [];
  @State groups: AnnoGroup[] = [];
  @State loading: boolean = true;
  @State note: string = '';
  /** 0 = 影片列表；>0 = 该影片的弹幕详情。 */
  @State detailMid: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/annotations?limit=300`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.items = safeRows(obj.items as AnnoRow[]);
      this.regroup();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] my annotations: ${e.code} ${e.message}`);
      this.note = '读取失败';
    }
    this.loading = false;
  }

  /** 按影片分组，保持服务端「新的在前」的顺序。 */
  private regroup(): void {
    const out: AnnoGroup[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: AnnoRow = this.items[i];
      let at: number = -1;
      for (let k = 0; k < out.length; k++) {
        if (out[k].metadata_id === it.metadata_id) {
          at = k;
          break;
        }
      }
      if (at < 0) {
        out.push({
          metadata_id: it.metadata_id,
          number: it.number,
          title: it.title,
          poster: it.poster,
          items: [it]
        });
      } else {
        out[at].items.push(it);
      }
    }
    this.groups = out;
  }

  private detailGroup(): AnnoGroup | undefined {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].metadata_id === this.detailMid) {
        return this.groups[i];
      }
    }
    return undefined;
  }

  /** 二级里按文件（版本/集）再分一层：弹幕跟着文件走，不能混着列。 */
  private detailFiles(): AnnoFileGroup[] {
    const g: AnnoGroup | undefined = this.detailGroup();
    const out: AnnoFileGroup[] = [];
    if (g === undefined) {
      return out;
    }
    for (let i = 0; i < g.items.length; i++) {
      const it: AnnoRow = g.items[i];
      let at: number = -1;
      for (let k = 0; k < out.length; k++) {
        if (out[k].file_key === it.file_key) {
          at = k;
          break;
        }
      }
      if (at < 0) {
        out.push({ file_key: it.file_key, file_name: it.file_name, items: [it] });
      } else {
        out[at].items.push(it);
      }
    }
    return out;
  }

  private fileCountOf(g: AnnoGroup): number {
    const keys: string[] = [];
    for (let i = 0; i < g.items.length; i++) {
      if (keys.indexOf(g.items[i].file_key) < 0) {
        keys.push(g.items[i].file_key);
      }
    }
    return keys.length;
  }

  private flash(t: string): void {
    this.note = t;
    setTimeout(() => {
      if (this.note === t) {
        this.note = '';
      }
    }, 1600);
  }

  private jump(mid: number, t: number, number: string, title: string,
    fileKey: string = '', fileName: string = ''): void {
    // 进详情页直接开播：切回竖屏时下面还有完整详情（第 8 条）
    const p: DetailParams = {
      id: mid,
      autoplay: true,
      position: t,
      fileKey: fileKey,
      fileName: fileName
    };
    router.pushUrl({ url: 'pages/DetailPage', params: p }).catch((err: BusinessError) => {
      console.error(`[amane] jump anno: ${err.code} ${err.message}`);
    });
  }

  private askDelete(row: AnnoRow): void {
    AlertDialog.show({
      title: '删掉这条弹幕？',
      message: '只删这一条，影片和进度不受影响。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.DANGER,
        action: () => {
          this.remove(row);
        }
      }
    });
  }

  private async remove(row: AnnoRow): Promise<void> {
    try {
      await httpDelete(
        `${Store.I.user}/api/user/annotations/${row.metadata_id}/${row.id}`, Store.I.token);
      this.items = this.items.filter((x: AnnoRow) => x.id !== row.id);
      this.regroup();
      this.flash('已删除');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] del anno: ${e.code} ${e.message}`);
      this.flash('删除失败');
    }
  }

  // ---- 一级：影片列表 ------------------------------------------------ //

  @Builder
  FilmItemView(g: AnnoGroup) {
    Row({ space: 10 }) {
      Image(Store.I.img(g.poster))
        .width(52)
        .height(72)
        .objectFit(ImageFit.Cover)
        .borderRadius(7)
        .backgroundColor(Theme.CARD)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(g.number.length > 0 ? g.number : g.title)
            .fontSize(13)
            .fontColor(Theme.TEXT)
            .maxLines(1)
            .layoutWeight(1)
          Text(this.fileCountOf(g) > 1 ? `${g.items.length} 条 · ${this.fileCountOf(g)} 个版本`
            : `${g.items.length} 条`)
            .fontSize(9)
            .fontColor(Theme.ACCENT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(5)
        }
        .width('100%')

        // 右边细分成一行一条弹幕缩略（最多 3 条，多了进二级看）
        ForEach(g.items.slice(0, 3), (a: AnnoRow) => {
          Row({ space: 6 }) {
            Text(clock(a.t_ms / 1000.0))
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width(40)
            Text(a.body)
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
        }, (a: AnnoRow) => `gp-${a.id}`)

        if (g.items.length > 3) {
          Text(`还有 ${g.items.length - 3} 条 ›`)
            .fontSize(9)
            .fontColor(Theme.ACCENT)
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
    .border({ width: 0.5, color: '#14FFFFFF' })
    .onClick(() => {
      this.detailMid = g.metadata_id;
    })
  }

  // ---- 二级：某部片的全部弹幕 ---------------------------------------- //

  @Builder
  DetailView() {
    Column() {
      // 置顶影片信息，始终钉在上方
      Row({ space: 10 }) {
        Image(Store.I.img(this.detailGroup() === undefined ? '' : this.detailGroup()!.poster))
          .width(44)
          .height(60)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .backgroundColor(Theme.CARD)
        Column({ space: 3 }) {
          Text(this.detailGroup() === undefined || this.detailGroup()!.number.length === 0
            ? '未知番号' : this.detailGroup()!.number)
            .fontSize(13)
            .fontColor(Theme.TEXT)
            .maxLines(1)
          Text(this.detailGroup() === undefined ? '' : this.detailGroup()!.title)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.detailGroup() === undefined ? 0 : this.detailGroup()!.items.length} 条弹幕`)
            .fontSize(9)
            .fontColor(Theme.ACCENT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('从头播')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(10)
          .onClick(() => {
            const g: AnnoGroup | undefined = this.detailGroup();
            if (g !== undefined) {
              const first: AnnoRow | undefined = g.items.length > 0 ? g.items[0] : undefined;
              this.jump(g.metadata_id, 0, g.number, g.title,
                first === undefined ? '' : first.file_key,
                first === undefined ? '' : first.file_name);
            }
          })
      }
      .width('100%')
      .padding(10)
      .backgroundColor(Theme.CARD)
      .borderRadius(12)

      List({ space: 8 }) {
        ForEach(this.detailFiles(), (fg: AnnoFileGroup) => {
          // 文件（版本/集）小标题：换集就换一组，绝不把两集的弹幕混在一起
          ListItem() {
            Row({ space: 6 }) {
              Text(fg.file_name.length > 0 ? fg.file_name
                : (fg.file_key.length > 0 ? fg.file_key : '默认版本'))
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(`${fg.items.length} 条`)
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 8, bottom: 2 })
          }

          ForEach(fg.items, (a: AnnoRow) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(clock(a.t_ms / 1000.0))
                  .fontSize(10)
                  .fontColor(Theme.ACCENT)
                  .width(46)
                Text(a.body)
                  .fontSize(12)
                  .fontColor(Theme.TEXT_DIM)
                  .layoutWeight(1)
                  .maxLines(3)
                Text('›')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.CARD)
              .borderRadius(10)
              .onClick(() => {
                this.jump(a.metadata_id, a.t_ms / 1000.0, a.number, a.title,
                  a.file_key, a.file_name);
              })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.DeleteButton(a)
                }
              }
            })
          }, (a: AnnoRow) => `da-${a.id}`)
        }, (fg: AnnoFileGroup) => `df-${fg.file_key}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .margin({ top: 8 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
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
            if (this.detailMid > 0) {
              this.detailMid = 0;
            } else {
              router.back();
            }
          })
        Text(this.detailMid > 0 ? '影片弹幕' : '我的弹幕')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.detailMid > 0
          ? `${this.detailGroup() === undefined ? 0 : this.detailGroup()!.items.length} 条`
          : `${this.groups.length} 部`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

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
      } else if (this.groups.length === 0) {
        Column({ space: 8 }) {
          Text('还没有弹幕')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('播放时点底栏的「弹幕」，发一句，下次播到那里会自己飘出来')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 40, right: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.detailMid > 0) {
        this.DetailView()
      } else {
        List({ space: 10 }) {
          ForEach(this.groups, (g: AnnoGroup) => {
            ListItem() {
              this.FilmItemView(g)
            }
          }, (g: AnnoGroup) => `g-${g.metadata_id}`)
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
  DeleteButton(item: AnnoRow) {
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
      this.askDelete(item);
    })
  }
}
