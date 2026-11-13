import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

interface CastToken {
  token: string;
  created_at: string;
  expires_at: string;
}

interface CastTokenData {
  items?: CastToken[];
}

interface CastTokenRes {
  ok: boolean;
  data?: CastTokenData;
}

const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';
const ST_ERR: string = 'err';

/**
 * 投屏令牌（2.5.6）。
 *
 * 交给电视的那把钥匙是**只读、限时**的：只认 GET/HEAD 的播放 / 字幕 / 封面，
 * 12 小时自动过期。这里列出来，方便随时吊销 —— 电视借给别人、或者怀疑地址外泄时用。
 */
@Entry
@Component
struct CastTokenPage {
  @State st: string = ST_LOADING;
  @State items: CastToken[] = [];
  @State note: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.st = ST_LOADING;
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/cast/token`, Store.I.token);
      const res = JSON.parse(raw) as CastTokenRes;
      const list: CastToken[] = [];
      const data = res.data;
      if (data !== undefined && data !== null && data.items !== undefined && data.items !== null) {
        for (let i = 0; i < data.items.length; i++) {
          const it = data.items[i];
          list.push({
            token: it.token === undefined || it.token === null ? '' : `${it.token}`,
            created_at: it.created_at === undefined || it.created_at === null ? '' : `${it.created_at}`,
            expires_at: it.expires_at === undefined || it.expires_at === null ? '' : `${it.expires_at}`
          });
        }
      }
      this.items = list;
      this.st = ST_OK;
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] cast tokens: ${e.code} ${e.message}`);
      this.st = ST_ERR;
      this.note = e.code === 404 ? '服务端还不支持投屏令牌（需新版服务端）' : '读取失败，点这里重试';
    }
  }

  /** `2026-11-12T06:06:31+00:00` → `11-12 14:06`（本机时区）。 */
  private fmt(iso: string): string {
    if (iso.length < 16) {
      return iso.length > 0 ? iso : '—';
    }
    const d = new Date(iso);
    if (isNaN(d.getTime())) {
      return iso.substring(0, 16).replace('T', ' ');
    }
    const mm = `${d.getMonth() + 1}`.padStart(2, '0');
    const dd = `${d.getDate()}`.padStart(2, '0');
    const hh = `${d.getHours()}`.padStart(2, '0');
    const mi = `${d.getMinutes()}`.padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  /** 密钥只露前 6 位：整串显示在屏幕上没必要。 */
  private short(tok: string): string {
    return tok.length > 6 ? `${tok.substring(0, 6)}…` : tok;
  }

  private confirmRevoke(it: CastToken): void {
    AlertDialog.show({
      title: '吊销这把钥匙？',
      message: '吊销后，正在用它的电视会立刻播不了。再投需要重新生成。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '吊销',
        fontColor: Theme.DANGER,
        action: () => {
          this.revoke(it);
        }
      }
    });
  }

  private async revoke(it: CastToken): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await httpDelete(`${Store.I.user}/api/user/cast/token/${it.token}`, Store.I.token);
      promptAction.showToast({ message: '已吊销', duration: 1400 });
      this.load();
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] cast revoke: ${e.code} ${e.message}`);
      promptAction.showToast({ message: '没吊销成，稍后再试', duration: 1600 });
    } finally {
      this.busy = false;
    }
  }

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('投屏令牌')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('给电视用的只读钥匙，12 小时过期')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  build() {
    Column() {
      this.Header()

      if (this.st === ST_OK) {
        Scroll() {
          Column({ space: 10 }) {
            if (this.items.length === 0) {
              Column({ space: 8 }) {
                Text('还没有投屏令牌')
                  .fontSize(13)
                  .fontColor(Theme.TEXT_DIM)
                Text('在影片的「选择版本」里点「投屏」会生成一把，用完 12 小时自动失效。')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .textAlign(TextAlign.Center)
                  .lineHeight(15)
              }
              .width('100%')
              .padding({ top: 60 })
            } else {
              ForEach(this.items, (it: CastToken) => {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text(this.short(it.token))
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                    Text(`${this.fmt(it.created_at)} 生成 · ${this.fmt(it.expires_at)} 过期`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text('吊销')
                    .fontSize(11)
                    .fontColor(Theme.DANGER)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor(Theme.CARD_HI)
                    .borderRadius(9)
                    .onClick(() => {
                      this.confirmRevoke(it);
                    })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.CARD)
                .borderRadius(12)
              }, (it: CastToken) => `ct-${it.token}`)
            }

            Text('这些钥匙只能读媒体（播放 / 字幕 / 封面），改不了任何数据；' +
              '换片时会复用还没过期的那一把。')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(14)
              .padding({ top: 4, bottom: Theme.BOTTOM_SAFE })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column({ space: 10 }) {
          if (this.st === ST_LOADING) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Theme.ACCENT)
          } else {
            Text(this.note)
              .fontSize(12)
              .fontColor(Theme.TEXT_DIM)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .height(34)
              .backgroundColor(Theme.CARD)
              .fontColor(Theme.TEXT)
              .fontSize(12)
              .onClick(() => {
                this.load();
              })
          }
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
