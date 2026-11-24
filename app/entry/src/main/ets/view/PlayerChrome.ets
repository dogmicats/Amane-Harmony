import { Theme } from '../common/Theme';
import { clock } from '../common/Util';

interface AspectOpt {
  k: string;
  l: string;
}

const ASPECT_OPTS: AspectOpt[] = [
  { k: 'fit', l: '适应' },
  { k: 'fill', l: '铺满' },
  { k: '16:9', l: '16:9' }
];

/**
 * 播放器控制层（纯 ArkUI · 2.8.3 液态玻璃 + 暗夜蔷薇丝绒升级）。
 *
 * 三种形态：
 *  - `compact`     —— 竖屏「顶部 16:9」：悬浮顶栏 + 工具胶囊行 + 迷你播放条
 *  - `portraitFull`—— 竖屏全屏：悬浮顶栏 + 左侧锁屏 + 中央控件 + 两行底栏
 *  - `landscape`   —— 横屏全屏：悬浮顶栏 + 左侧锁屏 + 中央控件 + 单行底栏
 *
 * ★ 图标规则：原有 `ic_*.svg` 绝对不加 `.fillColor()`（会填实线描框）；
 *   需要动态着色的图标（锁屏、勾选、关闭等）一律使用原生 `SymbolGlyph($r('sys.symbol.*'))`。
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
  /** 全屏锁屏状态：锁屏时只显示左侧解锁玻璃键，隐藏其它控件。 */
  @Param locked: boolean = false;
  /** 当前画面比例：'fit' | 'fill' | '16:9'。 */
  @Param aspectMode: string = 'fit';

  @Event onBack: () => void = () => {};
  @Event onPlayPause: () => void = () => {};
  @Event onSeekBy: (delta: number) => void = (delta: number) => {};
  @Event onTempSpeed: (on: boolean) => void = (on: boolean) => {};
  @Event onSpeed: () => void = () => {};
  @Event onPickSpeed: (v: number) => void = (v: number) => {};
  @Event onPickAspect: (mode: string) => void = (mode: string) => {};
  @Event onToggleLock: () => void = () => {};
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

  // ---- 图标（SVG 资源不加 fillColor）----------------------------------- //

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

  /** 圆形液态玻璃按钮（快退 / 快进）。 */
  @Builder
  RoundButton(src: Resource, iconSize: number, boxSize: number, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(boxSize)
        .height(boxSize)
        .borderRadius(boxSize / 2)
        .backgroundColor('#7A100D11')
        .backdropBlur(20)
        .border({ width: 0.75, color: '#38FFFFFF' })
        .shadow({ radius: 14, color: '#66000000', offsetY: 4 })
      this.Ic(src, iconSize, '#FFFFFF')
    }
    .width(boxSize)
    .height(boxSize)
    .alignContent(Alignment.Center)
    .onClick(() => {
      onTap();
    })
  }

  // ---- 倍速与画面浮层（Mockup 2 左下）---------------------------------- //

  @Builder
  SpeedMenu() {
    Column({ space: 8 }) {
      Row() {
        Text('倍速与画面')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor(['#B3FFFFFF'])
        }
        .width(24)
        .height(24)
        .borderRadius(12)
        .backgroundColor('#1FFFFFFF')
        .onClick(() => {
          this.speedOpen = false;
        })
      }
      .width('100%')
      .padding({ left: 4, right: 2 })

      Column({ space: 3 }) {
        ForEach(this.speedOptions, (v: number) => {
          Row() {
            Text(`${v.toFixed(v % 1 === 0 ? 1 : (v * 10 % 1 === 0 ? 1 : 2))}x`)
              .fontSize(12)
              .fontWeight(Math.abs(this.speed - v) < 0.01 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(Math.abs(this.speed - v) < 0.01 ? Theme.ACCENT_INK : '#E6FFFFFF')
              .fontFeature('"tnum" 1')
            Blank()
            if (Math.abs(this.speed - v) < 0.01) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor([Theme.ACCENT_INK])
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor(Math.abs(this.speed - v) < 0.01 ? Theme.accentAlpha(0.20) : '#00000000')
          .border({
            width: Math.abs(this.speed - v) < 0.01 ? 0.75 : 0,
            color: Theme.accentAlpha(0.50)
          })
          .onClick(() => {
            this.onPickSpeed(v);
            this.speedOpen = false;
          })
        }, (v: number) => `sp-${v}`)
      }
      .width('100%')

      Divider()
        .color('#1FFFFFFF')
        .strokeWidth(0.5)

      Column({ space: 6 }) {
        Text('画面比例')
          .fontSize(10)
          .fontColor('#8CFFFFFF')
          .width('100%')
          .padding({ left: 4 })

        Row({ space: 6 }) {
          ForEach(ASPECT_OPTS, (opt: AspectOpt) => {
            Text(opt.l)
              .fontSize(11)
              .fontWeight(this.aspectMode === opt.k ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.aspectMode === opt.k ? Theme.ACCENT_INK : '#D9FFFFFF')
              .layoutWeight(1)
              .height(28)
              .textAlign(TextAlign.Center)
              .borderRadius(10)
              .backgroundColor(this.aspectMode === opt.k ? Theme.accentAlpha(0.22) : '#1AFFFFFF')
              .border({
                width: 0.75,
                color: this.aspectMode === opt.k ? Theme.accentAlpha(0.55) : '#24FFFFFF'
              })
              .onClick(() => {
                this.onPickAspect(opt.k);
                this.speedOpen = false;
              })
          }, (opt: AspectOpt) => `asp-${opt.k}`)
        }
        .width('100%')
      }
      .width('100%')
    }
    .width(196)
    .padding(12)
    .backgroundColor('#D9141016')
    .backdropBlur(28)
    .border({ width: 0.75, color: '#33FFFFFF' })
    .borderRadius(18)
    .shadow({ radius: 24, color: '#80000000', offsetY: 8 })
    .onClick(() => {
      // 吞掉点击，防止冒泡关掉菜单
    })
  }

  // ---- 顶栏（Mockup 1 中 / Mockup 3）----------------------------------- //

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

        Text(this.onAir ? '外网' : '局域网')
          .fontSize(8)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.onAir ? '#FFB454' : '#6EE7B7')
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor(this.onAir ? '#26FFB454' : '#264ADE80')
          .border({ width: 0.5, color: this.onAir ? '#4DFFB454' : '#4D4ADE80' })
          .borderRadius(6)

        Blank()

        Text(`${this.speed}x`)
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .fontFeature('"tnum" 1')
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(Theme.accentAlpha(0.20))
          .border({ width: 0.6, color: Theme.accentAlpha(0.50) })
          .borderRadius(10)
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
      .height(34)
      .padding({ left: 6, right: 8 })
      .margin({ top: 6 })
      .borderRadius(17)
      .backgroundColor('#85100D11')
      .backdropBlur(24)
      .border({ width: 0.75, color: '#2EFFFFFF' })
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
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)

        Text(this.onAir ? '外网' : '局域网')
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.onAir ? '#FFB454' : '#6EE7B7')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(this.onAir ? '#26FFB454' : '#264ADE80')
          .border({ width: 0.5, color: this.onAir ? '#4DFFB454' : '#4D4ADE80' })
          .borderRadius(8)

        if (this.fileName.length > 0) {
          Text(`· ${this.fileName}`)
            .fontSize(10)
            .fontColor('#99FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank()
        }

        if (this.diagnostics.length > 0) {
          Text(this.diagnostics)
            .fontSize(9)
            .fontColor('#80FFFFFF')
            .fontFeature('"tnum" 1')
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
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT_INK)
          .fontFeature('"tnum" 1')
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .backgroundColor(Theme.accentAlpha(0.22))
          .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
          .borderRadius(12)
          .onClick(() => {
            this.speedOpen = !this.speedOpen;
          })
      }
      .width('88%')
      .constraintSize({ maxWidth: 780 })
      .height(38)
      .padding({ left: 8, right: 10 })
      .margin({ top: 10 })
      .borderRadius(19)
      .backgroundColor('#85100D11')
      .backdropBlur(28)
      .border({ width: 0.75, color: '#33FFFFFF' })
      .shadow({ radius: 18, color: '#73000000', offsetY: 5 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: -8 })))
    }
  }

  // ---- 竖屏工具行（字幕 / 截帧 / 弹幕）-------------------------------- //

  @Builder
  ToolIcon(src: Resource, size: number, box: number, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      this.Ic(src, size, '#FFFFFF')
    }
    .width(box)
    .height(box)
    .borderRadius(box / 2)
    .backgroundColor('#85100D11')
    .backdropBlur(18)
    .border({ width: 0.75, color: '#38FFFFFF' })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  CompactTools() {
    Row({ space: 8 }) {
      this.ToolIcon($r('app.media.ic_subtitle'), 18, 34, () => {
        this.onSubs();
      })
      this.ToolIcon($r('app.media.ic_snap'), 18, 34, () => {
        this.onSnap();
      })
      this.ToolIcon($r('app.media.ic_danmaku'), 18, 34, () => {
        this.onAnno();
      })
    }
    .width('96%')
    .justifyContent(FlexAlign.Start)
    .margin({ bottom: 6 })
  }

  // ---- 中央控件（Mockup 3）-------------------------------------------- //

  @Builder
  CenterBar() {
    Row({ space: this.layout === 'portraitFull' ? 28 : 36 }) {
      Column({ space: 5 }) {
        this.RoundButton($r('app.media.ic_back10'), this.layout === 'portraitFull' ? 28 : 32,
          this.layout === 'portraitFull' ? 50 : 56, () => {
            this.onSeekBy(-this.seekStep);
          })
        Text(`${this.seekStep}s`)
          .fontSize(10)
          .fontColor('#E6FFFFFF')
          .fontFeature('"tnum" 1')
      }
      .alignItems(HorizontalAlign.Center)

      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(this.layout === 'portraitFull' ? 62 : 70)
          .height(this.layout === 'portraitFull' ? 62 : 70)
          .borderRadius(35)
          .linearGradient(Theme.ctaGradient())
          .opacity(0.88)
          .border({ width: 1, color: '#59FFFFFF' })
          .shadow({ radius: 22, color: Theme.accentAlpha(0.48), offsetY: 4 })
        this.PlayIcon(this.layout === 'portraitFull' ? 30 : 34)
      }
      .width(this.layout === 'portraitFull' ? 62 : 70)
      .height(this.layout === 'portraitFull' ? 62 : 70)
      .onClick(() => {
        this.onPlayPause();
      })

      Column({ space: 5 }) {
        this.RoundButton($r('app.media.ic_forward10'), this.layout === 'portraitFull' ? 28 : 32,
          this.layout === 'portraitFull' ? 50 : 56, () => {
            this.onSeekBy(this.seekStep);
          })
        Text(`${this.seekStep}s`)
          .fontSize(10)
          .fontColor('#E6FFFFFF')
          .fontFeature('"tnum" 1')
      }
      .alignItems(HorizontalAlign.Center)
    }
    .alignItems(VerticalAlign.Center)
  }

  // ---- 进度条（等宽数字防跳动）---------------------------------------- //

  @Builder
  SeekRow(compact: boolean) {
    Row({ space: 6 }) {
      Text(clock(this.shownPos()))
        .fontSize(compact ? 9 : 10)
        .fontColor('#F2FFFFFF')
        .fontFeature('"tnum" 1')
        .maxLines(1)
        .width(compact ? 42 : 50)

      Slider({
        value: this.shownPos(),
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        step: 1
      })
        .layoutWeight(1)
        .selectedColor(Theme.ACCENT)
        .trackColor('#3DFFFFFF')
        .trackThickness(compact ? 2.5 : 3.5)
        .blockColor('#FFFFFF')
        .blockSize({ width: compact ? 9 : 12, height: compact ? 9 : 12 })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.onSeekMoving(value);
          } else if (mode === SliderChangeMode.End) {
            this.onSeekEnd(value);
          }
        })

      Text(clock(this.duration))
        .fontSize(compact ? 9 : 10)
        .fontColor('#99FFFFFF')
        .fontFeature('"tnum" 1')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Clip })
        .width(compact ? 42 : 50)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  IcTool(src: Resource, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      this.Ic(src, 17, '#FFFFFF')
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor('#33FFFFFF')
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  VolumeTool() {
    this.IcTool(this.volume > 0 ? $r('app.media.ic_volume') : $r('app.media.ic_mute_amber'), () => {
      this.onMute();
    })
  }

  @Builder
  ToolButtons(side: string) {
    Row({ space: 4 }) {
      if (side === 'left') {
        this.IcTool($r('app.media.ic_subtitle'), () => {
          this.onSubs();
        })
        this.IcTool($r('app.media.ic_audio'), () => {
          this.onAudio();
        })
        this.VolumeTool()
      } else {
        this.IcTool($r('app.media.ic_episodes'), () => {
          this.onPicker();
        })
        this.IcTool($r('app.media.ic_danmaku'), () => {
          this.onAnno();
        })
        if (this.layout === 'portraitFull') {
          this.IcTool($r('app.media.ic_fullscreen'), () => {
            this.onLandscape();
          })
        }
      }
    }
    .alignItems(VerticalAlign.Center)
  }

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
    .backgroundColor('#85100D11')
    .backdropBlur(18)
    .border({ width: 0.6, color: '#2EFFFFFF' })
    .margin({ bottom: 4 })
  }

  @Builder
  CompactBar() {
    Row({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(24)
          .height(24)
          .borderRadius(12)
          .linearGradient(Theme.ctaGradient())
        this.PlayIcon(11)
      }
      .width(24)
      .height(24)
      .onClick(() => {
        this.onPlayPause();
      })

      Column() {
        this.SeekRow(true)
      }
      .layoutWeight(1)

      Row() {
        this.Ic($r('app.media.ic_fullscreen'), 14, '#E6FFFFFF')
      }
      .width(26)
      .height(24)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onToggleFull();
      })
    }
    .width('96%')
    .height(32)
    .padding({ left: 6, right: 6 })
    .borderRadius(16)
    .backgroundColor('#85100D11')
    .backdropBlur(24)
    .border({ width: 0.75, color: '#2EFFFFFF' })
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
      Column({ space: 6 }) {
        this.SeekRow(false)
        Row() {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(30)
              .height(30)
              .borderRadius(15)
              .linearGradient(Theme.ctaGradient())
              .shadow({ radius: 12, color: Theme.accentAlpha(0.42), offsetY: 2 })
            this.PlayIcon(13)
          }
          .width(30)
          .height(30)
          .onClick(() => {
            this.onPlayPause();
          })

          Row() {
            this.ToolButtons('left')
          }
          .margin({ left: 8 })

          Blank()

          this.ToolButtons('right')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('94%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor('#85100D11')
      .backdropBlur(28)
      .border({ width: 0.75, color: '#33FFFFFF' })
      .shadow({ radius: 18, color: '#73000000', offsetY: 6 })
      .margin({ bottom: 10 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: 10 })))
    } else {
      // 横屏底栏（Mockup 3）：蔷薇渐变播放键 + 左组 + 进度条 + 右组 + 退出全屏
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(32)
            .height(32)
            .borderRadius(16)
            .linearGradient(Theme.ctaGradient())
            .shadow({ radius: 14, color: Theme.accentAlpha(0.45), offsetY: 2 })
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
          this.Ic($r('app.media.ic_fullscreen_exit'), 15, '#FFFFFF')
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor('#26FFFFFF')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onToggleFull();
        })
      }
      .width('90%')
      .constraintSize({ maxWidth: 800 })
      .height(44)
      .padding({ left: 10, right: 10 })
      .borderRadius(22)
      .backgroundColor('#85100D11')
      .backdropBlur(28)
      .border({ width: 0.75, color: '#33FFFFFF' })
      .shadow({ radius: 20, color: '#73000000', offsetY: 6 })
      .margin({ bottom: 12 })
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
        .combine(TransitionEffect.translate({ y: 10 })))
    }
  }

  /** 全屏左侧浮动锁屏键（Mockup 3）。 */
  @Builder
  LockButton() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.locked ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open'))
        .fontSize(17)
        .fontColor([this.locked ? Theme.ACCENT_INK : '#E6FFFFFF'])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(this.locked ? Theme.accentAlpha(0.28) : '#7A100D11')
    .backdropBlur(22)
    .border({
      width: 0.75,
      color: this.locked ? Theme.accentAlpha(0.68) : '#38FFFFFF'
    })
    .shadow({ radius: 14, color: this.locked ? Theme.accentAlpha(0.35) : '#66000000', offsetY: 4 })
    .onClick(() => {
      this.onToggleLock();
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.locked) {
        Column()
          .width('100%')
          .height(this.isCompact() ? (this.collapsed ? 0 : 76) : 112)
          .linearGradient({ angle: 180, colors: [['#5E000000', 0.0], ['#00000000', 1.0]] })
          .hitTestBehavior(HitTestMode.None)

        Stack({ alignContent: Alignment.BottomStart }) {
          Column()
            .width('100%')
            .height(this.isCompact() ? (this.collapsed ? 52 : 100) : 144)
            .linearGradient({ angle: 0, colors: [['#6B000000', 0.0], ['#00000000', 1.0]] })
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
      }

      // 全屏左侧锁屏键（锁屏时仅保留此键供解锁）
      if (!this.isCompact() && !this.collapsed) {
        Column() {
          this.LockButton()
        }
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ left: 16 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.speedOpen && !this.locked) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            this.speedOpen = false;
          })

        Stack({ alignContent: Alignment.TopEnd }) {
          Column() {
            this.SpeedMenu()
          }
          .margin({ top: this.isCompact() ? 46 : 56, right: 16 })
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
