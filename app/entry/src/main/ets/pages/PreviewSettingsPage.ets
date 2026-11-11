import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 高级设置 → 进度条预览。
 *
 * 服务端会「闲时慢跑」把库里没做过预览的片一部部生成（每部约 120KB），
 * 这样用户第一次拖进度条就有画面。这里把三件事交给用户：
 *  - 开不开这个后台任务；
 *  - 最多占多少空间（超了按最久没访问的删）；
 *  - 已经占了多少 / 一键清空。
 *
 * 存的是服务端 `DATA_DIR/preview-prefs.json`，改完立刻生效（warm 线程每轮重读）。
 */
interface PreviewPrefs {
  ok: boolean;
  enabled: boolean;
  warm: boolean;
  budget_mb: number;
  interval: number;
  used_mb: number;
  count: number;
}

@Entry
@Component
struct PreviewSettingsPage {
  @State warm: boolean = true;
  @State budget: number = 2048;
  @State usedMb: number = 0;
  @State count: number = 0;
  @State interval: number = 120;
  @State loading: boolean = true;
  @State note: string = '';
  @State busy: boolean = false;
  /** 服务端实际生效的缓存根目录（容器内路径）。 */
  @State cacheDir: string = '';
  @State dirSet: boolean = false;
  @State dirOk: boolean = true;
  @State dirWritable: boolean = true;
  @State dirDraft: string = '';
  @State showGuide: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/preview/settings`, Store.I.token);
      const o = JSON.parse(text) as Record<string, Object>;
      this.warm = o.warm !== false;
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
        this.note = '服务端没装 ffmpeg，预览生成不可用';
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] preview prefs: ${e.code} ${e.message}`);
      this.note = '读取失败，检查连接';
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
      this.note = '已保存，后台任务下一轮生效';
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
      this.note = n > 0 ? `已清空 ${n} 部` : '本来就是空的';
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
      this.note = '要写容器内的绝对路径，例如 /cache';
      return;
    }
    await this.save(`{"cache_dir":"${d}"}`);
    await this.load();
  }

  @Builder
  BudgetChip(v: number) {
    Text(v === 0 ? '不限制' : (v >= 1024 ? `${v / 1024} GB` : `${v} MB`))
      .fontSize(12)
      .fontColor(this.budget === v ? '#FFFFFF' : Theme.TEXT_DIM)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.budget === v ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(13)
      .margin({ right: 8, bottom: 6 })
      .onClick(() => {
        this.budget = v;
        this.save(`{"budget_mb":${v}}`);
      })
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
        Text('进度条预览')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          // 占用情况
          Column({ space: 6 }) {
            Row() {
              Text('已生成')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.loading ? '读取中…' : `${this.count} 部 · ${this.usedMb} MB`)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text(`每部约 120KB（8×8 格，每格 128×72）。拖动进度条时那块画面就是从这里来的。`)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 存储位置
          Column({ space: 8 }) {
            Row() {
              Text('存储位置')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.dirOk ? (this.dirWritable ? '可写' : '不可写')
                : '目录不存在')
                .fontSize(11)
                .fontColor(this.dirOk && this.dirWritable ? Theme.ACCENT : Theme.DANGER)
            }
            .width('100%')

            Text('容器内路径（默认 /cache，部署时映射到宿主机的大容量盘）')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')

            Row({ space: 8 }) {
              TextInput({ text: this.dirDraft, placeholder: '/cache' })
                .fontSize(12)
                .height(36)
                .layoutWeight(1)
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
                .onChange((v: string) => {
                  this.dirDraft = v;
                })
              Text(this.busy ? '保存中…' : '保存')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
                .onClick(() => {
                  this.saveDir();
                })
            }
            .width('100%')

            if (!this.dirOk || !this.dirWritable) {
              Text('这个目录在容器里不存在或写不进去：多半是 docker-compose 里没挂这个路径。')
                .fontSize(10)
                .fontColor(Theme.DANGER)
                .width('100%')
                .lineHeight(15)
            }

            Text(this.showGuide ? '收起说明 ▴' : '怎么加映射 / 换盘 ▾')
              .fontSize(11)
              .fontColor(Theme.ACCENT)
              .width('100%')
              .padding({ top: 2 })
              .onClick(() => {
                this.showGuide = !this.showGuide;
              })

            if (this.showGuide) {
              Column({ space: 6 }) {
                Text('1. 在宿主机上先建目录（挑空间大的分区）：')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
                Text('   mkdir -p /srv/amane-cache')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                Text('2. 编辑旁挂服务的 compose 文件，在 volumes 里加一行：')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
                Text('   - /srv/amane-cache:/cache')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                Text('3. 重建容器让它生效：')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
                Text('   docker compose up -d --force-recreate')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                Text('4. 回来把这里的路径填成容器里的那个（/cache），保存。')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
                Text('注意：路径必须已经挂进容器，否则写了也存不进去。')
                  .fontSize(10)
                  .fontColor(Theme.GOLD)
                  .width('100%')
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(8)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 后台预生成开关
          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('闲时预生成')
                .fontSize(14)
                .fontColor(Theme.TEXT)
              Text(this.warm
                ? `后台一部部慢慢做（约每 ${Math.round(this.interval / 60)} 分钟一部），不和播放抢带宽`
                : '关：只有真正打开某部片时才现做，第一次拖进度条可能没图')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .lineHeight(15)
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
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 预算
          Column({ space: 8 }) {
            Text('占用上限')
              .fontSize(14)
              .fontColor(Theme.TEXT)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              this.BudgetChip(0)
              this.BudgetChip(512)
              this.BudgetChip(1024)
              this.BudgetChip(2048)
              this.BudgetChip(4096)
            }
            .width('100%')
            Text('超过上限时会按「最久没看过」的顺序自动删旧的。当前全库 5000 多部，全做约 600MB。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Row({ space: 8 }) {
              Text('清空预览图')
                .fontSize(11)
                .fontColor(Theme.DANGER)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(8)
                .onClick(() => {
                  this.purge();
                })
              if (this.note.length > 0) {
                Text(this.note)
                  .fontSize(10)
                  .fontColor(Theme.ACCENT)
                  .layoutWeight(1)
                  .maxLines(2)
              }
              Blank()
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          Blank().height(24)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
