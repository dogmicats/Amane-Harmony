import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { dropPageCache, httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/** 一个自建分类（覆盖层里有、库里没有的名字）。 */
interface VirtualFacet {
  kind: string;
  name: string;
  films: number;
  cover: string;
  posters: string[];
}

interface VirtualRes {
  ok: boolean;
  data: VirtualData;
}

interface VirtualData {
  items: VirtualFacet[];
  total: number;
}

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';
const ST_ERR: string = 'err';

/**
 * 自建标签 / 系列（2.5.5.16）。
 *
 * 只列**用户自己起的名字** —— 库里原有的系列 / 标签不在这里，也不提供改删
 * （用户明确要求暂时不给这个能力）。删掉一个自建分类，等于把它从所有片的
 * 覆盖字段里摘掉，影片本身不动。
 */
@Entry
@Component
struct SelfFacetPage {
  @State st: string = ST_LOADING;
  @State items: VirtualFacet[] = [];
  @State note: string = '';
  @State busy: boolean = false;
  /** 改名浮层：ArkUI 没有带输入的对话框，自己盖一层（打开时重建，输入框初值才生效）。 */
  /** 新建浮层：先建一个还没有片挂着的自建系列 / 标签。 */
  @State createOpen: boolean = false;
  @State ck: string = 'tag';
  @State cname: string = '';
  @State renameOpen: boolean = false;
  @State rk: string = '';
  @State rfrom: string = '';
  @State rto: string = '';
  @State rfilms: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.st = ST_LOADING;
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/virtual_facets`, Store.I.token);
      const res = JSON.parse(raw) as VirtualRes;
      const data = res.data;
      const list: VirtualFacet[] = [];
      if (data !== undefined && data !== null && data.items !== undefined && data.items !== null) {
        for (let i = 0; i < data.items.length; i++) {
          const it: VirtualFacet = data.items[i];
          const name: string = it.name === undefined || it.name === null ? '' : `${it.name}`;
          if (name.length > 0) {
            const posters: string[] = [];
            const rawPosters = it.posters;
            if (rawPosters !== undefined && rawPosters !== null) {
              for (let k = 0; k < rawPosters.length; k++) {
                const p = `${rawPosters[k]}`;
                if (p.length > 0) {
                  posters.push(p);
                }
              }
            }
            list.push({
              kind: it.kind === undefined || it.kind === null ? 'tag' : `${it.kind}`,
              name: name,
              films: it.films === undefined || it.films === null ? 0 : Number(it.films),
              cover: it.cover === undefined || it.cover === null ? '' : `${it.cover}`,
              posters: posters
            });
          }
        }
      }
      this.items = list;
      this.st = ST_OK;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] virtual facets: ${e.code} ${e.message}`);
      this.st = ST_ERR;
      this.note = e.code === 404 ? '服务端还不支持自建分类的管理（需新版服务端）' : '读取失败，点这里重试';
    }
  }

  private ofKind(kind: string): VirtualFacet[] {
    const out: VirtualFacet[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].kind === kind) {
        out.push(this.items[i]);
      }
    }
    return out;
  }

  private confirmDelete(it: VirtualFacet): void {
    const label: string = it.kind === 'series' ? '系列' : '标签';
    AlertDialog.show({
      title: `删掉自建${label}「${it.name}」？`,
      // 说清「删的到底是什么」：这个名字不在库里，只写在你改过的那 N 部片的字段里
      message: `这 ${it.films} 部影片不再挂「${it.name}」这个名字。\n\n` +
        `名字本来就不在库里，只存在你改过的那几部片上；影片文件、库里原有的${label}都不动。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删掉',
        fontColor: Theme.DANGER,
        action: () => {
          this.remove(it);
        }
      }
    });
  }

  /** 点一行 → 该分类的影片墙（自建分类没有 id，走 name）。 */
  private openFacet(it: VirtualFacet): void {
    const params: Record<string, Object> = { 'kind': it.kind, 'id': 0, 'name': it.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: params });
  }

  private openCreate(): void {
    this.ck = 'tag';
    this.cname = '';
    this.createOpen = true;
  }

  /** 只写登记表：不碰任何影片，等用户在某部片里填同一个名字时自然挂上。 */
  private async doCreate(): Promise<void> {
    const name: string = this.cname.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '名字不能为空', duration: 1400 });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const body: Record<string, Object> = { 'kind': this.ck, 'name': name };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/virtual_facets/create`, Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        this.createOpen = false;
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({
          message: `已新建${this.ck === 'series' ? '系列' : '标签'}「${name}」`,
          duration: 1600
        });
        this.load();
      } else {
        promptAction.showToast({ message: '没建成，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      // 409 = 库里已有同名分类（服务端专门挡了这一种），说人话
      const msg: string = e.message.indexOf('409') >= 0
        ? '库里已经有同名的分类了，换个名字'
        : '没建成，稍后再试';
      promptAction.showToast({ message: msg, duration: 2000 });
    } finally {
      this.busy = false;
    }
  }

  private openRename(it: VirtualFacet): void {
    this.rk = it.kind;
    this.rfrom = it.name;
    this.rto = it.name;
    this.rfilms = it.films;
    this.renameOpen = true;
  }

  /** 改名 = 把所有片覆盖层里的旧名换成新名；只动覆盖层，库里分类不动。 */
  private async doRename(): Promise<void> {
    const to: string = this.rto.trim();
    if (to.length === 0) {
      promptAction.showToast({ message: '名字不能为空', duration: 1400 });
      return;
    }
    if (to === this.rfrom) {
      this.renameOpen = false;
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const body: Record<string, Object> = { 'kind': this.rk, 'from': this.rfrom, 'to': to };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/virtual_facets/rename`, Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        const data = obj.data as Record<string, Object>;
        const native: boolean = data.native === true;
        dropPageCache();
        Store.I.coverDirty = true;
        this.renameOpen = false;
        promptAction.showToast({
          message: native ? `已改成「${to}」，并入了库里的同名分类` : `已改成「${to}」`,
          duration: 1800
        });
        this.load();
      } else {
        promptAction.showToast({ message: '没改成，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] virtual rename: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没改成，稍后再试', duration: 1600 });
    } finally {
      this.busy = false;
    }
  }

  private async remove(it: VirtualFacet): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const body: Record<string, Object> = { 'kind': it.kind, 'name': it.name };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/virtual_facets/delete`, Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: `已删掉「${it.name}」`, duration: 1500 });
        this.load();
      } else {
        promptAction.showToast({ message: '没删成，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] virtual del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没删成，稍后再试', duration: 1600 });
    } finally {
      this.busy = false;
    }
  }

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('自建标签 / 系列')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('只列你自己起的名字，库里的分类不在这里')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text('＋')
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.ACCENT)
        .width(40)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.openCreate();
        })
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  @Builder
  Group(kind: string, title: string, hint: string) {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text(`${this.ofKind(kind).length}`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
      }
      .width('100%')

      if (this.ofKind(kind).length === 0) {
        Text(hint)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      } else {
        ForEach(this.ofKind(kind), (it: VirtualFacet) => {
          // 一行一条横幅（和「制片厂」那条长图版式一致）：没有自定义封面时
          // 用该分类下几部片的海报拼贴，而不是一个光秃秃的首字块。
          Stack({ alignContent: Alignment.BottomStart }) {
            if (it.cover.length > 0) {
              Image(Store.I.img(it.cover))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .alt($r('app.media.placeholder'))
            } else if (it.posters.length > 0) {
              Row({ space: 1 }) {
                ForEach(it.posters.slice(0, 3), (p: string, i: number) => {
                  Image(Store.I.img(p))
                    .width(`${(100 / Math.min(3, it.posters.length)).toFixed(2)}%`)
                    .height('100%')
                    // 竖版海报（2:3）放进宽横幅时，Cover 会等比放大再居中裁，
                    // 头就没了。TopStart 只裁底部，人脸保住。
                    .objectFit(ImageFit.TOP_START)
                    .alt($r('app.media.placeholder'))
                }, (p: string, i: number) => `vp-${it.kind}-${it.name}-${i}`)
              }
              .width('100%')
              .height('100%')
            } else {
              Column() {
                Text(it.name.length > 0 ? it.name.substring(0, 1) : '#')
                  .fontSize(22)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Theme.CARD_HI)
            }

            // 底部渐变：名字压在图上也要看得清
            Column()
              .width('100%')
              .height('66%')
              .linearGradient({
                angle: 180,
                colors: [['#00000000', 0], ['#B80B0B0F', 0.55], ['#F70B0B0F', 1]]
              })

            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(it.name)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${it.films} 部 · 自建${it.kind === 'series' ? '系列' : '标签'}`)
                  .fontSize(10)
                  .fontColor('#B9B9C6')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('改名')
                .fontSize(11)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor('#4D000000')
                .borderRadius(9)
                .onClick(() => {
                  this.openRename(it);
                })

              Text('删除')
                .fontSize(11)
                .fontColor('#FFB4B4')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor('#4D000000')
                .borderRadius(9)
                .onClick(() => {
                  this.confirmDelete(it);
                })
            }
            .width('100%')
            .padding({ left: 12, right: 10, bottom: 9 })
          }
          .width('100%')
          .height(118)
          .borderRadius(12)
          .clip(true)
          .onClick(() => {
            this.openFacet(it);
          })
        }, (it: VirtualFacet) => `vf-${it.kind}-${it.name}-${it.films}-${it.cover.length}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  /** 改名浮层：ArkUI 没有「带输入框的对话框」，自己盖一层（打开时重建，初值才生效）。 */
  @Builder
  RenameSheet() {
    Column() {
      Column({ space: 12 }) {
        Text(this.rk === 'series' ? '重命名系列' : '重命名标签')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(`会改 ${this.rfilms} 部影片里你自己填的${this.rk === 'series' ? '系列名' : '标签'}。新名字如果库里已经有，这些片会并进那个分类。`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(15)
          .width('100%')
        TextInput({ text: this.rto, placeholder: '新名字' })
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onChange((v: string) => {
            this.rto = v;
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(10)
            .onClick(() => {
              this.renameOpen = false;
            })
          Text(this.busy ? '…' : '确定')
            .fontSize(12)
            .fontColor(Theme.ON_ACCENT)
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .backgroundColor(Theme.ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.doRename();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('86%')
      .padding(16)
      .backgroundColor(Theme.CARD)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
      // 点卡片本身不关（只有点遮罩才关）
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.renameOpen = false;
    })
  }

  @Builder
  CreateSheet() {
    Column() {
      // 点浮层外部关闭
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.createOpen = false;
        })

      Column({ space: 12 }) {
        Text('新建自建分类')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .width('100%')

        Row({ space: 8 }) {
          ForEach([['tag', '标签'], ['series', '系列']], (pair: string[]) => {
            Text(pair[1])
              .fontSize(12)
              .fontColor(this.ck === pair[0] ? Theme.BG : Theme.TEXT)
              .backgroundColor(this.ck === pair[0] ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(14)
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .onClick(() => {
                this.ck = pair[0];
              })
          }, (pair: string[]) => `ck-${pair[0]}`)
          Blank()
        }
        .width('100%')

        TextInput({ placeholder: '名字（例：某个你记得住的叫法）', text: this.cname })
          .fontSize(13)
          .height(40)
          .maxLength(60)
          .onChange((v: string) => {
            this.cname = v;
          })

        Text('先建好名字，之后在影片的「编辑信息」里填同一个名字，影片就会挂到它下面。')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(15)

        Row({ space: 10 }) {
          Blank()
          Button('取消')
            .height(34)
            .fontSize(13)
            .backgroundColor(Theme.CARD_HI)
            .fontColor(Theme.TEXT)
            .onClick(() => {
              this.createOpen = false;
            })
          Button('新建')
            .height(34)
            .fontSize(13)
            .enabled(!this.busy)
            .onClick(() => {
              this.doCreate();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(18)
      .backgroundColor(Theme.CARD)
      .borderRadius({ topLeft: 18, topRight: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
      this.Header()

      if (this.st === ST_OK) {
        Scroll() {
          Column({ space: 12 }) {
            this.Group('series', '系列', '还没有自建的系列')
            this.Group('tag', '标签', '还没有自建的标签')

            Text('在影片的「编辑信息」里填一个库里没有的名字，保存时确认「新建」，它就会出现在这里。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
              .padding({ bottom: Theme.BOTTOM_SAFE })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 10 }) {
          if (this.st === ST_LOADING) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Theme.ACCENT)
          } else {
            Text(this.note)
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .height(34)
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(12)
              .onClick(() => {
                this.load();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)

      if (this.renameOpen) {
        this.RenameSheet()
      }

      if (this.createOpen) {
        this.CreateSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
