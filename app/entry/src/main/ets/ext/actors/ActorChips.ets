import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpGet } from '../../common/Http';
import { Store } from '../../common/Store';
import { Theme } from '../../common/Theme';
import { BrowseParams } from '../../common/Types';
import { ageBandOf, ageBandLabel, ageGenderLabel, PREF_AGE_GENDER } from '../../common/BrowseOptions';
import {
  ActorLookup, ActorParams, CastMember, CastMemberList, safeCastMembers
} from './ActorTypes';

/**
 * 公开扩展 actors：影片详情页的「出演」行。
 *
 * 做成 Emby 那样的**头像 + 姓名**：核心 /api/user/item/{id} 只有演员名，
 * 于是走扩展的 /api/user/item/{id}/cast 一次拿全（id / 姓名 / 性别 / 头像），
 * 不再逐个名字反查。头像圆形、可横向滑动，点任意一位进演员详情。
 * 扩展按「发行日 − 演员生日」现算的岁数写成「出演 N 岁」小徽章（点它跳同年龄段），
 * 缺生日什么都不显示；上游没有出演年龄这个字段，也不写回上游。
 *
 * 岁数只显示**当前选定性别**的：这个功能是给女演员做的，默认女优，男优的岁数
 * 不写出来也不参与筛选排序（右上角的「♀ 女优 / ♂ 男优」是同一份全局偏好，
 * 与媒体库筛选、搜索页筛选用的是同一个值）。
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
  /** 出演年龄看谁的：全局偏好，默认女优。 */
  @State ageGender: string = 'female';

  aboutToAppear(): void {
    this.ageGender = Store.I.prefString(PREF_AGE_GENDER, 'female');
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

  /** 点「出演 N 岁」徽章 → 同性别、同年龄段的影片列表（预置分桶 + 按出演年龄排序）。 */
  private openAgeBand(age: number): void {
    const band: string = ageBandOf(age);
    if (band.length === 0) {
      return;
    }
    const p: BrowseParams = {
      libraryId: 0,
      title: `${ageBandLabel(band)}的${ageGenderLabel(this.ageGender)}影片`,
      ageBand: band,
      sort: 'cast_age',
      ageGender: this.ageGender
    };
    router.pushUrl({ url: 'pages/LibraryPage', params: p });
  }

  /** 切换年龄的性别口径：写进全局偏好，筛选 / 排序两处跟着变。 */
  private toggleGender(): void {
    this.ageGender = this.ageGender === 'male' ? 'female' : 'male';
    Store.I.prefSetString(PREF_AGE_GENDER, this.ageGender);
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
      if (m.age > 0 && m.gender === this.ageGender) {
        // 「出演 24 岁」：语义直接带在标签里，一眼看出是出演本片时的岁数，
        // 不会误读成演员现在的年龄；做成与详情区块一致的小徽章（前缀淡色小字 +
        // 亮色数字 + 主题色圆角底），点它跳同性别同年龄段影片列表。
        // 只有当前选定性别的演员写岁数：男演员默认不显示（这不是男优年龄表）。
        Row({ space: 2 }) {
          Text('出演')
            .fontSize(8)
            .fontColor(Theme.TEXT_DIM)
          Text(`${m.age} 岁`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT)
        }
        .height(18)
        .padding({ left: 6, right: 6 })
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(9)
        .onClick(() => {
          this.openAgeBand(m.age);
        })
      } else {
        // 缺生日就什么都不写，只留等高空位，保证这一排头像不错位。
        Text('')
          .height(18)
          .width(64)
      }
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
        // 年龄只看一个性别：默认女优，点一下换男优；和筛选/排序共用同一份偏好。
        Text(this.ageGender === 'male' ? '♂ 男优' : '♀ 女优')
          .fontSize(9)
          .fontColor(Theme.TEXT_DIM)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.CARD_HI)
          .borderRadius(9)
          .onClick(() => {
            this.toggleGender();
          })
      }
      .width('100%')

      if (this.members.length > 0) {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.members, (m: CastMember) => {
              this.Person(m)
            }, (m: CastMember) => `cast-${m.id}-${this.ageGender}`)
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
