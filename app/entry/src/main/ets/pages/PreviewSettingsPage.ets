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
  shorts_warm?: boolean;
  budget_mb: number;
  interval: number;
  used_mb: number;
  count: number;
}

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
  /** 服务端实际生效的缓存根目录（容器内路径）。 */
  @State cacheDir: string = '';
  @State dirSet: boolean = false;
  @State dirOk: boolean = true;
  @State dirWritable: boolean = true;
  @State dirDraft: string = '';
  @State showGuide: boolean = false;
  /** 负一屏左侧光晕提示（本机偏好 minus_glow，默认开）。 */
  @State glowHint: boolean = true;

  aboutToAppear(): void {
    this.load();
    // 负一屏光晕开关是纯本机偏好（服务端没有这个概念）
    this.glowHint = Store.I.prefString('minus_glow', '1') !== '0';
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

  /** 上限摘要（只读）。编辑入口在「设置 → 刷一刷」，2026-11-15 收敛成一个地方。 */
  private budgetText(): string {
    if (this.budget <= 0) {
      return '不限制';
    }
    return this.budget >= 1024 ? `${this.budget / 1024} GB` : `${this.budget} MB`;
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

            // 加挂载的具体命令 2026-11-15 起收进「设置 → 服务器连接 → 部署说明」：
            // 这类东西属于部署细节，散在功能页里每次都要重讲一遍。
            Row({ space: 8 }) {
              Text('怎么加映射 / 换盘')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .layoutWeight(1)
              Text('部署说明 ›')
                .fontSize(11)
                .fontColor(Theme.ACCENT)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(Theme.accentAlpha(0.12))
                .borderRadius(8)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/SettingsConnectionPage' });
                })
            }
            .width('100%')
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

          // 刷一刷素材的开关已经搬到「设置 → 刷一刷」独立一页（2.6.1.64）：
          // 用户 22:42 反馈「藏在进度条预览里，不深入找根本想不到」。
          // 这里只留一句指路，不再重复放开关。
          Text('刷一刷素材的开关、负一屏提示光晕、以及这条上限的编辑入口，都收在「设置 → 刷一刷」；'
            + '这一页只显示当前值。')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .lineHeight(15)
            .padding({ left: 4, right: 4 })

          // 负一屏提示光晕（2.6.1.64）2026-11-15 已搬到「设置 → 刷一刷」：
          // 它讲的是首页/负一屏的事，和进度条预览没有关系。

          // 预算（两条预生成共用这一份上限：它们写的是同一个缓存目录）
          // 2026-11-15：上限只在「设置 → 刷一刷」那一个地方改，这里只显示当前值 + 跳过去改。
          Column({ space: 8 }) {
            Row() {
              Text('占用上限')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.budgetText())
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
            .width('100%')
            Text('预览图和刷一刷的封面帧是同一批文件，共用一份上限。为了不出现两个地方改同一个值的困惑，'
              + '编辑入口收在「设置 → 刷一刷」里，这一页只显示当前值。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Row({ space: 8 }) {
              Text('去刷一刷里改')
                .fontSize(11)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/ShortsSettingsPage' });
                })
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
            Text('超过上限时会按「最久没看过」的顺序自动删旧的。当前全库 5000 多部，全做约 600MB。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
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
