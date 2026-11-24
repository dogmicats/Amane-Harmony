/**
 * 主题常量：深色影院风。
 *
 * **强调色是可变的**（2.5.2 起）：`ACCENT` / `ACCENT2` / `ACCENT_SOFT` / `ON_ACCENT`
 * 由 `Personalize.applyTheme()` 在启动时与用户切换时整体改写。
 * 其余底色（BG / CARD / TEXT…）**故意不跟主题变** —— 只换强调色，
 * 才不会出现「某块卡片没跟上」的花屏；换主题后需要整棵树重建，
 * 由 `Index.ets` 监听 `AppStorage['amaneThemeEpoch']` 完成（见 `common/Personalize.ets` 头注释）。
 *
 * 每套配色是**四件套**，不是随便挑一个十六进制：
 *   - `accent`   主色（按钮底、选中态、图标、进度）
 *   - `accent2`  同族更亮的第二色，只用于渐变（大色块单调 = 廉价感）
 *   - `soft`     同一色相压暗到「能当底」的深色，用于 chip 底 / 徽章底
 *   - `onAccent` 压在 `accent` 上的文字色 —— 亮色主题（琥珀/薄荷/石墨）必须用深色字，
 *                统一写白字会在琥珀上糊成一片，这是上一版最丑的地方
 */
export interface ThemePalette {
  /** 偏好里存的键，一旦发布不能再改。 */
  key: string;
  /** 设置页显示的名字。 */
  name: string;
  /** 一句话气质，色卡下面那行小字。 */
  hint: string;
  /** 主强调色（受控低眩光宝石色）：实心主按钮、进度条、开关。 */
  accent: string;
  /** 渐变高光端（同色系丝光高点）：给主按钮与进度条做柔和宝石立体渐变。 */
  accent2: string;
  /** 暗底/玻璃专用文字与图标高亮色（高明度、低刺眼）：绝不让高饱和荧光字在 OLED 暗底上发毛。 */
  ink: string;
  /** 强调色的深底版本：标签底色、徽章底、选中 chip 底。 */
  soft: string;
  /** 压在 accent 上的文字色（亮色配深字，暗色配白字）。 */
  onAccent: string;
  /** 微调暗色浮层底（3–5% 同色相温度偏移，消除暖色主题贴在冷蓝灰卡片上的割裂感）。 */
  bgRaised: string;
  /** 微调暗色卡片底。 */
  card: string;
  /** 微调暗色高亮卡片/次级底。 */
  cardHi: string;
}

/** 预设顺序 = 设置页里的展示顺序，第一项是默认值（2.8.2 暗影院低眩光色系重构）。 */
export const THEME_PALETTES: ThemePalette[] = [
  {
    key: 'rose', name: '蔷薇', hint: '暗夜丝绒粉',
    accent: '#D95382', accent2: '#F28CB0', ink: '#FF9EBF', soft: '#331724', onAccent: '#FFFFFF',
    bgRaised: '#161215', card: '#1E181C', cardHi: '#282026'
  },
  {
    key: 'violet', name: '暮紫', hint: '深邃影院紫',
    accent: '#7E62E8', accent2: '#B197FC', ink: '#C2B0FF', soft: '#251D44', onAccent: '#FFFFFF',
    bgRaised: '#13121B', card: '#1A1824', cardHi: '#242131'
  },
  {
    key: 'indigo', name: '深海', hint: '静谧午夜蓝',
    accent: '#4E7AE6', accent2: '#80B3FF', ink: '#96BEFF', soft: '#18243E', onAccent: '#FFFFFF',
    bgRaised: '#11141C', card: '#171B26', cardHi: '#202635'
  },
  {
    key: 'teal', name: '松石', hint: '清透暗青',
    accent: '#2BA89C', accent2: '#6ADBD0', ink: '#78E2D7', soft: '#11302E', onAccent: '#071D1B',
    bgRaised: '#111718', card: '#161F20', cardHi: '#1F2B2C'
  },
  {
    key: 'mint', name: '青苔', hint: '低饱和森绿',
    accent: '#45B075', accent2: '#86E0AC', ink: '#8EE6B4', soft: '#142F20', onAccent: '#081E12',
    bgRaised: '#111714', card: '#161F1A', cardHi: '#1F2B24'
  },
  {
    key: 'amber', name: '琥珀', hint: '复古胶片金',
    accent: '#D4913B', accent2: '#F4C97E', ink: '#F6CD84', soft: '#332512', onAccent: '#1A1105',
    bgRaised: '#171410', card: '#201B15', cardHi: '#2B241C'
  },
  {
    key: 'coral', name: '赤陶', hint: '暖雾暮红',
    accent: '#D96857', accent2: '#F6A192', ink: '#FFA798', soft: '#361C18', onAccent: '#FFFFFF',
    bgRaised: '#171212', card: '#201918', cardHi: '#2B2120'
  },
  {
    key: 'graphite', name: '月银', hint: '极简冷银灰',
    accent: '#B8BFC9', accent2: '#E4E8F0', ink: '#DFE4EC', soft: '#22252C', onAccent: '#0B0B0F',
    bgRaised: '#131418', card: '#1B1C22', cardHi: '#25272F'
  }
];

