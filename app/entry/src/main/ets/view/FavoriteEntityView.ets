import { PosterRef } from '../common/Types';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 收藏页里「演员 / 导演 / 标签 / 系列」共用的一行数据。
 *
 * 四类收藏在服务端是两套存储（演员在 user.db，其余是上游 is_favorite），
 * 但展示形态按用户要求统一：左边封面（演员=头像，分类=最近作品海报），
 * 中间名称 + 共几部，右边紧贴一排可点的作品海报。
 */
/** 条目上的一枚小胶囊：文字 + 主题色（底色由组件自动加透明度）。 */
export interface FavBadge {
  text: string;
  color: string;
}

export interface FavEntity {
  /** actor / director / tag / series —— 只用于文案与列表 key。 */
  kind: string;
  id: number;
  name: string;
  count: number;
  cover: string;
  posters: PosterRef[];
  /**
   * 海报条下方那一行彩色小胶囊（演员：生日/身高/罩杯；分类：最近发行…）。
   * 以后分类新增属性，只要往这个数组里 push 一条就是新胶囊，不用改布局。
   */
  badges: FavBadge[];
}

/** 横版行里封面尺寸：宽 86、高 118（姓名与片数挪到封面下面，右边全留给海报）。 */
const COVER_W: number = 86;
const COVER_H: number = 118;
/** 海报条里每张海报的尺寸与间距（比上一版放大一档，一行约四张可见）。 */
const POSTER_W: number = 76;
const POSTER_H: number = 106;
const POSTER_GAP: number = 7;

/**
 * 统一条目视图：`grid=false` 是横版大行（默认），`grid=true` 是 3 列简版。
 *
 * 交互分工（避免误触）：
 *   - 点封面以外的整行 → 进这个演员/分类的详情页
 *   - 点右侧任意一张海报 → 直接进那部影片
 *   - 点封面右上角的心 → 取消收藏（就地移除，由父组件处理）
 */
@Component
export struct FavoriteEntityView {
  @Prop @Watch('onItemsChange') items: FavEntity[] = [];
  @Prop grid: boolean = false;
  onOpen: (e: FavEntity) => void = (e: FavEntity) => {};
  onFilm: (id: number) => void = (id: number) => {};
  onUnfav: (e: FavEntity) => void = (e: FavEntity) => {};

  onItemsChange(): void {
    // 父级换了数据（取消收藏 / 刷新）时不需要额外状态，保留钩子便于以后加动画
  }

  @Builder
  Heart(e: FavEntity) {
    Text('♥')
      .fontSize(12)
      .fontColor(Theme.ACCENT)
      .width(22)
      .height(22)
      .textAlign(TextAlign.Center)
      .borderRadius(11)
      .backgroundColor('#99000000')
      .onClick(() => {
        this.onUnfav(e);
      })
  }

  /** 横版行：一屏大约二到三行，封面与海报都放大一档。 */
  @Builder
  RowItem(e: FavEntity) {
    Row({ space: 12 }) {
      // 左列：封面（演员是头像）+ 姓名 + 片数，名字在头像下面而不是挤在中间
      Column({ space: 5 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          if (e.cover.length > 0) {
            Image(Store.I.img(e.cover))
              .width(COVER_W)
              .height(COVER_H)
              .objectFit(ImageFit.Cover)
              .borderRadius(9)
              .backgroundColor(Theme.CARD_HI)
              .alt($r('app.media.placeholder'))
          } else {
            Column() {
              Text(e.name.length > 0 ? e.name.substring(0, 1) : '?')
                .fontSize(24)
                .fontColor(Theme.TEXT_FAINT)
            }
            .width(COVER_W)
            .height(COVER_H)
            .justifyContent(FlexAlign.Center)
            .borderRadius(9)
            .backgroundColor(Theme.CARD_HI)
          }
          this.Heart(e)
        }
        .width(COVER_W)
        .height(COVER_H)

        Text(e.name.length > 0 ? e.name : '未命名')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(e.count > 0 ? `${e.count} 部` : '暂无作品')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
      }
      .width(COVER_W)
      .alignItems(HorizontalAlign.Start)

      // 右区：海报条 + 底下那行补充信息（原先这块是空白）
      Column({ space: 8 }) {
        Scroll() {
          Row({ space: POSTER_GAP }) {
            if (e.posters.length === 0) {
              Text('暂无海报')
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
                .height(POSTER_H)
                .padding({ right: 8 })
            } else {
              ForEach(e.posters, (p: PosterRef) => {
                Image(Store.I.img(p.url))
                  .width(POSTER_W)
                  .height(POSTER_H)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(7)
                  .backgroundColor(Theme.CARD_HI)
                  .onClick(() => {
                    this.onFilm(p.id);
                  })
              }, (p: PosterRef) => `fp-${e.kind}-${e.id}-${p.id}`)
            }
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(POSTER_H)
        .align(Alignment.Start)

        Row({ space: 8 }) {
          // 资料做成彩色小胶囊：比一行灰字好读，也方便以后加属性（加一条 FavBadge 即可）
          Flex({ wrap: FlexWrap.NoWrap, justifyContent: FlexAlign.Start }) {
            ForEach(e.badges.slice(0, 3), (b: FavBadge) => {
              Text(b.text)
                .fontSize(9)
                .fontColor(b.color)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(`#26${b.color.substring(1)}`)
                .borderRadius(7)
                .maxLines(1)
                .margin({ right: 4 })
            }, (b: FavBadge) => `bd-${e.kind}-${e.id}-${b.text}`)
          }
          .layoutWeight(1)
          .clip(true)

          Text('查看全部 ›')
            .fontSize(10)
            .fontColor(Theme.ACCENT)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
    .onClick(() => {
      this.onOpen(e);
    })
  }

  /** 3 列简版：只看封面和名字，适合快速浏览。 */
  @Builder
  GridItemView(e: FavEntity) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (e.cover.length > 0) {
          Image(Store.I.img(e.cover))
            .width('100%')
            .aspectRatio(0.74)
            .objectFit(ImageFit.Cover)
            .borderRadius(10)
            .backgroundColor(Theme.CARD)
            .alt($r('app.media.placeholder'))
        } else {
          Column() {
            Text(e.name.length > 0 ? e.name.substring(0, 1) : '?')
              .fontSize(22)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .aspectRatio(0.74)
          .justifyContent(FlexAlign.Center)
          .borderRadius(10)
          .backgroundColor(Theme.CARD)
        }
        this.Heart(e)
      }
      .width('100%')

      Text(e.name.length > 0 ? e.name : '未命名')
        .fontSize(12)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(e.count > 0 ? `${e.count} 部` : '暂无作品')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
    }
    .width('100%')
    .onClick(() => {
      this.onOpen(e);
    })
  }

  build() {
    if (this.grid) {
      Grid() {
        ForEach(this.items, (e: FavEntity) => {
          GridItem() {
            this.GridItemView(e)
          }
        }, (e: FavEntity) => `g-${e.kind}-${e.id}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(14)
      .width('100%')
    } else {
      Column({ space: 10 }) {
        ForEach(this.items, (e: FavEntity) => {
          this.RowItem(e)
        }, (e: FavEntity) => `r-${e.kind}-${e.id}`)
      }
      .width('100%')
    }
  }
}
