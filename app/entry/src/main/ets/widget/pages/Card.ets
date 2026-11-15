/**
 * 桌面服务卡片（2.6.1.26）：今日推荐 + 继续观看。
 *
 * 两档尺寸：2×2（小）与 2×4（横条）。
 * - 2×2：左边一张竖版海报，右边番号 + 标题 + 「继续观看」一行；
 * - 2×4：宽出来的地方把标题多放一行、底部加一行时间戳。
 *
 * 数据全部来自 `LocalStorage`（由 EntryFormAbility 的 formBindingData 灌进来），
 * 卡片本身不发请求 —— 断网时它至少还是「上次打开 App 时的那一张」，不会变白板。
 *
 * 点击：`postCardAction` 的 router 动作直接拉起 EntryAbility，App 端按 `from=card` 决定
 * 是否落在详情页（见 `Index.aboutToAppear` 里的处理）。
 */
import { CardPayload } from '../../common/CardCache';

const storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct Card {
  @LocalStorageProp('number') number: string = '';
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('posterUrl') posterUrl: string = '';
  @LocalStorageProp('contNumber') contNumber: string = '';
  @LocalStorageProp('contTitle') contTitle: string = '';
  @LocalStorageProp('at') at: string = '';

  /** 有没有内容：番号和海报都没有就当没同步过。 */
  private ready(): boolean {
    return this.number.length > 0 || this.posterUrl.length > 0;
  }

  build() {
    Column() {
      if (!this.ready()) {
        Column({ space: 6 }) {
          Text('Amane')
            .fontSize(13)
            .fontColor('#F4F4F7')
            .fontWeight(FontWeight.Medium)
          Text('打开 App 同步一次')
            .fontSize(10)
            .fontColor('#A3A3AE')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Row({ space: 8 }) {
          // 海报位：底下一层是兜底（渐变 + 番号首字母），上面盖 Image。
          // 卡片进程与 App 不是同一个网络上下文，明文 http 图在这里经常取不到 ——
          // 取不到时露出兜底层，至少不会是一块黑。
          Stack({ alignContent: Alignment.Center }) {
            Column() {
              Text(this.number.length > 0 ? this.number.substring(0, 2) : 'A')
                .fontSize(16)
                .fontColor('#4E4E58')
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#1B1B22')
            .borderRadius(8)

            if (this.posterUrl.length > 0) {
              Image(this.posterUrl)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
            }
          }
          .width('34%')
          .height('100%')

          Column() {
            Column({ space: 2 }) {
              if (this.number.length > 0) {
                Text(this.number)
                  .fontSize(10)
                  .fontColor('#F2C14E')
                  .maxLines(1)
              }
              Text(this.title.length > 0 ? this.title : '今日推荐')
                .fontSize(10)
                .fontColor('#F4F4F7')
                .lineHeight(14)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.contNumber.length > 0 ? `继续看 · ${this.contNumber}` : '每日推荐')
                .fontSize(8)
                .fontColor('#A3A3AE')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')

            Blank()

            if (this.at.length > 0) {
              Text(this.at)
                .fontSize(7)
                .fontColor('#4E4E58')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .backgroundColor('#0B0B0F')
    .borderRadius(16)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { from: 'card' }
      });
    })
  }
}
