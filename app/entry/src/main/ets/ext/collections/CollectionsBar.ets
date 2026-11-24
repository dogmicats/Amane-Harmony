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
  /**
   * 形态（2026-11-16）：
   *   `pill`  —— 老样子：一颗「清单 全部 ▾」胶囊（列表页的筛选条用，横向空间紧）；
   *   `strip` —— 收藏页专用：**整条玻璃**，里面平铺「全部 / 未归类 / 各清单」，
   *              和页顶「影片-…-系列」那条同一个材质与圆角，紧贴它下面，
   *              读起来像「影片」这一项长出来的子菜单。
   */
  @Prop variant: string = 'pill';
  /**
   * 多选（2026-11-16 用户要求）：清单可以同时选好几个，筛「同时出现在这些清单里」的内容。
   * 只在 `strip` 形态生效（pill 是列表页的快速单选，不改）。
   */
  @Prop multi: boolean = false;
  /** 多选时选中的清单 key 列表（'' 不在里面 = 全部）。 */
  @Prop currents: string[] = [];
  /** 多选结果回调（按选择顺序给）。 */
  onPickMulti: (keys: string[]) => void = (keys: string[]) => {};
  onPick: (key: string) => void = (key: string) => {};

  @State lists: CollectionInfo[] = [];
  @State show: boolean = false;
  @State keyword: string = '';
  @State creating: boolean = false;
  @State name: string = '';
  @State busy: boolean = false;
  @State note: string = '';
  /** 面板里的临时勾选（点「确定」才生效 —— 用户要"确认之前已选的要留着"）。 */
  @State draft: string[] = [];

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
    // 面板用「临时勾选」，确认才生效：搜索时已选的那些不会因为不在结果里而丢失
    this.draft = this.multi ? this.currents.slice() : [];
    // 每次打开都刷新：别的页面刚新建 / 改名 / 删掉，这里必须能看到
    this.load();
  }

  private inDraft(key: string): boolean {
    return this.draft.indexOf(key) >= 0;
  }

  private toggleDraft(key: string): void {
    // 「未归类」在服务端是独立语义（已收藏但没归进任何清单），不能和具体清单取交集 ——
    // 选它就单独生效，选具体清单则把「未归类」摘掉。
    if (key === 'none') {
      this.draft = this.inDraft('none') ? [] : ['none'];
      return;
    }
    const next: string[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.draft.length; i++) {
      const k: string = this.draft[i];
      if (k === key) {
        hit = true;
      } else if (k !== 'none') {
        next.push(k);
      }
    }
    if (!hit) {
      next.push(key);
    }
    this.draft = next;
  }

  /** 已勾选的清单名（置顶区用；按 draft 顺序）。 */
  private draftLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.draft.length; i++) {
      out.push(this.labelOf(this.draft[i]));
    }
    return out;
  }

  private labelOf(key: string): string {
    if (key === 'none') {
      return '未归类';
    }
    for (let i = 0; i < this.lists.length; i++) {
      if (`${this.lists[i].id}` === key) {
        return this.lists[i].name;
      }
    }
    return '清单';
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
        .fontColor((this.multi ? this.inDraft(key) : this.current === key) ? '#FFFFFF' : Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (count >= 0) {
        Text(`${count}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      if (this.multi ? this.inDraft(key) : this.current === key) {
        Text('✓')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: 12, right: 12 })
    .backgroundColor((this.multi ? this.inDraft(key) : this.current === key)
      ? Theme.ACCENT_SOFT : Color.Transparent)
    .borderRadius(10)
    .onClick(() => {
      if (this.multi) {
        // 多选：只改临时勾选，**不关面板、不立即生效** —— 确认前已选的不会被搜索顶掉
        if (key.length === 0) {
          this.draft = [];
          return;
        }
        this.toggleDraft(key);
      } else {
        this.onPick(key);
        this.show = false;
      }
    })
  }

  @Builder
  Picker() {
    Column({ space: 10 }) {
      Row() {
        Text(this.multi ? '选择清单（可多选）' : '选择清单')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.multi ? '确定' : '完成')
          .fontSize(13)
          .fontWeight(this.multi ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.multi ? Theme.ACCENT : Theme.TEXT_DIM)
          .onClick(() => {
            if (this.multi) {
              this.onPickMulti(this.draft.slice());
            }
            this.show = false;
          })
      }
      .width('100%')

      // 已选置顶（2026-11-16 用户要求）：**固定在这一行，不参与下面的搜索结果** ——
      // 搜别的关键词时，已经勾上的清单仍然看得见、点一下就能取消。
      if (this.multi) {
        Row({ space: 6 }) {
          Text(`已选 ${this.draft.length}`)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.draft, (k: string) => {
                Text(`${this.labelOf(k)} ✕`)
                  .fontSize(11)
                  .fontColor(Theme.ON_ACCENT)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(12)
                  .maxLines(1)
                  .onClick(() => {
                    this.toggleDraft(k);
                  })
              }, (k: string) => `draft-${k}`)
            }
            .padding({ right: 4 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .align(Alignment.Start)
        }
        .width('100%')
        .height(28)
      }

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
            .fontColor(Theme.ON_ACCENT)
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

  /**
   * 胶囊上显示的文字：只列**已选**的清单。
   * 一个没选 = 「全部」；多个 = 「A、B、C」。
   *
   * 超出的部分不再靠「等」拼进文字里（名字本身太长时，`等` 会被省略号一起吞掉，
   * 2026-11-16 用户实际看到的就是这个）。这里只给出**能完整放下的那几个名字**，
   * 「等」由调用处作为独立 Text 渲染 —— 只要 `overflowed()` 为真，它一定在。
   */
  private selectionLabel(): string {
    if (this.currents.length === 0) {
      return '全部';
    }
    const parts: string[] = this.fittedNames();
    return parts.join('、');
  }

  /** 能完整放进胶囊的清单名（按选择顺序，最多约 11 个字，且至少留一个给「等」）。 */
  private fittedNames(): string[] {
    const MAX_CHARS: number = 10;
    const parts: string[] = [];
    let used: number = 0;
    for (let i = 0; i < this.currents.length; i++) {
      const name: string = this.labelOf(this.currents[i]);
      if (parts.length > 0 && used + name.length + 1 > MAX_CHARS) {
        break;
      }
      // 单个名字就超长（用户说的"有的标签本身就太长"）：截断它自己，别让整条变成省略号
      if (parts.length === 0 && name.length > MAX_CHARS) {
        parts.push(`${name.substring(0, MAX_CHARS)}…`);
        used = MAX_CHARS;
        break;
      }
      parts.push(name);
      used += name.length + 1;
    }
    return parts;
  }

  /** 有没有没显示出来的清单（决定「等」出现与否，以及文字区留多宽）。 */
  private overflowed(): boolean {
    if (this.currents.length === 0) {
      return false;
    }
    return this.fittedNames().length < this.currents.length;
  }

  /** 条上某个清单是不是"选中"状态（多选看 currents，单选看 current）。 */
  private stripActive(key: string): boolean {
    if (this.multi) {
      return key.length === 0 ? this.currents.length === 0 : this.currents.indexOf(key) >= 0;
    }
    return this.current === key;
  }

  /**
   * `strip` 形态（收藏页）：**一颗按内容自适应的胶囊**，点它才展开抽屉。
   *
   * 2026-11-16 用户纠正第一版：「仍然要做成点一下就展开的抽屉，再在抽屉里操作多选；
   * 胶囊应该做成动态宽度（而不是一上来就横满），胶囊里只显示被我选上的清单」。
   * 所以这里不再平铺所有清单 —— 只显示当前选中的那几个名字（多个用顿号连），
   * 宽度跟着文字走，最多占 62% 宽再省略。
   */
  @Builder
  Strip() {
    Row() {
      Row({ space: 6 }) {
        Text(this.currents.length === 0 ? '清单' : '清单')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.selectionLabel())
          .fontSize(13)
          .fontWeight(this.currents.length > 0 ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.currents.length > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.overflowed() ? 132 : 200 })
        // 「等」**单独一个 Text**（2026-11-16 用户反馈：名字太长时它会被省略号一起吞掉）。
        // 不参与上面的省略，只要后面还有没显示出来的清单就一定在。
        if (this.overflowed()) {
          Text('等')
            .fontSize(13)
            .fontColor(this.currents.length > 0 ? '#FFFFFF' : Theme.TEXT_DIM)
        }
        // 展开箭头：用两条边拼出来的 chevron（不再用字形 ▾ —— 小字号下会糊成一个污点）
        Column()
          .width(6)
          .height(6)
          .borderWidth({ top: 0, left: 0, right: 1, bottom: 1 })
          .borderColor('#B3FFFFFF')
          .rotate({ angle: 45 })
          .margin({ top: -3 })
      }
      .padding({ left: 14, right: 12, top: 7, bottom: 7 })
      .backgroundColor('#24FFFFFF')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: Theme.STROKE_HI })
      .borderRadius(Theme.R_PILL)
      .onClick(() => {
        this.open();
      })

      Blank()

      if (this.showManage) {
        // 管理入口：不用齿轮（页面下方「筛选」已经是齿轮），三个点表示"更多"
        Text('⋯')
          .fontSize(16)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 8, right: 2, top: 2, bottom: 4 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/CollectionsPage' });
          })
      }
    }
    .width('100%')
  }

  build() {
    if (this.variant === 'strip') {
      Column() {
        this.Strip()
      }
      .width('100%')
      .bindSheet($$this.show, this.Picker(), {
        height: 520,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.BG_RAISED
      })
    } else {
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
        // 管理是「另一个动作」，做成独立的圆钮；图标用「⋯」不用齿轮 ——
        // 齿轮已经属于下方的「筛选」，两个齿轮并排会点错（2026-11-16 用户反馈）。
        Column() {
          Text('⋯')
            .fontSize(16)
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
}
