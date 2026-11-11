import { router } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';

/**
 * 设置（一级页）：只做分区导航，不放具体设置项。
 *
 * 布局照 hosplayer 的思路：先把整页切成几大块，二级入口按语义归到各块里。
 *   通用   —— 连接（地址 / Token / 测试重连）
 *   播放器 —— 播放器设置
 *   其他   —— 列表页（抽卡）、我的评价
 *   高级   —— 数据与入库（self 专属）
 *   关于   —— 关于、更新日志
 *
 * 新增设置先想清楚落在哪块；块内再拆二级页，别把一堆控件平铺回来。
 */
interface NavRow {
  key: string;
  label: string;
  desc: string;
  url: string;
  selfOnly: boolean;
  needOk?: boolean;
}

interface NavGroup {
  key: string;
  title: string;
  rows: NavRow[];
}

const GROUPS: NavGroup[] = [
  {
    key: 'general', title: '通用', rows: [
      { key: 'conn', label: '连接', desc: '局域网 / 外网地址、API Token、测试与重连', url: 'pages/SettingsConnectionPage', selfOnly: false }
    ]
  },
  {
    key: 'player', title: '播放器', rows: [
      { key: 'player', label: '播放器设置', desc: '解码、渲染、字幕等播放参数', url: 'pages/PlayerSettingsPage', selfOnly: false }
    ]
  },
  {
    key: 'other', title: '其他', rows: [
      { key: 'list', label: '列表页', desc: '抽卡模式：每轮张数与默认开关', url: 'pages/SettingsListPage', selfOnly: false },
      { key: 'collections', label: '我的清单', desc: '收藏清单：新建、改名、删除', url: 'pages/CollectionsPage', selfOnly: false },
      { key: 'picks', label: '我的截帧', desc: '我截的关键帧：看、跳、删、存到手机', url: 'pages/FramePicksPage', selfOnly: false }
    ]
  },
  {
    key: 'advanced', title: '高级', rows: [
      { key: 'preview', label: '进度条预览', desc: '闲时预生成开关、占用上限与清理', url: 'pages/PreviewSettingsPage', selfOnly: false }
    ]
  },
  {
    key: 'about', title: '关于', rows: [
      { key: 'about', label: '关于 Amane', desc: '版本、许可与项目信息', url: 'pages/AboutPage', selfOnly: false },
      { key: 'changelog', label: '更新日志', desc: '每个版本改了什么', url: 'pages/ChangelogPage', selfOnly: false }
    ]
  }
];

@Entry
@Component
struct SettingsPage {
  private visible(row: NavRow): boolean {
    return true;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })

      Scroll() {
        Column({ space: 18 }) {
          ForEach(GROUPS, (g: NavGroup) => {
            Column({ space: 8 }) {
              Text(g.title)
                .fontSize(11)
                .fontColor(Theme.TEXT_FAINT)
                .letterSpacing(1)
                .width('100%')

              Column({ space: 1 }) {
                ForEach(g.rows, (r: NavRow) => {
                  if (this.visible(r)) {
                    Row({ space: 12 }) {
                      Column({ space: 3 }) {
                        Text(r.label)
                          .fontSize(15)
                          .fontColor(Theme.TEXT)
                        Text(r.desc)
                          .fontSize(11)
                          .fontColor(Theme.TEXT_FAINT)
                          .maxLines(2)
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Text('›')
                        .fontSize(20)
                        .fontColor(Theme.TEXT_FAINT)
                    }
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                    .onClick(() => {
                      router.pushUrl({ url: r.url });
                    })
                  }
                }, (r: NavRow) => `row-${r.key}`)
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .clip(true)
            }
            .width('100%')
          }, (g: NavGroup) => `g-${g.key}`)

          Text(`当前连接：${Store.I.onWan ? '外网' : '局域网'} · ${Store.I.amane}`)
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}