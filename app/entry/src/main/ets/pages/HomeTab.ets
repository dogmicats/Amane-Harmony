import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { HomeData, HomeRow, MediaItem, BrowseParams, DetailParams, PlayerParams } from '../common/Types';
import { safeHome } from '../common/Safe';
import { BuildConfig } from '../common/BuildConfig';
import { HeroBanner } from '../view/HeroBanner';
import { MediaRow } from '../view/MediaRow';

export function emptyHome(): HomeData {
  const data: HomeData = {
    hero: [], continue: [], recommend: [], rows: [], libraries: [], generated_at: ''
  };
  return data;
}

@Component
export struct HomeTab {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  @State home: HomeData = emptyHome();
  @State loading: boolean = true;
  @State error: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    if (!Store.I.ready) {
      // 冷启动时 Index 还没拿到 config，稍后 refreshKey 变化会再来一次
      this.loading = false;
      return;
    }
    this.error = '';
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/home`, Store.I.token);
      this.home = safeHome(JSON.parse(text) as HomeData);
      this.loading = false;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] home: ${e.code} ${e.message}`);
      this.error = '首页加载失败，下拉重试';
      this.loading = false;
    }
  }

  private openDetail(item: MediaItem): void {
    const params: DetailParams = { id: item.id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  private openPlayer(item: MediaItem): void {
    const params: PlayerParams = {
      id: item.id, number: item.number, title: item.title, position: item.position
    };
    router.pushUrl({ url: 'pages/PlayerPage', params: params });
  }

  private openLibrary(id: number, title: string): void {
    const params: BrowseParams = { libraryId: id, title: title };
    router.pushUrl({ url: 'pages/LibraryPage', params: params });
  }

  @Builder
  Header() {
    Row() {
      Text('Amane')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
        .textShadow({ radius: 8, color: '#99000000', offsetX: 0, offsetY: 2 })
      Blank()
      Text('⌕')
        .fontSize(20)
        .fontColor('#FFFFFF')
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor('#59000000')
        .onClick(() => {
          router.pushUrl({ url: 'pages/SearchPage' });
        })
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
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
        List() {
          ListItem() {
            HeroBanner({
              items: this.home.hero,
              onPlay: (item: MediaItem) => {
                this.openPlayer(item);
              },
              onDetail: (item: MediaItem) => {
                this.openDetail(item);
              }
            })
          }


          // 公开扩展 actors 的特色入口：共演筛选放首屏，别藏在演员页角落里
          if (BuildConfig.ENABLE_ACTORS) {
            ListItem() {
              // 外层 Column 承担左右留白：Row 再设 width('100%') 时，
              // 100% 就是「已减掉留白」的宽度，不会像 margin 那样把整条撑出屏幕。
              Column() {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text('共演筛选')
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
                  Text('挑几个人找同台作品，或按「几个女演员」直接筛')
                    .fontSize(10)
                    .fontColor(Theme.TEXT_FAINT)
                    .maxLines(2)
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('去试 ›')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(14)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .border({ width: 0.5, color: '#1FFFFFFF' })
              .onClick(() => {
                router.pushUrl({ url: 'ext/actors/CastFinderPage' });
              })
              }
              .width('100%')
              .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
              .margin({ bottom: 12 })
            }
          }

          if (this.home.continue.length > 0) {
            ListItem() {
              MediaRow({
                title: '继续观看',
                subtitle: '接着上次的进度',
                items: this.home.continue,
                onTap: (item: MediaItem) => {
                  this.openDetail(item);
                },
                onMore: () => {
                  router.pushUrl({ url: 'pages/HistoryPage' });
                }
              })
            }
          }

          ListItem() {
            MediaRow({
              title: '每日推荐',
              subtitle: '每天换一批',
              items: this.home.recommend,
              onTap: (item: MediaItem) => {
                this.openDetail(item);
              },
              onMore: () => {
                this.openLibrary(0, '全部影片');
              }
            })
          }

          ForEach(this.home.rows, (row: HomeRow) => {
            ListItem() {
              MediaRow({
                title: row.title,
                subtitle: `${row.count} 部`,
                items: row.items,
                onTap: (item: MediaItem) => {
                  this.openDetail(item);
                },
                onMore: () => {
                  this.openLibrary(row.library_id, row.title);
                }
              })
            }
          }, (row: HomeRow) => row.id)

          ListItem() {
            Text(`共 ${this.home.libraries.length} 个媒体库 · Amane`)
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 28 })
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        this.Header()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
