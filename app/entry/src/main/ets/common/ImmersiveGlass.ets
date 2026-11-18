import { uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from './Store';

/**
 * 顶栏的**系统沉浸材质**（2026-11-17 十七改：按官方 API 26 文档重写）。
 *
 * ── 一句话结论 ────────────────────────────────────────────────
 * 材质对象自己就包含 **背景色 / 边框颜色 / 边框宽度 / 阴影 / 材质层滤镜（materialFilter）**。
 * 官方文档 `@ohos.arkui.uiMaterial` 原文：
 *
 *   「在高算力和中算力设备上，通过材质层滤镜属性 materialFilter 和阴影 shadow 属性实现材质效果，
 *     当 systemMaterial 属性生效后，已设置的背景色属性 backgroundColor 会被恢复为透明色，
 *     已设置的边框宽度 borderWidth 属性会被恢复为无边框效果。
 *     在低算力设备上，通过背景色 backgroundColor、边框颜色 borderColor、边框宽度 borderWidth、
 *     阴影 shadow 属性实现材质效果。」
 *
 * 也就是说：**底色、边、影子、折射全是材质自己画的**。我们之前十几版一直在材质上再叠
 * tint / 高光 / 亮边 / 外投影（还想靠 `materialColor` 压深、靠 `colorInvert` 让颜色渗进来），
 * 那些层不是「帮忙」，而是**盖住了材质自己的结果** —— 屏幕上看就只剩一层半透明+模糊，
 * 这才是「怎么调都只是模糊 / 只是变暗」的真正原因。
 *
 * 现在这里只做三件事：
 *   1. 选档位（style）—— 官方建议悬浮控件用 ULTRA_THIN / THIN，常规区域用 REGULAR；
 *   2. 不设 materialColor（不设 = 不额外混纯色，材质滤镜原样呈现）；
 *   3. 不开 colorInvert —— 它的作用是「让子树里的文字/图标自动反色」，不是让背景色渗入，
 *      我们顶栏是白字压在深色玻璃上，开了只会在某些背景下把字变黑。
 *
 * ── 档位 ────────────────────────────────────────────────────
 *   弱   → REGULAR      （常规厚度，颜色只渗一点，最稳）
 *   强   → THIN         （薄，背景颜色明显透上来，默认）
 *   极限 → ULTRA_THIN   （超薄，最透，最接近「玻璃」而不是「磨砂」）
 *   无   → 不挂材质，退回 TopBar 里那层兜底底色
 *
 * 用户可以显式选，默认走设备算力自动阶梯（高算力 → 强，其余 → 弱）。
 */

/** 偏好键：用户选的档位。`auto` = 跟着设备算力走（默认）。 */
export const GLASS_KEY: string = 'topbar_glass';

/** AppStorage 键：**解析后**的档位（0 无 / 1 弱 / 2 强 / 3 极限），界面只读这个。 */
export const GLASS_STORAGE: string = 'amaneGlass';

/** 档位常量（数字和界面上的四档一一对应）。 */
export const GLASS_OFF: number = 0;
export const GLASS_LOW: number = 1;
export const GLASS_MID: number = 2;
export const GLASS_MAX: number = 3;

export class ImmersiveGlass {
  /** 这台设备能不能用系统沉浸材质（`isImmersiveMaterialSupported`）。 */
  static supported: boolean = false;
  /** 这台设备的算力档（Exquisite / Gentle / Smooth），用于自动阶梯与界面说明。 */
  static deviceLevel: uiMaterial.MaterialLevel = uiMaterial.MaterialLevel.SMOOTH;
  /** 探针是否已经跑过（`init` 只做一次，不要每次进页面都查系统）。 */
  private static probed: boolean = false;
  /** 按档位缓存材质对象：`ImmersiveMaterial` 带 GPU 资源，每种档位只造一次。 */
  private static cache: Map<string, uiMaterial.ImmersiveMaterial> = new Map<string, uiMaterial.ImmersiveMaterial>();
  /** 可交互材质缓存（键 = 档位|着色），见 `pressMaterial`。 */
  private static pressCache: Map<string, uiMaterial.ImmersiveMaterial> = new Map<string, uiMaterial.ImmersiveMaterial>();

  /** 启动时调一次（放在 `Personalize.init()` 后面，赶在第一次 build 之前）。 */
  static init(): void {
    ImmersiveGlass.probe();
    AppStorage.setOrCreate<number>(GLASS_STORAGE, ImmersiveGlass.resolved());
  }

  /** 查设备能力。异常一律当「不支持」，绝不能因为查能力把启动带崩。 */
  private static probe(): void {
    if (ImmersiveGlass.probed) {
      return;
    }
    ImmersiveGlass.probed = true;
    try {
      ImmersiveGlass.supported = uiMaterial.isImmersiveMaterialSupported();
      ImmersiveGlass.deviceLevel = uiMaterial.getGlobalMaterialLevel();
    } catch (error) {
      const err = error as BusinessError;
      ImmersiveGlass.supported = false;
      console.error(`[amane] material probe: ${err.code} ${err.message}`);
    }
  }

  /** 用户选的档位（`auto` / `none` / `weak` / `strong` / `ultra`）。 */
  static mode(): string {
    return Store.I.prefString(GLASS_KEY, 'auto');
  }

  /**
   * 自动阶梯：设备算力 → 档位。
   *
   * 高算力给「强（THIN）」：比 REGULAR 薄一档，背景颜色能明显透上来；
   * 想更透/更稳由用户自己选「极限」或「弱」。低算力设备上 style 参数本身不生效
   * （系统只用底色/描边/阴影），所以给哪一档都一样，统一给「弱」。
   */
  static autoLevel(): number {
    ImmersiveGlass.probe();
    if (!ImmersiveGlass.supported) {
      return GLASS_OFF;
    }
    if (ImmersiveGlass.deviceLevel === uiMaterial.MaterialLevel.EXQUISITE) {
      // 三十改：高算力默认给「极限（ULTRA_THIN）」。底栏就是用这一档出的真玻璃；
      // 顶栏给 THIN 时明显更重、更白，两条栏放一起不是一套语言。
      return GLASS_MAX;
    }
    return GLASS_LOW;
  }

  /** 当前生效档位：显式选择优先，否则走自动阶梯。 */
  static resolved(): number {
    const m: string = ImmersiveGlass.mode();
    if (m === 'none') {
      return GLASS_OFF;
    }
    if (m === 'weak') {
      return GLASS_LOW;
    }
    if (m === 'strong') {
      return GLASS_MID;
    }
    if (m === 'ultra') {
      return GLASS_MAX;
    }
    return ImmersiveGlass.autoLevel();
  }

  /** 用户改档位：落盘 + 刷新 AppStorage（所有挂了顶栏的页面立刻重绘）。 */
  static setMode(mode: string): void {
    Store.I.prefSetString(GLASS_KEY, mode);
    AppStorage.setOrCreate<number>(GLASS_STORAGE, ImmersiveGlass.resolved());
  }

  /** 档位名（界面用）。 */
  static modeLabel(mode: string): string {
    if (mode === 'none') {
      return '无（兜底底色）';
    }
    if (mode === 'weak') {
      return '弱';
    }
    if (mode === 'strong') {
      return '强';
    }
    if (mode === 'ultra') {
      return '极限';
    }
    return `自动（${ImmersiveGlass.levelLabel(ImmersiveGlass.autoLevel())}）`;
  }

  /** 档位名（界面用）。 */
  static levelLabel(level: number): string {
    if (level <= GLASS_OFF) {
      return '无';
    }
    if (level === GLASS_LOW) {
      return '弱';
    }
    if (level === GLASS_MID) {
      return '强';
    }
    return '极限';
  }

  /** 设备算力的一句话说法，用在设置页小字里。 */
  static deviceLabel(): string {
    ImmersiveGlass.probe();
    if (!ImmersiveGlass.supported) {
      return `这台设备不支持系统沉浸材质，顶栏用兜底底色（${ImmersiveGlass.appStateLabel()}）`;
    }
    if (ImmersiveGlass.deviceLevel === uiMaterial.MaterialLevel.EXQUISITE) {
      return `高算力设备：材质滤镜 + 阴影完整生效 · ${ImmersiveGlass.appStateLabel()}`;
    }
    if (ImmersiveGlass.deviceLevel === uiMaterial.MaterialLevel.GENTLE) {
      return `中算力设备：材质滤镜生效，效果略简 · ${ImmersiveGlass.appStateLabel()}`;
    }
    return `低算力设备：系统只用底色/描边/阴影，没有滤镜与折射 · ${ImmersiveGlass.appStateLabel()}`;
  }

  /**
   * 应用级材质开关状态（`module.json5` 的 `ohos.arkui.UIMaterial.state`）。
   *
   * 组件级 `systemMaterial` 在 DEFAULT / ENABLE 下都能生效，只有 DISABLE 会全局禁掉；
   * 这里如实显示，方便现场判断「为什么这层玻璃没出来」。
   */
  static appStateLabel(): string {
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      if (info.state === uiMaterial.MaterialState.DISABLE) {
        return '应用级已禁用';
      }
      if (info.state === uiMaterial.MaterialState.ENABLE) {
        return '应用级已开启';
      }
      return '应用级默认';
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] material info: ${err.code} ${err.message}`);
      return '材质状态未知';
    }
  }

  /**
   * 取某一档的材质对象；`0` 或不支持时返回 `undefined`
   * （`systemMaterial(undefined)` = 不挂材质，正好当兜底的开关）。
   *
   * 参数只给 `style` 与 `applyShadow`：
   * - `materialColor` 不设 —— 不额外混纯色，材质滤镜原样呈现（设了纯色会挡住滤镜）；
   * - `colorInvert` 不设 —— 它是「子树文字/图标自动反色」，不是颜色渗入；
   * - `interactive` 关掉 —— 顶栏是常驻控件，按下整条形变看着像故障；
   * - `lightEffect` 不设 —— 光感是按压反馈，静态顶栏用不上。
   */
  static materialFor(level: number, tint: string = ''): uiMaterial.ImmersiveMaterial | undefined {
    ImmersiveGlass.probe();
    if (level <= GLASS_OFF || !ImmersiveGlass.supported) {
      return undefined;
    }
    // 四十一改：加了 `tint`（着色）参数。为什么需要它：
    // 顶栏那四块永远压在**内容**上，材质不设色就够（内容自己会给颜色）；
    // 但内容区里的胶囊（工具条按钮、分段条）背景可能是**纯黑** ——
    // 材质在纯黑上什么都不画，胶囊的轮廓就直接消失（真机看过：一排按钮变成裸文字）。
    // 所以那类场景传一个很淡的白（`#1FFFFFFF`，12%）：在纯黑上给出轮廓，
    // 压在亮内容上又不至于变成一块奶白。
    const key: string = `${level}|${tint}`;
    const hit: uiMaterial.ImmersiveMaterial | undefined = ImmersiveGlass.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const made: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
        style: ImmersiveGlass.styleFor(level),
        // 二十八改（底栏真机验证过的那一条）：`materialColor` 必须**全透明**。
        //
        // 官方注释原文：「材质层的着色。纯色必须有一定透明度，不能完全不透明，
        // 否则会**完全阻挡材质滤镜效果**。」
        //
        // 底栏那版之前传的是 24% 的黑，屏幕上立刻退化成「一层会变暗的磨砂玻璃」；
        // 改成 Transparent 之后，同一台机器、同一档算力，颜色一下就渗上来了。
        // 顶栏这里同理：任何纯色都是在材质滤镜上再盖一层墨。
        materialColor: tint.length > 0 ? tint : Color.Transparent,
        // 材质自带阴影（官方默认 true）。我们不再叠 `shadow` —— 两个影子会发脏
        applyShadow: true,
        interactive: false
      });
      ImmersiveGlass.cache.set(key, made);
      return made;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] material build: ${err.code} ${err.message}`);
      return undefined;
    }
  }

  /**
   * **可交互控件**用的材质（2026-11-17 三十一改：导入官方「沉浸式空间动效」）。
   *
   * 官方示例 `Spatialization` 的 `MaterialUtil.getMaterialModifier()` 给按钮/胶囊用的就是这一组：
   *
   *     new uiMaterial.ImmersiveMaterial({
   *       style: ULTRA_THIN,
   *       interactive: true,          // ← 形变：按下时整块按出弹性回弹
   *       lightEffect: { color: undefined },  // ← 边缘流光 / 点光源：按下点起一圈光晕
   *       materialColor: <半透明色>    // ← 官方也用着色，传的是 sys.color.comp_background_tertiary
   *     })
   *
   * 与顶栏那条「静态玻璃」（`materialFor`）的区别只有**一点**：`interactive` 打开。
   *
   * **默认不设 `materialColor`**（2026-11-17 三十二改）。三十一改给这些按钮传过 20% 黑，
   * 真机上立刻变成「三块深灰小方砖」—— 用户原话「深色薄底的效果不好，去掉」。
   * 着色一旦上去，材质滤镜和背后的海报就都被盖住了；玻璃要透，就只能不给色。
   * 可读性交回给文字自己（Medium 字重 + 投影），不再靠在背后垫一块暗色。
   *
   * `tint` 只留给**「开着」的状态**（排序/筛选/抽卡选中时那层淡主题色）：
   * 材质生效后系统会把 `backgroundColor` 复位成透明，靠背景色表达选中态在这条路上是无效的，
   * 只能走材质自己的着色。
   */
  static pressMaterial(level: number, tint?: string): uiMaterial.ImmersiveMaterial | undefined {
    ImmersiveGlass.probe();
    if (level <= GLASS_OFF || !ImmersiveGlass.supported) {
      return undefined;
    }
    const key: string = `press|${level}|${tint === undefined ? '-' : tint}`;
    const hit: uiMaterial.ImmersiveMaterial | undefined = ImmersiveGlass.pressCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const made: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        materialColor: tint === undefined ? Color.Transparent : tint,
        // 形变 + 流光：这两个才是「空间动效」本体，不是我们自己动的动画
        interactive: true,
        lightEffect: { color: undefined },
        // 小胶囊不要大投影：一条顶栏里叠三个影子会发脏
        applyShadow: false
      });
      ImmersiveGlass.pressCache.set(key, made);
      return made;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`[amane] press material: ${err.code} ${err.message}`);
      return undefined;
    }
  }

  /**
   * 是否**必须由我们自己铺底色 + 描边**（2026-11-17 十八改）。
   *
   * 官方对 `systemMaterial` 的实际分工说得很细：
   *
   *   高算力 / 中算力：材质生效后，已设置的 `backgroundColor` 被恢复为**透明**、
   *                     `borderWidth` 被恢复为**无边框**，效果完全由 materialFilter + shadow 画出来。
   *   低算力：         `style` 参数不生效，系统**就是用** backgroundColor / borderColor /
   *                     borderWidth / shadow 来实现材质效果。
   *   设备不支持：     `materialFor()` 返回 undefined，什么都不会画。
   *
   * 所以「要不要自己铺底」完全取决于档位，不能一刀切：
   *   - 高中算力：不铺（铺了也是被重置，多此一举，而且官方明确「不建议与 systemMaterial 同时使用」）；
   *   - 低算力 / 不支持：必须铺，否则整条顶栏**一个像素都不画**（十七改真机截图里
   *     「一层什么都没画的透明片」就是这么来的 —— 当时无条件把它设成了透明）。
   */
  static needOwnFill(): boolean {
    ImmersiveGlass.probe();
    if (!ImmersiveGlass.supported) {
      return true;
    }
    return ImmersiveGlass.deviceLevel === uiMaterial.MaterialLevel.SMOOTH;
  }

  /**
   * 档位 → 材质样式（官方建议：悬浮控件用 ULTRA_THIN / THIN，常规区域用 REGULAR）。
   * 越往上越透：玻璃感来自「薄」，越厚越像毛玻璃贴膜。
   */
  static styleFor(level: number): uiMaterial.ImmersiveStyle {
    if (level >= GLASS_MAX) {
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
    if (level === GLASS_MID) {
      return uiMaterial.ImmersiveStyle.THIN;
    }
    return uiMaterial.ImmersiveStyle.REGULAR;
  }
}
