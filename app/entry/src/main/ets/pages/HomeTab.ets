import { promptAction, router } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { httpDelete, httpGet, httpGetCached, cachedBody, dropPageCache, httpPost, httpWarmStream } from '../common/Http';
import { cachePut } from '../common/PageCache';
import { Store } from '../common/Store';
import { PoolParams } from '../common/PoolParams';
import { NavBarWatch } from '../common/NavBarWatch';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { markScroll } from '../view/Fx';
import { HomeData, HomeRow, LibraryInfo, MediaItem, BrowseParams, DetailParams, PlayerParams } from '../common/Types';
import { CardPayload, KEY_CARD, payloadOf } from '../common/CardCache';
import { safeHome } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { Reason, ReasonPack, ReasonLine } from '../common/Reason';
import { HeroBanner } from '../view/HeroBanner';
import { MediaRow } from '../view/MediaRow';
import { BannerRow } from '../view/BannerRow';
import { GlowOrb, ParticleField } from '../view/Fx';
import { GlassBox, GlassIcon, PageTitle } from '../view/GlassKit';

/** 首页「媒体库」一栏的一张卡（2.5.5.4）。 */
interface LibCard {
  id: number;
  name: string;
  count: number;
  /** 用户换过的封面；空串 = 用 posters 拼贴。 */
  cover: string;
  posters: string[];
}

export function emptyHome(): HomeData {
  const data: HomeData = {
    hero: [], continue: [], recommend: [], banners: [], rows: [], libraries: [], generated_at: ''
  };
  return data;
}

/** 理由还没算出来 / 关掉时，副标题退回原来那句，行头也不出现「推荐理由」。 */
function emptyReasons(): ReasonPack {
  return { headline: Reason.DEFAULT_SUBTITLE, topic: '', lines: [], count: 0 };
}

/**
 * 首页预热节流（2.6.1.85）：`metaId → 上次预热时刻`。
 *
 * 首页那张大图是「最短路径」的播放入口（点一下「立即播放」就开流），没有详情页那段
 * 「用户要看两秒」的缓冲。在这里先替它把服务端首块热起来，点下去才会快。
 * 同一部片 10 分钟内只热一次，别让来回刷首页把网盘回源拉爆。
 */
const HOME_WARM_AT: Map<number, number> = new Map();

/**
 * 首页的一行（2.5.2 起首页由数据驱动）。
 *
 * `kind` 决定用哪个组件渲染：`cast` 是甄选入口卡、`banner` 是横幅行、
 * 其余（`continue` / `row`）都是普通的横向海报行。`key` 同时是偏好里的键名，
 * 一旦发布不要再改（改了用户存的顺序就对不上了）。
 */
interface HomeSection {
  key: string;
  kind: string;
  title: string;
  subtitle: string;
  libraryId: number;
  /** `more` 按钮去哪：`history` 走观看记录，`library` 走这个媒体库。 */
  moreKind: string;
  items: MediaItem[];
}

/**
 * 首页「媒体库」一栏（2.5.5.4）：横向卡片，封面 = 自定义图 > 两张海报拼贴 > 首字。
 *
 * 换封面走**长按**（`bindContextMenu` + `ResponseType.LongPress`），单击仍是进库 ——
 * 同一张卡上再挂一个可点按钮，很容易点封面就误跳页面。
 */
@Component
struct LibraryRow {
  @Prop cards: LibCard[] = [];
  onOpen: (id: number, name: string) => void = (id: number, name: string) => {};
  onPickCover: (card: LibCard) => void = (card: LibCard) => {};
  onMakeGif: (card: LibCard) => void = (card: LibCard) => {};
  onRestoreCover: (card: LibCard) => void = (card: LibCard) => {};

  /** 长按菜单（`bindContextMenu` 只认 CustomBuilder）。 */
  @Builder
  CardMenu(c: LibCard) {
    Menu() {
      MenuItem({ content: '换封面（从相册选）' })
        .onClick(() => {
          this.onPickCover(c);
        })
      MenuItem({ content: '用库里海报做动图' })
        .onClick(() => {
          this.onMakeGif(c);
        })
      if (c.cover.length > 0) {
        MenuItem({ content: '恢复默认封面' })
          .onClick(() => {
            this.onRestoreCover(c);
          })
      }
    }
  }

  /**
   * 点「⇄」弹出的菜单。长按在很多机型上不灵（List 滚动手势会抢），
   * 所以给一个**明确可点**的入口，长按留着当捷径。
   */
  private menuItems(c: LibCard): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '换封面（从相册选）',
      action: () => {
        this.onPickCover(c);
      }
    });
    items.push({
      value: '用库里海报做动图',
      action: () => {
        this.onMakeGif(c);
      }
    });
    if (c.cover.length > 0) {
      items.push({
        value: '恢复默认封面',
        action: () => {
          this.onRestoreCover(c);
        }
      });
    }
    return items;
  }

  /**
   * 一张库卡。
   *
   * 为什么单独抽成一个组件：`bindContextMenu` 的 CustomBuilder **要的是「方法引用」，
   * 不是「调用结果」**。以前写成 `.bindContextMenu(this.Menu(c), ...)`，
   * 等于把执行完的 void 传进去 —— 长按的震动和缩放照旧（系统手势识别了），
   * 但菜单里什么都没有（2.5.6.8 用户报的正是这个）。
   * 这里把 `c` 放进 `@Prop`，菜单 builder 就能是无参的 `this.CardMenu`。
   */
  @Builder
  Card(c: LibCard) {
    LibCardCell({
      card: c,
      onOpen: (id: number, name: string) => {
        this.onOpen(id, name);
      },
      onPickCover: (card: LibCard) => {
        this.onPickCover(card);
      },
      onMakeGif: (card: LibCard) => {
        this.onMakeGif(card);
      },
      onRestoreCover: (card: LibCard) => {
        this.onRestoreCover(card);
      }
    })
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('媒体库')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.cards, (c: LibCard) => {
            this.Card(c)
          }, (c: LibCard) => `lib-${c.id}-${c.cover}-${c.posters.length}`)
        }
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      // 2026-11-16：这一条横滑时不要被首页的「右滑进负一屏」抢走。
      // 行组件都在 onTouch 里写 rowTouchAt 表示「这一划归我」，这条库栏之前漏了，
      // 于是从它上面右滑会直接把负一屏带出来（其他行不会，就是这个原因）。
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down || ev.type === TouchType.Move) {
          AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
        }
      })
      .width('100%')
    }
    .width('100%')
    .margin({ bottom: 13 })
  }
}

/**
 * 一张库卡（2.5.5.4）。
 *
 * 单独抽成组件的原因见上面 `LibraryRow.Card` 的注释：长按菜单要的 CustomBuilder
 * 必须是无参方法引用，数据只能从 `@Prop` 里读。
 */
@Component
struct LibCardCell {
  @Prop card: LibCard = { id: 0, name: '', count: 0, cover: '', posters: [] };
  onOpen: (id: number, name: string) => void = (id: number, name: string) => {};
  onPickCover: (card: LibCard) => void = (card: LibCard) => {};
  onMakeGif: (card: LibCard) => void = (card: LibCard) => {};
  onRestoreCover: (card: LibCard) => void = (card: LibCard) => {};

