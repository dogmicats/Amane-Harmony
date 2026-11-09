import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  PlayerPrefs, PlayerTuning, PresetOption, PRESETS, confText, presetTuning
} from '../common/PlayerPrefs';

/**
 * 播放器设置（独立页面，不放在「连接设置」里）。
 *
 * 面向用户的结构化界面：预设 + 开关 + 离散档位，最终由 PlayerPrefs 生成
 * mpv.conf。发布版也带这一页；原始配置文件只作为「高级」里的只读预览。
 *
 * 两个刻意的实现决定：
 * 1. 所有可调项都是**基本类型 @State**，不塞进对象里改属性——ArkUI 对普通
 *    对象字面量的深层属性变化不保证重渲染。
 * 2. 数值项用**离散档位 chip**，不用 Slider：设置页本身要上下滚动，手指划过
 *    Slider 会把值拽走（实测滑一下就变成「自定义」），chip 没有这个副作用。
 */
@Entry
@Component
struct PlayerSettingsPage {
  @State hwdec: boolean = true;
  @State preset: string = 'balanced';
  @State pauseWait: number = 0.2;
  @State readahead: number = 20;
  @State maxMiB: number = 64;
  @State backMiB: number = 32;
  @State hrSeek: boolean = false;
  @State extra: string = '';
  @State advanced: boolean = false;
  @State note: string = '';
  @State confPreview: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.fill(PlayerPrefs.load(ctx));
  }

  private fill(t: PlayerTuning): void {
    this.hwdec = t.hwdec;
    this.preset = t.preset;
    this.pauseWait = t.pauseWait;
    this.readahead = t.readahead;
    this.maxMiB = t.maxMiB;
    this.backMiB = t.backMiB;
    this.hrSeek = t.hrSeek;
    this.extra = t.extra;
    this.refreshPreview();
  }

  private current(): PlayerTuning {
    const t: PlayerTuning = {
      hwdec: this.hwdec,
      preset: this.preset,
      pauseWait: this.pauseWait,
      readahead: this.readahead,
      maxMiB: this.maxMiB,
      backMiB: this.backMiB,
      hrSeek: this.hrSeek,
      extra: this.extra
    };
    return t;
  }

  private refreshPreview(): void {
    this.confPreview = confText(this.current());
  }

  /** 档位值（chip 文案 + 数值），按 kind 取。 */
  private optionsOf(kind: string): number[] {
    if (kind === 'pauseWait') {
      return [0.1, 0.2, 0.5, 1, 2];
    }
    if (kind === 'readahead') {
      return [10, 20, 30, 45, 60];
    }
    if (kind === 'maxMiB') {
      return [48, 64, 128, 192, 256];
    }
    return [16, 32, 64, 128];
  }

  private pickValue(kind: string): number {
    if (kind === 'pauseWait') {
      return this.pauseWait;
    }
    if (kind === 'readahead') {
      return this.readahead;
    }
    if (kind === 'maxMiB') {
      return this.maxMiB;
    }
    return this.backMiB;
  }

  private unitOf(kind: string): string {
    if (kind === 'pauseWait' || kind === 'readahead') {
      return ' s';
    }
    return ' MiB';
  }

  private labelOf(kind: string, v: number): string {
    if (kind === 'pauseWait') {
      return `${v.toFixed(1)} s`;
    }
    return `${v}${this.unitOf(kind)}`;
  }

  private setValue(kind: string, v: number): void {
    if (kind === 'pauseWait') {
      // 预设里 0.1/0.2 这种一位小数，浮点相加会出 0.30000000000000004
      this.pauseWait = Math.round(v * 100) / 100;
    } else if (kind === 'readahead') {
      this.readahead = v;
    } else if (kind === 'maxMiB') {
      this.maxMiB = v;
    } else {
      this.backMiB = v;
    }
    this.markPreset();
  }

  /**
   * 单项改动后重新判定预设：数值正好等于某个预设就继续显示它，
   * 否则显示「自定义」。
   */
  private markPreset(): void {
    const keys: string[] = ['smooth', 'balanced', 'stable'];
    let matched: string = 'custom';
    for (let i = 0; i < keys.length; i++) {
      const p: PlayerTuning = presetTuning(keys[i], this.current());
      if (p.pauseWait === this.pauseWait && p.readahead === this.readahead
        && p.maxMiB === this.maxMiB && p.backMiB === this.backMiB && p.hrSeek === this.hrSeek) {
        matched = keys[i];
        break;
      }
    }
    this.preset = matched;
    this.refreshPreview();
  }

  private pickPreset(key: string): void {
    const t: PlayerTuning = presetTuning(key, this.current());
    t.preset = key;
    this.fill(t);
  }

  private presetLabel(): string {
    for (let i = 0; i < PRESETS.length; i++) {
      if (PRESETS[i].key === this.preset) {
        return PRESETS[i].label;
      }
    }
    return '自定义';
  }

  private save(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    PlayerPrefs.save(ctx, this.current());
    this.note = '已保存，下次进入播放页生效';
    setTimeout(() => {
      this.note = '';
    }, 2400);
  }

  private resetDefault(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const t: PlayerTuning = presetTuning('balanced', PlayerPrefs.load(ctx));
    t.preset = 'balanced';
    t.extra = '';
    this.fill(t);
    this.note = '已恢复推荐值，记得点保存';
    setTimeout(() => {
      this.note = '';
    }, 2400);
  }

  @Builder
  SectionTitle(text: string, desc: string) {
    Column({ space: 2 }) {
      Text(text)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')
      if (desc.length > 0) {
        Text(desc)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(15)
      }
    }
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder
  SwitchRow(title: string, desc: string, on: boolean, onChange: (v: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT)
        Text(desc)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(14)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(Theme.ACCENT)
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /**
   * 档位行：读 this.pickValue(kind)，不靠参数传值。
   * @Builder 按值传参不会随状态刷新，必须让 builder 内部直接读 state。
   */
  @Builder
  ChipRow(kind: string, title: string, desc: string) {
    Column({ space: 8 }) {
      Row() {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text(this.labelOf(kind, this.pickValue(kind)))
          .fontSize(12)
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.optionsOf(kind), (v: number) => {
          Text(this.labelOf(kind, v))
            .fontSize(12)
            .fontColor(this.pickValue(kind) === v ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.pickValue(kind) === v ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.setValue(kind, v);
            })
        }, (v: number) => `opt-${kind}-${v}`)
      }
      .width('100%')
      if (desc.length > 0) {
        Text(desc)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(14)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  build() {
    Column() {
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
        Text('播放器')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.presetLabel())
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(9)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          this.SectionTitle('预设', '一套数值对应一种网络环境，选完还能在下面单项微调')

          Row({ space: 8 }) {
            ForEach(PRESETS, (p: PresetOption) => {
              Column({ space: 3 }) {
                Text(p.label)
                  .fontSize(13)
                  .fontColor(this.preset === p.key ? '#FFFFFF' : Theme.TEXT)
                  .fontWeight(this.preset === p.key ? FontWeight.Medium : FontWeight.Normal)
                Text(p.desc)
                  .fontSize(9)
                  .fontColor(this.preset === p.key ? '#E6FFFFFF' : Theme.TEXT_FAINT)
                  .maxLines(2)
                  .textAlign(TextAlign.Center)
                  .lineHeight(12)
              }
              .layoutWeight(1)
              .padding({ left: 8, right: 8, top: 10, bottom: 10 })
              .backgroundColor(this.preset === p.key ? Theme.ACCENT : Theme.CARD)
              .borderRadius(12)
              .onClick(() => {
                this.pickPreset(p.key);
              })
            }, (p: PresetOption) => `preset-${p.key}`)
          }
          .width('100%')

          this.SectionTitle('播放', '')

          this.SwitchRow('硬件解码', '关了走软解。码率高、硬解花屏或卡住时再关', this.hwdec,
            (v: boolean) => {
              this.hwdec = v;
            })

          this.SwitchRow('精确跳转', '关：拖到最近关键帧，起播最快（默认）。开：落在准确时间点，但要多解码一段',
            this.hrSeek, (v: boolean) => {
              this.hrSeek = v;
              this.markPreset();
            })

          this.SectionTitle('缓冲', '拖动进度条后要等多久恢复，主要看前两项')

          this.ChipRow('pauseWait', '恢复前缓冲', '拖动后先攒这么多秒再播。这是「拖动完卡一下」的主因，调大更抗抖但更慢')
          this.ChipRow('readahead', '预读时长', '往后预读多少秒。网盘源建议 20~30')
          this.ChipRow('maxMiB', '缓存上限', '占用的内存上限。64 MiB 约等于 8Mbps 片源 60 秒')
          this.ChipRow('backMiB', '回退缓存', '往回拖时能不重新拉流的范围')

          Row({ space: 10 }) {
            Button('恢复推荐值')
              .layoutWeight(1)
              .height(40)
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(13)
              .onClick(() => {
                this.resetDefault();
              })
            Button('保存')
              .layoutWeight(1)
              .height(40)
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .margin({ top: 4 })

          if (this.note.length > 0) {
            Text(this.note)
              .fontSize(11)
              .fontColor('#8BD9A0')
              .width('100%')
          }

          // 高级：只读预览 + 额外参数。原始配置留给调试，日常不用碰。
          Row() {
            Text(this.advanced ? '▾ 高级（调试用）' : '▸ 高级（调试用）')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 10, bottom: 6 })
          .onClick(() => {
            this.advanced = !this.advanced;
          })

          if (this.advanced) {
            Text('额外参数（一行一个 key=value，追加到配置末尾）')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
            TextArea({ text: this.extra, placeholder: '例如\ntone-mapping=bt.2446a\nvd-lavc-threads=8' })
              .height(96)
              .fontSize(11)
              .fontColor(Theme.TEXT)
              .placeholderColor(Theme.TEXT_FAINT)
              .backgroundColor(Theme.CARD)
              .caretColor(Theme.ACCENT)
              .borderRadius(10)
              .onChange((v: string) => {
                this.extra = v;
                this.refreshPreview();
              })

            Text('生成的 mpv.conf（只读，用来确认参数）')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .margin({ top: 6 })
            Text(this.confPreview)
              .fontSize(9)
              .fontFamily('monospace')
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.CARD)
              .borderRadius(10)
          }

          Text('参数改动在下次进入播放页时生效；播放中不会热更新。')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .margin({ top: 6 })

          Blank().height(24)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
