import { router } from '@kit.ArkUI';
import { Theme, THEME_PALETTES, ThemePalette } from '../common/Theme';
import { Personalize, COLS_MIN, COLS_MAX, STILL_MIN, STILL_MAX } from '../common/Personalize';
import { Store } from '../common/Store';

/**
 * 外观（2.5.2）：主题色 + 海报列数 + 瀑布流列数。
 *
 * 值都存本地（换机不跟随）。换色会改 `Theme.ACCENT` 并 +1 主题版本号，
 * `Index` 看到版本号变化就整棵树重建。
 *
 * **本页必须自己做到「点一下立刻变」**（两轮踩了同一个坑）：
 *   - 第一轮：色卡的选中勾是 `@Builder` 接收 `picked` 布尔值 —— ArkUI 的 @Builder
 *     是**按值传参**，父组件重绘时它不会因为参数变了而重跑。
 *     修法：色卡 / 列数块改成独立 `@Component` + `@Prop`。
 *   - 第二轮（2.5.1.19）：勾会变了，但**预览块还是退出重进才变色**。
 *     根因是同一个：预览块当时只读 `Theme.ACCENT` / `Theme.ACCENT_SOFT` 这类
 *     **静态字段**。静态字段不是可观察状态，点色卡时没有任何节点「依赖」它，
 *     框架就不会把这几块标脏，自然不重绘。
 *     修法：颜色统一由本页的 `@State pal` 传进子组件（`ThemePreview` / `CountChip`），
 *     `pal` 一变，所有读过它的节点一起重绘。
 *
 * 结论（写死在规范里）：**「点一下就要变」的颜色，绝不能直接读 `Theme.ACCENT`，
 * 要么从 @State 传进去，要么让父级整棵重建。**
 */

/** 单个色卡：渐变圆点 + 名字。独立组件是为了让 @Prop 生效（见文件头注释）。 */
@Component
struct Swatch {
  @Prop palette: ThemePalette;
  @Prop picked: boolean;
  onPick: (key: string) => void = (key: string) => {};

  build() {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(38)
          .height(38)
          .borderRadius(19)
          .linearGradient({
            angle: 140,
            colors: [[this.palette.accent, 0.0], [this.palette.accent2, 1.0]]
          })
        if (this.picked) {
          Text('✓')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette.onAccent)
        }
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .border({ width: this.picked ? 2 : 0.5, color: this.picked ? Theme.TEXT : '#1FFFFFFF' })

      Text(this.palette.name)
        .fontSize(10)
        .fontColor(this.picked ? Theme.TEXT : Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .width('25%')
    .padding({ top: 2, bottom: 2 })
    .onClick(() => {
      this.onPick(this.palette.key);
    })
  }
}

/**
 * 列数选择块：一排小竖条示意「几列」，比只写「三列」好认。
 * `fluid` = 瀑布流：小条高度做得错落，暗示这不是整齐网格。
 */
@Component
struct CountChip {
  @Prop n: number = 2;
  @Prop current: number = 3;
  @Prop label: string = '';
  @Prop fluid: boolean = false;
  /** 强调色也从外面传入：本块会在换色时重绘（见文件头第二条注释）。 */
  @Prop accent: string = Theme.ACCENT;
  @Prop soft: string = Theme.ACCENT_SOFT;
  onPick: (n: number) => void = (n: number) => {};

  private bars(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.n; i++) {
      out.push(i);
    }
    return out;
  }

  /** 瀑布流示意用的错落高度。 */
  private barH(i: number): number {
    if (!this.fluid) {
      return 20;
    }
    const mod: number = i % 3;
    if (mod === 0) {
      return 20;
    }
    if (mod === 1) {
      return 13;
    }
    return 17;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 2 }) {
        ForEach(this.bars(), (i: number) => {
          Column()
            .layoutWeight(1)
            .height(this.barH(i))
            .backgroundColor(this.current === this.n ? this.accent : Theme.CARD_HI)
            .borderRadius(2)
        }, (i: number) => `bar-${this.n}-${i}`)
      }
      .width('100%')
      .height(20)
      .alignItems(VerticalAlign.Top)

      Text(this.label)
        .fontSize(10)
        .fontColor(this.current === this.n ? Theme.TEXT : Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ left: 5, right: 5, top: 8, bottom: 7 })
    .borderRadius(10)
    .backgroundColor(this.current === this.n ? this.soft : Theme.CARD)
    .border({ width: this.current === this.n ? 1 : 0, color: this.accent })
    .onClick(() => {
      this.onPick(this.n);
    })
  }
}

/**
 * 真界面预览：色卡只证明「这个色存在」，这块证明「用起来长什么样」。
 *
 * **颜色必须从 @Prop 进来，不能在 build 里读 `Theme.ACCENT`**：
 * 静态字段不可观察，点色卡时框架不会把这块标脏，就只剩「退出重进才变」
 * （2.5.1.19 修的就是这个）。
 */
@Component
struct ThemePreview {
  @Prop accent: string = Theme.ACCENT;
  @Prop accent2: string = Theme.ACCENT2;
  @Prop soft: string = Theme.ACCENT_SOFT;
  @Prop onAccent: string = Theme.ON_ACCENT;

