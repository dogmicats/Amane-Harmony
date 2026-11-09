import { router } from '@kit.ArkUI';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { FacetItem, FacetParams, facetLabel } from './FacetTypes';

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
  @Prop series: FacetItem = { id: 0, name: '', count: 0, posters: [] };
  @Prop studioName: string = '';

  private posterAt(i: number): string {
    return i < this.series.posters.length ? this.series.posters[i] : '';
  }

  @Builder
  Cover() {
    Stack() {
      if (this.series.posters.length <= 1) {
        if (this.series.posters.length === 1) {
          Image(Store.I.img(this.series.posters[0]))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .backgroundColor(Theme.CARD_HI)
            .alt($r('app.media.placeholder'))
        } else {
          Column() {
            Text('系')
              .fontSize(18)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.CARD_HI)
        }
      } else {
        // 四宫格：不足四张时用底色补齐，不留破图
        if (this.posterAt(0).length > 0) {
          Image(Store.I.img(this.posterAt(0)))
            .width(30)
            .height(30)
            .objectFit(ImageFit.TOP)
            .position({ x: 0, y: 0 })
            .backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(1).length > 0) {
          Image(Store.I.img(this.posterAt(1)))
            .width(30)
            .height(30)
            .objectFit(ImageFit.TOP)
            .position({ x: 32, y: 0 })
            .backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(2).length > 0) {
          Image(Store.I.img(this.posterAt(2)))
            .width(30)
            .height(30)
            .objectFit(ImageFit.TOP)
            .position({ x: 0, y: 32 })
            .backgroundColor(Theme.CARD_HI)
        }
        if (this.posterAt(3).length > 0) {
          Image(Store.I.img(this.posterAt(3)))
            .width(30)
            .height(30)
            .objectFit(ImageFit.TOP)
            .position({ x: 32, y: 32 })
            .backgroundColor(Theme.CARD_HI)
        }
      }
    }
    .width(62)
    .height(62)
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

  @Builder
  Group(label: string, kind: string, items: FacetItem[]) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.TEXT_FAINT)
        .width('100%')
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
      if (this.userTags.length > 0) {
        this.Group(facetLabel('user_tag'), 'user_tag', this.userTags)
      }
      if (this.tags.length > 0) {
        this.Group(facetLabel('tag'), 'tag', this.tags)
      }
      if (this.directors.length > 0) {
        this.Group(facetLabel('director'), 'director', this.directors)
      }
    }
    .width('100%')
    .margin({ top: 14 })
  }
}
