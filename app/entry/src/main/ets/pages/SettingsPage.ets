import { router, promptAction } from '@kit.ArkUI';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';
import { AppLog } from '../common/AppLog';
import { common } from '@kit.AbilityKit';
import { GlassGlyph, GlassSearchBar, PageTitle, GlassBack} from '../view/GlassKit';

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
 *  2. 「检索别名」+「自建标签 / 系列」合成 `资料整理`，「数据与入库」+「归档管理」合成 `管理工具`，
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
  /** 仅在「入库」或「归档」至少有一个开着时显示（管理工具聚合页）。 */
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

/**
 * 搜索用的同义词（2026-11-16，设置页搜索）。
 *
 * 用户找设置时想到的词和目标页的名字经常对不上：想看字幕去搜「字幕」，而它藏在「播放设置」里；
 * 想清缓存搜「空间」，而卡片叫「空间管理」。这张表就是补这层「联想」，
 * 键 = `NavRow.key`，值 = 空格分隔的同义词。没配的行只按 label/desc 匹配。
 *
 * 每组末尾还挂了**拼音全拼 + 首字母**（`zhuti zt`）：手机上打英文/首字母比切中文快得多，
 * 搜 `zt` 能出「主题」、`bf` 能出「播放设置」。这是手写的小表，不引拼音库。
 */
const NAV_KEYWORDS: Record<string, string> = {
  'conn': '服务器 地址 端口 密码 令牌 token 局域网 外网 连接 重连 ping 测试 fuwuqi lianjie mima dk',
  'casttoken': '投屏 电视 令牌 只读 画面 touping tp',
  'appearance': '主题 配色 颜色 皮肤 列数 海报 剧照 光效 触感 震动 深色 浅色 暗色 夜色 日间 夜间 界面 外观 布局 玻璃 毛玻璃 材质 顶栏 沉浸 模糊 算力 waiguan zhuti peise lieshu zt ps boli cailiao',
  'home': '首页 大图 横幅 banner 推荐 行 排序 显示 刷一刷 筛选 shouye datu tuijian sy',
  'list': '抽卡 每轮 张数 列表 默认 开关 chouka liebiao ck',
  'player': '播放 解码 硬解 软解 缓冲 代理 字幕 弹幕 后台 画中画 手势 bofang zimu danmu jiem a bf',
  'shorts': '刷一刷 后台 素材 占用 片段 预取 光晕 shuayishua sys',
  'preview': '进度条 预览 雪碧图 截帧 预生成 清理 磁盘 jindutiao yulan jdt',
  'cache': '空间 缓存 清理 容量 上限 占用 磁盘 图片 删除 清空 释放 重置 kongjian huancun qingli kj hc',
  'offline': '下载 离线 队列 wifi 限速 上限 空间 删除 xiazai lixian xz',
  'organize': '标签 系列 别名 检索 资料 自定义 整理 删除 重置 清空 ziliao zhengli biaoqian xilie bq',
  'backup': '备份 导出 导入 迁移 恢复 还原 收藏 评分 历史 beifen daoru daochu bf',
  'tools': '入库 还行 队列 清理 管理 后台 ruku guanli rk',
  'logexport': '日志 导出 txt 排障 反馈 抓日志 诊断 rizhi daochu rz'
};

