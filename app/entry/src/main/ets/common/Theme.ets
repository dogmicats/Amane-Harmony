/** 主题常量：深色影院风，主色沿用桌面图标的紫。 */

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
  static readonly ACCENT: string = '#7C5CFF';
  static readonly ACCENT_SOFT: string = '#3A2E6B';
  static readonly DANGER: string = '#FF5A5A';
  static readonly GOLD: string = '#F2C14E';
  static readonly RADIUS: number = 12;
  static readonly PAGE_PAD: number = 16;
  static readonly POSTER_W: number = 116;
  static readonly POSTER_H: number = 164;
  static readonly HERO_H: number = 430;
}
