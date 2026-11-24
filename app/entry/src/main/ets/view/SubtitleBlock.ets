import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { Theme } from '../common/Theme';
import {
  LocalCandidate, OnlineSubtitle, OwnedSubtitle, SubtitleClient, SubtitleItem,
  dedupSubtitles, subSourceLabel
} from '../common/Subtitles';

/**
 * 本片字幕（详情页用 · 2.8.3 暗夜黑曜石丝绒升级）。
 *
 * 形态：标题右侧一枚紧凑玻璃胶囊（原生 SymbolGlyph + 状态），点开是底部抽屉（bindSheet），
 * 内含去重后的「同目录 / 已缓存」、「已存进片库」、「在线字幕」三大卡片组。
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

  private refreshCaptchaView(svg: string): void {
    try {
      this.captchaCtrl.loadUrl(this.pageOf(svg));
    } catch (error) {
      const e = error as BusinessError;
      console.info(`[amane] captcha reload skipped: ${e.code}`);
    }
  }

  aboutToAppear(): void {
    this.reload();
  }

  onDidBuild(): void {
    if (this.metaId > 0 && this.metaId !== this.loadedFor) {
      this.loadedFor = this.metaId;
      this.reload();
    }
  }

  private currentLabel(): string {
    if (this.chosenId.length === 0) {
      return '未选择';
    }
    for (let i = 0; i < this.cachedItems.length; i++) {
      if (this.cachedItems[i].id === this.chosenId) {
        return this.cachedItems[i].name;
      }
    }
    return '已选择';
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
      this.owned = await SubtitleClient.owned(this.metaId);
      const ownedNames: string[] = [];
      for (let i = 0; i < this.owned.length; i++) {
        if (this.owned[i].exists) {
          ownedNames.push(this.owned[i].filename);
        }
      }
      const choiceId: string = res.choice !== undefined && res.choice !== null
        && res.choice.subtitle_id !== undefined && res.choice.subtitle_id !== null
        ? res.choice.subtitle_id : '';
      if (choiceId.length > 0) {
        this.chosenId = choiceId;
      } else if (res.choice !== undefined && res.choice !== null && choiceId.length === 0) {
        this.chosenId = '';
      }
      const dedup = dedupSubtitles(
        res.local === undefined || res.local === null ? [] : res.local,
        res.cached === undefined || res.cached === null ? [] : res.cached,
        this.chosenId,
        ownedNames
      );
      this.local = dedup.local;
      this.cachedItems = dedup.cached;
      this.hint = res.hint === undefined || res.hint === null ? '' : res.hint;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] subtitle block: ${e.code} ${e.message}`);
    }
  }

  private async pick(id: string, label: string): Promise<void> {
    const before: string = this.chosenId;
    this.chosenId = id;
    this.hint = id.length > 0 ? `已切换：${label}` : '已取消默认外挂字幕';
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
      this.hint = `已切换：${name}`;
      await this.reload();
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

  private encTag(item: OwnedSubtitle): string {
    const enc: string = item.encoding === undefined || item.encoding === null ? '' : item.encoding;
    if (enc.length === 0 || enc.indexOf('UTF-8') === 0) {
      return '';
    }
    return ` · ${enc}`;
  }

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
        this.hint = '已保存，但这份字幕解析不出内容（0 条）—— 换一条试试';
      } else {
        this.hint = res.kind === 'library'
          ? `已存到资源库：${res.files.join(' / ')}${cues > 0 ? ` · ${cues} 条` : ''}`
          : `已缓存（写不进媒体目录：${res.reason}）`;
      }
      this.online = this.online.filter((x: OnlineSubtitle) =>
        !(x.provider === item.provider && x.name === item.name));
      await this.reload();
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
  Sheet() {
    Column({ space: 10 }) {
      // 顶栏：本片字幕 + 当前选中状态
      Row({ space: 8 }) {
        Text('本片字幕')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
        if (this.busy) {
          Text('处理中…')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        } else {
          Text(`当前：${this.currentLabel()}`)
            .fontSize(11)
            .fontColor(this.chosenId.length > 0 ? Theme.ACCENT_INK : Theme.TEXT_FAINT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 6, bottom: 2 })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .width('100%')
          .padding({ left: 18, right: 18 })
          .maxLines(3)
      }

      Scroll() {
        Column({ space: 12 }) {
          // 卡片一：同目录 / 已缓存（已去重合并）
          if (this.local.length > 0 || this.cachedItems.length > 0) {
            Column({ space: 6 }) {
              Row() {
                Text('同目录 / 已缓存')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT_DIM)
                Blank()
                if (this.chosenId.length > 0) {
                  Text('取消默认')
                    .fontSize(11)
                    .fontColor(Theme.TEXT_FAINT)
                    .padding({ left: 8, right: 2, top: 2, bottom: 2 })
                    .onClick(() => {
                      this.pick('', '');
                    })
                }
              }
              .width('100%')
              .padding({ left: 4, right: 4, bottom: 2 })

              ForEach(this.cachedItems, (item: SubtitleItem) => {
                Row({ space: 8 }) {
                  if (item.id === this.chosenId) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(13)
                      .fontColor([Theme.ACCENT_INK])
                  }
                  Column({ space: 2 }) {
                    Text(item.name)
                      .fontSize(13)
                      .fontWeight(item.id === this.chosenId ? FontWeight.Medium : FontWeight.Normal)
                      .fontColor(item.id === this.chosenId ? Theme.TEXT : Theme.TEXT_DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(subSourceLabel(item.source))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (item.id === this.chosenId) {
                    Text('使用中')
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ACCENT_INK)
                      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                      .backgroundColor(Theme.accentAlpha(0.18))
                      .border({ width: 0.75, color: Theme.accentAlpha(0.55) })
                      .borderRadius(10)
                  }
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(item.id === this.chosenId ? Theme.accentAlpha(0.15) : '#00000000')
                .border({
                  width: item.id === this.chosenId ? 0.75 : 0,
                  color: Theme.accentAlpha(0.45)
                })
                .borderRadius(12)
                .onClick(() => {
                  this.pick(item.id, item.name);
                })
              }, (item: SubtitleItem) => `ch-${item.id}`)

              ForEach(this.local, (item: LocalCandidate) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(item.name)
                      .fontSize(13)
                      .fontColor(Theme.TEXT_DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text('同目录')
                      .fontSize(10)
                      .fontColor(Theme.TEXT_FAINT)
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .borderRadius(12)
                .onClick(() => {
                  this.pickLocal(item.name);
                })
              }, (item: LocalCandidate) => `dl-${item.name}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .border({ width: 0.75, color: '#1FFFFFFF' })
            .borderRadius(16)
          }

          // 卡片二：已存进片库（可删）
          if (this.owned.length > 0) {
            Column({ space: 8 }) {
              Text('已存进片库')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT_DIM)
                .width('100%')
                .padding({ left: 4, bottom: 2 })

              ForEach(this.owned, (item: OwnedSubtitle) => {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text(item.exists ? item.filename : `${item.filename}（已不在）`)
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    if (item.exists) {
                      Text(item.cues !== undefined && item.cues > 0
                        ? `${item.cues} 条${this.encTag(item)} · ${item.sample !== undefined && item.sample.length > 0
                          ? item.sample : '（首句为空）'}`
                        : '解析不出字幕内容（文件本身有问题，建议删除后重下）')
                        .fontSize(10)
                        .fontColor(item.cues !== undefined && item.cues > 0
                          ? Theme.TEXT_FAINT : '#FF8FA0')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (item.exists) {
                    Text('删除')
                      .fontSize(11)
                      .fontColor('#FF8FA0')
                      .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                      .backgroundColor('#24FF5F6E')
                      .border({ width: 0.75, color: '#59FF5F6E' })
                      .borderRadius(11)
                      .onClick(() => {
                        this.drop(item.filename);
                      })
                  }
                }
                .width('100%')
                .padding({ left: 4, right: 4, top: 4, bottom: 4 })
              }, (item: OwnedSubtitle) => `ow-${item.filename}`)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .border({ width: 0.75, color: '#1FFFFFFF' })
            .borderRadius(16)
          }

          // 卡片三：在线字幕搜索
          Column({ space: 10 }) {
            Text('在线字幕')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
              .padding({ left: 4 })

            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(14)
                .fontColor([Theme.ACCENT_INK])
              Text(this.onlineShown ? '重新搜索在线字幕' : '搜索在线字幕（迅雷 / JAV字幕）')
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(13)
                .fontColor([Theme.TEXT_FAINT])
            }
            .width('100%')
            .padding({ left: 14, right: 12, top: 11, bottom: 11 })
            .backgroundColor(Theme.accentAlpha(0.12))
            .border({ width: 0.75, color: Theme.accentAlpha(0.32) })
            .borderRadius(12)
            .onClick(() => {
              this.searchOnline();
            })

            if (this.needCaptcha) {
              Column({ space: 8 }) {
                Text('JAV字幕需要验证（输一次可连续搜几次）')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_DIM)
                  .width('100%')
                if (this.captchaImage.length > 0) {
                  Web({ src: this.captchaPage(), controller: this.captchaCtrl })
                    .width(220)
                    .height(74)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(10)
                    .domStorageAccess(false)
                    .javaScriptAccess(false)
                }
                Row({ space: 8 }) {
                  TextInput({ placeholder: '输入图中字符' })
                    .fontSize(12)
                    .fontColor(Theme.TEXT)
                    .placeholderColor(Theme.TEXT_FAINT)
                    .backgroundColor(Theme.CARD_HI)
                    .border({ width: 0.75, color: '#1FFFFFFF' })
                    .borderRadius(10)
                    .height(36)
                    .layoutWeight(1)
                    .onChange((v: string) => {
                      this.captchaAnswer = v;
                    })
                  Text('提交')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.ON_ACCENT)
                    .padding({ left: 14, right: 14 })
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .linearGradient(Theme.ctaGradient())
                    .borderRadius(10)
                    .opacity(this.busy ? 0.5 : 1)
                    .onClick(() => {
                      if (!this.busy) {
                        this.submitCaptcha();
                      }
                    })
                  Text('换一张')
                    .fontSize(12)
                    .fontColor(Theme.TEXT)
                    .padding({ left: 12, right: 12 })
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(Theme.CARD_HI)
                    .border({ width: 0.75, color: '#1FFFFFFF' })
                    .borderRadius(10)
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
              .padding(10)
              .backgroundColor(Theme.BG_RAISED)
              .borderRadius(12)
            }

            if (this.online.length > 0) {
              Column({ space: 6 }) {
                ForEach(this.online, (item: OnlineSubtitle) => {
                  Row({ space: 10 }) {
                    Stack({ alignContent: Alignment.Center }) {
                      SymbolGlyph($r('sys.symbol.doc_text'))
                        .fontSize(15)
                        .fontColor([this.isSaved(item) ? Theme.TEXT_FAINT : Theme.TEXT_DIM])
                    }
                    .width(32)
                    .height(32)
                    .borderRadius(9)
                    .backgroundColor(Theme.CARD_HI)

                    Column({ space: 2 }) {
                      Text(item.name)
                        .fontSize(12)
                        .fontColor(this.isSaved(item) ? Theme.TEXT_FAINT : Theme.TEXT)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(`${item.provider}${item.lang.length > 0 ? ' · ' + item.lang : ''}`)
                        .fontSize(10)
                        .fontColor(Theme.TEXT_FAINT)
                        .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.isSaved(item)) {
                      Text('已下载')
                        .fontSize(10)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#6EE7B7')
                        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                        .backgroundColor('#224ADE80')
                        .border({ width: 0.75, color: '#4D4ADE80' })
                        .borderRadius(10)
                    } else {
                      Text('下载')
                        .fontSize(10)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.ACCENT_INK)
                        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                        .backgroundColor(Theme.accentAlpha(0.16))
                        .border({ width: 0.75, color: Theme.accentAlpha(0.45) })
                        .borderRadius(10)
                    }
                  }
                  .width('100%')
                  .padding({ left: 6, right: 6, top: 8, bottom: 8 })
                  .borderRadius(12)
                  .onClick(() => {
                    if (this.isSaved(item)) {
                      this.hint = '这条已经在「已存进片库」里了，要换就点那条的「删除」';
                      return;
                    }
                    this.useOnline(item);
                  })
                }, (item: OnlineSubtitle) => `onl-${item.provider}-${item.name}`)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.CARD)
          .border({ width: 0.75, color: '#1FFFFFFF' })
          .borderRadius(16)

          Blank().height(20)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
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
    // 标题右侧的一枚丝绒玻璃胶囊（原生 SymbolGlyph 替代 fillColor SVG，杜绝白块 bug）
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.translate'))
        .fontSize(13)
        .fontColor([this.chosenId.length > 0 ? Theme.ACCENT_INK : Theme.TEXT_DIM])
      Text('字幕')
        .fontSize(11)
        .fontWeight(this.chosenId.length > 0 ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.chosenId.length > 0 ? Theme.ACCENT_INK : Theme.TEXT_DIM)
      if (this.count() > 1) {
        Text(`${this.count()}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .fontFeature('"tnum" 1')
      }
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(this.chosenId.length > 0 ? Theme.accentAlpha(0.16) : Theme.CARD)
    .borderRadius(14)
    .border({
      width: 0.75,
      color: this.chosenId.length > 0 ? Theme.accentAlpha(0.45) : '#1FFFFFFF'
    })
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
