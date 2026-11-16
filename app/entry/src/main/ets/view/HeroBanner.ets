import { MediaItem } from '../common/Types';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { runtimeText } from '../common/Util';
import { MarkBadges } from './MarkBadges';
import { GlowOrb, ParticleField } from './Fx';
import { ArtColor } from '../common/ArtColor';

/**
 * 首页顶部大海报轮播：横图铺满 + 底部渐变 + 番号/标题/两个按钮。
 * 素材优先用剧照（16:9 横图），没有就退回竖版海报（会裁切，但不至于空着）。
 *
 * 光效（2.6.1.14，「沉浸光效」强度 `amaneFx`）：
 *   - 轻以上：底部左侧一团主色柔光（呼吸），像银幕打在片名上；
 *   - 强：右上再补一团第二色微光 + 一层缓慢上升的浮尘。
 * 光晕画在文字**下面**（跟滑动一起走），粒子画在文字**上面**（`hitTestBehavior(None)`，不吃手势），
 * 这样滑动时粒子的位置不会跟着页面跳。
 */
@Component
export struct HeroBanner {
  /**
   * 2.6.1.32：必须是 `@Prop` —— 原来写成普通成员，父组件 `this.home` 换了新数据后
   * 子组件**不会重建**（V1 里只有 @Prop/@Link 这类装饰的才跟着刷新），
   * 表现就是「下拉刷新了但顶部还是原来那几部」。
   */
  @Prop @Watch('onItemsChanged') items: MediaItem[] = [];
  onPlay: (item: MediaItem) => void = () => {};
  onDetail: (item: MediaItem) => void = () => {};
  @State current: number = 0;
  @StorageProp('amaneFx') fx: number = 2;
  /**
   * 当前这张横幅的主色（2.6.1.18 一片一色）。
   *
   * 只给当前这一张取色 —— 12 张横幅全取一遍等于一次进首页多下 12 张图，
   * 而用户同一时刻只看得到一张。切到哪张取哪张，取不到就退回主题色。
   */
  @State tint: string = '';
  private tintFor: number = -1;
  /**
   * 整块横幅的透明度。两种用途：
   *
   * 1. **首次出现**：从 0 淡到 1（2026-11-16）。顶部大图现在等本次数据才挂载
   *    （`HomeTab.heroSkeleton` 先占位），所以"骨架 → 大图"也要有入场。
   * 2. **换了一批**（下拉刷新 / 切回首页换推荐）：压到 0.25 再淡回 1。
   *    注意冷启动那条路**已经不再走这里** —— 缓存首帧不再画 hero，从根上避免"先 A 后 B"。
   */
  @State alpha: number = 0;
  /** 上一批的首部 id（=1 说明是同一部，不用淡）。 */
  private firstId: number = -1;

