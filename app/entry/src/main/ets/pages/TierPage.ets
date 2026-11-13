import { router, promptAction, componentSnapshot } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { httpGet, httpPost, httpDelete } from '../common/Http';
import { Gallery } from '../common/Gallery';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 从夯到拉 · Tier 图（2.5.5 重做）。
 *
 * 页面三段，从上到下就是用户的操作顺序：
 *   1. **配置 + 一键生成**：类型、时间、性别、只看收藏、包含未评分；
 *   2. **当前图**：默认是「展示中 / 最新那张」，左边色块档名 + 右边一排图（真 tier list 的版式）；
 *   3. **历史生成**：每张的摘要 + 三个缩略图 + 设为展示 / 下载 / 删除。
 *
 * 铁律：**客户端只渲染不算档** —— 分档、档内排序、每档上限、默认条件全由服务端给
 * （`amane-user/server.py` 的 `tier_*`，契约见 `docs/TASKS/2.5.4-tierlist.md` §4）。
 *
 * 三个 ArkUI 老坑（本文件里都有对应写法）：
 *   1. `@Builder` 传参不因参数变化重跑 —— 会变的都读 `this.xxx`；
 *   2. `ForEach` 的 key 必须含会变的状态（否则内容换了节点按旧 key 复用）；
 *   3. 服务端给的是**相对路径**（`/api/resources/...`），必须过 `Store.I.img()` 才带得上 token。
 */

const ST_IDLE: string = 'idle';
const ST_LOADING: string = 'loading';
const ST_OK: string = 'ok';
const ST_EMPTY: string = 'empty';
/** 端点不存在（老服务端 404）。 */
const ST_OFF: string = 'off';

const KINDS: string[] = ['film', 'actor', 'director', 'studio', 'tag', 'series'];
const KIND_LABELS: string[] = ['影片', '演员', '导演', '厂牌', '标签', '系列'];

/** 一行档位的高度（左色块与右侧图区都按这个算）。 */
const ROW_H: number = 96;
const LABEL_W: number = 56;
/** 影片用竖版海报，其余用方块。 */
const FILM_W: number = 52;
const FILM_H: number = 78;
const SQUARE: number = 52;

interface TierItem {
  id: number;
  kind: string;
  name: string;
  /** 只有 film 有。 */
  number: string;
  /** 相对路径（海报 / 头像 / logo / 封面）；空串 = 占位块。 */
  image: string;
  score: number;
  rated_at: string;
}

interface TierRow {
  score: number;
  title: string;
  items: TierItem[];
  /** 这一档还有多少个没返回。 */
  more: number;
}

interface TierData {
  id: number;
  created_at: string;
  summary: string;
  /** 图名：用户填的，或服务端按条件 + 分布自动起的（2.5.4.10 起）。 */
  title: string;
  tiers: TierRow[];
  total: number;
  picked: boolean;
}

interface TierRes {
  ok: boolean;
  version: number;
  reason: string;
  data: TierData;
}

/** 历史记录一条：列表只给摘要与三张缩略图，点「下载」再去取整张。 */
interface TierSnap {
  id: number;
  created_at: string;
  summary: string;
  /** 图名（老快照为空串，界面退回显示 summary）。 */
  title: string;
  total: number;
  thumbs: string[];
  picked: boolean;
}

interface SnapListRes {
  ok: boolean;
  data: SnapListData;
}

interface SnapListData {
  items: TierSnap[];
  total: number;
}

interface SnapDeleteRes {
  ok: boolean;
  data: SnapDeleteData;
}

interface SnapDeleteData {
  removed: number;
}

/** 只要 id 的请求体（ArkTS 不接受无类型对象字面量，得有个 interface 兜着）。 */
interface IdBody {
  id: number;
}

