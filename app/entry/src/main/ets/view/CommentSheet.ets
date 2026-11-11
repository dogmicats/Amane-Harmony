import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommentItem } from '../common/Types';
import { Theme } from '../common/Theme';

/**
 * 评价正文里的链接片段。`url` 非空表示这一段本身就是一个可点的链接。
 * 列表里只显示纯文字，点开单条评价后再按片段渲染成可点文本。
 */
export interface CommentSeg {
  text: string;
  url: string;
}

/** 认这两种：网页链接、ed2k 之外的磁力链（刮削站的评价里最常见的就是磁力）。 */
const LINK_SPLIT: RegExp = /(https?:\/\/[^\s]+|magnet:\?xt=[^\s]+)/;
const LINK_HEAD: RegExp = /^(https?:\/\/|magnet:\?xt=)/;

/** 链接尾上常粘着中文标点/右括号，切出来时要剔掉，否则打开会 404。 */
const TAIL_TRIM: string = '。，、；：！？）)】」』>,."\'';

function trimTail(url: string): string {
  let s: string = url;
  while (s.length > 0 && TAIL_TRIM.indexOf(s.charAt(s.length - 1)) >= 0) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/**
 * 把正文切成「普通文字 / 链接」片段。
 * markdown 的 `[文字](链接)` 转成「文字 链接」，这样链接本身还能点。
 */
export function splitComment(body: string): CommentSeg[] {
  const out: CommentSeg[] = [];
  if (body === undefined || body === null || body.length === 0) {
    return out;
  }
  let s: string = body.replace(/\*\*/g, '').replace(/^>\s?/gm, '');
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 $2');
  const parts: string[] = s.split(LINK_SPLIT);
  for (let i = 0; i < parts.length; i++) {
    const p: string = parts[i];
    if (p.length === 0) {
      continue;
    }
    if (LINK_HEAD.test(p)) {
      const url: string = trimTail(p);
      const rest: string = p.substring(url.length);
      if (url.length > 0) {
        out.push({ text: url, url: url });
      }
      if (rest.length > 0) {
        out.push({ text: rest, url: '' });
      }
    } else {
      out.push({ text: p, url: '' });
    }
  }
  return out;
}

/** 列表预览用：一段纯文字（链接保留原文，只是不可点）。 */
export function commentPreview(body: string, maxChars: number): string {
  let s: string = body.replace(/\*\*/g, '').replace(/^>\s?/gm, '');
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 $2').trim();
  if (s.length > maxChars) {
    return s.substring(0, maxChars) + '…';
  }
  return s;
}

/**
 * 单条评价的全文弹层。
 *
 * 详情页原来把正文截成 6 行、且把链接语法抹成纯文字，长评看不全、带链接的也点不了。
 * 这里给一条完整可滚动的正文，链接按片段渲染成可点文字，调系统浏览器打开。
 */
@Component
export struct CommentSheet {
  comment: CommentItem = {
    id: 0, body: '', created_at: '', updated_at: ''
  };
  onClose: () => void = () => {};

  private openLink(url: string): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.openLink(url).catch((err: BusinessError) => {
        console.error(`[amane] openLink ${err.code} ${err.message}`);
      });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] openLink throw ${e.code} ${e.message}`);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶部把手 + 关闭
        Row() {
          Text('评价')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Blank()
          Text('关闭')
            .fontSize(12)
            .fontColor(Theme.ACCENT)
            .padding({ left: 10, right: 4, top: 6, bottom: 6 })
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
        .padding({ left: 18, right: 14, top: 14, bottom: 6 })

        if (this.comment.created_at.length > 0) {
          Text(this.comment.created_at.length >= 10
            ? this.comment.created_at.substring(0, 10) : this.comment.created_at)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .padding({ left: 18, right: 18, bottom: 8 })
        }

        Scroll() {
          // 按片段渲染：普通文字直接 Text，链接单独一段可点。
          // Flex 换行让链接自然排在行内，而不是每个片段独占一行。
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(splitComment(this.comment.body), (seg: CommentSeg, index: number) => {
              if (seg.url.length > 0) {
                Text(seg.text)
                  .fontSize(13)
                  .lineHeight(21)
                  .fontColor(Theme.ACCENT)
                  .decoration({ type: TextDecorationType.Underline, color: Theme.ACCENT })
                  .onClick(() => {
                    this.openLink(seg.url);
                  })
              } else {
                Text(seg.text)
                  .fontSize(13)
                  .lineHeight(21)
                  .fontColor(Theme.TEXT_DIM)
              }
            }, (seg: CommentSeg, index: number) => `seg-${index}`)
          }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 28 })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('72%')
      .backgroundColor(Theme.BG_RAISED)
      .borderRadius({ topLeft: 18, topRight: 18 })
      .onClick(() => {
        // 吞掉点击，避免穿透到遮罩
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .onClick(() => {
      this.onClose();
    })
  }
}
