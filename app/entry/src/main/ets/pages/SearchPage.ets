import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpDelete, httpGet, httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { BuildConfig } from '../common/BuildConfig';
import {
  BrowseResult, DetailParams, MediaItem, SearchHistoryItem, SearchHistoryList, SuggestItem, SuggestResult,
  SuggestTotals, emptySuggestTotals
} from '../common/Types';
import { safeItems, safeSearchHistory, safeSuggestResult } from '../common/Safe';
import {
  AGE_BANDS, MYRATING_OPTIONS, PREF_AGE_GENDER, SORT_OPTIONS, ChipOption, SortOption,
  ageBandParams, ageGenderParam, sortLabelWith
} from '../common/BrowseOptions';
import { CollectionInfo, fetchCollections } from '../ext/collections/CollectionTypes';
import { PosterCard } from '../view/PosterCard';

/** 联想 / 搜索可选的类型，顺序即 chip 顺序、也是结果分组顺序。 */
const ALL_KINDS: string[] = ['film', 'actor', 'director', 'tag', 'series', 'studio'];
/** 除影片以外的实体类型：它们点了进的是各自的列表页，不是影片详情。 */
const ENTITY_KINDS: string[] = ['actor', 'director', 'tag', 'series', 'studio'];
/** 范围偏好存这里：上次选了哪几类，下次进搜索页沿用。 */
const KEY_SCOPE: string = 'search_scope';
/** 混搜时影片在联想里最多占几行（其余靠「看全部」进结果页）。 */
const FILM_SUG_CAP: number = 4;
/** 搜索历史在空态里最多显示几条（服务端存 30 条，这里只铺一屏够用的）。 */
const HISTORY_SHOW: number = 12;

interface KindOption {
  key: string;
  label: string;
}

/** 联想结果的分组：同一类的行放一块，省的在一长条里认类型。 */
interface SuggestGroup {
  key: string;
  label: string;
  total: number;
  items: SuggestItem[];
  /** 还有没显示完的：影片被截断时给「看全部」入口。 */
  more: boolean;
}

/**
 * 跳转参数自己声明：核心页面不 import 可插拔扩展里的类型，
 * 关掉扩展时这里也不该跟着红。形状与 ActorParams / FacetParams 一致。
 */
interface ActorNavParams {
  id: number;
  name: string;
}

interface FacetNavParams {
  kind: string;
  id: number;
  name: string;
}

/** /api/user/ping 的响应（只用版本号）。 */
interface PingInfo {
  ok: boolean;
  version: string;
  time: string;
}

function kindLabel(kind: string): string {
  if (kind === 'actor') {
    return '演员';
  }
  if (kind === 'director') {
    return '导演';
  }
  if (kind === 'tag') {
    return '标签';
  }
  if (kind === 'series') {
    return '系列';
  }
  if (kind === 'studio') {
    return '制片商';
  }
  return '影片';
}

