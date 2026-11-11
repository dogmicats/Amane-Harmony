import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet, httpPut } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams } from '../common/Types';

/** 我写过的一条评价（GET /api/user/mycomments，片名与海报由服务端补齐）。 */
interface MyComment {
  id: number;
  metadata_id: number;
  body: string;
  created_at: string;
  updated_at: string;
  number: string;
  title: string;
  poster: string;
}

interface MyCommentList {
  items: MyComment[];
}

/**
 * 我的评价（「我的」→ 我的评价）。
 *
 * 详情页里写的评价散在各部片子下面，这里给一个总览，并且**就地能改能删**：
 *   * 右侧「改 / 删」按钮
 *   * 左滑也能删（和观看记录、入库管理同一套手势）
 *   * 点正文区域进那部片的详情页
 */
@Entry
@Component
struct MyCommentsPage {
  @State items: MyComment[] = [];
  @State loading: boolean = true;
  /** 正在改的那条（0 = 弹层关闭）。 */
  @State editingId: number = 0;
  @State draft: string = '';
  @State saving: boolean = false;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/mycomments?limit=200`,
        Store.I.token);
      const data = JSON.parse(text) as MyCommentList;
      this.items = data.items === undefined || data.items === null ? [] : data.items;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] mycomments: ${e.code} ${e.message}`);
    }
    this.loading = false;
  }

  private open(item: MyComment): void {
    const params: DetailParams = { id: item.metadata_id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private preview(body: string): string {
    const s: string = body.replace(/\s+/g, ' ').trim();
    return s.length > 90 ? `${s.substring(0, 90)}…` : s;
  }

  private flash(msg: string): void {
    this.note = msg;
    setTimeout(() => {
      this.note = '';
    }, 1800);
  }

  private async save(): Promise<void> {
    const text: string = this.draft.trim();
    if (text.length === 0) {
      this.flash('评价不能为空');
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      // 改评价要带影片 id（同一个 id 在不同片下才唯一），先从列表里找回来
      let mid: number = 0;
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].id === this.editingId) {
          mid = this.items[i].metadata_id;
        }
      }
      if (mid <= 0) {
        this.flash('这条评价不见了');
        this.saving = false;
        return;
      }
      await httpPut(
        `${Store.I.user}/api/user/item/${mid}/comment/${this.editingId}`,
        Store.I.token, JSON.stringify({ body: text }));
      this.flash('已保存');
      this.editingId = 0;
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] edit comment: ${e.code} ${e.message}`);
      this.flash('保存失败');
    }
    this.saving = false;
  }

  private askDelete(item: MyComment): void {
    AlertDialog.show({
      title: '删除这条评价？',
      message: '删了就找不回来了（只删你写的这条，影片本身不受影响）。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.DANGER,
        action: () => {
          this.remove(item);
        }
      }
    });
  }

  private async remove(item: MyComment): Promise<void> {
    try {
      await httpDelete(
        `${Store.I.user}/api/user/item/${item.metadata_id}/comment/${item.id}`, Store.I.token);
      const next: MyComment[] = [];
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].id !== item.id) {
          next.push(this.items[i]);
        }
      }
      this.items = next;
      this.flash('已删除');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] del comment: ${e.code} ${e.message}`);
      this.flash('删除失败');
    }
  }

  @Builder
  EditSheet() {
    Column() {
      Column({ space: 10 }) {
        Text('改这条评价')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        TextArea({ text: this.draft, placeholder: '改一改…' })
          .height(150)
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .backgroundColor(Theme.CARD)
          .borderRadius(10)
          .onChange((v: string) => {
            this.draft = v;
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.editingId = 0;
            })
          Text(this.saving ? '保存中…' : '保存')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.save();
            })
        }
        .width('100%')
      }
      .width('88%')
      .padding(18)
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
    .onClick(() => {
      this.editingId = 0;
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
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
          Text('我的评价')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Blank()
          Text(this.note.length > 0 ? this.note : `${this.items.length} 条`)
            .fontSize(11)
            .fontColor(this.note.length > 0 ? Theme.TEXT_DIM : Theme.TEXT_FAINT)
        }
        .width('100%')
        .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.ACCENT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column({ space: 8 }) {
            Text('还没写过评价')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text('在影片详情页点「写评价」，写过的都会出现在这里')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.items, (c: MyComment) => {
              ListItem() {
                Row({ space: 10 }) {
                  Image(Store.I.img(c.poster))
                    .width(52)
                    .height(72)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(Theme.CARD)
                    .borderRadius(8)
                    .alt($r('app.media.placeholder'))

                  Column({ space: 4 }) {
                    Text(c.number.length > 0 ? c.number : c.title)
                      .fontSize(12)
                      .fontColor(Theme.ACCENT)
                    Text(this.preview(c.body))
                      .fontSize(12)
                      .fontColor(Theme.TEXT_DIM)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Row({ space: 6 }) {
                      Text(c.created_at.length >= 10 ? c.created_at.substring(0, 10) : c.created_at)
                        .fontSize(9)
                        .fontColor(Theme.TEXT_FAINT)
                      Blank()
                      Text('改')
                        .fontSize(10)
                        .fontColor(Theme.ACCENT)
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .backgroundColor(Theme.CARD_HI)
                        .borderRadius(7)
                        .onClick(() => {
                          this.editingId = c.id;
                          this.draft = c.body;
                        })
                      Text('删')
                        .fontSize(10)
                        .fontColor(Theme.DANGER)
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .backgroundColor(Theme.CARD_HI)
                        .borderRadius(7)
                        .onClick(() => {
                          this.askDelete(c);
                        })
                    }
                    .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding(10)
                .backgroundColor(Theme.CARD)
                .borderRadius(11)
                .border({ width: 1, color: Theme.ACCENT_SOFT })
                .onClick(() => {
                  this.open(c);
                })
              }
              // 左滑删除：和观看记录、入库管理一致
              .swipeAction({
                end: {
                  builder: () => {
                    Text('删除')
                      .fontSize(13)
                      .fontColor('#FFFFFF')
                      .width(68)
                      .height('100%')
                      .textAlign(TextAlign.Center)
                      .backgroundColor(Theme.DANGER)
                      .borderRadius(11)
                      .onClick(() => {
                        this.askDelete(c);
                      })
                  }
                }
              })
            }, (c: MyComment) => `mc-${c.id}`)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')

      if (this.editingId > 0) {
        this.EditSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