function num(v: number): number {
  if (v === undefined || v === null) {
    return 0;
  }
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function str(v: string): string {
  return v === undefined || v === null ? '' : `${v}`;
}

function bool(v: boolean): boolean {
  return v === true;
}

/** `Date` → `YYYY-MM-DD`（本地时区；别用 toISOString，晚上会差一天）。 */
function ymd(d: Date): string {
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const dd: string = day < 10 ? `0${day}` : `${day}`;
  return `${d.getFullYear()}-${mm}-${dd}`;
}

/** ISO（UTC）→ `MM-DD HH:mm`（本机时区）。解不出来就原样截前 16 字。 */
function stamp(iso: string): string {
  if (iso.length === 0) {
    return '';
  }
  const t: number = Date.parse(iso);
  if (!Number.isFinite(t)) {
    return iso.length >= 16 ? iso.substring(5, 16).replace('T', ' ') : iso;
  }
  const d: Date = new Date(t);
  const mm: number = d.getMonth() + 1;
  const dd: number = d.getDate();
  const hh: number = d.getHours();
  const mi: number = d.getMinutes();
  return `${mm < 10 ? '0' : ''}${mm}-${dd < 10 ? '0' : ''}${dd} `
    + `${hh < 10 ? '0' : ''}${hh}:${mi < 10 ? '0' : ''}${mi}`;
}

/** 文件名用的时间戳：`20261111_2335`（相册里按名字就能看出是哪天存的）。 */
function fileStamp(): string {
  const d: Date = new Date();
  const mm: string = `${d.getMonth() + 1}`.length < 2 ? `0${d.getMonth() + 1}` : `${d.getMonth() + 1}`;
  const dd: string = `${d.getDate()}`.length < 2 ? `0${d.getDate()}` : `${d.getDate()}`;
  const hh: string = `${d.getHours()}`.length < 2 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mi: string = `${d.getMinutes()}`.length < 2 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  return `${d.getFullYear()}${mm}${dd}_${hh}${mi}`;
}

@Entry
@Component
struct TierPage {
  // ---- 生成条件 --------------------------------------------------------
  @State kinds: string[] = ['film'];
  /** `all` / `30` / `90` / `year`。 */
  @State rangeKey: string = 'all';
  @State dateFrom: string = '';
  @State dateTo: string = '';
  /** `''` 不限 / `female` / `male`（只对演员类有意义）。 */
  @State gender: string = '';
  @State favoriteOnly: boolean = false;
  @State includeUnrated: boolean = false;
  @State cfgOpen: boolean = true;
  /** 自己填的图名；留空由服务端按条件 + 分布起名（`tier_title()`）。 */
  @State customTitle: string = '';
  /** 存到相册的图里要不要画标题（默认要；黑体居中，画在浅色底板顶部）。 */
  @State exportWithTitle: boolean = true;

  // ---- 当前图 ----------------------------------------------------------
  @State st: string = ST_IDLE;
  @State tiers: TierRow[] = [];
  @State total: number = 0;
  @State curId: number = 0;
  @State curSummary: string = '';
  /** 当前这张图的名字（服务端起的名，或用户自己填的）。 */
  @State curTitle: string = '';
  @State curAt: string = '';
  @State curPicked: boolean = false;
  @State note: string = '';
  /** 每次换图 +1：ForEach 的 key 带上它，节点才会真的重画（老坑 2）。 */
  @State boardKey: number = 0;

  // ---- 历史 ------------------------------------------------------------
  @State hist: TierSnap[] = [];
  @State histLoading: boolean = false;

  // ---- 忙 / 提示 -------------------------------------------------------
  @State generating: boolean = false;
  @State exporting: boolean = false;
  @State downloadingId: number = 0;
  @State hint: string = '';

  aboutToAppear(): void {
    // 进来先看「展示中 / 最新那张」，而不是空面板
    this.loadCurrent();
    this.loadHistory();
  }

  // ---- 取数 ------------------------------------------------------------

  private async loadCurrent(): Promise<void> {
    this.st = ST_LOADING;
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/tier/current`, Store.I.token);
      const res: TierRes = JSON.parse(raw) as TierRes;
      if (res.data === undefined || res.data === null || res.data.tiers === undefined) {
        this.st = ST_OFF;
        return;
      }
      this.applyData(res.data, res.ok === true);
      this.note = res.ok === true ? '' : str(res.reason);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier/current: ${e.code} ${e.message}`);
      this.st = ST_OFF;
    }
  }

  private async loadHistory(): Promise<void> {
    this.histLoading = true;
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/tier/snapshots?limit=30`, Store.I.token);
      const res: SnapListRes = JSON.parse(raw) as SnapListRes;
      const out: TierSnap[] = [];
      const src: TierSnap[] = res.data === undefined || res.data === null ? [] : res.data.items;
      if (Array.isArray(src)) {
        for (let i = 0; i < src.length; i++) {
          const it: TierSnap = src[i];
          const thumbs: string[] = Array.isArray(it.thumbs) ? it.thumbs : [];
          out.push({
            id: num(it.id),
            created_at: str(it.created_at),
            summary: str(it.summary),
            title: str(it.title),
            total: num(it.total),
            thumbs: thumbs,
            picked: bool(it.picked)
          });
        }
      }
      this.hist = out;
    } catch (err) {
      const e = err as BusinessError;
      // 老服务端没有历史端点：不报错，只是这一段空着
      console.error(`[amane] tier/snapshots: ${e.code} ${e.message}`);
      this.hist = [];
    }
    this.histLoading = false;
  }

  private applyData(d: TierData, ok: boolean): void {
    const rows: TierRow[] = [];
    const src: TierRow[] = Array.isArray(d.tiers) ? d.tiers : [];
    for (let i = 0; i < src.length; i++) {
      const r: TierRow = src[i];
      const items: TierItem[] = [];
      const list: TierItem[] = Array.isArray(r.items) ? r.items : [];
      for (let j = 0; j < list.length; j++) {
        const it: TierItem = list[j];
        items.push({
          id: num(it.id),
          kind: str(it.kind),
          name: str(it.name),
          number: str(it.number),
          image: str(it.image),
          score: num(it.score),
          rated_at: str(it.rated_at)
        });
      }
      rows.push({ score: num(r.score), title: str(r.title), items: items, more: num(r.more) });
    }
    this.tiers = rows;
    this.total = num(d.total);
    this.curId = num(d.id);
    this.curSummary = str(d.summary);
    this.curTitle = str(d.title);
    this.curAt = str(d.created_at);
    this.curPicked = bool(d.picked);
    this.boardKey = this.boardKey + 1;
    this.st = ok && this.total > 0 ? ST_OK : ST_EMPTY;
  }

  // ---- 条件 ------------------------------------------------------------

  private kindLabel(kind: string): string {
    const i: number = KINDS.indexOf(kind);
    return i >= 0 ? KIND_LABELS[i] : kind;
  }

  private hasKind(kind: string): boolean {
    return this.kinds.indexOf(kind) >= 0;
  }

  /** 演员这一档才有性别：选的是影片 / 标签时那一排不出现，省一行高度。 */
  private showGender(): boolean {
    return this.hasKind('actor');
  }

  private toggleKind(kind: string): void {
    const next: string[] = [];
    let had: boolean = false;
    for (let i = 0; i < this.kinds.length; i++) {
      if (this.kinds[i] === kind) {
        had = true;
      } else {
        next.push(this.kinds[i]);
      }
    }
    if (!had) {
      next.push(kind);
    }
    if (next.length === 0) {
      promptAction.showToast({ message: '至少留一类内容', duration: 1500 });
      return;
    }
    this.kinds = next;
  }

  private applyRange(key: string): void {
    this.rangeKey = key;
    if (key === 'all') {
      this.dateFrom = '';
      this.dateTo = '';
      return;
    }
    const to: Date = new Date();
    let from: Date;
    if (key === 'year') {
      from = new Date(to.getFullYear(), 0, 1);
    } else {
      const days: number = key === '30' ? 30 : 90;
      from = new Date(to.getTime() - (days - 1) * 86400000);
    }
    this.dateFrom = ymd(from);
    this.dateTo = ymd(to);
  }

  private rangeLabel(key: string): string {
    if (key === '30') {
      return '近 30 天';
    }
    if (key === '90') {
      return '近 90 天';
    }
    return key === 'year' ? '今年' : '全部';
  }

  private genderOf(id: number): string {
    if (id === 1) {
      return 'female';
    }
    if (id === 2) {
      return 'male';
    }
    return '';
  }

  private genderUk(id: number): string {
    const g: string = this.genderOf(id);
    return g === this.gender ? g : `u${id}`;
  }

  private genderLabel(id: number): string {
    if (id === 1) {
      return '女';
    }
    return id === 2 ? '男' : '不限';
  }

  private resetFilters(): void {
    this.kinds = ['film'];
    this.rangeKey = 'all';
    this.dateFrom = '';
    this.dateTo = '';
    this.gender = '';
    this.favoriteOnly = false;
    this.includeUnrated = false;
  }

  private async generate(): Promise<void> {
    if (this.generating) {
      return;
    }
    this.generating = true;
    this.hint = '正在按星级排…';
    try {
      const body: Record<string, Object> = {
        'kinds': this.kinds,
        'date_from': this.dateFrom,
        'date_to': this.dateTo,
        'actor_gender': this.gender,
        'favorite_only': this.favoriteOnly,
        'include_unrated': this.includeUnrated,
        // 留空 -> 服务端按条件 + 星分布自动起名（`tier_title()`）
        'title': this.customTitle.trim()
      };
      const raw: string = await httpPost(
        `${Store.I.user}/api/user/tier/generate`, Store.I.token, JSON.stringify(body));
      const res: TierRes = JSON.parse(raw) as TierRes;
      if (res.data === undefined || res.data === null || res.data.tiers === undefined) {
        this.st = ST_OFF;
        this.hint = '';
        return;
      }
      this.applyData(res.data, res.ok === true);
      this.note = res.ok === true ? '' : str(res.reason);
      this.cfgOpen = false;
      this.hint = this.st === ST_OK ? `已生成 · 共 ${this.total} 个` : '';
      if (this.st === ST_EMPTY) {
        promptAction.showToast({ message: '这组条件下没有内容，放宽筛选再试', duration: 1800 });
      }
      // 之前没有「展示中」的那张就顺手把新图设为展示（否则重开页面又跳回老图）；
      // 已经手动锁定过就尊重用户，不抢。
      if (this.st === ST_OK && !this.curPicked && this.curId > 0) {
        const idBody: IdBody = { id: this.curId };
        await httpPost(`${Store.I.user}/api/user/tier/pick`, Store.I.token, JSON.stringify(idBody));
        this.curPicked = true;
      }
      await this.loadHistory();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier/generate: ${e.code} ${e.message}`);
      this.st = ST_OFF;
      this.hint = e.code === 404 ? '服务端还没开 Tier 图（需 1.4.4+）' : '生成失败，请重试';
    } finally {
      this.generating = false;
    }
  }

  // ---- 历史操作 --------------------------------------------------------

  private async pickSnapshot(it: TierSnap): Promise<void> {
    try {
      const body: IdBody = { id: it.id };
      await httpPost(`${Store.I.user}/api/user/tier/pick`, Store.I.token,
        JSON.stringify(body));
      await this.loadCurrent();
      await this.loadHistory();
      this.hint = '已设为展示';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier/pick: ${e.code} ${e.message}`);
      this.hint = '设为展示失败';
    }
  }

  private confirmDelete(it: TierSnap): void {
    promptAction.showDialog({
      title: '删掉这张图？',
      message: `${stamp(it.created_at)} · ${it.summary}`,
      buttons: [
        { text: '取消', color: '#8A8A96' },
        { text: '删除', color: '#E5372B' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        this.deleteSnapshot(it);
      }
    }).catch(() => {
    });
  }

  private async deleteSnapshot(it: TierSnap): Promise<void> {
    try {
      await httpDelete(`${Store.I.user}/api/user/tier/snapshots/${it.id}`, Store.I.token);
      if (this.curId === it.id) {
        await this.loadCurrent();
      }
      await this.loadHistory();
      this.hint = '已删除';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier/delete: ${e.code} ${e.message}`);
      this.hint = '删除失败';
    }
  }

  /**
   * 历史图「下载到本地」：先把这张画到画布区，等一帧后截图，再回到原来那张。
   *
   * 为什么不能直接截：`componentSnapshot` 只能截**已经渲染出来**的节点，
   * 历史列表里没有整张图的内容（列表只给摘要 + 三张缩略图）。
   */
  private async downloadSnapshot(it: TierSnap): Promise<void> {
    if (this.exporting || this.downloadingId > 0) {
      return;
    }
    this.downloadingId = it.id;
    this.hint = '正在准备这张图…';
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/tier/snapshots/${it.id}`, Store.I.token);
      const res: TierRes = JSON.parse(raw) as TierRes;
      if (res.data === undefined || res.data === null) {
        this.hint = '取不到这张图';
        return;
      }
      const keep: TierRow[] = this.tiers;
      const keepTotal: number = this.total;
      const keepId: number = this.curId;
      const keepSummary: string = this.curSummary;
      const keepTitle: string = this.curTitle;
      const keepAt: string = this.curAt;
      const keepPicked: boolean = this.curPicked;
      const keepSt: string = this.st;
      this.applyData(res.data, true);
      // 等渲染落地再截图；260ms 在真机上够一帧，太快会截到上一张
      setTimeout(() => {
        this.exportPng(`tier-${it.id}`).then(() => {
          // 还原：用户看的是「当前图」，不该被一次下载改掉
          this.tiers = keep;
          this.total = keepTotal;
          this.curId = keepId;
          this.curSummary = keepSummary;
          this.curTitle = keepTitle;
          this.curAt = keepAt;
          this.curPicked = keepPicked;
          this.st = keepSt;
          this.boardKey = this.boardKey + 1;
          this.downloadingId = 0;
        }).catch((err: BusinessError) => {
          console.error(`[amane] tier/download export: ${err.code} ${err.message}`);
          this.downloadingId = 0;
        });
      }, 260);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier/download: ${e.code} ${e.message}`);
      this.hint = '下载失败，检查相册权限';
      this.downloadingId = 0;
    }
  }

  // ---- 导出 ------------------------------------------------------------

  /**
   * 截图 → 存相册。
   *
   * 和「截帧存相册」走**同一条已验证的路**（`common/Gallery.ets`）：
   *   1. 打包成 **JPEG**（截帧那条线一直是 jpg，png 走这条路没被验证过）；
   *   2. 落到 **`filesDir/tier`**，不是 `cacheDir` —— 缓存目录交给媒体库时
   *      有拿不到文件的情况（2.5.4.7 的「提示成功但相册里没有」就在这儿）；
   *   3. `Gallery.saveImage` 会把系统返回的媒体 URI 打日志，**返回空数组算失败**，
   *      以前不管返回值一律报「已保存到相册」，用户被提示骗了。
   */
  private async exportPng(name: string): Promise<void> {
    if (this.exporting) {
      return;
    }
    if (this.st !== ST_OK) {
      promptAction.showToast({ message: '先有一张图再导出', duration: 1600 });
      return;
    }
    this.exporting = true;
    this.hint = '正在生成图片…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pm: image.PixelMap = await componentSnapshot.get('tierCanvas');
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 98 });
      packer.release();
      pm.release();
      const bytes: number = buf === undefined || buf === null ? 0 : buf.byteLength;
      console.info(`[amane] tier snapshot bytes=${bytes}`);
      if (bytes < 1024) {
        // 取到空图 / 1×1 就别往相册里塞了，塞进去也是一张看不见的东西
        this.hint = '';
        promptAction.showToast({ message: '截图是空的，重开这一页再试', duration: 2000 });
        return;
      }

      const title: string = `Amane_Tier_${fileStamp()}`;
      const ok: boolean = await Gallery.saveBytes(ctx, buf, title, 'jpg');
      if (!ok) {
        // 相册这条路没走通（用户取消 / 系统没给写权限）→ 让用户自己挑个位置，
        // 文件管理里一定找得到。别在这里假报成功。
        const picked: boolean = await Gallery.saveToPicked(ctx, buf, `${title}.jpg`);
        if (picked) {
          this.hint = '已存到你选的位置';
          promptAction.showToast({ message: '已保存', duration: 1600 });
        } else {
          this.hint = '没有存成';
          promptAction.showToast({ message: '没有存成', duration: 1800 });
        }
        return;
      }
      this.hint = '已存进相册：图库 → 相册 → 所有照片';
      promptAction.showToast({ message: '已保存到相册', duration: 1600 });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] tier export: ${e.code} ${e.message}`);
      this.hint = `没存成（${e.code}）`;
      promptAction.showToast({ message: '没存成，检查一下相册权限', duration: 2000 });
    } finally {
      this.exporting = false;
    }
  }

  // ---- 配色 ------------------------------------------------------------

  /** 五档颜色照经典 tier list 那张图：红 / 橙 / 黄 / 米 / 白。 */
  private tierColor(score: number): string {
    if (score === 5) {
      return '#E5372B';
    }
    if (score === 4) {
      return '#F5B335';
    }
    if (score === 3) {
      return '#FFE227';
    }
    if (score === 2) {
      return '#FBEBCF';
    }
    if (score === 1) {
      return '#F4F4F4';
    }
    return '#A8AEB8';
  }

  private tierInk(score: number): string {
    return score === 5 ? '#FFFFFF' : '#1A1A1A';
  }

  // ---- 视图 ------------------------------------------------------------

  @Builder
  Header() {
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
      Column({ space: 2 }) {
        Text('从夯到拉')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text('按你的星级拍的座次')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text(this.exporting ? '…' : '导出')
        .fontSize(11)
        .fontColor(this.st === ST_OK ? Theme.ON_ACCENT : Theme.TEXT_FAINT)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(this.st === ST_OK ? Theme.ACCENT : Theme.CARD_HI)
        .borderRadius(13)
        .onClick(() => {
          this.exportPng('tier-current');
        })
    }
    .width('100%')
    .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })
  }

  @Builder
  KindChip(k: string) {
    Text(this.kindLabel(k))
      .fontSize(11)
      .fontColor(this.hasKind(k) ? Theme.ON_ACCENT : Theme.TEXT_DIM)
      .padding({ left: 11, right: 11, top: 5, bottom: 5 })
      .backgroundColor(this.hasKind(k) ? Theme.ACCENT : Theme.CARD_HI)
      .borderRadius(12)
      .margin({ right: 6, bottom: 6 })
      .onClick(() => {
        this.toggleKind(k);
      })
  }

  @Builder
  ConfigPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('生成条件')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(this.cfgOpen ? '收起' : '展开')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .onClick(() => {
        this.cfgOpen = !this.cfgOpen;
      })

      if (this.cfgOpen) {
        // 1. 类型（多选）
        Column({ space: 4 }) {
          Text('内容')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(KINDS, (k: string) => {
              this.KindChip(k)
            }, (k: string) => `k-${k}-${this.hasKind(k) ? 1 : 0}`)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // 2. 时间
        Column({ space: 4 }) {
          Text('时间')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
          Row({ space: 6 }) {
            ForEach(['all', '30', '90', 'year'], (key: string) => {
              Text(this.rangeLabel(key))
                .fontSize(10)
                .fontColor(this.rangeKey === key ? Theme.ACCENT : Theme.TEXT_FAINT)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(this.rangeKey === key ? Theme.ACCENT_SOFT : '#00FFFFFF')
                .borderRadius(10)
                .onClick(() => {
                  this.applyRange(key);
                })
            }, (key: string) => `r-${key}-${this.rangeKey === key ? 1 : 0}`)
            Blank()
            if (this.dateFrom.length > 0) {
              Text(`${this.dateFrom.substring(5)} ~ ${this.dateTo.substring(5)}`)
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // 3. 演员性别（只在选了演员时出现）
        if (this.showGender()) {
          Column({ space: 4 }) {
            Text('演员性别')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
            Row({ space: 6 }) {
              ForEach([0, 1, 2], (id: number) => {
                Text(this.genderLabel(id))
                  .fontSize(10)
                  .fontColor(this.genderOf(id) === this.gender ? Theme.ACCENT : Theme.TEXT_FAINT)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor(this.genderOf(id) === this.gender
                    ? Theme.ACCENT_SOFT : '#00FFFFFF')
                  .borderRadius(10)
                  .onClick(() => {
                    this.gender = this.genderOf(id);
                  })
              }, (id: number) => `g-${this.genderUk(id)}`)
              Blank()
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }

        // 4. 图名（留空由服务端按条件 + 分布自动起名）
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('图名')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
            Text('留空自动起名')
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .opacity(0.75)
            Blank()
            if (this.customTitle.length > 0) {
              Text('清空')
                .fontSize(9)
                .fontColor(Theme.ACCENT)
                .onClick(() => {
                  this.customTitle = '';
                })
            }
          }
          .width('100%')

          TextInput({ text: this.customTitle, placeholder: '如：今年的演员：神仙打架' })
            .fontSize(12)
            .fontColor(Theme.TEXT)
            .placeholderFont({ size: 11 })
            .placeholderColor(Theme.TEXT_FAINT)
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(10)
            .height(38)
            .maxLength(40)
            .onChange((v: string) => {
              this.customTitle = v;
            })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // 5. 两个开关
        Row({ space: 16 }) {
          Row({ space: 6 }) {
            Text(this.favoriteOnly ? '☑' : '☐')
              .fontSize(12)
              .fontColor(this.favoriteOnly ? Theme.ACCENT : Theme.TEXT_FAINT)
            Text('只看收藏')
              .fontSize(10)
              .fontColor(Theme.TEXT_DIM)
          }
          .onClick(() => {
            this.favoriteOnly = !this.favoriteOnly;
          })

          Row({ space: 6 }) {
            Text(this.includeUnrated ? '☑' : '☐')
              .fontSize(12)
              .fontColor(this.includeUnrated ? Theme.ACCENT : Theme.TEXT_FAINT)
            Text('带上未评分')
              .fontSize(10)
              .fontColor(Theme.TEXT_DIM)
          }
          .onClick(() => {
            this.includeUnrated = !this.includeUnrated;
          })
          Blank()
          Text('重置')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.resetFilters();
            })
        }
        .width('100%')
      }

      // 5. 一键生成（始终可见：收起条件也要能再生成一张）
      Row() {
        Text(this.generating ? '生成中…' : '一键生成')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ON_ACCENT)
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.ACCENT)
      .borderRadius(21)
      .opacity(this.generating ? 0.6 : 1)
      .onClick(() => {
        this.generate();
      })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
  }

  /** 一格：图（影片竖版 / 其余方块），取不到图画首字。 */
  @Builder
  Cell(it: TierItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (it.image.length > 0) {
        Image(Store.I.img(it.image))
          .width(it.kind === 'film' ? FILM_W : SQUARE)
          .height(it.kind === 'film' ? FILM_H : SQUARE)
          .objectFit(ImageFit.Cover)
          .borderRadius(4)
          .backgroundColor(Theme.CARD_HI)
          .alt($r('app.media.placeholder'))
      } else {
        Column() {
          Text(it.number.length > 0 ? it.number.substring(0, 2)
            : (it.name.length > 0 ? it.name.substring(0, 1) : '?'))
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width(it.kind === 'film' ? FILM_W : SQUARE)
        .height(it.kind === 'film' ? FILM_H : SQUARE)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.CARD_HI)
        .borderRadius(4)
      }
      // 影片在图底盖一条番号：tier 图里光看海报认不出是哪部
      if (it.kind === 'film' && it.number.length > 0) {
        Text(it.number)
          .fontSize(7)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          .backgroundColor('#B3000000')
      }
    }
    .width(it.kind === 'film' ? FILM_W : SQUARE)
    .height(it.kind === 'film' ? FILM_H : SQUARE)
    .borderRadius(4)
    .clip(true)
    .margin({ right: 6 })
  }

  /** 一档：左边色块档名 + 右边一排（横滑）。 */
  @Builder
  TierBand(row: TierRow) {
    Row() {
      Column({ space: 2 }) {
        Text(row.title)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.tierInk(row.score))
          .textAlign(TextAlign.Center)
          .maxLines(2)
        Text(row.more > 0 ? `${row.items.length}+${row.more}` : `${row.items.length}`)
          .fontSize(9)
          .fontColor(this.tierInk(row.score))
          .opacity(0.7)
      }
      .width(LABEL_W)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.tierColor(row.score))

      if (row.items.length > 0) {
        Scroll() {
          Row() {
            ForEach(row.items, (it: TierItem) => {
              this.Cell(it)
            }, (it: TierItem) => `c-${row.score}-${it.kind}-${it.id}-${this.boardKey}`)
            Blank()
          }
          .height('100%')
          .padding({ left: 8, right: 8 })
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .height('100%')
        .align(Alignment.Start)
      } else {
        Row() {
          Text('这一档还没有')
            .fontSize(10)
            .fontColor('#9A9A9A')
        }
        .layoutWeight(1)
        .height('100%')
        .padding({ left: 12 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height(ROW_H)
    // 每档右侧是「白里泛灰」的底色（用户 2026-11-12 定），左侧色块盖在上面
    .backgroundColor('#E9E9E9')
    .borderRadius(8)
    .clip(true)
  }

  @Builder
  Board() {
    Column({ space: 0 }) {
      if (this.st === ST_OK) {
        Column({ space: 3 }) {
          ForEach(this.tiers, (row: TierRow) => {
            this.TierBand(row)
          }, (row: TierRow) => `b-${row.score}-${row.items.length}-${row.more}-${this.boardKey}`)
        }
        .width('100%')
      } else if (this.st === ST_LOADING) {
        Column() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .height(160)
        .justifyContent(FlexAlign.Center)
      } else if (this.st === ST_OFF) {
        Column({ space: 6 }) {
          Text(this.note.length > 0 ? this.note : '服务端还没开 Tier 图')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
            .textAlign(TextAlign.Center)
          Text('需要 1.4.4 以上的服务端；这一版页面已经就位')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height(160)
        .justifyContent(FlexAlign.Center)
      } else if (this.st === ST_EMPTY) {
        Column({ space: 6 }) {
          Text('这张图是空的')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
          Text('给几部片打分，或放宽上面的条件再点「一键生成」')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height(160)
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 6 }) {
          Text('还没生成')
            .fontSize(12)
            .fontColor(Theme.TEXT_DIM)
          Text('选好条件点「一键生成」，会立刻按星级排给你看')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
        }
        .width('100%')
        .height(160)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  CurrentBlock() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.curTitle.length > 0 ? this.curTitle : '这一张')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.curPicked) {
          Text('展示中')
            .fontSize(9)
            .fontColor(Theme.ACCENT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(4)
        }
        Text(this.curAt.length > 0 ? stamp(this.curAt) : '')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')

      if (this.curSummary.length > 0) {
        Text(this.curSummary)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // 导出就是截这块 —— id 别改，改了导出会截到空。
      // 标题也在这块里：勾了「导出带标题」时才会画，所以屏幕上看就是你将拿到的那张图。
      Column({ space: 6 }) {
        if (this.exportWithTitle && this.curTitle.length > 0) {
          Text(this.curTitle)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111111')
            .textAlign(TextAlign.Center)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: 2, left: 6, right: 6 })
        }
        this.Board()
      }
      .id('tierCanvas')
      .width('100%')
      .padding(10)
      // 白里泛灰的底板：截图/相册里这张图才像一张 tier 图（深色底下会糊成一团）
      .backgroundColor('#F2F2F2')
      .borderRadius(14)

      // 导出选项：默认带标题（黑体居中），不要就点掉
      Row({ space: 6 }) {
        Text(this.exportWithTitle ? '☑' : '☐')
          .fontSize(12)
          .fontColor(this.exportWithTitle ? Theme.ACCENT : Theme.TEXT_FAINT)
        Text('导出时带上标题')
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
        Text('黑体居中，只影响存到相册的图')
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
          .opacity(0.8)
        Blank()
      }
      .width('100%')
      .onClick(() => {
        this.exportWithTitle = !this.exportWithTitle;
      })
    }
    .width('100%')
  }

  @Builder
  HistoryRow(it: TierSnap) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        // 三张缩略图叠着放：一眼能认出是哪一张
        Row({ space: 3 }) {
          ForEach(it.thumbs.slice(0, 3), (p: string, i: number) => {
            Image(Store.I.img(p))
              .width(30)
              .height(30)
              .objectFit(ImageFit.Cover)
              .borderRadius(5)
              .backgroundColor(Theme.CARD_HI)
              .alt($r('app.media.placeholder'))
          }, (p: string, i: number) => `h-${it.id}-${i}`)
        }
        .width(96)
        .height(30)

        Column({ space: 3 }) {
          Row({ space: 5 }) {
            Text(it.title.length > 0 ? it.title : stamp(it.created_at))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (it.picked) {
              Text('展示中')
                .fontSize(8)
                .fontColor(Theme.ACCENT)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .backgroundColor(Theme.ACCENT_SOFT)
                .borderRadius(3)
            }
          }
          .width('100%')
          Text(`${stamp(it.created_at)} · ${it.summary}`)
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.downloadingId === it.id ? '准备中…' : '下载')
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.ACCENT_SOFT)
          .borderRadius(11)
          .onClick(() => {
            this.downloadSnapshot(it);
          })
        if (!it.picked) {
          Text('设为展示')
            .fontSize(10)
            .fontColor(Theme.TEXT_DIM)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(11)
            .onClick(() => {
              this.pickSnapshot(it);
            })
        }
        Blank()
        Text('删除')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick(() => {
            this.confirmDelete(it);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.CARD)
    .borderRadius(12)
    .border({ width: this.curId === it.id ? 1 : 0, color: Theme.ACCENT })
  }

  @Builder
  HistoryBlock() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('历史生成')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Text(`${this.hist.length}`)
          .fontSize(9)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        if (this.histLoading) {
          Text('刷新中…')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
        }
      }
      .width('100%')

      if (this.hist.length === 0) {
        Text(this.histLoading ? '正在读历史…' : '还没有历史。生成过的图会留在这里，可随时下载或切回。')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.hist, (it: TierSnap) => {
          this.HistoryRow(it)
        }, (it: TierSnap) => `s-${it.id}-${it.picked ? 1 : 0}-${this.curId === it.id ? 1 : 0}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 12 }) {
          this.ConfigPanel()
          this.CurrentBlock()
          this.HistoryBlock()

          if (this.hint.length > 0) {
            Text(this.hint)
              .fontSize(9)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
          }

          Text('每次生成都会存一张快照：之后改评分不会改已存的老图，要更新就再点一次生成。')
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .width('100%')
            .padding({ bottom: 24 })
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
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
