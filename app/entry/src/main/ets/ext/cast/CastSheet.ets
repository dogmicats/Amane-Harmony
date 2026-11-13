import { promptAction } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';

interface CastLinkData {
  mid?: number;
  number?: string;
  title?: string;
  source?: string;
  key?: string;
  token?: string;
  expires_at?: string;
  base?: string;
  url?: string;
  cover_url?: string;
  subtitles_url?: string;
  subtitle_url_tpl?: string;
  hint?: string;
}

interface CastLinkRes {
  ok: boolean;
  data?: CastLinkData;
  reason?: string;
}

/**
 * 投屏（2.5.6）：把「这一部、这个版本」变成一套**只读地址**交给电视。
 *
 * 为什么要专门发个临时钥匙：播放地址原本要带主 token，而那把钥匙能改数据、能删快照。
 * 交给电视（第三方设备、会留日志）不合适。服务端发的 `ct` 只认 GET/HEAD 的
 * play / streams / photo / studio-logo，12 小时自动过期，也能随时吊销。
 *
 * 这一版只到「拿到地址、复制给电视」：DLNA 自动发现要真机 + 同一局域网，
 * 单独一项做（见 docs/TASKS/2.5.6-system.md §3）。
 */
@Component
export struct CastSheet {
  @Prop metaId: number = 0;
  @Prop number: string = '';
  @Prop title: string = '';
  @Prop source: string = '';
  @Prop fileKey: string = '';
  onClose: () => void = () => {};

  @State loading: boolean = true;
  @State note: string = '';
  @State playUrl: string = '';
  @State coverUrl: string = '';
  @State subUrl: string = '';
  @State expires: string = '';
  @State base: string = '';

  aboutToAppear(): void {
    this.generate();
  }

  private async generate(): Promise<void> {
    this.loading = true;
    this.note = '';
    try {
      const body: Record<string, Object> = { 'mid': this.metaId, 'hours': 12 };
      if (this.source.length > 0) {
        body['source'] = this.source;
      }
      if (this.fileKey.length > 0) {
        body['key'] = this.fileKey;
      }
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/cast/link`, Store.I.token, JSON.stringify(body));
      const res = JSON.parse(raw) as CastLinkRes;
      const d = res.data;
      if (res.ok === true && d !== undefined && d !== null) {
        this.playUrl = d.url === undefined ? '' : `${d.url}`;
        this.coverUrl = d.cover_url === undefined ? '' : `${d.cover_url}`;
        this.subUrl = d.subtitles_url === undefined ? '' : `${d.subtitles_url}`;
        this.expires = d.expires_at === undefined ? '' : `${d.expires_at}`;
        this.base = d.base === undefined ? '' : `${d.base}`;
        if (this.playUrl.length === 0) {
          this.note = '服务端没返回播放地址';
        }
      } else {
        this.note = res.reason === undefined || res.reason === null || `${res.reason}`.length === 0
          ? '生成失败，稍后再试' : `${res.reason}`;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.info(`[amane] cast link: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端还不支持投屏（需新版服务端）' : '网络不通，生成失败';
    }
    this.loading = false;
  }

  private copy(text: string, label: string): void {
    if (text.length === 0) {
      return;
    }
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: `${label}已复制`, duration: 1400 });
    }).catch((err: BusinessError) => {
      console.info(`[amane] pasteboard: ${err.code} ${err.message}`);
      promptAction.showToast({ message: '复制失败', duration: 1400 });
    });
  }

  /** `2026-11-13T01:30:00+00:00` → `11-13 09:30`（本机时区），解不出来就原样。 */
  private expiresLabel(): string {
    if (this.expires.length < 16) {
      return this.expires;
    }
    const d = new Date(this.expires);
    const t = d.getTime();
    if (isNaN(t)) {
      return this.expires.substring(0, 16).replace('T', ' ');
    }
    const mm = `${d.getMonth() + 1}`.padStart(2, '0');
    const dd = `${d.getDate()}`.padStart(2, '0');
    const hh = `${d.getHours()}`.padStart(2, '0');
    const mi = `${d.getMinutes()}`.padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  @Builder
  Line(label: string, value: string) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(label)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text('复制')
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(8)
          .onClick(() => {
            this.copy(value, label);
          })
      }
      .width('100%')
      Text(value)
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .lineHeight(15)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD_HI)
    .borderRadius(10)
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('投给电视')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
          Text('生成一份只读地址，电视用它就能播')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('✕')
          .fontSize(14)
          .fontColor(Theme.TEXT_DIM)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.number.length > 0 ? this.number : `${this.metaId}`)
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(7)
        Text(this.title)
          .fontSize(12)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(Theme.ACCENT)
          Text('正在准备地址…')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
      } else if (this.note.length > 0) {
        Column({ space: 10 }) {
          Text(this.note)
            .fontSize(12)
            .fontColor(Theme.DANGER)
            .textAlign(TextAlign.Center)
          Text('重试')
            .fontSize(12)
            .fontColor(Theme.TEXT)
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .backgroundColor(Theme.CARD)
            .borderRadius(10)
            .onClick(() => {
              this.generate();
            })
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
      } else {
        this.Line('播放地址（交给电视）', this.playUrl)
        this.Line('封面', this.coverUrl)
        this.Line('字幕列表', this.subUrl)

        Row({ space: 6 }) {
          Text('有效期')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
          Text(this.expiresLabel().length > 0 ? this.expiresLabel() : '12 小时')
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
          Blank()
          Text('重新生成')
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .onClick(() => {
              this.generate();
            })
        }
        .width('100%')

        Text('在电视的播放器里打开「播放地址」即可。它只读、12 小时过期、随时可以在设置里吊销。' +
          '自动发现电视（DLNA）还没做，这一版是手动把地址交给电视。')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .lineHeight(14)
      }
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 8, bottom: 24 })
  }
}
