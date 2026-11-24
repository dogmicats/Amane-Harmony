import { curves, router } from '@kit.ArkUI';
import { ImmersiveGlass } from '../common/ImmersiveGlass';
import { Theme } from '../common/Theme';

/**
 * ★ 视觉基底原件（2026-11-18 四十一改）★
 *
 * 用户把 2.7.3.0（tag `ui-baseline-261118`）定成视觉基底，要求「每一页的顶部标题、
 * 按钮等，都改成这一套」。这套东西只有一条判据：**长得跟媒体库顶栏那四块一样**。
 *
 *   · 形状：胶囊（半径 = 高度一半）或 16 圆角的小方块。
 *   · 文字：13 / Medium / 白 + 8 半径暗投影（亮海报压上来也要站得住）。
 *   · 底色：**不画实色块**。选中 = 30% 主题色，未选中 = 12% 白 + 模糊 + 发丝亮边。
 *
 * ── 一个用血换来的限制（四十一改真机实测，别重犯）─────────────────
 * `ImmersiveGlass.supported === true` **不等于**把材质挂上去就有像素。
 * 沉浸材质的落点是官方硬限制：只有 Navigation/NavDestination 的**标题栏**、
 * `barPosition: End` 的**底部 TabBar** 里才真正渲染。
 *
 * 实测（2026-11-18 00:31 真机）：给收藏页工具条那两颗胶囊挂材质（设备支持、档位 3、
 * 还给了 12% 白着色）→ 屏幕上**什么都没了**，一排按钮变成几坨裸文字、分段条整条消失；
 * 同一份代码挂进标题栏（媒体库顶栏）就正常出玻璃。
 *
 * 所以内容区只能走兜底配方：`backgroundBlurStyle` + 12% 白 + 0.5vp 发丝亮边
 * （与抽卡墙那颗置顶按钮完全一致）。`mat` 参数是留给**标题栏里**的调用（那时才是真材质），
 * 内容区的页面一律不传。
 */

/** 胶囊文字的统一字号：与媒体库顶栏那四块同一个值。 */
const PILL_FONT: number = 13;
/** 暗投影：亮色海报底下，白字要有自己的边。 */
const PILL_SHADOW: ShadowOptions = { radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 };
/**
 * 内容区胶囊的底着色（12% 白）。
 *
 * 纯黑底上模糊几乎不画东西，靠这一层给出「这里有一颗胶囊」的轮廓；
 * 压在亮内容上又不至于变成一块奶白。数值与旧版工具条那层底色一致。
 */
const PILL_BASE: string = '#21FFFFFF';
/** 发丝亮边：玻璃的第二个信号（第一个是模糊）。35% 白在亮图与纯黑底上都清晰利落。 */
const PILL_EDGE: string = '#38FFFFFF';
/** 内容区兜底玻璃的柔阴影：让悬浮胶囊从内容中轻轻浮起。 */
const PILL_FLOAT: ShadowOptions = { radius: 12, color: '#4D000000', offsetX: 0, offsetY: 3 };

/**
 * 文字胶囊：一排动作按钮（排序 / 筛选 / 抽卡 / 清单 / 共演…）的最小单位。
 *
 * `active` = 选中：文字变主题色 + 胶囊着 30% 主题色（与顶栏「抽卡中」一致）。
 */
@Component
export struct GlassCapsule {
  @Prop label: string = '';
  @Prop active: boolean = false;
  /** 未选中时是否用暗一点的字（默认纯白，与顶栏那四块一致）。 */
  @Prop dim: boolean = false;
  /** 字号（`size` 这个属性名被 ArkUI 组件基类占了，只能叫 `fs`）。 */
  @Prop fs: number = PILL_FONT;
  @Prop padH: number = 9;
  @Prop padV: number = 7;
  @Prop radius: number = 16;
  /** 自定义着色（空 = 选中 30% 主题色 / 未选中 12% 白）。 */
  @Prop tint: string = '';
  /** 上限宽度（0 = 不限）。长标签靠省略号收尾，别把右边顶出屏幕。 */
  @Prop maxW: number = 0;
  /** 只在**标题栏里**传 true —— 内容区挂了不会有像素，见文件头那段。 */
  @Prop mat: boolean = false;
  @StorageProp('amaneGlass') level: number = 2;
  onTap: () => void = () => {};

