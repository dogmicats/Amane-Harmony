import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';
import { AppLog } from '../common/AppLog';
import { common } from '@kit.AbilityKit';

/**
 * 设置（一级页）：只做分区导航，不放具体设置项。
 *
 * 布局照 hosplayer 的思路：先把整页切成几大块，二级入口按语义归到各块里。
 * **一组只放一种东西**，宁可多切一组，也别设「其他」这种垃圾桶组。
 *
 *   通用     —— 全局环境：连接（地址 / Token）、检索别名（名字映射）
 *   外观     —— 看起来是什么样：主题与列数、首页内容、列表页抽卡
 *   播放     —— 与看片直接相关：播放器设置、进度条预览
 *   我的内容 —— 我自己的东西：离线缓存、清单、截帧、自建标签
 *   高级     —— 管理/排查：入库、还行、投屏令牌、导出日志
 *   重置     —— 不可撤销的破坏性动作，单独成组沉到最底，不许和日常项混排
 *
 * 「关于 Amane / 检查更新 / 更新日志」2.6.1.7 起不在设置里了：
 * 三行搬到「我的 → 关于」（`pages/AboutHubPage`）。设置里那组已删，别再往这里加回来 ——
 * 同一个东西两处入口，改一处忘一处就是下一个「点进去还是旧版」的 bug。
 *
 * 组内顺序：常用的在上、排障/偏门在下。新增设置先想清楚落在哪块；
 * 块内再拆二级页，别把一堆控件平铺回来。
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
  /** 动作行（url 为空）右侧的动词，如「清空」「导出」；有它就不画 ›。 */
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
    key: 'general', title: '通用', rows: [
      { key: 'conn', label: '连接', desc: '局域网 / 外网地址、API Token、测试与重连', url: 'pages/SettingsConnectionPage', selfOnly: false },
      { key: 'alias', label: '检索别名', desc: '俗称和库里的名字对不上时，在这儿挂钩（如 搜查官 → 女检察官）', url: 'pages/AliasPage', selfOnly: false }
    ]
  },
  {
    key: 'look', title: '外观', rows: [
      { key: 'appearance', label: '主题与列数', desc: '8 套主题色、海报列数、剧照瀑布流列数（都能双指一捏切换）', url: 'pages/SettingsAppearancePage', selfOnly: false },
      { key: 'home', label: '首页内容', desc: '首页哪几行显示、从上到下怎么排', url: 'pages/SettingsHomePage', selfOnly: false },
      { key: 'list', label: '列表页', desc: '抽卡模式：每轮张数与默认开关', url: 'pages/SettingsListPage', selfOnly: false }
    ]
  },
  {
    key: 'player', title: '播放', rows: [
      { key: 'player', label: '播放器设置', desc: '解码、渲染、字幕等播放参数', url: 'pages/PlayerSettingsPage', selfOnly: false },
      { key: 'preview', label: '进度条预览', desc: '闲时预生成开关、占用上限与清理', url: 'pages/PreviewSettingsPage', selfOnly: false }
    ]
  },
  {
    key: 'mine', title: '我的内容', rows: [
      { key: 'offline', label: '离线缓存', desc: '下到手机里的影片：进度、队列、仅 WiFi、上限与清理', url: 'pages/OfflinePage', selfOnly: false },
      { key: 'collections', label: '我的清单', desc: '收藏清单：新建、改名、删除', url: 'pages/CollectionsPage', selfOnly: false },
      { key: 'picks', label: '我的截帧', desc: '我截的关键帧：看、跳、删、存到手机', url: 'pages/FramePicksPage', selfOnly: false },
      { key: 'selffacet', label: '自建标签 / 系列', desc: '你自己起的名字都在这儿，可单独删；库里的分类不在这里', url: 'pages/SelfFacetPage', selfOnly: false }
    ]
  },
  {
    key: 'advanced', title: '高级', rows: [
      // 投屏（2.5.6）暂时隐藏：没有真机能验，先不对外开。
      // 要开：设置里把偏好 `enable_cast` 置 true（详情页的「投屏」按钮读同一个开关）
      { key: 'casttoken', label: '投屏令牌', desc: '投给电视时用的只读钥匙，12 小时过期，可随时吊销', url: 'pages/CastTokenPage', selfOnly: false, needCast: true },
      // 排查用：把最近运行日志存成 txt（用户手上没有电脑抓 hilog 时用）
      { key: 'logexport', label: '导出运行日志', desc: '把最近几千条运行日志存成 txt，出问题时发给我就能定位', url: '', selfOnly: false, action: '导出' }
    ]
  },
  {
    // 破坏性动作单独成组：不挨着日常项，手指蹭不到；颜色也和其他行不一样。
    key: 'reset', title: '重置', rows: [
      { key: 'resetmeta', label: '清空所有自定义修改', desc: '把改过的片名/演员/标签与换过的封面全部还原成刮削原样（所有设备一起变）', url: '', selfOnly: false, action: '清空', danger: true }
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

  /**
   * 清空所有本地修改（2.5.5）。破坏性且不可撤销 —— 先问再发，返回里带上清掉几条。
   * 老服务端 404 就说「本版没有」而不是报错。
   */
  private confirmResetMeta(): void {
    AlertDialog.show({
      title: '清空所有自定义修改？',
      message: '你改过的片名、演员、标签、封面会全部回到刮削原样（所有设备一起变），且不能撤销。',
      primaryButton: {
        value: '清空',
        fontColor: Theme.DANGER,
        action: () => {
          this.resetMeta();
        }
      },
      secondaryButton: {
        value: '算了',
        action: () => {
        }
      }
    });
  }

  private async resetMeta(): Promise<void> {
    try {
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/meta_override/clear`, Store.I.token, '{"confirm":true}');
      const obj = JSON.parse(raw) as Record<string, Object>;
      const data = obj.data;
      let n: number = 0;
      if (data !== undefined && data !== null) {
        const v = (data as Record<string, Object>).removed;
        n = v === undefined || v === null ? 0 : Number(v);
      }
      promptAction.showToast({ message: `已清空 ${n} 部`, duration: 1600 });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] meta clear: ${e.code} ${e.message}`);
      promptAction.showToast({
        message: e.code === 404 ? '这个版本还不支持自定义修改' : '清空失败，稍后再试',
        duration: 1800
      });
    }
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
                      // 2.5.5：「清空所有本地修改」是个动作行（没有目标页）
                      if (r.key === 'resetmeta') {
                        this.confirmResetMeta();
                        return;
                      }
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