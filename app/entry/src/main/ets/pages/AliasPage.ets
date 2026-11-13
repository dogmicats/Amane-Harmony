import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { SuggestItem } from '../common/Types';

/**
 * 高级设置 → 检索别名。
 *
 * 解决的问题：你说的话和你库里的名字对不上。库里叫「女检察官」，你搜「搜查官」；
 * 库里叫「寝取」，你搜「ntr」。这类对应关系程序猜不出来（语义），只能人工维护。
 *
 * 但**人工维护的前提是知道该维护什么** —— 让用户面对一张空表发呆是不现实的。
 * 所以这个页面的主体不是「已有别名」，而是上半屏的**待处理**：
 * 那些你搜过、严格条件下几乎一条都没有的词，由服务端从搜索记录里攒出来，
 * 顺便按字面重合度猜几个库里的名字当候选（猜不准很正常，所以每条都能「自己找」）。
 *
 * 服务端：
 *   GET    /api/user/search/misses            待处理（词 + 候选 + 次数）
 *   DELETE /api/user/search/misses?q=         不想管 / 处理完，从清单里去掉
 *   GET    /api/user/search/aliases           已有别名（films = 目标挂了多少部）
 *   POST   /api/user/search/aliases           新增（目标名不存在会 404 并给纠错建议）
 *   DELETE /api/user/search/aliases?alias=    删自加的（出厂那些删不掉）
 */
interface MissCand {
  kind: string;
  target: string;
  films: number;
}

interface MissRow {
  q: string;
  raw: string;
  hits: number;
  times: number;
  candidates: MissCand[];
}

interface AliasRow {
  alias: string;
  kind: string;
  target: string;
  source: string;
  films: number;
}

/** 「自己找」时从 /suggest 拿到的实体行。 */
interface PickRow {
  kind: string;
  name: string;
}

const KIND_CN: Record<string, string> = {
  'tag': '标签',
  'series': '系列',
  'actor': '演员'
};

@Entry
@Component
struct AliasPage {
  @State misses: MissRow[] = [];
  @State aliases: AliasRow[] = [];
  /** 服务端自动处理掉的「写法差异」条数（折叠别名，不进上面的列表）。 */
  @State variantCount: number = 0;
  @State loading: boolean = true;
  @State note: string = '';
  @State busyKey: string = '';
  /** 正在为哪个词自己找目标（空 = 没在找）。 */
  @State pickFor: string = '';
  @State pickDraft: string = '';
  @State pickRows: PickRow[] = [];
  @State pickLoading: boolean = false;
  /** 正在给哪条别名「再加一个名字」（值为 alias|kind|target，空 = 没展开）。 */
  @State addFor: string = '';
  @State addRows: MissCand[] = [];
  @State addLoading: boolean = false;

  aboutToAppear(): void {
    this.loadAll();
  }

  private async loadAll(): Promise<void> {
    await Promise.all([this.loadMisses(), this.loadAliases()]);
    this.loading = false;
  }