  private fill(): string {
    if (this.tint.length > 0) {
      return this.tint;
    }
    return this.active ? Theme.accentAlpha(0.22) : PILL_BASE;
  }

  private matFill(): string | undefined {
    if (this.tint.length > 0) {
      return this.tint;
    }
    return this.active ? Theme.accentAlpha(0.22) : undefined;
  }

  build() {
    if (this.mat && ImmersiveGlass.pressMaterial(this.level, this.matFill()) !== undefined) {
      Text(this.label)
        .fontSize(this.fs)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.active ? Theme.ACCENT_INK : (this.dim ? Theme.TEXT_DIM : '#FFFFFF'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: this.maxW > 0 ? this.maxW : 10000 })
        .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
        .borderRadius(this.radius)
        .systemMaterial(ImmersiveGlass.pressMaterial(this.level, this.matFill()))
        // 材质是矩形，圆角靠 clip 裁
        .clip(true)
        .textShadow(PILL_SHADOW)
        .onClick(() => {
          this.onTap();
        })
    } else {
      Text(this.label)
        .fontSize(this.fs)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.active ? Theme.ACCENT_INK : (this.dim ? Theme.TEXT_DIM : '#FFFFFF'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: this.maxW > 0 ? this.maxW : 10000 })
        .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
        .borderRadius(this.radius)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .backgroundColor(this.fill())
        .border({ width: 0.75, color: this.active ? Theme.inkAlpha(0.48) : PILL_EDGE })
        .shadow(PILL_FLOAT)
        .textShadow(PILL_SHADOW)
        .onClick(() => {
          this.onTap();
        })
    }
  }
}

/**
 * 字形胶囊：只有一个符号的方形小件（视图切换 ☰/▦、翻页 ‹ ›…）。
 * 尺寸由调用方给，默认 34×34、圆角 12。
 */
@Component
export struct GlassGlyph {
  @Prop glyph: string = '';
  @Prop active: boolean = false;
  @Prop glyphSize: number = 15;
  @Prop boxW: number = 34;
  @Prop boxH: number = 34;
  @Prop radius: number = 12;
  @Prop mat: boolean = false;
  @StorageProp('amaneGlass') level: number = 2;
  onTap: () => void = () => {};

  private fill(): string {
    return this.active ? Theme.accentAlpha(0.22) : PILL_BASE;
  }

  /** 材质着色：同 `GlassCapsule.matFill()` —— 未选中的字形胶囊不着色（否则纯黑底上发灰）。 */
  private matFill(): string | undefined {
    return this.active ? Theme.accentAlpha(0.22) : undefined;
  }

