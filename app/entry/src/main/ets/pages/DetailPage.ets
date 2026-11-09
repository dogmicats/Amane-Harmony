import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { DetailParams, IngestList, IngestTask, ItemDetail, MediaFile, PlayerParams } from '../common/Types';
import { clock, runtimeText, scoreText, sizeText, dateText } from '../common/Util';
import { safeDetail, safeIngestList } from '../common/Safe';

function emptyDetail(): ItemDetail {
  const d: ItemDetail = {
    id: 0, number: '', title: '', plot: '', actors: [], tags: [], studio: '', series: '',
    release: '', runtime: 0, content_type: '', score: 0, poster: '', fanart: '',
    favorite: false, position: 0, duration: 0, finished: false, files: [], stills: [], ingest: []
  };
  return d;
}

@Entry
@Component
struct DetailPage {
  @State detail: ItemDetail = emptyDetail();
  @State loading: boolean = true;
  @State fav: boolean = false;
  @State expanded: boolean = false;
  @State toast: string = '';
  /** 单独维护：@State 数组赋值才会触发刷新，塞在 detail 对象里不会。 */
  @State ingest: IngestTask[] = [];
  private metaId: number = 0;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    const params = router.getParams() as DetailParams;
    if (params !== undefined && params !== null && params.id !== undefined && params.id !== null) {
      this.metaId = Number(params.id);
    }
    this.load();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private async load(): Promise<void> {
    try {
      const text: string = await httpGet(`${Store.I.user}/api/user/item/${this.metaId}`, Store.I.token);
      const detail: ItemDetail = safeDetail(JSON.parse(text) as ItemDetail);
      this.detail = detail;
      this.fav = detail.favorite;
      this.ingest = detail.ingest;
      if (detail.favorite) {
        Store.I.favIds.add(detail.id);
      } else {
        Store.I.favIds.delete(detail.id);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] detail: ${e.code} ${e.message}`);
      this.toast = '加载失败';
    }
    this.loading = false;
    this.syncPolling();
  }

  /** 只拉入库队列，不重刷整页：点收藏后和轮询时用它。 */
  private async refreshIngest(): Promise<void> {
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/ingest?metadata_id=${this.metaId}`, Store.I.token);
      const obj: IngestList = JSON.parse(text) as IngestList;
      this.ingest = safeIngestList(obj.items);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] ingest: ${e.code} ${e.message}`);
    }
    this.syncPolling();
  }

  private hasActiveIngest(): boolean {
    for (let i = 0; i < this.ingest.length; i++) {
      const s: string = this.ingest[i].status;
      if (s === 'pending' || s === 'running') {
        return true;
      }
    }
    return false;
  }

  /** 有待办就 10 秒刷一次，全部终态后自动停，避免常驻请求。 */
  private syncPolling(): void {
    if (!this.fav || this.metaId === 0) {
      this.stopPolling();
      return;
    }
    if (this.hasActiveIngest() && this.pollTimer < 0) {
      this.pollTimer = setInterval(() => {
        this.refreshIngest();
      }, 10000);
    } else if (!this.hasActiveIngest()) {
      this.stopPolling();
    }
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private play(): void {
    const params: PlayerParams = {
      id: this.detail.id,
      number: this.detail.number,
      title: this.detail.title,
      position: this.detail.finished ? 0 : this.detail.position
    };
    router.pushUrl({ url: 'pages/PlayerPage', params: params });
  }

  private async toggleFav(): Promise<void> {
    try {
      const on: boolean = await Store.I.toggleFav(this.detail.id);
      this.fav = on;
      this.toast = on ? '已加入收藏，开始自动入库' : '已取消收藏';
      if (on) {
        // 服务端在 PUT 里已经入队，这里立刻把状态取回来并开始轮询
        await this.refreshIngest();
      } else {
        this.ingest = [];
        this.stopPolling();
      }
      setTimeout(() => {
        this.toast = '';
      }, 1800);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] fav: ${e.code} ${e.message}`);
      this.toast = '操作失败';
    }
  }

  @Builder
  Chip(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Theme.TEXT_DIM)
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .backgroundColor(Theme.CARD)
      .borderRadius(11)
      .margin({ right: 6, bottom: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // 顶部大图
            Stack({ alignContent: Alignment.BottomStart }) {
              Image(Store.I.img(this.detail.fanart.length > 0 ? this.detail.fanart : this.detail.poster))
                .width('100%')
                .height(340)
                .objectFit(ImageFit.Cover)
                .backgroundColor(Theme.CARD)
              Column()
                .width('100%')
                .height(340)
                .linearGradient({
                  angle: 180,
                  colors: [['#00000000', 0.4], ['#800B0B0F', 0.85], ['#0B0B0F', 1.0]]
                })
            }
            .width('100%')
            .height(340)

            Column() {
              Row({ space: 14 }) {
                Image(Store.I.img(this.detail.poster))
                  .width(104)
                  .height(148)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .backgroundColor(Theme.CARD)
                  .shadow({ radius: 16, color: '#99000000', offsetY: 6 })

                Column({ space: 6 }) {
                  Text(this.detail.number)
                    .fontSize(12)
                    .fontColor(Theme.ACCENT)
                    .fontWeight(FontWeight.Medium)
                  Text(this.detail.title.length > 0 ? this.detail.title : this.detail.number)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Theme.TEXT)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.metaLine())
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .maxLines(2)
                  if (this.detail.score > 0) {
                    Text(`★ ${scoreText(this.detail.score)}`)
                      .fontSize(12)
                      .fontColor(Theme.GOLD)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .margin({ top: -66 })

              // 操作区
              Row({ space: 10 }) {
                Button() {
                  Row({ space: 6 }) {
                    Text('▶')
                      .fontSize(13)
                      .fontColor('#FFFFFF')
                    Text(this.detail.position > 5 && !this.detail.finished
                      ? `继续播放 ${clock(this.detail.position)}` : '播放')
                      .fontSize(14)
                      .fontColor('#FFFFFF')
                  }
                }
                .layoutWeight(1)
                .height(42)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(21)
                .onClick(() => {
                  this.play();
                })

                Column({ space: 1 }) {
                  Text(this.fav ? '♥' : '♡')
                    .fontSize(15)
                    .fontColor(this.fav ? Theme.ACCENT : Theme.TEXT)
                  Text(this.fav ? '已收藏' : '收藏')
                    .fontSize(9)
                    .fontColor(Theme.TEXT_FAINT)
                }
                .width(58)
                .height(42)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Theme.CARD)
                .borderRadius(21)
                .onClick(() => {
                  this.toggleFav();
                })
              }
              .width('100%')
              .margin({ top: 16 })

              // 收藏自动入库：网盘库 → 本地库的搬运进度
              if (this.fav && this.ingest.length > 0) {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text('⇩')
                      .fontSize(14)
                      .fontColor(Theme.ACCENT)
                    Text('自动入库')
                      .fontSize(12)
                      .fontColor(Theme.TEXT)
                    Text(this.ingestSummary())
                      .fontSize(11)
                      .fontColor(Theme.TEXT_DIM)
                      .layoutWeight(1)
                      .textAlign(TextAlign.End)
                    Text('↻')
                      .fontSize(14)
                      .fontColor(Theme.TEXT_FAINT)
                      .onClick(() => {
                        this.refreshIngest();
                      })
                  }
                  .width('100%')

                  ForEach(this.ingest, (task: IngestTask) => {
                    Row({ space: 6 }) {
                      Text(`${this.libLabel(task.src_lib)} → ${this.libLabel(task.dst_lib)}`)
                        .fontSize(11)
                        .fontColor(Theme.TEXT_DIM)
                        .layoutWeight(1)
                      Text(this.ingestStatusText(task))
                        .fontSize(10)
                        .fontColor(this.ingestStatusColor(task.status))
                    }
                    .width('100%')
                  }, (task: IngestTask) => `ingest-${task.src_lib}-${task.dst_lib}`)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(Theme.CARD)
                .borderRadius(Theme.RADIUS)
                .margin({ top: 12 })
              }

              // 标签
              if (this.detail.tags.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.detail.tags, (tag: string) => {
                    this.Chip(tag)
                  }, (tag: string) => `tag-${tag}`)
                }
                .width('100%')
                .margin({ top: 14 })
              }

              // 演员
              if (this.detail.actors.length > 0) {
                Column({ space: 6 }) {
                  Text('出演')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                  Text(this.detail.actors.join(' / '))
                    .fontSize(13)
                    .fontColor(Theme.TEXT)
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 14 })
              }

              // 简介
              if (this.detail.plot.length > 0) {
                Column({ space: 6 }) {
                  Text('简介')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                  Text(this.detail.plot)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_DIM)
                    .lineHeight(19)
                    .maxLines(this.expanded ? 40 : 4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(this.expanded ? '收起' : '展开')
                    .fontSize(11)
                    .fontColor(Theme.ACCENT)
                    .onClick(() => {
                      this.expanded = !this.expanded;
                    })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 14 })
              }

              // 剧照
              if (this.detail.stills.length > 0) {
                Column({ space: 8 }) {
                  Text('剧照')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                  Scroll() {
                    Row({ space: 8 }) {
                      ForEach(this.detail.stills, (url: string, index: number) => {
                        Image(Store.I.img(url))
                          .width(190)
                          .height(107)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(8)
                          .backgroundColor(Theme.CARD)
                      }, (url: string, index: number) => `still-${index}`)
                    }
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                  .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              // 文件
              if (this.detail.files.length > 0) {
                Column({ space: 8 }) {
                  Text(`文件（${this.detail.files.length}）`)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .width('100%')
                  ForEach(this.detail.files, (file: MediaFile) => {
                    Row({ space: 8 }) {
                      Text(file.definition.length > 0 ? file.definition : '视频')
                        .fontSize(10)
                        .fontColor(Theme.TEXT)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .backgroundColor(Theme.ACCENT_SOFT)
                        .borderRadius(4)
                      Text(this.fileName(file.path))
                        .fontSize(11)
                        .fontColor(Theme.TEXT_DIM)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(sizeText(file.size))
                        .fontSize(10)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width('100%')
                  }, (file: MediaFile) => `file-${file.id}`)
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ top: 16 })
              }

              Blank().height(30)
            }
            .width('100%')
            .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 返回按钮
        Text('‹')
          .fontSize(24)
          .fontColor('#FFFFFF')
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor('#59000000')
          .margin({ left: 12, top: 8 })
          .onClick(() => {
            router.back();
          })

        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor('#CC000000')
            .borderRadius(16)
            .position({ x: '50%', y: '88%' })
            .translate({ x: -40 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  private ingestSummary(): string {
    let done: number = 0;
    let failed: number = 0;
    let active: number = 0;
    for (let i = 0; i < this.ingest.length; i++) {
      const status: string = this.ingest[i].status;
      if (status === 'done') {
        done++;
      } else if (status === 'failed' && this.ingest[i].attempts >= 3) {
        failed++;
      } else if (status === 'pending' || status === 'running') {
        active++;
      }
    }
    if (active > 0) {
      return `进行中 ${done}/${this.ingest.length}`;
    }
    if (failed > 0) {
      return `完成 ${done}/${this.ingest.length} · ${failed} 项失败`;
    }
    return `已完成 ${done}/${this.ingest.length}`;
  }

  private ingestStatusText(task: IngestTask): string {
    if (task.status === 'pending') {
      return '等待入库';
    }
    if (task.status === 'running') {
      return '入库中…';
    }
    if (task.status === 'done') {
      return '已入库';
    }
    if (task.status === 'failed') {
      return task.attempts >= 3 ? '入库失败' : `失败 · 待重试 ${task.attempts}/3`;
    }
    return task.status.length > 0 ? task.status : '未知';
  }

  private ingestStatusColor(status: string): string {
    if (status === 'done') {
      return '#5FD08A';
    }
    if (status === 'running') {
      return Theme.GOLD;
    }
    if (status === 'failed') {
      return Theme.DANGER;
    }
    return Theme.TEXT_FAINT;
  }

  private libLabel(id: number): string {
    if (id === 1) {
      return '网盘破解';
    }
    if (id === 2) {
      return '本地JAV';
    }
    if (id === 3) {
      return '网盘JAV';
    }
    if (id === 4 || id === 6) {
      return '旧JAV';
    }
    if (id === 5) {
      return '本地破解';
    }
    if (id === 7) {
      return '无码流出';
    }
    return `库${id}`;
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.detail.release.length > 0) {
      parts.push(dateText(this.detail.release));
    }
    if (this.detail.runtime > 0) {
      parts.push(runtimeText(this.detail.runtime));
    }
    if (this.detail.studio.length > 0) {
      parts.push(this.detail.studio);
    }
    if (this.detail.series.length > 0) {
      parts.push(this.detail.series);
    }
    return parts.join(' · ');
  }

  private fileName(path: string): string {
    const index: number = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }
}
