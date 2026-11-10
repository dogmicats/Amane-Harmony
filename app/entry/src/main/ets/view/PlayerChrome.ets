import { Theme } from '../common/Theme';
import { clock } from '../common/Util';

/**
 * 播放器控制层（纯 ArkUI，不依赖 mpv）。
 *
 * 形态对齐 flymby / HOSPlayer：**两条很薄的悬浮玻璃条**，一条在顶、一条在底，
 * 中间整块留给画面。做法要点：
 *  - 玻璃用 `backdropBlur(radius)`：只模糊"条下面"的内容，再叠一层 8% 的
 *    黑色/白色薄色 —— 视频必须能透出来；`backgroundBlurStyle` 的
 *    COMPONENT_ULTRA_THICK 在深色下几乎是不透明的，会把下面的画面糊成一块，
 *    所以不再用它做底色。
 *  - 高度压到 40 / 56，单行排布；按钮不做大色块（只有播放键是强调色 + 光晕），
 *    避免"一大块"。
 *  - 边框 0.6vp 高光 + 很浅的投影，玻璃边缘才立得住。
 *
 * systemMaterial（沉浸光感材质）按官方限制只在 Navigation 标题栏 / 底部 TabBar /
 * 弹窗类组件生效，普通容器不生效，所以这里不做无效调用。
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

  @Event onBack: () => void = () => {};
  @Event onPlayPause: () => void = () => {};
  @Event onSpeed: () => void = () => {};
  @Event onSeekMoving: (seconds: number) => void = () => {};
  @Event onSeekEnd: (seconds: number) => void = () => {};
  @Event onSubs: () => void = () => {};
  @Event onAudio: () => void = () => {};
  @Event onMute: () => void = () => {};

  private shownPos(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.pos;
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(22)
        .fontColor('#FFFFFF')
        .width(26)
        .height(26)
        .textAlign(TextAlign.Center)
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

      Text(`${this.speed}x`)
        .fontSize(11)
        .fontColor('#E6FFFFFF')
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .backgroundColor('#26FFFFFF')
        .borderRadius(10)
        .onClick(() => {
          this.onSpeed();
        })
    }
    .width('86%')
    .constraintSize({ maxWidth: 760 })
    .height(40)
    .padding({ left: 10, right: 8 })
    .margin({ top: 12 })
    .borderRadius(20)
    .backgroundColor('#1F000000')
    .backdropBlur(26)
    .border({ width: 0.6, color: '#2EFFFFFF' })
    .shadow({ radius: 14, color: '#59000000', offsetY: 4 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
      .combine(TransitionEffect.translate({ y: -8 })))
  }

  @Builder
  BottomBar() {
    Row({ space: 10 }) {
      // 唯一的强调色元素：36 的圆钮 + 外发光
      Stack() {
        Column()
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor(Theme.ACCENT)
          .shadow({ radius: 14, color: '#A67C5CFF', offsetY: 2 })
        Text(this.playing ? '❚❚' : '▶')
          .fontSize(13)
          .fontColor('#FFFFFF')
      }
      .width(36)
      .height(36)
      .onClick(() => {
        this.onPlayPause();
      })

      Text(clock(this.shownPos()))
        .fontSize(11)
        .fontColor('#E6FFFFFF')
        .width(44)

      Slider({
        value: this.shownPos(),
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        step: 1
      })
        .layoutWeight(1)
        .selectedColor(Theme.ACCENT)
        .trackColor('#3DFFFFFF')
        .trackThickness(3)
        .blockColor('#FFFFFF')
        .blockSize({ width: 12, height: 12 })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.onSeekMoving(value);
          } else if (mode === SliderChangeMode.End) {
            this.onSeekEnd(value);
          }
        })

      Text(clock(this.duration))
        .fontSize(11)
        .fontColor('#8CFFFFFF')
        .width(44)
        .textAlign(TextAlign.End)

      Text('字幕')
        .fontSize(11)
        .fontColor('#E6FFFFFF')
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
        .onClick(() => {
          this.onSubs();
        })

      Text('音轨')
        .fontSize(11)
        .fontColor('#E6FFFFFF')
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
        .onClick(() => {
          this.onAudio();
        })

      Text(this.volume > 0 ? '音量' : '静音')
        .fontSize(11)
        .fontColor(this.volume > 0 ? '#E6FFFFFF' : '#FFB454')
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
        .onClick(() => {
          this.onMute();
        })
    }
    .width('86%')
    .constraintSize({ maxWidth: 760 })
    .height(56)
    .padding({ left: 10, right: 10 })
    .borderRadius(28)
    .backgroundColor('#1F000000')
    .backdropBlur(30)
    .border({ width: 0.6, color: '#2EFFFFFF' })
    .shadow({ radius: 18, color: '#66000000', offsetY: 6 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 160 })
      .combine(TransitionEffect.translate({ y: 10 })))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 上下压暗幕：玻璃条本身是透的，亮画面下需要一点点衬底才读得清字
      Column()
        .width('100%')
        .height(120)
        .linearGradient({ angle: 180, colors: [['#59000000', 0.0], ['#00000000', 1.0]] })
        .hitTestBehavior(HitTestMode.None)

      Stack({ alignContent: Alignment.BottomStart }) {
        Column()
          .width('100%')
          .height(150)
          .linearGradient({ angle: 0, colors: [['#66000000', 0.0], ['#00000000', 1.0]] })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      Column() {
        Row() {
          this.TopBar()
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Blank()

        if (this.bandwidthText.length > 0) {
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
        .margin({ bottom: 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
