import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';

/**
 * 设置 · 资料整理（二级页，2026-11-15 建立）。
 *
 * 为什么单独一页：检索别名（俗称映射）和自建标签/系列都是「我给它起过名字」这件事的两半，
 * 以前分在「通用」和「我的内容」两组里，用户得先知道它属于哪一类才找得到。
 * 现在合成一个入口，名字用用户自己的话（资料整理）而不是机制名。
 *
 * 底部的「清空所有自定义修改」从设置一级页的「重置」组迁进来：
 * 它清的就是这一页管的那些改动，放在一起才讲得通；破坏性动作仍单独成块、DANGER 色、二次确认。
 *
 * 行为零变化：两行只是转发到原来的页面（`AliasPage` / `SelfFacetPage`），
 * 清空仍打 `POST /api/user/meta_override/clear`，老服务端 404 仍提示「这个版本还不支持」。
 */

interface OrgRow {
  key: string;
  label: string;
  desc: string;
  url: string;
}

const ROWS: OrgRow[] = [
  {
    key: 'alias', label: '检索别名',
    desc: '俗称和库里的名字对不上时，在这儿挂钩（如 搜查官 → 女检察官）',
    url: 'pages/AliasPage'
  },
  {
    key: 'selffacet', label: '自建标签 / 系列',
    desc: '你自己起的名字都在这儿，可单独删；库里的分类不在这里',
    url: 'pages/SelfFacetPage'
  }
];

@Entry
@Component
struct OrganizePage {
  /** 清空所有本地修改（2.5.5）。行为与设置页原实现一致，只是搬了位置。 */
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

  @Builder
  NavRow(r: OrgRow) {
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
        Text('资料整理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: Theme.PAGE_PAD, top: 6, bottom: 6 })

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 8 }) {
            Text('我起过的名字')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .letterSpacing(1)
              .width('100%')
            Column() {
              this.NavRow(ROWS[0])
              Divider()
                .strokeWidth(1)
                .color(Theme.CARD_HI)
              this.NavRow(ROWS[1])
            }
            .width('100%')
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
            .clip(true)
            Text('这两处只影响你手机上的检索与分类，不改服务器里刮削到的原始数据。')
              .fontSize(10)
              .fontColor(Theme.TEXT_FAINT)
              .width('100%')
              .lineHeight(16)
          }
          .width('100%')

          Column({ space: 8 }) {
            Text('危险操作')
              .fontSize(11)
              .fontColor(Theme.TEXT_FAINT)
              .letterSpacing(1)
              .width('100%')
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('清空所有自定义修改')
                  .fontSize(15)
                  .fontColor(Theme.DANGER)
                Text('把改过的片名/演员/标签与换过的封面全部还原成刮削原样（所有设备一起变）')
                  .fontSize(11)
                  .fontColor(Theme.TEXT_FAINT)
                  .maxLines(2)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('清空')
                .fontSize(12)
                .fontColor(Theme.DANGER)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .backgroundColor(Theme.CARD)
            .borderRadius(14)
            .onClick(() => {
              this.confirmResetMeta();
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PAD, right: Theme.PAGE_PAD, bottom: Theme.BOTTOM_SAFE })
      }
      .layoutWeight(1)
      // Scroll 里的 Column 默认会被垂直居中（真机实测：标题下空出一大块），必须显式靠上
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
