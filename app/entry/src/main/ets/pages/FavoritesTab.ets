import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams, FavList, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { MarkBadges } from '../view/MarkBadges';

@Component
export struct FavoritesTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State items: MediaItem[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/favorites?limit=200`, Store.I.token);
      const data: FavList = JSON.parse(text) as FavList;
      this.items = safeItems(data.items);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] favorites: ${e.code} ${e.message}`);
    }
    this.loading = false;
  }

  build() {
    Column() {
      Row() {
        Text('我的收藏')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`${this.items.length} 部`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8, bottom: 12 })

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text('♥')
            .fontSize(34)
            .fontColor(Theme.TEXT_FAINT)
          Text('还没有收藏')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('在详情页点小心心，片子会出现在这里')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.items, (item: MediaItem) => {
            GridItem() {
              Column() {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(Store.I.img(item.poster))
                    .width('100%')
                    .aspectRatio(0.704)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(10)
                    .backgroundColor(Theme.CARD)
                  Row({ space: 3 }) {
                    if (item.marks !== undefined && item.marks !== null && item.marks.length > 0) {
                      MarkBadges({ marks: item.marks, max: 2, badgeSize: 8, fill: 'dark' })
                    }
                    Text('♥')
                      .fontSize(13)
                      .fontColor(Theme.ACCENT)
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('#99000000')
                      .borderRadius(10)
                  }
                  .margin(5)
                }
                .width('100%')

                Text(item.number)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 5 })
              }
              .width('100%')
              .onClick(() => {
                const params: DetailParams = { id: item.id };
                router.pushUrl({ url: 'pages/DetailPage', params: params });
              })
            }
          }, (item: MediaItem) => `fav-${item.id}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(14)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 84 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
