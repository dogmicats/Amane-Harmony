/**
 * 「候选范围」编辑卡（2.8.2 视觉统一版）：
 *  - 顶部大图（hero_pool_spec）与刷一刷（shorts_pool_spec）共用同一筛选实现；
 *  - 统一升级为黑曜石大圆角卡 + 丝绒半透选态胶囊 + 暗色凹陷输入框 + 宝石渐变主按钮。
 */
import { promptAction } from '@kit.ArkUI';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

interface PoolOpt {
  key: string;
  label: string;
}

interface LibChip {
  id: number;
  name: string;
}

interface LibsResp {
  items: LibChip[];
}

@Component
export struct PoolFilterCard {
  specKey: string = 'hero_pool_spec';
  presetKey: string = 'hero_pool';
  title: string = '挑片范围';
  hint: string = '不选条件则从全库随机挑片';
  onChanged: () => void = () => {};

  @State libs: LibChip[] = [];
  @State selLibs: number[] = [];
  @State poolState: string = 'any';
  @State poolYear: string = '';
  @State poolTags: string = '';
  @State poolActor: string = '';

  aboutToAppear(): void {
    this.loadSpec();
    this.loadLibs();
  }

  private loadSpec(): void {
    const raw: string = Store.I.prefString(this.specKey, '');
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
      this.poolYear = String(o['year_from'] === undefined ? '' : o['year_from']);
      const tags = o['tags'];
      this.poolTags = tags === undefined || tags === null ? '' : (tags as string[]).join(',');
      this.poolActor = String(o['actor'] === undefined ? '' : o['actor']);
    } catch (e) {
      console.info(`[amane] ${this.specKey} 解析失败`);
    }
  }

  private async loadLibs(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/libraries`, Store.I.token);
      const res: LibsResp = JSON.parse(text) as LibsResp;
      const items: LibChip[] = res.items === undefined || res.items === null ? [] : res.items;
      const out: LibChip[] = [];
      for (let i = 0; i < items.length; i++) {
        out.push({ id: items[i].id, name: items[i].name });
      }
      this.libs = out;
    } catch (e) {
      console.info(`[amane] ${this.specKey} 读媒体库失败`);
    }
  }

  private stateOptions(): PoolOpt[] {
    return [
      { key: 'any', label: '不限' },
      { key: 'unwatched', label: '未观看' },
      { key: 'watched', label: '看过' },
      { key: 'fav', label: '已收藏' },
      { key: 'rated', label: '4 分以上' }
    ];
  }

  private yearOptions(): PoolOpt[] {
    return [
      { key: '', label: '不限' },
      { key: '2015', label: '2015+' },
      { key: '2020', label: '2020+' },
      { key: '2023', label: '2023+' }
    ];
  }

  private activeSummary(): string {
    let n: number = 0;
    if (this.selLibs.length > 0) {
      n++;
    }
    if (this.poolState !== 'any') {
      n++;
    }
    if (this.poolYear.length > 0) {
      n++;
    }
    if (this.poolTags.trim().length > 0) {
      n++;
    }
    if (this.poolActor.trim().length > 0) {
      n++;
    }
    return n === 0 ? '全库' : `${n} 项条件`;
  }

  private apply(): void {
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
    Store.I.prefSetString(this.specKey, JSON.stringify(spec));
    Store.I.prefSetString(this.presetKey, Object.keys(spec).length === 0 ? 'all' : 'custom');
    this.onChanged();
    promptAction.showToast({
      message: Object.keys(spec).length === 0 ? '已清空：回到全库' : '条件已应用，返回后生效',
      duration: 1600
    });
  }

  private clear(): void {
    this.selLibs = [];
    this.poolState = 'any';
    this.poolYear = '';
    this.poolTags = '';
    this.poolActor = '';
    Store.I.prefSetString(this.specKey, '');
    Store.I.prefSetString(this.presetKey, 'all');
    this.onChanged();
    promptAction.showToast({ message: '已恢复全库', duration: 1200 });
  }

  @Builder
  OptionChip(label: string, on: boolean, onTap: () => void) {
    Text(label)
      .fontSize(11.5)
      .fontWeight(on ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(on ? Theme.ACCENT_INK : Theme.TEXT_DIM)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(on ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
      .borderRadius(Theme.R_PILL)
      .border({ width: on ? 0.75 : 0.5, color: on ? Theme.inkAlpha(0.50) : '#16FFFFFF' })
      .margin({ right: 7, bottom: 7 })
      .onClick(() => {
        onTap();
      })
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.activeSummary())
          .fontSize(10.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.activeSummary() === '全库' ? Theme.TEXT_DIM : Theme.ACCENT_INK)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.activeSummary() === '全库' ? Theme.CARD_HI : Theme.accentAlpha(0.18))
          .border({
            width: 0.5,
            color: this.activeSummary() === '全库' ? '#1AFFFFFF' : Theme.inkAlpha(0.42)
          })
          .borderRadius(Theme.R_PILL)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.libs.length > 0) {
        Column({ space: 6 }) {
          Text('媒体库')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.libs, (lib: LibChip) => {
              this.OptionChip(lib.name, this.selLibs.indexOf(lib.id) >= 0, () => {
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

      Column({ space: 6 }) {
        Text('状态')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.stateOptions(), (opt: PoolOpt) => {
            this.OptionChip(opt.label, this.poolState === opt.key, () => {
              this.poolState = opt.key;
            })
          }, (opt: PoolOpt) => `st-${opt.key}-${this.poolState}`)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 6 }) {
        Text('发行年份')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.yearOptions(), (opt: PoolOpt) => {
            this.OptionChip(opt.label, this.poolYear === opt.key, () => {
              this.poolYear = opt.key;
            })
          }, (opt: PoolOpt) => `yr-${opt.key}-${this.poolYear}`)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 8 }) {
        Column({ space: 5 }) {
          Text('标签')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          TextInput({ text: this.poolTags, placeholder: '逗号分隔' })
            .height(38)
            .fontSize(12.5)
            .fontColor(Theme.TEXT)
            .placeholderColor(Theme.TEXT_FAINT)
            .caretColor(Theme.ACCENT_INK)
            .backgroundColor('#141114')
            .border({ width: 0.75, color: '#1EFFFFFF' })
            .borderRadius(10)
            .onChange((v: string) => {
              this.poolTags = v;
            })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 5 }) {
          Text('演员')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
          TextInput({ text: this.poolActor, placeholder: '名字片段' })
            .height(38)
            .fontSize(12.5)
            .fontColor(Theme.TEXT)
            .placeholderColor(Theme.TEXT_FAINT)
            .caretColor(Theme.ACCENT_INK)
            .backgroundColor('#141114')
            .border({ width: 0.75, color: '#1EFFFFFF' })
            .borderRadius(10)
            .onChange((v: string) => {
              this.poolActor = v;
            })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Text(this.hint)
        .fontSize(10.5)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')

      Row({ space: 10 }) {
        Button('清空')
          .height(38)
          .padding({ left: 18, right: 18 })
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
          .backgroundColor('#18FFFFFF')
          .border({ width: 0.75, color: '#24FFFFFF' })
          .borderRadius(Theme.R_PILL)
          .onClick(() => {
            this.clear();
          })
        Button('应用条件')
          .height(38)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ON_ACCENT)
          .backgroundColor(Color.Transparent)
          .linearGradient(Theme.ctaGradient())
          .border({ width: 0.75, color: '#38FFFFFF' })
          .borderRadius(Theme.R_PILL)
          .layoutWeight(1)
          .onClick(() => {
            this.apply();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }
}
