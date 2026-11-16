/**
 * 「候选范围」编辑卡（2026-11-15 抽出）。
 *
 * 为什么要抽：顶部大图（`hero_pool_spec`）和刷一刷（`shorts_pool_spec`）要用**同一套**
 * 筛选实现（媒体库多选 / 观看状态 / 年份 / 标签 / 演员 → 条件串），但**用法不复用**
 * —— 两处各自存自己的条件，改一处不影响另一处。
 *
 * 所以这里只负责「编辑 + 落偏好」，用哪套偏好由 `specKey` / `presetKey` 决定；
 * 落盘后调 `onChanged()` 让调用方决定怎么让生效的缓存失效（首页是 pool 缓存、
 * 刷一刷是片段预取缓存）。
 */
import { promptAction } from '@kit.ArkUI';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/** 一个可选项（状态 / 年份）。 */
interface PoolOpt {
  key: string;
  label: string;
}

/** 媒体库 chip。 */
interface LibChip {
  id: number;
  name: string;
}

/** `/api/user/libraries` 的响应。 */
interface LibsResp {
  items: LibChip[];
}

@Component
export struct PoolFilterCard {
  /** 条件 JSON 存哪个偏好键（`hero_pool_spec` / `shorts_pool_spec`）。 */
  specKey: string = 'hero_pool_spec';
  /** 预设池存哪个偏好键（`hero_pool` / `shorts_pool`）。 */
  presetKey: string = 'hero_pool';
  title: string = '从哪儿挑';
  hint: string = '按下面的条件组合出候选范围；都不选 = 全库。';

  /** 条件应用/清空后通知调用方（作废它自己的缓存）。 */
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

  /** 读回已保存的条件。 */
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

  /** 存条件；自己这套偏好写自己的键，和另一处互不影响。 */
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
    // 空条件落回 `all`，不落 `custom`：`custom` 只是客户端标记，服务端预设表里没有它
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
      .fontSize(12)
      .fontColor(on ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(on ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(Theme.R_PILL)
      .border({ width: 1, color: on ? Theme.accentAlpha(0.55) : Theme.STROKE })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        onTap();
      })
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(15)
          .fontColor(Theme.TEXT)
        Text(this.hint)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(15)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.libs.length > 0) {
        Column({ space: 6 }) {
          Text('媒体库（可多选）')
            .fontSize(11)
            .fontColor(Theme.TEXT_DIM)
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
        Text('观看状态')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
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
          .fontColor(Theme.TEXT_DIM)
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
            this.apply();
          })
        Button('清空')
          .height(38)
          .fontSize(14)
          .fontColor(Theme.TEXT_DIM)
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(Theme.R_PILL)
          .onClick(() => {
            this.clear();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.R_CARD)
    .border({ width: 1, color: Theme.STROKE })
  }
}
