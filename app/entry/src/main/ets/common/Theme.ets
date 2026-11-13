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
  /** 主强调色：选中态、按钮、进度圈、评分星。 */
  accent: string;
  /** 渐变第二色（同色系更亮 / 略偏色），只给渐变和大色块用。 */
  accent2: string;
  /** 强调色的深底版本：标签底色、徽章底、选中 chip 底。 */
  soft: string;
  /** 压在 accent 上的文字色（亮色配深字，暗色配白字）。 */
  onAccent: string;
}

/** 预设顺序 = 设置页里的展示顺序，第一项是默认值。 */
export const THEME_PALETTES: ThemePalette[] = [
  { key: 'violet', name: '幽紫', hint: '经典影院紫', accent: '#8B6CFF', accent2: '#C77DFF', soft: '#2A2350', onAccent: '#FFFFFF' },
  { key: 'indigo', name: '靛蓝', hint: '深夜放映厅', accent: '#5B8CFF', accent2: '#7BD5FF', soft: '#1C2A4A', onAccent: '#FFFFFF' },
  { key: 'teal', name: '青碧', hint: '冷调霓虹', accent: '#2FD4BE', accent2: '#86F2E0', soft: '#103B37', onAccent: '#06231F' },
  { key: 'mint', name: '薄荷', hint: '清爽夜绿', accent: '#55D98C', accent2: '#A8F0B8', soft: '#12341F', onAccent: '#062114' },
  { key: 'amber', name: '琥珀', hint: '胶片暖光', accent: '#FFB03A', accent2: '#FFD98A', soft: '#3B2A10', onAccent: '#1A1204' },
  { key: 'coral', name: '珊瑚', hint: '黄昏余温', accent: '#FF7A63', accent2: '#FFB18A', soft: '#3F211B', onAccent: '#1F0A06' },
  { key: 'rose', name: '玫红', hint: '霓虹灯牌', accent: '#FF5F92', accent2: '#FFA8C7', soft: '#40182A', onAccent: '#2A0512' },
  { key: 'graphite', name: '石墨', hint: '极简黑白', accent: '#C3C9D6', accent2: '#EFF2F8', soft: '#23262E', onAccent: '#0B0B0F' }
];

export const DEFAULT_THEME_KEY: string = 'violet';

export class Theme {
  static readonly BG: string = '#0B0B0F';
  static readonly BG_RAISED: string = '#14141A';
  static readonly CARD: string = '#1B1B22';
  static readonly CARD_HI: string = '#24242D';
  static readonly TEXT: string = '#F4F4F7';
  static readonly TEXT_DIM: string = '#A3A3AE';
  static readonly TEXT_FAINT: string = '#6C6C78';
  /** 未选中的底栏图标/文字：比 TEXT_FAINT 亮，深底上才看得清。 */
  static readonly TAB_IDLE: string = '#C2C2CE';
  /**
   * 页面底部安全距离（TabBar 58 + 系统导航条 + 余量）。
   *
   * **凡是「贴在页面最底部」的内容都要留这么多**：Tab 页里最后的列表/卡片如果不留，
   * 会被悬浮底栏和手势条盖住，点了没反应（收藏页的入库卡就踩过）。
   */
  static readonly BOTTOM_SAFE: number = 108;
  /** 当前强调色：由 `applyPalette()` 改写，别在页面里写死十六进制。 */
  static ACCENT: string = '#8B6CFF';
  /** 渐变的第二色：`linearGradient` 的终点，别单独拿它当文字色。 */
  static ACCENT2: string = '#C77DFF';
  static ACCENT_SOFT: string = '#2A2350';
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

  /** 切到某套预设；未知键退回默认，不抛错（偏好文件被改坏也不至于白屏）。 */
  static applyPalette(key: string): void {
    const picked: ThemePalette = Theme.paletteOf(key);
    Theme.paletteKey = picked.key;
    Theme.ACCENT = picked.accent;
    Theme.ACCENT2 = picked.accent2;
    Theme.ACCENT_SOFT = picked.soft;
    Theme.ON_ACCENT = picked.onAccent;
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

  /** 任意色 + 透明度 → `#AARRGGBB`（`accent2` 的蒙层也用得上）。 */
  static alphaOf(color: string, alpha: number): string {
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const hex: string = a.toString(16).toUpperCase();
    const aa: string = hex.length < 2 ? `0${hex}` : hex;
    const body: string = color.length === 9 ? color.substring(3) : color.substring(1);
    return `#${aa}${body.toUpperCase()}`;
  }
}
