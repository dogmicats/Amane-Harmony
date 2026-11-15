import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize, HomeRowPref } from '../common/Personalize';
import { BuildConfig } from '../common/BuildConfig';
import { HomeData, HomeRow } from '../common/Types';
import { safeHome } from '../common/Safe';
import { Reason } from '../common/Reason';
import { resetShortsCache } from '../view/ShortsView';

/**
 * 首页内容（2.5.2）：哪几行显示、从上到下怎么排。
 *
 * 只列「横排 / 卡片」，顶部大图（Hero）固定在第一屏，不参与排序 ——
 * 它决定进 App 的第一眼观感，关掉会得到一个空荡荡的首页。
 *
 * 存的是键名（`cast` / `continue` / `banner` / `row:<库 id>`），
 * 媒体库改名或换顺序都不影响已存的偏好；新出现的库追加在末尾并默认打开。
 */
interface RowEntry {
  key: string;
  title: string;
  desc: string;
  on: boolean;
}

/** 顶部大图的候选池选项。 */
interface PoolOpt {
  key: string;
  label: string;
}

/** 媒体库 chip。 */
interface LibChip {
  id: number;
  name: string;
}

@Entry
@Component
struct SettingsHomePage {
  @State entries: RowEntry[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  /** 每次改动 +1，让它当 ForEach 的 key 一部分：顺序一变就整段重建，不会串行。 */
  @State rev: number = 0;
  @State reasonOn: boolean = true;
  /** 顶部大图候选池（自由条件，2026-11-14）：媒体库 + 状态 + 年份 + 标签 + 演员。 */
  @State heroPool: string = 'all';
  @State libs: LibChip[] = [];
  @State selLibs: number[] = [];
  @State poolState: string = 'any';
  @State poolYear: string = '';
  @State poolTags: string = '';
  @State poolActor: string = '';
  /** 刷一刷（负一屏）是否也按这套范围（偏好 `shorts_pool_follow_hero`，默认开）。 */
  @State shortsFollow: boolean = true;

  aboutToAppear(): void {
    this.reasonOn = Reason.enabled();
    this.heroPool = Store.I.prefString('hero_pool', 'all');
    this.shortsFollow = Store.I.prefString('shorts_pool_follow_hero', '1') !== '0';
    this.loadPoolSpec();
    this.loadLibs();
    this.load();
  }

  /** 读回已保存的条件（偏好 `hero_pool_spec`，JSON）。 */
  private loadPoolSpec(): void {
    const raw: string = Store.I.prefString('hero_pool_spec', '');
    if (raw.length === 0) {
      return;
    }
    try {
      const o = JSON.parse(raw) as Record<string, Object>;
      const libs = o['libs'];
      if (libs !== undefined && libs !== null) {
        this.selLibs = (libs as number[]).slice();
      }
      this.poolState = String(o['state'] === undefined ? 'any' : o['state']);
      const yf: string = String(o['year_from'] === undefined ? '' : o['year_from']);
      this.poolYear = yf;
      const tags = o['tags'];
      this.poolTags = tags === undefined || tags === null ? '' : (tags as string[]).join(',');
      this.poolActor = String(o['actor'] === undefined ? '' : o['actor']);
    } catch (e) {
      console.info('[amane] hero_pool_spec 解析失败');
    }
  }

  private async loadLibs(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/libraries`, Store.I.token);
      const o = JSON.parse(text) as Record<string, Object>;
      const arr = (o['items'] === undefined ? [] : o['items']) as Record<string, Object>[];
      const out: LibChip[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push({
          id: Number(arr[i]['id']) || 0,
          name: String(arr[i]['name'] === undefined ? '' : arr[i]['name'])
        });
      }
      this.libs = out;
    } catch (e) {
      console.info('[amane] load libs failed');
    }
  }

  private stateOptions(): PoolOpt[] {
    return [
      { key: 'any', label: '不限' },
      { key: 'unwatched', label: '未观看' },
      { key: 'watched', label: '看过' },
      { key: 'fav', label: '已收藏' },
      { key: 'rated', label: '我打 4 分以上' }
    ];
  }

  private yearOptions(): PoolOpt[] {
    return [
      { key: '', label: '不限' },
      { key: '2015', label: '2015 以后' },
      { key: '2020', label: '2020 以后' },
      { key: '2023', label: '2023 以后' }
    ];
  }

  /** 存条件；首页下一次请求就带上（服务端池子进缓存 key，立刻生效）。 */
  private applyPoolSpec(): void {
    const spec: Record<string, Object> = {};
    if (this.selLibs.length > 0) {
      spec['libs'] = this.selLibs.slice();
    }
    if (this.poolState !== 'any') {
      spec['state'] = this.poolState;
    }
    if (this.poolYear.length > 0) {
      spec['year_from'] = Number(this.poolYear) || 0;
    }
    const tags: string[] = this.poolTags.split(/[,，]/).map((s: string) => s.trim())
      .filter((s: string) => s.length > 0);
    if (tags.length > 0) {
      spec['tags'] = tags;
    }
    if (this.poolActor.trim().length > 0) {
      spec['actor'] = this.poolActor.trim();
    }
    Store.I.prefSetString('hero_pool_spec', JSON.stringify(spec));
    // 空条件要落回 `all`，不能落 `custom`：PoolParams 会把 `custom` 当预设发给服务端，
    // 而预设表里没有它（服务端只能当「未知」退回全库）—— 语义上对，但请求里挂个假值很容易误导排查。
    Store.I.prefSetString('hero_pool', Object.keys(spec).length === 0 ? 'all' : 'custom');
    // 范围变了：负一屏的预取缓存要作废，否则还拿着旧范围的片段在刷
    resetShortsCache();
    promptAction.showToast({
      message: Object.keys(spec).length === 0 ? '已清空：回到全库' : '条件已应用，回首页下拉刷新 / 再进负一屏生效',
      duration: 1600
    });
  }

  private clearPoolSpec(): void {
    this.selLibs = [];
    this.poolState = 'any';
    this.poolYear = '';
    this.poolTags = '';
    this.poolActor = '';
    Store.I.prefSetString('hero_pool_spec', '');
    Store.I.prefSetString('hero_pool', 'all');
    resetShortsCache();
    promptAction.showToast({ message: '已恢复全库', duration: 1200 });
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/home`, Store.I.token);
      const home: HomeData = safeHome(JSON.parse(raw) as HomeData);
      this.entries = this.compose(this.baseEntries(home));
      this.loading = false;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] home rows: ${err.code} ${err.message}`);
      // 拿不到首页也让人能看见已有偏好，别显示空白页
      const saved: HomeRowPref[] = Personalize.loadRows();
      const fallback: RowEntry[] = [];
      for (let i = 0; i < saved.length; i++) {
        fallback.push({ key: saved[i].key, title: this.titleOf(saved[i].key), desc: '', on: saved[i].on });
      }
      this.entries = fallback;
      this.error = '读不到首页数据（用已保存的设置）。连上服务器再进来可看到最新列表。';
      this.loading = false;
    }
  }

  /** 服务端这次真给了哪些行（顺序即服务端默认顺序）。 */
  private baseEntries(home: HomeData): RowEntry[] {
    const out: RowEntry[] = [];
    if (BuildConfig.ENABLE_ACTORS) {
      out.push({ key: 'cast', title: '共演筛选', desc: '特色入口：挑人找同台作品', on: true });
    }
    out.push({
      key: 'continue',
      title: '继续观看',
      desc: home.continue.length > 0 ? `${home.continue.length} 部看到一半` : '暂时没有未看完的',
      on: true
    });
    out.push({
      key: 'banner',
      title: '每日推荐',
      desc: '每天换一批的高清横幅',
      on: true
    });
    for (let i = 0; i < home.rows.length; i++) {
      const row: HomeRow = home.rows[i];
      out.push({ key: `row:${row.id}`, title: row.title, desc: `${row.count} 部`, on: true });
    }
    return out;
  }

  /** 按已存偏好重排 + 套用开关；偏好里没有的新键追加在末尾、默认打开。 */
  private compose(base: RowEntry[]): RowEntry[] {
    const saved: HomeRowPref[] = Personalize.loadRows();
    const known: Map<string, boolean> = new Map<string, boolean>();
    const out: RowEntry[] = [];
    for (let i = 0; i < saved.length; i++) {
      known.set(saved[i].key, saved[i].on);
    }
    for (let i = 0; i < saved.length; i++) {
      const idx: number = this.indexOf(base, saved[i].key);
      if (idx < 0) {
        continue;
      }
      const b: RowEntry = base[idx];
      out.push({ key: b.key, title: b.title, desc: b.desc, on: saved[i].on });
    }
    for (let i = 0; i < base.length; i++) {
      if (!known.has(base[i].key)) {
        out.push(base[i]);
      }
    }
    return out;
  }

  private indexOf(list: RowEntry[], key: string): number {
    for (let i = 0; i < list.length; i++) {
      if (list[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  private titleOf(key: string): string {
    if (key === 'cast') {
      return '共演筛选';
    }
    if (key === 'continue') {
      return '继续观看';
    }
    if (key === 'banner') {
      return '每日推荐';
    }
    if (key.startsWith('row:')) {
      return `媒体库 ${key.substring(4)}`;
    }
    return key;
  }

  private persist(): void {
    const rows: HomeRowPref[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      rows.push({ key: this.entries[i].key, on: this.entries[i].on });
    }
    Personalize.saveRows(rows);
  }

  private toggle(index: number): void {
    const next: RowEntry[] = this.entries.slice();
    const e: RowEntry = next[index];
    next[index] = { key: e.key, title: e.title, desc: e.desc, on: !e.on };
    this.entries = next;
    this.rev++;
    this.persist();
  }

  private move(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.entries.length) {
      return;
    }
    const next: RowEntry[] = this.entries.slice();
    const tmp: RowEntry = next[index];
    next[index] = next[target];
    next[target] = tmp;
    this.entries = next;
    this.rev++;
    this.persist();
  }

  private resetAll(): void {
    Personalize.saveRows([]);
    this.rev++;
    this.load();
    promptAction.showToast({ message: '已恢复默认顺序', duration: 1500 });
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
        Text('首页内容')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('哪几行显示、从上到下怎么排；顶部大图取自哪里、刷一刷是否共用筛选范围')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text('恢复默认')
        .fontSize(11)
        .fontColor(Theme.TEXT_DIM)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.CARD)
        .borderRadius(10)
        .onClick(() => {
          this.resetAll();
        })
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })
  }

  @Builder
  RowItem(e: RowEntry, index: number) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(e.title)
          .fontSize(15)
          .fontColor(e.on ? Theme.TEXT : Theme.TEXT_FAINT)
        if (e.desc.length > 0) {
          Text(e.desc)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('↑')
        .fontSize(15)
        .fontColor(index === 0 ? Theme.TEXT_FAINT : Theme.TEXT_DIM)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(9)
        .opacity(index === 0 ? 0.35 : 1)
        .onClick(() => {
          this.move(index, -1);
        })

      Text('↓')
        .fontSize(15)
        .fontColor(index === this.entries.length - 1 ? Theme.TEXT_FAINT : Theme.TEXT_DIM)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(9)
        .opacity(index === this.entries.length - 1 ? 0.35 : 1)
        .onClick(() => {
          this.move(index, 1);
        })

      Toggle({ type: ToggleType.Switch, isOn: e.on })
        .selectedColor(Theme.ACCENT)
        .onChange((isOn: boolean) => {
          // 只在用户真改了才写回：程序化刷新也会触发 onChange
          if (isOn !== e.on) {
            this.toggle(index);
          }
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
  }

  build() {
    Column() {
      this.Header()

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(26)
            .height(26)
            .color(Theme.ACCENT)
          Text('正在读首页结构…')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            if (this.error.length > 0) {
              Text(this.error)
                .fontSize(11)
                .fontColor(Theme.GOLD)
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.CARD)
                .borderRadius(12)
            }

            // 大图候选池（2026-11-14 · 用户要「自由选择」）：
            // 不再是固定几个预设，而是**媒体库多选 + 状态 + 年份 + 标签 + 演员**自由组合。
            Column({ space: 12 }) {
              Column({ space: 3 }) {
                Text('顶部大图 / 刷一刷从哪儿挑')
                  .fontSize(15)
                  .fontColor(Theme.TEXT)
                Text('按下面的条件组合出候选范围；都不选 = 全库。下拉刷新与负一屏都在这个范围内换')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .lineHeight(15)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')

              // 媒体库（多选）
              if (this.libs.length > 0) {
                Column({ space: 6 }) {
                  Text('媒体库（可多选）')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_DIM)
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.libs, (lib: LibChip) => {
                      Text(lib.name)
                        .fontSize(12)
                        .fontColor(this.selLibs.indexOf(lib.id) >= 0 ? '#FFFFFF' : Theme.TEXT_DIM)
                        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                        .backgroundColor(this.selLibs.indexOf(lib.id) >= 0 ? Theme.ACCENT : Theme.CARD_HI)
                        .borderRadius(Theme.R_PILL)
                        .border({
                          width: 1,
                          color: this.selLibs.indexOf(lib.id) >= 0
                            ? Theme.accentAlpha(0.55) : Theme.STROKE
                        })
                        .margin({ right: 8, bottom: 8 })
                        .onClick(() => {
                          const i: number = this.selLibs.indexOf(lib.id);
                          const next: number[] = this.selLibs.slice();
                          if (i >= 0) {
                            next.splice(i, 1);
                          } else {
                            next.push(lib.id);
                          }
                          this.selLibs = next;
                        })
                    }, (lib: LibChip) => `lib-${lib.id}-${this.selLibs.indexOf(lib.id)}`)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
              }

              // 状态
              Column({ space: 6 }) {
                Text('观看状态')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.stateOptions(), (opt: PoolOpt) => {
                    Text(opt.label)
                      .fontSize(12)
                      .fontColor(this.poolState === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                      .backgroundColor(this.poolState === opt.key ? Theme.ACCENT : Theme.CARD_HI)
                      .borderRadius(Theme.R_PILL)
                      .border({
                        width: 1,
                        color: this.poolState === opt.key ? Theme.accentAlpha(0.55) : Theme.STROKE
                      })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.poolState = opt.key;
                      })
                  }, (opt: PoolOpt) => `st-${opt.key}-${this.poolState}`)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')

              // 年份
              Column({ space: 6 }) {
                Text('发行年份')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.yearOptions(), (opt: PoolOpt) => {
                    Text(opt.label)
                      .fontSize(12)
                      .fontColor(this.poolYear === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                      .backgroundColor(this.poolYear === opt.key ? Theme.ACCENT : Theme.CARD_HI)
                      .borderRadius(Theme.R_PILL)
                      .border({
                        width: 1,
                        color: this.poolYear === opt.key ? Theme.accentAlpha(0.55) : Theme.STROKE
                      })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.poolYear = opt.key;
                      })
                  }, (opt: PoolOpt) => `yr-${opt.key}-${this.poolYear}`)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')

              // 标签 / 演员
              Column({ space: 6 }) {
                Text('标签（逗号分隔，命中任一）')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                TextInput({ text: this.poolTags, placeholder: '例如：中字,单体' })
                  .height(38)
                  .fontSize(13)
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(Theme.R_IMG)
                  .onChange((v: string) => {
                    this.poolTags = v;
                  })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')

              Column({ space: 6 }) {
                Text('演员（名字片段即可）')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                TextInput({ text: this.poolActor, placeholder: '例如：三上' })
                  .height(38)
                  .fontSize(13)
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(Theme.R_IMG)
                  .onChange((v: string) => {
                    this.poolActor = v;
                  })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')

              Row({ space: 10 }) {
                Button('应用条件')
                  .height(38)
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(Theme.R_PILL)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.applyPoolSpec();
                  })
                Button('清空')
                  .height(38)
                  .fontSize(14)
                  .fontColor(Theme.TEXT_DIM)
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(Theme.R_PILL)
                  .onClick(() => {
                    this.clearPoolSpec();
                  })
              }
              .width('100%')

              // 刷一刷（负一屏）是否复用这套范围（2026-11-14 用户：可以的话直接复用）
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text('刷一刷也用这个范围')
                    .fontSize(13)
                    .fontColor(Theme.TEXT)
                  Text('开：负一屏只刷上面条件里的片；关：负一屏从全库随便刷')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                    .lineHeight(15)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.shortsFollow })
                  .selectedColor(Theme.ACCENT)
                  .onChange((on: boolean) => {
                    this.shortsFollow = on;
                    Store.I.prefSetString('shorts_pool_follow_hero', on ? '1' : '0');
                    // 立即作废预取缓存：下次进负一屏就按新范围取
                    resetShortsCache();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.R_CARD)
            .border({ width: 1, color: Theme.STROKE })

            Column({ space: 1 }) {
              ForEach(this.entries, (e: RowEntry, index: number) => {
                this.RowItem(e, index)
              }, (e: RowEntry) => `${e.key}-${this.rev}`)
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
            .clip(true)

            Column({ space: 8 }) {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text('每日推荐理由')
                    .fontSize(15)
                    .fontColor(Theme.TEXT)
                  Text('行头显示今日一句话；点「推荐理由」看整批，今天上榜的片子详情页里也能看到')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.reasonOn })
                  .selectedColor(Theme.ACCENT)
                  .onChange((isOn: boolean) => {
                    this.reasonOn = isOn;
                    Reason.setEnabled(isOn);
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(14)

            Text('顶部大图固定在第一屏，不在这里；关掉的行首页就不显示，顺序即从上到下。改完直接回首页看，不用重启。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
