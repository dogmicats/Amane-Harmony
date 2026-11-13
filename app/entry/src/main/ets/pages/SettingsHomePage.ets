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

@Entry
@Component
struct SettingsHomePage {
  @State entries: RowEntry[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  /** 每次改动 +1，让它当 ForEach 的 key 一部分：顺序一变就整段重建，不会串行。 */
  @State rev: number = 0;
  @State reasonOn: boolean = true;

  aboutToAppear(): void {
    this.reasonOn = Reason.enabled();
    this.load();
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
        Text('显示哪几行、从上到下怎么排')
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
