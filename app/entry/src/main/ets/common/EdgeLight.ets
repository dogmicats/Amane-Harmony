import { Theme } from './Theme';

/**
 * **边缘光**（Edge Light）—— 顶栏胶囊与底栏高亮共用的同一种轮廓语言。
 *
 * ── 为什么要有它（2026-11-17 三十四改）──────────────────────────
 * 用户原话：
 *   「顶部胶囊和底部的高亮不统一，而且都不好看。看能不能改成边缘光效？
 *     外圈高光然后逐步淡化到内部无光。」
 *
 * 之前两边是两套做法，所以怎么看都不像一家人：
 *   · 顶栏胶囊：系统材质的底色糊满整块 → 一团均匀的奶白，没有边界；
 *   · 底栏高亮：`accentAlpha(0.18)` 实心填充 + 一圈描边 → 一块紫色色块。
 * 一个「满」，一个「块」，共同点是——**光都在内部**。
 *
 * ── 怎么做（不靠贴图、不靠 blur）────────────────────────────
 * 真的「边缘亮、往里淡出、中心零」需要一个沿轮廓衰减的渐变。ArkUI 的
 * `linearGradient` / `radialGradient` 都按**矩形**铺，胶囊一长，圆角和长边
 * 衰减速度就不一样，画出来是两头亮中间暗，反而更脏。
 *
 * 所以这里用**三层叠出来**，任何尺寸都成立：
 *   ① 上沿柔光：竖直渐变，顶边 18% 白 → 46% 处归零。光从上方来，很薄一层；
 *   ② 内衬光：一条 **4vp 宽的 border**，只有 8% 白 —— 紧贴轮廓的一圈微光，
 *      因为它自己就是「描边」，天然跟着圆角走，宽度恒定；
 *   ③ 头发丝边：1vp、30% 白 —— 把轮廓钉住，没有它渐变会散掉。
 *
 * 三层全部往内衰减、中心一个像素都不画 → 就是「外圈高光，内部无光」。
 * 换色只需要换 `tint`：顶栏给白、底栏给主题色，形状语言完全一致。
 */
@Component
export struct EdgeLight {
  /** 圆角。必须和宿主胶囊的 `borderRadius` 一致，否则轮廓会错位。 */
  @Prop radius: number = 23;
  /** 光的颜色：顶栏 `#FFFFFF`，底栏 `Theme.ACCENT`。 */
  @Prop tint: string = '#FFFFFF';
  /** 总强度（0~1+）。同一套形状要压暗就调这一个，不用逐个改三层的透明。 */
  @Prop level: number = 1;
  /** 上沿柔光的强度。 */
  @Prop sheen: number = 0.18;
  /** 头发丝边的强度。 */
  @Prop ring: number = 0.30;
  /** 内衬光（4vp 那条宽边）的强度。 */
  @Prop bloom: number = 0.08;
  /** 内衬光的宽度（vp）。小胶囊别给太大，30 高的东西给 4 就占掉一圈了。 */
  @Prop bloomW: number = 4;

  build() {
    Stack() {
      // ① 上沿柔光：光照在玻璃上边缘，往下就没了
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .linearGradient({
          angle: 180,
          colors: [
            [Theme.alphaOf(this.tint, this.sheen * this.level), 0],
            [Theme.alphaOf(this.tint, this.sheen * 0.32 * this.level), 0.16],
            [Theme.alphaOf(this.tint, 0), 0.46],
            [Theme.alphaOf(this.tint, 0), 1]
          ]
        })

      // ② 内衬光：一条贴着轮廓的宽边，往里就散掉了
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .border({ width: this.bloomW, color: Theme.alphaOf(this.tint, this.bloom * this.level) })

      // ③ 贴着亮边内侧的一道**暗线**。
      //
      // 只画白边有个硬伤：海报一亮，白边就消失在白里了（真机截图里「排序」那几颗
      // 在亮海报上几乎看不出轮廓）。真玻璃的断面永远是「外面一道亮边 + 紧贴它一道暗线」，
      // 明暗差才是边界。做法：先铺一层 2vp 的暗边，再用 1vp 的亮边盖住最外面 1vp，
      // 剩下那 1vp 暗线就紧贴在里面 —— 亮底暗底都读得出轮廓。
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .border({ width: 2, color: Theme.alphaOf('#000000', 0.20 * this.level) })

      // ④ 头发丝边：轮廓本身
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .border({ width: 1, color: Theme.alphaOf(this.tint, this.ring * this.level) })
    }
    .width('100%')
    .height('100%')
    // 边缘光只是装饰：绝不能挡住底下胶囊的点击 / 长按
    .hitTestBehavior(HitTestMode.None)
  }
}
