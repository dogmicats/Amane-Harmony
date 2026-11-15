import { router } from '@kit.ArkUI';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { FacetItem, emptyFacet, FacetParams, PrefixParams, facetLabel } from './FacetTypes';
import { SectionHead } from '../../view/SectionHead';

/** @Prop 的默认值必须是完整字面量：FacetItem 新增字段时只改这里，别散落在组件里。 */
function emptyItemSeries(): FacetItem {
  return emptyFacet();
}

function openFacet(kind: string, item: FacetItem): void {
  if (item.id <= 0) {
    return;
  }
  const params: FacetParams = { kind: kind, id: item.id, name: item.name };
  router.pushUrl({ url: 'ext/facets/FacetPage', params: params });
}

/**
 * 公开扩展 facets：影片详情里的「所属系列」卡片。
 *
 * 系列信息以前只混在标题下方那一行元数据里（日期 · 时长 · 厂牌 · 系列），
 * 既是纯文本也没有「同系列还有哪些」的入口。这里独立成卡：
 * 左侧是系列内最近四部拼成的四宫格封面，右边是系列名 + 同系列片数 + 制片商，
 * 点一下直接进系列影片墙 —— 布局保持原样，只是把封面塞进了左侧那块空白。
 */
@Component
export struct SeriesCard {
  @Prop series: FacetItem = emptyItemSeries();
  @Prop studioName: string = '';

  private posterAt(i: number): string {
    return i < this.series.posters.length ? this.series.posters[i] : '';
  }

  @Builder
  Cover() {
    // 三张海报横向并列，按 2:3 原比例展示，不裁剪（旧版四宫格截图式裁切看不出海报原貌）
    Row({ space: 2 }) {
      if (this.series.posters.length === 0) {
        Column() {
          Text('系')
            .fontSize(16)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(40)
        .height(46)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.CARD_HI)
      } else {
        ForEach([0, 1, 2], (i: number) => {
          Image(i < this.series.posters.length ? Store.I.img(this.series.posters[i]) : '')
            .width(this.series.posters.length >= 2 ? 31 : 40)
            .height(46)
            .objectFit(ImageFit.Cover)
            .backgroundColor(Theme.CARD_HI)
            .alt($r('app.media.placeholder'))
            .visibility(i < this.series.posters.length ? Visibility.Visible : Visibility.None)
        }, (i: number) => `scv-${i}`)
      }
    }
    .height(46)
    .borderRadius(8)
    .clip(true)
    .backgroundColor(Theme.CARD_HI)
  }

  build() {
    Row({ space: 11 }) {
      Column()
        .width(3)
        .height(44)
        .backgroundColor(Theme.ACCENT)
        .borderRadius(2)

      this.Cover()

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text('所属系列')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
          if (this.series.count > 0) {
            Text(`${this.series.count} 部`)
              .fontSize(9)
              .fontColor(Theme.ACCENT)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.ACCENT_SOFT)
              .borderRadius(4)
          }
        }
        .width('100%')

        Text(this.series.name.length > 0 ? this.series.name : '未命名系列')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.studioName.length > 0) {
          Text(this.studioName)
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.series.id > 0) {
        Text('›')
          .fontSize(20)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
    .border({ width: 0.5, color: '#14FFFFFF' })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      openFacet('series', this.series);
    })
  }
}

/**
 * 公开扩展 facets：影片详情里的可点标签行。
 *
 * 上游 /api/metadata/{id} 的 tag_ids 是 name→id 的字典，扩展把它拆成数组下发；
 * 有了 id 才能从「这部片的标签」直接跳到「同标签的所有片」。
 */
@Component
export struct FacetTagChips {
  @Prop tags: FacetItem[] = [];
  @Prop userTags: FacetItem[] = [];
  @Prop directors: FacetItem[] = [];
  /** 制片商（id 来自 item_facets 的 studio，0 表示没有）；点它进制片商影片墙。 */
  @Prop studio: FacetItem = emptyFacet();
  /** 本部番号的前缀；非空时给一个「同番号前缀」标签。 */
  @Prop prefix: string = '';

  private openPrefix(): void {
    if (this.prefix.length === 0) {
      return;
    }
    const params: PrefixParams = { prefix: this.prefix };
    router.pushUrl({ url: 'pages/PrefixPage', params: params });
  }

  @Builder
  Group(label: string, kind: string, items: FacetItem[]) {
    Column({ space: 6 }) {
      // 子分组标签（我的标签 / 标签 / 导演）：降一档到 10.5px —— 上面已经有分区标题了，
      // 子标签如果跟分区标题一样大，又会回到「一片灰字」的老问题。
      if (label.length > 0) {
        Text(label)
          .fontSize(10.5)
          .fontColor(Theme.TEXT_FAINT)
          .letterSpacing(0.3)
          .width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(items, (t: FacetItem) => {
          Text(t.name)
            .fontSize(11)
            .fontColor(Theme.TEXT)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(11)
            .margin({ right: 6, bottom: 6 })
            .onClick(() => {
              openFacet(kind, t);
            })
        }, (t: FacetItem) => `${kind}-${t.id}`)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column({ space: 12 }) {
      // 分区总标题（2.6.1.23）：这块原来只有「标签 / 导演」两个子标签，没有自己的头，
      // 夹在带竖标的其它块之间会显得「没头没尾」—— 用户点名的三个标题之一。
      SectionHead({ title: '标签' })
      if (this.userTags.length > 0) {
        this.Group(facetLabel('user_tag'), 'user_tag', this.userTags)
      }
      if (this.tags.length > 0) {
        // 子标签名与分区标题重复，留空不画
        this.Group('', 'tag', this.tags)
      }
      if (this.directors.length > 0) {
        this.Group(facetLabel('director'), 'director', this.directors)
      }
      // 制片厂 / 同番号前缀：和标签同一套小标签样式，放在标签栏最下面。
      // 这两个是「这部片从哪来、还有哪些同编号的」，性质与标签不同，但入口就在这里最顺手。
      if (this.studio.id > 0 || this.prefix.length > 0) {
        Column({ space: 6 }) {
          SectionHead({ title: '出处' })
          Flex({ wrap: FlexWrap.Wrap }) {
            if (this.studio.id > 0) {
              Text(`制片厂 · ${this.studio.name}`)
                .fontSize(11)
                .fontColor(Theme.TEXT)
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .backgroundColor(Theme.CARD_HI)
                .borderRadius(11)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  openFacet('studio', this.studio);
                })
            }
            if (this.prefix.length > 0) {
              Text(`同番号 ${this.prefix}`)
                .fontSize(11)
                .fontColor(Theme.ACCENT)
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .backgroundColor(Theme.ACCENT_SOFT)
                .borderRadius(11)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.openPrefix();
                })
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .width('100%')
    // 左对齐（2.6.1.23）：不加这行时 Column 默认居中，分区标题的竖标会跑到屏幕中间
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 14 })
  }
}
