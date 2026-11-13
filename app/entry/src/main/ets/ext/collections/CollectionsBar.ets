import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../../common/Theme';
import {
  CollectionInfo, CollectionCreateResult, createCollection, fetchCollections
} from './CollectionTypes';

/**
 * 清单选择器（2.4.5.17）：收藏页与各列表页的「收藏夹」筛选共用同一个组件。
 *
 * 之前是两套：收藏页用平铺 chip（清单一多就滚不到头），列表页的 MyFilterBar 自己
 * 又拉一份 lists 且只在 aboutToAppear 拉一次 —— 新建清单后那边仍是「全部／未归类」。
 * 现在合成一个：**自己取数、每次打开面板再刷新一次**，所以任何页面新建/改名/删除后，
 * 下次点开就是最新的；胶囊上的当前清单名也不会因为「列表没刷新」而回退。
 */
@Component
export struct CollectionsBar {
  /** '' = 全部收藏；'none' = 已收藏但没归类；数字字符串 = 指定清单。 */
  @Prop current: string = '';
  /** 是否在胶囊右侧显示「管理」入口（收藏页显示，列表页筛选不显示）。 */
  @Prop showManage: boolean = true;
  onPick: (key: string) => void = (key: string) => {};

  @State lists: CollectionInfo[] = [];
  @State show: boolean = false;
  @State keyword: string = '';
  @State creating: boolean = false;
  @State name: string = '';
  @State busy: boolean = false;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      this.lists = await fetchCollections();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collections: ${e.code} ${e.message}`);
    }
  }

  private open(): void {
    this.show = true;
    // 每次打开都刷新：别的页面刚新建 / 改名 / 删掉，这里必须能看到
    this.load();
  }

  /** 当前选中的清单名；id 在列表里找不到时退回「清单」。 */
  private currentLabel(): string {
    if (this.current.length === 0) {
      return '全部';
    }
    if (this.current === 'none') {
      return '未归类';
    }
    for (let i = 0; i < this.lists.length; i++) {
      if (`${this.lists[i].id}` === this.current) {
        return this.lists[i].name;
      }
    }
    return '清单';
  }

  private filtered(): CollectionInfo[] {
    const kw: string = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return this.lists;
    }
    const out: CollectionInfo[] = [];
    for (let i = 0; i < this.lists.length; i++) {
      if (this.lists[i].name.toLowerCase().indexOf(kw) >= 0) {
        out.push(this.lists[i]);
      }
    }
    return out;
  }

  private async createList(): Promise<void> {
    const v: string = this.name.trim();
    if (v.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const r: CollectionCreateResult = await createCollection(v);
      this.name = '';
      this.creating = false;
      this.note = '';
      await this.load();
      if (r.id > 0) {
        this.onPick(`${r.id}`);
        this.show = false;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] collection create: ${e.code} ${e.message}`);
      this.note = e.code === 409 ? '已经有同名清单了' : '新建失败，请重试';
    }
    this.busy = false;
  }

  @Builder
  Option(key: string, text: string, count: number) {
    Row({ space: 8 }) {
      Text(text)
        .fontSize(14)
        .fontColor(this.current === key ? '#FFFFFF' : Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (count >= 0) {
        Text(`${count}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      if (this.current === key) {
        Text('✓')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.current === key ? Theme.ACCENT_SOFT : Color.Transparent)
    .borderRadius(10)
    .onClick(() => {
      this.onPick(key);
      this.show = false;
    })
  }

  @Builder
  Picker() {
    Column({ space: 10 }) {
      Row() {
        Text('选择清单')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text('完成')
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
          .onClick(() => {
            this.show = false;
          })
      }
      .width('100%')

      TextInput({ text: this.keyword, placeholder: '搜索清单名' })
        .height(38)
        .fontSize(12)
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
        .onChange((v: string) => {
          this.keyword = v;
        })

      Scroll() {
        Column({ space: 2 }) {
          this.Option('', '全部', -1)
          this.Option('none', '未归类', -1)
          ForEach(this.filtered(), (c: CollectionInfo) => {
            this.Option(`${c.id}`, c.name, c.n)
          }, (c: CollectionInfo) => `cp-${c.id}`)
          if (this.filtered().length === 0 && this.keyword.length > 0) {
            Text('没有匹配的清单')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .padding({ top: 16 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      if (this.creating) {
        Row({ space: 8 }) {
          TextInput({ text: this.name, placeholder: '新清单名' })
            .layoutWeight(1)
            .height(38)
            .fontSize(12)
            .backgroundColor(Theme.CARD)
            .onChange((v: string) => {
              this.name = v;
            })
          Text(this.busy ? '…' : '创建')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(9)
            .onClick(() => {
              this.createList();
            })
        }
        .width('100%')
      }

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(10)
          .fontColor(Theme.DANGER)
          .width('100%')
      }

      Row({ space: 10 }) {
        Text('＋ 新建清单')
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(10)
          .onClick(() => {
            this.creating = !this.creating;
          })
        Blank()
        Text('管理清单 ›')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .padding({ top: 7, bottom: 7 })
          .onClick(() => {
            this.show = false;
            router.pushUrl({ url: 'pages/CollectionsPage' });
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 6, bottom: 18 })
  }

  build() {
    Row({ space: 10 }) {
      // 左：清单选择器（唯一主入口）。做成一颗胶囊，前缀「清单」提示这是筛选，
      // 名字 + 箭头合在同一颗里，避免原来是「三段字 + 两个紧贴的小块」粘成一坨。
      Row({ space: 7 }) {
        Text('清单')
          .fontSize(10)
          .fontColor(this.current.length > 0 ? '#E8FFFFFF' : Theme.TEXT_FAINT)
        Text(this.currentLabel())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.current.length > 0 ? Theme.ON_ACCENT : Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 150 })
        Text('▾')
          .fontSize(9)
          .fontColor(this.current.length > 0 ? '#CCFFFFFF' : Theme.TEXT_FAINT)
      }
      .padding({ left: 14, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.current.length > 0 ? Theme.ACCENT : Theme.CARD)
      .borderRadius(18)
      .onClick(() => {
        this.open();
      })

      Blank()

      if (this.showManage) {
        // 右：管理是「另一个动作」，做成独立的圆形图标按钮 —— 与左侧胶囊拉开距离，
        // 不再像一条被切开的按钮。
        Column() {
          Text('⚙')
            .fontSize(15)
            .fontColor(Theme.TEXT_DIM)
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(Theme.CARD)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          router.pushUrl({ url: 'pages/CollectionsPage' });
        })
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4, bottom: 10 })
    .bindSheet($$this.show, this.Picker(), {
      height: 520,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG_RAISED
    })
  }
}