  build() {
    Column({ space: 11 }) {
      Row({ space: 10 }) {
        // 一张迷你海报：底用当前色压暗，避免只是个灰块
        Column()
          .width(42)
          .height(58)
          .borderRadius(7)
          .linearGradient({
            angle: 160,
            colors: [[this.soft, 0.0], [Theme.CARD_HI, 0.72], [Theme.CARD, 1.0]]
          })
          .border({ width: 0.5, color: Theme.alphaOf(this.accent, 0.45) })

        Column({ space: 5 }) {
          Text('预览 · 视频详情')
            .fontSize(12)
            .fontColor(Theme.TEXT)
          Row({ space: 5 }) {
            Text('已选中')
              .fontSize(9)
              .fontColor(this.onAccent)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor(this.accent)
              .borderRadius(7)
            Text('标签底')
              .fontSize(9)
              .fontColor(this.accent)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor(this.soft)
              .borderRadius(7)
            Text('★ 4.5')
              .fontSize(9)
              .fontColor(Theme.GOLD)
          }
          Row() {
            Text('▶ 立即播放')
              .fontSize(10)
              .fontColor(this.onAccent)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(11)
              .linearGradient({
                angle: 120,
                colors: [[this.accent, 0.0], [this.accent2, 1.0]]
              })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 进度条：强调色在播放器 chrome 里的样子
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(3)
          .borderRadius(2)
          .backgroundColor('#26FFFFFF')
        Column()
          .width('62%')
          .height(3)
          .borderRadius(2)
          .linearGradient({
            angle: 90,
            colors: [[this.accent, 0.0], [this.accent2, 1.0]]
          })
      }
      .width('100%')
      .height(3)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.BG_RAISED)
    .borderRadius(14)
    .border({ width: 0.5, color: Theme.alphaOf(this.accent, 0.22) })
  }
}

@Entry
@Component
struct SettingsAppearancePage {
  /** 即时反馈用：点完立刻高亮，不等静态字段下次被读取。 */
  @State pickedKey: string = Theme.paletteKey;
  /**
   * 本页所有「会跟着主题变」的颜色都从这里取（`@State` 才能让节点重绘）。
   * 不要改回 `Theme.ACCENT` 直读 —— 那正是「预览要重进才刷新」的原因。
   */
  @State pal: ThemePalette = Theme.paletteOf(Theme.paletteKey);
  @StorageProp('amaneThemeEpoch') @Watch('onEpoch') themeEpoch: number = 0;
  @StorageProp('amaneCols') posterCols: number = 3;
  @StorageProp('amaneStillCols') stillCols: number = 2;

  aboutToAppear(): void {
    this.pal = Theme.paletteOf(Theme.paletteKey);
    this.pickedKey = this.pal.key;
  }

  /** 别处换了主题（理论上没有），同步一下选中态。 */
  onEpoch(): void {
    this.pal = Theme.paletteOf(Theme.paletteKey);
    this.pickedKey = this.pal.key;
  }

  /** 点色卡：先换本页状态（立刻重绘），再落盘 + 通知外面。 */
  private pickTheme(key: string): void {
    this.pickedKey = key;
    this.pal = Theme.paletteOf(key);
    Personalize.applyTheme(key);
  }

  private range(from: number, to: number): number[] {
    const out: number[] = [];
    for (let n = from; n <= to; n++) {
      out.push(n);
    }
    return out;
  }

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('外观')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('主题色与列数，只存这台设备')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 18 }) {

          Column({ space: 10 }) {
            Row() {
              Text('主题色')
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .letterSpacing(1)
              Blank()
              Text(this.pal.hint)
                .fontSize(10)
                .fontColor(this.pal.accent)
            }
            .width('100%')

            Column({ space: 12 }) {
              // 8 套分两行：一行 8 个会挤成小点，两行四列才点得准
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(THEME_PALETTES, (p: ThemePalette) => {
                  Swatch({
                    palette: p,
                    picked: this.pickedKey === p.key,
                    onPick: (key: string) => {
                      this.pickTheme(key);
                    }
                  })
                }, (p: ThemePalette) => `pal-${p.key}`)
              }
              .width('100%')

              ThemePreview({
                accent: this.pal.accent,
                accent2: this.pal.accent2,
                soft: this.pal.soft,
                onAccent: this.pal.onAccent
              })

              Text('换完立刻生效，返回任何页面都是新颜色；底色不动，只换强调色。')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }
          .width('100%')

          Column({ space: 10 }) {
            Text('海报列数')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .letterSpacing(1)
              .width('100%')

            Column({ space: 10 }) {
              Row({ space: 8 }) {
                ForEach(this.range(COLS_MIN, COLS_MAX), (n: number) => {
                  CountChip({
                    n: n,
                    current: this.posterCols,
                    label: Personalize.colsName(n),
                    fluid: false,
                    accent: this.pal.accent,
                    soft: this.pal.soft,
                    onPick: (v: number) => {
                      Personalize.setCols(v);
                    }
                  })
                }, (n: number) => `col-${n}`)
              }
              .width('100%')

              Text('媒体库 / 收藏 / 搜索 / 演员 / 标签 / 观看记录 / 稍后再看 / 同番号 —— 全部跟着变。在列表页双指一捏（或张开）也能切。')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }
          .width('100%')

          Column({ space: 10 }) {
            Text('剧照瀑布流')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .letterSpacing(1)
              .width('100%')

            Column({ space: 10 }) {
              Row({ space: 8 }) {
                ForEach(this.range(STILL_MIN, STILL_MAX), (n: number) => {
                  CountChip({
                    n: n,
                    current: this.stillCols,
                    label: Personalize.stillsName(n),
                    fluid: true,
                    accent: this.pal.accent,
                    soft: this.pal.soft,
                    onPick: (v: number) => {
                      Personalize.setStills(v);
                    }
                  })
                }, (n: number) => `still-${n}`)
              }
              .width('100%')

              Text('抽卡墙、演员盲盒、影片剧照 —— 三处是同一套瀑布流，这里改一次全变。单列是满屏大图，四列是缩略图联系表；在瀑布流上双指捏合也能切。')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
