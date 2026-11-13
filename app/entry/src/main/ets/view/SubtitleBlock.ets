import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { Theme } from '../common/Theme';
import {
  LocalCandidate, OnlineSubtitle, OwnedSubtitle, SubtitleClient, SubtitleItem
} from '../common/Subtitles';

/**
 * 本片字幕（详情页用）。
 *
 * 形态：标题右侧一枚**紧凑胶囊**（字幕图标 + 状态），点开是底部抽屉（bindSheet），
 * 抽屉里做全部管理 —— 同目录 / 已缓存 / 已下载（可删）/ 在线搜索 / 需要时的验证码。
 *
 * 为什么不就地展开：就地展开会把标题区撑高，且用户否掉了「箭头展开」那种粗糙形态；
 * 抽屉是系统级手势（下拉关闭、拖拽把手），与本 App 其它面板一致。
 *
 * 数据只有一份：选择写进服务端 choice，播放器打开时自动套用。
 */
@Component
export struct SubtitleBlock {
  metaId: number = 0;
  /** 父页面保留的双向绑定，供「播放前知道选了哪条」用。 */
  @Link chosenId: string;

  @State local: LocalCandidate[] = [];
  @State cachedItems: SubtitleItem[] = [];
  @State owned: OwnedSubtitle[] = [];
  @State online: OnlineSubtitle[] = [];
  @State showSheet: boolean = false;
  @State busy: boolean = false;
  @State hint: string = '';
  @State onlineShown: boolean = false;
  /** JAV字幕 需要验证时才亮出来：图在应用内显示，输一次能用约 5 次搜索。 */
  @State needCaptcha: boolean = false;
  @State captchaId: string = '';
  @State captchaImage: string = '';
  @State captchaAnswer: string = '';
  @State captchaMsg: string = '';
  private loadedFor: number = 0;
  /** 验证码用 WebView 渲染：ArkUI 的 Image 对 SVG <text> 支持不全，字会叠/被裁。 */
  private captchaCtrl: webview.WebviewController = new webview.WebviewController();

  /** 把 SVG 包成一张定宽定高的页面，交给 WebView 画（Chromium 的 SVG 渲染是完整的）。 */
  private pageOf(svg: string): string {
    const html = `<html><head><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<style>html,body{margin:0;padding:0;background:#fff;overflow:hidden}` +
      `img{display:block;width:100%;height:auto}</style></head>` +
      `<body><img src="${svg}"></body></html>`;
    return 'data:text/html;charset=utf-8,' + encodeURIComponent(html);
  }

  private captchaPage(): string {
    return this.pageOf(this.captchaImage);
  }

  /**
   * 换一张必须**显式重载**：`Web({src})` 只在创建时读一次 src，
   * 后续 @State 变了不会自己重新导航 —— 这就是「点换一张图不变、关了抽屉重开才变」的原因。
   */
  private refreshCaptchaView(svg: string): void {
    try {
      this.captchaCtrl.loadUrl(this.pageOf(svg));
    } catch (error) {
      // Web 还没挂到树上（抽屉刚关/刚开）时 loadUrl 会抛，下一帧按 state 重新创建即可
      const e = error as BusinessError;
      console.info(`[amane] captcha reload skipped: ${e.code}`);
    }
  }

  aboutToAppear(): void {
    this.reload();
  }

  /** metaId 是普通属性、变化不触发刷新，靠这里兜住「先渲染后取数」。 */
  onDidBuild(): void {
    if (this.metaId > 0 && this.metaId !== this.loadedFor) {
      this.loadedFor = this.metaId;
      this.reload();
    }
  }

  /** 当前选中项的可读名字（抽屉顶部那行）。 */
  private currentLabel(): string {
    if (this.chosenId.length === 0) {
      return '未选择';
    }
    for (let i = 0; i < this.cachedItems.length; i++) {
      if (this.cachedItems[i].id === this.chosenId) {
        return this.cachedItems[i].name;
      }
    }
    return '已选择（在线来源）';
  }

  private count(): number {
    return this.local.length + this.cachedItems.length;
  }

