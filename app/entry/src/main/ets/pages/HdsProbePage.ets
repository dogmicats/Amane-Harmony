import { router, uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, HdsNavigation, HdsNavDestination, ScrollEffectType } from '@kit.UIDesignKit';
import { Theme } from '../common/Theme';

/**
 * HDS 沉浸光感评估页（2026-11-17，**临时页**）。
 *
 * 目的只有一个：回答「要不要把导航骨架升级成 HDS」这个问题，用真实设备给结论。
 * 它不改动任何现有页面，从「设置 → 维护与排障 → HDS 评估」进入。
 *
 * 页面上给三组证据：
 *   1. 设备能力：`canIUse` + `hdsMaterial.getSystemMaterialTypes()` + 旧 API 的
 *      `uiMaterial.isImmersiveMaterialSupported()`，三者对照；
 *   2. 真实标题栏：`HdsNavigation` / `HdsNavDestination` + `systemMaterialEffect` +
 *      `GRADIENT_BLUR`，滚动时看「从透明渐变到模糊」和边缘光晕；
 *   3. 一屏可滚动的色块：故意用高对比色，方便看清模糊与光晕的边界。
 */
@Entry
@Component
struct HdsProbePage {
  private stack: NavPathStack = new NavPathStack();
  /** Tab 内嵌套实验用的独立栈（和第二块区域分开，避免互相干扰）。 */
  private innerStack: NavPathStack = new NavPathStack();
  /** 能力检测结果（多行文本）。 */
  @State caps: string = '检测中…';
  @State err: string = '';

  aboutToAppear(): void {
    this.caps = this.probe();
  }

  /** 枚举转人话，日志和界面都能看懂。 */
  private mtName(t: hdsMaterial.MaterialType): string {
    if (t === hdsMaterial.MaterialType.NONE) {
      return 'NONE';
    }
    if (t === hdsMaterial.MaterialType.ADAPTIVE) {
      return 'ADAPTIVE';
    }
    if (t === hdsMaterial.MaterialType.IMMERSIVE) {
      return 'IMMERSIVE';
    }
    return `${t}`;
  }