  aboutToAppear(): void {
    this.firstId = this.items.length > 0 ? this.items[0].id : -1;
    this.loadTint(0);
    // 首次挂载从 0 淡进来（2026-11-16）：顶部大图现在等**这一次的数据**才挂载
    // （缓存首帧只显示骨架，见 HomeTab.heroSkeleton），所以第一次出现也要有入场，
    // 否则骨架 → 大图仍是一次硬切。
    animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.alpha = 1;
    });
  }

  /**
   * 换了一批数据（进首页拿到 fresh / 下拉刷新）。
   *
   * 索引越界就回第一张；主色重取 —— 否则顶部换成了另一部片，底部那团光还是上一部的颜色。
   */
  private onItemsChanged(): void {
    if (this.current >= this.items.length) {
      this.current = 0;
    }
    this.tintFor = -1;
    this.loadTint(this.current);
    // 首部换了才淡入：同一部（比如只是推荐行刷新）不该有动画
    const nowId: number = this.items.length > 0 ? this.items[0].id : -1;
    if (this.firstId !== -1 && nowId !== this.firstId) {
      this.swapFade();
    }
    this.firstId = nowId;
  }

  /** 换图时先压到 0.25 再淡回 1（约 260ms），避免"突然变成另一张"。 */
  private swapFade(): void {
    this.alpha = 0.25;
    animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.alpha = 1;
    });
  }

  private loadTint(index: number): void {
    if (index < 0 || index >= this.items.length || this.tintFor === index) {
      return;
    }
    this.tintFor = index;
    const item: MediaItem = this.items[index];
    const raw: string = item.fanart.length > 0 ? item.fanart : item.poster;
    if (raw.length === 0) {
      this.tint = '';
      return;
    }
    const url: string = Store.I.img(raw);
    const cached: string = ArtColor.cached(url);
    if (cached.length > 0) {
      this.tint = cached;
      return;
    }
    this.tint = '';
    ArtColor.of(url, Store.I.token).then((accent: string) => {
      // 算的时候用户可能已经划走了，只认回来的还是当前这张
      if (accent.length > 0 && this.tintFor === index) {
        this.tint = accent;
      }
    }).catch((err: BusinessError) => {
      console.info(`[amane] hero tint: ${err.code}`);
    });
  }

  private glowColor(): string {
    return this.tint.length > 0 ? this.tint : Theme.ACCENT;
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.items.length > 0) {
        Swiper() {
          ForEach(this.items, (item: MediaItem) => {
            Stack({ alignContent: Alignment.BottomStart }) {
              Image(Store.I.img(item.fanart.length > 0 ? item.fanart : item.poster))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD)
                // 2026-11-16 用户：大图上不该把负一屏拉出来（挡住「右滑进负一屏」的误触），
                // 但下面「立即播放 / 详情」那一行要留着可以拉。用首页既有的
                // rowTouchAt 机制把这一划标成「这一块归我」，父层就不会抢。
                .onTouch((ev: TouchEvent) => {
                  if (ev.type === TouchType.Down || ev.type === TouchType.Move) {
                    AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
                  }
                })

              // 顶部 scrim（2026-11-14）：让状态栏 / 顶部浮层在亮封面上也读得清，
              // 同时给画面加一层"影院幕布"的压暗感 —— 不加这层，亮片顶部会糊成一片。
              // 2026-11-16 用户连问两次「更透」→「最透」：55% → 34% → 现在只留 10%。
              // 状态栏那行字靠这层才不糊在亮封面上，所以没敢直接归零。
              Column()
                .width('100%')
                .height('38%')
                .align(Alignment.TopStart)
                .linearGradient({
                  angle: 180,
                  colors: [['#1A000000', 0], ['#00000000', 1]]
                })
                .hitTestBehavior(HitTestMode.None)

              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 180,
                  // 2026-11-16 用户「最透」：原 0.62 处就 80% 黑、0.96 处实色，封面糊成一块。
                  // 现在 0-70% 高度基本不压，只在底部按钮区收紧到 80%，
                  // 好处是图全露出来；代价是白色标题压在亮画面上会变糊（用户要看极限效果）。
                  colors: [['#00000000', 0.35], ['#4D0B0B0F', 0.70], ['#A60B0B0F', 0.92],
                           ['#CC0B0B0F', 1.0]]
                })
                // 2026-11-16：这层全屏压暗盖在封面之上，会把触摸全吃掉 ——
                // 于是大图的 onTouch 永远不触发，「右滑进负一屏」照旧生效。
                // 让压暗层不参与命中，触摸落到下面的 Image 上。
                .hitTestBehavior(HitTestMode.None)

              // 光晕：从画面左下角「溢」出来的一团主色光，右下角补一点第二色。
              // 都往外平移了一段，看起来像光从画面外打进来，而不是贴在图上的一个圆。
              if (this.fx >= 1) {
                Stack({ alignContent: Alignment.BottomStart }) {
                  GlowOrb({
                    color: this.glowColor(),
                    diameter: this.fx >= 2 ? 340 : 280,
                    alpha: this.fx >= 2 ? 0.42 : 0.28,
                    breath: true,
                    period: 3400
                  })
                    .translate({ x: -96, y: 96 })
                }
                .width('100%')
                .height('100%')
                .hitTestBehavior(HitTestMode.None)

                if (this.fx >= 2) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    GlowOrb({
                      color: ArtColor.second(this.glowColor()),
                      diameter: 240,
                      alpha: 0.16,
                      breath: true,
                      period: 4600
                    })
                      .translate({ x: 70, y: -80 })
                  }
                  .width('100%')
                  .height('100%')
                  .hitTestBehavior(HitTestMode.None)
                }
              }

              Column() {
                // 2.6.1.30：这块**不是**每日推荐 —— 数据来自服务端 `build_hero` 的独立随机池，
                // 下拉刷新就换一批。给它一个名字，和下面「每日推荐（每天固定）」分开。
                Row({ space: 5 }) {
                  Text('✦')
                    .fontSize(9)
                    .fontColor(Theme.GOLD)
                  Text('翻牌子')
                    .fontSize(10)
                    .fontColor(Theme.GOLD)
                    .fontWeight(FontWeight.Medium)
                  Text('下拉换一批')
                    .fontSize(9)
                    .fontColor('#B3FFFFFF')
                }
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor('#59000000')
                .borderRadius(9)
                .margin({ bottom: 8 })

                Row({ space: 6 }) {
                  Text(item.number)
                    .fontSize(11)
                    .fontColor(Theme.TEXT)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    // 番号底色跟着这张图的主色走（取不到色时就是主题色，观感与旧版一致）
                    .backgroundColor(Theme.alphaOf(this.glowColor(), 0.3))
                    .borderRadius(4)
                  if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                    MarkBadges({ marks: item.marks, max: 3, badgeSize: 9, fill: 'dark' })
                  }
                  if (item.studio.length > 0) {
                    Text(item.studio)
                      .fontSize(11)
                      .fontColor(Theme.TEXT_DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width('100%')
                .margin({ bottom: 6 })
                // 标题栏同样不参与「右滑进负一屏」（2026-11-16）
                .onTouch((ev: TouchEvent) => {
                  if (ev.type === TouchType.Down || ev.type === TouchType.Move) {
                    AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
                  }
                })

                Text(item.title.length > 0 ? item.title : item.number)
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.TEXT)
                  .lineHeight(29)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ bottom: 6 })
                  .onTouch((ev: TouchEvent) => {
                    if (ev.type === TouchType.Down || ev.type === TouchType.Move) {
                      AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
                    }
                  })

                Text(runtimeText(item.runtime))
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .margin({ bottom: 12 })

                Row({ space: 10 }) {
                  Button() {
                    Row({ space: 6 }) {
                      Text('▶')
                        .fontSize(13)
                        .fontColor('#FFFFFF')
                      Text(item.position > 0 ? '继续播放' : '立即播放')
                        .fontSize(14)
                        .fontColor('#FFFFFF')
                        .fontWeight(FontWeight.Medium)
                    }
                  }
                  .height(38)
                  .padding({ left: 18, right: 18 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(19)
                  // 主按钮带一圈同色辉光，深色底上才"发光"而不是一块平涂
                  .shadow({ radius: 18, color: Theme.alphaOf(Theme.ACCENT, 0.45), offsetX: 0, offsetY: 6 })
                  .onClick(() => {
                    this.onPlay(item);
                  })

                  Button('详情')
                    .height(38)
                    .padding({ left: 18, right: 18 })
                    .fontSize(14)
                    .fontColor(Theme.TEXT)
                    .backgroundColor('#26FFFFFF')
                    .borderRadius(19)
                    .border({ width: 1, color: Theme.STROKE_HI })
                    .onClick(() => {
                      this.onDetail(item);
                    })

                  Blank()

                  // 翻页指示（2026-11-16 用户）：从右上角搬进**这一行按钮的最右边** ——
                  // 原来 absolute 在 top 96，正文一长就被海报/标题压住看不见。
                  // 高度跟按钮行对齐，视觉上跟「立即播放 / 详情」是一组。
                  if (this.items.length > 1) {
                    Row({ space: 4 }) {
                      ForEach(this.items, (it: MediaItem, index: number) => {
                        Column()
                          .width(index === this.current ? 14 : 4)
                          .height(4)
                          .borderRadius(2)
                          .backgroundColor(index === this.current ? '#E6FFFFFF' : '#4DFFFFFF')
                      }, (it: MediaItem, index: number) => `dot-${it.id}-${index}`)
                    }
                    .height(38)
                    .alignItems(VerticalAlign.Center)
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .height('100%')
            // 2.6.1.28：整张图都能点进详情（原来只有右下「详情」小按钮可点，
            // 看到海报想点进去是本能动作）。两个按钮的 onClick 在子层，会先吃掉点击。
            .onClick(() => {
              this.onDetail(item);
            })
          }, (item: MediaItem) => `${item.id}`)
        }
        .autoPlay(this.items.length > 1)
        .interval(7000)
        .loop(true)
        .indicator(false)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.current = index;
          // 切到哪张就给哪张取色：横幅是首页最大的视觉块，颜色跟片走它才「属于这部片」
          this.loadTint(index);
        })

        // 浮尘盖在整块大图上（含文字），但 alpha 峰值只有 0.34 且不吃手势，
        // 作用是让静止的大图「活」起来；别调高，调高标题会糊。
        if (this.fx >= 2) {
          ParticleField({ count: 22, color: '#FFFFFF', alpha: 0.34, drift: 1 })
        }
      }
    }
    .width('100%')
    .height(Theme.HERO_H)
    .backgroundColor(Theme.BG)
    // 换一批 hero 时（冷启动：缓存那批 → fresh 那批）压暗再淡入，别硬切
    .opacity(this.alpha)
  }
}
