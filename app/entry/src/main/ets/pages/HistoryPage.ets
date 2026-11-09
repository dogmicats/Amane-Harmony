import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { HistoryItem, HistoryList, PlayerParams } from '../common/Types';
import { clock, dateText, remainText } from '../common/Util';
import { safeHistory } from '../common/Safe';

@Entry
@Component
struct HistoryPage {
  @State items: HistoryItem[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/history?limit=120`, Store.I.token);
      const data: HistoryList = JSON.parse(text) as HistoryList;
      this.items = safeHistory(data.items);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] history: ${e.code} ${e.message}`);
    }
    this.loading = false;
  }

  private async remove(id: number): Promise<void> {
    try {
      await httpDelete(`${Store.I.user}/api/user/history/${id}`, Store.I.token);
      const next: HistoryItem[] = [];
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].id !== id) {
          next.push(this.items[i]);
        }
      }
      this.items = next;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] history delete: ${e.code} ${e.message}`);
    }
  }

  private resume(item: HistoryItem): void {
    const params: PlayerParams = {
      id: item.id,
      number: item.number,
      title: item.title,
      position: item.finished ? 0 : item.position
    };
    router.pushUrl({ url: 'pages/PlayerPage', params: params });
  }

  private ratio(item: HistoryItem): number {
    if (item.duration <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(1, item.position / item.duration * 100));
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
        Text('观看记录')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`${this.items.length} 条`)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(26)
            .height(26)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 8 }) {
          Text('还没有观看记录')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('看过的片子会出现在这里，可以接着播')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (item: HistoryItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Image(Store.I.img(item.poster))
                    .width(86)
                    .height(120)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(8)
                    .backgroundColor(Theme.CARD)
                  if (this.ratio(item) > 0) {
                    Progress({ value: this.ratio(item), total: 100, type: ProgressType.Linear })
                      .width('100%')
                      .height(3)
                      .color(Theme.ACCENT)
                      .backgroundColor('#4DFFFFFF')
                  }
                }
                .width(86)
                .borderRadius(8)

                Column({ space: 5 }) {
                  Text(item.number)
                    .fontSize(12)
                    .fontColor(Theme.ACCENT)
                  Text(item.title)
                    .fontSize(13)
                    .fontColor(Theme.TEXT)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${clock(item.position)} / ${clock(item.duration)}`)
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                  Text(item.finished ? '已看完' : remainText(item.position, item.duration))
                    .fontSize(10)
                    .fontColor(item.finished ? Theme.TEXT_FAINT : '#8BD9A0')
                  Text(dateText(item.played_at.replace('T', ' ')))
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.CARD)
              .borderRadius(Theme.RADIUS)
              .onClick(() => {
                this.resume(item);
              })
            }
            .swipeAction({
              end: {
                builder: () => {
                  Text('删除')
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .width(72)
                    .height('100%')
                    .textAlign(TextAlign.Center)
                    .backgroundColor(Theme.DANGER)
                    .onClick(() => {
                      this.remove(item.id);
                    })
                }
              }
            })
          }, (item: HistoryItem) => `his-${item.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
