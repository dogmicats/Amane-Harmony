import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import {
  ActorLookup, ActorParams, CastMember, CastMemberList, safeCastMembers
} from './ActorTypes';

/**
 * 公开扩展 actors：影片详情页的「出演」行。
 *
 * 做成 Emby 那样的**头像 + 姓名**：核心 /api/user/item/{id} 只有演员名，
 * 于是走扩展的 /api/user/item/{id}/cast 一次拿全（id / 姓名 / 性别 / 头像），
 * 不再逐个名字反查。头像圆形、可横向滑动，点任意一位进演员详情。
 *
 * 服务端没装扩展或请求失败时退回「纯姓名 chip」，仍然靠 lookup 反查 id，
 * 保证老服务端也不至于看不了演员。
 */
@Component
export struct ActorChips {
  @Prop metaId: number = 0;
  @Prop names: string[] = [];
  @State members: CastMember[] = [];
  @State busy: string = '';
  @State note: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    if (this.metaId <= 0) {
      return;
    }
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/item/${this.metaId}/cast`, Store.I.token);
      const r: CastMemberList = JSON.parse(text) as CastMemberList;
      this.members = safeCastMembers(r.items);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] item cast: ${e.code} ${e.message}`);
      this.members = [];
    }
  }

  private open(id: number, name: string): void {
    if (id <= 0) {
      this.openByName(name);
      return;
    }
    const p: ActorParams = { id: id, name: name };
    router.pushUrl({ url: 'ext/actors/ActorDetailPage', params: p });
  }

  /** 老服务端兜底：只有名字时反查实体 id。 */
  private async openByName(name: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = name;
    try {
      const text: string = await httpGet(
        `${Store.I.user}/api/user/actors/lookup?name=${encodeURIComponent(name)}`,
        Store.I.token);
      const r: ActorLookup = JSON.parse(text) as ActorLookup;
      if (r !== undefined && r !== null && Number(r.id) > 0) {
        const p: ActorParams = { id: Number(r.id), name: name };
        router.pushUrl({ url: 'ext/actors/ActorDetailPage', params: p });
      } else {
        this.note = `没有找到「${name}」的演员资料`;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[amane] actor lookup: ${e.code} ${e.message}`);
      this.note = e.code === 404 ? '服务端未启用演员扩展' : '查询失败，请检查连接';
    }
    this.busy = '';
    if (this.note.length > 0) {
      setTimeout(() => {
        this.note = '';
      }, 2200);
    }
  }

  @Builder
  Person(m: CastMember) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (m.avatar.length > 0) {
          Image(Store.I.img(m.avatar))
            .width(54)
            .height(54)
            .objectFit(ImageFit.Cover)
            .borderRadius(27)
            .backgroundColor(Theme.CARD_HI)
            .alt($r('app.media.placeholder'))
        } else {
          Column() {
            Text(m.name.length > 0 ? m.name.substring(0, 1) : '?')
              .fontSize(20)
              .fontColor(Theme.TEXT_FAINT)
          }
          .width(54)
          .height(54)
          .justifyContent(FlexAlign.Center)
          .borderRadius(27)
          .backgroundColor(Theme.CARD_HI)
        }
        if (m.gender === 'female' || m.gender === 'male') {
          Text(m.gender === 'female' ? '♀' : '♂')
            .fontSize(9)
            .fontColor(m.gender === 'female' ? '#FF8FB1' : '#7FB4FF')
            .width(16)
            .height(16)
            .textAlign(TextAlign.Center)
            .borderRadius(8)
            .backgroundColor('#CC0B0B0F')
            .position({ x: 38, y: 38 })
        }
      }
      .width(54)
      .height(54)

      Text(m.name.length > 0 ? m.name : '未署名')
        .fontSize(10)
        .fontColor(Theme.TEXT_DIM)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(64)
        .height(26)
    }
    .width(64)
    .onClick(() => {
      this.open(m.id, m.name);
    })
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('出演')
          .fontSize(12)
          .fontColor(Theme.TEXT_FAINT)
        Text(`${this.members.length > 0 ? this.members.length : this.names.length}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_FAINT)
        Blank()
      }
      .width('100%')

      if (this.members.length > 0) {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.members, (m: CastMember) => {
              this.Person(m)
            }, (m: CastMember) => `cast-${m.id}`)
          }
          .padding({ right: 4 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)
      } else if (this.names.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.names, (name: string) => {
            Text(this.busy === name ? `${name} …` : name)
              .fontSize(12)
              .fontColor(Theme.TEXT)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.CARD_HI)
              .borderRadius(12)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.openByName(name);
              })
          }, (name: string) => `chip-${name}`)
        }
        .width('100%')
      }

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(11)
          .fontColor(Theme.GOLD)
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 14 })
  }
}
