import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, dropPageCache, httpPost, httpPut, httpDelete } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { ItemDetail } from '../common/Types';
import { safeDetail } from '../common/Safe';

/**
 * 编辑影片信息（2.5.5 · Agent2 客户端）。
 *
 * 改的是**本地覆盖层**（服务端 `meta_override` 表），不动 amane 的库：
 * 网页端看不到这些改动，随时可「恢复默认」。字段名与库同名（title / actors / tags /
 * series / studio / release / note），客户端**不做合并判断** —— 读接口一律覆盖优先。
 *
 * 契约在 `docs/TASKS/2.5.5-metadata-cover.md` §4。
 *
 * 保存策略：**只发改过的字段**（与 `base` 逐项比），这样「只改标题」不会把别的字段
 * 一起写进覆盖层 —— 否则以后库那边更新了，本地会一直压着一个旧值。
 */

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';
/** 老服务端没这组端点（404）。 */
const ST_OFF: string = 'off';

interface OverrideFields {
  title: string;
  actors: string[];
  tags: string[];
  series: string;
  studio: string;
  release: string;
  note: string;
}

interface OverrideData {
  id: number;
  /** 只含改过的键。 */
  fields: OverrideFields;
  cover: string;
}

interface OverrideRes {
  ok: boolean;
  version: number;
  reason: string;
  data: OverrideData;
}

interface SimpleData {
  removed: number;
}

interface SimpleRes {
  ok: boolean;
  version: number;
  data: SimpleData;
}

function str(v: string): string {
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}

