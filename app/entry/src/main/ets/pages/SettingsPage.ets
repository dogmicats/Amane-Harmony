import { router, promptAction } from '@kit.ArkUI';
import { Store, MODE_LAN, MODE_WAN } from '../common/Store';
import { Theme } from '../common/Theme';
import { Personalize } from '../common/Personalize';
import { setPageFullScreen } from '../common/PageFullscreen';
import { BuildConfig } from '../common/BuildConfig';
import { AppLog } from '../common/AppLog';
import { common } from '@kit.AbilityKit';
import { GlassSearchBar, PageTitle, GlassBack } from '../view/GlassKit';
import {
  SettingsAmbientGlow, SettingsChevron, SettingsIconTile, SettingsRowDivider, SettingsSectionTitle
} from '../view/SettingsKit';

interface NavRow {
  key: string;
  icon: Resource;
  label: string;
  desc: string;
  url: string;
  selfOnly: boolean;
  needOk?: boolean;
  needCast?: boolean;
  action?: string;
  danger?: boolean;
}

interface NavGroup {
  key: string;
  title: string;
  rows: NavRow[];
}

const NAV_KEYWORDS: Record<string, string> = {
  'conn': '服务器 地址 端口 密码 令牌 token 局域网 外网 连接 重连 ping 测试 fuwuqi lianjie mima dk',
  'casttoken': '投屏 电视 令牌 只读 画面 touping tp',
  'appearance': '主题 配色 颜色 皮肤 列数 海报 剧照 光效 触感 震动 深色 浅色 暗色 夜色 日间 夜间 界面 外观 布局 玻璃 毛玻璃 材质 顶栏 沉浸 模糊 算力 waiguan zhuti peise lieshu zt ps boli cailiao',
  'home': '首页 大图 横幅 banner 推荐 行 排序 显示 刷一刷 筛选 shouye datu tuijian sy',
  'list': '抽卡 每轮 张数 列表 默认 开关 chouka liebiao ck',
  'player': '播放 解码 硬解 软解 缓冲 代理 字幕 弹幕 后台 画中画 手势 bofang zimu danmu jiema bf',
  'shorts': '刷一刷 后台 素材 占用 片段 预取 光晕 shuayishua sys',
  'preview': '进度条 预览 雪碧图 截帧 预生成 清理 磁盘 jindutiao yulan jdt',
  'cache': '空间 缓存 清理 容量 上限 占用 磁盘 图片 删除 清空 释放 重置 kongjian huancun qingli kj hc',
  'subtitlemgr': '字幕 中字 外挂 健康检查 搜索队列 置信度 无字幕 外文 下载 zimu zizhang jiancha jk',
  'offline': '下载 离线 队列 wifi 限速 上限 空间 删除 xiazai lixian xz',
  'organize': '标签 系列 别名 检索 资料 自定义 整理 删除 重置 清空 ziliao zhengli biaoqian xilie bq',
  'backup': '备份 导出 导入 迁移 恢复 还原 收藏 评分 历史 beifen daoru daochu bf',
  'tools': '入库 还行 队列 清理 管理 后台 ruku guanli rk',
  'logexport': '日志 导出 txt 排障 反馈 抓日志 诊断 rizhi daochu rz'
};

