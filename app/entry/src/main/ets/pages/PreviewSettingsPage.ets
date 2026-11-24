import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { setPageFullScreen } from '../common/PageFullscreen';
import { PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider
} from '../view/SettingsKit';

@Entry
@Component
struct PreviewSettingsPage {
  @State warm: boolean = true;
  @State shortsWarm: boolean = true;
  @State budget: number = 2048;
  @State usedMb: number = 0;
  @State count: number = 0;
  @State interval: number = 120;
  @State loading: boolean = true;
  @State note: string = '';
  @State busy: boolean = false;
  @State cacheDir: string = '';
  @State dirSet: boolean = false;
  @State dirOk: boolean = true;
  @State dirWritable: boolean = true;
  @State dirDraft: string = '';
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/preview/settings`, Store.I.token);
      const o = JSON.parse(text) as Record<string, Object>;
      this.warm = o.warm !== false;
      this.shortsWarm = o.shorts_warm !== false;
      this.budget = Number(o.budget_mb) || 0;
      this.usedMb = Number(o.used_mb) || 0;
      this.count = Number(o.count) || 0;
      this.interval = Number(o.interval) || 120;
      this.cacheDir = String(o.cache_dir === undefined || o.cache_dir === null ? '' : o.cache_dir);
      this.dirDraft = this.cacheDir;
      this.dirSet = o.cache_dir_set === true;
      this.dirOk = o.cache_ok !== false;
      this.dirWritable = o.writable !== false;
      if (o.enabled === false) {
        this.note = '服务端未检测到 ffmpeg，预览生成不可用';
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] preview prefs: ${e.code} ${e.message}`);
      this.note = '读取失败，请检查连接';
    }
    this.loading = false;
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
      console.error(`[amane] preview save: ${e.code} ${e.message}`);
      this.note = '保存失败';
    }
    this.busy = false;
  }

  private async purge(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const text: string = await httpPost(
        `${Store.I.user}/api/user/preview/purge`, Store.I.token, '{}');
      const o = JSON.parse(text) as Record<string, Object>;
      const n: number = Number(o.removed) || 0;
      this.usedMb = 0;
      this.count = 0;
      this.note = n > 0 ? `已清空 ${n} 部预览图` : '本来就是空的';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] preview purge: ${e.code} ${e.message}`);
      this.note = '清空失败';
    }
    this.busy = false;
  }

  private async saveDir(): Promise<void> {
    const d: string = this.dirDraft.trim();
    if (d.length > 0 && !d.startsWith('/')) {
      this.note = '需填写容器内绝对路径，例如 /cache';
      return;
    }
    await this.save(`{"cache_dir":"${d}"}`);
    await this.load();
  }

  private budgetText(): string {
    if (this.budget <= 0) {
      return '不限制';
    }
    return this.budget >= 1024 ? `${this.budget / 1024} GB` : `${this.budget} MB`;
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
        PageTitle({ text: '进度条预览', fs: 18 })
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

            // 概览 + 开关合入一张卡
            Column() {
              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.film'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('已生成雪碧图')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('每部约 120 KB，拖动进度条即时预览')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.loading ? '读取中…' : `${this.count} 部 · ${this.usedMb} MB`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ACCENT_INK)
                  .fontFeature('"tnum" 1')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 13 })

              SettingsRowDivider()

              Row({ space: 12 }) {
                SettingsIconTile({ icon: $r('sys.symbol.clock'), tileSize: 36, iconSize: 17 })
                Column({ space: 2 }) {
                  Text('闲时预生成')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text(this.warm
                    ? `后台约每 ${Math.max(1, Math.round(this.interval / 60))} 分钟生成一部，不抢带宽`
                    : '仅打开播放时按需生成')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.warm })
                  .selectedColor(Theme.ACCENT)
                  .onChange((v: boolean) => {
                    this.warm = v;
                    this.save(`{"warm":${v ? 'true' : 'false'}}`);
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 13 })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            // 存储位置
            Column({ space: 10 }) {
              Row() {
                Text('存储位置')
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                Text(this.dirOk ? (this.dirWritable ? '可写' : '不可写') : '目录不存在')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.dirOk && this.dirWritable ? '#8EE6B4' : Theme.DANGER)
              }
              .width('100%')

              Row({ space: 8 }) {
                TextInput({ text: this.dirDraft, placeholder: '/cache' })
                  .fontSize(12.5)
                  .fontColor(Theme.TEXT)
                  .placeholderColor(Theme.TEXT_FAINT)
                  .caretColor(Theme.ACCENT_INK)
                  .height(38)
                  .layoutWeight(1)
                  .backgroundColor('#141114')
                  .border({ width: 0.75, color: '#1EFFFFFF' })
                  .borderRadius(10)
                  .onChange((v: string) => {
                    this.dirDraft = v;
                  })
                Text(this.busy ? '保存中…' : '保存')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ACCENT_INK)
                  .padding({ left: 14, right: 14, top: 9, bottom: 9 })
                  .backgroundColor(Theme.accentAlpha(0.18))
                  .border({ width: 0.75, color: Theme.inkAlpha(0.46) })
                  .borderRadius(10)
                  .onClick(() => {
                    this.saveDir();
                  })
              }
              .width('100%')

              if (!this.dirOk || !this.dirWritable) {
                Text('容器内该目录不存在或不可写，请检查 compose volumes 映射。')
                  .fontSize(10.5)
                  .fontColor(Theme.DANGER)
                  .width('100%')
              }

              Row({ space: 8 }) {
                Text('容器路径需映射至宿主机大容量盘')
                  .fontSize(10.5)
                  .fontColor(Theme.TEXT_FAINT)
                  .layoutWeight(1)
                Row({ space: 3 }) {
                  Text('部署说明')
                    .fontSize(11)
                    .fontColor(Theme.ACCENT_INK)
                  SettingsChevron({ glyphSize: 11 })
                }
                .onClick(() => {
                  router.pushUrl({ url: 'pages/SettingsConnectionPage' });
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })

            // 占用上限与清理
            Column() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text('共用占用上限')
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT)
                  Text('与刷一刷素材共用，在刷一刷设置中修改')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.budgetText())
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ACCENT_INK)
                  .fontFeature('"tnum" 1')
                SettingsChevron({ glyphSize: 13 })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 13 })
              .onClick(() => {
                router.pushUrl({ url: 'pages/ShortsSettingsPage' });
              })

              SettingsRowDivider({ indent: 14 })

              Row({ space: 10 }) {
                SettingsIconTile({ icon: $r('sys.symbol.trash'), tileSize: 32, iconSize: 15, danger: true })
                Text('清空所有预览图')
                  .fontSize(13.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.DANGER)
                  .layoutWeight(1)
                SettingsChevron({ glyphSize: 13 })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .onClick(() => {
                this.purge();
              })
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(18)
            .border({ width: 0.75, color: Theme.STROKE })
            .clip(true)

            if (this.note.length > 0) {
              Text(this.note)
                .fontSize(11)
                .fontColor(Theme.ACCENT_INK)
                .width('100%')
                .padding({ left: 4 })
            }

            Blank().height(Theme.pageBottomSafe())
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
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