  /** 常用裸 Unicode 字形自动升级为鸿蒙原生 SymbolGlyph，保留调用方签名零改动。 */
  private mappedSymbol(): Resource | undefined {
    if (this.glyph === '♥') {
      return $r('sys.symbol.heart_fill');
    }
    if (this.glyph === '♡') {
      return $r('sys.symbol.heart');
    }
    if (this.glyph === '▦') {
      return $r('sys.symbol.square_grid_2x2');
    }
    if (this.glyph === '☰') {
      return $r('sys.symbol.list_bullet');
    }
    if (this.glyph === '↻') {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (this.glyph === '✕') {
      return $r('sys.symbol.xmark');
    }
    return undefined;
  }

  @Builder
  GlyphFace() {
    if (this.mappedSymbol() !== undefined) {
      SymbolGlyph(this.mappedSymbol() as Resource)
        .fontSize(this.glyphSize)
        .fontWeight(FontWeight.Medium)
        .fontColor([this.active ? Theme.ACCENT_INK : '#FFFFFF'])
    } else {
      Text(this.glyph)
        .fontSize(this.glyphSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.active ? Theme.ACCENT_INK : '#FFFFFF')
        .textAlign(TextAlign.Center)
        .textShadow(PILL_SHADOW)
    }
  }

  build() {
    if (this.mat && ImmersiveGlass.pressMaterial(this.level, this.matFill()) !== undefined) {
      Stack() {
        this.GlyphFace()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .systemMaterial(ImmersiveGlass.pressMaterial(this.level, this.matFill()))
      .clip(true)
      .onClick(() => {
        this.onTap();
      })
    } else {
      Stack() {
        this.GlyphFace()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor(this.fill())
      .border({ width: 0.75, color: this.active ? Theme.accentAlpha(0.60) : PILL_EDGE })
      .shadow(PILL_FLOAT)
      .onClick(() => {
        this.onTap();
      })
    }
  }
}

/**
 * 玻璃框：把**任意内容**装进一个胶囊里（品牌字、图标、自定义排版的文字）。
 *
 * `GlassCapsule` 只管「一颗文字按钮」；需要往胶囊里塞别的东西（比如首页左上角那个
 * `Amane` 品牌签名）时用这件 —— 底配方与胶囊完全一致，所以两者并排时不打架。
 */
@Component
export struct GlassBox {
  @BuilderParam content: () => void = this.EmptyContent;
  @Prop radius: number = 15;
  @Prop padH: number = 10;
  @Prop padV: number = 5;
  @Prop mat: boolean = false;
  /**
   * 着色。空串 = **材质不着色**（真玻璃，与媒体库顶栏那四块一致）；
   * 兜底分支仍然铺 `PILL_BASE`（不然在没有材质的地方会彻底看不见）。
   */
  @Prop tint: string = '';
  /** 整块可点（四十八改：视图切换那种「点哪儿都算」的胶囊需要它）。 */
  onTap: () => void = () => {};
  @StorageProp('amaneGlass') level: number = 2;

  @Builder
  EmptyContent() {
  }

  build() {
    if (this.mat && ImmersiveGlass.materialFor(this.level, this.tint) !== undefined) {
      Row() {
        this.content()
      }
      .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
      .borderRadius(this.radius)
      .systemMaterial(ImmersiveGlass.materialFor(this.level, this.tint))
      .clip(true)
      .onClick(() => {
        this.onTap();
      })
    } else {
      Row() {
        this.content()
      }
      .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
      .borderRadius(this.radius)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor(this.tint.length > 0 ? this.tint : PILL_BASE)
      .border({ width: 0.5, color: PILL_EDGE })
      .onClick(() => {
        this.onTap();
      })
    }
  }
}

/**
 * 玻璃图标件：一颗矢量图标装进玻璃方块（首页那颗放大镜就是它）。
 * 与 `GlassGlyph` 的区别只有一处 —— 那个放的是**字形**，这个放的是 `Image` 资源。
 */
@Component
export struct GlassIcon {
  /** 图标资源：`$r('app.media.ic_search')`。默认值只是占位（ArkTS 要求有初始化）。 */
  icon: Resource = $r('app.media.ic_search');
  @Prop iconSize: number = 18;
  @Prop boxW: number = 34;
  @Prop boxH: number = 34;
  @Prop radius: number = 12;
  @Prop mat: boolean = false;
  /** 同 `GlassBox.tint`：空串 = 材质不着色。 */
  @Prop tint: string = '';
  @StorageProp('amaneGlass') level: number = 2;
  onTap: () => void = () => {};

  @Builder
  Glyph() {
    Image(this.icon)
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
      .draggable(false)
  }

  build() {
    if (this.mat && ImmersiveGlass.pressMaterial(this.level, this.tint.length > 0 ? this.tint : undefined) !== undefined) {
      Stack() {
        this.Glyph()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .systemMaterial(ImmersiveGlass.pressMaterial(this.level, this.tint.length > 0 ? this.tint : undefined))
      .clip(true)
      .onClick(() => {
        this.onTap();
      })
    } else {
      Stack() {
        this.Glyph()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor(this.tint.length > 0 ? this.tint : PILL_BASE)
      .border({ width: 0.75, color: PILL_EDGE })
      .shadow(PILL_FLOAT)
      .onClick(() => {
        this.onTap();
      })
    }
  }
}

/**
 * 返回键：**统一用 `ic_back` 那颗箭头**（六十改·2）。
 *
 * 用户：「各个界面的返回图标不好看，直接用 HDS 沉浸光感评估页里临时测试用的这一颗」。
 * 那颗就是 `app.media.ic_back`（细描边 2.1、圆头圆角，播放器 chrome 用的也是它）——
 * 之前各页用的是 `‹` 字形，笔画细、随字号变形，压在玻璃上像一根划痕。
 *
 * 与 `GlassGlyph` 的区别只有「放图标而不是字形」，底配方完全一致：
 *   标题栏里 `mat: true` → 系统材质；内容区 → 模糊 + 12% 白 + 发丝亮边。
 * `scrim` 给**压在亮海报上**的那几处（详情页/演员详情）：多垫一层 25% 黑，
 * 否则白箭头在浅色封面上就没了。
 */
@Component
export struct GlassBack {
  @Prop boxW: number = 34;
  @Prop boxH: number = 34;
  /** 圆角 = 半高 → **一颗球**（用户 2026-11-18：「背景胶囊不是颗球吗？怎么还是方块」）。 */
  @Prop radius: number = 17;
  @Prop iconSize: number = 18;
  @Prop mat: boolean = false;
  @Prop scrim: boolean = false;
  @StorageProp('amaneGlass') level: number = 2;
  onTap: () => void = () => {
    router.back();
  };

  @Builder
  Arrow() {
    Image($r('app.media.ic_back'))
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
      .draggable(false)
  }

  build() {
    if (this.mat && ImmersiveGlass.pressMaterial(this.level, undefined) !== undefined) {
      Stack() {
        this.Arrow()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .systemMaterial(ImmersiveGlass.pressMaterial(this.level, undefined))
      .clip(true)
      .onClick(() => {
        this.onTap();
      })
    } else {
      Stack() {
        this.Arrow()
      }
      .width(this.boxW)
      .height(this.boxH)
      .borderRadius(this.radius)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor(this.scrim ? '#47000000' : PILL_BASE)
      .border({ width: 0.75, color: PILL_EDGE })
      .shadow(PILL_FLOAT)
      .onClick(() => {
        this.onTap();
      })
    }
  }
}

/**
 * 页面标题：20 / Bold / 白 + 8 半径暗投影 —— 「媒体库」那三个字的规格。
 * 之前各页各写一套（19 / 20 / 15、有的没投影），切个 Tab 标题的重量就换一次。
 */
@Component
export struct PageTitle {  @Prop text: string = '';
  @Prop fs: number = 20;

  build() {
    Text(this.text)
      .fontSize(this.fs)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .maxLines(1)
      .flexShrink(0)
      .textShadow(PILL_SHADOW)
  }
}

/**
 * 二级页的标准头：返回胶囊 + 标题 + 右侧动作槽（四十一改）。
 *
 * 二级页原来各写一遍「裸 ‹ 24 号字 + 17 号标题 + 一颗实心胶囊」，十几页十二种手感。
 * 这里收成一件：返回是 `GlassGlyph('‹')`（与视图切换那两颗同一个形状），标题 18 号
 * （比主 Tab 的 20 小一档 —— 旁边多了一颗 34 的返回钮，同高才不头重），右侧留槽。
 */
@Component
export struct NavHeader {
  @Prop title: string = '';
  /** 标题下的说明（可空）。 */
  @Prop subtitle: string = '';
  /** 顶部额外留白（真全屏时传 `topInset + 6`）。 */
  @Prop padTop: number = 6;
  @BuilderParam trailing: () => void = this.EmptyTrailing;
  onBack: () => void = () => {
    router.back();
  };

  @Builder
  EmptyTrailing() {
  }

  build() {
    Row({ space: 10 }) {
      GlassBack({
        onTap: () => {
        this.onBack();
        }
      })
      Column({ space: 2 }) {
        PageTitle({ text: this.title, fs: 18 })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      this.trailing()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: Theme.PAGE_PAD, top: this.padTop, bottom: 8 })
  }
}

/**
 * ★ 统一的搜索胶囊（五十五改）★
 *
 * 用户：「放大镜要统一，你不要擅自改图标」——所以把「一颗放大镜胶囊，点一下自己长成
 * 搜索栏」这件事**收成一个组件**：所有页面用同一份实现、同一个图标、同一套尺寸比例，
 * 谁也别再手搓一个像但不一样的。
 *
 * 形态（用户定的）：
 *   收着 → 一颗 `boxH` 见方的放大镜胶囊，贴在弹性区右端（= 原来那颗放大镜的位置）
 *   展开 → **同一个节点**的宽度补间到弹性区实测宽度（真·宽度形变），里面
 *          放大镜 + 输入框 + 一个 ✕
 *   ✕ 双职责：有字先清字，没字才收起
 *
 * 用法：`GlassSearchBar({ placeholder:'搜索演员', mat:true, onCommit: … }).layoutWeight(1)`
 * —— 外层给 `layoutWeight(1)` + 与行同高，它自己负责「贴右 / 铺满」和宽度形变。
 */
@Component
export struct GlassSearchBar {
  @Prop placeholder: string = '搜索';
  /** 胶囊高度（收着时也是正方形边长）。 */
  @Prop boxH: number = 33;
  /** 所在行的高度（默认 46，与标题栏一行一致）。 */
  @Prop rowH: number = 46;
  @Prop radius: number = 16;
  /** 放大镜尺寸：统一 16（33 见方）/ 18（42）/ 20（46），比例一致。 */
  @Prop iconSize: number = 16;
  /** 只在 Navigation 标题栏里传 true。 */
  @Prop mat: boolean = false;
  @StorageProp('amaneGlass') level: number = 2;
  /** 防抖后回调关键词（空串 = 清空）。 */
  onCommit: (kw: string) => void = () => {};

  /**
   * 外部强制展开（2026-11-18 三十八改·二）。
   *
   * 默认 false，且不传就完全走原来的「点放大镜自己长」的行为 —— 演员/标签/收藏三页
   * 一个字都不用改。媒体库把它放在**标题栏第二行**：那一行只在展开时存在，
   * 所以组件出生就该是展开态（`aboutToAppear` 里同步）。
   */
  @Prop @Watch('onForceOpen') forceOpen: boolean = false;
  /** 用户点 ✕ 收起时通知外部（外部据此把自己那一行收掉）。 */
  onClosed: () => void = () => {};

  @State private open: boolean = false;
  @State private text: string = '';
  @State private midW: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    if (this.forceOpen) {
      this.open = true;
    }
  }

  private onForceOpen(): void {
    if (this.forceOpen === this.open) {
      return;
    }
    if (this.forceOpen) {
      this.open = true;
    } else {
      this.text = '';
      this.open = false;
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  /** 胶囊当前宽度：收着 = 正方形；展开 = 量到的弹性区宽度。 */
  private w(): number {
    if (!this.open) {
      return this.boxH;
    }
    return this.midW > this.boxH + 8 ? this.midW : 120;
  }

  private emit(value: string): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.onCommit(this.text.trim());
    }, 300);
  }

  private doOpen(): void {
    this.getUIContext().animateTo(
      { duration: 260, curve: curves.interpolatingSpring(0, 1, 288, 26) }, () => {
        this.open = true;
      });
  }

    private doClose(): void {
      this.text = '';
      this.getUIContext().animateTo(
        { duration: 240, curve: curves.interpolatingSpring(0, 1, 288, 30) }, () => {
          this.open = false;
        });
      this.onCommit('');
      // 外部（媒体库第二行）据此把自己那一行收掉；不传就是空实现。
      this.onClosed();
    }

  /** 那一颗 ✕：有字先清字，没字才收起。 */
  private onX(): void {
    if (this.text.length > 0) {
      this.text = '';
      this.onCommit('');
      return;
    }
    this.doClose();
  }

  @Builder
  Inner() {
    // 五十七改：**绝不能给 ic_search 加 fillColor**。
    // 那个 SVG 是 `fill=none` + `stroke` 画的外圈和手柄；一旦设 fillColor，
    // 系统会把圆圈内部一起填实 —— 演员/标签两颗放大镜就变成「实心团」，
    // 而首页/收藏（从没设过）是空心描边。用户说的「图标本身长得就不一样」就是它。
    Image($r('app.media.ic_search'))
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
      .draggable(false)

    if (this.open) {
      TextInput({ text: $$this.text, placeholder: this.placeholder })
        .layoutWeight(1)
        .height(this.boxH - 2)
        .fontSize(13)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_DIM)
        .placeholderFont({ size: 12 })
        .backgroundColor(Color.Transparent)
        .padding({ left: 6, right: 2 })
        .onChange((value: string) => {
          this.emit(value);
        })
        .onSubmit(() => {
          this.onCommit(this.text.trim());
        })

      Stack() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(12)
          .fontColor(['#CCFFFFFF'])
          .fontWeight(FontWeight.Medium)
      }
      .width(24)
      .height(24)
      .borderRadius(12)
      .onClick(() => {
        this.onX();
      })
    }
  }

  /** 有材质走材质，没有就走兜底（与其它原件同一判据）。 */
  private matOK(): boolean {
    return this.mat && ImmersiveGlass.materialFor(this.level) !== undefined;
  }

  @Builder
  Capsule() {
    if (this.matOK()) {
      Row() {
        this.Inner()
      }
      .width(this.w())
      .height(this.boxH)
      .borderRadius(this.open ? this.radius : this.boxH / 2)
      .justifyContent(this.open ? FlexAlign.Start : FlexAlign.Center)
      .padding(this.open ? { left: 10, right: 4 } : { left: 0, right: 0 })
      .systemMaterial(ImmersiveGlass.materialFor(this.level))
      .clip(true)
      .onClick(() => {
        // 2026-11-18 六十改：展开态再点放大镜 = 收起。
        // 用户原话：「搜索栏展开的时候再点一下放大镜应该要可以收起」——
        // 以前这里只管开，收只能靠 ✕，而 ✕ 的首要职责是「清字」，两件事挤在一个按钮上。
        if (this.open) {
          this.doClose();
        } else {
          this.doOpen();
        }
      })
    } else {
      Row() {
        this.Inner()
      }
      .width(this.w())
      .height(this.boxH)
      .borderRadius(this.open ? this.radius : this.boxH / 2)
      .justifyContent(this.open ? FlexAlign.Start : FlexAlign.Center)
      .padding(this.open ? { left: 10, right: 4 } : { left: 0, right: 0 })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .backgroundColor(PILL_BASE)
      .border({ width: 0.5, color: PILL_EDGE })
      .clip(true)
      .onClick(() => {
        if (this.open) {
          this.doClose();
        } else {
          this.doOpen();
        }
      })
    }
  }

  build() {
    Row() {
      this.Capsule()
    }
    .width('100%')
    .height(this.rowH)
    .justifyContent(FlexAlign.End)
    .onAreaChange((o: Area, n: Area) => {
      const w: number = parseFloat(`${n.width}`);
      if (w > 0 && Math.abs(w - this.midW) > 0.5) {
        this.midW = w;
      }
    })
  }
}