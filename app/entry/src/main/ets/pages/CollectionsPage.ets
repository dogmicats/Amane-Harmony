import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import {
  CollectionInfo, CollectionCreateResult, createCollection, deleteCollection,
  fetchCollections, renameCollection
} from '../ext/collections/CollectionTypes';

/**
 * 清单管理（2.4.5.15）：新建 / 改名 / 删除我的收藏清单。
 *
 * 收藏页的选择器只负责「选」，管理动作集中在这里，避免在胶囊里塞一堆图标。
 * 数据就是 `GET /api/user/collections`（含每个清单的片数），改名走 PUT、
 * 删除走 DELETE（只删清单与归类关系，影片本身的收藏状态不变）。
 */
@Entry
@Component
struct CollectionsPage {
  @State lists: CollectionInfo[] = [];
  @State loading: boolean = true;
  @State note: string = '';
  /** 正在改名的清单 id；0 = 没有。 */
  @State editingId: number = 0;
  @State editName: string = '';
  /** 已按过一次「删除」、等待确认的清单 id。 */
  @State confirmId: number = 0;
  @State creating: boolean = false;
  @State newName: string = '';
  @State busy: boolean = false;

  onPageShow(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.lists.length === 0;
    try {
      this.lists = await fetchCollections();
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collections: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端未启用清单功能' : '读取失败，请检查连接';
    }
    this.loading = false;
  }

  private openCollection(c: CollectionInfo): void {
    const params: Record<string, Object> = {
      'libraryId': 0,
      'collectionId': c.id,
      'title': c.name.length > 0 ? c.name : '清单'
    };
    router.pushUrl({ url: 'pages/LibraryPage', params: params });
  }

  private async create(): Promise<void> {
    const v: string = this.newName.trim();
    if (v.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const r: CollectionCreateResult = await createCollection(v);
      this.newName = '';
      this.creating = false;
      this.note = r.id > 0 ? '已新建' : '';
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      this.note = e.code === 409 ? '已经有同名清单了' : '新建失败，请重试';
    }
    this.busy = false;
  }

  private async saveName(id: number): Promise<void> {
    const v: string = this.editName.trim();
    if (v.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      await renameCollection(id, v);
      this.editingId = 0;
      this.note = '';
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      this.note = e.code === 409 ? '已经有同名清单了' : '改名失败，请重试';
    }
    this.busy = false;
  }

  private async remove(id: number): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await deleteCollection(id);
      this.confirmId = 0;
      this.note = '已删除清单';
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collection delete: ${e.code} ${e.message}`);
      this.note = '删除失败，请重试';
    }
    this.busy = false;
  }

  @Builder
  RowItem(c: CollectionInfo) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        if (this.editingId === c.id) {
          TextInput({ text: this.editName })
            .layoutWeight(1)
            .height(36)
            .fontSize(13)
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(8)
            .onChange((v: string) => {
              this.editName = v;
            })
          Text('保存')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(8)
            .onClick(() => {
              this.saveName(c.id);
            })
          Text('取消')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.editingId = 0;
            })
        } else {
          Column({ space: 3 }) {
            Text(c.name.length > 0 ? c.name : '未命名')
              .fontSize(14)
              .fontColor(Theme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(`${c.n} 部`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // 点名字进这个清单的影片墙（2.5.5.25）
          .onClick(() => {
            this.openCollection(c);
          })

          Text('›')
            .fontSize(18)
            .fontColor(Theme.TEXT_FAINT)
            .width(18)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.openCollection(c);
            })

          Text('改名')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.confirmId = 0;
              this.editingId = c.id;
              this.editName = c.name;
            })
          Text(this.confirmId === c.id ? '确认删除' : '删除')
            .fontSize(12)
            .fontColor(this.confirmId === c.id ? '#FFFFFF' : Theme.DANGER)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.confirmId === c.id ? Theme.DANGER : Color.Transparent)
            .borderRadius(8)
            .onClick(() => {
              if (this.confirmId === c.id) {
                this.remove(c.id);
              } else {
                this.confirmId = c.id;
                this.editingId = 0;
              }
            })
        }
      }
      .width('100%')

      if (this.confirmId === c.id) {
        Text('只删除清单本身和归类关系，影片不会被取消收藏。')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
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
        Text('我的清单')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text('＋ 新建')
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(10)
          .onClick(() => {
            this.creating = !this.creating;
          })
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })

      if (this.creating) {
        Row({ space: 8 }) {
          TextInput({ text: this.newName, placeholder: '新清单名' })
            .layoutWeight(1)
            .height(38)
            .fontSize(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(10)
            .onChange((v: string) => {
              this.newName = v;
            })
          Text(this.busy ? '…' : '创建')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.create();
            })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
      }

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.lists.length === 0) {
        Column({ space: 10 }) {
          Text('☰')
            .fontSize(30)
            .fontColor(Theme.TEXT_FAINT)
          Text('还没有清单')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('新建一个清单，把收藏的影片按自己的方式归类。')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 1 }) {
            ForEach(this.lists, (c: CollectionInfo) => {
              this.RowItem(c)
            }, (c: CollectionInfo) => `col-${c.id}`)
          }
          .width('100%')
          .backgroundColor(Theme.CARD)
          .borderRadius(14)
          .clip(true)
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
