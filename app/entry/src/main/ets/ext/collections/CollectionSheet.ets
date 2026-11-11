import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../../common/Theme';
import {
  CollectionInfo, fetchCollections, fetchItemCollections, createCollection,
  CollectionCreateResult, setItemCollections, ensureFavorite, removeFavorite
} from './CollectionTypes';

/**
 * 详情页「收藏到清单」底部面板。由父页面条件渲染（if (showCollections)），
 * 所以每次打开都是新实例，aboutToAppear 里拉一次清单与该片归属即可。
 *
 * 交互取舍：点「收藏」不再是静默的一键切换，而是打开这个面板 —— 用户要能
 * 在这一个地方同时完成「收藏 / 取消收藏」与「归到哪些清单」，不必再找第二个入口。
 * 清单可以多择；一个都不选就是「只收藏，不归类」。
 */
@Component
export struct CollectionSheet {
  @Prop metaId: number = 0;
  @Prop favorite: boolean = false;
  onClose: () => void = () => {};
  onChanged: (fav: boolean, ids: number[]) => void = (fav: boolean, ids: number[]) => {};

  @State lists: CollectionInfo[] = [];
  @State picked: number[] = [];
  @State newName: string = '';
  @State creating: boolean = false;
  @State busy: boolean = false;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      this.lists = await fetchCollections();
      this.picked = await fetchItemCollections(this.metaId);
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collections: ${e.code} ${e.message}`);
      this.note = '清单读取失败';
    }
  }

  private isPicked(id: number): boolean {
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === id) {
        return true;
      }
    }
    return false;
  }

  /** ArkUI 数组按引用监听，改元素不刷新，必须整体换新数组。 */
  private toggle(id: number): void {
    const next: number[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === id) {
        hit = true;
      } else {
        next.push(this.picked[i]);
      }
    }
    if (!hit) {
      next.push(id);
    }
    this.picked = next;
  }

  private async createList(): Promise<void> {
    const name: string = this.newName.trim();
    if (name.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const r: CollectionCreateResult = await createCollection(name);
      this.lists = await fetchCollections();
      if (r.id > 0 && !this.isPicked(r.id)) {
        this.picked = this.picked.concat([r.id]);
      }
      this.newName = '';
      this.creating = false;
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collection create: ${e.code} ${e.message}`);
      this.note = '新建失败（可能重名）';
    }
    this.busy = false;
  }

  private async apply(): Promise<void> {
    if (this.busy || this.metaId <= 0) {
      return;
    }
    this.busy = true;
    try {
      // 顺序不能反：先确保 favorites 有这一条，再写清单关联
      await ensureFavorite(this.metaId);
      await setItemCollections(this.metaId, this.picked);
      this.onChanged(true, this.picked);
      this.onClose();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collection apply: ${e.code} ${e.message}`);
      this.note = '保存失败';
    }
    this.busy = false;
  }

  private async unfav(): Promise<void> {
    if (this.busy || this.metaId <= 0) {
      return;
    }
    this.busy = true;
    try {
      await removeFavorite(this.metaId);
      this.picked = [];
      this.onChanged(false, []);
      this.onClose();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collection unfav: ${e.code} ${e.message}`);
      this.note = '取消失败';
    }
    this.busy = false;
  }

  build() {
    Column() {
      Column({ space: 10 }) {
        Row() {
          Column({ space: 2 }) {
            Text('收藏到清单')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
            Text('可多选，也可以只收藏不归类')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        if (this.lists.length === 0) {
          Text('还没有清单，点下面「+ 新建清单」建一个')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .padding({ top: 12, bottom: 12 })
        } else {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.lists, (c: CollectionInfo) => {
                Row({ space: 8 }) {
                  Text(this.isPicked(c.id) ? '☑' : '☐')
                    .fontSize(16)
                    .fontColor(this.isPicked(c.id) ? Theme.ACCENT : Theme.TEXT_FAINT)
                  Text(c.name)
                    .fontSize(13)
                    .fontColor(Theme.TEXT)
                    .layoutWeight(1)
                  Text(`${c.n} 部`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .width('100%')
                .padding({ left: 10, right: 10, top: 9, bottom: 9 })
                .backgroundColor(this.isPicked(c.id) ? Theme.ACCENT_SOFT : Theme.CARD)
                .borderRadius(10)
                .onClick(() => {
                  this.toggle(c.id);
                })
              }, (c: CollectionInfo) => `cl-${c.id}`)
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 250 })
          .width('100%')
        }

        if (this.creating) {
          Row({ space: 8 }) {
            TextInput({ placeholder: '清单名（最多 24 字）' })
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .backgroundColor(Theme.CARD)
              .onChange((v: string) => {
                this.newName = v;
              })
            Text(this.busy ? '…' : '建')
              .fontSize(13)
              .fontColor(Theme.ACCENT)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(8)
              .onClick(() => {
                this.createList();
              })
          }
          .width('100%')
        } else {
          Text('+ 新建清单')
            .fontSize(12)
            .fontColor(Theme.ACCENT)
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.creating = true;
            })
        }

        if (this.note.length > 0) {
          Text(this.note)
            .fontSize(11)
            .fontColor(Theme.DANGER)
        }

        Row({ space: 10 }) {
          if (this.favorite) {
            Text('取消收藏')
              .fontSize(12)
              .fontColor(Theme.DANGER)
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .backgroundColor(Theme.CARD)
              .borderRadius(10)
              .onClick(() => {
                this.unfav();
              })
          }
          Blank()
          Text(this.busy ? '保存中…' : '完成')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 22, right: 22, top: 10, bottom: 10 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.apply();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 26 })
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius({ topLeft: 18, topRight: 18 })
      .onClick(() => {
        // 吞掉点击，避免穿透到遮罩把面板关掉
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#99000000')
    .onClick(() => {
      this.onClose();
    })
  }
}
