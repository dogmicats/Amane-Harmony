import { router, promptAction } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPut } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize, HomeRowPref } from '../common/Personalize';
import { BuildConfig } from '../common/BuildConfig';
import { HomeData, HomeRow } from '../common/Types';
import { safeHome } from '../common/Safe';
import { Reason } from '../common/Reason';
import { PoolFilterCard } from '../view/PoolFilterCard';
import { GlassBack, GlassCapsule, PageTitle } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsRowDivider, SettingsSectionTitle, VelvetChip
} from '../view/SettingsKit';

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
  @State rev: number = 0;
  @State reasonOn: boolean = true;
  @State heroPool: string = 'all';
  @State dailyPreset: string = 'balanced';
  @State dailyNote: string = '';
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.reasonOn = Reason.enabled();
    this.loadDaily();
    this.load();
  }

  private loadDaily(): void {
    httpGet(`${Store.I.user}/api/user/daily`, Store.I.token)
      .then((text: string) => {
        const o = JSON.parse(text) as Record<string, Object>;
        const p: string = String(o['preset'] === undefined ? '' : o['preset']);
        if (p.length > 0) {
          this.dailyPreset = p;
        }
      })
      .catch((err: BusinessError) => {
        console.info(`[amane] daily preset: ${err.code}`);
      });
  }

  private setDaily(name: string): void {
    this.dailyPreset = name;
    httpPut(`${Store.I.user}/api/user/daily`, Store.I.token, JSON.stringify({ preset: name }))
      .then(() => {
        this.dailyNote = '已记下，回首页下拉刷新即可生效';
      })
      .catch((err: BusinessError) => {
        this.dailyNote = `保存失败（${err.code}）`;
      });
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
      const saved: HomeRowPref[] = Personalize.loadRows();
      const fallback: RowEntry[] = [];
      for (let i = 0; i < saved.length; i++) {
        fallback.push({ key: saved[i].key, title: this.titleOf(saved[i].key), desc: '', on: saved[i].on });
      }
      this.entries = fallback;
      this.error = '暂未连上服务器，当前显示已保存设置。';
      this.loading = false;
    }
  }

  private baseEntries(home: HomeData): RowEntry[] {
    const out: RowEntry[] = [];
    if (BuildConfig.ENABLE_ACTORS) {
      out.push({ key: 'cast', title: '甄选', desc: '多条件自由组合筛片', on: true });
    }
    out.push({
      key: 'continue',
      title: '继续观看',
      desc: home.continue.length > 0 ? `${home.continue.length} 部未看完` : '暂无未看完',
      on: true
    });
    out.push({
      key: 'banner',
      title: '每日推荐',
      desc: '每天固定一批横幅',
      on: true
    });
    for (let i = 0; i < home.rows.length; i++) {
      const row: HomeRow = home.rows[i];
      out.push({ key: `row:${row.id}`, title: row.title, desc: `${row.count} 部`, on: true });
    }
    return out;
  }

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
      return '甄选';
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
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        PageTitle({ text: '首页内容', fs: 18 })
        Blank()
        GlassCapsule({
          label: '恢复默认',
          fs: 12,
          padH: 12,
          padV: 6,
          radius: 16,
          mat: true,
          onTap: () => {
            this.resetAll();
          }
        })
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  private barH(): number {
    return this.topInset + 46;
  }

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  @Builder
  RowItem(e: RowEntry, index: number) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(e.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(e.on ? Theme.TEXT : Theme.TEXT_FAINT)
        if (e.desc.length > 0) {
          Text(e.desc)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(13)
          .fontColor([index === 0 ? Theme.TEXT_FAINT : Theme.TEXT_DIM])
      }
      .width(30)
      .height(30)
      .backgroundColor(Theme.CARD_HI)
      .border({ width: 0.5, color: '#16FFFFFF' })
      .borderRadius(9)
      .opacity(index === 0 ? 0.35 : 1)
      .onClick(() => {
        this.move(index, -1);
      })

      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(13)
          .fontColor([index === this.entries.length - 1 ? Theme.TEXT_FAINT : Theme.TEXT_DIM])
      }
      .width(30)
      .height(30)
      .backgroundColor(Theme.CARD_HI)
      .border({ width: 0.5, color: '#16FFFFFF' })
      .borderRadius(9)
      .opacity(index === this.entries.length - 1 ? 0.35 : 1)
      .onClick(() => {
        this.move(index, 1);
      })

      Toggle({ type: ToggleType.Switch, isOn: e.on })
        .selectedColor(Theme.ACCENT)
        .onChange((isOn: boolean) => {
          if (isOn !== e.on) {
            this.toggle(index);
          }
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.ACCENT_INK)
            Text('正在读取首页结构…')
              .fontSize(12)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 14 }) {
              Blank().height(this.barH() + 6)

              if (this.error.length > 0) {
                Text(this.error)
                  .fontSize(11)
                  .fontColor(Theme.GOLD)
                  .width('100%')
                  .padding(12)
                  .backgroundColor('#1FFFD06B')
                  .border({ width: 0.5, color: '#40FFD06B' })
                  .borderRadius(12)
              }

              PoolFilterCard({
                specKey: 'hero_pool_spec',
                presetKey: 'hero_pool',
                title: '顶部大图挑片范围',
                hint: '不选条件则从全库随机挑片（与刷一刷独立）',
                onChanged: () => {
                  Store.I.prefSetString('home_pool_rev', `${Date.now()}`);
                }
              })

              // 首页分区排序与开关
              Column({ space: 8 }) {
                SettingsSectionTitle({ title: '分区顺序与显隐' })
                Column() {
                  ForEach(this.entries, (e: RowEntry, index: number) => {
                    Column() {
                      if (index > 0) {
                        SettingsRowDivider({ indent: 14 })
                      }
                      this.RowItem(e, index)
                    }
                    .width('100%')
                  }, (e: RowEntry) => `${e.key}-${this.rev}`)
                }
                .width('100%')
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
                .clip(true)
              }
              .width('100%')

              // 每日推荐设置合并为一张卡
              Column({ space: 8 }) {
                SettingsSectionTitle({ title: '每日推荐' })
                Column() {
                  Row({ space: 10 }) {
                    Column({ space: 2 }) {
                      Text('展示推荐理由')
                        .fontSize(14.5)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.TEXT)
                      Text('在每日推荐与详情页显示推荐短句')
                        .fontSize(11)
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

                  SettingsRowDivider({ indent: 14 })

                  Column({ space: 10 }) {
                    Column({ space: 2 }) {
                      Text('推荐取向')
                        .fontSize(14.5)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.TEXT)
                      Text('调节每日推荐偏熟悉还是偏新鲜')
                        .fontSize(11)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width('100%')

                    Row({ space: 8 }) {
                      VelvetChip({
                        label: '更懂我',
                        active: this.dailyPreset === 'taste',
                        onTap: () => {
                          this.setDaily('taste');
                        }
                      })
                      VelvetChip({
                        label: '均衡',
                        active: this.dailyPreset === 'balanced',
                        onTap: () => {
                          this.setDaily('balanced');
                        }
                      })
                      VelvetChip({
                        label: '多惊喜',
                        active: this.dailyPreset === 'explore',
                        onTap: () => {
                          this.setDaily('explore');
                        }
                      })
                    }
                    .width('100%')

                    if (this.dailyNote.length > 0) {
                      Text(this.dailyNote)
                        .fontSize(10.5)
                        .fontColor(Theme.ACCENT_INK)
                        .width('100%')
                    }
                  }
                  .width('100%')
                  .padding(14)
                }
                .width('100%')
                .backgroundColor(Theme.CARD)
                .borderRadius(18)
                .border({ width: 0.75, color: Theme.STROKE })
                .clip(true)
              }
              .width('100%')

              Text('顶部大图固定置顶，调整后返回首页即刻生效。')
                .fontSize(10.5)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .padding({ left: 4 })
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
