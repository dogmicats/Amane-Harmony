import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet, httpPost } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { DetailParams } from '../../common/Types';
import { FavoriteEntityView, FavEntity, FavBadge } from '../../view/FavoriteEntityView';
import {
  ActorItem, ActorList, ActorParams, safeActorList
} from './ActorTypes';

/**
 * 「收藏的演员」（收藏页的一个分段）。
 *
 * 数据来自 actors 扩展的 `GET /api/user/actors?favorite=true`：上游 actors 表
 * 没有收藏列，记录存在旁挂 user.db，顺序是最近收藏在前；`posters` 是这位演员
 * 最近几部作品的海报（带影片 id），由扩展一次算好，点海报能直接进影片。
 *
 * 展示交给 `view/FavoriteEntityView`：与导演/标签/系列共用同一套横版行与
 * 3 列简版，四类收藏看起来是一套东西。
 */
@Component
export struct FavoriteActorsView {
  @Prop @Watch('onRefresh') refreshKey: number = 0;
  /** true = 3 列简版；false = 横版大行。 */
  @Prop grid: boolean = false;

  @State entities: FavEntity[] = [];
  @State loading: boolean = true;
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onRefresh(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = this.entities.length === 0;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/actors?favorite=true&limit=200`, Store.I.token);
      const raw: ActorList = JSON.parse(text) as ActorList;
      const list: ActorItem[] = safeActorList(raw).items;
      const out: FavEntity[] = [];
      for (let i = 0; i < list.length; i++) {
        const a: ActorItem = list[i];
        out.push({
          kind: 'actor',
          id: a.id,
          name: a.name,
          count: a.count,
          cover: a.avatar,
          posters: a.posters,
          badges: this.actorBadges(a)
        });
      }
      this.entities = out;
      this.note = '';
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] favorite actors: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端未启用演员扩展' : '读取失败，请检查连接';
    }
    this.loading = false;
  }

  /** 海报条下面那行彩色胶囊：生日 / 身高 / 罩杯，有什么给什么。 */
  private actorBadges(a: ActorItem): FavBadge[] {
    const out: FavBadge[] = [];
    if (a.birthday.length >= 10) {
      out.push({ text: a.birthday.substring(0, 10), color: '#7FB8FF' });
    }
    if (a.height > 0) {
      out.push({ text: `${a.height}cm`, color: '#7FE0B0' });
    }
    if (a.cup.length > 0 && a.bust > 0) {
      out.push({ text: `${a.cup} · ${a.bust}`, color: '#FFC46B' });
    }
    return out;
  }

  private open(e: FavEntity): void {
    const p: ActorParams = { id: e.id, name: e.name };
    router.pushUrl({ url: 'ext/actors/ActorDetailPage', params: p });
  }

  private openFilm(id: number): void {
    const p: DetailParams = { id: id };
    router.pushUrl({ url: 'pages/DetailPage', params: p });
  }

  /** 取消收藏：先本地移除（立刻有反馈），失败再放回去。 */
  private async unfavorite(e: FavEntity): Promise<void> {
    const before: FavEntity[] = this.entities;
    const rest: FavEntity[] = [];
    for (let i = 0; i < before.length; i++) {
      if (before[i].id !== e.id) {
        rest.push(before[i]);
      }
    }
    this.entities = rest;
    try {
      await httpPost(`${Store.I.user}/api/user/actors/${e.id}/favorite`, Store.I.token,
        JSON.stringify({ favorite: false }));
    } catch (err) {
      const ex = err as BusinessError;
      console.error(`[amane] unfavorite actor: ${ex.code} ${ex.message}`);
      this.entities = before;
      this.note = '取消失败，请检查连接';
      setTimeout(() => {
        this.note = '';
      }, 2000);
    }
  }

  build() {
    if (this.loading) {
      Column() {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(Theme.ACCENT)
      }
      .width('100%')
      .height(180)
      .justifyContent(FlexAlign.Center)
    } else if (this.entities.length === 0) {
      Column({ space: 10 }) {
        Text('♥')
          .fontSize(30)
          .fontColor(Theme.TEXT_FAINT)
        Text(this.note.length > 0 ? this.note : '还没有收藏的演员')
          .fontSize(13)
          .fontColor(Theme.TEXT_DIM)
        if (this.note.length === 0) {
          Text('在演员详情页点右上角的心，喜欢的演员会集中到这里。')
            .fontSize(11)
            .fontColor(Theme.TEXT_FAINT)
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
      }
      .width('100%')
      .height(260)
      .justifyContent(FlexAlign.Center)
    } else {
      FavoriteEntityView({
        items: this.entities,
        grid: this.grid,
        onOpen: (e: FavEntity) => {
          this.open(e);
        },
        onFilm: (id: number) => {
          this.openFilm(id);
        },
        onUnfav: (e: FavEntity) => {
          this.unfavorite(e);
        }
      })
      .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD })
    }
  }
}
