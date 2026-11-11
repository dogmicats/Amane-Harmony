import { Theme } from '../common/Theme';
import { clock } from '../common/Util';

/**
 * 播放器控制层（纯 ArkUI，不依赖 mpv）。
 *
 * 三种形态：
 *  - `compact`     —— 竖屏「顶部 16:9」：顶栏 + **工具行**（字幕/选集/截帧/弹幕）+ 迷你播放条；
 *                     收缩态只留一条 MiniBar。
 *  - `portraitFull`—— 竖屏全屏：顶栏 + 中央控件 + 两行底栏
 *  - `landscape`   —— 横屏全屏：顶栏 + 中央控件 + 单行底栏
 *
 * ★ 图标一律用 `resources/base/media/ic_*.svg`（极简线面风格）★
 *   之前用 Polygon/Path 手画，坐标单位（vp）和 0..100 的直觉混着用，
 *   尺寸反复出错（一会儿白块一会儿针尖大）。位图/矢量资源给多少就是多少，
 *   只用 `.fillColor()` 上色，不再手算几何。
 */
@ComponentV2
export struct PlayerChrome {
  @Param number: string = '';
  @Param title: string = '';
  @Param fileName: string = '';
  @Param onAir: boolean = false;
  @Param speed: number = 1;
  @Param playing: boolean = false;
  @Param pos: number = 0;
  @Param duration: number = 0;
  @Param seekPreview: number = -1;
  @Param volume: number = 100;
  @Param diagnostics: string = '';
  @Param bandwidthText: string = '';
  @Param seekStep: number = 10;
  @Param speedOptions: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];
  @Param tempSpeed: number = 3.0;
  /** `compact` | `portraitFull` | `landscape`。 */
  @Param layout: string = 'landscape';
  /** 竖屏被详情抽屉顶上来、画面缩小时 = true：只留一条 MiniBar。 */
  @Param collapsed: boolean = false;
  @Param pipActive: boolean = false;

  @Event onBack: () => void = () => {};
  @Event onPlayPause: () => void = () => {};
  @Event onSeekBy: (delta: number) => void = (delta: number) => {};
  @Event onTempSpeed: (on: boolean) => void = (on: boolean) => {};
  @Event onSpeed: () => void = () => {};
  @Event onPickSpeed: (v: number) => void = (v: number) => {};
  @Event onSnap: () => void = () => {};
  @Event onPicker: () => void = () => {};
  @Event onAnno: () => void = () => {};
  @Event onPip: () => void = () => {};
  @Event onToggleFull: () => void = () => {};
  @Event onLandscape: () => void = () => {};
  @Event onSeekMoving: (seconds: number) => void = (seconds: number) => {};
  @Event onSeekEnd: (seconds: number) => void = (seconds: number) => {};
  @Event onSubs: () => void = () => {};
  @Event onAudio: () => void = () => {};
  @Event onMute: () => void = () => {};

  @Local speedOpen: boolean = false;

  private shownPos(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.pos;
  }

  private isCompact(): boolean {
    return this.layout === 'compact';
  }

  // ---- 图标（SVG 资源，尺寸即所给尺寸）--------------------------------- //

  /**
   * ★ 绝对不要给这些 SVG 加 `.fillColor()` ★
   *
   * `fillColor` 会把 SVG 里**所有形状**（包括 `fill="none"` 的描边图形）一起填实：
   * 字幕框、对话气泡、四角括号这些线描图标全变成实心白方块/白圆，
   * 屏幕上就是「一个个纯白的方块和圆」（2.4.6.17 反馈第 1 条）。
   *
   * 图标自己带颜色：白色图标 `fill="#FFFFFF"`，需要彩色就单独做一个
   * （`ic_mute_amber.svg` / `ic_pip_on.svg`）。`tint` 参数只为兼容旧调用保留。
   */
  @Builder
  Ic(src: Resource, size: number, tint: string) {
    Image(src)
      .width(size)
      .height(size)
      .objectFit(ImageFit.Contain)
      .draggable(false)
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  PlayIcon(size: number) {
    if (this.playing) {
      this.Ic($r('app.media.ic_pause'), size, '#FFFFFF')
    } else {
      this.Ic($r('app.media.ic_play'), size, '#FFFFFF')
    }
  }

  /** 圆形按钮：底色 + 图标（图标在圆心，尺寸 ≈ 圆的 58%），点击热区 = 整个圆。 */
  @Builder
  RoundButton(src: Resource, iconSize: number, boxSize: number, bg: string, tint: string,
    onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(boxSize)
        .height(boxSize)
        .borderRadius(boxSize / 2)
        .backgroundColor(bg)
      this.Ic(src, iconSize, tint)
    }
    .width(boxSize)
    .height(boxSize)
    .alignContent(Alignment.Center)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  SpeedMenu() {
    Column({ space: 1 }) {
      ForEach(this.speedOptions, (v: number) => {
        Row() {
          Text(`${v}x`)
            .fontSize(12)
            .fontColor(Math.abs(this.speed - v) < 0.01 ? Theme.ACCENT : '#E6FFFFFF')
          Blank()
          if (Math.abs(this.speed - v) < 0.01) {
            Text('✓')
              .fontSize(11)
              .fontColor(Theme.ACCENT)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          this.onPickSpeed(v);
          this.speedOpen = false;
        })
      }, (v: number) => `sp-${v}`)
    }
    .width(112)
    .padding({ top: 6, bottom: 6 })
    .backgroundColor('#D9000000')
    .backdropBlur(24)
    .border({ width: 0.6, color: '#2EFFFFFF' })
    .borderRadius(14)
    .shadow({ radius: 18, color: '#66000000', offsetY: 6 })
    .onClick(() => {
      // 吞掉点击，不然冒泡到遮罩立刻又关上
    })
  }

  // ---- 顶栏 ------------------------------------------------------------ //

  @Builder
  TopBar() {
    if (this.isCompact()) {
      Row({ space: 6 }) {
        Row() {
          this.Ic($r('app.media.ic_back'), 15, '#FFFFFF')
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onBack();
        })

        Text(this.number)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)

        Text(this.onAir ? '外网' : '内网')
          .fontSize(8)
          .fontColor(this.onAir ? '#FFB454' : '#7FE3C0')
          .padding({ left: 3, right: 3 })
          .backgroundColor('#2E000000')
          .borderRadius(3)

        Blank()

        Text(`${this.speed}x`)
          .fontSize(9)
          .fontColor('#E6FFFFFF')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor('#26FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            this.speedOpen = !this.speedOpen;
          })

        Row() {
          this.Ic($r('app.media.ic_snap'), 14, '#FFFFFF')
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onSnap();
        })

        Row() {
          this.Ic(this.pipActive ? $r('app.media.ic_pip_on') : $r('app.media.ic_pip'), 14, '#FFFFFF')
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onPip();
        })
      }
      .width('96%')
      .height(32)
      .padding({ left: 6, right: 6 })
      .margin({ top: 6 })
      .borderRadius(16)
      .backgroundColor('#33000000')
      .backdropBlur(18)
      .border({ width: 0.6, color: '#26FFFFFF' })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: -8 })))
    } else {
      Row({ space: 8 }) {
        Row() {
          this.Ic($r('app.media.ic_back'), 17, '#FFFFFF')
        }
        .width(30)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onBack();
        })

        Text(this.number)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)

        Text(this.onAir ? '外网' : '局域网')
          .fontSize(9)
          .fontColor(this.onAir ? '#FFB454' : '#7FE3C0')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor('#2E000000')
          .borderRadius(3)

        if (this.fileName.length > 0) {
          Text(`· ${this.fileName}`)
            .fontSize(10)
            .fontColor('#8CFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank()
        }

        if (this.diagnostics.length > 0) {
          Text(this.diagnostics)
            .fontSize(9)
            .fontColor('#73FFFFFF')
            .maxLines(1)
        }

        Row() {
          this.Ic($r('app.media.ic_snap'), 16, '#FFFFFF')
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onSnap();
        })

        Row() {
          this.Ic(this.pipActive ? $r('app.media.ic_pip_on') : $r('app.media.ic_pip'), 16, '#FFFFFF')
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onPip();
        })

        Text(`${this.speed}x`)
          .fontSize(11)
          .fontColor('#E6FFFFFF')
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor('#26FFFFFF')
          .borderRadius(10)
          .onClick(() => {
            this.speedOpen = !this.speedOpen;
          })
      }
      .width('88%')
      .constraintSize({ maxWidth: 760 })
      .height(36)
      .padding({ left: 8, right: 8 })
      .margin({ top: 10 })
      .borderRadius(18)
      .backgroundColor('#1F000000')
      .backdropBlur(26)
      .border({ width: 0.6, color: '#2EFFFFFF' })
      .shadow({ radius: 14, color: '#59000000', offsetY: 4 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: -8 })))
    }
  }

  // ---- 工具按钮（统一纯图标：极简线面 + 胶囊底，不写文字）-------------- //

  /**
   * 图标按钮：竖屏工具行用（36 高、图标 20，手指好点）。
   *
   * ★ 底色要够深、图标要纯白 ★
   *   之前底是 24% 黑、图标是 90% 白（#E6FFFFFF）：在亮画面上两者糊成一片，
   *   用户根本看不出画的是什么（2.4.6.15 反馈第 2 条）。改成 45% 黑底 + 细白边
   *   + 纯白图标，任何画面上都能看清轮廓。
   */
  @Builder
  ToolIcon(src: Resource, tint: string, size: number, box: number, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      this.Ic(src, size, tint)
    }
    .width(box)
    .height(box)
    .borderRadius(box / 2.4)
    .backgroundColor('#73000000')
    .border({ width: 0.6, color: '#40FFFFFF' })
    .onClick(() => {
      onTap();
    })
  }

  // ---- 竖屏工具行（第 4 条：字幕 / 选集 / 截帧 / 弹幕）---------------- //

  /**
   * 竖屏工具行：字幕 / 截帧 / 弹幕。
   *
   * 选集从竖屏入口里拿掉了（用户 2.4.6.20 第 2 条）：竖屏这块只有 16:9 那么高，
   * 选集面板塞进去又挤又难看，换集走详情页的版本/同系列更顺手。
   * 画中画也不放这儿 —— 顶栏已经有同一个按钮，重复了。
   */
  @Builder
  CompactTools() {
    Row({ space: 8 }) {
      this.ToolIcon($r('app.media.ic_subtitle'), '#FFFFFF', 20, 36, () => {
        this.onSubs();
      })
      this.ToolIcon($r('app.media.ic_snap'), '#FFFFFF', 20, 36, () => {
        this.onSnap();
      })
      this.ToolIcon($r('app.media.ic_danmaku'), '#FFFFFF', 20, 36, () => {
        this.onAnno();
      })
    }
    .width('96%')
    .justifyContent(FlexAlign.Start)
    .margin({ bottom: 6 })
  }

  // ---- 中央控件 -------------------------------------------------------- //

  /**
   * 中央控件（Emby 布局：中间播放，左右快进快退）。
   *
   * 尺寸按「图标占圆的一半以上」定：圆 60 / 图标 34（57%），竖屏全屏圆 52 / 图标 30。
   * 之前圆 56 配 28 的图标、而图标自身图形只占 viewBox 的 37%，看着就是「一个大空圆
   * 里一个小点」—— 现在图形也重画成满幅（见 resources/base/media/ic_back10.svg）。
   */
  @Builder
  CenterBar() {
    Row({ space: this.layout === 'portraitFull' ? 28 : 34 }) {
      Column({ space: 4 }) {
        this.RoundButton($r('app.media.ic_back10'), this.layout === 'portraitFull' ? 30 : 34,
          this.layout === 'portraitFull' ? 52 : 60,
          '#4D000000', '#FFFFFF', () => {
            this.onSeekBy(-this.seekStep);
          })
        // 秒数在圆外（第 5 条），圆里只放图标
        Text(`${this.seekStep}s`)
          .fontSize(10)
          .fontColor('#D9FFFFFF')
      }
      .alignItems(HorizontalAlign.Center)

      Column({ space: 1 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(this.layout === 'portraitFull' ? 62 : 72)
            .height(this.layout === 'portraitFull' ? 62 : 72)
            .borderRadius(36)
            .backgroundColor('#66000000')
            .backdropBlur(22)
            .border({ width: 0.8, color: '#3DFFFFFF' })
          this.PlayIcon(this.layout === 'portraitFull' ? 34 : 40)
        }
        .width(this.layout === 'portraitFull' ? 62 : 72)
        .height(this.layout === 'portraitFull' ? 62 : 72)
        .onClick(() => {
          this.onPlayPause();
        })
      }

      Column({ space: 4 }) {
        this.RoundButton($r('app.media.ic_forward10'), this.layout === 'portraitFull' ? 30 : 34,
          this.layout === 'portraitFull' ? 52 : 60,
          '#4D000000', '#FFFFFF', () => {
            this.onSeekBy(this.seekStep);
          })
        Text(`${this.seekStep}s`)
          .fontSize(10)
          .fontColor('#D9FFFFFF')
      }
      .alignItems(HorizontalAlign.Center)
    }
    .alignItems(VerticalAlign.Center)
  }

  // ---- 进度条 ---------------------------------------------------------- //

  /**
   * 进度条一行。
   *
   * ★ 两侧时间必须 `maxLines(1)` + 稍宽（第 8 条）★
   *   `1:23:45` 在 fontSize 10 / width 40 时会折成两行（横屏右端尤其明显），
   *   看着就像「总时长断了一截」。宽度给到 46，并且禁止换行、超长裁掉。
   */
  @Builder
  SeekRow(compact: boolean) {
    Row({ space: 6 }) {
      Text(clock(this.shownPos()))
        .fontSize(compact ? 9 : 10)
        .fontColor('#E6FFFFFF')
        .maxLines(1)
        .width(compact ? 38 : 46)

      Slider({
        value: this.shownPos(),
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        step: 1
      })
        .layoutWeight(1)
        .selectedColor(Theme.ACCENT)
        .trackColor('#3DFFFFFF')
        .trackThickness(compact ? 2 : 3)
        .blockColor('#FFFFFF')
        .blockSize({ width: compact ? 8 : 11, height: compact ? 8 : 11 })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.onSeekMoving(value);
          } else if (mode === SliderChangeMode.End) {
            this.onSeekEnd(value);
          }
        })

      Text(clock(this.duration))
        .fontSize(compact ? 9 : 10)
        .fontColor('#8CFFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Clip })
        .width(compact ? 38 : 46)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 底栏/工具行里的小图标按钮（横屏那排，纯图标不写文字）。 */
  @Builder
  IcTool(src: Resource, tint: string, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      this.Ic(src, 17, tint)
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor('#4D000000')
    .onClick(() => {
      onTap();
    })
  }

  /**
   * 静音键（用户第 3 条）：有声音 = 喇叭+声波（白），静音 = 喇叭+叉（琥珀）。
   * 两态用**两张图**，不靠 API 着色（见 Ic 的说明）。
   */
  @Builder
  VolumeTool() {
    this.IcTool(this.volume > 0 ? $r('app.media.ic_volume') : $r('app.media.ic_mute_amber'),
      '#FFFFFF', () => {
        this.onMute();
      })
  }

  /**
   * 底栏图标组（横屏 / 竖屏全屏用）。
   *
   * 按用户 2.4.6.20 第 4 条分组：
   *  - 左组 = 字幕 / 音轨 / 音量（贴左下角）
   *  - 右组 = 选集 / 弹幕（贴右下角）
   * 截帧挪到**顶栏右上角**，画中画本来就在顶栏（底栏再放一个就重复了）。
   */
  @Builder
  ToolButtons(side: string) {
    Row({ space: 2 }) {
      if (side === 'left') {
        this.IcTool($r('app.media.ic_subtitle'), '#FFFFFF', () => {
          this.onSubs();
        })
        this.IcTool($r('app.media.ic_audio'), '#FFFFFF', () => {
          this.onAudio();
        })
        this.VolumeTool()
      } else {
        this.IcTool($r('app.media.ic_episodes'), '#FFFFFF', () => {
          this.onPicker();
        })
        this.IcTool($r('app.media.ic_danmaku'), '#FFFFFF', () => {
          this.onAnno();
        })
        if (this.layout === 'portraitFull') {
          this.IcTool($r('app.media.ic_fullscreen'), '#FFFFFF', () => {
            this.onLandscape();
          })
        }
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 收缩态（画面只剩 ~80vp）用的极简条：播放 / 细进度 / 全屏。 */
  @Builder
  MiniBar() {
    Row({ space: 4 }) {
      Row() {
        this.PlayIcon(13)
      }
      .width(24)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onPlayPause();
      })

      Slider({
        value: this.shownPos(),
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        step: 1
      })
        .layoutWeight(1)
        .selectedColor(Theme.ACCENT)
        .trackColor('#4DFFFFFF')
        .trackThickness(2)
        .blockColor('#FFFFFF')
        .blockSize({ width: 9, height: 9 })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.onSeekMoving(value);
          } else if (mode === SliderChangeMode.End) {
            this.onSeekEnd(value);
          }
        })

      Row() {
        this.Ic($r('app.media.ic_fullscreen'), 13, '#E6FFFFFF')
      }
      .width(24)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onToggleFull();
      })
    }
    .width('96%')
    .height(26)
    .padding({ left: 6, right: 6 })
    .borderRadius(13)
    .backgroundColor('#59000000')
    .backdropBlur(16)
    .border({ width: 0.5, color: '#26FFFFFF' })
    .margin({ bottom: 4 })
  }

  @Builder
  CompactBar() {
    // 播放 / 时间 / 进度 / 全屏
    Row({ space: 5 }) {
      Row() {
        this.PlayIcon(13)
      }
      .width(24)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onPlayPause();
      })

      // SeekRow 自己写了 width('100%')，横排里要包一层 layoutWeight
      Column() {
        this.SeekRow(true)
      }
      .layoutWeight(1)

      Row() {
        this.Ic($r('app.media.ic_fullscreen'), 13, '#E6FFFFFF')
      }
      .width(26)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onToggleFull();
      })
    }
    .width('96%')
    .height(28)
    .padding({ left: 6, right: 6 })
    .borderRadius(14)
    .backgroundColor('#33000000')
    .backdropBlur(18)
    .border({ width: 0.6, color: '#26FFFFFF' })
    .margin({ bottom: 6 })
  }

  @Builder
  BottomBar() {
    if (this.isCompact()) {
      if (this.collapsed) {
        this.MiniBar()
      } else {
        Column() {
          this.CompactTools()
          this.CompactBar()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
    } else if (this.layout === 'portraitFull') {
      Column({ space: 4 }) {
        this.SeekRow(false)
        Row() {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(28)
              .height(28)
              .borderRadius(14)
              .backgroundColor(Theme.ACCENT)
            this.PlayIcon(13)
          }
          .width(28)
          .height(28)
          .onClick(() => {
            this.onPlayPause();
          })

          Row() {
            this.ToolButtons('left')
          }
          .margin({ left: 6 })

          Blank()

          this.ToolButtons('right')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('94%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor('#1F000000')
      .backdropBlur(30)
      .border({ width: 0.6, color: '#2EFFFFFF' })
      .shadow({ radius: 18, color: '#66000000', offsetY: 6 })
      .margin({ bottom: 10 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: 10 })))
    } else {
      // 横屏底栏：播放 + 左下组（字幕/音轨/音量）+ 进度条 + 右下组（选集/弹幕）+ 退出全屏
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(Theme.ACCENT)
            .shadow({ radius: 14, color: '#A67C5CFF', offsetY: 2 })
          this.PlayIcon(14)
        }
        .width(32)
        .height(32)
        .onClick(() => {
          this.onPlayPause();
        })

        this.ToolButtons('left')

        Column() {
          this.SeekRow(false)
        }
        .layoutWeight(1)
        .margin({ left: 2, right: 2 })

        this.ToolButtons('right')

        Row() {
          this.Ic($r('app.media.ic_fullscreen_exit'), 14, '#FFFFFF')
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onToggleFull();
        })
      }
      .width('90%')
      .constraintSize({ maxWidth: 780 })
      .height(42)
      .padding({ left: 10, right: 10 })
      .borderRadius(21)
      .backgroundColor('#1F000000')
      .backdropBlur(30)
      .border({ width: 0.6, color: '#2EFFFFFF' })
      .shadow({ radius: 18, color: '#66000000', offsetY: 6 })
      .margin({ bottom: 12 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: 10 })))
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height(this.isCompact() ? (this.collapsed ? 0 : 76) : 110)
        .linearGradient({ angle: 180, colors: [['#59000000', 0.0], ['#00000000', 1.0]] })
        .hitTestBehavior(HitTestMode.None)

      Stack({ alignContent: Alignment.BottomStart }) {
        Column()
          .width('100%')
          .height(this.isCompact() ? (this.collapsed ? 52 : 100) : 140)
          .linearGradient({ angle: 0, colors: [['#66000000', 0.0], ['#00000000', 1.0]] })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      Column() {
        if (!this.collapsed) {
          Row() {
            this.TopBar()
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }

        Blank()

        if (this.bandwidthText.length > 0 && !this.isCompact()) {
          Text(this.bandwidthText)
            .fontSize(9)
            .fontColor(Theme.GOLD)
            .maxLines(2)
            .width('86%')
            .margin({ bottom: 6 })
        }

        Row() {
          this.BottomBar()
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')

      if (!this.isCompact() && !this.collapsed) {
        Column() {
          this.CenterBar()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.speedOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#26000000')
          .onClick(() => {
            this.speedOpen = false;
          })

        Stack({ alignContent: Alignment.TopEnd }) {
          Column() {
            this.SpeedMenu()
          }
          .margin({ top: this.isCompact() ? 44 : 52, right: 10 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