const GROUPS: NavGroup[] = [
  {
    key: 'conn', title: '连接与服务', rows: [
      { key: 'conn', icon: $r('sys.symbol.wifi'), label: '服务器连接', desc: '局域网与外网地址、Token', url: 'pages/SettingsConnectionPage', selfOnly: false },
      { key: 'casttoken', icon: $r('sys.symbol.swap'), label: '投屏令牌', desc: '只读投屏钥匙，12 小时有效', url: 'pages/CastTokenPage', selfOnly: false, needCast: true }
    ]
  },
  {
    key: 'look', title: '外观与浏览', rows: [
      { key: 'appearance', icon: $r('sys.symbol.paintpalette'), label: '外观与布局', desc: '主题色、列数、顶栏材质与触感', url: 'pages/SettingsAppearancePage', selfOnly: false },
      { key: 'home', icon: $r('sys.symbol.house'), label: '首页内容', desc: '分区排序、大图池与推荐取向', url: 'pages/SettingsHomePage', selfOnly: false },
      { key: 'list', icon: $r('sys.symbol.rectangle_stack'), label: '列表与抽卡', desc: '剧照瀑布流每轮张数与开关', url: 'pages/SettingsListPage', selfOnly: false }
    ]
  },
  {
    key: 'player', title: '播放', rows: [
      { key: 'player', icon: $r('sys.symbol.play_circle'), label: '播放设置', desc: '播放方式、字幕弹幕与解码缓冲', url: 'pages/PlayerSettingsPage', selfOnly: false },
      { key: 'shorts', icon: $r('sys.symbol.wand_and_stars'), label: '刷一刷', desc: '负一屏素材预备、范围与背景', url: 'pages/ShortsSettingsPage', selfOnly: false },
      { key: 'preview', icon: $r('sys.symbol.film'), label: '进度条预览', desc: '雪碧图预生成与占用上限', url: 'pages/PreviewSettingsPage', selfOnly: false }
    ]
  },
  {
    key: 'data', title: '存储与数据', rows: [
      { key: 'cache', icon: $r('sys.symbol.externaldrive'), label: '空间管理', desc: '本机与服务端缓存占用与清理', url: 'pages/CachePage', selfOnly: false },
      { key: 'subtitlemgr', icon: $r('sys.symbol.translate'), label: '字幕管理', desc: '中文字幕体检与批量队列', url: 'pages/SubtitleManagerPage', selfOnly: false },
      { key: 'offline', icon: $r('sys.symbol.download'), label: '下载管理', desc: '离线影片队列与上限', url: 'pages/OfflinePage', selfOnly: false },
      { key: 'organize', icon: $r('sys.symbol.folder'), label: '资料整理', desc: '别名、自建标签与系列', url: 'pages/OrganizePage', selfOnly: false },
      { key: 'pending', icon: $r('sys.symbol.list_bullet_square'), label: '待下载决策记录', desc: '待下载影片与网盘进度', url: 'pages/PendingHistoryPage', selfOnly: true },
      { key: 'backup', icon: $r('sys.symbol.cloud_and_arrow_up'), label: '数据备份与迁移', desc: '收藏、评分与历史导入导出', url: 'pages/BackupPage', selfOnly: false }
    ]
  },
  {
    key: 'ops', title: '维护与排障', rows: [
      { key: 'logexport', icon: $r('sys.symbol.doc_text'), label: '诊断与日志', desc: '导出运行日志用于排查问题', url: '', selfOnly: false, action: '导出' }
    ]
  }
];

@Entry
@Component
struct SettingsPage {
  @State q: string = '';
  /** 从子页返回时刷新实时状态摘要（主题名、列数、连接地址、抽卡张数）。 */
  @State themeName: string = Theme.paletteOf(Theme.paletteKey).name;
  @State themeAccent: string = Theme.ACCENT;
  @State themeInk: string = Theme.ACCENT_INK;
  @State themeCard: string = Theme.CARD;
  @State hostLabel: string = '';
  @State onWan: boolean = false;
  @State modeLabel: string = '自动';
  @State posterCols: number = 3;
  @State gachaCount: number = 10;
  @State shortsBgLabel: string = '海报底';
  @StorageProp('amaneTopInset') topInset: number = 30;
  private navStack: NavPathStack = new NavPathStack();

  private syncSummary(): void {
    const pal = Theme.paletteOf(Theme.paletteKey);
    this.themeName = pal.name;
    this.themeAccent = pal.accent;
    this.themeInk = pal.ink;
    this.themeCard = pal.card;
    this.hostLabel = Store.I.amane.replace('http://', '').replace('https://', '');
    this.onWan = Store.I.onWan;
    this.modeLabel = Store.I.mode === MODE_LAN ? '局域网' : (Store.I.mode === MODE_WAN ? '外网' : '自动');
    this.posterCols = Personalize.cols();
    this.gachaCount = Store.I.gachaCount;
    this.shortsBgLabel = Store.I.prefString('shorts_poster_bg', '1') !== '0' ? '海报底' : '纯黑边';
  }

  aboutToAppear(): void {
    this.syncSummary();
  }

  onPageShow(): void {
    setPageFullScreen(getContext(this), true);
    this.syncSummary();
  }

  private visible(row: NavRow): boolean {
    if (row.needCast === true && Store.I.prefString('enable_cast', '0') !== '1') {
      return false;
    }
    return true;
  }

  private rowsOf(g: NavGroup): NavRow[] {
    return g.rows.filter((r: NavRow) => this.visible(r));
  }

  /** 每行右侧真实摘要（纯本地即时状态，不编造假数据）。 */
  private summaryOf(key: string): string {
    if (key === 'conn') {
      return `${this.modeLabel} · ${this.onWan ? '外网' : '局域网'}`;
    }
    if (key === 'appearance') {
      return `${this.themeName} · ${this.posterCols}列`;
    }
    if (key === 'list') {
      return `每轮 ${this.gachaCount} 张`;
    }
    if (key === 'player') {
      return 'mpv';
    }
    if (key === 'shorts') {
      return this.shortsBgLabel;
    }
    return '';
  }

  private norm(s: string): string {
    return s.replace(/\s+/g, '').toLowerCase();
  }

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

  /** 顶部快捷状态条：左进服务器连接，右进外观与布局。 */
  @Builder
  StatusStrip() {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.onWan ? '#F4C97E' : '#45B075')
        Column({ space: 2 }) {
          Text(this.onWan ? '外网已连接' : '局域网已连接')
            .fontSize(13.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
          Text(this.hostLabel)
            .fontSize(10.5)
            .fontColor(Theme.TEXT_FAINT)
            .fontFeature('"tnum" 1')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        router.pushUrl({ url: 'pages/SettingsConnectionPage' });
      })

