import { httpGet, httpPost } from '../common/Http';
import { PoolFilterCard } from '../view/PoolFilterCard';
import { resetShortsCache } from '../view/ShortsView';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider, VelvetChip
} from '../view/SettingsKit';

interface ShortsPrefs {
  shorts_warm?: boolean;
  budget_mb?: number;
  used_mb?: number;
  count?: number;
  frames_mb?: number;
  frames_count?: number;
  frames_scored?: number;
  total_mb?: number;
}

@Entry
@Component
struct ShortsSettingsPage {
  @State on: boolean = true;
  @State budget: number = 2048;
  @State busy: boolean = false;
  @State note: string = '';
  @State framesMb: number = 0;
  @State framesCount: number = 0;
  @State framesScored: number = 0;
  @State spriteMb: number = 0;
  @State totalMb: number = 0;
  @State posterBg: boolean = true;
  @State glowHint: boolean = true;
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.posterBg = Store.I.prefString('shorts_poster_bg', '1') !== '0';
    this.glowHint = Store.I.prefString('minus_glow', '1') !== '0';
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/preview/settings`, Store.I.token);
      const o = JSON.parse(text) as ShortsPrefs;
      this.on = o.shorts_warm !== false;
      this.budget = Number(o.budget_mb) || 0;
      this.framesMb = Number(o.frames_mb) || 0;
      this.framesCount = Number(o.frames_count) || 0;
      this.framesScored = Number(o.frames_scored) || 0;
      this.spriteMb = Number(o.used_mb) || 0;
      this.totalMb = Number(o.total_mb) || 0;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] shorts prefs: ${e.code} ${e.message}`);
      this.note = '读不到设置';
    }
  }

  private async purgeFrames(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const text: string = await httpPost(
        `${Store.I.user}/api/user/preview/purge?what=frames`, Store.I.token, '{}');
      const o = JSON.parse(text) as Record<string, Object>;
      const n: number = Number(o.removed) || 0;
      this.note = n > 0 ? `已清掉 ${n} 部素材帧` : '本来就是空的';
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] shorts purge: ${e.code} ${e.message}`);
      this.note = '清理失败';
    }
    this.busy = false;
  }

  private async save(patch: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await httpPost(`${Store.I.user}/api/user/preview/settings`, Store.I.token, patch);
      this.note = '已保存，后台下一轮生效';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] shorts save: ${e.code} ${e.message}`);
      this.note = '保存失败';
    }
    this.busy = false;
  }

  private budgetLabel(v: number): string {
    if (v === 0) {
      return '不限制';
    }
    return v >= 1024 ? `${v / 1024} GB` : `${v} MB`;
  }

  private usageRatioPct(): string {
    if (this.budget <= 0) {
      return this.totalMb > 0 ? '25%' : '0%';
    }
    const pct: number = Math.min(100, Math.max(4, Math.round((this.totalMb / this.budget) * 100)));
    return `${pct}%`;
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
        PageTitle({ text: '刷一刷', fs: 18 })
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
        SettingsAmbientGlow()

        Scroll() {
          Column({ space: 14 }) {
            Blank().height(this.barH() + 6)

            // 挑片范围卡
            PoolFilterCard({
              specKey: 'shorts_pool_spec',
              presetKey: 'shorts_pool',
              title: '挑片范围',
              hint: '不选条件则从全库随机挑片',
              onChanged: () => {
                resetShortsCache();
              }
            })

            // 3 个核心开关合并为一张分组黑曜石卡
            Column() {
              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.download'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('后台准备素材')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('闲时缓存本地片段，开屏即播')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.on })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.on = v;
                    this.save(`{"shorts_warm":${v ? 'true' : 'false'}}`);
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })

              SettingsRowDivider()

              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.picture'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('模糊海报背景')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('横屏视频上下留白铺模糊封面')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.posterBg })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.posterBg = v;
                    Store.I.prefSetString('shorts_poster_bg', v ? '1' : '0');
                    AppStorage.setOrCreate<number>('shortsPosterBg', v ? 1 : 0);
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })

              SettingsRowDivider()

              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.wand_and_stars'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('负一屏边缘光晕')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('首页左侧显示呼吸光晕提示')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.glowHint })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.glowHint = v;
                    Store.I.prefSetString('minus_glow', v ? '1' : '0');
                    Store.I.prefSetString('minus_glow_keep', v ? '1' : '0');
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            // 素材占用 + 上限 + 清空
            Column({ space: 12 }) {
              Row() {
                Text('素材占用')
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                Blank()
                Text(`${this.totalMb} MB / ${this.budgetLabel(this.budget)}`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ACCENT_INK)
                  .fontFeature('"tnum" 1')
              }
              .width('100%')

              // 玫瑰渐变占用进度条
              Stack({ alignContent: Alignment.Start }) {
                Column()
                  .width('100%')
                  .height(7)
                  .borderRadius(3.5)
                  .backgroundColor('#1AFFFFFF')
                if (this.totalMb > 0) {
                  Column()
                    .width(this.usageRatioPct())
                    .height(7)
                    .borderRadius(3.5)
                    .linearGradient(Theme.ctaGradient())
                }
              }
              .width('100%')
              .height(7)

              Row() {
                Text(`刷一刷 ${this.framesMb} MB（${this.framesCount} 部 · 已打分 ${this.framesScored}）`)
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .fontFeature('"tnum" 1')
                Blank()
                Text(`预览 ${this.spriteMb} MB`)
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .fontFeature('"tnum" 1')
              }
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach([512, 1024, 2048, 4096, 0], (v: number) => {
                  Column() {
                    VelvetChip({
                      label: this.budgetLabel(v),
                      active: this.budget === v,
                      padH: 12,
                      padV: 6,
                      fs: 11.5,
                      onTap: () => {
                        this.budget = v;
                        this.save(`{"budget_mb":${v}}`);
                      }
                    })
                  }
                  .margin({ right: 7, bottom: 7 })
                }, (v: number) => `bg-${v}-${this.budget === v ? 1 : 0}`)
              }
              .width('100%')

              SettingsRowDivider({ indent: 0 })

              Row({ space: 10 }) {
                SettingsIconTile({ icon: $r('sys.symbol.trash'), tileSize: 32, iconSize: 15, danger: true })
                Text(this.busy ? '清理中…' : '清空已缓存片段')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.DANGER)
                  .layoutWeight(1)
                SettingsChevron({ glyphSize: 13 })
              }
              .width('100%')
              .padding({ top: 2, bottom: 2 })
              .onClick(() => {
                this.purgeFrames();
              })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })

            if (this.note.length > 0) {
              Text(this.note)
                .fontSize(11)
                .fontColor(Theme.ACCENT_INK)
                .width('100%')
                .padding({ left: 4 })
            }

            Text('优先取弹幕时刻与高分构图，与进度条预览共用上限（暂不含网盘片）。')
              .fontSize(10.5)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(16)
              .padding({ left: 4, right: 4 })

            Blank().height(Theme.pageBottomSafe())
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
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