  private async reload(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const res = await SubtitleClient.list(this.metaId);
      this.local = res.local === undefined || res.local === null ? [] : res.local;
      this.cachedItems = res.cached === undefined || res.cached === null ? [] : res.cached;
      this.hint = res.hint === undefined || res.hint === null ? '' : res.hint;
      if (res.choice !== undefined && res.choice !== null && res.choice.subtitle_id.length > 0) {
        this.chosenId = res.choice.subtitle_id;
      }
      this.owned = await SubtitleClient.owned(this.metaId);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] subtitle block: ${e.code} ${e.message}`);
    }
  }

  private async pick(id: string, label: string): Promise<void> {
    // 乐观更新、**不关抽屉**：点了立刻打勾，用户能看见「切换成功了」。
    const before: string = this.chosenId;
    this.chosenId = id;
    this.hint = `已选择：${label}`;
    this.busy = true;
    try {
      await SubtitleClient.remember(this.metaId, id);
    } catch (error) {
      const e = error as BusinessError;
      this.chosenId = before;
      this.hint = `记住选择失败：${e.message}`;
    } finally {
      this.busy = false;
    }
  }

  private async pickLocal(name: string): Promise<void> {
    this.busy = true;
    try {
      const item = await SubtitleClient.loadLocal(this.metaId, name);
      await SubtitleClient.remember(this.metaId, item.id);
      this.chosenId = item.id;
      await this.reload();
      this.showSheet = false;
    } catch (error) {
      const e = error as BusinessError;
      this.hint = `读取失败：${e.message}`;
    } finally {
      this.busy = false;
    }
  }

  private async searchOnline(): Promise<void> {
    this.busy = true;
    this.onlineShown = true;
    this.hint = '';
    try {
      const res = await SubtitleClient.search(this.metaId, '');
      this.online = res.items === undefined || res.items === null ? [] : res.items;
      if (res.total === 0) {
        this.hint = '几个源都没找到这条的字幕';
      } else if (res.errors !== undefined && res.errors !== null && res.errors.length > 0) {
        const names: string[] = [];
        let captcha: boolean = false;
        for (let i = 0; i < res.errors.length; i++) {
          names.push(res.errors[i].provider);
          if (res.errors[i].captcha) {
            captcha = true;
          }
        }
        this.hint = `部分源不可用：${names.join(' / ')}`;
        this.needCaptcha = captcha;
      }
      if (this.needCaptcha && this.captchaImage.length === 0) {
        await this.loadCaptcha();
      }
    } catch (error) {
      const e = error as BusinessError;
      this.hint = `搜索失败：${e.message}`;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 非 UTF-8 的字幕在统计后面标一下编码（例：`1155 条（GBK）· …`）。
   * 用户报「字幕是乱码」时，一眼能看出服务端是按哪种编码解的（2.6.1.7）。
   */
  private encTag(item: OwnedSubtitle): string {
    const enc: string = item.encoding === undefined || item.encoding === null ? '' : item.encoding;
    if (enc.length === 0 || enc.indexOf('UTF-8') === 0) {
      return '';
    }
    return `（${enc}）`;
  }

  /**
   * 这条在线结果是不是已经下载过了（2.5.9.1）。
   *
   * 判据：服务端给每条结果算的 `lang_tag`（落盘会用哪个后缀）与「已存进片库」那条的
   * 语言后缀一致，且来源 provider 相同 —— 这样「下完以后搜索列表里还挂着一模一样的一条」
   * 就不会再出现：那条直接标「已下载」并失去点击下载的能力。
   */
  private isSaved(item: OnlineSubtitle): boolean {
    const tag: string = item.lang_tag === undefined || item.lang_tag === null ? '' : item.lang_tag;
    if (tag.length === 0) {
      return false;
    }
    for (let i = 0; i < this.owned.length; i++) {
      const o: OwnedSubtitle = this.owned[i];
      if (!o.exists) {
        continue;
      }
      if (o.provider === item.provider && (o.lang === undefined || o.lang === null
        ? false : o.lang === tag)) {
        return true;
      }
    }
    return false;
  }

  private async useOnline(item: OnlineSubtitle): Promise<void> {
    this.busy = true;
    try {
      const res = await SubtitleClient.save(this.metaId, item);
      await SubtitleClient.remember(this.metaId, res.subtitle_id);
      this.chosenId = res.subtitle_id;
      const cues: number = res.cues === undefined || res.cues === null ? -1 : res.cues;
      if (cues === 0) {
        // 解析不出 cue：明确告诉用户是这份字幕的问题，别让他去怀疑播放器
        this.hint = `已保存，但这份字幕解析不出内容（0 条）—— 换一条试试`;
      } else {
        this.hint = res.kind === 'library'
          ? `已存到资源库：${res.files.join(' / ')}${cues > 0 ? ` · ${cues} 条` : ''}`
          : `已缓存（写不进媒体目录：${res.reason}）`;
      }
      this.online = this.online.filter((x: OnlineSubtitle) =>
        !(x.provider === item.provider && x.name === item.name));
      await this.reload();
      this.showSheet = false;
    } catch (error) {
      const e = error as BusinessError;
      this.hint = `保存失败：${e.message}`;
    } finally {
      this.busy = false;
    }
  }

  private async drop(filename: string): Promise<void> {
    try {
      await SubtitleClient.removeOwned(this.metaId, filename);
      this.hint = `已删除 ${filename}`;
      await this.reload();
    } catch (error) {
      const e = error as BusinessError;
      this.hint = `删除失败：${e.message}`;
    }
  }

  private async loadCaptcha(): Promise<void> {
    this.captchaMsg = '正在取验证码…';
    try {
      const c = await SubtitleClient.captcha();
      this.captchaId = c.captchaId;
      this.captchaImage = c.image;
      this.captchaMsg = '看图输入字符，验证后可连续搜几次';
      this.refreshCaptchaView(c.image);
    } catch (error) {
      const e = error as BusinessError;
      this.captchaMsg = `取验证码失败：${e.message}`;
    }
  }

  private async submitCaptcha(): Promise<void> {
    if (this.captchaId.length === 0 || this.captchaAnswer.trim().length === 0) {
      this.captchaMsg = '先看图输入字符';
      return;
    }
    this.busy = true;
    try {
      const res = await SubtitleClient.verifyCaptcha(this.captchaId, this.captchaAnswer.trim());
      if (res.ok) {
        this.needCaptcha = false;
        this.captchaImage = '';
        this.captchaAnswer = '';
        this.captchaMsg = `验证通过（还能搜 ${res.remaining} 次）`;
        await this.searchOnline();
      } else {
        this.captchaMsg = '没通过，换一张再试';
        await this.loadCaptcha();
      }
    } catch (error) {
      const e = error as BusinessError;
      this.captchaMsg = `验证失败：${e.message}`;
    } finally {
      this.busy = false;
    }
  }

  @Builder
  SectionLabel(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Theme.TEXT_FAINT)
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })
  }

  /** 底部抽屉：全部管理动作都在这里。 */
  @Builder
  Sheet() {
    Column() {
      Row() {
        Text('本片字幕')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        if (this.busy) {
          Text('处理中…')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })

      Text(`当前：${this.currentLabel()}`)
        .fontSize(11)
        .fontColor(this.chosenId.length > 0 ? Theme.ACCENT : Theme.TEXT_FAINT)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
          .maxLines(3)
      }

      Scroll() {
        Column() {
          if (this.local.length > 0) {
            this.SectionLabel('同目录')
            ForEach(this.local, (item: LocalCandidate) => {
              Row() {
                Text(`· ${item.name}`)
                  .fontSize(13)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 12, bottom: 12 })
              .onClick(() => {
                this.pickLocal(item.name);
              })
            }, (item: LocalCandidate) => `dl-${item.name}`)
          }

          if (this.cachedItems.length > 0) {
            this.SectionLabel('已缓存')
            ForEach(this.cachedItems, (item: SubtitleItem) => {
              Row({ space: 8 }) {
                Text(item.id === this.chosenId ? '✓' : '')
                  .fontSize(12)
                  .width(14)
                  .fontColor(Theme.ACCENT)
                Text(item.name)
                  .fontSize(13)
                  .fontColor(item.id === this.chosenId ? Theme.ACCENT : Theme.TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 12, bottom: 12 })
              .onClick(() => {
                this.pick(item.id, item.name);
              })
            }, (item: SubtitleItem) => `ch-${item.id}`)
          }

          if (this.owned.length > 0) {
            this.SectionLabel('已存进片库（可删）')
            ForEach(this.owned, (item: OwnedSubtitle) => {
              Column({ space: 3 }) {
                Row({ space: 8 }) {
                  Text(item.exists ? item.filename : `${item.filename}（已不在）`)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_DIM)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (item.exists) {
                    Text('删')
                      .fontSize(11)
                      .fontColor('#FF8A80')
                      .padding({ left: 10, right: 4, top: 6, bottom: 6 })
                      .onClick(() => {
                        this.drop(item.filename);
                      })
                  }
                }
                .width('100%')
                // 解析统计（2.5.9.1）：把「字幕本身烂」和「字幕控件不显示」分开 ——
                // 有 N 条却看不见 = 选没选上/渲染问题；0 条 = 这个文件解析不出字幕。
                if (item.exists) {
                  Text(item.cues !== undefined && item.cues > 0
                    ? `${item.cues} 条${this.encTag(item)} · ${item.sample !== undefined && item.sample.length > 0
                      ? item.sample : '（首句为空）'}`
                    : '解析不出字幕内容（文件本身有问题，换一条）')
                    .fontSize(10)
                    .fontColor(item.cues !== undefined && item.cues > 0
                      ? Theme.TEXT_FAINT : '#FF8A80')
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 10, bottom: 10 })
            }, (item: OwnedSubtitle) => `ow-${item.filename}`)
          }

          this.SectionLabel('在线')
          Row() {
            Text(this.onlineShown ? '重新搜索' : '搜索在线字幕（迅雷 / JAV字幕）')
              .fontSize(13)
              .fontColor(Theme.TEXT)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 12, bottom: 12 })
          .onClick(() => {
            this.searchOnline();
          })

          if (this.needCaptcha) {
            Column({ space: 8 }) {
              Text('JAV字幕需要验证（输一次可搜几次）')
                .fontSize(11)
                .fontColor(Theme.TEXT_DIM)
                .width('100%')
              if (this.captchaImage.length > 0) {
                Web({ src: this.captchaPage(), controller: this.captchaCtrl })
                  .width(220)
                  .height(74)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(8)
                  .domStorageAccess(false)
                  .javaScriptAccess(false)
              }
              Row({ space: 8 }) {
                TextInput({ placeholder: '输入图中字符' })
                  .fontSize(12)
                  .height(34)
                  .layoutWeight(1)
                  .onChange((v: string) => {
                    this.captchaAnswer = v;
                  })
                Button('提交')
                  .fontSize(12)
                  .height(34)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.submitCaptcha();
                  })
                Button('换一张')
                  .fontSize(12)
                  .height(34)
                  .backgroundColor(Theme.CARD_HI)
                  .fontColor(Theme.TEXT)
                  .onClick(() => {
                    this.loadCaptcha();
                  })
              }
              .width('100%')
              if (this.captchaMsg.length > 0) {
                Text(this.captchaMsg)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
          }

          if (this.online.length > 0) {
            ForEach(this.online, (item: OnlineSubtitle) => {
              Row({ space: 8 }) {
                Text(item.name)
                  .fontSize(13)
                  .fontColor(this.isSaved(item) ? Theme.TEXT_FAINT : Theme.TEXT)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 已经下载过的那条：不再给「再下一次」的入口，避免同一条字幕出现两遍
                Text(this.isSaved(item) ? '已下载'
                  : `${item.provider}${item.lang.length > 0 ? ' · ' + item.lang : ''}`)
                  .fontSize(10)
                  .fontColor(this.isSaved(item) ? Theme.ACCENT : Theme.TEXT_FAINT)
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 12, bottom: 12 })
              .onClick(() => {
                if (this.isSaved(item)) {
                  this.hint = '这条已经在「已存进片库」里了，要换就点那条的「删」';
                  return;
                }
                this.useOnline(item);
              })
            }, (item: OnlineSubtitle) => `onl-${item.provider}-${item.name}`)
          }

          Blank().height(24)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  build() {
    // 标题右侧的一枚胶囊：图标 + 状态。没有箭头，也没有「管理」字样。
    Row({ space: 6 }) {
      Image($r('app.media.ic_subtitle'))
        .width(14)
        .height(14)
        .fillColor(this.chosenId.length > 0 ? Theme.ACCENT : Theme.TEXT_DIM)
      Text('字幕')
        .fontSize(11)
        .fontColor(this.chosenId.length > 0 ? Theme.ACCENT : Theme.TEXT_DIM)
      if (this.count() > 1) {
        Text(`${this.count()}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
    .border({ width: 0.5, color: '#1FFFFFFF' })
    .onClick(() => {
      this.showSheet = true;
      this.reload();
    })
    .bindSheet($$this.showSheet, this.Sheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: Theme.BG,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })
  }
}
