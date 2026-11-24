import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { Theme, THEME_PALETTES, ThemePalette } from '../common/Theme';
import { Personalize, COLS_MIN, COLS_MAX, STILL_MIN, STILL_MAX } from '../common/Personalize';
import { Store } from '../common/Store';
import { Haptics } from '../common/Haptics';
import { ImmersiveGlass } from '../common/ImmersiveGlass';
import { cacheReadStale } from '../common/PageCache';
import { HOME_BOOT_CACHE_KEY } from '../common/Motion';
import { HomeData } from '../common/Types';
import { safeHome } from '../common/Safe';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsIconTile, SettingsRowDivider, SettingsSectionTitle
} from '../view/SettingsKit';

/**
 * 外观与布局（2.8.2 重构）：
 *  - 统一全屏沉浸式液态玻璃顶栏 + 实时变色氛围光晕；
 *  - 顶部电影级实时预览卡（优先用本地缓存海报，回退暗夜电影渐层）；
 *  - 8 套暗夜丝绒色盘 + 合并式布局密度卡 + 顶栏材质 + 触感反馈。
 *  - 本页所有随主题变化的颜色均经 `@State pal` 传入，保证点色卡即刻全页重绘。
 */

/** 单个珠宝色卡：渐变圆盘 + 选中发光环与原生勾 + 主题名。 */
@Component
struct Swatch {
  @Prop palette: ThemePalette;
  @Prop picked: boolean;
  onPick: (key: string) => void = (key: string) => {};

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(40)
          .height(40)
          .borderRadius(20)
          .linearGradient({
            angle: 135,
            colors: [[this.palette.accent, 0.0], [this.palette.accent2, 1.0]]
          })
          .shadow(this.picked
            ? { radius: 14, color: Theme.alphaOf(this.palette.accent, 0.55), offsetX: 0, offsetY: 2 }
            : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
        if (this.picked) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor([this.palette.onAccent])
        }
      }
      .width(48)
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.picked ? Theme.alphaOf(this.palette.accent, 0.16) : Color.Transparent)
      .border({ width: this.picked ? 1.5 : 0.5, color: this.picked ? this.palette.ink : '#1EFFFFFF' })

      Text(this.palette.name)
        .fontSize(11)
        .fontWeight(this.picked ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.picked ? this.palette.ink : Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .width('25%')
    .padding({ top: 4, bottom: 6 })
    .onClick(() => {
      this.onPick(this.palette.key);
    })
  }
}

/** 列数选择块（海报列数 / 剧照瀑布流共用）：迷你竖条示意 + 丝绒半透选态。 */
@Component
struct CountChip {
  @Prop n: number = 2;
  @Prop current: number = 3;
  @Prop label: string = '';
  @Prop fluid: boolean = false;
  @Prop accent: string = Theme.ACCENT;
  @Prop ink: string = Theme.ACCENT_INK;
  @Prop cardHi: string = Theme.CARD_HI;
  onPick: (n: number) => void = (n: number) => {};

  private bars(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.n; i++) {
      out.push(i);
    }
    return out;
  }

  private barH(i: number): number {
    if (!this.fluid) {
      return 16;
    }
    const mod: number = i % 3;
    if (mod === 0) {
      return 16;
    }
    if (mod === 1) {
      return 10;
    }
    return 13;
  }

  build() {
    Column({ space: 5 }) {
      Row({ space: 2 }) {
        ForEach(this.bars(), (i: number) => {
          Column()
            .layoutWeight(1)
            .height(this.barH(i))
            .backgroundColor(this.current === this.n ? this.ink : '#4DFFFFFF')
            .borderRadius(2)
        }, (i: number) => `bar-${this.n}-${i}`)
      }
      .width('100%')
      .height(16)
      .alignItems(VerticalAlign.Top)

      Text(this.label)
        .fontSize(10)
        .fontWeight(this.current === this.n ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.current === this.n ? this.ink : Theme.TEXT_FAINT)
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ left: 6, right: 6, top: 8, bottom: 7 })
    .borderRadius(12)
    .backgroundColor(this.current === this.n ? Theme.alphaOf(this.accent, 0.20) : this.cardHi)
    .border({
      width: this.current === this.n ? 0.75 : 0.5,
      color: this.current === this.n ? Theme.alphaOf(this.ink, 0.52) : '#14FFFFFF'
    })
    .onClick(() => {
      this.onPick(this.n);
    })
  }
}