export const DEFAULT_THEME_KEY: string = 'rose';

export class Theme {
  /** 极深黑曜石根底色：所有主题共用，确保冷启零色差与 OLED 纯暗底。 */
  static readonly BG: string = '#0B0B0F';
  /** 浮层 / 抽屉 / 卡片底色：随主题带有 3–5% 同色相暗调，彻底消除暖主题贴在冷蓝灰卡上的突兀感。 */
  static BG_RAISED: string = '#161215';
  static CARD: string = '#1E181C';
  static CARD_HI: string = '#282026';
  static readonly TEXT: string = '#F4F4F7';
  static readonly TEXT_DIM: string = '#A8A5B0';
  static readonly TEXT_FAINT: string = '#726E7B';
  /** 未选中的底栏图标/文字：比 TEXT_FAINT 亮，深底上才看得清。 */
  static readonly TAB_IDLE: string = '#C4C2CD';
  /**
   * 页面底部安全距离（TabBar 58 + 系统导航条 + 余量）。
   *
   * **凡是「贴在页面最底部」的内容都要留这么多**：Tab 页里最后的列表/卡片如果不留，
   * 会被悬浮底栏和手势条盖住，点了没反应（收藏页的入库卡就踩过）。
   */
  static readonly BOTTOM_SAFE: number = 108;
  /**
   * 状态栏（系统时间/电量那条）高度，vp。
   *
   * `Index` 在拿到窗口后写进 AppStorage；**真全屏**（`setWindowLayoutFullScreen(true)`）下
   * 内容会画到状态栏后面，顶栏必须自己让出这么多，否则标题被时钟压住。
   * 读不到就 0（等于没有全屏，顶栏不需要让位）。
   */
  static topInset(): number {
    const v: number | undefined = AppStorage.get<number>('amaneTopInset');
    return v === undefined ? 0 : v;
  }

  /** 系统导航条（手势条）高度，vp；底栏要浮在它上面，底部留白也按它加。 */
  static navInset(): number {
    const v: number | undefined = AppStorage.get<number>('amaneNavInset');
    return v === undefined ? 0 : v;
  }

  /** 无底栏独立二级页的底部安全留白（24vp 余量 + 系统手势条，避免误用 108vp 的 TabBar 留白）。 */
  static pageBottomSafe(): number {
    return 24 + Theme.navInset();
  }
  /** 当前强调色：由 `applyPalette()` 改写，别在页面里写死十六进制。 */
  static ACCENT: string = '#D95382';
  /** 渐变的第二色：`linearGradient` 的终点，别单独拿它当文字色。 */
  static ACCENT2: string = '#F28CB0';
  /** 暗底/玻璃专用文字与图标高亮色（高明度、低刺眼，消除 OLED 暗底荧光眩光）。 */
  static ACCENT_INK: string = '#FF9EBF';
  static ACCENT_SOFT: string = '#331724';
  /** 压在 ACCENT 上的文字色（亮色主题要用深字）。 */
  static ON_ACCENT: string = '#FFFFFF';
  /** 当前主题键（`violet` / `teal` / …），设置页用来高亮选中项。 */
  static paletteKey: string = DEFAULT_THEME_KEY;
  static readonly DANGER: string = '#FF5A5A';
  static readonly GOLD: string = '#F2C14E';
  static readonly RADIUS: number = 12;
  static readonly PAGE_PAD: number = 16;
  static readonly POSTER_W: number = 116;
  static readonly POSTER_H: number = 164;
  static readonly HERO_H: number = 430;

