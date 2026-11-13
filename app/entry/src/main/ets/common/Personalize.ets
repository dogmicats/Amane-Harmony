/**
 * 个性化偏好（本地）：主题色 / 海报列数 / 首页各行的显隐与顺序。
 *
 * 三条约定：
 * 1. **只存本地**（`Store` 的 `prefString` 那套），不建服务端配置、不加端点；
 * 2. 列数用 **AppStorage** 中转：`@StorageProp('amaneCols')` 给海报网格（10 个页面），
 *    `@StorageProp('amaneStillCols')` 给剧照瀑布流（`view/StillsWall`，抽卡 / 盲盒 / 详情页共用）。
 *    双指捏合改的是同一个值，设置页改的也是它；
 * 3. 主题色改的是 `Theme.ACCENT` 这类静态字段，**不会自己触发重绘** ——
 *    `Theme.ets` 里所有颜色都是在 `build()` 时静态读走的，子组件不会因为静态字段变了就重建。
 *    所以这里把 `AppStorage['amaneThemeEpoch']` 加一，由 `Index.ets` 监听后整棵 Tab 树重建，
 *    保证「全局一次换干净」，不留一块没跟上的紫色。
 */
import { promptAction } from '@kit.ArkUI';
import { Store } from './Store';
import { Theme, DEFAULT_THEME_KEY } from './Theme';

/** 偏好键。 */
export const PREF_THEME: string = 'ui_theme_palette';
export const PREF_COLS: string = 'ui_poster_cols';
export const PREF_STILL_COLS: string = 'ui_still_cols';
export const PREF_HOME_ROWS: string = 'ui_home_rows';

/** AppStorage 键：列表页用 `@StorageProp` 订阅（装饰器只吃字面量，页面里直接写字符串）。 */
export const KEY_COLS: string = 'amaneCols';
export const KEY_STILL_COLS: string = 'amaneStillCols';
export const KEY_THEME_EPOCH: string = 'amaneThemeEpoch';

export const COLS_MIN: number = 2;
export const COLS_MAX: number = 4;
export const COLS_DEFAULT: number = 3;

/**
 * 瀑布流（剧照）列数：1–4，默认 2。
 *
 * 和海报列数**分开一套**：海报是 2:3 的固定卡，3 列正好；剧照横竖混排，
 * 单列是「满屏大图」的另一种看法，四列是缩略图联系表 —— 两组值的合理区间不一样，
 * 绑在一起会互相拖累（把海报调成 2 列的人，不一定想让剧照也变 2 列）。
 */
export const STILL_MIN: number = 1;
export const STILL_MAX: number = 4;
export const STILL_DEFAULT: number = 2;

/** 首页一行：键 + 是否显示。持久化格式 `key=1|key=0`，顺序就是渲染顺序。 */
export interface HomeRowPref {
  key: string;
  on: boolean;
}

export class Personalize {
  // ---------- 启动 ----------

  /** `Store.init()` 之后调用一次（`Index.aboutToAppear`）。 */
  static init(): void {
    Theme.applyPalette(Store.I.prefString(PREF_THEME, DEFAULT_THEME_KEY));
    const cols: number = Personalize.clampCols(Personalize.readColsPref());
    AppStorage.setOrCreate<number>(KEY_COLS, cols);
    const stills: number = Personalize.clampStills(Personalize.readStillsPref());
    AppStorage.setOrCreate<number>(KEY_STILL_COLS, stills);
    AppStorage.setOrCreate<number>(KEY_THEME_EPOCH, 0);
  }

  // ---------- 主题 ----------

  static themeKey(): string {
    return Theme.paletteKey;
  }

  /** 换主题：改色 → 存偏好 → 加一版 epoch 触发全局重建。 */
  static applyTheme(key: string): void {
    Theme.applyPalette(key);
    Store.I.prefSetString(PREF_THEME, Theme.paletteKey);
    const cur: number | undefined = AppStorage.get<number>(KEY_THEME_EPOCH);
    AppStorage.setOrCreate<number>(KEY_THEME_EPOCH, (cur === undefined ? 0 : cur) + 1);
  }

  // ---------- 海报列数 ----------

  static clampCols(n: number): number {
    if (n !== n) {
      return COLS_DEFAULT;
    }
    const v: number = Math.trunc(n);
    if (v < COLS_MIN) {
      return COLS_MIN;
    }
    if (v > COLS_MAX) {
      return COLS_MAX;
    }
    return v;
  }

  private static readColsPref(): number {
    const raw: string = Store.I.prefString(PREF_COLS, `${COLS_DEFAULT}`);
    return Personalize.clampCols(Number(raw));
  }

  /** 当前列数（页面里优先用 `@StorageProp`，这里给设置页和捏合逻辑用）。 */
  static cols(): number {
    const v: number | undefined = AppStorage.get<number>(KEY_COLS);
    return Personalize.clampCols(v === undefined ? COLS_DEFAULT : v);
  }

  /** 改列数：**设置页与捏合共用这一个入口**，两边永远一致。 */
  static setCols(n: number): void {
    const v: number = Personalize.clampCols(n);
    AppStorage.setOrCreate<number>(KEY_COLS, v);
    Store.I.prefSetString(PREF_COLS, `${v}`);
  }

