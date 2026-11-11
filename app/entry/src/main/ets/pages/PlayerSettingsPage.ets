import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { Store } from '../common/Store';
import { httpGet, httpPost } from '../common/Http';
import { cacheClear, cacheSizeKb } from '../common/PageCache';
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
  @State note: string = '';
  @State confPreview: string = '';
  /** 交互项（不进 mpv.conf，存 Store 偏好）。 */
  @State seekStep: number = 10;
  /** 重力自动切换：关了播放页永远横屏全屏。 */
  @State autorotate: boolean = true;
  /** 返回桌面自动画中画（默认关）。 */
  @State pipAuto: boolean = false;
  /** 长按加速到多少倍（默认 3）。 */
  @State tempSpeed: number = 3;
  /** 从列表/剧照/弹幕跳进播放页时的默认形态：portrait | landscape。 */
  @State jumpMode: string = 'portrait';
  /** 播放方式：embed（就地起播，默认）| theater（跳播放页）| legacy（点了直接横屏全屏）。 */
  @State openMode: string = 'bili';
  /** 本地磁盘缓存上限 MiB（0 = 关）。 */
  @State diskMiB: number = 0;
  @State cacheNote: string = '';
  /** 弹幕样式（B 站式飞行）。 */
  @State danmuOn: boolean = true;
  @State danmuSize: number = 16;
  @State danmuSpeed: number = 90;
  @State danmuTracks: number = 6;
  @State danmuAlpha: number = 0.9;
  /** 服务端播放缓存占用（「1.2 GB / 4 GB · 320 块」）。 */
  @State cacheStat: string = '';
  /** 页面级数据缓存占用（KB）。 */
  @State pageCacheKb: number = 0;
  @State pageNote: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.fill(PlayerPrefs.load(ctx));
    const step: number = Number(Store.I.prefString('player_seek_step', '10'));
    this.seekStep = step >= 5 && step <= 60 ? Math.trunc(step) : 10;
    this.autorotate = Store.I.prefString('player_autorotate', '1') !== '0';
    this.pipAuto = Store.I.prefString('player_pip_auto', '0') === '1';
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
    this.loadCacheStat();
    this.pageCacheKb = cacheSizeKb();
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
      extra: this.extra,
      diskMiB: this.diskMiB
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
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(SEEK_STEPS, (v: number) => {
          Text(`${v} 秒`)
            .fontSize(12)
            .fontColor(this.seekStep === v ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.seekStep === v ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.seekStep = v;
              Store.I.prefSetString('player_seek_step', `${v}`);
            })
        }, (v: number) => `seek-${v}`)
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
              .fontColor(this.danmuSize === v ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuSize === v ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuSize = v;
                Store.I.prefSetString('danmu_size', `${v}`);
              })
          }, (v: number) => `ds-${v}`)
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
              .fontColor(this.danmuSpeed === o.v ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuSpeed === o.v ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuSpeed = o.v;
                Store.I.prefSetString('danmu_speed', `${o.v}`);
              })
          }, (o: Record<string, number>) => `dv-${o.v}`)
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
              .fontColor(this.danmuTracks === v ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(this.danmuTracks === v ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuTracks = v;
                Store.I.prefSetString('danmu_tracks', `${v}`);
              })
          }, (v: number) => `dt-${v}`)
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
              .fontColor(Math.abs(this.danmuAlpha - o.v) < 0.01 ? '#FFFFFF' : Theme.TEXT_DIM)
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .backgroundColor(Math.abs(this.danmuAlpha - o.v) < 0.01 ? Theme.ACCENT : Theme.CARD_HI)
              .borderRadius(12)
              .margin({ right: 7, bottom: 4 })
              .onClick(() => {
                this.danmuAlpha = o.v;
                Store.I.prefSetString('danmu_alpha', `${o.v}`);
              })
          }, (o: Record<string, number>) => `da-${o.v}`)
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
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([2, 3, 4, 5], (v: number) => {
          Text(`${v}x`)
            .fontSize(12)
            .fontColor(this.tempSpeed === v ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.tempSpeed === v ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.tempSpeed = v;
              Store.I.prefSetString('player_temp_speed', `${v}`);
            })
        }, (v: number) => `ts-${v}`)
      }
      .width('100%')
      Text('整块画面按住不放 = 临时加速到这档，松手回到原来的档位')
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
            .fontColor(this.openMode === o.k ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.openMode === o.k ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.openMode = o.k;
              Store.I.prefSetString('player_open_mode', o.k);
            })
        }, (o: Record<string, string>) => `om-${o.k}`)
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
            .fontColor(this.jumpMode === o.k ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.jumpMode === o.k ? Theme.ACCENT : Theme.CARD_HI)
            .borderRadius(13)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.jumpMode = o.k;
              Store.I.prefSetString('player_jump_mode', o.k);
            })
        }, (o: Record<string, string>) => `jm-${o.k}`)
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
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      Text('看过的片段会缓存在服务端磁盘上，第二次打开同一部片直接读缓存，不再回源网盘')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)

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
        Text('清理缓存')
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            this.clearDiskCache();
          })
        if (this.cacheNote.length > 0) {
          Text(this.cacheNote)
            .fontSize(10)
            .fontColor(Theme.ACCENT)
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
            .fontColor(this.diskMiB === v ? '#FFFFFF' : Theme.TEXT_DIM)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.diskMiB === v ? Theme.ACCENT : Theme.CARD_HI)
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
        }, (v: number) => `dc-${v}`)
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
      const used: number = Number(obj.used_mb) || 0;
      const budget: number = Number(obj.budget_mb) || 0;
      const files: number = Number(obj.files) || 0;
      if (budget <= 0) {
        this.cacheStat = '服务端未开启';
      } else {
        this.cacheStat = `已用 ${used >= 1024 ? (used / 1024).toFixed(1) + ' GB' : used.toFixed(0) + ' MB'} / ${budget >= 1024 ? (budget / 1024).toFixed(0) + ' GB' : budget + ' MB'}`;
        if (files > 0) {
          this.cacheStat = `${this.cacheStat} · ${files} 块`;
        }
      }
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
   */
  @Builder
  PageCacheRow() {
    Column({ space: 8 }) {
      Row() {
        Text('页面缓存')
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
        Text(this.pageCacheKb > 0 ? `${this.pageCacheKb} KB` : '空')
          .fontSize(11)
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      Text('详情页、首页这些数据在本机存一份：第二次进来先把上次的内容铺上去，网络在后台刷新')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
        .lineHeight(14)
      Row({ space: 8 }) {
        Text('刷新')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            this.pageCacheKb = cacheSizeKb();
          })
        Text('清理')
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(8)
          .onClick(() => {
            const n: number = cacheClear();
            this.pageCacheKb = 0;
            this.pageNote = n > 0 ? `已清理 ${n} 份` : '本来就是空的';
          })
        if (this.pageNote.length > 0) {
          Text(this.pageNote)
            .fontSize(10)
            .fontColor(Theme.ACCENT)
        }
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

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
        const removed: number = Number(obj.removed) || 0;
        this.cacheNote = `已清理服务端 ${removed} 个缓存块`;
        this.loadCacheStat();
      })
      .catch((err: BusinessError) => {
        console.error(`[amane] clear playcache: ${err.code} ${err.message}`);
        this.cacheNote = '服务端清理失败';
      });
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

          this.SeekStepRow()
          this.TempSpeedRow()
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

          // 返回桌面自动画中画（R18）：默认关，避免一按 home 就冒小窗
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('返回桌面自动画中画')
                .fontSize(14)
                .fontColor(Theme.TEXT)
              Text('开了之后按 home / 切到别的应用，播放会自动缩成小窗')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .lineHeight(14)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.pipAuto })
              .selectedColor(Theme.ACCENT)
              .onChange((v: boolean) => {
                this.pipAuto = v;
                Store.I.prefSetString('player_pip_auto', v ? '1' : '0');
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          this.SectionTitle('弹幕', '播放时从右往左飞过画面的那层字')
          this.DanmuSection()

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
          this.PageCacheRow()

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