  @Builder
  CardMenu() {
    Menu() {
      MenuItem({ content: '换封面（从相册选）' })
        .onClick(() => {
          this.onPickCover(this.card);
        })
      MenuItem({ content: '用库里海报做动图' })
        .onClick(() => {
          this.onMakeGif(this.card);
        })
      if (this.card.cover.length > 0) {
        MenuItem({ content: '恢复默认封面' })
          .onClick(() => {
            this.onRestoreCover(this.card);
          })
      }
    }
  }

  private menuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '换封面（从相册选）',
      action: () => {
        this.onPickCover(this.card);
      }
    });
    items.push({
      value: '用库里海报做动图',
      action: () => {
        this.onMakeGif(this.card);
      }
    });
    if (this.card.cover.length > 0) {
      items.push({
        value: '恢复默认封面',
        action: () => {
          this.onRestoreCover(this.card);
        }
      });
    }
    return items;
  }

  /**
   * 封面视觉（不含 ⇄ 按钮）：原图与倒影共用同一份，保证镜像和本体一致。
   * 三种形态：用户自定义封面 > 两张库内海报拼贴 > 库名首字。
   */
  @Builder
  CoverArt() {
    if (this.card.cover.length > 0) {
      Image(Store.I.img(this.card.cover))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    } else if (this.card.posters.length > 0) {
      Row({ space: 1 }) {
        ForEach(this.card.posters, (p: string, i: number) => {
          Image(Store.I.img(p))
            .layoutWeight(1)
            .height('100%')
            .objectFit(ImageFit.Cover)
        }, (p: string, i: number) => `lp-${this.card.id}-${i}`)
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        Text(this.card.name.substring(0, 1))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_DIM)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.CARD_HI)
    }
  }

  build() {
    Column({ space: 5 }) {
      // 封面 + 倒影贴成一段（两者零间隙），整段再与下面的库名/部数保持 5 的距离
      Column() {
        Stack({ alignContent: Alignment.TopEnd }) {
          this.CoverArt()
          // 明确可点：点它出菜单（长按在很多机型上会被滚动手势抢掉）
          Text('⇄')
            .fontSize(10)
            .fontColor('#F2FFFFFF')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#99000000')
            .borderRadius(7)
            .margin({ top: 5, right: 5 })
            .bindMenu(this.menuItems())
        }
        .width('100%')
        .height(84)
        .borderRadius(10)
        .clip(true)
        .backgroundColor(Theme.CARD_HI)
        .border({
          width: this.card.cover.length > 0 ? 1 : 0,
          color: Theme.accentAlpha(0.32)
        })

        // 镜像倒影（2026-11-17，用户参考 hosplayer）：取封面底部一段垂直翻转，
        // 再叠一层背景色渐变同时完成「压暗」和「淡出」。
        // scale 绕中心翻转不改变布局尺寸：84 高的镜像在 TopStart 的 30 高 Stack 里
        // 只露出顶部 30px，那正是封面底部 30px 的倒影。倒影不拦点击，点它等同点卡片进库。
        //
        // 暗部/收尾的坑：不要在 Stack 上挂 opacity —— 它会把渐变底部那层本该
        // 100% 不透明的背景色一起削薄，容器 clip 时还剩几十 % 的倒影被硬切断，
        // 看着像「戛然而止」。改为渐变自带 alpha：顶部即带背景色压暗，到底部
        // 82% 处已是纯背景色，clip 掉的那段和页面底色同色，自然看不出边界。
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            this.CoverArt()
          }
          .width('100%')
          .height(84)
          .scale({ x: 1, y: -1 })

          Column()
            .width('100%')
            .height(30)
            .linearGradient({
              angle: 180,
              colors: [
                ['#800B0B0F', 0.0],
                ['#B30B0B0F', 0.40],
                ['#FF0B0B0F', 0.82],
                ['#FF0B0B0F', 1.0]
              ]
            })
        }
        .width('100%')
        .height(30)
        .clip(true)
      }
      .width('100%')

      Text(this.card.name)
        .fontSize(11)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(`${this.card.count} 部`)
        .fontSize(9)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
    }
    .width(148)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen(this.card.id, this.card.name);
    })
    // 传方法引用，不要传 `this.CardMenu()` —— 那是执行结果（void），菜单会是空的
    .bindContextMenu(this.CardMenu, ResponseType.LongPress)
  }
}

