import { httpGet, httpPost } from '../common/Http';
import { PoolFilterCard } from '../view/PoolFilterCard';
import { resetShortsCache } from '../view/ShortsView';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 刷一刷（短视频流）的设置（2.6.1.64）。
 *
 * 为什么单独一页：这条开关原来塞在「设置 → 进度条预览」里 —— 用户 22:42 的原话是
 * 「用户如果不是深入去找，很难想到刷一刷素材的开关会藏在进度条预览里」。
 * 刷一刷是个独立功能，开关就该在设置里有一行自己的名字。
 *
 * 和「进度条预览」的关系：两者写的是**同一个缓存目录**（同一批帧文件），
 * 所以「占用上限」是共用的那一份，不是各算各的 —— 各算各的会重复扣同一份空间。
 */
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
  /** 视频上下留白：铺模糊海报（开）还是纯黑边（关）。本机偏好 `shorts_poster_bg`。 */
  @State posterBg: boolean = true;
  /**
   * 负一屏提示光晕（2026-11-15 从「进度条预览」搬来）。
   * 它讲的是「首页最左边还有一屏」，属于刷一刷/负一屏这条线，和进度条预览无关。
   * 偏好键仍是 `minus_glow` / `minus_glow_keep`，行为一字未改。
   */
  @State glowHint: boolean = true;

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
      this.note = n > 0 ? `已清掉 ${n} 部的素材帧` : '本来就是空的';
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
      this.note = '已保存，后台任务下一轮生效';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] shorts save: ${e.code} ${e.message}`);
      this.note = '保存失败';
    }
    this.busy = false;
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
        Text('刷一刷')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 6, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      Scroll() {
        Column({ space: 10 }) {
          // 选片范围（2026-11-15 用户要求拆出来）：和顶部大图**共用同一套筛选实现**
          // （PoolFilterCard），但存的是自己的一套偏好（shorts_pool_spec / shorts_pool）,
          // 改这里不再影响顶部大图。
          PoolFilterCard({
            specKey: 'shorts_pool_spec',
            presetKey: 'shorts_pool',
            title: '刷一刷从哪儿挑',
            hint: '只在符合这些条件的片里截片段；都不选 = 全库。和顶部大图各算各的。',
            onChanged: () => {
              // 范围变了：预取缓存必须作废，否则还拿着旧范围的片段在刷
              resetShortsCache();
            }
          })

          // 开关
          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('后台准备素材')
                .fontSize(14)
                .fontColor(Theme.TEXT)
              Text(this.on
                ? '关着屏幕也在慢慢准备：一次一部、每 1.5 分钟一部、只扫本地盘的片子'
                : '关：只有打开刷一刷时才现扫。前面几次能刷的比较少，而且要等')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .lineHeight(15)
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
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 留白铺什么（2.6.2.19）：模糊海报底 / 纯黑边。
          // 纯本机偏好 —— 服务端没有这个概念，改完回刷一刷立即生效。
          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('海报背景')
                .fontSize(14)
                .fontColor(Theme.TEXT)
              Text(this.posterBg
                ? '横板视频上下留白处铺一张模糊的封面，跟着画面一起刷走'
                : '关：留白处只留纯黑边（最省电，滑起来也更稳）')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .lineHeight(15)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.posterBg })
              .selectedColor(Theme.ACCENT)
              .onChange((v: boolean) => {
                this.posterBg = v;
                Store.I.prefSetString('shorts_poster_bg', v ? '1' : '0');
                // 刷一刷是按 AppStorage 铺的：这里同步过去，返回就生效，不用重启
                AppStorage.setOrCreate<number>('shortsPosterBg', v ? 1 : 0);
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 负一屏提示光晕（2026-11-15 从「进度条预览」搬来）：学过一次就该停，给个开关关掉
          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('负一屏提示光晕')
                .fontSize(14)
                .fontColor(Theme.TEXT)
              Text(this.glowHint
                ? '首页最左边那道细光带，每次打开 App 亮三下，提示「往左还有一屏」；进过一次负一屏会自动关掉'
                : '关：首页不再闪那条光带（负一屏仍可从最左边点/左滑进入）')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .lineHeight(15)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.glowHint })
              .selectedColor(Theme.ACCENT)
              .onChange((v: boolean) => {
                this.glowHint = v;
                Store.I.prefSetString('minus_glow', v ? '1' : '0');
                // 用户手动打开过就记下来：之后进负一屏不再自动关掉（尊重手动设置）
                Store.I.prefSetString('minus_glow_keep', v ? '1' : '0');
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 占用上限（和进度条预览共用）
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
            Text('刷一刷的封面帧和「进度条预览」的缩略图是同一批文件，所以这里是共用的一份上限，'
              + '只在这一页改（空间管理、进度条预览页只显示摘要）。超了按「最久没看过」先删。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 占用明细（用户 23:02：不许出现「占十几 G 还清不掉」的东西）
          Column({ space: 8 }) {
            Text('现在占了多少')
              .fontSize(14)
              .fontColor(Theme.TEXT)
              .width('100%')
            Row() {
              Text('刷一刷素材')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
              Blank()
              Text(`${this.framesMb} MB · ${this.framesCount} 部（已打分 ${this.framesScored}）`)
                .fontSize(12)
                .fontColor(Theme.TEXT)
            }
            .width('100%')
            Row() {
              Text('进度条预览')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
              Blank()
              Text(`${this.spriteMb} MB`)
                .fontSize(12)
                .fontColor(Theme.TEXT)
            }
            .width('100%')
            Row() {
              Text('合计')
                .fontSize(12)
                .fontColor(Theme.TEXT_DIM)
              Blank()
              Text(`${this.totalMb} MB`)
                .fontSize(12)
                .fontColor(Theme.GOLD)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            Text('到上限会自动停，不会一直涨。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(15)
            Row({ space: 8 }) {
              Text('清空刷一刷素材')
                .fontSize(11)
                .fontColor(Theme.DANGER)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(13)
                .onClick(() => {
                  this.purgeFrames();
                })
              Blank()
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // 说明
          Column({ space: 6 }) {
            Text('它是怎么挑片段的')
              .fontSize(13)
              .fontColor(Theme.TEXT)
              .width('100%')
            Text('① 你自己发过弹幕的那一秒优先（那是你最直接的心头好）；'
              + '② 没有弹幕的，用画面打分挑（清晰度 / 主体占比 / 亮度 / 画面复杂度）；'
              + '③ 这两样都还没有的，先随机取一段顶上，保证你不会刷到空。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(16)
            Text('网盘的片子暂时不参与 —— 拖到 10 秒处要等它几十秒，刷不动。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(16)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          if (this.note.length > 0) {
            Text(this.note)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .padding({ top: 4 })
          }
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ top: 36 })
    .backgroundColor(Theme.BG)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
