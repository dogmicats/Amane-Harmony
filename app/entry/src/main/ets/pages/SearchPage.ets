import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BrowseResult, DetailParams, MediaItem } from '../common/Types';
import { safeItems } from '../common/Safe';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State searched: boolean = false;
  private seq: number = 0;

  private async search(text: string): Promise<void> {
    const query: string = text.trim();
    if (query.length === 0) {
      this.items = [];
      this.searched = false;
      return;
    }
    this.seq++;
    const mine: number = this.seq;
    this.loading = true;
    try {
      const url: string = `${Store.I.user}/api/user/browse?q=${encodeURIComponent(query)}&limit=60`;
      const raw: string = await httpGet(url, Store.I.token);
      if (mine !== this.seq) {
        return;
      }
      const result: BrowseResult = JSON.parse(raw) as BrowseResult;
      this.items = safeItems(result.items);
      this.total = result.total === undefined || result.total === null ? this.items.length : result.total;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] search: ${e.code} ${e.message}`);
    }
    this.loading = false;
    this.searched = true;
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        TextInput({ text: this.keyword, placeholder: '搜番号 / 标题 / 演员' })
          .layoutWeight(1)
          .height(38)
          .backgroundColor(Theme.CARD)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 13 })
          .caretColor(Theme.ACCENT)
          .defaultFocus(true)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.search(this.keyword);
          })
        Text('搜索')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.search(this.keyword);
          })
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 10 })

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
      } else if (this.searched && this.items.length === 0) {
        Column({ space: 8 }) {
          Text('没有找到')
            .fontSize(14)
            .fontColor(Theme.TEXT_DIM)
          Text('试试只输入番号前缀，比如 ABP')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (!this.searched) {
        Column({ space: 8 }) {
          Text('⌕')
            .fontSize(32)
            .fontColor(Theme.TEXT_FAINT)
          Text('输入关键词开始搜索')
            .fontSize(12)
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
                Image(Store.I.img(item.poster))
                  .width('100%')
                  .aspectRatio(0.704)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .backgroundColor(Theme.CARD)
                Text(item.number)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .width('100%')
                  .margin({ top: 5 })
                Text(item.title)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .width('100%')
              .onClick(() => {
                const params: DetailParams = { id: item.id };
                router.pushUrl({ url: 'pages/DetailPage', params: params });
              })
            }
          }, (item: MediaItem) => `s-${item.id}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(14)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
