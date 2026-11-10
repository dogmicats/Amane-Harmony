import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

/**
 * 更新日志。数据源是 resources/rawfile/changelog.md —— 由 tools/version.py sync
 * 从仓库根 CHANGELOG.md 复制过来，不要手改 rawfile（下次 sync 会被覆盖）。
 *
 * 只做「够用的 Markdown 子集」渲染：## 版本标题 / 整行 **小标题** / - 列表 /
 * > 引用 / --- 分隔线 / 行内 **粗体**。CHANGELOG 里也只用到这些。
 */

interface LogLine {
  kind: string;
  text: string;
}

interface LogVersion {
  version: string;
  date: string;
  /** 段首那个整行粗体的小标题，折叠时当摘要显示。 */
  summary: string;
  lines: LogLine[];
}

interface Inline {
  t: string;
  b: boolean;
}

function kindOf(line: string): string {
  const t: string = line.trim();
  if (t.length === 0) {
    return 'empty';
  }
  if (t === '---' || t === '***') {
    return 'hr';
  }
  if (t.startsWith('>')) {
    return 'quote';
  }
  if (t.startsWith('- ') || t.startsWith('* ')) {
    return (line.startsWith('  ') || line.startsWith('\t')) ? 'li2' : 'li1';
  }
  if (t.startsWith('**') && t.endsWith('**') && t.length > 4) {
    return 'h';
  }
  if (t.startsWith('#')) {
    return 'text';
  }
  return 'text';
}

function bodyOf(line: string, kind: string): string {
  const t: string = line.trim();
  if (kind === 'quote') {
    return t.substring(1).trim();
  }
  if (kind === 'li1' || kind === 'li2') {
    return t.substring(2).trim();
  }
  return t;
}

