import { router } from '@kit.ArkUI';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BusinessError } from '@kit.BasicServicesKit';
import { LikedClip, likedSorted, removeLiked } from '../common/LikedShorts';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { GlassGlyph, PageTitle, GlassBack} from '../view/GlassKit';
import { SettingsAmbientGlow } from '../view/SettingsKit';

/**
 * 我的喜爱（刷一刷里点过心的片段）。
 *
 * 用户 2026-11-14 23:53：「要像抖音一样，要有地方可以查看『我的喜爱』，
 * 并且最好从表达上和正片的收藏能区分开。」
 *
 * 所以这一页刻意不叫「收藏」、也不复用收藏页：
 *   - 数据源是本机偏好 `shorts_like_items`（快照），不是服务端 favorites；
 *   - 每条记的是**片段**（番号 + 起点），点进去回到那一秒，不是从头放整片；
 *   - 顶部一句话把这个区别写清楚，避免用户以为「取消喜爱 = 取消收藏」。
 */
@Entry
@Component
struct MyLikedShortsPage {
  @State rows: LikedClip[] = [];
  @State note: string = '';

  /** onPageShow：从详情页回来可能已经取消喜爱了，重读一遍。 */
  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
    this.reload();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.rows = likedSorted();
  }

  private clock(sec: number): string {
    const s: number = Math.max(0, Math.round(sec));
    const h: number = Math.floor(s / 3600);
    const m: number = Math.floor((s % 3600) / 60);
    const ss: number = s % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const sss: string = ss < 10 ? `0${ss}` : `${ss}`;
    return h > 0 ? `${h}:${mm}:${sss}` : `${m}:${sss}`;
  }

  private openClip(c: LikedClip): void {
    router.pushUrl({
      url: 'pages/DetailPage',
      params: { id: c.id, position: c.start }
    }).catch((err: BusinessError) => {
      console.error(`[amane] liked -> detail: ${err.code} ${err.message}`);
    });
  }

  private unlike(c: LikedClip): void {
    removeLiked(c.id);
    // 爱心状态（shorts_likes）也要一起摘掉，否则回负一屏还是亮的
    const key: string = `${c.id}`;
    const ids: string[] = Store.I.prefString('shorts_likes', '')
      .split(',')
      .filter((k: string) => k.length > 0 && k !== key);
    Store.I.prefSetString('shorts_likes', ids.join(','));
    this.reload();
    this.note = `已经不喜爱 ${c.number}（不影响影片的收藏）`;
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 8 }) {
        // 五十八改：返回键换成基底的玻璃胶囊（与其它二级页统一）
        GlassBack({
          mat: true,
          onTap: () => {
          router.back();
          }
        })
        PageTitle({ text: '我的喜爱', fs: 18 })
        Blank()
        Text(this.rows.length > 0 ? `${this.rows.length} 条` : '')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: 16 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow()
        Column() {
        // 顶部：标题 + 一句「和收藏不一样」的说明

  // 六十改：让出浮层标题栏的高度
  Blank().height(this.barH())

        Text('刷一刷里点过心的片段。这里和影片的「收藏」是两件事：取消喜爱不会动收藏，收藏也不会出现在这里。')
          .fontSize(12)
          .fontColor(Theme.TEXT_DIM)
          .lineHeight(18)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 10 })

        if (this.note.length > 0) {
          Text(this.note)
            .fontSize(12)
            .fontColor(Theme.GOLD)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }

        if (this.rows.length === 0) {
          Column({ space: 10 }) {
            Text('♡')
              .fontSize(40)
              .fontColor(Theme.TEXT_DIM)
            Text('还没有喜爱')
              .fontSize(15)
              .fontColor(Theme.TEXT)
            Text('在负一屏点一下右侧的爱心，或者双击画面，就会收进这里')
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.rows, (c: LikedClip) => {
              ListItem() {
                this.Row(c)
              }
            }, (c: LikedClip) => `${c.id}_${c.at}`)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')

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

  @Builder
  Row(c: LikedClip) {
    Row({ space: 10 }) {
      // 海报（竖图）：没有海报就留一块底色，别显示破图
      if (c.poster.length > 0) {
        Image(Store.I.img(c.poster))
          .width(52)
          .height(74)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
      } else {
        Column() {
          Text('无图').fontSize(10).fontColor(Theme.TEXT_DIM)
        }
        .width(52)
        .height(74)
        .borderRadius(6)
        .backgroundColor(Theme.CARD)
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(c.number)
            .fontSize(13)
            .fontColor(Theme.GOLD)
            .fontWeight(FontWeight.Medium)
          if (c.actor.length > 0) {
            Text(c.actor)
              .fontSize(11)
              .fontColor(Theme.TEXT_DIM)
          }
        }
        .width('100%')

        Text(c.title.length > 0 ? c.title : c.number)
          .fontSize(13)
          .fontColor(Theme.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`片段 ${this.clock(c.start)} 起 · 共 ${Math.round(c.dur)} 秒`)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 取消喜爱（只是不喜爱，不动收藏）。
      // 触控区给到 44×44：22vp 的图标太小，真机点偏一点就落到整行的 onClick 上、
      // 变成「打开详情」了（2026-11-15 00:31 实测）。Block 让这一块自己吃掉点击，不传给整行。
      Column() {
        Image($r('app.media.ic_s_heart_on'))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.unlike(c);
      })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(16)
    .border({ width: 0.75, color: Theme.STROKE })
    .onClick(() => {
      this.openClip(c);
    })
  }
}