  private probe(): string {
    const lines: string[] = [];
    try {
      lines.push(`HDS syscap 可用: ${canIUse('SystemCapability.UIDesign.HDSComponent.Core')}`);
    } catch (e) {
      lines.push('HDS syscap 检测失败');
    }
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      const names: string[] = [];
      for (let i = 0; i < types.length; i++) {
        names.push(this.mtName(types[i]));
      }
      lines.push(`getSystemMaterialTypes: [${names.join(', ')}]`);
    } catch (e) {
      lines.push('getSystemMaterialTypes 抛错（系统可能不支持 HDS 材质）');
    }
    try {
      lines.push(`uiMaterial.isImmersiveMaterialSupported: ${uiMaterial.isImmersiveMaterialSupported()}`);
    } catch (e) {
      lines.push('uiMaterial.isImmersiveMaterialSupported 不可用');
    }
    console.info(`[amane] hds probe: ${lines.join(' | ')}`);
    return lines.join('\n');
  }

  @Builder
  ColorBand(i: number) {
    Row({ space: 10 }) {
      Text(`${i}`)
        .fontSize(13)
        .fontColor('#111111')
        .width(28)
        .textAlign(TextAlign.Center)
      Text('这块用来观察标题栏的模糊与光晕边界')
        .fontSize(12)
        .fontColor('#111111')
      Blank()
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 12 })
    .borderRadius(10)
    // 高饱和色块：模糊/折射/光晕在这上面最容易看出来
    .backgroundColor(i % 2 === 0 ? '#FFD166' : '#06D6A0')
  }

  build() {
    // HdsNavigation 是 HDS 的导航容器；里面放一个 HdsNavDestination 才会渲染标题栏
    HdsNavigation(this.stack) {
      HdsNavDestination() {
        Scroll() {
          Column({ space: 12 }) {
            Text('设备能力检测')
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
            Text(this.caps)
              .fontSize(12)
              .fontColor(Theme.TEXT)
              .width('100%')
              .padding(12)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .backgroundColor('#1FFFFFFF')
              .border({ width: 0.5, color: '#33FFFFFF' })
              .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
              .borderRadius(12)

            Text('Tab 内嵌套测试（决定媒体库能不能用）')
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
              .margin({ top: 10 })
            Text('媒体库是 TabContent 里的内容，不是独立页面。上次我用普通 Navigation 这样套，' +
              '整页黑屏。下面这块是"Tabs 里再放 HdsNavigation + HdsNavDestination"，' +
              '如果它能正常显示并带材质，媒体库就能只包一层解决，不用换整个导航骨架。')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')

            // ↓ 关键实验：Tabs 的 TabContent 里嵌 HDS 导航
            Tabs({ barPosition: BarPosition.Start }) {
              TabContent() {
                HdsNavigation(this.innerStack) {
                  HdsNavDestination() {
                    Scroll() {
                      Column({ space: 8 }) {
                        ForEach([0, 1, 2, 3, 4, 5], (i: number) => {
                          Row() {
                            Text(`内嵌页 ${i}`)
                              .fontSize(12)
                              .fontColor('#111111')
                          }
                          .width('100%')
                          .height(48)
                          .padding({ left: 12 })
                          .borderRadius(8)
                          .backgroundColor(i % 2 === 0 ? '#FFD166' : '#06D6A0')
                        }, (i: number) => `inner-${i}`)
                      }
                      .width('100%')
                      .padding(10)
                    }
                    .width('100%')
                    .height('100%')
                  }
                  .titleBar({
                    style: {
                      scrollEffectOpts: {
                        enableScrollEffect: true,
                        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
                      },
                      systemMaterialEffect: {
                        materialType: hdsMaterial.MaterialType.IMMERSIVE,
                        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
                      }
                    },
                    content: { title: { mainTitle: '内嵌标题栏' } }
                  })
                }
                .mode(NavigationMode.Stack)
                .width('100%')
                .height('100%')
              }
              .tabBar('内嵌 A')

              TabContent() {
                Text('对照组：普通内容（这里应该零变化，用来确认黑屏是"嵌套"造成还是别的原因）')
                  .fontSize(12)
                  .fontColor(Theme.TEXT_DIM)
                  .padding(16)
              }
              .tabBar('对照 B')
            }
            .barHeight(40)
            .height(320)
            .width('100%')
            .backgroundColor('#1A1A1F')
            .borderRadius(12)

            Text('标题栏观察区')
              .fontSize(13)
              .fontColor(Theme.TEXT_DIM)
              .width('100%')
              .margin({ top: 6 })
            Text('往上滚：标题栏应从半透明渐变到模糊；看边缘有没有被"灯照亮"的光晕；' +
              '再对比底部 Tab 栏（系统材质）的观感是否一致。')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')

            ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], (i: number) => {
              this.ColorBand(i);
            }, (i: number) => `band-${i}`)

            Text('返回')
              .fontSize(13)
              .fontColor(Theme.ACCENT)
              .padding({ left: 18, right: 18, top: 10, bottom: 10 })
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .backgroundColor('#1FFFFFFF')
              .border({ width: 0.5, color: '#33FFFFFF' })
              .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })
              .borderRadius(14)
              .margin({ top: 10, bottom: 40 })
              .onClick(() => {
                router.back();
              })
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .titleBar({
        style: {
          // 滚动时标题栏从"半透明"渐变到"模糊"
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.GRADIENT_BLUR
          },
          // 沉浸光感材质：文档建议 ADAPTIVE（系统按设备算力自动选档）
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: 'HDS 沉浸光感评估',
            subTitle: '标题栏材质 · 渐变模糊 · 光晕'
          }
        }
      })
    }
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}