function strList(v: string[]): string[] {
  const out: string[] = [];
  if (v === undefined || v === null) {
    return out;
  }
  for (let i = 0; i < v.length; i++) {
    const t: string = str(v[i]);
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

function sameList(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

function emptyFields(): OverrideFields {
  const f: OverrideFields = {
    title: '', actors: [], tags: [], series: '', studio: '', release: '', note: ''
  };
  return f;
}

/** 一个联想候选（演员 / 标签 / 系列 / 厂牌共用）。 */
interface SugItem {
  id: number;
  name: string;
  count: number;
}

/**
 * 联想候选条。抽成独立组件而不是页面里的 `@Builder`：
 * `@Builder` 带参时外面的 `@State` 变了不一定重建 `if` 分支（2.5.1.20 踩过），
 * 而 `@Prop` 一变子组件会整体重绘，候选区才能真的出现/消失。
 */
@Component
struct SugList {
  @Prop items: SugItem[] = [];
  @Prop active: boolean = false;
  onPick: (name: string) => void = (name: string) => {};

  build() {
    if (this.active && this.items.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.items, (it: SugItem) => {
          Row({ space: 4 }) {
            Text(it.name)
              .fontSize(10)
              .fontColor(Theme.TEXT_DIM)
              .maxLines(1)
            if (it.count > 0) {
              Text(`${it.count}`)
                .fontSize(8)
                .fontColor(Theme.TEXT_FAINT)
            }
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(10)
          .margin({ right: 5, bottom: 5 })
          .onClick(() => {
            this.onPick(it.name);
          })
        }, (it: SugItem) => `${it.name}-${it.count}`)
      }
      .width('100%')
    }
  }
}

/**
 * 单值字段（标题 / 系列 / 厂牌 / 发行日）。
 *
 * 为什么是 `@Component` 而不是页面里的 `@Builder`：`@Builder` 的参数是**值拷贝**，
 * 页面 `@State` 变了它不会重建（2.5.5.6 的「联想点了不填入」就是这个）；
 * 而且 `TextInput` 的 `text` 只在创建时取一次，外部改值必须走 `TextInputController`。
 */
@Component
struct EditField {
  @Prop label: string = '';
  /**
   * 外部改值（点联想候选）要能**回填到输入框**。
   * `TextInputController` 没有 setText，`text:` 又只在创建时取一次，
   * 所以这里自己持一份 `@State text`：@Prop 变了用 @Watch 同步过来，
   * 输入框用 `$$this.text` 双向绑。
   */
  @Prop @Watch('onValueChange') value: string = '';
  @Prop hint: string = '';
  @Prop touched: boolean = false;
  @Prop sugItems: SugItem[] = [];
  @Prop sugActive: boolean = false;
  @State text: string = '';
  onChange: (v: string) => void = (v: string) => {};
  onPick: (name: string) => void = (name: string) => {};

  aboutToAppear(): void {
    this.text = this.value;
  }

  onValueChange(): void {
    if (this.text !== this.value) {
      this.text = this.value;
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        if (this.touched) {
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(Theme.ACCENT)
        }
        Blank()
      }
      .width('100%')

      TextInput({ text: $$this.text, placeholder: this.hint })
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(8)
        .onChange((v: string) => {
          this.onChange(v);
        })

      SugList({
        items: this.sugItems,
        active: this.sugActive,
        onPick: (n: string) => {
          this.onPick(n);
        }
      })
    }
    .width('100%')
  }
}

/**
 * 名字列表（演员 / 标签）：chip 可删，下面一行可加。
 *
 * 与 `EditField` 同一个理由 —— 原来写成 `@Builder`，点「✕」数据删了但界面不动，
 * 看起来就是「点了没反应」。
 */
@Component
struct EditList {
  @Prop label: string = '';
  @Prop items: string[] = [];
  @Prop @Watch('onDraftChange') draft: string = '';
  @Prop hint: string = '';
  @Prop touched: boolean = false;
  @Prop sugItems: SugItem[] = [];
  @Prop sugActive: boolean = false;
  /** 同上：编辑框自己持一份文本，外部清空（加完一个名字）要能看见。 */
  @State text: string = '';
  onDraft: (v: string) => void = (v: string) => {};
  onAdd: () => void = () => {};
  onRemove: (name: string) => void = (name: string) => {};
  onPick: (name: string) => void = (name: string) => {};

  aboutToAppear(): void {
    this.text = this.draft;
  }

  onDraftChange(): void {
    if (this.text !== this.draft) {
      this.text = this.draft;
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        if (this.touched) {
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(Theme.ACCENT)
        }
        Blank()
        Text(`${this.items.length}`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      if (this.items.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.items, (it: string) => {
            Row({ space: 5 }) {
              Text(it)
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
              // 「✕」单独给一块 16×16 的点击区：之前挤在胶囊里，
              // 手指按偏一点就落到胶囊外，观感就是「点了没反应」
              Text('✕')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width(16)
                .height(16)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.onRemove(it);
                })
            }
            .padding({ left: 9, right: 4, top: 4, bottom: 4 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(11)
            .margin({ right: 6, bottom: 6 })
          }, (it: string) => `chip-${this.label}-${it}`)
        }
        .width('100%')
      }

      TextInput({ text: $$this.text, placeholder: this.hint })
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(8)
        .onChange((v: string) => {
          this.onDraft(v);
        })
        .onSubmit(() => {
          this.onAdd();
        })

      SugList({
        items: this.sugItems,
        active: this.sugActive,
        onPick: (n: string) => {
          this.onPick(n);
        }
      })
    }
    .width('100%')
  }
}

@Entry
@Component
struct MetaEditPage {
  @State mid: number = 0;
  @State st: string = ST_LOADING;
  @State note: string = '';

  @State title: string = '';
  @State actors: string[] = [];
  @State tags: string[] = [];
  @State series: string = '';
  @State studio: string = '';
  @State release: string = '';
  @State memo: string = '';

  /** 库里的原值：用来判断「改了哪几项」和「恢复默认后长什么样」。 */
  @State base: OverrideFields = emptyFields();
  /** 覆盖层已有的值：用来标「这一项你改过」。 */
  @State touched: string[] = [];

  @State actorDraft: string = '';
  @State tagDraft: string = '';
  @State busy: boolean = false;