@Component
export struct HomeTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** 每次回到首页 +1：只换内容，不显示骨架（见 silentRefresh）。 */
  @Prop @Watch('onResume') resumeKey: number = 0;
  /** 左侧光晕的当前透明度（0 = 不显示）。 */
  /** 顶部状态栏高度（真全屏下顶栏要让出这么多，见 Index.readInsets）。 */
  @StorageProp('amaneTopInset') topInset: number = 30;
  @State glowA: number = 0;
  /**
   * 主滚动区的控制器：底栏自动收起要用**绝对偏移**判断方向。
   * `onScroll(x, y)` 的参数是「本帧滚了多少」的标量（回滚时符号也不可靠，真机实测
   * 只看到过 +1 / -2 这种抖动值），拿它判方向会一直以为在往下看。
   */
  private sc: Scroller = new Scroller();
  /**
   * 导航栈（四十三改）：首页套 Navigation 只为了拿到**标题栏这个材质落点**，
   * 栈里永远只有本页自己 —— 和媒体库同样的用法。
   */
  private navStack: NavPathStack = new NavPathStack();
  @State home: HomeData = emptyHome();
  /** 这次真的要铺的行（顺序 / 显隐来自「设置 → 首页内容」）。 */
  @State sections: HomeSection[] = [];
  @State loading: boolean = true;
  /** 光效档位（设置里可降）：2=全开 / 1=少 / 0=关。首屏占位背景按它决定画多少。 */
  @StorageProp('amaneFx') fx: number = 2;
  @State error: string = '';
  /**
   * 顶部大图还在等这次的数据（缓存首帧阶段）。
   * 为什么要有它：hero 是**每次 fresh 都重洗**的，先把上次那部画出来再换成新的，
   * 无论怎么淡化都是"换了台"；这一块干脆等真数据，一次画对（2026-11-16 用户反馈）。
   */
  @State heroSkeleton: boolean = false;
  /** 首页「媒体库」一栏的卡（含自定义封面 / 拼贴海报）。 */
  @State libCards: LibCard[] = [];
  /** 下拉刷新中（Refresh 的双向绑定）。 */
  @State pulling: boolean = false;
  /** 每日推荐的整批理由（纯客户端生成，不占卡片版面）。 */
  @State reasonPack: ReasonPack = emptyReasons();
  @State reasonOn: boolean = true;
  /** 老缓存补拉统计只试一次，避免不支持该字段的服务端每次冷启动都被多打一次。 */
  private statsTried: boolean = false;
  /** 右滑进负一屏的触摸采样（只观测，不参与手势仲裁；-1 = 本次未起手）。 */
  private swipeX0: number = -1;
  private swipeY0: number = 0;
  private swipeX1: number = 0;
  private swipeY1: number = 0;
  /** Down 时的横坐标（用来判断「是不是从左侧边缘起手」）。 */
  private swipeStartX0: number = -1;
  /** 起手点的 Y（vp，屏幕绝对），用来判断"上半屏起手"。 */
  private swipeStartY0: number = -1;
  /** 屏幕高缓存（vp）。只在第一次取，避免 Move 里频繁查询 display。 */
  private cachedScreenH: number = 0;

  aboutToAppear(): void {
    this.load();
    // 光晕：**1 秒硬延时**（2026-11-16 用户「不要管他加载多久了」）。
    // 之前挂在 `loading` 的 @Watch 上，但 `minus_glow` 这个偏好被"进过一次负一屏就自动关掉"
    // 的逻辑写成了 0，于是 prompt 再准也永远不显示 —— 见 pulseGlowOnce() 里改掉的门禁。
    setTimeout(() => {
      this.pulseGlowOnce();
    }, 1000);
  }

  /**
   * 打开负一屏（刷一刷）——**不再 router.push**（2026-11-14 13:15）。
   *
   * 用户反馈：「不跟手，一开始只出来一点，拉到中间偏右了才突然弹出来」。
   * 根因是 router 页面要等**抬手**才会开始转场，手指移动过程中页面上什么都没有。
   * 现在改成：首页把手指位移实时写进 `AppStorage['minusDx']`，
   * 由 `Index` 里的负一屏图层按这个位移实时平移（跟手），抬手再决定吸附开/关。
   */
  private openShorts(): void {
    this.glowA = 0;
    // 进来三次才不再提醒（2026-11-16 用户：一次太少，完全不关也不好）。
    // 计数落在偏好里，跨启动累计；设置页手动关掉的（minus_glow=0）保持尊重。
    const seen: number = Number(Store.I.prefString('minus_glow_seen', '0')) || 0;
    const next: number = seen + 1;
    Store.I.prefSetString('minus_glow_seen', `${next}`);
    if (next >= 3 && Store.I.prefString('minus_glow_keep', '0') !== '1') {
      Store.I.prefSetString('minus_glow', '0');
    }
    AppStorage.setOrCreate<string>('minusCmd', 'open');
  }

  /**
   * 左侧光晕：一次会话只闪一次（AppStorage 记住），三次呼吸后停。
   * 「提示到、但不烦人」是这个组件唯一的目标；可在 设置 → 预览 里关掉。
   */
  private pulseGlowOnce(): void {
    // 一次性迁移（2026-11-16）：老版本「进过一次负一屏就自动关掉」把 `minus_glow` 写成了 0，
    // 用户没在设置里关过，却从此再也看不到（连报两轮"不触发"就是这个）。
    // 这里把历史遗留的 0 复位一次，之后完全尊重设置页的开关。
    if (Store.I.prefString('minus_glow_reset_v1', '0') !== '1') {
      Store.I.prefSetString('minus_glow_reset_v1', '1');
      if (Store.I.prefString('minus_glow', '1') === '0') {
        Store.I.prefSetString('minus_glow', '1');
      }
    }
    if (Store.I.prefString('minus_glow', '1') === '0') {
      return;
    }
    if (AppStorage.get<boolean>('glowShown') === true) {
      return;
    }
    AppStorage.setOrCreate<boolean>('glowShown', true);
    let step: number = 0;
    const tick = () => {
      step++;
      this.glowA = step % 2 === 1 ? 0.42 : 0;
      if (step < 6) {
        // 节奏放慢（2026-11-16 用户：稍微慢一点点）：980ms 一呼一吸，三次约 6 秒
        setTimeout(tick, 980);
      }
    };
    setTimeout(tick, 900);
  }

  /**
   * 首页数据一变就重算理由。理由按「日期 + item.id」稳定复现，
   * 所以下拉刷新不会让同一部片换一句话；换一天才会。
   */
  private refreshReasons(): void {
    this.reasonOn = Reason.enabled();
    if (!this.reasonOn) {
      this.reasonPack = emptyReasons();
      return;
    }
    // 理由要对着「推荐那一行实际展示的片」生成（旧服务端兜底时会剔掉顶部已用的前 6 部）
    const items: MediaItem[] = this.bannerRowList();
    if (items.length === 0) {
      this.reasonPack = emptyReasons();
      return;
    }
    // 全库统计摘要由 /api/user/home 下发；老服务端没有该字段时 undefined，
    // Reason.build 会自动跳过全库族，其余理由照常生成。
    // 注意：服务端给的那句 reason_text 在 Reason.build 内部就优先用了（否则它落盘的
    // 快照还是旧的，理由抽屉与详情页会跟首页不一致）。
    const pack: ReasonPack = Reason.build(items, this.home.continue, this.home.library_stats);
    this.reasonPack = pack;
    // 老缓存兜底：home 会被 PageCache 落盘（TTL 5 分钟 / 跨重启仍在），服务端
    // 刚升级完时首屏很可能还是升级前那份没有 library_stats 的 JSON。补一次
    // 不走缓存的请求，拿到统计后重算 —— 同一天同一批的理由结果稳定，不会跳字。
    if (this.home.library_stats === undefined && !this.statsTried) {
      this.statsTried = true;
      this.fetchStatsAndRebuild(items);
    }
  }

  /**
   * 首页接口地址：带上「大图候选池」。
   * 条件 → 参数的拼法在 `common/PoolParams.ets`（负一屏共用同一份，见那里的说明）。
   */
  private homeUrl(fresh: boolean): string {
    const head: string = `${Store.I.user}/api/user/home?`;
    const q: string = PoolParams.query();
    return head + (fresh ? `fresh=1&${q}` : q);
  }

  /** 只补统计字段，不替换整份 home，避免把用户正在看的列表刷掉。 */
  private async fetchStatsAndRebuild(items: MediaItem[]): Promise<void> {
    try {
      const text: string = await httpGet(this.homeUrl(false), Store.I.token);
      const fresh: HomeData = safeHome(JSON.parse(text) as HomeData);
      if (fresh.library_stats !== undefined) {
        this.home.library_stats = fresh.library_stats;
        this.reasonPack = Reason.build(items, fresh.continue, fresh.library_stats);
      }
    } catch (err) {
      // 老服务端 / 断网都静默降级：全库族不出现，其余理由照常
      console.info('[amane] reason stats refresh failed');
    }
  }

  onRefresh(): void {
    this.load();
  }

  onResume(): void {
    if (this.resumeKey <= 0) {
      return;
    }
    this.silentRefresh();
  }

  /**
   * 每次回到首页：**静默换一批**（2.6.2.x）。
   *
   * 以前进首页走 `httpGetCached`（5 分钟）+ 服务端 5 分钟聚合缓存，所以一整天看到的推荐都一样，
   * 只有手动下拉才换。现在进页面就带 `fresh=1` 拿一份新的，但**不显示骨架屏**：
   * 旧内容先留着，新数据到了直接替换 —— 既不闪，也不会看着像在刷新。
   */
  private async silentRefresh(): Promise<void> {
    if (!Store.I.ready) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${this.homeUrl(true)}`, Store.I.token);
      this.home = safeHome(JSON.parse(text) as HomeData);
      this.syncCard();
      this.error = '';
      this.loading = false;
      this.refreshReasons();
      this.buildLibCards();
      this.buildSections();
    } catch (err) {
      const e = err as BusinessError;
      // 静默失败：留着旧内容，别因为换推荐失败就变成错误页
      console.info(`[amane] home silent: ${e.code} ${e.message}`);
    }
  }

  /**
   * 把「今日推荐 + 继续观看」写进偏好，桌面服务卡片读它（见 `common/CardCache`）。
   *
   * 只写一次字符串、不碰网络：卡片进程里没有 Store 的登录态，也不该为了看一眼
   * 今日推荐去跑一遍内网/外网判定。写失败不影响首页本身，所以整体吞掉。
   */
  private syncCard(): void {
    try {
      const p: CardPayload = payloadOf(this.home, (raw: string) => Store.I.img(raw));
      Store.I.prefSetString(KEY_CARD, JSON.stringify(p));
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] card sync: ${e.code}`);
    }
  }

  /**
   * 下拉刷新：**必须绕开两层缓存**，否则转了圈还是旧数据。
   * ① 客户端 httpGetCached（load() 用的）；② 服务端 /home 的 5 分钟聚合缓存 ——
   *    所以要带 `fresh=1`，服务端才会重算（横幅与推荐都会重新洗一批）。
   */
  private async pullRefresh(): Promise<void> {
    if (!Store.I.ready) {
      this.pulling = false;
      return;
    }
    this.pulling = true;
    try {
      const text: string = await httpGet(
        `${this.homeUrl(true)}`, Store.I.token);
      this.home = safeHome(JSON.parse(text) as HomeData);
      this.syncCard();
      this.error = '';
      this.loading = false;
      this.refreshReasons();
      this.buildLibCards();
      this.buildSections();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] home pull: ${e.code} ${e.message}`);
      if (this.home.rows.length === 0) {
        this.error = '首页加载失败，下拉重试';
      }
    }
    this.pulling = false;
  }

  private async load(): Promise<void> {
    if (!Store.I.ready) {
      // 冷启动时 Index 还没拿到 config，稍后 refreshKey 变化会再来一次
      this.loading = false;
      return;
    }
    this.error = '';
    const url: string = this.homeUrl(false);
    // 先用缓存把首页画出来（哪怕已过期）：来回切 tab 不用每次都看骨架屏
    if (this.home.rows.length === 0 && this.home.hero.length === 0) {
      const stale: string | undefined = cachedBody(url);
      if (stale !== undefined) {
        try {
          this.home = safeHome(JSON.parse(stale) as HomeData);
          // ★ 缓存首帧**不画顶部大图**（2026-11-16 用户反馈「先显示上次那部，然后硬跳成新的」）★
          // 服务端 `build_hero` 每次 fresh 都重洗，缓存的那部与本次必然不同 ——
          // 与其先画 A 再淡成 B（之前 260ms 压暗淡入，用户仍觉得"跳"），不如这一块先留骨架，
          // 等 fresh 回来一次性画对的那部。行列表照旧用缓存铺，不闪整页。
          this.heroSkeleton = true;
          this.syncCard();
          this.loading = false;
        } catch (err) {
          console.info('[amane] home cache parse failed');
        }
      }
    }
    try {
      // 冷启动也不吃缓存：带 fresh=1 直接拿新的一批（推荐 / 横幅都要换）。
      // 以前这里是 httpGetCached(..., 300000)，所以「重开 App 还是同一份」（2026-11-13 反馈）。
      // 首屏仍然先用上面那段 cachedBody 铺出来，不闪骨架；网络回来再替换。
      const text: string = await httpGet(
        `${this.homeUrl(true)}`, Store.I.token);
      this.home = safeHome(JSON.parse(text) as HomeData);
      // 留一份给下次冷启动"先画出来"用（只是画面上的一帧，不代表数据是最新的）
      cachePut(url, text, 1800000);
      // 真数据到了：顶部大图从骨架换成这一次的那部（首次挂载带淡入，见 HeroBanner）
      this.heroSkeleton = false;
      this.syncCard();
      this.loading = false;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] home: ${e.code} ${e.message}`);
      if (this.home.rows.length === 0) {
        this.error = '首页加载失败，下拉重试';
      }
      // 拉不到新数据就别让骨架一直挂着：退回缓存里那部（有总比空着强）
      this.heroSkeleton = false;
      this.loading = false;
    }
    this.refreshReasons();
    this.buildLibCards();
    this.buildSections();
    this.warmHero();
    // 光晕由 aboutToAppear 的 1 秒硬延时触发，这里不再掺一脚
  }

  /**
   * 预热首页大图那部片的首块（2.6.1.85）。
   *
   * 为什么只预热第 1 部：它是进首页默认显示的那张，也是「立即播放」最可能点到的。
   * 用户划到第 3 张再点，那就回到「没预热」的老路径 —— 和以前一样，不会更差。
   */
  private warmHero(): void {
    if (!Store.I.ready) {
      return;
    }
    const hero: MediaItem[] = this.heroList();
    if (hero.length === 0) {
      return;
    }
    const id: number = hero[0].id;
    const now: number = Date.now();
    const at: number | undefined = HOME_WARM_AT.get(id);
    if (at !== undefined && now - at < 600000) {
      return;
    }
    HOME_WARM_AT.set(id, now);
    const url: string = Store.I.playUrl(id);
    // 等首屏图片和布局先跑完，再抢带宽去做预热
    setTimeout(() => {
      httpWarmStream(url).catch(() => {
        // 预热失败不影响任何东西
      });
    }, 900);
  }

  /**
   * 顶部大图的数据源（2.6.1.78）。
   *
   * 线上 8770 还是服务端 1.4.52 —— 那个版本的 `hero` **就是「每日推荐」的前 6 部**
   * （`h[0].id === recommend[0].id` 是它的指纹），而推荐是按分数固定排序的：
   * 客户端就算每次带 `fresh=1`，服务端也只洗「横幅」那一行，顶部永远同一部。
   * 用户 2026-11-13 23:35：「每次打开 app，首页 hero 横幅一直是同一个影片」。
   *
   * 兜底：旧服务端时顶部改用 `banners` —— 那一行**服务端每次 fresh 都会洗**，
   * 实测连续三次请求 banner0 分别是 JUR-081 / SDAM-8302 / ABP-171。
   * 新服务端（1.4.58+）有独立 hero 池且与推荐互斥，这个分支不会进来。
   */
  private legacyHero(): boolean {
    const h: MediaItem[] = this.home.hero;
    const r: MediaItem[] = this.home.recommend;
    if (h.length === 0) {
      return true;
    }
    if (r.length === 0) {
      return false;
    }
    return h[0].id === r[0].id;
  }

  private heroList(): MediaItem[] {
    if (!this.legacyHero()) {
      return this.home.hero;
    }
    const pool: MediaItem[] = this.home.banners.length >= 6 ? this.home.banners : this.home.recommend;
    return pool.slice(0, 6);
  }

  /**
   * 「每日推荐」那一行。
   *
   * 旧服务端走兜底时，顶部已经吃掉了 banners 的前 6 部 —— 这一行跳过它们，
   * 免得同一部在顶部和推荐位各出现一次（2.6.1.30 定下的规矩）。
   * 剩下不够 6 部就整份照给：宁可重复，也不要只剩两张。
   */
  private bannerRowList(): MediaItem[] {
    const pool: MediaItem[] = this.home.banners.length > 0 ? this.home.banners : this.home.recommend;
    if (!this.legacyHero()) {
      return pool;
    }
    const used: Set<number> = new Set<number>();
    const hero: MediaItem[] = this.heroList();
    for (let i = 0; i < hero.length; i++) {
      used.add(hero[i].id);
    }
    const rest: MediaItem[] = [];
    for (let i = 0; i < pool.length; i++) {
      if (!used.has(pool[i].id)) {
        rest.push(pool[i]);
      }
    }
    return rest.length >= 6 ? rest : pool;
  }

  /**
   * 媒体库卡：封面优先用用户换过的，没有就拿该库最近两部的海报拼。
   * 海报只能从 `home.rows` 里借（每行就是这个库的前 18 部），没有行的小库
   * 就显示首字 —— 不为它单独再发一次请求。
   */
  private buildLibCards(): void {
    const cards: LibCard[] = [];
    for (let i = 0; i < this.home.libraries.length; i++) {
      const lib: LibraryInfo = this.home.libraries[i];
      const posters: string[] = [];
      for (let r = 0; r < this.home.rows.length && posters.length < 2; r++) {
        const row: HomeRow = this.home.rows[r];
        if (row.library_id !== lib.id) {
          continue;
        }
        for (let k = 0; k < row.items.length && posters.length < 2; k++) {
          const p = row.items[k].poster;
          if (p !== undefined && `${p}`.length > 0) {
            posters.push(`${p}`);
          }
        }
      }
      cards.push({
        id: lib.id,
        name: lib.name,
        count: lib.count,
        cover: lib.cover === undefined || lib.cover === null ? '' : lib.cover,
        posters: posters
      });
    }
    this.libCards = cards;
  }

  /**
   * 按偏好排一次首页：「服务端这次给了哪些行」∩「用户要的显隐与顺序」。
   *
   * 只影响行的排列，不改任何一行的内部版式；`key` 用媒体库 id 而不是标题，
   * 改名不会让已存的顺序失效。偏好里没有的新库会自动追加到末尾并打开。
   */
  private buildSections(): void {
    const avail: HomeSection[] = [];
    const keys: string[] = [];
    if (BuildConfig.ENABLE_ACTORS) {
      avail.push({
        key: 'cast', kind: 'cast', title: '甄选', subtitle: '',
        libraryId: 0, moreKind: '', items: []
      });
      keys.push('cast');
    }
    if (this.home.continue.length > 0) {
      avail.push({
        key: 'continue', kind: 'continue', title: '继续观看', subtitle: '接着上次的进度',
        libraryId: 0, moreKind: 'history', items: this.home.continue
      });
      keys.push('continue');
    }
    if (this.home.banners.length > 0 || this.home.recommend.length > 0) {
      avail.push({
        key: 'banner', kind: 'banner', title: '每日推荐',
        subtitle: this.reasonOn ? this.reasonPack.headline : Reason.DEFAULT_SUBTITLE,
        libraryId: 0, moreKind: 'library',
        items: this.bannerRowList()
      });
      keys.push('banner');
    }
    // 「媒体库」目录：横向一排卡片，一眼看到每个库长什么样、各有多少片
    if (this.libCards.length > 0) {
      avail.push({
        key: 'libs', kind: 'libs', title: '媒体库', subtitle: `${this.libCards.length} 个`,
        libraryId: 0, moreKind: '', items: []
      });
      keys.push('libs');
    }
    for (let i = 0; i < this.home.rows.length; i++) {
      const row: HomeRow = this.home.rows[i];
      const key: string = `row:${row.id}`;
      avail.push({
        key: key, kind: 'row', title: row.title, subtitle: `${row.count} 部`,
        libraryId: row.library_id, moreKind: 'library', items: row.items
      });
      keys.push(key);
    }

    const ordered: string[] = Personalize.orderKeys(keys);
    const out: HomeSection[] = [];
    for (let i = 0; i < ordered.length; i++) {
      for (let j = 0; j < avail.length; j++) {
        if (avail[j].key === ordered[i]) {
          out.push(avail[j]);
          break;
        }
      }
    }
    this.sections = out;
  }

  private openDetail(item: MediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openPlayer(item: MediaItem): void {
    const params: DetailParams = { id: item.id, autoplay: true, position: item.position };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openLibrary(id: number, title: string): void {
    const params: BrowseParams = { libraryId: id, title: title };
    router.pushUrl({ url: 'pages/LibraryPage', params: params });
  }

  /** 媒体库封面按 `lib-<id>` 存（和分类封面同一张表，kind=library）。 */
  private libCoverUrl(card: LibCard): string {
    return `${Store.I.user}/api/user/cover-any/library/${encodeURIComponent(`lib-${card.id}`)}`;
  }

  private async pickLibCover(card: LibCard): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const opt: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
      if (res.photoUris.length === 0) {
        return;
      }
      const uri: string = res.photoUris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(f.fd).size;
      if (size > 8 * 1024 * 1024) {
        fileIo.closeSync(f);
        promptAction.showToast({ message: '图太大了（超过 8MB），换一张', duration: 2000 });
        return;
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(buf));
      let ext: string = 'jpg';
      const lower: string = uri.toLowerCase();
      if (lower.indexOf('.png') >= 0) {
        ext = 'png';
      } else if (lower.indexOf('.webp') >= 0) {
        ext = 'webp';
      } else if (lower.indexOf('.gif') >= 0) {
        ext = 'gif';
      }
      const body: Record<string, Object> = { 'data': b64, 'ext': ext };
      const raw: string = await httpPost(this.libCoverUrl(card), Store.I.token, JSON.stringify(body));
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        promptAction.showToast({ message: '封面换好了', duration: 1500 });
        this.load();
      } else {
        promptAction.showToast({ message: '没换成功，稍后再试', duration: 1600 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib cover: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没换成功（选图或上传失败）', duration: 1800 });
    }
  }

  /** 媒体库动图封面：取库里最近几部的海报拼轮播（服务端合成）。 */
  private async makeLibGif(card: LibCard): Promise<void> {
    promptAction.showToast({ message: '正在用库里的海报拼动图，约 10 秒…', duration: 3000 });
    try {
      const url: string = `${Store.I.user}/api/user/facet-gif/library/` +
        encodeURIComponent(`lib-${card.id}`);
      const body: Record<string, Object> = { 'count': 6, 'duration': 900 };
      const raw: string = await httpPost(url, Store.I.token, JSON.stringify(body), 90000);
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj.ok === true) {
        dropPageCache();
        Store.I.coverDirty = true;
        promptAction.showToast({ message: '动图封面好了', duration: 1500 });
        this.load();
      } else {
        const why: string = obj.reason === undefined || obj.reason === null ? '' : `${obj.reason}`;
        promptAction.showToast({ message: why.length > 0 ? why : '没做成，稍后再试', duration: 2200 });
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib gif: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没做成（服务端可能不支持）', duration: 2200 });
    }
  }

  private async restoreLibCover(card: LibCard): Promise<void> {
    try {
      await httpDelete(this.libCoverUrl(card), Store.I.token);
      dropPageCache();
      promptAction.showToast({ message: '已恢复默认封面', duration: 1500 });
      this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] lib cover del: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没恢复成，稍后再试', duration: 1600 });
    }
  }

  @Builder
  Header() {
    Row() {
      // ★ 2026-11-18 四十三改：真的系统材质 ★
      //
      // 用户问「我要的就是系统材质，为什么不行？」—— 因为**位置**不对，不是参数不对。
      // 沉浸材质的落点是官方硬限制：只有 Navigation/NavDestination 的**标题栏**、
      // `barPosition: End` 的底部 TabBar 里才出像素。之前这条 header 是画在内容区里的
      // 自建 Row（首页根 Stack 的一层），挂 `systemMaterial` 一个像素都不会有 ——
      // 这就是当时只能退成「模糊 + 极薄暗底」那种兜底的原因。
      //
      // 现在整页套了 Navigation，这条 header 经 `title(builder, { barStyle: STACK })`
      // 搬进了标题栏（与媒体库完全同一个落点），所以 `mat: true` 是真的材质：
      // 折射、边缘光、阴影都由系统画，我们**不再铺任何底色**（`tint: ''`）。
      GlassBox({ radius: 23, padH: 14, padV: 9, mat: true, tint: '' }) {
        // ★ 四十四改：左上角这一颗的**规范**（用户定的，之后每页都照这个来）★
        // 「位置和大小要参考媒体库这一颗」= 20 号 / Bold / 白 / 暗投影，装在 46 高的玻璃胶囊里。
        // 原来是 15 号 Medium + 字间距的品牌签名，用户要求放大加粗到标题量级。
        PageTitle({ text: 'Amane', fs: 20 })
      }
      Blank()
      // 搜索键（五十六改）：**与收藏/演员/标签完全同一颗** —— 42 见方、圆角 21、图标 18。
      // 之前首页是 46/23/20，比例虽然一致，但用户要的「统一」是一个像素都别差。
      GlassIcon({
        icon: $r('app.media.ic_search'),
        iconSize: 18,
        boxW: 42,
        boxH: 42,
        radius: 21,
        mat: true,
        tint: '',
        onTap: () => {
          router.pushUrl({ url: 'pages/SearchPage' });
        }
      })
    }
    .width('100%')
    .height(46)
    .alignItems(VerticalAlign.Center)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 标题栏配置（四十三改）：首页 header 搬进 Navigation 标题栏后，高度 = 状态栏 + 8 + 46 + 8。
   *
   * 写成有明确返回类型的方法，不是内联对象字面量 —— 联合类型下内联 `{ builder, height }`
   * 会触发 `arkts-no-untyped-obj-literals`（媒体库那一版踩过）。
   */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar()
      },
      height: 62 + this.topInset
    };
  }

  /** 标题栏壳：只让出状态栏，玻璃胶囊由里面的 Header 自己挂材质。 */
  @Builder
  TitleBar() {
    Column() {
      this.Header()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset + 8 })
  }

  /**
   * 公开扩展 actors 的特色入口卡（甄选）。
   *
   * 从 build() 里搬出来只是为了让首页那段 ForEach 短一点；
   * 版式与 2.4.x 完全一致，别顺手改。
   */
  @Builder
  CastEntry() {
    // 外层 Column 承担左右留白：Row 再设 width('100%') 时，
    // 100% 就是「已减掉留白」的宽度，不会像 margin 那样把整条撑出屏幕。
    Column() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('甄选')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT)
            Text('特色')
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(4)
          }
          Text('按演员、标签、人数、媒体库等条件自由组合，筛出你要的片子')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(2)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('去试 ›')
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(Theme.accentAlpha(0.22))
          .borderRadius(Theme.R_PILL)
          .border({ width: 1, color: Theme.accentAlpha(0.45) })
      }
      .width('100%')
      .padding(Theme.G_L)
      .backgroundColor(Theme.CARD)
      .borderRadius(Theme.R_CARD)
      .border({ width: 1, color: Theme.STROKE })
      .onClick(() => {
        router.pushUrl({ url: 'ext/actors/CastFinderPage' });
      })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    .margin({ bottom: 12 })
  }

  /** 理由卡左侧的封面：按 id 从当天这批里找，找不到就不画图（不占位）。 */
  private reasonCover(id: number): string {
    const arr: MediaItem[] = this.home.banners.length > 0 ? this.home.banners : this.home.recommend;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].id === id) {
        return arr[i].poster.length > 0 ? arr[i].poster : arr[i].fanart;
      }
    }
    return '';
  }

  build() {
    // ★ 2026-11-18 四十三改：整页套一层 Navigation ★
    //
    // 唯一目的：让顶上那条 header 落到**标题栏**里 —— 沉浸材质只认这个位置。
    // 与媒体库（`LibraryTab`）完全同一个结构：`title(builder, { barStyle: STACK })`，
    // 标题栏浮在内容之上，大图从它底下穿过去，玻璃才有东西可采样。
    // 内容树的层次一个都没动，只是外面多了一层壳。
    Navigation(this.navStack) {
    Stack({ alignContent: Alignment.TopStart }) {
      // 左边缘漏光：放在**最底层**（2026-11-16 用户报「左侧 110vp 内滑不动」——
      // 它原来压在内容上面，虽然设了 hitTestBehavior(None)，实测仍吃掉纵向手势）。
      // 放底层照样能「从边缝漏出来」：列表与卡片本身透明，光从它们底下的空隙透上来。
        // 左边缘「漏光」（2026-11-16 用户：不要真是一根条，要像负一屏里有宝藏、光从边缝漏出来）。
        //
        // ★ 不要用 `.blur()` ★（2026-11-16 用户报「有一层毛玻璃盖住首页内容」）：
        //   这一层是透明容器，`blur` 会把**它背后**的首页内容一起糊掉，看起来就是毛玻璃。
        //   柔光改用「径向渐变多档衰减 + 两层不同半径叠加」做，纯颜色渐变，不动背后像素。
        Stack({ alignContent: Alignment.TopStart }) {
          // 外层：更大更淡的一圈，负责"光晕"的扩散感
          Column()
            .width('100%')
            .height('100%')
            .radialGradient({
              center: ['0%', '50%'],
              radius: '150%',
              colors: [
                [Theme.accentAlpha(0.30), 0],
                [Theme.accentAlpha(0.16), 0.35],
                [Theme.accentAlpha(0.06), 0.65],
                [Theme.accentAlpha(0.0), 1]
              ]
            })
            .hitTestBehavior(HitTestMode.None)
          // 内层：贴着边缘更亮，给出"光从缝里透进来"的核心
          Column()
            .width('100%')
            .height('100%')
            .radialGradient({
              center: ['0%', '50%'],
              radius: '85%',
              colors: [
                [Theme.accentAlpha(0.62), 0],
                [Theme.accentAlpha(0.40), 0.22],
                [Theme.accentAlpha(0.18), 0.48],
                [Theme.accentAlpha(0.05), 0.72],
                [Theme.accentAlpha(0.0), 1]
              ]
            })
            .hitTestBehavior(HitTestMode.None)
        }
        .width(110)
        .height('100%')
        .opacity(this.glowA)
        .animation({ duration: 820, curve: Curve.EaseInOut })
        // 2026-11-16 用户报「负一屏提示光效被首页大图遮住」：这层原先在 Stack **最底层**
        // （为修「左边缘 110vp 内滑不动」），结果 hero 大图直接盖住它。
        // 现在用 zIndex 提到内容之上；触摸靠 None 穿透（下面两个内层渐变也要 None ——
        // `HitTestMode.None` 只作用于自身，子节点默认仍参与命中，
        // 这正是当初「设了 None 还挡手势」的真因）。
        .zIndex(3)
        .hitTestBehavior(HitTestMode.None)

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Theme.ACCENT)
          Text('正在整理媒体库…')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 12 }) {
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.TEXT_DIM)
          Button('重试')
            .height(36)
            .backgroundColor(Theme.CARD)
            .fontColor(Theme.TEXT)
            .fontSize(13)
            .onClick(() => {
              this.loading = true;
              this.load();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 下拉刷新：refresh 包住 List（Header 是悬浮层，不能包进去）。
        // refreshing 用 $$ 双向绑定，onRefreshing 里置 true 由 pullRefresh 收尾置 false。
        Refresh({ refreshing: $$this.pulling }) {
          List({ scroller: this.sc }) {
          ListItem() {
            if (this.heroSkeleton) {
              // 缓存首帧：不画任何色块（2026-11-16 用户：别留一大块丑的灰片），
              // 但也不能是纯黑 —— 用和「启动加载连库」同一套背景（呼吸光团 + 浮尘），
              // 让这块看起来本来就是背景的一部分。
              Stack({ alignContent: Alignment.Center }) {
                if (this.fx >= 1) {
                  GlowOrb({
                    color: Theme.ACCENT,
                    diameter: this.fx >= 2 ? 320 : 240,
                    alpha: 0.22,
                    breath: true,
                    period: 3600
                  })
                }
                if (this.fx >= 2) {
                  ParticleField({ count: 18, color: '#FFFFFF', alpha: 0.30, drift: 0.6 })
                }
              }
              .width('100%')
              .height(Theme.HERO_H)
            } else {
              HeroBanner({
                items: this.heroList(),
                onPlay: (item: MediaItem) => {
                  this.openPlayer(item);
                },
                onDetail: (item: MediaItem) => {
                  this.openDetail(item);
                }
              })
            }
          }
          // 2026-11-16：整块 hero（大图 + 番号/厂牌/标题 + 按钮行）都不参与「右滑进负一屏」。
          // 之前只在内部几个子节点上标记，实测仍会被 Swiper/压暗层截胡；直接在 ListItem 上标，
          // 这一块从根上不参与首页的右滑判定。
          .onTouch((ev: TouchEvent) => {
            if (ev.type === TouchType.Down || ev.type === TouchType.Move) {
              AppStorage.setOrCreate<number>('rowTouchAt', Date.now());
            }
          })

          // 2.6.1.61：原来那行「刷一刷」入口删了 —— 挪到负一屏（首页左滑进入），
          // 首页只保留最左侧那条会闪几次的光晕做提示（见 build() 里 GlowHint）。


          // 行的顺序与显隐来自「设置 → 首页内容」（2.5.2）：这里按 sections 铺，
          // 每行内部版式与原来完全一致，只是改由数据驱动。顶部大图固定在最上面。
          ForEach(this.sections, (s: HomeSection) => {
            ListItem() {
              if (s.kind === 'cast') {
                this.CastEntry()
              } else if (s.kind === 'libs') {
                LibraryRow({
                  cards: this.libCards,
                  onOpen: (id: number, name: string) => {
                    this.openLibrary(id, name);
                  },
                  onPickCover: (card: LibCard) => {
                    this.pickLibCover(card);
                  },
                  onMakeGif: (card: LibCard) => {
                    this.makeLibGif(card);
                  },
                  onRestoreCover: (card: LibCard) => {
                    this.restoreLibCover(card);
                  }
                })
              } else if (s.kind === 'banner') {
                // 每日推荐用高清横幅：优先用服务端校验过的真横图（带真实比例），
                // 没有时才退回推荐列表（按 16:9 裁切）。
                BannerRow({
                  title: s.title,
                  subtitle: s.subtitle,
                  items: s.items,
                  // 每张卡自己的理由（2.6.1.36）：贴在各自海报下方，和片对得上号
                  lines: this.reasonOn ? this.reasonPack.lines : [],
                  whyLabel: this.reasonOn ? '推荐理由' : '',
                  onWhy: () => {
                    router.pushUrl({ url: 'pages/ReasonsPage' });
                  },
                  onTap: (item: MediaItem) => {
                    this.openDetail(item);
                  },
                  // 「全部」= 今天这批推荐的全部理由（原来是跳到全部影片，语义不对）
                  onMore: () => {
                    router.pushUrl({ url: 'pages/ReasonsPage' });
                  }
                })
              } else {
                MediaRow({
                  title: s.title,
                  subtitle: s.subtitle,
                  items: s.items,
                  onTap: (item: MediaItem) => {
                    this.openDetail(item);
                  },
                  onMore: () => {
                    if (s.moreKind === 'history') {
                      router.pushUrl({ url: 'pages/HistoryPage' });
                    } else {
                      this.openLibrary(s.libraryId, s.title);
                    }
                  }
                })
              }
            }
          }, (s: HomeSection) => s.key)

          ListItem() {
            Text(`共 ${this.home.libraries.length} 个媒体库 · Amane`)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 96 })
          }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 滚动时让粒子闭嘴（2.6.1.18 光效预算）：指到新的可见行就喊一声，
          // 停手 420ms 后自动恢复。首页大图那块 Canvas 是整页最贵的一层。
          .onScrollIndex((first: number, last: number) => {
            markScroll();
          })
          // 往下看收起底栏、往回划弹回来（2026-11-15，学 piliplus）。
          // 用控制器的**绝对偏移**差分：`onScroll` 的参数是标量增量，判不了方向。
          .onScroll((x: number, y: number) => {
            NavBarWatch.onOffset(this.sc.currentOffset().yOffset);
          })
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => {
          this.pullRefresh();
        })

        // 四十三改：header 已搬进 Navigation 标题栏（`TitleBar`），这里不再画第二遍。

        // 负一屏提示（2.6.1.68）：首页元素太密，光带本身在满屏内容里几乎看不见，
        // 所以提示时**把整页压暗一点**（8% 黑），光带在暗底上才跳得出来；闪完两层一起退。
        Column()
          .width('100%')
          .height('100%')
          .align(Alignment.TopStart)
          .backgroundColor('#000000')
          .opacity(this.glowA * 0.22)
          .animation({ duration: 820, curve: Curve.EaseInOut })
          .hitTestBehavior(HitTestMode.None)

        // 兜底点击区：只剩最左 12vp（原来 8vp 的光带也吃这块），点了能进负一屏；
        // 再往右就完全交给列表，纵向滑动不再被拦。
        Column()
          .width(12)
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.openShorts();
          })

        // 内容区左滑进负一屏（2.6.1.65）：手势挂在**根 Stack** 上（见下面的 .gesture），
        // 不在顶层再盖一层感应区 —— 盖一层会挡掉下面的点击，还得靠 hitTest 兜。
      }
    }
    .width('100%')
    .height('100%')
