import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost, httpPut } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { GlassBack, GlassBox, PageTitle } from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

interface TasteRankItem {
  name: string;
  count: number;
  ratio: number;
}

interface TastePreset {
  key: string;
  label: string;
  desc: string;
}

interface TasteSamples {
  rated: number;
  favorites: number;
  watched: number;
  implicit: number;
  seeds: number;
  disliked: number;
}

interface TasteData {
  preset: string;
  explore_ratio?: number | null;
  presets: TastePreset[];
  samples: TasteSamples;
  actors: TasteRankItem[];
  tags: TasteRankItem[];
  series: TasteRankItem[];
  studios: TasteRankItem[];
  eras: TasteRankItem[];
  prefixes: TasteRankItem[];
}

interface PresetBody {
  preset: string;
}

interface RatioBody {
  explore_ratio: number;
}

function emptyTaste(): TasteData {
  return {
    preset: 'balanced',
    presets: [],
    samples: { rated: 0, favorites: 0, watched: 0, implicit: 0, seeds: 0, disliked: 0 },
    actors: [], tags: [], series: [], studios: [], eras: [], prefixes: []
  };
}

@Entry
@Component
struct TastePage {
  @State loading: boolean = true;
  @State err: string = '';
  @State data: TasteData = emptyTaste();
  @State preset: string = 'balanced';
  @State explorePct: number = -1;
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/taste?limit=10`, Store.I.token);
      const d = JSON.parse(text) as TasteData;
      this.data = d;
      this.preset = d.preset === undefined || d.preset === null ? 'balanced' : d.preset;
      this.explorePct = d.explore_ratio === undefined || d.explore_ratio === null
        ? -1 : Math.round(Number(d.explore_ratio) * 100);
      this.err = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] taste: ${e.code} ${e.message}`);
      this.err = e.code === 404 ? '服务端版本较旧，暂不支持画像接口' : '加载失败，点这里重试';
    }
    this.loading = false;
  }

  private async pickPreset(key: string): Promise<void> {
    if (key === this.preset) {
      return;
    }
    const old: string = this.preset;
    this.preset = key;
    try {
      const body: PresetBody = { preset: key };
      await httpPost(`${Store.I.user}/api/user/daily`, Store.I.token, JSON.stringify(body));
    } catch (err) {
      this.preset = old;
      const e = err as BusinessError;
      this.err = `切换失败（${e.code}）`;
    }
  }

  private async saveRatio(pct: number): Promise<void> {
    const old: number = this.explorePct;
    this.explorePct = pct;
    try {
      const body: RatioBody = { explore_ratio: pct / 100 };
      await httpPut(`${Store.I.user}/api/user/daily`, Store.I.token, JSON.stringify(body));
    } catch (err) {
      this.explorePct = old;
      const e = err as BusinessError;
      this.err = `保存失败（${e.code}）`;
      setTimeout(() => {
        this.err = '';
      }, 2200);
    }
  }

  private hasData(): boolean {
    return this.data.samples.seeds > 0;
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
        PageTitle({ text: '我的口味', fs: 18 })
        Blank()
        GlassBox({
          radius: 20,
          padH: 10,
          padV: 10,
          mat: true,
          onTap: () => {
            this.load();
          }
        }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([Theme.TEXT])
        }
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

  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  private barH(): number {
    return this.topInset + 46;
  }

  private sampleVal(kind: string): number {
    if (kind === 'rated') {
      return this.data.samples.rated;
    }
    if (kind === 'favorites') {
      return this.data.samples.favorites;
    }
    if (kind === 'watched') {
      return this.data.samples.watched;
    }
    return this.data.samples.implicit;
  }

  private rankItems(kind: string): TasteRankItem[] {
    if (kind === 'actors') {
      return this.data.actors;
    }
    if (kind === 'tags') {
      return this.data.tags;
    }
    if (kind === 'series') {
      return this.data.series;
    }
    if (kind === 'studios') {
      return this.data.studios;
    }
    if (kind === 'eras') {
      return this.data.eras;
    }
    return this.data.prefixes;
  }

  @Builder
  Samples() {
    Column({ space: 10 }) {
      Text('画像依据')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
        .width('100%')

      Row() {
        this.SampleCell('评分', 'rated', false)
        this.SampleCell('收藏', 'favorites', false)
        this.SampleCell('完播', 'watched', true)
        this.SampleCell('隐式', 'implicit', false)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .linearGradient({
      angle: 145,
      colors: [[Theme.accentAlpha(0.12), 0.0], ['#00000000', 0.62]]
    })
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  SampleCell(label: string, kind: string, highlight: boolean) {
    Column({ space: 3 }) {
      Text(`${this.sampleVal(kind)}`)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(highlight && this.sampleVal(kind) > 0
          ? Theme.ACCENT_INK
          : (this.sampleVal(kind) > 0 ? Theme.TEXT : Theme.TEXT_FAINT))
        .fontFeature('"tnum" 1')
      Text(label)
        .fontSize(10.5)
        .fontColor(Theme.TEXT_FAINT)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  Presets() {
    Column({ space: 10 }) {
      Column({ space: 2 }) {
        Text('推荐取向')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Text('调节每日推荐里熟口味与新发现的比例')
          .fontSize(10.5)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 4 }) {
        ForEach(this.data.presets, (p: TastePreset) => {
          Column({ space: 2 }) {
            Text(p.label)
              .fontSize(12.5)
              .fontWeight(this.preset === p.key ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.preset === p.key ? Theme.ACCENT_INK : Theme.TEXT_DIM)
            Text(p.desc)
              .fontSize(9)
              .fontColor(this.preset === p.key ? Theme.ACCENT_INK : Theme.TEXT_FAINT)
              .opacity(this.preset === p.key ? 0.78 : 1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 8, bottom: 8, left: 4, right: 4 })
          .borderRadius(Theme.R_PILL)
          .backgroundColor(this.preset === p.key ? Theme.accentAlpha(0.22) : Color.Transparent)
          .border({
            width: this.preset === p.key ? 0.75 : 0,
            color: this.preset === p.key ? Theme.inkAlpha(0.52) : Color.Transparent
          })
          .onClick(() => {
            this.pickPreset(p.key);
          })
        }, (p: TastePreset) => `${p.key}-${this.preset === p.key ? 1 : 0}`)
      }
      .width('100%')
      .padding(4)
      .backgroundColor('#141114')
      .border({ width: 0.5, color: '#1AFFFFFF' })
      .borderRadius(Theme.R_PILL)

      Row({ space: 8 }) {
        Text('随机探索')
          .fontSize(11.5)
          .fontColor(Theme.TEXT_DIM)
        Slider({
          value: this.explorePct < 0 ? 0 : this.explorePct,
          min: 0,
          max: 50,
          step: 5,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor(Theme.ACCENT)
          .trackColor('#1AFFFFFF')
          .blockColor(Theme.ACCENT2)
          .onChange((v: number, mode: SliderChangeMode) => {
            this.explorePct = v;
            if (mode === SliderChangeMode.End) {
              this.saveRatio(v);
            }
          })
        Text(this.explorePct < 0 ? '跟预设' : `${this.explorePct}%`)
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.explorePct < 0 ? Theme.TEXT_FAINT : Theme.ACCENT_INK)
          .fontFeature('"tnum" 1')
          .width(46)
          .textAlign(TextAlign.End)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(18)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  RankBlock(title: string, kind: string, useRoseGrad: boolean, pillStyle: boolean) {
    if (this.rankItems(kind).length > 0) {
      Column({ space: 10 }) {
        Row({ space: 6 }) {
          Text(title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Blank()
          Text(`${this.rankItems(kind).length} 项`)
            .fontSize(10.5)
            .fontColor(Theme.TEXT_FAINT)
            .fontFeature('"tnum" 1')
        }
        .width('100%')

        ForEach(this.rankItems(kind), (it: TasteRankItem, idx: number) => {
          Row({ space: 10 }) {
            if (pillStyle) {
              Text(it.name)
                .fontSize(11)
                .fontWeight(idx < 3 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(idx < 3 ? Theme.ACCENT_INK : Theme.TEXT_DIM)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(idx < 3 ? Theme.accentAlpha(0.18) : Theme.CARD_HI)
                .border({ width: 0.5, color: idx < 3 ? Theme.inkAlpha(0.42) : '#18FFFFFF' })
                .borderRadius(Theme.R_PILL)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 98 })
            } else {
              Text(`${idx + 1}`)
                .fontSize(11)
                .fontWeight(idx < 3 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(idx < 3 ? Theme.ACCENT_INK : Theme.TEXT_FAINT)
                .fontFeature('"tnum" 1')
                .width(18)
                .textAlign(TextAlign.Center)
              Text(it.name)
                .fontSize(12.5)
                .fontWeight(idx < 3 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(Theme.TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 112 })
            }

            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(6)
                .borderRadius(3)
                .backgroundColor('#18FFFFFF')
              Column()
                .width(`${Math.max(6, Math.round(it.ratio * 100))}%`)
                .height(6)
                .borderRadius(3)
                .linearGradient(useRoseGrad
                  ? Theme.ctaGradient()
                  : { angle: 90, colors: [['#D4913B', 0.0], ['#F4C97E', 1.0]] })
            }
            .layoutWeight(1)
            .height(6)

            Text(`${Math.round(it.ratio * 100)}%`)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(idx < 3 ? Theme.TEXT : Theme.TEXT_DIM)
              .fontFeature('"tnum" 1')
              .width(36)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (it: TasteRankItem) => `${title}_${it.name}_${Math.round(it.ratio * 100)}`)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.CARD)
      .borderRadius(18)
      .border({ width: 0.75, color: Theme.STROKE })
    }
  }

  @Builder
  Body() {
    Scroll() {
      Column({ space: 14 }) {
        if (!this.hasData()) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(30)
              .fontColor([Theme.TEXT_FAINT])
            Text('还没有足够的数据')
              .fontSize(14)
              .fontColor(Theme.TEXT_DIM)
            Text('给看过的片打分或收藏几部，画像就会自动生成')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .padding({ top: 56, bottom: 40 })
        } else {
          this.Samples()
          this.Presets()
          this.RankBlock('最偏爱的演员', 'actors', true, false)
          this.RankBlock('高频偏好标签', 'tags', true, true)
          this.RankBlock('系列偏好', 'series', false, false)
          this.RankBlock('制片商', 'studios', false, false)
          this.RankBlock('年代分布', 'eras', true, true)
          this.RankBlock('番号前缀', 'prefixes', true, true)
          Text('结合高分、收藏与近期完播度加权生成。')
            .fontSize(10.5)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .padding({ left: 4, top: 2, bottom: 10 })
        }
      }
      .width('100%')
      .padding({
        left: Theme.PAGE_PAD, right: Theme.PAGE_PAD,
        top: this.barH() + 6, bottom: Theme.pageBottomSafe()
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.ACCENT_INK)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.err.length > 0) {
          Column() {
            Text(this.err)
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
              .padding(24)
              .onClick(() => {
                this.load();
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          this.Body()
        }
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