  /** 联想候选：`sugKind` 决定候选条画在哪个字段下面（空 = 不画）。 */
  @State sugKind: string = '';
  @State sugs: SugItem[] = [];
  private sugTimer: number = -1;
  /** 保存前要新建的名字（非空时页面底部出现确认带）。 */
  @State missing: string[] = [];
  private pendingSave: Record<string, Object> = {};
  /** 每个字段最近一次输入的词，异步回来时比对，防止旧请求覆盖新候选。 */
  private sugWord: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const raw = params.id;
      this.mid = raw === undefined || raw === null ? 0 : Number(raw);
    }
    this.load();
  }

  private async load(): Promise<void> {
    if (this.mid <= 0) {
      this.st = ST_OFF;
      return;
    }
    this.st = ST_LOADING;
    try {
      // ① 先取影片本身（已由服务端按「覆盖优先」合并过）—— 既当显示值，也当「改没改」的基准。
      //    覆盖层接口只回 `fields`，不回库值，所以基准必须从 item 拿。
      const itemRaw: string = await httpGet(
        `${Store.I.user}/api/user/item/${this.mid}`, Store.I.token);
      const item: ItemDetail = safeDetail(JSON.parse(itemRaw) as ItemDetail);
      const base: OverrideFields = {
        title: str(item.title),
        actors: strList(item.actors),
        tags: strList(item.tags),
        series: str(item.series),
        studio: str(item.studio),
        release: str(item.release),
        note: ''
      };
      this.base = base;
      this.title = base.title;
      this.actors = base.actors;
      this.tags = base.tags;
      this.series = base.series;
      this.studio = base.studio;
      this.release = base.release;
      this.memo = base.note;

      // ② 再取覆盖层：只用来标「这一项你改过」+ 把覆盖值铺回去
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/meta_override/${this.mid}`, Store.I.token);
      const res: OverrideRes = JSON.parse(raw) as OverrideRes;
      if (res.data === undefined || res.data === null) {
        this.st = ST_OFF;
        return;
      }
      const cur: OverrideFields = this.norm(res.data.fields);
      this.touched = this.touchedOf(cur);
      if (cur.title.length > 0) {
        this.title = cur.title;
      }
      if (cur.actors.length > 0) {
        this.actors = cur.actors;
      }
      if (cur.tags.length > 0) {
        this.tags = cur.tags;
      }
      if (cur.series.length > 0) {
        this.series = cur.series;
      }
      if (cur.studio.length > 0) {
        this.studio = cur.studio;
      }
      if (cur.release.length > 0) {
        this.release = cur.release;
      }
      if (cur.note.length > 0) {
        this.memo = cur.note;
      }
      this.note = '';
      this.st = ST_OK;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] meta_override get: ${e.code} ${e.message}`);
      this.st = ST_OFF;
      this.note = e.code === 404 ? '服务端还不支持自定义修改（需新版服务端）' : '读取失败';
    }
  }

  private norm(f: OverrideFields): OverrideFields {
    if (f === undefined || f === null) {
      return emptyFields();
    }
    const out: OverrideFields = {
      title: str(f.title),
      actors: strList(f.actors),
      tags: strList(f.tags),
      series: str(f.series),
      studio: str(f.studio),
      release: str(f.release),
      note: str(f.note)
    };
    return out;
  }

  /** 哪些字段在覆盖层里（= 用户改过）。 */
  private touchedOf(cur: OverrideFields): string[] {
    const out: string[] = [];
    if (cur.title.length > 0) {
      out.push('title');
    }
    if (cur.actors.length > 0) {
      out.push('actors');
    }
    if (cur.tags.length > 0) {
      out.push('tags');
    }
    if (cur.series.length > 0) {
      out.push('series');
    }
    if (cur.studio.length > 0) {
      out.push('studio');
    }
    if (cur.release.length > 0) {
      out.push('release');
    }
    if (cur.note.length > 0) {
      out.push('note');
    }
    return out;
  }

  private isTouched(key: string): boolean {
    return this.touched.indexOf(key) >= 0;
  }

  /** 只把**改过**的字段发上去（和库的原值比）。 */
  private async save(): Promise<void> {
    if (this.busy) {
      return;
    }
    // 输入框里还没按回车的内容也要算数 —— 以前填了标签直接点保存，
    // 会被判成「没有改动」，用户以为丢了。
    if (this.actorDraft.trim().length > 0) {
      this.addActor();
    }
    if (this.tagDraft.trim().length > 0) {
      this.addTag();
    }
    const body: Record<string, Object> = {};
    if (this.title !== this.base.title) {
      body['title'] = this.title;
    }
    if (!sameList(this.actors, this.base.actors)) {
      body['actors'] = this.actors;
    }
    if (!sameList(this.tags, this.base.tags)) {
      body['tags'] = this.tags;
    }
    if (this.series !== this.base.series) {
      body['series'] = this.series;
    }
    if (this.studio !== this.base.studio) {
      body['studio'] = this.studio;
    }
    if (this.release !== this.base.release) {
      body['release'] = this.release;
    }
    if (this.memo !== this.base.note) {
      body['note'] = this.memo;
    }
    if (Object.keys(body).length === 0) {
      promptAction.showToast({ message: '没有改动', duration: 1400 });
      return;
    }
    // 库里没有的系列 / 标签 / 厂牌：先问一句「是否新建」（像 Windows 新建文件夹）
    this.busy = true;
    const missing: string[] = await this.missingNames(body);
    this.busy = false;
    if (missing.length > 0) {
      // 不用系统对话框：连续保存两次会叠出两个框，点掉一个另一个还在，
      // 第二次保存时页面已经退出，看着就是「建了一个、另一个失败」。
      // 改成页面底部一条确认带，状态明确、不会被叠。
      this.missing = missing;
      this.pendingSave = body;
      return;
    }
    this.doSave(body);
  }

  private confirmCreate(): void {
    const body: Record<string, Object> = this.pendingSave;
    this.missing = [];
    this.pendingSave = {};
    this.doSave(body);
  }

  /**
   * 查这批名字在库里存不存在，返回「库里没有」的可读列表（空数组 = 全都有）。
   *
   * 查询失败一律当「都有」—— 宁可不提示，也不能因为一个探测请求把保存挡住。
   */
  private async missingNames(body: Record<string, Object>): Promise<string[]> {
    const items: Record<string, Object>[] = [];
    const series: string = body['series'] === undefined ? '' : `${body['series']}`.trim();
    if (series.length > 0) {
      items.push({ 'kind': 'series', 'name': series });
    }
    const studio: string = body['studio'] === undefined ? '' : `${body['studio']}`.trim();
    if (studio.length > 0) {
      items.push({ 'kind': 'studio', 'name': studio });
    }
    const actors: string[] = body['actors'] as string[];
    if (actors !== undefined && actors !== null) {
      for (let i = 0; i < actors.length; i++) {
        items.push({ 'kind': 'actor', 'name': `${actors[i]}` });
      }
    }
    const tags: string[] = body['tags'] as string[];
    if (tags !== undefined && tags !== null) {
      for (let i = 0; i < tags.length; i++) {
        items.push({ 'kind': 'tag', 'name': `${tags[i]}` });
      }
    }
    if (items.length === 0) {
      return [];
    }
    try {
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/names/check`, Store.I.token, JSON.stringify({ 'items': items }));
      const res = JSON.parse(raw) as Record<string, Object>;
      const data = res.data as Record<string, Object>;
      const list = data.items as Record<string, Object>[];
      const out: string[] = [];
      if (list !== undefined && list !== null) {
        for (let i = 0; i < list.length; i++) {
          if (list[i].exists === true) {
            continue;
          }
          const kind: string = `${list[i].kind}`;
          let label: string = '厂牌';
          if (kind === 'series') {
            label = '系列';
          } else if (kind === 'tag') {
            label = '标签';
          } else if (kind === 'actor') {
            label = '演员';
          }
          out.push(`· ${label}「${list[i].name}」`);
        }
      }
      return out;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] names check: ${e.code} ${e.message}`);
      return [];
    }
  }

  private async doSave(body: Record<string, Object>): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const raw: string = await httpPut(
        `${Store.I.user}/api/user/meta_override/${this.mid}`, Store.I.token, JSON.stringify(body));
      const res: OverrideRes = JSON.parse(raw) as OverrideRes;
      if (res.ok === true) {
        // 首页 / 列表的 GET 缓存要丢：否则列表还按旧片名显示，等 5 分钟才变
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '存好了，列表会按你的版本显示', duration: 1600 });
        router.back();
      } else {
        promptAction.showToast({ message: str(res.reason).length > 0 ? res.reason : '没存成', duration: 1800 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] meta_override put: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没存成，稍后再试', duration: 1600 });
    } finally {
      this.busy = false;
    }
  }

  /** 恢复默认：连封面一起清（服务端契约如此），所以先问一句。 */
  private confirmReset(): void {
    AlertDialog.show({
      title: '恢复成刮削的原始信息？',
      message: '你改过的字段和换过的封面都会被清掉，所有设备都会变回库里的原样',
      primaryButton: {
        value: '恢复',
        fontColor: Theme.DANGER,
        action: () => {
          this.reset();
        }
      },
      secondaryButton: {
        value: '算了',
        action: () => {
        }
      }
    });
  }

  private async reset(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const raw: string = await httpDelete(
        `${Store.I.user}/api/user/meta_override/${this.mid}`, Store.I.token);
      const res: SimpleRes = JSON.parse(raw) as SimpleRes;
      if (res.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '已恢复默认', duration: 1500 });
        this.load();
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] meta_override del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没恢复成，稍后再试', duration: 1600 });
    } finally {
      this.busy = false;
    }
  }

  private addActor(): void {
    const v: string = this.actorDraft.trim();
    if (v.length === 0) {
      return;
    }
    if (this.actors.indexOf(v) >= 0) {
      this.actorDraft = '';
      this.sugs = [];
      this.sugKind = '';
      return;
    }
    const next: string[] = this.actors.slice();
    next.push(v);
    this.actors = next;
    this.actorDraft = '';
    this.sugs = [];
    this.sugKind = '';
  }

  private addTag(): void {
    const v: string = this.tagDraft.trim();
    if (v.length === 0) {
      return;
    }
    if (this.tags.indexOf(v) >= 0) {
      this.tagDraft = '';
      this.sugs = [];
      this.sugKind = '';
      return;
    }
    const next: string[] = this.tags.slice();
    next.push(v);
    this.tags = next;
    this.tagDraft = '';
    this.sugs = [];
    this.sugKind = '';
  }

  private removeActor(name: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.actors.length; i++) {
      if (this.actors[i] !== name) {
        next.push(this.actors[i]);
      }
    }
    this.actors = next;
  }

  private removeTag(name: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i] !== name) {
        next.push(this.tags[i]);
      }
    }
    this.tags = next;
  }

  // ---- 视图 ------------------------------------------------------------

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
        Text('编辑信息')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('存在你的服务端，换手机也在')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 副标题一长就把「保存」挤出屏幕：这里必须吃掉剩余宽度，让按钮固定在右侧
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.st === ST_OK) {
        Text(this.busy ? '…' : '保存')
          .fontSize(12)
          .fontColor(Theme.ON_ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(14)
          .onClick(() => {
            this.save();
          })
      }
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  /** 一行输入。「改过」的项右上角点一个小点，省得忘了哪些是本地覆盖。 */
  private applyField(key: string, v: string): void {
    if (key === 'title') {
      this.title = v;
    } else if (key === 'series') {
      this.series = v;
      this.queueSug('series', v);
    } else if (key === 'studio') {
      this.studio = v;
      this.queueSug('studio', v);
    } else if (key === 'release') {
      this.release = v;
    } else if (key === 'note') {
      this.memo = v;
    }
  }

  // ---- 联想（2.5.5.4）：手打的名字常常和库里的写法差一个字 ----------------

  /**
   * 输入后 260ms 再查，避免每敲一个字发一次请求。
   * 空输入直接清候选 —— 这时候该看的是「我有哪些」，不是候选。
   */
  private queueSug(kind: string, q: string): void {
    const word: string = q.trim();
    this.sugKind = kind;
    this.sugWord = word;
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    if (word.length === 0) {
      this.sugs = [];
      return;
    }
    this.sugTimer = setTimeout(() => {
      this.sugTimer = -1;
      this.fetchSug(kind, word);
    }, 260);
  }

  private sugUrl(kind: string, word: string): string {
    let path: string = '/api/user/actors';
    if (kind === 'tags') {
      path = '/api/user/facets/tag';
    } else if (kind === 'series') {
      path = '/api/user/facets/series';
    } else if (kind === 'studio') {
      path = '/api/user/facets/studio';
    }
    return `${Store.I.user}${path}?search=${encodeURIComponent(word)}&limit=8`;
  }

  /** 拉候选。失败一律当「没有候选」—— 联想不该弹错误，也不该拦住保存。 */
  private async fetchSug(kind: string, word: string): Promise<void> {
    try {
      const raw: string = await httpGet(this.sugUrl(kind, word), Store.I.token);
      const obj = JSON.parse(raw) as Record<string, Object>;
      // 用户又改了输入：这份结果已经过期，丢掉
      if (this.sugKind !== kind || this.sugWord !== word) {
        return;
      }
      const list: SugItem[] = [];
      const src = obj.items as SugItem[];
      if (src !== undefined && src !== null && Array.isArray(src)) {
        for (let i = 0; i < src.length && list.length < 8; i++) {
          const it = src[i];
          const name: string = str(it.name);
          if (name.length === 0) {
            continue;
          }
          list.push({ id: Number(it.id) || 0, name: name, count: Number(it.count) || 0 });
        }
      }
      this.sugs = list;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] sug ${kind}: ${e.code}`);
      this.sugs = [];
    }
  }

  /** 点候选 = 采用库里的写法：单值字段直接填，多值字段追加成 chip。 */
  private pickSug(kind: string, name: string): void {
    if (kind === 'series') {
      this.series = name;
    } else if (kind === 'studio') {
      this.studio = name;
    } else if (kind === 'actors') {
      if (this.actors.indexOf(name) < 0) {
        const next: string[] = this.actors.slice();
        next.push(name);
        this.actors = next;
      }
      this.actorDraft = '';
    } else if (kind === 'tags') {
      if (this.tags.indexOf(name) < 0) {
        const next: string[] = this.tags.slice();
        next.push(name);
        this.tags = next;
      }
      this.tagDraft = '';
    }
    this.sugs = [];
    this.sugKind = '';
  }

  /** 名字列表（演员 / 标签）：已抽成 `EditList` 组件。 */

  build() {
    Column() {
      this.Header()

      if (this.st === ST_OK) {
        Scroll() {
          Column({ space: 14 }) {
            Column({ space: 12 }) {
              EditField({
                label: '标题', value: this.title, hint: '片名',
                touched: this.isTouched('title'),
                onChange: (v: string) => {
                  this.applyField('title', v);
                }
              })
              EditField({
                label: '系列', value: this.series, hint: '没有就留空',
                touched: this.isTouched('series'),
                sugActive: this.sugKind === 'series', sugItems: this.sugs,
                onChange: (v: string) => {
                  this.applyField('series', v);
                },
                onPick: (n: string) => {
                  this.pickSug('series', n);
                }
              })
              EditField({
                label: '厂牌', value: this.studio, hint: '制片商',
                touched: this.isTouched('studio'),
                sugActive: this.sugKind === 'studio', sugItems: this.sugs,
                onChange: (v: string) => {
                  this.applyField('studio', v);
                },
                onPick: (n: string) => {
                  this.pickSug('studio', n);
                }
              })
              EditField({
                label: '发行日', value: this.release, hint: 'YYYY-MM-DD',
                touched: this.isTouched('release'),
                onChange: (v: string) => {
                  this.applyField('release', v);
                }
              })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)

            Column({ space: 12 }) {
              EditList({
                label: '演员', items: this.actors, draft: this.actorDraft,
                hint: '输一个名字，回车加进去',
                touched: this.isTouched('actors'),
                sugActive: this.sugKind === 'actors', sugItems: this.sugs,
                onDraft: (v: string) => {
                  this.actorDraft = v;
                  this.queueSug('actors', v);
                },
                onAdd: () => {
                  this.addActor();
                },
                onRemove: (name: string) => {
                  this.removeActor(name);
                },
                onPick: (n: string) => {
                  this.pickSug('actors', n);
                }
              })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)

            Column({ space: 12 }) {
              EditList({
                label: '标签', items: this.tags, draft: this.tagDraft,
                hint: '输一个标签，回车加进去',
                touched: this.isTouched('tags'),
                sugActive: this.sugKind === 'tags', sugItems: this.sugs,
                onDraft: (v: string) => {
                  this.tagDraft = v;
                  this.queueSug('tags', v);
                },
                onAdd: () => {
                  this.addTag();
                },
                onRemove: (name: string) => {
                  this.removeTag(name);
                },
                onPick: (n: string) => {
                  this.pickSug('tags', n);
                }
              })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)

            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Text('备注')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                if (this.isTouched('note')) {
                  Column()
                    .width(5)
                    .height(5)
                    .borderRadius(3)
                    .backgroundColor(Theme.ACCENT)
                }
                Blank()
              }
              .width('100%')
              TextArea({ text: this.memo, placeholder: '给自己记一句（只有你看得到）' })
                .fontSize(12)
                .fontColor(Theme.TEXT)
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
                .height(84)
                .onChange((v: string) => {
                  this.memo = v;
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)

            Text('恢复默认')
              .fontSize(12)
              .fontColor(Theme.DANGER)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .onClick(() => {
                this.confirmReset();
              })

            Text('改动存在你的服务端（旁挂库），换手机、重装都还在；amane 网页端读的是库里的原值，看不到这些修改。换封面在详情页那块。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ bottom: Theme.BOTTOM_SAFE })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 8 }) {
          if (this.st === ST_LOADING) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Theme.ACCENT)
          } else {
            Text('打不开编辑')
              .fontSize(14)
              .fontColor(Theme.TEXT)
            Text(this.note.length > 0 ? this.note : '服务端还不支持自定义修改')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }

      // 新建确认带：固定在底部，不叠、不影响页面退出
      if (this.missing.length > 0) {
        Column({ space: 8 }) {
          Text('库里没有这些名字')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
            .width('100%')
          ForEach(this.missing, (m: string) => {
            Text(m)
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
          }, (m: string) => `miss-${m}`)
          Text('新建后它们会作为自建分类出现在对应列表里（存在服务端，换手机也在）。')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(14)
          Row({ space: 10 }) {
            Text('取消')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(10)
              .onClick(() => {
                this.missing = [];
                this.pendingSave = {};
              })
            Text('新建并保存')
              .fontSize(12)
              .fontColor(Theme.ON_ACCENT)
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .backgroundColor(Theme.ACCENT)
              .borderRadius(10)
              .onClick(() => {
                this.confirmCreate();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .padding(14)
        .backgroundColor(Theme.CARD)
        .borderRadius({ topLeft: 14, topRight: 14 })
        .border({ width: 0.5, color: Theme.accentAlpha(0.35) })
        .margin({ bottom: Theme.BOTTOM_SAFE })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