/** 电影级实时预览卡：真实微缩海报 + 丝绒胶囊 + 宝石渐变播放钮 + 进度条。 */
@Component
struct ThemePreview {
  @Prop themeName: string = '蔷薇';
  @Prop accent: string = Theme.ACCENT;
  @Prop accent2: string = Theme.ACCENT2;
  @Prop ink: string = Theme.ACCENT_INK;
  @Prop soft: string = Theme.ACCENT_SOFT;
  @Prop onAccent: string = Theme.ON_ACCENT;
  @Prop bgRaised: string = Theme.BG_RAISED;
  @Prop card: string = Theme.CARD;
  @Prop cardHi: string = Theme.CARD_HI;
  @Prop posterUrl: string = '';
  @Prop sampleTitle: string = '私人影院 · 暗夜预览';

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        // 左侧微缩电影海报（有本地缓存则显示真海报，无缓存则呈现暗夜主题胶片渐层）
        Stack({ alignContent: Alignment.Center }) {
          if (this.posterUrl.length > 0) {
            Image(Store.I.img(this.posterUrl))
              .width(56)
              .height(82)
              .objectFit(ImageFit.Cover)
          } else {
            Column()
              .width(56)
              .height(82)
              .linearGradient({
                angle: 155,
                colors: [[this.soft, 0.0], [this.cardHi, 0.60], [this.card, 1.0]]
              })
            SymbolGlyph($r('sys.symbol.film'))
              .fontSize(22)
              .fontColor([Theme.alphaOf(this.ink, 0.68)])
          }
        }
        .width(56)
        .height(82)
        .borderRadius(10)
        .clip(true)
        .border({ width: 0.75, color: Theme.alphaOf(this.ink, 0.36) })

        Column({ space: 6 }) {
          Text(`实时预览 · ${this.themeName}暗夜`)
            .fontSize(10.5)
            .fontColor(Theme.TEXT_DIM)

          Row({ space: 5 }) {
            Text('已选中')
              .fontSize(9.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.ink)
              .padding({ left: 8, right: 8, top: 2.5, bottom: 2.5 })
              .backgroundColor(Theme.alphaOf(this.accent, 0.22))
              .border({ width: 0.5, color: Theme.alphaOf(this.ink, 0.52) })
              .borderRadius(Theme.R_PILL)
            Text('中字')
              .fontSize(9.5)
              .fontColor(Theme.TEXT_DIM)
              .padding({ left: 8, right: 8, top: 2.5, bottom: 2.5 })
              .backgroundColor(this.cardHi)
              .border({ width: 0.5, color: '#1EFFFFFF' })
              .borderRadius(Theme.R_PILL)
            Row({ space: 2 }) {
              SymbolGlyph($r('sys.symbol.star_fill'))
                .fontSize(9)
                .fontColor([Theme.GOLD])
              Text('4.8')
                .fontSize(9.5)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.GOLD)
                .fontFeature('"tnum" 1')
            }
            .padding({ left: 6, right: 7, top: 2, bottom: 2 })
            .backgroundColor('#1FFFD06B')
            .border({ width: 0.5, color: '#38FFD06B' })
            .borderRadius(Theme.R_PILL)
            .alignItems(VerticalAlign.Center)
          }

          Text(this.sampleTitle)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row({ space: 7 }) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(10)
                .fontColor([this.onAccent])
              Text('立即播放')
                .fontSize(10.5)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.onAccent)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(Theme.R_PILL)
            .linearGradient({
              angle: 132,
              colors: [[this.accent, 0.0], [this.accent2, 1.0]]
            })
            .border({ width: 0.5, color: '#38FFFFFF' })

            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.heart_fill'))
                .fontSize(10)
                .fontColor([this.ink])
              Text('已收藏')
                .fontSize(10.5)
                .fontColor(Theme.TEXT)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(Theme.R_PILL)
            .backgroundColor(Theme.alphaOf(this.accent, 0.16))
            .border({ width: 0.5, color: Theme.alphaOf(this.ink, 0.42) })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 渐变播放进度条 + 发光圆点
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(3.5)
          .borderRadius(2)
          .backgroundColor('#22FFFFFF')
        Row() {
          Column()
            .layoutWeight(1)
            .height(3.5)
            .borderRadius(2)
            .linearGradient({
              angle: 90,
              colors: [[this.accent, 0.0], [this.accent2, 1.0]]
            })
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor('#FFFFFF')
            .shadow({ radius: 6, color: Theme.alphaOf(this.accent2, 0.80), offsetX: 0, offsetY: 0 })
            .margin({ left: -4 })
        }
        .width('64%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(10)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.bgRaised)
    .linearGradient({
      angle: 145,
      colors: [[Theme.alphaOf(this.accent, 0.15), 0.0], ['#00000000', 0.62]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.alphaOf(this.ink, 0.28) })
  }
}