.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.BG)
    // 内容区**右滑** = 进负一屏（用户 00:49 定的方向）。
    //
    // ★ 为什么用 onTouch 自己算，而不是 PanGesture（2026-11-14 实测）★
    //   `.gesture()`      → 被列表/横向海报行先吃掉，收不到；
    //   `.priorityGesture()` → 父优先能收到，但**纵向也一起被它接管**，首页下拉刷新废掉
    //                        （2.6.2.8 就是这么把「大图下拉换一批」搞坏的）；
    //   Tabs 原生滑动开着时，横向手势同样先被 Tabs 的识别器拿走。
    // 触摸事件不受手势仲裁影响，parent 的 onTouch 照样能收到 down/move/up，
    // 所以我们只**观测**位移、不参与竞争：下拉、横滑海报行、点击全都不受影响。
    .onTouch((ev: TouchEvent) => {
      this.trackSwipe(ev);
    })
    }
    // 四十三改：Navigation 壳。内容仍是整屏（barStyle STACK = 标题栏浮在上面，
    // 大图照旧从屏幕最顶上开始），所以宽高都写满、背景色跟页面一致。
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  /** 记一次触摸的起止点（只观测，不消费事件）。 */
  private trackSwipe(ev: TouchEvent): void {
    // ★ 抬手时 `touches` 是**空数组**（那根手指已经离开），别拿它判「单指」——
    //   第一版就是这么写的，Up 全被守卫挡掉，「右滑没反应」照旧。位置在 Move 里存。
    // ★ 坐标用 `screenX/screenY`（**屏幕**绝对）★
    // 先试过 `x/y`：那是被点组件的局部坐标，手指落在「继续观看」那一行时是相对那一行的，
    // 行还会跟着手指滚动 —— 实测一次 500→1100 的滑动报成 x0=148 / dx=177，全被带偏。
    if (ev.type === TouchType.Down) {
      if (ev.touches.length === 1) {
        this.swipeX0 = ev.touches[0].screenX;
        this.swipeY0 = ev.touches[0].screenY;
        this.swipeX1 = this.swipeX0;
        this.swipeY1 = this.swipeY0;
        this.swipeStartX0 = this.swipeX0;
        this.swipeStartY0 = this.swipeY0;
      } else {
        this.swipeX0 = -1;
        this.swipeStartX0 = -1;
        this.swipeStartY0 = -1;
      }
      return;
    }
    if (ev.type === TouchType.Move) {
      if (ev.touches.length === 1 && this.swipeX0 >= 0) {
        this.swipeX1 = ev.touches[0].screenX;
        this.swipeY1 = ev.touches[0].screenY;
        // 跟手（2026-11-14 13:15）：手指还在滑的时候就把位移交给 Index 的负一屏图层，
        // 让它按真实位移平移；只在「看起来是右滑」时才发，避免纵向滚动把页面带着抖。
        const mvx: number = this.swipeX1 - this.swipeX0;
        const mvy: number = this.swipeY1 - this.swipeY0;
        if (this.entryZone(this.swipeStartX0, this.swipeStartY0) && !this.rowBusy()
          && mvx > 0 && Math.abs(mvx) > Math.abs(mvy) * 1.2) {
          AppStorage.setOrCreate<number>('minusDx', mvx);
        }
      }
      return;
    }
    if (this.swipeX0 < 0) {
      AppStorage.setOrCreate<number>('minusDx', 0);
      return;
    }
    const dx: number = this.swipeX1 - this.swipeX0;
    const dy: number = this.swipeY1 - this.swipeY0;
    const from: number = this.swipeStartX0;
    const startY: number = this.swipeStartY0;
    this.swipeX0 = -1;
    this.swipeStartX0 = -1;
    this.swipeStartY0 = -1;
    // 抬手：按位移决定吸附（开还是弹回）。阈值用屏宽的 30%，跟手之后不需要再卡「起手位置」。
    const w: number = this.screenW();
    if (ev.type === TouchType.Up && from >= 0 && this.entryZone(from, startY) && !this.rowBusy()
      && dx > 40 && Math.abs(dx) > Math.abs(dy) * 1.6) {
      if (dx > w * 0.30) {
        this.openShorts();
      } else {
        AppStorage.setOrCreate<string>('minusCmd', 'cancel');
      }
    } else {
      // 2026-11-16：拉出一点又没拉够时，**必须补间回弹**。
      // 原来这里直接把 minusDx 置 0，等于零帧归位 —— 表现就是「主页秒弹回、负一屏闪一下消失」。
      // 只要这一划真的带动过负一屏，就走 cancel 让 Index 用 180ms 弹回去。
      const movedRaw: number | undefined = AppStorage.get<number>('minusDx');
      const moved: number = movedRaw === undefined || movedRaw === null ? 0 : movedRaw;
      if (moved > 0) {
        AppStorage.setOrCreate<string>('minusCmd', 'cancel');
      } else {
        AppStorage.setOrCreate<number>('minusDx', 0);
      }
    }
  }

  /**
   * 右滑进负一屏的**起手区**（2026-11-14 21:02 用户要求放宽）。
   *
   * 之前只有「左侧 60vp」或「上半屏 520vp 以内」才算，实际手感是：
   * 站在列表里（"继续观看"那一带的下半屏）往右滑根本没反应，得贴着最左边才行。
   * 现在放宽成：**左侧 1/3 任意高度**，或 **0.8 屏高以内任意位置**。
   *
   * 会不会和横向海报行打架？不会 —— 行自己开始滚时会往 `rowDragAt` 记一笔
   * （`MediaRow` / `BannerRow` 的 `onScrollStart`），`rowBusy()` 为真时这一划直接不抢。
   */
  private entryZone(x: number, y: number): boolean {
    if (x < 0) {
      return false;
    }
    const h: number = this.screenH();
    // 底栏（胶囊 tab）以上**整屏都能起手**；横向海报行的区域由 rowBusy() 排除。
    return y >= 0 && y < h - 96;
  }

  /**
   * 这一划是不是落在横向行上（海报行 / banner 行）。
   *
   * 行组件在 `onTouch` 里持续写 `rowTouchAt`；`onTouch` 是子先父后，
   * 所以父层的 Move/Up 读到的永远是**刚被行刷新过**的时间戳 → 这一划不抢。
   * 只认 250ms 内的，避免"刚滑完海报马上从空白处右滑"被误伤。
   */
  private rowBusy(): boolean {
    const raw: number | undefined = AppStorage.get<number>('rowTouchAt');
    const at: number = raw === undefined || raw === null ? 0 : raw;
    return at > 0 && Date.now() - at < 250;
  }

  /** 屏幕宽（vp）。 */
  private screenW(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return px2vp(d.width);
    } catch (e) {
      return 390;
    }
  }

  /**
   * 屏幕高（vp），结果缓存一次（Move 里会被高频调用）。
   * 2026-11-14 19:20 加：起手判定原来写死 `y < 520`，而「继续观看」那一行正好在 520 以下，
   * 用户从「观看」两个字及右边起手永远进不去负一屏。改成按屏幕比例算，不写死像素。
   */
  private screenH(): number {
    if (this.cachedScreenH > 0) {
      return this.cachedScreenH;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.cachedScreenH = px2vp(d.height);
    } catch (e) {
      this.cachedScreenH = 844;
    }
    return this.cachedScreenH;
  }

  /**
   * 右滑进负一屏的起手区 —— 已由 `entryZone()`（左侧 1/3 任意高度，或 0.8 屏高内任意位置）
   * 取代；旧版这里的 `inSwipeZone()`（x<130 或 y<68% 屏高）在合并 2026-11-14 时删掉，
   * 因为它既没有 `rowBusy()` 这层「这一划落在横向海报行上就不抢」的保护，范围也更窄。
   */
}
