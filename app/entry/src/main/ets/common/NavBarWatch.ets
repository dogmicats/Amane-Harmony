/**
 * 底部导航栏自动收起（2026-11-15，学 piliplus）。
 *
 * 用户要的：**往下看时底栏让位，往回看时底栏回来**。
 * 做法不复杂，难的是「别抖」——
 *   - 手指划过一点就收/放，会看到底栏一直在颤；
 *   - 所以按**方向累计位移**判断，不是每个滚动帧都判；
 *   - 收起要滑得远一点（`HIDE_AT`），回来要灵一点（`SHOW_AT` 更小）——
 *     人的直觉是「我一往回划就要看见它」。
 *
 * 状态放 `AppStorage`：底栏在 `Index` 的 Tabs 上，滚动发生在各个 Tab 里，
 * 中间隔着几层，用偏好或回调传递都比这一个键麻烦。
 */
const HIDE_AT: number = 26;   // 向下（内容往前）累计超过它就收起
const SHOW_AT: number = 10;   // 往回滑累计超过它就弹出（更灵敏）
/** Grid / List 只有索引回调：换一行按这个当量折算成位移。 */
const ROW_STEP: number = 40;

export class NavBarWatch {
  /** AppStorage 键：底栏是否收起。 */
  static readonly KEY: string = 'nav_bar_hidden';

  private static acc: number = 0;
  private static hidden: boolean = false;
  /** Grid / List 上一次看到的第一个可见行（-1 = 还没初始化）。 */
  private static lastIndex: number = -1;
  /** Scroll 上一次的滚动偏移（-1 = 还没初始化）。`onScroll` 给的是绝对偏移，不是增量。 */
  private static lastOff: number = -1;

  /** 复位成「显示」。切 tab、进负一屏、退出负一屏都该调它。 */
  static reset(): void {
    NavBarWatch.acc = 0;
    NavBarWatch.lastIndex = -1;
    NavBarWatch.lastOff = -1;
    NavBarWatch.write(false);
  }

  private static write(hidden: boolean): void {
    if (hidden === NavBarWatch.hidden) {
      return;
    }
    NavBarWatch.hidden = hidden;
    // 验收判据：真机 `hilog -x | grep 'nav bar'` 能看到向下收起 / 向上弹回各一次
    console.info(`[amane] nav bar hidden=${hidden}`);
    AppStorage.setOrCreate<boolean>(NavBarWatch.KEY, hidden);
  }

  /**
   * 喂**当前滚动偏移**（Scroll 的 `onScroll(xOffset, yOffset)` 给的是绝对偏移，不是增量 ——
   * 2026-11-15 真机踩过：当成增量用，只会一直往「收起」累计，往回划永远弹不回来）。
   * 这里自己差分：偏移变大 = 内容往前翻（往下看）→ 收起；变小 = 往回看 → 弹回。
   *
   * @param allowShow 允许「弹回」吗。触底弹簧的余震会让偏移往回走一点，
   *                  那不是用户在往回划；调用方可以在刚追加完的那几百毫秒里传 false，
   *                  只屏蔽「弹回」、不屏蔽「收起」（用户继续往下看照样能收）。
   */
  static onOffset(off: number, allowShow: boolean = true): void {
    if (off < 0) {
      return;
    }
    // 到顶：底栏必须看得见（2026-11-16 真机报「收起后滚到顶、或点『回到顶部』，
    // 底栏再也不回来，页面顶部点不到任何 tab」——收起时 barHeight=0，是真的点不到）。
    // 到顶后没有「往回滚」的位移可累计，靠 feed() 永远等不到 SHOW_AT。
    if (off <= 0) {
      NavBarWatch.acc = 0;
      NavBarWatch.lastOff = 0;
      NavBarWatch.write(false);
      return;
    }
    if (NavBarWatch.lastOff < 0) {
      NavBarWatch.lastOff = off;
      return;
    }
    const d: number = off - NavBarWatch.lastOff;
    NavBarWatch.lastOff = off;
    if (d < 0 && !allowShow) {
      // 只吞掉回程：累计值跟着归零，别让反弹抵掉下一次真实的「往回划」
      NavBarWatch.acc = 0;
      return;
    }
    NavBarWatch.feed(d);
  }

  /** 有符号位移：`dy > 0` = 往下看，`dy < 0` = 往回看。 */
  private static feed(dy: number): void {
    if (dy === 0) {
      return;
    }
    if (dy > 0) {
      NavBarWatch.acc = NavBarWatch.acc > 0 ? NavBarWatch.acc + dy : dy;
    } else {
      NavBarWatch.acc = NavBarWatch.acc < 0 ? NavBarWatch.acc + dy : dy;
    }
    if (!NavBarWatch.hidden && NavBarWatch.acc >= HIDE_AT) {
      NavBarWatch.write(true);
    } else if (NavBarWatch.hidden && NavBarWatch.acc <= -SHOW_AT) {
      NavBarWatch.write(false);
    }
  }

  /**
   * 用「第一个可见行的索引」喂方向（Grid / List 只有 index 回调，没有像素偏移）。
   *
   * 一步换行按 `ROW_STEP` 记，行高通常远大于它，所以「滑过一行」就能触发一次判断，
   * 手感上接近连续位移；同时避免每个滚动帧都写 AppStorage（那才是抖的根源）。
   */
  static onIndex(first: number): void {
    if (first < 0) {
      return;
    }
    // 回到第一行 = 到顶，同样必须把底栏放出来（Grid / List 走的是索引回调，没有像素偏移）。
    if (first === 0) {
      NavBarWatch.lastIndex = 0;
      NavBarWatch.acc = 0;
      NavBarWatch.write(false);
      return;
    }
    if (NavBarWatch.lastIndex < 0) {
      NavBarWatch.lastIndex = first;
      return;
    }
    const step: number = first - NavBarWatch.lastIndex;
    if (step === 0) {
      return;
    }
    NavBarWatch.lastIndex = first;
    NavBarWatch.feed(step > 0 ? ROW_STEP : -ROW_STEP);
  }
}
