import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { Store } from '../common/Store';
import { SubStyle, SUB_SIZE_OPTS, SUB_OUTLINE_OPTS, SUB_POS_OPTS, SUB_BG_OPTS, SubOpt } from '../common/SubStyle';
import { httpGet, httpPost } from '../common/Http';
import { PageTitle, GlassBack } from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';
import {
  PlayerPrefs, PlayerTuning, PresetOption, PRESETS, confText, presetTuning
} from '../common/PlayerPrefs';

/** 快进/快退一次跳多少秒（播放页正中间那两个按钮）。 */
const SEEK_STEPS: number[] = [5, 10, 15, 20, 30];

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
  /** 播放性能区默认折叠（2026-11-15）：预设/解码/缓冲这些是调参，不该占第一屏。 */
  @State perfOpen: boolean = false;
  @State note: string = '';
  @State confPreview: string = '';
  /** 交互项（不进 mpv.conf，存 Store 偏好）。 */
  @State seekStep: number = 10;
  /** 重力自动切换：关了播放页永远横屏全屏。 */
  @State autorotate: boolean = true;
  /** 回桌面自动出系统小窗（默认关，2026-11-13 21:14 用户定）。 */
  @State pipAuto: boolean = false;
  /** 后台出声（回桌面后只留声音，默认关）。 */
  @State bgPlay: boolean = false;
  /** 长按加速到多少倍（默认 3）。 */
  @State tempSpeed: number = 3;
  /** 从列表/剧照/弹幕跳进播放页时的默认形态：portrait | landscape。 */
  @State jumpMode: string = 'portrait';
  /** 播放方式：embed（就地起播，默认）| theater（跳播放页）| legacy（点了直接横屏全屏）。 */
  @State openMode: string = 'bili';
  /** 本地磁盘缓存上限 MiB（0 = 关）。 */
  @State diskMiB: number = 0;
  /** 起播优先（2.6.1.57）：不等缓冲攒满就出画面。 */
  @State startFast: boolean = true;
  @State cacheNote: string = '';
  /** 弹幕样式（B 站式飞行）。 */
  @State danmuOn: boolean = true;
  @State danmuSize: number = 16;
  @State danmuSpeed: number = 90;
  @State danmuTracks: number = 6;
  @State danmuAlpha: number = 0.9;
  /** 字幕样式（2.6.1.55）：真值在偏好里，这里只做选中态。 */
  @State subSizePct: number = 100;
  @State subOutlineW: number = 3;
  @State subPosPct: number = 100;
  @State subBgMode: number = 0;
  /** 服务端播放缓存占用（「1.2 GB / 4 GB · 320 块」）。 */
  @State cacheStat: string = '';
  /** 网盘片那份缓存的额度（MB，用户可调；0 = 关闭）。 */
  @State remoteMb: number = 4096;
  /** 本地片那份（固定小额度，只显示不给改）。 */
  @State localStat: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.fill(PlayerPrefs.load(ctx));
    const step: number = Number(Store.I.prefString('player_seek_step', '10'));
    this.seekStep = step >= 5 && step <= 60 ? Math.trunc(step) : 10;
    this.autorotate = Store.I.prefString('player_autorotate', '1') !== '0';
    // 这两个开关默认关（2026-11-13 21:14 用户定），播放器读取口径必须一致。
    this.pipAuto = Store.I.prefString('player_pip_auto', '0') === '1';
    this.bgPlay = Store.I.prefString('player_bg_play', '0') === '1';
    const ts: number = Number(Store.I.prefString('player_temp_speed', '3'));
    this.tempSpeed = ts >= 1.5 && ts <= 5 ? ts : 3;
    this.jumpMode = Store.I.prefString('player_jump_mode', 'portrait');
    this.openMode = Store.I.prefString('player_open_mode', 'bili');
    this.diskMiB = Number(Store.I.prefString('player_disk_cache', '0')) || 0;
    this.danmuOn = Store.I.prefString('danmu_on', '1') === '1';
    this.danmuSize = Number(Store.I.prefString('danmu_size', '16')) || 16;
    this.danmuSpeed = Number(Store.I.prefString('danmu_speed', '90')) || 90;
    this.danmuTracks = Number(Store.I.prefString('danmu_tracks', '6')) || 6;
    this.danmuAlpha = Number(Store.I.prefString('danmu_alpha', '0.9')) || 0.9;
    // 字幕样式：和播放页那个面板共用同一套偏好
    this.subSizePct = SubStyle.size();
    this.subOutlineW = SubStyle.outline();
    this.subPosPct = SubStyle.pos();
    this.subBgMode = SubStyle.bg();
    this.loadCacheStat();
  }

  /** 一行提示（2 秒自动消失），给开关联动这类「改了另一个」的反馈用。 */
  private flash(msg: string): void {
    this.note = msg;
    setTimeout(() => {
      this.note = '';
    }, 2200);
  }

  /**
   * 回桌面后的三种状态（2026-11-15）。
   *
   * 原来「后台播放」和「回桌面出小窗」是两个 Switch，互斥靠「开一个自动关另一个」实现，
   * 用户看到的是「我开了一个，另一个自己关了」。现在表达成一个单选项，但**底下还是这两个偏好键**：
   *   off = 都关（默认） / bg = player_bg_play=1 / pip = player_pip_auto=1
   * 键名、默认值、互斥规则一个都没变，老配置读出来自然落到对应档。
   */
  private deskMode(): string {
    if (this.pipAuto) {
      return 'pip';
    }
    return this.bgPlay ? 'bg' : 'off';
  }

  private pickDesk(mode: string): void {
    this.bgPlay = mode === 'bg';
    this.pipAuto = mode === 'pip';
    Store.I.prefSetString('player_bg_play', this.bgPlay ? '1' : '0');
    Store.I.prefSetString('player_pip_auto', this.pipAuto ? '1' : '0');
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
    this.diskMiB = t.diskMiB;
    this.startFast = t.startFast;
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
      extra: this.extra,
      diskMiB: this.diskMiB,
      startFast: this.startFast
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

  /** 快进/快退步长：播放页正中间那对按钮一次跳多远。 */
  @Builder
  SeekStepRow() {
    Column({ space: 8 }) {
      Row() {
        Text('快进 / 快退')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text(`${this.seekStep} 秒`)
          .fontSize(12)
          .fontColor(Theme.ACCENT_INK)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(SEEK_STEPS, (v: number) => {
          Text(`${v} 秒`)
            .fontSize(12)
            .fontColor(this.seekStep === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.seekStep === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.seekStep === v ? 0.75 : 0.5, color: this.seekStep === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.seekStep = v;
              Store.I.prefSetString('player_seek_step', `${v}`);
            })
        }, (v: number) => `seek-${v}-${this.seekStep === v ? 1 : 0}`)
      }
      .width('100%')
      Text('播放页正中间那对 « » 按钮，按一下跳多少秒')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 弹幕样式：一行一个维度，全部读 state（@Builder 传值不重建，踩过）。 */
  @Builder
  DanmuSection() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('播放时显示弹幕')
            .fontSize(14)
            .fontColor(Theme.TEXT)
          Text('从右往左飞过画面，按时间点出现')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.danmuOn })
          .selectedColor(Theme.ACCENT)
          .onChange((v: boolean) => {
            this.danmuOn = v;
            Store.I.prefSetString('danmu_on', v ? '1' : '0');
          })
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('字号')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(40)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([14, 16, 18, 20], (v: number) => {
            Text(`${v}`)
              .fontSize(12)
              .fontColor(this.danmuSize === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuSize === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.danmuSize === v ? 0.75 : 0.5, color: this.danmuSize === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuSize = v;
                Store.I.prefSetString('danmu_size', `${v}`);
              })
          }, (v: number) => `ds-${v}-${this.danmuSize === v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('速度')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(40)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([{ v: 55, l: '慢' }, { v: 90, l: '中' }, { v: 140, l: '快' }], (o: Record<string, number>) => {
            Text(String(o.l))
              .fontSize(12)
              .fontColor(this.danmuSpeed === o.v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuSpeed === o.v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.danmuSpeed === o.v ? 0.75 : 0.5, color: this.danmuSpeed === o.v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuSpeed = o.v;
                Store.I.prefSetString('danmu_speed', `${o.v}`);
              })
          }, (o: Record<string, number>) => `dv-${o.v}-${this.danmuSpeed === o.v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('轨道')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(40)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([4, 6, 8], (v: number) => {
            Text(`${v} 行`)
              .fontSize(12)
              .fontColor(this.danmuTracks === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuTracks === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.danmuTracks === v ? 0.75 : 0.5, color: this.danmuTracks === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuTracks = v;
                Store.I.prefSetString('danmu_tracks', `${v}`);
              })
          }, (v: number) => `dt-${v}-${this.danmuTracks === v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('不透明')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(40)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([{ v: 0.6, l: '淡' }, { v: 0.8, l: '中' }, { v: 1.0, l: '实' }], (o: Record<string, number>) => {
            Text(String(o.l))
              .fontSize(12)
              .fontColor(Math.abs(this.danmuAlpha - o.v) < 0.01 ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(Math.abs(this.danmuAlpha - o.v) < 0.01 ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: Math.abs(this.danmuAlpha - o.v) < 0.01 ? 0.75 : 0.5, color: Math.abs(this.danmuAlpha - o.v) < 0.01 ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuAlpha = o.v;
                Store.I.prefSetString('danmu_alpha', `${o.v}`);
              })
          }, (o: Record<string, number>) => `da-${o.v}-${Math.abs(this.danmuAlpha - o.v) < 0.01 ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /**
   * 字幕样式（2.6.1.55）：字号 / 描边 / 位置 / 背景。
   *
   * 和播放页里那个「字幕 · 样式」面板共用同一套偏好（`SubStyle`），两处改都算数。
   * 播放中想边看边调，用播放页那个面板 —— 那边点一下立刻写进 mpv；
   * 这里改完回到播放页也会生效（进播放器时按偏好套一遍）。
   */
  @Builder
  SubtitleStyleSection() {
    Column({ space: 10 }) {
      Row({ space: 7 }) {
        Text('字号')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(34)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SUB_SIZE_OPTS, (o: SubOpt) => {
            Text(o.l)
              .fontSize(12)
              .fontColor(this.subSizePct === o.v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.subSizePct === o.v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.subSizePct === o.v ? 0.75 : 0.5, color: this.subSizePct === o.v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.subSizePct = o.v;
                SubStyle.setSize(o.v);
              })
          }, (o: SubOpt) => `ss-${o.v}-${this.subSizePct === o.v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('描边')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(34)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SUB_OUTLINE_OPTS, (o: SubOpt) => {
            Text(o.l)
              .fontSize(12)
              .fontColor(this.subOutlineW === o.v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.subOutlineW === o.v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.subOutlineW === o.v ? 0.75 : 0.5, color: this.subOutlineW === o.v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.subOutlineW = o.v;
                SubStyle.setOutline(o.v);
              })
          }, (o: SubOpt) => `so-${o.v}-${this.subOutlineW === o.v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('位置')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(34)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SUB_POS_OPTS, (o: SubOpt) => {
            Text(o.l)
              .fontSize(12)
              .fontColor(this.subPosPct === o.v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.subPosPct === o.v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.subPosPct === o.v ? 0.75 : 0.5, color: this.subPosPct === o.v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.subPosPct = o.v;
                SubStyle.setPos(o.v);
              })
          }, (o: SubOpt) => `sp-${o.v}-${this.subPosPct === o.v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 7 }) {
        Text('背景')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(34)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SUB_BG_OPTS, (o: SubOpt) => {
            Text(o.l)
              .fontSize(12)
              .fontColor(this.subBgMode === o.v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.subBgMode === o.v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.subBgMode === o.v ? 0.75 : 0.5, color: this.subBgMode === o.v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.subBgMode = o.v;
                SubStyle.setBg(o.v);
              })
          }, (o: SubOpt) => `sb-${o.v}-${this.subBgMode === o.v ? 1 : 0}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Text('播放中也可在字幕面板右上角「样式」微调')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .lineHeight(14)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 长按加速倍速：整块画面长按 420ms 触发。 */
  @Builder
  TempSpeedRow() {
    Column({ space: 8 }) {
      Row() {
        Text('长按加速')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text(`${this.tempSpeed}x`)
          .fontSize(12)
          .fontColor(Theme.ACCENT_INK)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([2, 3, 4, 5], (v: number) => {
          Text(`${v}x`)
            .fontSize(12)
            .fontColor(this.tempSpeed === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.tempSpeed === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.tempSpeed === v ? 0.75 : 0.5, color: this.tempSpeed === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.tempSpeed = v;
              Store.I.prefSetString('player_temp_speed', `${v}`);
            })
        }, (v: number) => `ts-${v}-${this.tempSpeed === v ? 1 : 0}`)
      }
      .width('100%')
      Text('长按画面临时加速，松手恢复原速')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /**
   * 播放方式（用户第 3 条）：新版「就地起播」/ 旧版「点了直接横屏全屏」。
   * 位置放在「跳转后默认形态」上面 —— 它决定的是「怎么进入播放」。
   */
  @Builder
  OpenModeRow() {
    Column({ space: 8 }) {
      Row() {
        Text('播放方式')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([
          { k: 'bili', l: 'B 站模式（就地起播）' },
          { k: 'emby', l: 'Emby 模式（跳播放页全屏）' }
        ], (o: Record<string, string>) => {
          Text(o.l)
            .fontSize(12)
            .fontColor(this.openMode === o.k ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.openMode === o.k ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.openMode === o.k ? 0.75 : 0.5, color: this.openMode === o.k ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.openMode = o.k;
              Store.I.prefSetString('player_open_mode', o.k);
            })
        }, (o: Record<string, string>) => `om-${o.k}-${this.openMode === o.k ? 1 : 0}`)
      }
      .width('100%')
      Text('B 站模式：点播放后播放器直接出现在详情页顶部，不跳页、不重新加载；\n'
        + 'Emby 模式：点播放跳到独立播放页、横屏全屏（习惯老操作选这个）')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 从别处跳进播放页时的默认形态。 */
  @Builder
  JumpModeRow() {
    Column({ space: 8 }) {
      Row() {
        Text('跳转后默认形态')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([{ k: 'portrait', l: '竖屏（顶部播放 + 详情）' }, { k: 'landscape', l: '横屏全屏' }], (o: Record<string, string>) => {
          Text(o.l)
            .fontSize(12)
            .fontColor(this.jumpMode === o.k ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.jumpMode === o.k ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.jumpMode === o.k ? 0.75 : 0.5, color: this.jumpMode === o.k ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.jumpMode = o.k;
              Store.I.prefSetString('player_jump_mode', o.k);
            })
        }, (o: Record<string, string>) => `jm-${o.k}-${this.jumpMode === o.k ? 1 : 0}`)
      }
      .width('100%')
      Text('从剧照、截帧、弹幕、观看记录点进去时用哪种；播放页里还能随时切')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /**
   * 播放缓存（1.3.35 起是**服务端**按块落盘的缓存）。
   *
   * 之前这里只有 mpv 的 `cache-on-disk`：那个缓存只在本次播放里有意义，
   * 退出就没了，用户自然会觉得「每次进去都重新缓存」。真正让第二次打开变快的，
   * 是服务端把下过的块留在 NAS 磁盘上 —— 这里直接显示占用并支持一键清空。
   */
  @Builder
  DiskCacheRow() {
    Column({ space: 8 }) {
      Row() {
        Text('播放缓存')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text(this.cacheStat.length > 0 ? this.cacheStat : '读取中…')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
      }
      .width('100%')
      Text('缓存已播片段以加速网盘起播；额度与清理在「空间管理」调整。')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
      if (this.localStat.length > 0) {
        Text(this.localStat)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(14)
      }

      // 网盘片上限只读显示：**调节入口只留「空间管理」一处**（2026-11-15 合并且去重）。
      // 两个页面同时能改同一个数字，用户改完不知道哪个生效，也容易一边改了另一边看不出变化。
      Row() {
        Text('网盘片缓存上限')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .layoutWeight(1)
        Text(this.remoteMb > 0 ? (this.remoteMb >= 1024 ? `${Math.round(this.remoteMb / 1024)} GB` : `${this.remoteMb} MB`) : '关闭')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .margin({ top: 2 })

      Row({ space: 8 }) {
        Text('刷新')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            this.loadCacheStat();
          })
        // 2026-11-15：上限与清理只留「空间管理」一个入口（那边能分开看网盘片 / 本地片），
        // 这里只读 + 跳转，避免同一个数字两处改让人困惑。
        Text('去空间管理调整 ›')
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            router.pushUrl({ url: 'pages/CachePage' });
          })
        if (this.cacheNote.length > 0) {
          Text(this.cacheNote)
            .fontSize(10)
            .fontColor(Theme.ACCENT_INK)
            .layoutWeight(1)
            .maxLines(2)
        }
        Blank()
      }
      .width('100%')

      // 本机 mpv 的缓冲（只影响本次播放内的拖动/回看）
      Row() {
        Text('本机缓冲')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .layoutWeight(1)
        Text(this.diskMiB > 0 ? `${this.diskMiB} MB` : '关闭')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .margin({ top: 2 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([0, 512, 1024, 2048, 4096], (v: number) => {
          Text(v === 0 ? '关' : (v >= 1024 ? `${v / 1024} GB` : `${v} MB`))
            .fontSize(12)
            .fontColor(this.diskMiB === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.diskMiB === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.diskMiB === v ? 0.75 : 0.5, color: this.diskMiB === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.diskMiB = v;
              Store.I.prefSetString('player_disk_cache', `${v}`);
              // 缓存策略写进 mpv.conf，下次进播放页生效
              const ctx = getContext(this) as common.UIAbilityContext;
              const t: PlayerTuning = this.current();
              t.diskMiB = v;
              PlayerPrefs.save(ctx, t);
              this.cacheNote = '本机缓冲已保存，下次进播放页生效';
            })
        }, (v: number) => `dc-${v}-${this.diskMiB === v ? 1 : 0}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 拉服务端的缓存占用（失败就静默留空，不影响别的设置项）。 */
  private loadCacheStat(): void {
    httpGet(`${Store.I.user}/api/user/playcache`, Store.I.token).then((text: string) => {
      const obj = JSON.parse(text) as Record<string, Object>;
      const used: number = Number(obj.remote_used_mb) || 0;
      const budget: number = Number(obj.remote_budget_mb) || 0;
      const files: number = Number(obj.files) || 0;
      const locUsed: number = Number(obj.local_used_mb) || 0;
      const locMb: number = Number(obj.local_budget_mb) || 0;
      this.remoteMb = budget;
      const fmt = (mb: number, digits: boolean): string => {
        if (mb >= 1024) {
          return digits ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb / 1024)} GB`;
        }
        return `${Math.round(mb)} MB`;
      };
      if (budget <= 0) {
        this.cacheStat = '已关闭（不缓存网盘片）';
      } else {
        this.cacheStat = `${fmt(used, true)} / ${fmt(budget, false)}`;
        if (files > 0) {
          this.cacheStat = `${this.cacheStat} · ${files} 块`;
        }
      }
      this.localStat = locMb > 0
        ? `本地片：${fmt(locUsed, true)} / ${fmt(locMb, false)}（固定额度）`
        : '本地片：未启用';
    }).catch((err: BusinessError) => {
      console.error(`[amane] playcache: ${err.code} ${err.message}`);
      this.cacheStat = '读取失败';
    });
  }

  /** 清空服务端缓存 + 本机 mpv 的 stream-cache。 */
  /**
   * 页面缓存（用户第 9 条）：详情页/首页这些「读接口」的响应留一份在本机。
   *
   * 和服务端「播放缓存」是两件事：
   *  - 播放缓存 = 视频数据块，解决「起播慢」；
   *  - 页面缓存 = 页面数据（JSON），解决「每次进页面都要等一下才出内容」。
   *
   * 2026-11-15：页面缓存的「看占用 + 清理」搬到「设置 → 存储与数据 → 空间管理」（那一页的
   * 「页面数据」卡片就是这件事，还带条数）。这里不再重复放，避免同一份数据两个清理入口。
   */

  private clearDiskCache(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dir: string = `${PlayerPrefs.dir(ctx)}/stream-cache`;
      if (fs.accessSync(dir)) {
        const list = fs.listFileSync(dir);
        for (let i = 0; i < list.length; i++) {
          fs.unlinkSync(`${dir}/${list[i]}`);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] clear local cache: ${e.code} ${e.message}`);
    }
    httpPost(`${Store.I.user}/api/user/playcache/clear`, Store.I.token, '{}')
      .then((text: string) => {
        const obj = JSON.parse(text) as Record<string, Object>;
        const removed: number = (Number(obj.remote_removed) || 0) + (Number(obj.local_removed) || 0);
        this.cacheNote = `已清理服务端 ${removed} 个缓存块`;
        this.loadCacheStat();
      })
      .catch((err: BusinessError) => {
        console.error(`[amane] clear playcache: ${err.code} ${err.message}`);
        this.cacheNote = '服务端清理失败';
      });
  }

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
          .fontColor(Theme.ACCENT_INK)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.optionsOf(kind), (v: number) => {
          Text(this.labelOf(kind, v))
            .fontSize(12)
            .fontColor(this.pickValue(kind) === v ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.pickValue(kind) === v ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.pickValue(kind) === v ? 0.75 : 0.5, color: this.pickValue(kind) === v ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
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
        PageTitle({ text: '播放设置', fs: 18 })
        Blank()
        Text(this.presetLabel())
          .fontSize(11)
          .fontColor(Theme.ACCENT_INK)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(9)
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

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  build() {
    Navigation(this.navStack) {
      Column() {

        Scroll() {
          Column({ space: 12 }) {

          // 六十改：标题栏浮在内容之上 —— 首屏落在玻璃下方，一滚动就从玻璃底下穿过去，
          // 材质才有颜色可采样。
          Blank().height(this.barH() + 6)
            // ── 播放习惯（2026-11-15 重排：先放「怎么播」，性能参数收进下面的折叠区）──
            this.SectionTitle('播放习惯', '下面这些改完立即生效，不用点保存')

            this.OpenModeRow()
            this.JumpModeRow()

            // 重力开关内联在 build 里（不用 @Builder 传值）：
            // @Builder 按值传参不重建，「点了开关不动」这坑在抽卡那里踩过。
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('重力自动切换')
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                Text(this.autorotate
                  ? '竖着拿 = 顶部 16:9 播放器 + 下拉详情；横着拿 = 全屏'
                  : '播放页永远横屏全屏，竖着拿也不变')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .lineHeight(14)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autorotate })
                .selectedColor(Theme.ACCENT)
                .onChange((v: boolean) => {
                  this.autorotate = v;
                  Store.I.prefSetString('player_autorotate', v ? '1' : '0');
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)

            this.SeekStepRow()
            this.TempSpeedRow()

            // ── 返回桌面后（2026-11-15）：两个互斥开关合成一个单选项 ──
            // 偏好键与默认值一个都没变：都不选 = 关闭；player_bg_play=1 = 仅声音；player_pip_auto=1 = 画中画。
            // 原来两个 Switch 各自带「开一个自动关另一个」，用户开了一个另一个突然关掉，看着像 bug。
            this.SectionTitle('返回桌面后', '按 home 或切到别的应用时怎么办；选完立即生效')

            Column({ space: 10 }) {
              Row() {
                Text('按 home 回桌面后')
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                Text(this.deskMode() === 'off' ? '关闭' : (this.deskMode() === 'bg' ? '仅声音' : '画中画'))
                  .fontSize(12)
                  .fontColor(Theme.ACCENT_INK)
              }
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap }) {
                Text('关闭')
                  .fontSize(12)
                  .fontColor(this.deskMode() === 'off' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .backgroundColor(this.deskMode() === 'off' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.deskMode() === 'off' ? 0.75 : 0.5, color: this.deskMode() === 'off' ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
                  .borderRadius(13)
                  .margin({ right: 8, bottom: 4 })
                  .onClick(() => {
                    this.pickDesk('off');
                  })
                Text('只留声音')
                  .fontSize(12)
                  .fontColor(this.deskMode() === 'bg' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .backgroundColor(this.deskMode() === 'bg' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.deskMode() === 'bg' ? 0.75 : 0.5, color: this.deskMode() === 'bg' ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
                  .borderRadius(13)
                  .margin({ right: 8, bottom: 4 })
                  .onClick(() => {
                    this.pickDesk('bg');
                  })
                Text('缩成小窗')
                  .fontSize(12)
                  .fontColor(this.deskMode() === 'pip' ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .backgroundColor(this.deskMode() === 'pip' ? Theme.accentAlpha(0.20) : Theme.CARD_HI)
          .border({ width: this.deskMode() === 'pip' ? 0.75 : 0.5, color: this.deskMode() === 'pip' ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
                  .borderRadius(13)
                  .margin({ right: 8, bottom: 4 })
                  .onClick(() => {
                    this.pickDesk('pip');
                  })
              }
              .width('100%')

              Text(this.deskMode() === 'off'
                ? '回到桌面就停：声音和画面都不留（默认）。'
                : (this.deskMode() === 'bg'
                  ? '回到桌面后画面没了、声音继续，不出现小窗。'
                  : '回到桌面后自动缩成桌面小窗，画面和声音都跟着走。'))
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .lineHeight(15)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
            .alignItems(HorizontalAlign.Start)

            // 应用内小窗（2.6.2.1）改成**只在播放器上点「画中画」时出现**（2026-11-13 21:12
            // 用户口径：退出详情页不自动弹；回桌面走系统画中画）。原来那两个开关
            // （「离开详情页继续小窗」与「回桌面出小窗」）已在 2026-11-15 合成上面那个单选项。

            this.SectionTitle('弹幕', '播放时从右往左飞过画面的那层字；改完立即生效')
            this.DanmuSection()

            this.SectionTitle('字幕样式', '字号、描边、位置、背景；改完立刻生效，不用重播')
            this.SubtitleStyleSection()

            // ── 播放性能（2026-11-15：默认折叠）──
            // 这些是「调参」，日常不用碰；收起来后第一屏只剩播放习惯、回桌面行为、字幕弹幕。
            Row() {
              Text(this.perfOpen ? '▾ 播放性能' : '▸ 播放性能')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
                .layoutWeight(1)
              Text(this.presetLabel())
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width('100%')
            .padding({ top: 12, bottom: 6 })
            .onClick(() => {
              this.perfOpen = !this.perfOpen;
            })

            if (this.perfOpen) {
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
                  .backgroundColor(this.preset === p.key ? Theme.accentAlpha(0.20) : Theme.CARD)
                  .border({ width: this.preset === p.key ? 0.75 : 0.5, color: this.preset === p.key ? Theme.inkAlpha(0.50) : '#14FFFFFF' })
                  .borderRadius(12)
                  .onClick(() => {
                    this.pickPreset(p.key);
                  })
                }, (p: PresetOption) => `preset-${p.key}`)
              }
              .width('100%')

              // 起播优先（2.6.1.57）：网页播放器那种「拿到第一帧就播」的观感
              Row({ space: 12 }) {
                Column({ space: 2 }) {
                  Text('起播优先')
                    .fontSize(14)
                    .fontColor(Theme.TEXT)
                  Text('不等缓冲攒满就出画面，点开即播、拖进度也更快；' +
                    '代价是网络很慢时画面上来会先顿一下')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                    .lineHeight(14)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.startFast })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.startFast = v;
                    this.refreshPreview();
                    this.save();
                  })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(Theme.RADIUS)

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

            this.DiskCacheRow()

            this.ChipRow('pauseWait', '恢复前缓冲', '拖动后先攒这么多秒再播。这是「拖动完卡一下」的主因，调大更抗抖但更慢')
            this.ChipRow('readahead', '预读时长', '往后预读多少秒。网盘源建议 20~30')
            this.ChipRow('maxMiB', '缓存上限', '占用的内存上限。64 MiB 约等于 8Mbps 片源 60 秒')
            this.ChipRow('backMiB', '回退缓存', '往回拖时能不重新拉流的范围')

            Row({ space: 10 }) {
              Button('恢复推荐值')
                .layoutWeight(1)
                .height(42)
                .backgroundColor('#1AFFFFFF')
                .border({ width: 0.75, color: '#28FFFFFF' })
                .borderRadius(21)
                .fontColor(Theme.TEXT)
                .fontSize(13)
                .onClick(() => {
                  this.resetDefault();
                })
              Button('保存')
                .layoutWeight(1)
                .height(42)
                .backgroundColor(Color.Transparent)
                .linearGradient(Theme.ctaGradient())
                .border({ width: 0.75, color: '#38FFFFFF' })
                .borderRadius(21)
                .fontColor(Theme.ON_ACCENT)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .onClick(() => {
                  this.save();
                })
            }
            .width('100%')
            .margin({ top: 4 })
            }

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
                .caretColor(Theme.ACCENT_INK)
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
                .fontSize(10)
                .fontFeature('"tnum" 1')
                .fontColor(Theme.TEXT_DIM)
                .width('100%')
                .padding(10)
                .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                .backgroundColor('#1FFFFFFF')
                .border({ width: 0.5, color: '#33FFFFFF' })
                .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
                .borderRadius(10)
            }

            Text('习惯与字幕即时生效；性能与高级参数保存后下次起播生效。')
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