const GROUPS: NavGroup[] = [
  {
    key: 'conn', title: '连接与服务', rows: [
      // 临时置顶（2026-11-17）：HDS 沉浸光感评估探针，评估完删这一行与对应页面
      { key: 'hdsprobe', label: '★ HDS 沉浸光感评估（临时）', desc: '查设备材质能力，并演示 HDS 标题栏的材质/渐变模糊/光晕', url: 'pages/HdsProbePage', selfOnly: false },
      { key: 'conn', label: '服务器连接', desc: '局域网 / 外网地址、API Token、测试与重连', url: 'pages/SettingsConnectionPage', selfOnly: false },
      // 投屏（2.5.6）暂时隐藏：没有真机能验，先不对外开。
      // 要开：设置里把偏好 `enable_cast` 置 true（详情页的「投屏」按钮读同一个开关）
      { key: 'casttoken', label: '投屏令牌', desc: '投给电视时用的只读钥匙，12 小时过期，可随时吊销', url: 'pages/CastTokenPage', selfOnly: false, needCast: true }
    ]
  },
  {
    key: 'look', title: '外观与浏览', rows: [
      { key: 'appearance', label: '外观与布局', desc: '8 套主题色、海报列数、剧照瀑布流列数，以及触感反馈', url: 'pages/SettingsAppearancePage', selfOnly: false },
      { key: 'home', label: '首页内容', desc: '哪几行显示、从上到下怎么排；顶部大图取自哪里（刷一刷的范围在「刷一刷」那页）', url: 'pages/SettingsHomePage', selfOnly: false },
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
  /** 设置搜索的输入（2026-11-16）：空串 = 正常分组列表，非空 = 结果列表。 */
  @State q: string = '';
  private visible(row: NavRow): boolean {
    // 投屏默认隐藏：这套要真机 + 同一局域网才能验，没验之前不摆给用户。
    // 想试的时候把偏好 `enable_cast` 打开（详情页投屏按钮读同一个键）。
    if (row.needCast === true && Store.I.prefString('enable_cast', '0') !== '1') {
      return false;
    }
    // 管理工具是聚合页：入库与「归档」都没开时，整行不显示（否则点进去是空页）。
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

  // ── 设置搜索（2026-11-16）──────────────────────────────────────────
  /** 归一化：去掉空白、统一小写，让「 字幕 」和「字幕」等价。 */
  private norm(s: string): string {
    return s.replace(/\s+/g, '').toLowerCase();
  }

  /**
   * 单行打分：0 = 不命中；分数越高越靠前。
   * 权重按「用户最可能依据什么找」排：标题 > 同义词 > 描述。
   */
  private scoreOf(r: NavRow, q: string): number {
    const query: string = this.norm(q);
    if (query.length === 0) {
      return 0;
    }
    const label: string = this.norm(r.label);
    if (label === query) {
      return 100;
    }
    if (label.startsWith(query)) {
      return 90;
    }
    if (label.includes(query)) {
      return 80;
    }
    const kw: string = this.norm(NAV_KEYWORDS[r.key] === undefined ? '' : NAV_KEYWORDS[r.key]);
    if (kw.length > 0 && kw.includes(query)) {
      return 60;
    }
    if (this.norm(r.desc).includes(query)) {
      return 40;
    }
    // 退一步：多字查询按「首字逐字命中」算模糊（「播放字幕」→ 关键词里两处都能沾上）
    if (query.length >= 2 && kw.length > 0) {
      let hit: number = 0;
      for (let i = 0; i < query.length; i++) {
        if (kw.includes(query.charAt(i))) {
          hit++;
        }
      }
      if (hit === query.length) {
        return 20;
      }
    }
    return 0;
  }

  /** 命中的行（跨分组），按分数降序；同分保持原有顺序。 */
  private hits(): NavRow[] {
    const out: NavRow[] = [];
    const scores: number[] = [];
    for (let gi = 0; gi < GROUPS.length; gi++) {
      const rows: NavRow[] = this.rowsOf(GROUPS[gi]);
      for (let ri = 0; ri < rows.length; ri++) {
        const s: number = this.scoreOf(rows[ri], this.q);
        if (s <= 0) {
          continue;
        }
        // 插入排序：命中数量很少（<30），没必要上 sort
        let pos: number = out.length;
        for (let i = 0; i < scores.length; i++) {
          if (s > scores[i]) {
            pos = i;
            break;
          }
        }
        out.splice(pos, 0, rows[ri]);
        scores.splice(pos, 0, s);
      }
    }
    return out;
  }

  /** 结果行下方的分组提示（「外观与浏览」这种），让人知道自己在找的东西属于哪一块。 */
  private groupTitleOf(key: string): string {
    for (let gi = 0; gi < GROUPS.length; gi++) {
      const rows: NavRow[] = GROUPS[gi].rows;
      for (let ri = 0; ri < rows.length; ri++) {
        if (rows[ri].key === key) {
          return GROUPS[gi].title;
        }
      }
    }
    return '';
  }

  /** 点一行：动作行（导出日志）就地执行，其余进对应页面。抽出来给搜索和原列表共用。 */
  private open(row: NavRow): void {
    if (row.key === 'logexport') {
      this.exportLog();
      return;
    }
    router.pushUrl({ url: row.url });
  }

  private async exportLog(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    promptAction.showToast({ message: `正在导出（${AppLog.count()} 行）…` });
    const msg: string = await AppLog.export(ctx);
    promptAction.showToast({ message: msg, duration: 6000 });
    AppLog.mark('settings', `导出日志：${msg}`);
  }

  @Builder
  TitleBar() {
    Column() {
      Row({ space: 10 }) {
        GlassBack({
          mat: true,
          onTap: () => {
          router.back();
          }
        })
        PageTitle({ text: '设置', fs: 18 })
        // 五十九改：搜索收成统一组件 `GlassSearchBar` —— 点放大镜那颗胶囊自己长成搜索栏，
        // 与首页/收藏/演员/标签同一套交互、同一个图标（以前是内容区单独一条实色输入框）。
        GlassSearchBar({
          placeholder: '搜索设置',
          boxH: 42,
          rowH: 46,
          radius: 21,
          iconSize: 18,
          onCommit: (kw: string) => {
            this.q = kw;
          }
        })
        .layoutWeight(1)
      }
      .height(46)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
  }

  @StorageProp('amaneTopInset') topInset: number = 30;

  /** 导航栈（六十改）：整页套 Navigation 只为拿到「标题栏」这个材质落点。 */
  private navStack: NavPathStack = new NavPathStack();

  /** 标题栏实际高度（内容要让开这么多）。 */
  private barH(): number {
    return this.topInset + 46;
  }

  /** 标题栏配置：高度 = 状态栏 + 46，内容行落在状态栏下面（与媒体库同一套）。 */
  private titleConfig(): NavigationCustomTitle {
    return {
      builder: () => {
        this.TitleBar();
      },
      height: 46 + this.topInset
    };
  }

  build() {
    Navigation(this.navStack) {
      Column() {

        // 五十九改：原来这条常驻搜索框已撤 —— 搜索胶囊搬进了标题行（点一下自己长成搜索栏），
        // 内容区不再被一条实色输入框压掉一截。
        Scroll() {
          Column({ space: 18 }) {

          // 六十改：标题栏浮在内容之上 —— 首屏落在玻璃下方，一滚动就从玻璃底下穿过去，
          // 材质才有颜色可采样。
          Blank().height(this.barH())
            if (this.q.trim().length > 0) {
              // 搜索结果：一张卡，按相关度排序，行下补一行分组名
              Column() {
                ForEach(this.hits(), (r: NavRow, idx: number) => {
                  Column() {
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
                        Text(`${this.groupTitleOf(r.key)} · ${r.desc}`)
                          .fontSize(11)
                          .fontColor(Theme.TEXT_FAINT)
                          .maxLines(2)
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (r.action !== undefined) {
                        Text(r.action)
                          .fontSize(12)
                          .fontColor(Theme.TEXT_DIM)
                      } else {
                        Text('›')
                          .fontSize(20)
                          .fontColor(Theme.TEXT_FAINT)
                      }
                    }
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                    .onClick(() => {
                      this.open(r);
                    })
                  }
                  .width('100%')
                }, (r: NavRow) => `hit-${r.key}`)

                if (this.hits().length === 0) {
                  Text('没有找到相关设置，换个说法试试（比如「字幕」→ 播放设置）')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .padding({ left: 14, right: 14, top: 16, bottom: 16 })
                    .width('100%')
                }
              }
              .width('100%')
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .clip(true)
            } else {
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
                        this.open(r);
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
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}