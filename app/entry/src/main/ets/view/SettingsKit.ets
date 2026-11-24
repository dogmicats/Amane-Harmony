import { Theme } from '../common/Theme';

/**
 * 「我的」与「设置」全线共用视觉组件（2.8.2 重构）。
 *
 * 统一规范：
 *  - 顶部主题微光（SettingsAmbientGlow）：随 8 套主题自动变色，不拦点击；
 *  - 36×36 丝绒半透图标底座（SettingsIconTile）：统一替代裸文字与实心色块；
 *  - 丝绒半透选态胶囊（VelvetChip）：替代全站二级页里的旧刺眼实心 Theme.ACCENT 块；
 *  - 缩进细分割线 & 原生右箭头：消灭裸字符 `›` 与透底黑缝。
 */

/** 顶部柔和主题氛围光晕：挂在页面 Stack 底层，不拦截任何手势。 */
@Component
export struct SettingsAmbientGlow {
  @Prop accent: string = Theme.ACCENT;
  @Prop glowHeight: number = 220;

  build() {
    Column()
      .width('100%')
      .height(this.glowHeight)
      .hitTestBehavior(HitTestMode.None)
      .radialGradient({
        center: ['46%', '0%'],
        radius: '92%',
        colors: [
          [Theme.alphaOf(this.accent, 0.22), 0.0],
          [Theme.alphaOf(this.accent, 0.09), 0.46],
          ['#00000000', 1.0]
        ]
      })
  }
}

/** 统一 34/36px 半透玻璃图标底座。 */
@Component
export struct SettingsIconTile {
  icon: Resource = $r('sys.symbol.gearshape');
  @Prop tileSize: number = 36;
  @Prop iconSize: number = 17;
  @Prop accent: string = Theme.ACCENT;
  @Prop ink: string = Theme.ACCENT_INK;
  @Prop danger: boolean = false;

  build() {
    Stack() {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.danger ? Theme.DANGER : this.ink])
    }
    .width(this.tileSize)
    .height(this.tileSize)
    .borderRadius(11)
    .backgroundColor(this.danger ? Theme.alphaOf(Theme.DANGER, 0.14) : Theme.alphaOf(this.accent, 0.14))
    .border({
      width: 0.5,
      color: this.danger ? Theme.alphaOf(Theme.DANGER, 0.34) : Theme.alphaOf(this.ink, 0.28)
    })
  }
}

/** 分组小标题行（左标题 + 可选右侧主题高亮状态）。 */
@Component
export struct SettingsSectionTitle {
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop hintColor: string = Theme.ACCENT_INK;

  build() {
    Row() {
      Text(this.title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
      Blank()
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(10.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.hintColor)
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }
}

/** 带主题色竖条点缀的分组标题（用于空间管理、下载队列等模块）。 */
@Component
export struct SettingsBarSectionTitle {
  @Prop title: string = '';
  @Prop count: string = '';
  @Prop accent: string = Theme.ACCENT;

  build() {
    Row({ space: 8 }) {
      Row()
        .width(3)
        .height(13)
        .borderRadius(1.5)
        .linearGradient(Theme.ctaGradient())
      Text(this.title)
        .fontSize(13.5)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
      if (this.count.length > 0) {
        Text(this.count)
          .fontSize(12)
          .fontColor(Theme.TEXT_FAINT)
          .fontFeature('"tnum" 1')
      }
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 2, right: 2 })
  }
}

/** 卡片内行间细分割线（带图标行缩进 62，表单行缩进 14）。 */
@Component
export struct SettingsRowDivider {
  @Prop indent: number = 62;

  build() {
    Divider()
      .strokeWidth(0.5)
      .color('#12FFFFFF')
      .margin({ left: this.indent, right: 14 })
  }
}

/** 统一原生细右箭头，替代裸字符 `›`。 */
@Component
export struct SettingsChevron {
  @Prop glyphSize: number = 13;

  build() {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(this.glyphSize)
      .fontColor([Theme.TEXT_FAINT])
  }
}

/** 丝绒半透选态胶囊：用于全部二级设置页的单选/多选/档位切换。 */
@Component
export struct VelvetChip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  @Prop padH: number = 14;
  @Prop padV: number = 7;
  @Prop fs: number = 12;
  @Prop accent: string = Theme.ACCENT;
  @Prop ink: string = Theme.ACCENT_INK;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(this.fs)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.active ? this.ink : Theme.TEXT_DIM)
      .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
      .backgroundColor(this.active ? Theme.alphaOf(this.accent, 0.20) : Theme.CARD_HI)
      .border({
        width: this.active ? 0.75 : 0.5,
        color: this.active ? Theme.alphaOf(this.ink, 0.50) : '#14FFFFFF'
      })
      .borderRadius(Theme.R_PILL)
      .onClick(() => {
        this.onTap();
      })
  }
}