/** 顶栏材质四档选择块。 */
@Component
struct FxChip {
  @Prop label: string = '';
  @Prop sub: string = '';
  @Prop picked: boolean = false;
  @Prop accent: string = Theme.ACCENT;
  @Prop ink: string = Theme.ACCENT_INK;
  @Prop cardHi: string = Theme.CARD_HI;
  onPick: () => void = () => {};

  build() {
    Column({ space: 3 }) {
      Text(this.label)
        .fontSize(12.5)
        .fontWeight(this.picked ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.picked ? this.ink : Theme.TEXT)
      Text(this.sub)
        .fontSize(9.5)
        .fontColor(this.picked ? this.ink : Theme.TEXT_FAINT)
        .opacity(this.picked ? 0.80 : 1)
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.picked ? Theme.alphaOf(this.accent, 0.20) : this.cardHi)
    .border({
      width: this.picked ? 0.75 : 0.5,
      color: this.picked ? Theme.alphaOf(this.ink, 0.52) : '#14FFFFFF'
    })
    .onClick(() => {
      this.onPick();
    })
  }
}

@Entry
@Component
struct SettingsAppearancePage {
  @State pickedKey: string = Theme.paletteKey;
  @State pal: ThemePalette = Theme.paletteOf(Theme.paletteKey);
  @State previewPoster: string = '';
  @State previewTitle: string = '私人影院 · 暗夜预览';
  @StorageProp('amaneThemeEpoch') @Watch('onEpoch') themeEpoch: number = 0;
  @StorageProp('amaneCols') posterCols: number = 3;
  @StorageProp('amaneStillCols') stillCols: number = 2;
  @StorageProp('amaneFx') fx: number = 2;
  @StorageProp('amaneHaptic') haptic: number = 1;
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State glassMode: string = ImmersiveGlass.mode();
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.pal = Theme.paletteOf(Theme.paletteKey);
    this.pickedKey = this.pal.key;
    this.glassMode = ImmersiveGlass.mode();
    this.loadSamplePoster();
  }

  /** 从本地首页缓存取一张现成海报给实时预览卡，不发额外网络请求。 */
  private loadSamplePoster(): void {
    try {
      const raw: string | undefined = cacheReadStale(HOME_BOOT_CACHE_KEY);
      if (raw === undefined || raw.length === 0) {
        return;
      }
      const home: HomeData = safeHome(JSON.parse(raw) as HomeData);
      const list = home.hero.length > 0 ? home.hero : (home.continue.length > 0 ? home.continue : home.recommend);
      if (list.length > 0) {
        const first = list[0];
        if (first.poster.length > 0) {
          this.previewPoster = first.poster;
        }
        if (first.title.length > 0) {
          this.previewTitle = first.title;
        } else if (first.number.length > 0) {
          this.previewTitle = first.number;
        }
      }
    } catch (e) {
      // 缓存为空或格式变化时静默回退默认暗夜胶片卡
    }
  }

  onEpoch(): void {
    this.pal = Theme.paletteOf(Theme.paletteKey);
    this.pickedKey = this.pal.key;
  }

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
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
            router.back();
          }
        })
        PageTitle({ text: '外观与布局', fs: 18 })
        Blank()
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

  private barH(): number {
    return this.topInset + 46;
  }

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
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow({ accent: this.pal.accent })

        Scroll() {
          Column({ space: 16 }) {
            Blank().height(this.barH() + 6)

            // 顶部电影级实时预览卡
            ThemePreview({
              themeName: this.pal.name,
              accent: this.pal.accent,
              accent2: this.pal.accent2,
              ink: this.pal.ink,
              soft: this.pal.soft,
              onAccent: this.pal.onAccent,
              bgRaised: this.pal.bgRaised,
              card: this.pal.card,
              cardHi: this.pal.cardHi,
              posterUrl: this.previewPoster,
              sampleTitle: this.previewTitle
            })

            // 主题色盘
            Column({ space: 8 }) {
              SettingsSectionTitle({
                title: '主题色',
                hint: this.pal.hint,
                hintColor: this.pal.ink
              })

              Column({ space: 10 }) {
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

                Text('同步微调暗色卡片氛围与液态玻璃高光')
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 14, bottom: 12 })
              .backgroundColor(this.pal.card)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
            }
            .width('100%')

            // 布局密度：合并海报列数与剧照瀑布流至单张黑曜石卡
            Column({ space: 8 }) {
              SettingsSectionTitle({ title: '布局密度' })

              Column() {
                Row({ space: 10 }) {
                  SettingsIconTile({
                    icon: $r('sys.symbol.square_grid_2x2'),
                    tileSize: 32,
                    iconSize: 15,
                    accent: this.pal.accent,
                    ink: this.pal.ink
                  })
                  Text('海报列数')
                    .fontSize(13.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                    .width(66)
                  Row({ space: 6 }) {
                    ForEach(this.range(COLS_MIN, COLS_MAX), (n: number) => {
                      CountChip({
                        n: n,
                        current: this.posterCols,
                        label: Personalize.colsName(n),
                        fluid: false,
                        accent: this.pal.accent,
                        ink: this.pal.ink,
                        cardHi: this.pal.cardHi,
                        onPick: (v: number) => {
                          Personalize.setCols(v);
                        }
                      })
                    }, (n: number) => `col-${n}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 13, bottom: 13 })
                .alignItems(VerticalAlign.Center)

                SettingsRowDivider({ indent: 14 })

                Row({ space: 10 }) {
                  SettingsIconTile({
                    icon: $r('sys.symbol.rectangle_stack'),
                    tileSize: 32,
                    iconSize: 15,
                    accent: this.pal.accent,
                    ink: this.pal.ink
                  })
                  Text('剧照瀑布流')
                    .fontSize(13.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                    .width(66)
                  Row({ space: 6 }) {
                    ForEach(this.range(STILL_MIN, STILL_MAX), (n: number) => {
                      CountChip({
                        n: n,
                        current: this.stillCols,
                        label: Personalize.stillsName(n),
                        fluid: true,
                        accent: this.pal.accent,
                        ink: this.pal.ink,
                        cardHi: this.pal.cardHi,
                        onPick: (v: number) => {
                          Personalize.setStills(v);
                        }
                      })
                    }, (n: number) => `still-${n}`)
                  }
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 13, bottom: 10 })
                .alignItems(VerticalAlign.Center)

                Text('列表页双指捏合也可随时切换')
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ bottom: 12 })
              }
              .width('100%')
              .backgroundColor(this.pal.card)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)
            }
            .width('100%')

            // 顶栏材质
            Column({ space: 8 }) {
              SettingsSectionTitle({
                title: '顶栏材质',
                hint: ImmersiveGlass.modeLabel(this.glassMode),
                hintColor: this.pal.ink
              })

              Column({ space: 10 }) {
                Row({ space: 8 }) {
                  FxChip({
                    label: '无',
                    sub: '兜底',
                    picked: this.glassMode === 'none',
                    accent: this.pal.accent,
                    ink: this.pal.ink,
                    cardHi: this.pal.cardHi,
                    onPick: () => {
                      this.glassMode = 'none';
                      ImmersiveGlass.setMode('none');
                    }
                  })
                  FxChip({
                    label: '弱',
                    sub: '常规',
                    picked: this.glassMode === 'weak',
                    accent: this.pal.accent,
                    ink: this.pal.ink,
                    cardHi: this.pal.cardHi,
                    onPick: () => {
                      this.glassMode = 'weak';
                      ImmersiveGlass.setMode('weak');
                    }
                  })
                  FxChip({
                    label: '强',
                    sub: '透亮',
                    picked: this.glassMode === 'strong',
                    accent: this.pal.accent,
                    ink: this.pal.ink,
                    cardHi: this.pal.cardHi,
                    onPick: () => {
                      this.glassMode = 'strong';
                      ImmersiveGlass.setMode('strong');
                    }
                  })
                  FxChip({
                    label: '极限',
                    sub: '最透',
                    picked: this.glassMode === 'ultra',
                    accent: this.pal.accent,
                    ink: this.pal.ink,
                    cardHi: this.pal.cardHi,
                    onPick: () => {
                      this.glassMode = 'ultra';
                      ImmersiveGlass.setMode('ultra');
                    }
                  })
                }
                .width('100%')

                if (this.glassMode !== 'auto') {
                  Text('恢复自动（跟随设备算力）')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.pal.ink)
                    .onClick(() => {
                      this.glassMode = 'auto';
                      ImmersiveGlass.setMode('auto');
                    })
                }

                Text(ImmersiveGlass.deviceLabel())
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.pal.card)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
            }
            .width('100%')

            // 触感反馈
            Row({ space: 12 }) {
              SettingsIconTile({
                icon: $r('sys.symbol.slider_horizontal_2'),
                tileSize: 36,
                iconSize: 17,
                accent: this.pal.accent,
                ink: this.pal.ink
              })
              Column({ space: 2 }) {
                Text('触感反馈')
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                Text('收藏、删改与落位轻震')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.haptic === 1 })
                .selectedColor(this.pal.accent)
                .onChange((on: boolean) => {
                  Haptics.setOn(on);
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 13, bottom: 13 })
            .backgroundColor(this.pal.card)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
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
