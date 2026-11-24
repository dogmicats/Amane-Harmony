/**
 * 玻璃扫光骨架屏（2.8.2 美化重构 · P1 升级）。
 *
 * 相比旧版单色灰块呼吸，升级为「深色半透玻璃基座 + 极细受光描边 + 斜向高光扫过（Shimmer）」，
 * 视觉上与全站液态玻璃语言保持同一质感；同时保留 `amaneFxLow` 低电量静止保护。
 * 额外提供 `HeroGlassSkeleton` 与 `HomeGlassSkeleton`，让冷启动/缓存过渡彻底告别孤立转圈与黑洞。
 */
import { Theme } from '../common/Theme';

@Component
export struct SkeletonBlock {
  /** 宽度：'100%' / '60%' 这种百分比字符串，或 '120' 这种定宽。 */
  @Prop w: string = '100%';
  @Prop h: number = 14;
  @Prop radius: number = 8;
  /** 起始节奏错开（ms），让多块骨架波浪式扫过而不呆板齐闪。 */
  @Prop lag: number = 0;
  /** 是否开启 1px 玻璃细描边（大卡开启，细文字条可关闭更清爽）。 */
  @Prop rim: boolean = false;
  @State private sweep: boolean = false;
  @StorageProp('amaneFxLow') private lowPower: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    if (this.lowPower === 1) {
      return;
    }
    this.timer = setInterval(() => {
      this.sweep = !this.sweep;
    }, 1150 + this.lag);
    setTimeout(() => {
      if (this.timer >= 0) {
        this.sweep = true;
      }
    }, 60 + this.lag);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 118,
          colors: this.lowPower === 1
            ? [['#16161F', 0], ['#1D1D28', 0.5], ['#16161F', 1]]
            : (this.sweep
              ? [['#15151E', 0], ['#232332', 0.42], ['#2E2C42', 0.56], ['#16161F', 1]]
              : [['#1B1B26', 0], ['#15151E', 0.48], ['#20202E', 0.86], ['#15151E', 1]])
        })
        .animation({ duration: 1050, curve: Curve.EaseInOut })
    }
    .width(this.w)
    .height(this.h)
    .borderRadius(this.radius)
    .backgroundColor('#16161F')
    .border(this.rim
      ? { width: 0.75, color: '#1AFFFFFF' }
      : { width: 0, color: Color.Transparent })
    .clip(true)
  }
}

/**
 * 首页顶部 Hero 玻璃骨架：缓存首帧或首次冷启时精准占位 `Theme.HERO_H`，
 * 带柔和主色氛围光与底部标题/按钮玻璃占位，不再是一块纯黑空洞。
 */
@Component
export struct HeroGlassSkeleton {
  @State private glowPulse: boolean = false;
  @StorageProp('amaneFxLow') private lowPower: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    if (this.lowPower === 1) {
      return;
    }
    this.timer = setInterval(() => {
      this.glowPulse = !this.glowPulse;
    }, 1800);
    setTimeout(() => {
      if (this.timer >= 0) {
        this.glowPulse = true;
      }
    }, 80);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 145,
          colors: [
            ['#13121C', 0],
            [Theme.accentAlpha(this.glowPulse ? 0.16 : 0.08), 0.48],
            ['#0B0B0F', 1]
          ]
        })
        .animation({ duration: 1700, curve: Curve.EaseInOut })

      Column({ space: 10 }) {
        SkeletonBlock({ w: '32%', h: 20, radius: 10, rim: true })
        Row({ space: 6 }) {
          SkeletonBlock({ w: '72', h: 18, radius: 6, lag: 60 })
          SkeletonBlock({ w: '42', h: 18, radius: 6, lag: 110 })
          SkeletonBlock({ w: '42', h: 18, radius: 6, lag: 150 })
        }
        SkeletonBlock({ w: '74%', h: 24, radius: 8, lag: 90 })
        SkeletonBlock({ w: '48%', h: 16, radius: 6, lag: 140 })
        Row({ space: 10 }) {
          SkeletonBlock({ w: '124', h: 38, radius: 19, lag: 80, rim: true })
          SkeletonBlock({ w: '76', h: 38, radius: 19, lag: 140, rim: true })
          Blank()
          Row({ space: 4 }) {
            SkeletonBlock({ w: '14', h: 4, radius: 2 })
            SkeletonBlock({ w: '4', h: 4, radius: 2 })
            SkeletonBlock({ w: '4', h: 4, radius: 2 })
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 18 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(Theme.HERO_H)
  }
}

/**
 * 首页整屏玻璃骨架：首次冷启动（无本地缓存）时替代孤立小圈转圈，
 * 让真实顶栏 + 6 Tab 底栏第一帧即就位，内容区平滑长出来。
 */
@Component
export struct HomeGlassSkeleton {
  private cards: number[] = [0, 1, 2, 3];

  build() {
    Scroll() {
      Column({ space: 18 }) {
        HeroGlassSkeleton()

        // 甄选条占位
        Column() {
          SkeletonBlock({ w: '100%', h: 64, radius: Theme.R_CARD, lag: 100, rim: true })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

        // 继续观看行占位
        Column({ space: 10 }) {
          Row() {
            SkeletonBlock({ w: '88', h: 18, radius: 6, lag: 80 })
            Blank()
            SkeletonBlock({ w: '42', h: 12, radius: 5, lag: 140 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

          Row({ space: 12 }) {
            ForEach(this.cards, (idx: number) => {
              Column({ space: 6 }) {
                SkeletonBlock({ w: `${Theme.POSTER_W}`, h: Theme.POSTER_H, radius: Theme.R_IMG, lag: idx * 70, rim: true })
                SkeletonBlock({ w: '82', h: 11, radius: 4, lag: idx * 70 + 40 })
                SkeletonBlock({ w: '64', h: 9, radius: 4, lag: idx * 70 + 80 })
              }
              .alignItems(HorizontalAlign.Start)
            }, (idx: number) => `hsk-c-${idx}`)
          }
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 每日推荐横幅占位
        Column({ space: 10 }) {
          Row() {
            SkeletonBlock({ w: '96', h: 18, radius: 6, lag: 120 })
            Blank()
            SkeletonBlock({ w: '64', h: 20, radius: 10, lag: 180 })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

          Row({ space: 12 }) {
            SkeletonBlock({ w: '240', h: 148, radius: Theme.R_IMG, lag: 110, rim: true })
            SkeletonBlock({ w: '240', h: 148, radius: Theme.R_IMG, lag: 190, rim: true })
          }
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column().height(Theme.BOTTOM_SAFE)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