  private async loadMisses(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/search/misses?limit=30`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.misses = safeMisses(obj.items as MissRow[]);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias misses: ${e.code} ${e.message}`);
      this.say('读取待处理清单失败，检查连接');
    }
  }

  private async loadAliases(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/search/aliases`, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      this.aliases = safeAliases(obj.items as AliasRow[]);
      const vc: number = Number(obj.variants);
      this.variantCount = Number.isFinite(vc) ? vc : 0;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias list: ${e.code} ${e.message}`);
    }
  }

  private say(text: string): void {
    this.note = text;
    setTimeout(() => {
      if (this.note === text) {
        this.note = '';
      }
    }, 2600);
  }

  /** 建一条别名：`alias` 是用户打的词，`target` 是库里的真名。 */
  private async addAlias(alias: string, kind: string, target: string,
    missQ: string): Promise<void> {
    if (this.busyKey.length > 0) {
      return;
    }
    this.busyKey = `${alias}|${target}`;
    try {
      const body: string = JSON.stringify({ alias: alias, kind: kind, target: target });
      await httpPost(`${Store.I.user}/api/user/search/aliases`, Store.I.token, body);
      // 处理完就把这个词从待处理里摘掉：清单是「待办」，不是审计日志
      if (missQ.length > 0) {
        await this.dropMiss(missQ, false);
      }
      this.say(`已记住：${alias} → ${target}`);
      await this.loadAll();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias add: ${e.code} ${e.message}`);
      // 目标名写错时服务端会回一句带纠错建议的话，尽量把它显出来
      this.say('没加上：目标名在库里找不到（用「自己找」挑一个）');
    }
    this.busyKey = '';
  }

  private async dropMiss(q: string, reload: boolean): Promise<void> {
    try {
      await httpDelete(
        `${Store.I.user}/api/user/search/misses?q=${encodeURIComponent(q)}`, Store.I.token);
      if (reload) {
        await this.loadMisses();
        this.say('已忽略');
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] miss drop: ${e.code} ${e.message}`);
    }
  }

  private async delAlias(row: AliasRow): Promise<void> {
    if (row.source === 'builtin') {
      this.say('出厂默认改不了（它随程序走）');
      return;
    }
    try {
      const u = `${Store.I.user}/api/user/search/aliases`
        + `?alias=${encodeURIComponent(row.alias)}&target=${encodeURIComponent(row.target)}`;
      await httpDelete(u, Store.I.token);
      this.say('已删除');
      await this.loadAliases();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias del: ${e.code} ${e.message}`);
      this.say('删除失败');
    }
  }

  /** 「自己找」：拿用户输入去库里搜实体名，避免让他记规范名。 */
  private async searchTargets(q: string): Promise<void> {
    const key: string = q.trim();
    if (key.length === 0) {
      this.pickRows = [];
      return;
    }
    this.pickLoading = true;
    try {
      const url: string = `${Store.I.user}/api/user/suggest?q=${encodeURIComponent(key)}`
        + `&types=tag,series,actor&per=8`;
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const list: PickRow[] = [];
      const items: SuggestItem[] = (obj.items as SuggestItem[]);
      for (let i = 0; i < items.length; i++) {
        const it: SuggestItem = items[i];
        const t: string = it.type === undefined || it.type === null ? '' : String(it.type);
        const name: string = it.name === undefined || it.name === null ? '' : String(it.name);
        if (t.length === 0 || t === 'film' || name.length === 0) {
          continue;
        }
        list.push({ kind: t, name: name });
      }
      this.pickRows = list;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias pick: ${e.code} ${e.message}`);
      this.say('搜索失败');
    }
    this.pickLoading = false;
  }

  /**
   * 「再加一个名字」：一个俗称往往对应好几个标签（ntr → 寝取 / NTR / 恶堕…）。
   * 候选来自 `/search/expand?q=<俗称>` 的 missing —— 也就是「这个词现在没覆盖到、
   * 但字面相近」的那些名字，让人确认后追加，全程不猜语义。
   */
  private async openAdd(row: AliasRow): Promise<void> {
    const key: string = `${row.alias}|${row.kind}|${row.target}`;
    if (this.addFor === key) {
      this.addFor = '';
      this.addRows = [];
      return;
    }
    this.addFor = key;
    this.addRows = [];
    this.addLoading = true;
    try {
      const url: string = `${Store.I.user}/api/user/search/expand?q=`
        + `${encodeURIComponent(row.alias)}`;
      const text: string = await httpGet(url, Store.I.token);
      const obj = JSON.parse(text) as Record<string, Object>;
      const list: MissCand[] = [];
      const arr: MissCand[] = obj.missing as MissCand[];
      if (arr !== undefined && arr !== null) {
        for (let i = 0; i < arr.length; i++) {
          const c: MissCand = safeCand(arr[i]);
          if (c.target.length > 0 && c.films > 0) {
            list.push(c);
          }
        }
      }
      this.addRows = list;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] alias add-candidates: ${e.code} ${e.message}`);
    }
    this.addLoading = false;
  }

  @Builder
  Head() {
    Row({ space: 4 }) {
      Text('‹')
        .fontSize(24)
        .fontColor(Theme.TEXT)
        .width(30)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      Text('检索别名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
      Blank()
      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .maxLines(2)
          .width('46%')
          .textAlign(TextAlign.End)
      }
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })
  }

  /** 候选 chip：点一下就直接建成别名。 */
  @Builder
  CandChip(miss: MissRow, c: MissCand) {
    Row({ space: 4 }) {
      Text(c.target)
        .fontSize(11)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${c.films}`)
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
    }
    .constraintSize({ maxWidth: '62%' })
    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(11)
    .onClick(() => {
      this.addAlias(miss.raw.length > 0 ? miss.raw : miss.q, c.kind, c.target, miss.q);
    })
  }

  @Builder
  MissCard(miss: MissRow) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(miss.raw.length > 0 ? miss.raw : miss.q)
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(miss.times > 1 ? `搜过 ${miss.times} 次 · ${miss.hits} 条`
          : `搜过 1 次 · ${miss.hits} 条`)
          .fontSize(10)
          .fontColor(Theme.DANGER)
      }
      .width('100%')

      if (hasCandidates(miss)) {
        Text('猜的（按字面）。不对就点「自己找」，在库里挑一个。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(miss.candidates, (c: MissCand) => {
          Row() {
            this.CandChip(miss, c)
          }
          .margin({ right: 6, bottom: 6 })
        }, (c: MissCand) => `c-${miss.q}-${c.kind}-${c.target}`)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text(this.pickFor === miss.q ? '收起' : '自己找')
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            if (this.pickFor === miss.q) {
              this.pickFor = '';
              return;
            }
            this.pickFor = miss.q;
            this.pickDraft = miss.raw.length > 0 ? miss.raw : miss.q;
            this.pickRows = [];
            this.searchTargets(this.pickDraft);
          })
        Text('忽略')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .onClick(() => {
            this.dropMiss(miss.q, true);
          })
        Blank()
        if (this.busyKey.length > 0) {
          Text('处理中…')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
      .width('100%')

      // 「自己找」：先在库里搜，再点选 —— 语义猜不出来，只能让人来认
      if (this.pickFor === miss.q) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            TextInput({ text: this.pickDraft, placeholder: '在库里搜名字（标签/系列/演员）' })
              .fontSize(12)
              .height(34)
              .layoutWeight(1)
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(8)
              .onChange((v: string) => {
                this.pickDraft = v;
              })
              .onSubmit(() => {
                this.searchTargets(this.pickDraft);
              })
            Text(this.pickLoading ? '…' : '搜')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .backgroundColor(Theme.ACCENT)
              .borderRadius(8)
              .onClick(() => {
                this.searchTargets(this.pickDraft);
              })
          }
          .width('100%')

          if (this.pickRows.length === 0 && !this.pickLoading) {
            Text('没有匹配的名字。换个词试试，或直接输完整的标签名再搜。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
          }

          ForEach(this.pickRows, (p: PickRow) => {
            Row({ space: 8 }) {
              Text(KIND_CN[p.kind] === undefined ? p.kind : KIND_CN[p.kind])
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(5)
              Text(p.name)
                .fontSize(12)
                .fontColor(Theme.TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('用这个')
                .fontSize(10)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.addAlias(miss.raw.length > 0 ? miss.raw : miss.q, p.kind, p.name, miss.q);
            })
          }, (p: PickRow) => `p-${p.kind}-${p.name}`)
        }
        .width('100%')
        .padding(10)
        .backgroundColor(Theme.BG_RAISED)
        .borderRadius(10)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  AliasCard(row: AliasRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(row.alias)
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('→')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Text(row.target)
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`${row.films} 部`)
          .fontSize(10)
          .fontColor(row.films > 0 ? Theme.ACCENT : Theme.DANGER)
        // 一个俗称往往该挂好几个名字（1 对 N），这里是入口
        Text('＋')
          .fontSize(12)
          .fontColor(this.addFor === `${row.alias}|${row.kind}|${row.target}`
            ? Theme.ACCENT : Theme.TEXT_FAINT)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => {
            this.openAdd(row);
          })
        Text(row.source === 'builtin' ? '出厂' : '删除')
          .fontSize(10)
          .fontColor(row.source === 'builtin' ? Theme.TEXT_FAINT : Theme.DANGER)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .onClick(() => {
            this.delAlias(row);
          })
      }
      .width('100%')

      if (this.addFor === `${row.alias}|${row.kind}|${row.target}`) {
        Column({ space: 4 }) {
          Text(this.addLoading ? '找…' : (this.addRows.length > 0
            ? `这个词还没覆盖到、但名字相近的（点一下加进来）：`
            : '没找到别的相近名字。要挂一个特定的名字，到上面「待处理」里用「自己找」。'))
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(14)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.addRows, (c: MissCand) => {
              Row({ space: 4 }) {
                Text(c.target)
                  .fontSize(11)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${c.films}`)
                  .fontSize(9)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .constraintSize({ maxWidth: '62%' })
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(11)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.addAlias(row.alias, c.kind, c.target, '');
              })
            }, (c: MissCand) => `add-${row.alias}-${c.kind}-${c.target}`)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
  }

  build() {
    Column() {
      this.Head()

      Scroll() {
        Column({ space: 12 }) {
          // 说明：为什么会有这一页
          Column({ space: 5 }) {
            Text('同一个东西，你叫它一个名字，库里叫它另一个。')
              .fontSize(12)
              .fontColor(Theme.TEXT)
              .width('100%')
            Text('比如库里叫「女检察官」，你搜「搜查官」；库里叫「寝取」，你搜「ntr」。'
              + '这里记下这类对应关系，之后你按自己的说法搜就能命中。只影响搜索，不改影片本身。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 待处理：这张清单才是重点 —— 别名靠人工维护，得先让人知道该维护什么
          Row({ space: 6 }) {
            Text('待处理')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
            Text(`${this.misses.length}`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
            Blank()
            Text('搜过但几乎没结果')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .padding({ left: 2, top: 4 })

          if (this.loading) {
            Text('读取中…')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding(12)
          } else if (this.misses.length === 0) {
            Text('最近没有搜空的词。等你在搜索页碰上「一条都没有」的情况，它就会出现在这儿。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
              .padding(12)
              .backgroundColor(Theme.CARD)
              .borderRadius(Theme.RADIUS)
          } else {
            ForEach(this.misses, (m: MissRow) => {
              this.MissCard(m)
            }, (m: MissRow) => `m-${m.q}`)
          }

          // 已有别名
          Row({ space: 6 }) {
            Text('已有别名')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
            Text(`${this.aliases.length}`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
            Blank()
            Text('点右边可删（出厂的不行）')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .padding({ left: 2, top: 8 })

          ForEach(this.aliases, (a: AliasRow) => {
            this.AliasCard(a)
          }, (a: AliasRow) => `a-${a.alias}-${a.kind}-${a.target}`)

          Text('「部」是那个名字在库里挂了多少部片。0 部说明名字写错了 —— '
            + '错一个字在搜索里就是一条都搜不到，而且不会报错。')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(14)
            .padding({ top: 2 })

          if (this.variantCount > 0) {
            Text(`另有 ${this.variantCount} 个名字只是「写法不同」（日文新字体 / 繁体），`
              + '系统已经自动认得，不用在这儿维护。比如搜「搜查官」也能出「女捜查官」。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)
              .padding({ top: 4 })
          }
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}

/** 有没有猜出来的候选（模板里不方便写逻辑，抽成函数）。 */
function hasCandidates(miss: MissRow): boolean {
  return miss.candidates.length > 0;
}

/** JSON 里的脏数据兜底：少字段 / 类型不对时给默认值，别让页面炸掉。 */
function safeCand(raw: MissCand): MissCand {
  const films: number = Number(raw.films);
  return {
    kind: raw.kind === undefined || raw.kind === null ? '' : String(raw.kind),
    target: raw.target === undefined || raw.target === null ? '' : String(raw.target),
    films: Number.isFinite(films) ? films : 0
  };
}

function safeMisses(raw: MissRow[]): MissRow[] {
  const list: MissRow[] = [];
  if (raw === undefined || raw === null) {
    return list;
  }
  for (let i = 0; i < raw.length; i++) {
    const it: MissRow = raw[i];
    if (it === undefined || it === null) {
      continue;
    }
    const hits: number = Number(it.hits);
    const times: number = Number(it.times);
    const cands: MissCand[] = [];
    const cr: MissCand[] = it.candidates as MissCand[];
    if (cr !== undefined && cr !== null) {
      for (let j = 0; j < cr.length; j++) {
        const c: MissCand = safeCand(cr[j]);
        if (c.target.length > 0) {
          cands.push(c);
        }
      }
    }
    const q: string = it.q === undefined || it.q === null ? '' : String(it.q);
    if (q.length === 0) {
      continue;
    }
    list.push({
      q: q,
      raw: it.raw === undefined || it.raw === null ? q : String(it.raw),
      hits: Number.isFinite(hits) ? hits : 0,
      times: Number.isFinite(times) ? times : 1,
      candidates: cands
    });
  }
  return list;
}

function safeAliases(raw: AliasRow[]): AliasRow[] {
  const list: AliasRow[] = [];
  if (raw === undefined || raw === null) {
    return list;
  }
  for (let i = 0; i < raw.length; i++) {
    const it: AliasRow = raw[i];
    if (it === undefined || it === null) {
      continue;
    }
    const alias: string = it.alias === undefined || it.alias === null ? '' : String(it.alias);
    const target: string = it.target === undefined || it.target === null ? '' : String(it.target);
    if (alias.length === 0 || target.length === 0) {
      continue;
    }
    const films: number = Number(it.films);
    list.push({
      alias: alias,
      kind: it.kind === undefined || it.kind === null ? 'tag' : String(it.kind),
      target: target,
      source: it.source === undefined || it.source === null ? 'builtin' : String(it.source),
      films: Number.isFinite(films) ? films : 0
    });
  }
  return list;
}
