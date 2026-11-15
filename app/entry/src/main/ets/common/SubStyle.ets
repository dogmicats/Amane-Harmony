import { Store } from './Store';

/**
 * 字幕样式（2.6.1.55）：字号 / 描边 / 位置 / 背景，**播放中改完立刻生效**。
 *
 * 为什么走 mpv 属性、不自己画一层：
 * 字幕是 libass 在 mpv 里渲染的（`setSubtitleTrack` 挂上去的 vtt/srt）。自己再画一层
 * 会和内核那份重影、还要自己做时间轴同步，得不偿失。而 mpv 的 `sub-*` 全是
 * **运行时属性**，`setProperty` 之后下一帧就套用 —— 不重开流、不动 surface、
 * 不会打断播放（这点很关键：这个工程里任何重建 XComponent 的操作都会让 mpv 停）。
 *
 * 数值口径：
 * - `sub-font-size` 是「libass 单位」，默认 55；这里按百分比缩放，100 = 55。
 * - `sub-border-size` 是描边粗细（默认 3），0 = 不描边（同时关阴影，否则黑边还在）。
 * - `sub-pos` 是垂直位置百分比，100 = 原来贴底的位置，越大越靠上。
 * - 背景走 `sub-border-style=background-box` + `sub-back-color`(AARRGGBB)。
 */

export const PREF_SUB_SIZE: string = 'sub_size';
export const PREF_SUB_OUTLINE: string = 'sub_outline';
export const PREF_SUB_POS: string = 'sub_pos';
export const PREF_SUB_BG: string = 'sub_bg';

/**
 * 100% 对应的 libass 字号。
 *
 * 基准取自 MIMK-091 的中文硬字幕实测（2026-11-13 22:2x，1280×720 取帧量像素）：
 * 单字墨迹高 44px → 字号约 50（mpv 原厂默认是 55，所以「标准」比原来略小一号）。
 */
const BASE_FONT_SIZE: number = 50;

/**
 * 贴底时的下边距（`sub-margin-y`）。
 *
 * 同一部片的硬字幕是**压着画面底边**排的（取帧测得底部空隙 0px），
 * mpv 默认留 1 行左右，看着会比它高出一截。10 是「够安全又接近原片」的值。
 */
const BOTTOM_MARGIN: number = 10;

/** 面板/设置页共用的一组选项：v 是存进偏好与 mpv 的值，l 是按钮上的字。 */
export interface SubOpt {
  v: number;
  l: string;
}

export const SUB_SIZE_OPTS: SubOpt[] = [
  { v: 85, l: '小' }, { v: 100, l: '标准' }, { v: 125, l: '大' }, { v: 150, l: '特大' }
];
export const SUB_OUTLINE_OPTS: SubOpt[] = [
  { v: 0, l: '无' }, { v: 2, l: '细' }, { v: 3, l: '标准' }, { v: 5, l: '粗' }
];
/** mpv 的 `sub-pos`：100 是原来贴底的位置，越大越靠上。 */
export const SUB_POS_OPTS: SubOpt[] = [
  { v: 100, l: '贴底' }, { v: 88, l: '略高' }, { v: 55, l: '中间' }, { v: 15, l: '顶部' }
];
export const SUB_BG_OPTS: SubOpt[] = [{ v: 0, l: '无' }, { v: 1, l: '半透明' }, { v: 2, l: '实底' }];

export class SubStyle {
  /** 字号百分比：70 / 85 / 100 / 125 / 150 / 180，越界夹回。 */
  static size(): number {
    const raw: number = Number(Store.I.prefString(PREF_SUB_SIZE, '100'));
    if (!Number.isFinite(raw)) {
      return 100;
    }
    return Math.min(180, Math.max(70, Math.round(raw)));
  }

  static setSize(v: number): void {
    Store.I.prefSetString(PREF_SUB_SIZE, `${Math.min(180, Math.max(70, Math.round(v)))}`);
  }

  /** 描边粗细：0（关）/ 2（细）/ 3（标准）/ 5（粗）。 */
  static outline(): number {
    const raw: number = Number(Store.I.prefString(PREF_SUB_OUTLINE, '3'));
    if (!Number.isFinite(raw)) {
      return 3;
    }
    return Math.min(6, Math.max(0, Math.round(raw)));
  }

  static setOutline(v: number): void {
    Store.I.prefSetString(PREF_SUB_OUTLINE, `${Math.min(6, Math.max(0, Math.round(v)))}`);
  }

  /** 垂直位置：100 = 贴底（mpv 默认），越小越靠下、越大越靠上。 */
  static pos(): number {
    const raw: number = Number(Store.I.prefString(PREF_SUB_POS, '100'));
    if (!Number.isFinite(raw)) {
      return 100;
    }
    return Math.min(100, Math.max(8, Math.round(raw)));
  }

  static setPos(v: number): void {
    Store.I.prefSetString(PREF_SUB_POS, `${Math.min(100, Math.max(8, Math.round(v)))}`);
  }

  /** 背景：0 关 / 1 半透明底 / 2 实底。 */
  static bg(): number {
    const raw: number = Number(Store.I.prefString(PREF_SUB_BG, '0'));
    if (!Number.isFinite(raw)) {
      return 0;
    }
    return Math.min(2, Math.max(0, Math.round(raw)));
  }

  static setBg(v: number): void {
    Store.I.prefSetString(PREF_SUB_BG, `${Math.min(2, Math.max(0, Math.round(v)))}`);
  }

  /**
   * 当前样式换算成「要写进 mpv 的属性值」。
   *
   * 为什么不在这里直接 `setProperty`：`MpvLib` 这个类型从 har 里 import 成值以后，
   * hvigor 会去找 `@mpv-ohos/mpv-arkts` 的入口文件（包里只有 `Index.d.ets`，没有
   * `Index.ets`），直接报 `Failed to find entry file`。写属性的动作放在 PlayerView
   * （那里 `player.native` 本来就有类型）最稳。
   */
  static spec(): SubStyleSpec {
    const outline: number = SubStyle.outline();
    const bg: number = SubStyle.bg();
    const spec: SubStyleSpec = {
      fontSize: Math.round(BASE_FONT_SIZE * SubStyle.size() / 100),
      pos: SubStyle.pos(),
      // 贴底时把下边距收到 10：MIMK-091 那套硬字幕是压着底边排的
      marginY: BOTTOM_MARGIN,
      outline: outline,
      // 不描边时阴影也要关：mpv 的 outline-and-shadow 即使 border=0 也留一层模糊阴影
      shadow: outline > 0 ? 2 : 0,
      borderStyle: bg === 0 ? 'outline-and-shadow' : 'background-box',
      backColor: bg === 0 ? '#00000000' : (bg === 2 ? '#E6000000' : '#8C000000')
    };
    return spec;
  }
}

/** 要写进 mpv 的一组字幕属性值（见 `SubStyle.spec()`）。 */
export interface SubStyleSpec {
  fontSize: number;
  pos: number;
  /** 贴底时的下边距（`sub-margin-y`），对齐原片「压着底边」的排法。 */
  marginY: number;
  outline: number;
  shadow: number;
  borderStyle: string;
  backColor: string;
}
