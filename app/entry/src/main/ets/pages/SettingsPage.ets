import { router, promptAction } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';
import { AppLog } from '../common/AppLog';
import { common } from '@kit.AbilityKit';

/**
 * 设置（一级页）：只做分区导航，不放具体设置项。
 *
 * 2026-11-15 重排（依据 `docs/ai-context/queue/agent1-mine-ia-catalog.md`）：原来的
 * 通用 / 外观 / 播放 / 我的内容 / 高级 / 重置 六组，改成按「用户想干什么」分的五组：
 *
 *   连接与服务 —— 这台手机怎么连上服务器（地址、Token、投屏钥匙）
 *   外观与浏览 —— 看起来是什么样、列表怎么摆
 *   播放       —— 与看片直接相关：播放方式、刷一刷、进度条预览
 *   存储与数据 —— 占了多少、留多大、怎么清、怎么备份
 *   维护与排障 —— 后台队列与日志，平时用不到
 *
 * 同轮做的三件去重 / 归拢：
 *  1. 「我的清单」「我的截帧」从设置里删掉 —— 收藏页的「管理清单」和「我的」页已有入口，
 *     同一个东西两处入口，改一处忘一处就是下一个「点进去还是旧版」的 bug。
 *  2. 「检索别名」+「自建标签 / 系列」合成 `资料整理`，「数据与入库」+「还行管理」合成 `管理工具`，
 *     一级页变短，二级页各自保留原页面（行为零变化）。
 *  3. 「清空所有自定义修改」从「重置」组搬进 `资料整理` 页底部危险区 —— 它清的就是那一页管的改动。
 *
 * 「关于 Amane / 检查更新 / 更新日志」2.6.1.7 起不在设置里：三行在「我的 → 关于」（`pages/AboutHubPage`）。
 * 别往这里加回来。
 *
 * 组内顺序：常用的在上、排障/偏门在下。新增设置先想清楚落在哪块；块内再拆二级页。
 */
interface NavRow {
  key: string;
  label: string;
  desc: string;
  url: string;
  selfOnly: boolean;
  needOk?: boolean;
  /** 仅在开着投屏（偏好 enable_cast）时显示；目前默认关 —— 没有真机能验。 */
  needCast?: boolean;
  /** 仅在「入库」或「还行」至少有一个开着时显示（管理工具聚合页）。 */
  /** 动作行（url 为空）右侧的动词，如「导出」；有它就不画 ›。 */
  action?: string;
  /** 破坏性动作：标题用 DANGER 色，提醒「这一行不一样」。 */
  danger?: boolean;
}

interface NavGroup {
  key: string;
  title: string;
  rows: NavRow[];
}

const GROUPS: NavGroup[] = [
  {
    key: 'conn', title: '连接与服务', rows: [
      { key: 'conn', label: '服务器连接', desc: '局域网 / 外网地址、API Token、测试与重连', url: 'pages/SettingsConnectionPage', selfOnly: false },
      // 投屏（2.5.6）暂时隐藏：没有真机能验，先不对外开。
      // 要开：设置里把偏好 `enable_cast` 置 true（详情页的「投屏」按钮读同一个开关）
      { key: 'casttoken', label: '投屏令牌', desc: '投给电视时用的只读钥匙，12 小时过期，可随时吊销', url: 'pages/CastTokenPage', selfOnly: false, needCast: true }
    ]
  },
  {
    key: 'look', title: '外观与浏览', rows: [
      { key: 'appearance', label: '外观与布局', desc: '8 套主题色、海报列数、剧照瀑布流列数；光效强度与触感反馈也在这里', url: 'pages/SettingsAppearancePage', selfOnly: false },
      { key: 'home', label: '首页内容', desc: '哪几行显示、从上到下怎么排；顶部大图取自哪里、刷一刷是否共用筛选', url: 'pages/SettingsHomePage', selfOnly: false },
      { key: 'list', label: '列表与抽卡', desc: '抽卡模式：每轮张数与默认开关', url: 'pages/SettingsListPage', selfOnly: false }
    ]
  },
  {
    key: 'player', title: '播放', rows: [
      { key: 'player', label: '播放设置', desc: '播放方式、返回桌面后怎么办、字幕与弹幕；解码与缓冲在页内折叠', url: 'pages/PlayerSettingsPage', selfOnly: false },
      { key: 'shorts', label: '刷一刷', desc: '后台准备素材的开关、占用上限、片段怎么挑的；负一屏提示光晕也在这里', url: 'pages/ShortsSettingsPage', selfOnly: false },
      { key: 'preview', label: '进度条预览', desc: '闲时预生成开关、占用上限与清理', url: 'pages/PreviewSettingsPage', selfOnly: false }
    ]
  },
  {
    key: 'data', title: '存储与数据', rows: [
      { key: 'cache', label: '空间管理', desc: '这台手机与服务器各占多少：哪些能清、各留多大上限', url: 'pages/CachePage', selfOnly: false },
      { key: 'offline', label: '下载管理', desc: '下到手机里的影片：进度、队列、仅 WiFi、上限与清理', url: 'pages/OfflinePage', selfOnly: false },
      { key: 'organize', label: '资料整理', desc: '检索别名、自建标签与系列；清空自定义修改在最底', url: 'pages/OrganizePage', selfOnly: false },
      { key: 'backup', label: '数据备份与迁移', desc: '收藏、评分、历史、稍后再看、清单的导出与导入（按番号匹配）', url: 'pages/BackupPage', selfOnly: false }
    ]
  },
  {
    key: 'ops', title: '维护与排障', rows: [
      // 排查用：把最近运行日志存成 txt（用户手上没有电脑抓 hilog 时用）
      { key: 'logexport', label: '诊断与日志', desc: '把最近几千条运行日志存成 txt，出问题时发给我就能定位', url: '', selfOnly: false, action: '导出' }
    ]
  }
];

