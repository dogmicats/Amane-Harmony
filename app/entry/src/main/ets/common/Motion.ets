import { curves, display } from '@kit.ArkUI';

/**
 * 统一动效物理参数与「一镜到底」封面交接通道（2.8.2 美化重构 · P1）。
 *
 * 1. 全站物理弹簧收口在一处，告别散落各处的线性/EaseOut 硬切；
 * 2. 封面进详情页一镜到底：卡片在点击瞬间把自身在屏幕上的真实矩形写进交接槽，
 *    DetailPage 首帧即从该精确坐标起跑，经 `SPRING_HERO` 物理弹簧与 `geometryTransition`
 *    顺滑展开落位到详情页封面，零黑屏、零中心弹窗跳变、且兼容全站全部 `router.pushUrl` 入口。
 */

export interface CoverRect {
  id: number;
  poster: string;
  x: number;
  y: number;
  w: number;
  h: number;
  radius: number;
  at: number;
}

export const HOME_BOOT_CACHE_KEY: string = 'amane:home:boot:v1';

let pendingCover: CoverRect | undefined = undefined;

export class Motion {
  /** 卡片 / 按钮轻按回弹。 */
  static springTap(): ICurve {
    return curves.interpolatingSpring(0, 1, 360, 32);
  }

  /** 抽屉 / 弹层 / 浮卡展开。 */
  static springSheet(): ICurve {
    return curves.interpolatingSpring(0, 1, 288, 30);
  }

  /** 封面一镜到底几何展开弹簧（顺滑轻盈、微阻尼落稳）。 */
  static springHero(): ICurve {
    return curves.interpolatingSpring(0, 1, 260, 28);
  }

  /** 底栏流光主线。 */
  static springFlow(): ICurve {
    return curves.interpolatingSpring(0, 1, 260, 30);
  }

  /** 底栏流光尾迹（质量略重，自然慢半拍）。 */
  static springTail(): ICurve {
    return curves.interpolatingSpring(0, 1.8, 190, 34);
  }

  /** 登记点击海报在屏幕上的真实坐标（vp），供 DetailPage 立刻接棒做一镜到底展开。 */
  static markCover(id: number, poster: string, x: number, y: number, w: number, h: number, radius: number = 12): void {
    if (id <= 0 || poster.length === 0 || w <= 10 || h <= 10) {
      return;
    }
    pendingCover = {
      id: id,
      poster: poster,
      x: x,
      y: y,
      w: w,
      h: h,
      radius: radius,
      at: Date.now()
    };
  }

  /** DetailPage 启动时取走交接坐标（1.5 秒内且 id 匹配才生效，一次性消费）。 */
  static takeCover(id: number): CoverRect | undefined {
    const cur: CoverRect | undefined = pendingCover;
    if (cur === undefined) {
      return undefined;
    }
    if (cur.id !== id || Date.now() - cur.at > 1500) {
      return undefined;
    }
    pendingCover = undefined;
    return cur;
  }

  /** 读取当前屏幕逻辑宽度（vp），用于计算 16:9 头图高度与目标封面落点。 */
  static screenWidthVp(): number {
    try {
      const w: number = px2vp(display.getDefaultDisplaySync().width);
      return w > 200 ? w : 390;
    } catch (e) {
      return 390;
    }
  }
}
