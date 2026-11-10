import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BrowseResult, DetailParams, MediaItem, SuggestItem, SuggestResult } from '../common/Types';
import { safeItems, safeSuggest } from '../common/Safe';
import { PosterCard } from '../view/PosterCard';

/** 联想档位的中文名：服务端按 tier 排好序，这里只管贴标签。 */
function tierLabel(tier: number): string {
  if (tier === 1) {
    return '精确';
  }
  if (tier === 2) {
    return '相关';
  }
  return '更多';
}

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State sugs: SuggestItem[] = [];
  private seq: number = 0;
  private sugSeq: number = 0;
  private sugTimer: number = -1;

  aboutToDisappear(): void {
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
  }

  /**
   * 搜索联想：输入即搜，不等点按钮。
   * 防抖 300ms；服务端按「精确 → 相关 → 扩大」三档递进返回，
   * 准确的排前面，没有准确的才弹模糊的，模糊不够就再扩大范围。
   */
  private onKeyword(value: string): void {
    this.keyword = value;
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    const text: string = value.trim();
    if (text.length === 0) {
      this.sugs = [];
      return;
    }
    this.sugTimer = setTimeout(() => {
      this.sugTimer = -1;
      this.suggest(text);
    }, 300);
  }

  private async suggest(text: string): Promise<void> {
    this.sugSeq++;
    const mine: number = this.sugSeq;
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/suggest?q=${encodeURIComponent(text)}`, Store.I.token);
      if (mine !== this.sugSeq) {
        return; // 已有更新的输入，丢弃过期结果
      }
      this.sugs = safeSuggest(JSON.parse(raw) as SuggestResult);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] suggest: ${e.code} ${e.message}`);
    }
  }

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

  /** 点「搜索」按钮或回车：切到完整结果网格，联想列表退场。 */
  private commitSearch(): void {
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    this.search(this.keyword);
  }

  private openDetail(id: number): void {
    const params: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  @Builder
  SuggestionRow(item: SuggestItem) {
    Row({ space: 10 }) {
      Image(Store.I.img(item.poster))
        .width(38)
        .height(54)
        .objectFit(ImageFit.Cover)
        .borderRadius(6)
        .backgroundColor(Theme.CARD)
        .alt($r('app.media.placeholder'))
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(item.number.length > 0 ? item.number : '未知番号')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ACCENT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
          Text(tierLabel(item.tier))
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(4)
        }
        Text(item.title.length > 0 ? item.title : ' ')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(16)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
    .onClick(() => {
      this.openDetail(item.id);
    })
  }

  @Builder
  SuggestList() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('联想结果')
          .fontSize(12)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(`查看「${this.keyword.trim()}」的全部结果 →`)
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.commitSearch();
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      List({ space: 6 }) {
        ForEach(this.sugs, (item: SuggestItem) => {
          ListItem() {
            this.SuggestionRow(item)
          }
        }, (item: SuggestItem) => `sug-${item.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
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
            this.onKeyword(value);
          })
          .onSubmit(() => {
            this.commitSearch();
          })
        Text('搜索')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.commitSearch();
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
      } else if (this.searched) {
        Grid() {
          ForEach(this.items, (item: MediaItem) => {
            GridItem() {
              // 与媒体库 / 首页 / 演员作品共用同一张海报卡，标记不再各页漏做
              PosterCard({
                item: item,
                fluid: true,
                onTap: () => {
                  this.openDetail(item.id);
                }
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
      } else if (this.sugs.length > 0) {
        // 输入中：实时联想结果（准确在前，模糊递进）
        this.SuggestList()
      } else {
        Column({ space: 8 }) {
          Text('⌕')
            .fontSize(32)
            .fontColor(Theme.TEXT_FAINT)
          Text('输入即联想：番号精确匹配排最前，没有就逐步放宽')
            .fontSize(12)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