  /**
   * 双指缩放一步：张开放大 = 海报变大 = 列数变少；捏合 = 列数变多。
   * 阈值取 ±15%，手指只是抖一下不会误切。切成功弹一句，免得不知道发生了什么。
   */
  static zoom(scale: number): void {
    const before: number = Personalize.cols();
    let want: number = before;
    if (scale >= 1.15) {
      want = before - 1;
    } else if (scale <= 0.87) {
      want = before + 1;
    }
    const next: number = Personalize.clampCols(want);
    if (next === before) {
      return;
    }
    Personalize.setCols(next);
    try {
      promptAction.showToast({ message: `海报 ${Personalize.colsName(next)}`, duration: 1200 });
    } catch (error) {
      console.info('[amane] pinch toast skipped');
    }
  }

  /** 列数 → `columnsTemplate` 字符串。ArkTS 里不用 `repeat`，直接给四个字面量最稳。 */
  static colsTemplate(n: number): string {
    if (n <= 2) {
      return '1fr 1fr';
    }
    if (n >= 4) {
      return '1fr 1fr 1fr 1fr';
    }
    return '1fr 1fr 1fr';
  }

  /** 每个列数配一句人话，设置页与捏合提示共用。 */
  static colsName(n: number): string {
    if (n <= 2) {
      return '两列（大图）';
    }
    if (n >= 4) {
      return '四列（密）';
    }
    return '三列（默认）';
  }

  // ---------- 瀑布流（剧照）列数 ----------

  static clampStills(n: number): number {
    if (n !== n) {
      return STILL_DEFAULT;
    }
    const v: number = Math.trunc(n);
    if (v < STILL_MIN) {
      return STILL_MIN;
    }
    if (v > STILL_MAX) {
      return STILL_MAX;
    }
    return v;
  }

  private static readStillsPref(): number {
    const raw: string = Store.I.prefString(PREF_STILL_COLS, `${STILL_DEFAULT}`);
    return Personalize.clampStills(Number(raw));
  }

  /** 当前瀑布流列数（`StillsWall` 里用 `@StorageProp`，这里给设置页和捏合逻辑用）。 */
  static stills(): number {
    const v: number | undefined = AppStorage.get<number>(KEY_STILL_COLS);
    return Personalize.clampStills(v === undefined ? STILL_DEFAULT : v);
  }

  static setStills(n: number): void {
    const v: number = Personalize.clampStills(n);
    AppStorage.setOrCreate<number>(KEY_STILL_COLS, v);
    Store.I.prefSetString(PREF_STILL_COLS, `${v}`);
  }

  /**
   * 瀑布流上的双指缩放：张开 = 图更大 = 列更少，捏合 = 列更多。
   * 和海报那套是同一个手势语义，只是作用的偏好不同。
   */
  static zoomStills(scale: number): void {
    const before: number = Personalize.stills();
    let want: number = before;
    if (scale >= 1.15) {
      want = before - 1;
    } else if (scale <= 0.87) {
      want = before + 1;
    }
    const next: number = Personalize.clampStills(want);
    if (next === before) {
      return;
    }
    Personalize.setStills(next);
    try {
      promptAction.showToast({ message: `剧照 ${Personalize.stillsName(next)}`, duration: 1200 });
    } catch (error) {
      console.info('[amane] still pinch toast skipped');
    }
  }

  static stillsName(n: number): string {
    if (n <= 1) {
      return '单列（满屏）';
    }
    if (n >= 4) {
      return '四列（缩略）';
    }
    if (n >= 3) {
      return '三列（密）';
    }
    return '两列（默认）';
  }

  // ---------- 首页各行的显隐与顺序 ----------

  static loadRows(): HomeRowPref[] {
    const out: HomeRowPref[] = [];
    const raw: string = Store.I.prefString(PREF_HOME_ROWS, '');
    if (raw.length === 0) {
      return out;
    }
    const parts: string[] = raw.split('|');
    for (let i = 0; i < parts.length; i++) {
      const item: string = parts[i];
      const eq: number = item.lastIndexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = item.substring(0, eq);
      if (key.length === 0) {
        continue;
      }
      const pref: HomeRowPref = { key: key, on: item.substring(eq + 1) === '1' };
      out.push(pref);
    }
    return out;
  }

  static saveRows(rows: HomeRowPref[]): void {
    const parts: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      parts.push(`${rows[i].key}=${rows[i].on ? '1' : '0'}`);
    }
    Store.I.prefSetString(PREF_HOME_ROWS, parts.join('|'));
  }

  /**
   * 按用户的顺序挑出「这次真的要渲染」的键。
   *
   * `available` 是服务端这次真给了的键（顺序 = 服务端默认顺序）。
   * 偏好里没有的新键（例如新加了一个媒体库）追加在末尾并默认打开 ——
   * 否则用户会以为「新库怎么不见了」。
   */
  static orderKeys(available: string[]): string[] {
    const saved: HomeRowPref[] = Personalize.loadRows();
    const seen: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < saved.length; i++) {
      seen.set(saved[i].key, saved[i].on);
    }
    const out: string[] = [];
    for (let i = 0; i < saved.length; i++) {
      const key: string = saved[i].key;
      if (!saved[i].on) {
        continue;
      }
      if (available.indexOf(key) < 0) {
        continue;
      }
      out.push(key);
    }
    for (let i = 0; i < available.length; i++) {
      const key: string = available[i];
      if (seen.has(key)) {
        continue;
      }
      out.push(key);
    }
    return out;
  }
}