@Entry
@Component
struct SettingsPage {
  private visible(row: NavRow): boolean {
    // 投屏默认隐藏：这套要真机 + 同一局域网才能验，没验之前不摆给用户。
    // 想试的时候把偏好 `enable_cast` 打开（详情页投屏按钮读同一个键）。
    if (row.needCast === true && Store.I.prefString('enable_cast', '0') !== '1') {
      return false;
    }
    // 管理工具是聚合页：入库与「还行」都没开时，整行不显示（否则点进去是空页）。
    return true;
  }

  /**
   * 先过滤再渲染：只有「过滤后的第 0 行」才不画上分隔线。
   * 直接在 ForEach 里按原始下标判断，会在「整组第一条恰好被隐藏」时（如 public 版没有入库）
   * 画出第一条上方那条多余的分隔线。
   */
  private rowsOf(g: NavGroup): NavRow[] {
    return g.rows.filter((r: NavRow) => this.visible(r));
  }

  private async exportLog(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    promptAction.showToast({ message: `正在导出（${AppLog.count()} 行）…` });
    const msg: string = await AppLog.export(ctx);
    promptAction.showToast({ message: msg, duration: 6000 });
    AppLog.mark('settings', `导出日志：${msg}`);
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

              Column() {
                ForEach(this.rowsOf(g), (r: NavRow, idx: number) => {
                  Column() {
                    // 行间用 1px 细线分隔（原来是 1px 的透底黑缝，像卡片被切成几段）
                    if (idx > 0) {
                      Divider()
                        .strokeWidth(1)
                        .color(Theme.CARD_HI)
                    }
                    Row({ space: 12 }) {
                      Column({ space: 3 }) {
                        Text(r.label)
                          .fontSize(15)
                          .fontColor(r.danger === true ? Theme.DANGER : Theme.TEXT)
                        Text(r.desc)
                          .fontSize(11)
                          .fontColor(Theme.TEXT_FAINT)
                          .maxLines(2)
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      // 动作行（导出 / 清空）用动词代替 ›，别让它看着像能进下一页
                      if (r.action !== undefined) {
                        Text(r.action)
                          .fontSize(12)
                          .fontColor(r.danger === true ? Theme.DANGER : Theme.TEXT_DIM)
                      } else {
                        Text('›')
                          .fontSize(20)
                          .fontColor(Theme.TEXT_FAINT)
                      }
                    }
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                    .onClick(() => {
                      // 动作行（没有目标页）：诊断与日志 = 导出 txt
                      if (r.key === 'logexport') {
                        this.exportLog();
                        return;
                      }
                      router.pushUrl({ url: r.url });
                    })
                  }
                  .width('100%')
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