      Divider()
        .vertical(true)
        .height(24)
        .strokeWidth(0.5)
        .color('#1CFFFFFF')

      Row({ space: 7 }) {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.themeAccent)
        Text(this.themeName)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themeInk)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .backgroundColor(Theme.alphaOf(this.themeAccent, 0.18))
          .border({ width: 0.5, color: Theme.alphaOf(this.themeInk, 0.44) })
          .borderRadius(Theme.R_PILL)
        SettingsChevron({ glyphSize: 12 })
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        router.pushUrl({ url: 'pages/SettingsAppearancePage' });
      })
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.themeCard)
    .linearGradient({
      angle: 140,
      colors: [[Theme.alphaOf(this.themeAccent, 0.10), 0.0], ['#00000000', 0.60]]
    })
    .borderRadius(16)
    .border({ width: 0.75, color: Theme.STROKE })
  }

  @Builder
  NavRowView(r: NavRow, sub: string) {
    Row({ space: 12 }) {
      SettingsIconTile({
        icon: r.icon,
        tileSize: 36,
        iconSize: 17,
        accent: this.themeAccent,
        ink: this.themeInk,
        danger: r.danger === true
      })
      Column({ space: 2 }) {
        Text(r.label)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(r.danger === true ? Theme.DANGER : Theme.TEXT)
        Text(sub)
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (r.action !== undefined) {
        Text(r.action)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(r.danger === true ? Theme.DANGER : this.themeInk)
          .padding({ left: 11, right: 11, top: 5, bottom: 5 })
          .backgroundColor(r.danger === true ? Theme.alphaOf(Theme.DANGER, 0.16) : Theme.alphaOf(this.themeAccent, 0.18))
          .border({
            width: 0.5,
            color: r.danger === true ? Theme.alphaOf(Theme.DANGER, 0.42) : Theme.alphaOf(this.themeInk, 0.44)
          })
          .borderRadius(Theme.R_PILL)
      } else {
        if (this.summaryOf(r.key).length > 0) {
          Text(this.summaryOf(r.key))
            .fontSize(11.5)
            .fontColor(Theme.TEXT_DIM)
            .fontFeature('"tnum" 1')
            .margin({ right: 2 })
        }
        SettingsChevron({ glyphSize: 13 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .onClick(() => {
      this.open(r);
    })
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
        GlassSearchBar({
          placeholder: '搜索设置',
          boxH: 40,
          rowH: 46,
          radius: 20,
          iconSize: 17,
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

  private barH(): number {
    return this.topInset + 46;
  }

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
      Stack({ alignContent: Alignment.Top }) {
        SettingsAmbientGlow({ accent: this.themeAccent })

        Scroll() {
          Column({ space: 16 }) {
            Blank().height(this.barH() + 6)

            if (this.q.trim().length > 0) {
              Column() {
                ForEach(this.hits(), (r: NavRow, idx: number) => {
                  Column() {
                    if (idx > 0) {
                      SettingsRowDivider()
                    }
                    this.NavRowView(r, `${this.groupTitleOf(r.key)} · ${r.desc}`)
                  }
                  .width('100%')
                }, (r: NavRow) => `hit-${r.key}-${this.themeName}`)

                if (this.hits().length === 0) {
                  Text('没有找到相关设置，换个词试试（例如「字幕」「主题」）')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_FAINT)
                    .padding({ left: 16, right: 16, top: 18, bottom: 18 })
                    .width('100%')
                }
              }
              .width('100%')
              .backgroundColor(this.themeCard)
              .borderRadius(18)
              .border({ width: 0.75, color: Theme.STROKE })
              .clip(true)
            } else {
              this.StatusStrip()

              ForEach(GROUPS, (g: NavGroup) => {
                if (this.rowsOf(g).length > 0) {
                  Column({ space: 8 }) {
                    SettingsSectionTitle({ title: g.title })

                    Column() {
                      ForEach(this.rowsOf(g), (r: NavRow, idx: number) => {
                        Column() {
                          if (idx > 0) {
                            SettingsRowDivider()
                          }
                          this.NavRowView(r, r.desc)
                        }
                        .width('100%')
                      }, (r: NavRow) => `row-${r.key}-${this.themeName}-${this.posterCols}-${this.gachaCount}-${this.onWan ? 1 : 0}`)
                    }
                    .width('100%')
                    .backgroundColor(this.themeCard)
                    .borderRadius(18)
                    .border({ width: 0.75, color: Theme.STROKE })
                    .clip(true)
                  }
                  .width('100%')
                }
              }, (g: NavGroup) => `g-${g.key}-${this.themeName}`)
            }
          }
          .width('100%')
          .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.pageBottomSafe() })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title(this.titleConfig(), { barStyle: BarStyle.STACK })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