/** 联想档位的中文名：服务端按 tier 排好序，这里只管贴标签。 */
function tierLabel(tier: number): string {
  if (tier === 1) {
    return '精确';
  }
  if (tier === 2) {
    return '相关';
  }
  return '更多';
}

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State items: MediaItem[] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State sugs: SuggestItem[] = [];
  /** 各实体类型的命中总数（服务端 totals），分组标题上的「共 N」用它。 */
  @State totals: SuggestTotals = emptySuggestTotals();
  /** 服务端真正支持的类型；首帧还不知道，capsKnown=false 时不灰任何 chip。 */
  @State supported: string[] = [];
  @State capsKnown: boolean = false;
  /** 老服务端（不认识 types）——只可能回影片，给一条橙色说明。 */
  @State legacy: boolean = false;
  /**
   * 老服务端时连的是哪个地址、它自报什么版本。
   * 「服务端版本不够」这种提示如果不写地址，最容易白折腾：用户改了 8771，
   * 但 App 实际还在打 8770 / 外网域名（`no supported` 只看得到现象看不到是谁）。
   */
  @State legacyAddr: string = '';
  @State legacyVer: string = '';
  /** 本次搜索范围（多选）：film / actor / director / tag / series / studio。 */
  @State scope: string[] = ALL_KINDS.slice(0);
  /** 结果页顶部的实体命中（演员 / 分类），点进去是对应的列表页。 */
  @State ents: SuggestItem[] = [];
  /** 搜索历史（服务端存的，重装/换设备都还在）。 */
  @State hist: SearchHistoryItem[] = [];
  /** 「清空」要点两次：第一次把文案换成确认词，3 秒内没再点就恢复。 */
  @State confirmClear: boolean = false;
  /** 结果条件：出演年龄分桶 / 我的评分 / 收藏夹 + 排序，key 与媒体库共用一份。 */
  @State fAge: string = '';
  /** 出演年龄看哪个性别：female（默认）/ male，与媒体库、详情页共用一份偏好。 */
  @State fAgeGender: string = 'female';
  @State fMyRating: string = '';
  @State fCollection: string = '';
  @State collectionChips: ChipOption[] = [];
  @State sort: string = 'recent';
  @State order: string = 'desc';
  private seq: number = 0;
  private sugSeq: number = 0;
  private sugTimer: number = -1;
  private clearTimer: number = -1;

  aboutToAppear(): void {
    this.loadHistory();
    this.loadCollections();
    this.fAgeGender = Store.I.prefString(PREF_AGE_GENDER, 'female');
    const saved: string = Store.I.prefString(KEY_SCOPE, '');
    if (saved.length === 0) {
      return;
    }
    const picked: string[] = [];
    const parts: string[] = saved.split(',');
    for (let i = 0; i < parts.length; i++) {
      const key: string = parts[i].trim();
      if (ALL_KINDS.indexOf(key) >= 0 && picked.indexOf(key) < 0 && this.kindEnabled(key)) {
        picked.push(key);
      }
    }
    if (picked.length > 0) {
      this.scope = picked;
    }
  }

  aboutToDisappear(): void {
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
  }

  /** 这个类型在当前包里有没有对应扩展（public 通道两扩展都开，自用两条也都开）。 */
  private kindEnabled(kind: string): boolean {
    if (kind === 'actor') {
      return BuildConfig.ENABLE_ACTORS;
    }
    if (kind === 'film') {
      return true;
    }
    return BuildConfig.ENABLE_FACETS;
  }

  private filmOn(): boolean {
    return this.scope.indexOf('film') >= 0;
  }

  private entKinds(): string[] {
    const out: string[] = [];
    for (let i = 0; i < ENTITY_KINDS.length; i++) {
      if (this.scope.indexOf(ENTITY_KINDS[i]) >= 0) {
        out.push(ENTITY_KINDS[i]);
      }
    }
    return out;
  }

  private kindOptions(): KindOption[] {
    const out: KindOption[] = [];
    for (let i = 0; i < ALL_KINDS.length; i++) {
      const key: string = ALL_KINDS[i];
      if (this.kindEnabled(key)) {
        out.push({ key: key, label: kindLabel(key) });
      }
    }
    return out;
  }

  /** 服务端明确说了没有的类型：chip 灰掉、点了给提示，别让人以为筛过了。 */
  private offKind(key: string): boolean {
    if (!this.capsKnown || key === 'film') {
      return false;
    }
    return this.supported.indexOf(key) < 0;
  }

  /**
   * 多选范围：点一下切换，至少留一项（全取消等于没有搜索对象）。
   * 改完立刻作废在飞的联想与结果，并重跑当前关键词。
   */
  private toggleKind(key: string): void {
    if (this.offKind(key)) {
      promptAction.showToast({
        message: this.legacy
          ? `服务端 ${this.legacyVer.length > 0 ? this.legacyVer : '版本偏低'} 只支持影片联想，升级到 1.3.12+ 后可用`
          : `服务端没开「${kindLabel(key)}」搜索，装好对应扩展后可用`,
        duration: 2000
      });
      return;
    }
    const idx: number = this.scope.indexOf(key);
    if (idx >= 0) {
      if (this.scope.length <= 1) {
        promptAction.showToast({ message: '至少保留一项搜索范围', duration: 1500 });
        return;
      }
      const next: string[] = this.scope.slice(0);
      next.splice(idx, 1);
      this.scope = next;
    } else {
      const next: string[] = this.scope.slice(0);
      next.push(key);
      next.sort((a: string, b: string) => ALL_KINDS.indexOf(a) - ALL_KINDS.indexOf(b));
      this.scope = next;
    }
    Store.I.prefSetString(KEY_SCOPE, this.scope.join(','));
    this.reflow();
  }

  /** 范围变了：已经显示的结果 / 联想全部按新范围重来。 */
  private reflow(): void {
    this.seq++;
    this.loading = false;
    this.searched = false;
    this.ents = [];
    const text: string = this.keyword.trim();
    if (text.length === 0) {
      return;
    }
    this.suggest(text);
  }

  /**
   * 搜索联想：输入即搜，不等点按钮。
   * 防抖 300ms；服务端按「精确 → 相关 → 扩大」三档递进返回，
   * 准确的排前面，没有准确的才弹模糊的，模糊不够就再扩大范围。
   * `types` 是这次勾选的类型，影片和演员 / 分类可以同时要。
   */
  private onKeyword(value: string): void {
    this.keyword = value;
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    // 关键词一改，上一次的结果就过期了：在飞的请求按 seq 作废，
    // 否则它回来以后会把「搜索结果」又铺回去，把联想列表顶掉。
    this.seq++;
    this.searched = false;
    this.loading = false;

    const text: string = value.trim();
    if (text.length === 0) {
      this.sugs = [];
      this.totals = emptySuggestTotals();
      return;
    }
    this.sugTimer = setTimeout(() => {
      this.sugTimer = -1;
      this.suggest(text);
    }, 300);
  }

  /** 服务端能力对齐：老服务端只回影片，扩展关掉的类型从范围里摘掉。 */
  private applyCaps(r: SuggestResult): void {
    this.legacy = r.legacy;
    if (r.legacy) {
      // 老服务端只有影片这一类：把 chip 也灰掉，别让人以为「勾了但没生效」
      this.capsKnown = true;
      this.supported = ['film'];
      if (this.scope.indexOf('film') < 0 || this.scope.length > 1) {
        this.scope = ['film'];
      }
      if (this.legacyAddr.length === 0) {
        this.legacyAddr = Store.I.user;
        this.probeVersion();
      }
      return;
    }
    this.capsKnown = true;
    this.supported = r.supported;
    const kept: string[] = [];
    for (let i = 0; i < this.scope.length; i++) {
      const key: string = this.scope[i];
      if (key === 'film' || r.supported.indexOf(key) >= 0) {
        kept.push(key);
      }
    }
    if (kept.length > 0 && kept.length !== this.scope.length) {
      this.scope = kept;
      Store.I.prefSetString(KEY_SCOPE, kept.join(','));
    }
  }

  /** 老服务端才问一次版本号：提示里写清「打到哪台、几版」，省得以为是客户端坏了。 */
  private async probeVersion(): Promise<void> {
    try {
      const raw: string = await httpGet(`${Store.I.user}/api/user/ping`, Store.I.token);
      const data = JSON.parse(raw) as PingInfo;
      const ver: string = data.version === undefined || data.version === null ? '' : data.version;
      if (ver.length > 0) {
        this.legacyVer = ver;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] ping: ${e.code} ${e.message}`);
    }
  }

  private async suggest(text: string): Promise<void> {
    this.sugSeq++;
    const mine: number = this.sugSeq;
    try {
      const url: string = `${Store.I.user}/api/user/suggest?q=${encodeURIComponent(text)}`
        + `&types=${this.scope.join(',')}&per=3`;
      const raw: string = await httpGet(url, Store.I.token);
      if (mine !== this.sugSeq) {
        return; // 已有更新的输入，丢弃过期结果
      }
      const result: SuggestResult = safeSuggestResult(JSON.parse(raw) as SuggestResult);
      this.applyCaps(result);
      this.sugs = result.items;
      this.totals = result.totals;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] suggest: ${e.code} ${e.message}`);
    }
  }

  /** 收藏夹筛选项来自 collections 扩展；关掉扩展时整行不显示，条件也别带出去。 */
  private async loadCollections(): Promise<void> {
    if (!BuildConfig.ENABLE_COLLECTIONS) {
      return;
    }
    try {
      const lists: CollectionInfo[] = await fetchCollections();
      const opts: ChipOption[] = [
        { key: '', label: '全部' },
        { key: 'none', label: '未归类' }
      ];
      for (let i = 0; i < lists.length; i++) {
        opts.push({ key: `${lists[i].id}`, label: lists[i].name });
      }
      this.collectionChips = opts;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] search collections: ${e.code} ${e.message}`);
    }
  }

  /** 条件改了：已经在结果页就立刻按新条件重搜；还在联想态就留到下次点「搜索」。 */
  private rerun(): void {
    const q: string = this.keyword.trim();
    if (this.searched && q.length > 0) {
      this.search(q);
    }
  }

  /**
   * 完整结果：勾了影片就去 browse 拉网格；勾了实体再单独拉一遍联想接口
   * （那次只带实体类型，per 放宽到 8，够结果页顶部横条用）。
   */
  private async search(text: string): Promise<void> {
    const query: string = text.trim();
    if (query.length === 0) {
      this.items = [];
      this.ents = [];
      this.searched = false;
      return;
    }
    this.seq++;
    const mine: number = this.seq;
    this.loading = true;
    const kinds: string[] = this.entKinds();
    try {
      if (this.filmOn()) {
        const parts: string[] = [
          `q=${encodeURIComponent(query)}`, `limit=60`,
          `sort=${this.sort}`, `order=${this.order}`
        ];
        const ageParts: string[] = ageBandParams(this.fAge);
        for (let i = 0; i < ageParts.length; i++) {
          parts.push(ageParts[i]);
        }
        // 性别只在用到年龄时带上（区间筛选或按年龄排序）。
        if (this.fAge.length > 0 || this.sort === 'cast_age') {
          parts.push(ageGenderParam(this.fAgeGender));
        }
        if (this.fMyRating.length > 0) {
          parts.push(`myrating=${this.fMyRating}`);
        }
        if (this.fCollection.length > 0) {
          parts.push(`collection=${this.fCollection}`);
        }
        const url: string = `${Store.I.user}/api/user/browse?${parts.join('&')}`;
        const raw: string = await httpGet(url, Store.I.token);
        if (mine !== this.seq) {
          return;
        }
        const result: BrowseResult = JSON.parse(raw) as BrowseResult;
        this.items = safeItems(result.items);
        this.total = result.total === undefined || result.total === null ? this.items.length : result.total;
      } else {
        this.items = [];
        this.total = 0;
      }
      if (kinds.length > 0) {
        const url: string = `${Store.I.user}/api/user/suggest?q=${encodeURIComponent(query)}`
          + `&types=${kinds.join(',')}&per=8`;
        const raw: string = await httpGet(url, Store.I.token);
        if (mine !== this.seq) {
          return;
        }
        this.ents = safeSuggestResult(JSON.parse(raw) as SuggestResult).items;
      } else {
        this.ents = [];
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] search: ${e.code} ${e.message}`);
    }
    this.loading = false;
    this.searched = true;
  }

  /** 点「搜索」按钮或回车：切到完整结果，联想列表退场。 */
  private commitSearch(): void {
    if (this.sugTimer >= 0) {
      clearTimeout(this.sugTimer);
      this.sugTimer = -1;
    }
    const q: string = this.keyword.trim();
    if (q.length === 0) {
      return;
    }
    this.recordHistory(q);
    this.search(q);
  }

  // ---- 搜索历史 ---------------------------------------------------------

  private async loadHistory(): Promise<void> {
    try {
      const raw: string = await httpGet(
        `${Store.I.user}/api/user/search/history?limit=12`, Store.I.token);
      this.hist = safeSearchHistory(JSON.parse(raw) as SearchHistoryList);
    } catch (err) {
      // 老服务端没有这个接口（404）：历史区块就不出现，不影响搜索本身
      const e = err as BusinessError;
      console.error(`[amane] search history: ${e.code} ${e.message}`);
    }
  }

  /**
   * 记一条搜索：本地先插到最前（点完立刻能看到），再交给服务端落库。
   * 落库成功后再拉一次，把服务端的排序 / 次数同步回来；失败就保持本地这份。
   */
  private recordHistory(q: string): void {
    const next: SearchHistoryItem[] = [];
    for (let i = 0; i < this.hist.length; i++) {
      if (this.hist[i].q !== q) {
        next.push(this.hist[i]);
      }
    }
    const head: SearchHistoryItem = { q: q, hits: 1, usedAt: '' };
    next.unshift(head);
    this.hist = next.slice(0, HISTORY_SHOW);
    httpPost(`${Store.I.user}/api/user/search/history`, Store.I.token, JSON.stringify({ q: q }))
      .then(() => {
        this.loadHistory();
      })
      .catch((err: BusinessError) => {
        console.error(`[amane] search history add: ${err.code} ${err.message}`);
      });
  }

  private delHistory(q: string): void {
    const next: SearchHistoryItem[] = [];
    for (let i = 0; i < this.hist.length; i++) {
      if (this.hist[i].q !== q) {
        next.push(this.hist[i]);
      }
    }
    this.hist = next;
    httpDelete(`${Store.I.user}/api/user/search/history?q=${encodeURIComponent(q)}`, Store.I.token)
      .catch((err: BusinessError) => {
        console.error(`[amane] search history del: ${err.code} ${err.message}`);
      });
  }

  /** 清空要两下：这类操作没有撤销，一次误触把历史全清掉很恼人。 */
  private onClear(): void {
    if (!this.confirmClear) {
      this.confirmClear = true;
      if (this.clearTimer >= 0) {
        clearTimeout(this.clearTimer);
      }
      this.clearTimer = setTimeout(() => {
        this.confirmClear = false;
        this.clearTimer = -1;
      }, 4000);
      return;
    }
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
    this.confirmClear = false;
    this.hist = [];
    httpDelete(`${Store.I.user}/api/user/search/history`, Store.I.token)
      .catch((err: BusinessError) => {
        console.error(`[amane] search history clear: ${err.code} ${err.message}`);
      });
  }

  /** 点历史词：填回搜索框并直接搜。 */
  private useHistory(q: string): void {
    this.keyword = q;
    this.commitSearch();
  }

  private openDetail(id: number): void {
    const params: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: params });
  }

  /** 联想 / 结果里的实体行：演员进作品列表，分类进分类影片墙。 */
  private openEntity(item: SuggestItem): void {
    if (item.type === 'actor') {
      const actor: ActorNavParams = { id: item.id, name: item.name };
      router.pushUrl({ url: 'ext/actors/ActorWorksPage', params: actor });
      return;
    }
    const facet: FacetNavParams = { kind: item.type, id: item.id, name: item.name };
    router.pushUrl({ url: 'ext/facets/FacetPage', params: facet });
  }

  private openSug(item: SuggestItem): void {
    if (item.type === 'film') {
      this.openDetail(item.id);
      return;
    }
    this.openEntity(item);
  }

  /**
   * 实体行的副标题：`演员 · 49 部`，按别名命中时补一句 `· 别名 蕾`。
   * 不写的话，搜「蕾」突然冒出个「つぼみ」，人会以为匹配错了。
   */
  private entSub(item: SuggestItem): string {
    const base: string = `${kindLabel(item.type)} · ${item.count} 部`;
    if (item.alias.length > 0 && item.alias !== item.name) {
      return `${base} · 别名 ${item.alias}`;
    }
    return base;
  }

  /** 按类型分组；服务端的 items 是「影片在前、实体按类型排」，这里重新分堆。 */
  private sugGroups(): SuggestGroup[] {
    const out: SuggestGroup[] = [];
    for (let i = 0; i < ALL_KINDS.length; i++) {
      const kind: string = ALL_KINDS[i];
      const bucket: SuggestItem[] = [];
      for (let j = 0; j < this.sugs.length; j++) {
        if (this.sugs[j].type === kind) {
          bucket.push(this.sugs[j]);
        }
      }
      if (bucket.length === 0) {
        continue;
      }
      let total: number = bucket.length;
      if (kind === 'actor') {
        total = this.totals.actor;
      } else if (kind === 'director') {
        total = this.totals.director;
      } else if (kind === 'tag') {
        total = this.totals.tag;
      } else if (kind === 'series') {
        total = this.totals.series;
      } else if (kind === 'studio') {
        total = this.totals.studio;
      }
      out.push({
        key: kind, label: kindLabel(kind), total: total > 0 ? total : bucket.length,
        items: bucket, more: false
      });
    }

    // 混搜时影片最多占 4 行：搜「三上」能命中十几部片，全铺开的话
    // 演员 / 标签分组会被挤到键盘下面去，等于这一轮新加的联想白做。
    let hasEntity: boolean = false;
    for (let i = 0; i < out.length; i++) {
      if (out[i].key !== 'film') {
        hasEntity = true;
      }
    }
    if (hasEntity) {
      for (let i = 0; i < out.length; i++) {
        if (out[i].key === 'film' && out[i].items.length > FILM_SUG_CAP) {
          out[i] = {
            key: 'film', label: out[i].label, total: out[i].total,
            items: out[i].items.slice(0, FILM_SUG_CAP), more: true
          };
        }
      }
    }
    return out;
  }

  @Builder
  ScopeBar() {
    Row({ space: 6 }) {
      Text('范围')
        .fontSize(10)
        .fontColor(Theme.TEXT_FAINT)
      ForEach(this.kindOptions(), (opt: KindOption) => {
        Text(opt.label)
          .fontSize(11)
          .fontWeight(this.scope.indexOf(opt.key) >= 0 ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.offKind(opt.key) ? Theme.TEXT_FAINT
            : (this.scope.indexOf(opt.key) >= 0 ? '#FFFFFF' : Theme.TEXT_DIM))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.offKind(opt.key) ? Theme.BG_RAISED
            : (this.scope.indexOf(opt.key) >= 0 ? Theme.ACCENT : Theme.CARD))
          .borderRadius(11)
          .opacity(this.offKind(opt.key) ? 0.55 : 1)
          .onClick(() => {
            this.toggleKind(opt.key);
          })
      }, (opt: KindOption) => `sk-${opt.key}-${this.scope.indexOf(opt.key) >= 0 ? 1 : 0}`)
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
  }

  /**
   * 结果条件条：出演年龄分桶 + 排序。常驻而不藏进面板 —— 搜索页本就是
   * 「给定关键词再看范围」，条件看得见才不会以为筛了没生效。
   * key 全部取自 common/BrowseOptions，和媒体库筛选 / 详情页点岁数是同一套；
   * 年龄前面的「♀ 女优 / ♂ 男优」是性别开关，默认女优。
   */
  @Builder
  FilterBar() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        // 点它换性别：这个功能是给女演员做的，默认女优；符号 + 文字一起给，
        // 免得「女优」被看成年龄档位。与详情页徽章、媒体库筛选共用同一份偏好。
        Text(this.fAgeGender === 'male' ? '♂ 男优' : '♀ 女优')
          .fontSize(10)
          .fontColor(Theme.TEXT_DIM)
          .width(46)
          .height(24)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.CARD)
          .borderRadius(9)
          .onClick(() => {
            this.fAgeGender = this.fAgeGender === 'male' ? 'female' : 'male';
            Store.I.prefSetString(PREF_AGE_GENDER, this.fAgeGender);
            this.rerun();
          })
        Scroll() {
          Row({ space: 6 }) {
            ForEach(AGE_BANDS, (opt: ChipOption) => {
              Text(opt.label)
                .fontSize(11)
                .fontColor(this.fAge === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.fAge === opt.key ? Theme.ACCENT : Theme.CARD)
                .borderRadius(11)
                .onClick(() => {
                  this.fAge = opt.key;
                  this.rerun();
                })
            }, (opt: ChipOption) => `sa-${opt.key}-${this.fAge === opt.key ? 1 : 0}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(30)
        .layoutWeight(1)
        .align(Alignment.Start)
      }
      .width('100%')

      if (BuildConfig.ENABLE_RATINGS) {
        Row({ space: 6 }) {
          Text('评分')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width(28)
          Scroll() {
            Row({ space: 6 }) {
              ForEach(MYRATING_OPTIONS, (opt: ChipOption) => {
                Text(opt.label)
                  .fontSize(11)
                  .fontColor(this.fMyRating === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.fMyRating === opt.key ? Theme.ACCENT : Theme.CARD)
                  .borderRadius(11)
                  .onClick(() => {
                    this.fMyRating = opt.key;
                    this.rerun();
                  })
              }, (opt: ChipOption) => `sr-${opt.key}-${this.fMyRating === opt.key ? 1 : 0}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .height(30)
          .layoutWeight(1)
          .align(Alignment.Start)
        }
        .width('100%')
      }

      if (BuildConfig.ENABLE_COLLECTIONS && this.collectionChips.length > 0) {
        Row({ space: 6 }) {
          Text('清单')
            .fontSize(10)
            .fontColor(Theme.TEXT_FAINT)
            .width(28)
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.collectionChips, (opt: ChipOption) => {
                Text(opt.label)
                  .fontSize(11)
                  .fontColor(this.fCollection === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.fCollection === opt.key ? Theme.ACCENT : Theme.CARD)
                  .borderRadius(11)
                  .onClick(() => {
                    this.fCollection = opt.key;
                    this.rerun();
                  })
              }, (opt: ChipOption) => `sc-${opt.key}-${this.fCollection === opt.key ? 1 : 0}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .height(30)
          .layoutWeight(1)
          .align(Alignment.Start)
        }
        .width('100%')
      }

      Row({ space: 6 }) {
        Text('排序')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
          .width(28)
        Scroll() {
          Row({ space: 6 }) {
            ForEach(SORT_OPTIONS, (opt: SortOption) => {
              Text(`${sortLabelWith(opt.key, this.fAgeGender)}${this.sort === opt.key && opt.key !== 'random' ? (this.order === 'asc' ? ' ↑' : ' ↓') : ''}`)
                .fontSize(11)
                .fontColor(this.sort === opt.key ? '#FFFFFF' : Theme.TEXT_DIM)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.sort === opt.key ? Theme.ACCENT : Theme.CARD)
                .borderRadius(11)
                .onClick(() => {
                  if (this.sort === opt.key && opt.key !== 'random') {
                    this.order = this.order === 'asc' ? 'desc' : 'asc';
                  } else {
                    this.sort = opt.key;
                    this.order = opt.def;
                  }
                  this.rerun();
                })
            }, (opt: SortOption) => `ss-${opt.key}-${this.sort === opt.key ? this.order : ''}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(30)
        .layoutWeight(1)
        .align(Alignment.Start)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 6 })
  }

  /** 一行三段的通用行：左缩略图 / 中两行文字 / 右箭头。影片与实体共用。 */
  @Builder
  SugRow(item: SuggestItem) {
    Row({ space: 10 }) {
      if (item.type === 'film') {
        Image(Store.I.img(item.poster))
          .width(38)
          .height(54)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .backgroundColor(Theme.CARD)
          .alt($r('app.media.placeholder'))
      } else if (item.image.length > 0) {
        Image(Store.I.img(item.image))
          .width(44)
          .height(44)
          .objectFit(ImageFit.Cover)
          .borderRadius(item.type === 'actor' ? 22 : 8)
          .backgroundColor(Theme.CARD_HI)
      } else {
        // 没有头像 / 封面时给个首字块：不留空洞，也还能认人
        Text(item.name.length > 0 ? item.name.substring(0, 1) : '·')
          .fontSize(16)
          .fontColor(Theme.TEXT_DIM)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(item.type === 'actor' ? 22 : 8)
      }

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(item.type === 'film'
            ? (item.number.length > 0 ? item.number : '未知番号')
            : (item.name.length > 0 ? item.name : '未命名'))
            .fontSize(item.type === 'film' ? 12 : 13)
            .fontWeight(FontWeight.Medium)
            .fontColor(item.type === 'film' ? Theme.ACCENT : Theme.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
          Text(item.type === 'film' ? tierLabel(item.tier) : kindLabel(item.type))
            .fontSize(9)
            .fontColor(Theme.TEXT_FAINT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.CARD_HI)
            .borderRadius(4)
        }
        Text(item.type === 'film'
          ? (item.title.length > 0 ? item.title : ' ')
          : this.entSub(item))
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(16)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Theme.CARD)
    .borderRadius(10)
    .onClick(() => {
      this.openSug(item);
    })
  }

  @Builder
  GroupHeader(group: SuggestGroup) {
    Row({ space: 6 }) {
      Text(group.label)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_DIM)
      if (group.total > group.items.length) {
        Text(`共 ${group.total}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      Blank()
      if (group.more) {
        Text('看全部 →')
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.commitSearch();
          })
      } else if (group.key !== 'film') {
        Text('每一条都能点进列表 →')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
    }
    .width('100%')
    .padding({ left: 2, right: 2, top: 4, bottom: 2 })
  }

  @Builder
  SuggestList() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('联想结果')
          .fontSize(12)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
        Text(`搜索「${this.keyword.trim()}」→`)
          .fontSize(11)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.commitSearch();
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      List({ space: 6 }) {
        ForEach(this.sugGroups(), (group: SuggestGroup) => {
          ListItem() {
            this.GroupHeader(group)
          }
          ForEach(group.items, (item: SuggestItem) => {
            ListItem() {
              this.SugRow(item)
            }
          }, (item: SuggestItem) => `sug-${group.key}-${item.id}`)
        }, (group: SuggestGroup) => `sg-${group.key}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 结果页顶部的实体横条：不抢影片网格的位置，点一项进对应列表。 */
  @Builder
  EntStrip() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('演员 / 分类')
          .fontSize(11)
          .fontColor(Theme.TEXT_DIM)
        Blank()
        Text('点一项进列表 →')
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })

      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.ents, (item: SuggestItem) => {
            Column({ space: 5 }) {
              if (item.image.length > 0) {
                Image(Store.I.img(item.image))
                  .width(44)
                  .height(44)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(item.type === 'actor' ? 22 : 9)
                  .backgroundColor(Theme.CARD_HI)
              } else {
                Text(item.name.length > 0 ? item.name.substring(0, 1) : '·')
                  .fontSize(16)
                  .fontColor(Theme.TEXT_DIM)
                  .width(44)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(Theme.CARD_HI)
                  .borderRadius(item.type === 'actor' ? 22 : 9)
              }
              Text(item.name)
                .fontSize(11)
                .fontColor(Theme.TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(72)
                .textAlign(TextAlign.Center)
              Text(`${kindLabel(item.type)} · ${item.count}`)
                .fontSize(9)
                .fontColor(Theme.TEXT_FAINT)
                .maxLines(1)
                .width(72)
                .textAlign(TextAlign.Center)
            }
            .width(72)
            .onClick(() => {
              this.openEntity(item);
            })
          }, (item: SuggestItem) => `ent-${item.type}-${item.id}`)
        }
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      // 必须给高度：外层 Column 高度有限，Scroll 不给高度会吃掉整块可用空间，
      // 下面的影片网格就被压成 0 高（表现为「结果页只有一行卡片」）。
      .height(84)
      .align(Alignment.Start)
    }
    .width('100%')
    .padding({ bottom: 10 })
  }

  @Builder
  EmptyHint(text: string, sub: string) {
    Column({ space: 8 }) {
      Text(text)
        .fontSize(14)
        .fontColor(Theme.TEXT_DIM)
      Text(sub)
        .fontSize(11)
        .fontColor(Theme.TEXT_FAINT)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 空态：上面是搜索历史（点一下直接再搜），下面是使用提示。
   * 历史放服务端，重装包 / 换设备都还在 —— 与收藏、观看记录同一套思路。
   */
  @Builder
  IdlePanel() {
    Column({ space: 16 }) {
      if (this.hist.length > 0) {
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Text('搜索历史')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_DIM)
            Blank()
            Text(this.confirmClear ? '再点一次清空' : '清空')
              .fontSize(11)
              .fontColor(this.confirmClear ? Theme.DANGER : Theme.TEXT_FAINT)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.onClear();
              })
          }
          .width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.hist, (h: SearchHistoryItem) => {
              Row({ space: 5 }) {
                Text(h.q)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .maxLines(1)
                  .constraintSize({ maxWidth: 180 })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 单条删除：胶囊右侧的小叉，别让人为了删一条去点「清空」
                Text('✕')
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .padding({ left: 2, right: 2, top: 2, bottom: 2 })
                  .onClick(() => {
                    this.delHistory(h.q);
                  })
              }
              .padding({ left: 10, right: 8, top: 6, bottom: 6 })
              .backgroundColor(Theme.CARD)
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.useHistory(h.q);
              })
            }, (h: SearchHistoryItem) => `sh-${h.q}`)
          }
          .width('100%')
        }
        .width('100%')
      }

      Column({ space: 6 }) {
        Text('⌕')
          .fontSize(28)
          .fontColor(Theme.TEXT_FAINT)
        Text('输入即联想：影片 / 演员 / 导演 / 标签 / 系列 / 制片商')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
          .textAlign(TextAlign.Center)
        Text('上面的「范围」决定这一次搜哪几类')
          .fontSize(11)
          .fontColor(Theme.TEXT_FAINT)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, top: 10 })
  }

  @Builder
  Results() {
    Column() {
      if (this.filmOn() && this.items.length > 0 && this.ents.length > 0) {
        this.EntStrip()
      }
      if (this.filmOn() && this.items.length > 0) {
        Grid() {
          ForEach(this.items, (item: MediaItem) => {
            GridItem() {
              // 与媒体库 / 首页 / 演员作品共用同一张海报卡，标记不再各页漏做
              PosterCard({
                item: item,
                fluid: true,
                onTap: () => {
                  this.openDetail(item.id);
                }
              })
            }
          }, (item: MediaItem) => `s-${item.id}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(14)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      } else if (this.ents.length > 0) {
        // 没勾影片（或影片零命中）：实体命中就是主结果，竖排一行一条
        List({ space: 6 }) {
          ForEach(this.ents, (item: SuggestItem) => {
            ListItem() {
              this.SugRow(item)
            }
          }, (item: SuggestItem) => `res-${item.type}-${item.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
      } else {
        this.EmptyHint('没有找到', '试试只输入番号前缀（比如 ABP），或放宽上面的搜索范围')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(Theme.TEXT)
          .width(30)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        TextInput({ text: this.keyword, placeholder: '搜番号 / 标题 / 演员 / 标签…' })
          .layoutWeight(1)
          .height(38)
          .backgroundColor(Theme.CARD)
          .fontColor(Theme.TEXT)
          .placeholderColor(Theme.TEXT_FAINT)
          .placeholderFont({ size: 13 })
          .caretColor(Theme.ACCENT)
          .defaultFocus(true)
          .onChange((value: string) => {
            // 程序化赋值（点历史词）也会触发 onChange，但那不是「用户在输入」：
            // 不拦住会把刚发起的搜索按 seq 作废，页面又退回联想列表。
            if (value === this.keyword) {
              return;
            }
            this.onKeyword(value);
          })
          .onSubmit(() => {
            this.commitSearch();
          })
        Text('搜索')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.commitSearch();
          })
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 8 })

      // 搜索前先定范围：多选，勾什么搜什么
      this.ScopeBar()
      // 结果条件：出演年龄 + 排序，与媒体库同一套 key
      this.FilterBar()

      if (this.legacy) {
        Column({ space: 3 }) {
          Text(`当前服务端${this.legacyVer.length > 0 ? ` ${this.legacyVer}` : ''} 只支持影片联想`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFB74D')
          // 发布版不提测试端口：只说去改地址，别把内部端口号暴露给普通用户
          Text(`连的是 ${this.legacyAddr}；按类型搜需要服务端 ≥ 1.3.12。\n到「我的 → 连接设置 → 用户数据服务地址」` +
            (BuildConfig.CHANNEL === 'self' ? '改成测试端口（8771）' : '改成正确的那台') +
            '后点「保存并重连」。')
            .fontSize(9)
            .fontColor('#CCFFB74D')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor('#26FFB74D')
        .borderRadius(8)
        .margin({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: 8 })
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(26)
            .height(26)
            .color(Theme.ACCENT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.searched) {
        this.Results()
      } else if (this.sugs.length > 0) {
        // 输入中：实时联想结果（按类型分堆，影片在前，实体都能点进列表）
        this.SuggestList()
      } else {
        this.IdlePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