  // ── 视觉基线（2026-11-14 · 用户「要好看」）──────────────────────────────
  // 目的只有一个：**把散落的魔数收成刻度**。以前圆角全是 12、间距到处 10/14/18，
  // 单看每处都不难看，摆在一起就"廉价"。新代码一律用这些，老代码改到哪用哪，不强推。
  /** 卡片圆角（比图片大一档，才有"内嵌"感）。 */
  static readonly R_CARD: number = 16;
  /** 图片 / 海报圆角。 */
  static readonly R_IMG: number = 12;
  /** 胶囊 / chip 圆角。 */
  static readonly R_PILL: number = 999;
  /** 卡片 1px 描边：深色底上唯一能"抬起"卡片又不脏的办法。 */
  static readonly STROKE: string = '#17FFFFFF';
  /** 强调描边（选中态 / 悬停）。 */
  static readonly STROKE_HI: string = '#2EFFFFFF';
  /** 间距刻度：4 / 8 / 12 / 16 / 24。 */
  static readonly G_XS: number = 4;
  static readonly G_S: number = 8;
  static readonly G_M: number = 12;
  static readonly G_L: number = 16;
  static readonly G_XL: number = 24;
  /** 字阶：标题 / 正文 / 注解。 */
  static readonly T_TITLE: number = 17;
  static readonly T_BODY: number = 14;
  static readonly T_META: number = 11;
  /** 圆角 + 描边一次到位：`Theme.card()` 给"能点的卡片"用。 */
  static card(): number {
    return Theme.R_CARD;
  }

  /** 切到某套预设；未知键退回默认，不抛错（偏好文件被改坏也不至于白屏）。 */
  static applyPalette(key: string): void {
    const picked: ThemePalette = Theme.paletteOf(key);
    Theme.paletteKey = picked.key;
    Theme.ACCENT = picked.accent;
    Theme.ACCENT2 = picked.accent2;
    Theme.ACCENT_INK = picked.ink;
    Theme.ACCENT_SOFT = picked.soft;
    Theme.ON_ACCENT = picked.onAccent;
    Theme.BG_RAISED = picked.bgRaised;
    Theme.CARD = picked.card;
    Theme.CARD_HI = picked.cardHi;
  }

  /** 按 key 取整套（未知键退回默认）。设置页画色卡也用它。 */
  static paletteOf(key: string): ThemePalette {
    for (let i = 0; i < THEME_PALETTES.length; i++) {
      if (THEME_PALETTES[i].key === key) {
        return THEME_PALETTES[i];
      }
    }
    return THEME_PALETTES[0];
  }

  static paletteName(key: string): string {
    return Theme.paletteOf(key).name;
  }

  /**
   * 把当前强调色加上透明度，返回 `#AARRGGBB`。
   *
   * 阴影、蒙层、渐变这类地方以前写死了 `#4D7C5CFF` 这种「紫 + 30%」，
   * 换主题后会变成一块紫斑，必须走这个方法现算。
   */
  static accentAlpha(alpha: number): string {
    return Theme.alphaOf(Theme.ACCENT, alpha);
  }

  /** 高明度暗底高亮色 + 透明度（玻璃选中描边、柔光边框首选）。 */
  static inkAlpha(alpha: number): string {
    return Theme.alphaOf(Theme.ACCENT_INK, alpha);
  }

  /** 主 CTA 按钮专用宝石渐变：告别生硬平涂塑料块，与深曜黑背景自然融合。 */
  static ctaGradient(): LinearGradientOptions {
    return {
      angle: 132,
      colors: [[Theme.ACCENT, 0.0], [Theme.ACCENT2, 1.0]]
    };
  }

  /** 任意色 + 透明度 → `#AARRGGBB`（`accent2` 的蒙层也用得上）。 */
  static alphaOf(color: string, alpha: number): string {
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const hex: string = a.toString(16).toUpperCase();
    const aa: string = hex.length < 2 ? `0${hex}` : hex;
    const body: string = color.length === 9 ? color.substring(3) : color.substring(1);
    return `#${aa}${body.toUpperCase()}`;
  }
}