/** 行内 **粗体** 切段；反引号直接去掉，代码感靠等宽字体不值得多一层解析。 */
function segments(text: string): Inline[] {
  const out: Inline[] = [];
  let rest: string = text.replace(/`/g, '');
  while (rest.length > 0) {
    const i: number = rest.indexOf('**');
    if (i < 0) {
      const tail: Inline = { t: rest, b: false };
      out.push(tail);
      break;
    }
    const j: number = rest.indexOf('**', i + 2);
    if (j < 0) {
      const tail: Inline = { t: rest, b: false };
      out.push(tail);
      break;
    }
    if (i > 0) {
      const plain: Inline = { t: rest.substring(0, i), b: false };
      out.push(plain);
    }
    const bold: Inline = { t: rest.substring(i + 2, j), b: true };
    out.push(bold);
    rest = rest.substring(j + 2);
  }
  return out;
}

/** 拼接被硬换行拆开的同一段。中文直接连，英文单词之间补一个空格。 */
function joinText(head: string, tail: string): string {
  if (head.length === 0) {
    return tail;
  }
  const a: string = head.charAt(head.length - 1);
  const b: string = tail.charAt(0);
  const asciiA: boolean = /[A-Za-z0-9]/.test(a);
  const asciiB: boolean = /[A-Za-z0-9]/.test(b);
  return asciiA && asciiB ? `${head} ${tail}` : head + tail;
}

function parseLog(text: string, current: string): LogVersion[] {
  const out: LogVersion[] = [];
  const rows: string[] = text.split('\n');
  let cur: number = -1;
  let broken: boolean = true; // 上一行是空行 → 下一行一定新起一段
  for (let i = 0; i < rows.length; i++) {
    const line: string = rows[i].replace('\r', '');
    if (line.startsWith('## ')) {
      const head: string = line.substring(3).trim();
      const parts: string[] = head.split(' ');
      // 标题带完成时间（CONVENTIONS.md §8.5）：## 2.3.12 (2026-11-10 11:20)
      const dm: RegExpMatchArray | null = head.match(/\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?/);
      const item: LogVersion = {
        version: parts.length > 0 ? parts[0].replace(/^\[|\]$/g, '') : head,
        date: dm !== null ? dm[0] : '',
        summary: '',
        lines: []
      };
      out.push(item);
      cur = out.length - 1;
      broken = true;
      continue;
    }
    if (cur < 0) {
      continue; // 第一个 ## 之前的文件说明不展示
    }
    const kind: string = kindOf(line);
    if (kind === 'empty') {
      broken = true;
      continue;
    }
    const body: string = bodyOf(line, kind);
    const last: number = out[cur].lines.length - 1;
    const prevKind: string = last >= 0 ? out[cur].lines[last].kind : '';

    // CHANGELOG 是按 ~45 字手工换行的。不合并的话每行都按原文断在中间，
    // 右边白一大截；合并后交给 Text 自己折行。
    if (!broken && last >= 0) {
      if (kind === 'text' && (prevKind === 'text' || prevKind === 'li1' || prevKind === 'li2')) {
        out[cur].lines[last].text = joinText(out[cur].lines[last].text, body);
        continue;
      }
      if (kind === 'quote' && prevKind === 'quote') {
        out[cur].lines[last].text = joinText(out[cur].lines[last].text, body);
        continue;
      }
    }
    const row: LogLine = { kind: kind, text: body };
    out[cur].lines.push(row);
    if (kind === 'h' && out[cur].summary.length === 0) {
      out[cur].summary = body.replace(/^\*\*|\*\*$/g, '');
    }
    broken = false;
  }
  // 当前版本没有段落时别让页面看起来是空的
  if (out.length === 0) {
    const fallback: LogVersion = {
      version: current, date: '', summary: '',
      lines: [{ kind: 'text', text: '这一版没有写更新日志。' }]
    };
    out.push(fallback);
  }
  return out;
}

@Entry
@Component
struct ChangelogPage {
  @State versions: LogVersion[] = [];
  @State open: string[] = [];
  @State failed: boolean = false;
  private current: string = BuildConfig.APP_VERSION;

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('changelog.md');
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      this.versions = parseLog(text, this.current);
      // 默认只展开最新一版：36 个版本全展开要渲几千行
      this.open = this.versions.length > 0 ? [this.versions[0].version] : [];
    } catch (err) {
      this.failed = true;
      console.error(`[amane] changelog load failed: ${err}`);
    }
  }

  private isOpen(version: string): boolean {
    return this.open.indexOf(version) >= 0;
  }

  private toggle(version: string): void {
    const next: string[] = this.open.slice();
    const i: number = next.indexOf(version);
    if (i >= 0) {
      next.splice(i, 1);
    } else {
      next.push(version);
    }
    this.open = next;
  }

  /** 行内粗体要拆 Span，所以正文统一走 Text + ForEach(Span)。 */
  @Builder
  Rich(text: string, size: number, color: string, weight: FontWeight) {
    Text() {
      ForEach(segments(text), (s: Inline, idx: number) => {
        Span(s.t)
          .fontSize(size)
          .fontColor(s.b ? Theme.TEXT : color)
          .fontWeight(s.b ? FontWeight.Bold : weight)
      }, (s: Inline, idx: number) => `${idx}-${s.t.length}`)
    }
    .width('100%')
    .lineHeight(size + 7)
  }

  @Builder
  Line(line: LogLine) {
    if (line.kind === 'hr') {
      Divider()
        .color(Theme.CARD_HI)
        .margin({ top: 10, bottom: 6 })
    } else if (line.kind === 'h') {
      Text(line.text.replace(/^\*\*|\*\*$/g, ''))
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
        .width('100%')
        .margin({ top: 14, bottom: 3 })
    } else if (line.kind === 'quote') {
      Row() {
        Text(line.text)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .lineHeight(17)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, top: 4, bottom: 4 })
      .border({ width: { left: 2 }, color: { left: Theme.CARD_HI } })
      .margin({ top: 4, bottom: 4 })
    } else if (line.kind === 'li1' || line.kind === 'li2') {
      Row({ space: 5 }) {
        Text('•')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .width(8)
          .height(19)
          .textAlign(TextAlign.Center)
        Column() {
          this.Rich(line.text, 12, Theme.TEXT_DIM, FontWeight.Normal)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: line.kind === 'li2' ? 16 : 2, top: 5 })
    } else {
      Column() {
        this.Rich(line.text, 12, Theme.TEXT_DIM, FontWeight.Normal)
      }
      .width('100%')
      .padding({ top: 6 })
    }
  }

  @Builder
  VersionCard(item: LogVersion) {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(item.version)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(item.version === this.current ? Theme.ACCENT : Theme.TEXT)
            if (item.version === this.current) {
              Text('当前')
                .fontSize(9)
                .fontColor('#FFFFFF')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(Theme.ACCENT)
                .borderRadius(6)
            }
            if (item.date.length > 0) {
              Text(item.date)
                .fontSize(10)
                .fontColor(Theme.TEXT_FAINT)
            }
          }
          // 折叠时给一行摘要，不然列表上只看见一串版本号，得逐个点开
          if (!this.isOpen(item.version) && item.summary.length > 0) {
            Text(item.summary)
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.isOpen(item.version) ? '▾' : '›')
          .fontSize(13)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .onClick(() => {
        this.toggle(item.version);
      })

      if (this.isOpen(item.version)) {
        Column() {
          ForEach(item.lines, (line: LogLine, idx: number) => {
            this.Line(line)
          }, (line: LogLine, idx: number) => `${idx}-${line.kind}-${line.text.length}`)
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 14 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  build() {
    Column({ space: 14 }) {
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
          Text('更新日志')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(`当前版本 ${this.current} · ${BuildConfig.CHANNEL === 'self' ? '自用线' : '公开发布'}`)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 4 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.failed) {
            Text('读不到内置的更新日志（rawfile/changelog.md 缺失），重新构建前先跑 tools/version.py sync。')
              .fontSize(12)
              .fontColor(Theme.DANGER)
              .lineHeight(18)
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.CARD)
              .borderRadius(Theme.RADIUS)
          }
          ForEach(this.versions, (item: LogVersion) => {
            this.VersionCard(item)
          }, (item: LogVersion) => `${item.version}-${this.isOpen(item.version) ? 'o' : 'c'}`)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 40 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
