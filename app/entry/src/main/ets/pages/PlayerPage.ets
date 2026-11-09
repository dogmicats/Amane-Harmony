import { router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AudioTrack, Media, Player, PlayerConfig, PlayerSurface, SubtitleTrack } from '@mpv-ohos/mpv-arkts';
import { httpPost } from '../common/Http';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { PlayerParams } from '../common/Types';
import { clock } from '../common/Util';
import { common } from '@kit.AbilityKit';
import { SubtitleClient, SubtitleItem, LocalCandidate } from '../common/Subtitles';

const SPEEDS: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];

/**
 * 原生播放页：mpv 内核（硬解 + 内嵌字幕/音轨），自绘控制层。
 * 手势：左右拖 = 找进度，竖直拖 = 左亮度 / 右音量，双击 = 播放暂停。
 *
 * 所有 player.* 都是原生调用，内核线程异常时会抛，全部包 try-catch 否则整页闪退。
 */
@Entry
@ComponentV2
struct PlayerPage {
  private player: Player | undefined = undefined;
  private metaId: number = 0;
  private metaNumber: string = '';
  private metaTitle: string = '';
  private startPos: number = 0;
  private tickId: number = -1;
  private saveId: number = -1;
  private lastSavedPos: number = 0;
  private completed: boolean = false;
  private subTracks: SubtitleTrack[] = [];
  private audioTracks: AudioTrack[] = [];
  private panKind: string = '';
  private panBase: number = 0;
  private panStartPos: number = 0;
  private win: window.Window | undefined = undefined;

  @Local surfaceReady: boolean = false;
  @Local pos: number = 0;
  @Local duration: number = 0;
  @Local playing: boolean = false;
  @Local buffering: boolean = false;
  @Local bitrate: number = 0;
  @Local bufPct: number = 0;
  @Local speed: number = 1.0;
  @Local showControls: boolean = true;
  @Local volume: number = 100;
  @Local bright: number = 0.5;
  @Local seekPreview: number = -1;
  @Local errorText: string = '';
  @Local showPanel: boolean = false;
  @Local panelKind: string = 'subs';
  @Local subLabels: string[] = [];
  @Local audioLabels: string[] = [];
  @Local hint: string = '';
  @Local volumeHint: number = -1;
  @Local localSubs: LocalCandidate[] = [];
  @Local extSubs: SubtitleItem[] = [];
  @Local subUrlInput: string = '';
  @Local subBusy: boolean = false;
  @Local subHint: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as PlayerParams;
    if (params !== undefined && params !== null) {
      this.metaId = params.id === undefined || params.id === null ? 0 : Number(params.id);
      this.metaNumber = params.number === undefined || params.number === null ? '' : params.number;
      this.metaTitle = params.title === undefined || params.title === null ? '' : params.title;
      const start: number = params.position === undefined || params.position === null
        ? 0 : Number(params.position);
      this.startPos = start > 5 ? start : 0;
    }
    try {
      this.player = new Player(new PlayerConfig({ hwdec: true, vo: 'gpu-next', osc: false, osd: false }));
      this.surfaceReady = true;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] player init: ${e.code} ${e.message}`);
      this.errorText = `播放内核没装好：${e.message}`;
      return;
    }
    this.enterFullscreen();
    this.openMedia();
    this.tickId = setInterval(() => {
      this.syncState();
    }, 300);
    this.saveId = setInterval(() => {
      this.saveProgress(false);
    }, 10000);
  }

  aboutToDisappear(): void {
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
    if (this.saveId >= 0) {
      clearInterval(this.saveId);
      this.saveId = -1;
    }
    this.saveProgress(true);
    this.surfaceReady = false;
    try {
      if (this.player !== undefined) {
        this.player.destroy();
        this.player = undefined;
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] player destroy: ${e.code} ${e.message}`);
    }
    this.exitFullscreen();
  }

  private enterFullscreen(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.win = win;
      win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarEnable([]);
      win.getWindowProperties();
    }).catch((error: BusinessError) => {
      console.error(`[amane] fullscreen: ${error.code} ${error.message}`);
    });
  }

  private exitFullscreen(): void {
    if (this.win === undefined) {
      return;
    }
    this.win.setPreferredOrientation(window.Orientation.PORTRAIT);
    this.win.setWindowLayoutFullScreen(false);
    this.win.setWindowSystemBarEnable(['status', 'navigation']);
  }

  private openMedia(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      // token 已经在 URL 的 query 里，不要再走 httpHeaders：
      // mpv-arkts 会把头名编码坏（%65%authorization），反而触发 401。
      const media: Media = new Media(Store.I.playUrl(this.metaId), {
        start: this.startPos
      });
      this.player.stream.error.listen((message: string) => {
        this.errorText = message.length > 0 ? message : '播放失败';
      });
      this.player.open(media);
      this.pos = this.startPos;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] open: ${e.code} ${e.message}`);
      this.errorText = `打不开这个文件：${e.message}`;
    }
  }

  private syncState(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      const st = this.player.state;
      if (st === undefined || st === null) {
        return;
      }
      this.pos = st.position;
      this.duration = st.duration;
      this.playing = st.playing;
      this.buffering = st.buffering;
      this.bitrate = st.videoBitrate > 0 ? st.videoBitrate : 0;
      this.bufPct = st.bufferingPercentage >= 0 ? st.bufferingPercentage : 0;
      this.speed = st.speed;
      if (st.eof && !this.completed) {
        this.completed = true;
        this.saveProgress(true);
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] sync: ${e.code} ${e.message}`);
    }
  }

  private saveProgress(force: boolean): void {
    if (this.duration <= 0 || this.metaId <= 0) {
      return;
    }
    if (!force && Math.abs(this.pos - this.lastSavedPos) < 5) {
      return;
    }
    this.lastSavedPos = this.pos;
    const body: string = JSON.stringify({
      metadata_id: this.metaId,
      position: this.pos,
      duration: this.duration,
      finished: this.completed || this.pos >= this.duration * 0.95
    });
    httpPost(`${Store.I.user}/api/user/history`, Store.I.token, body).catch((error: BusinessError) => {
      console.error(`[amane] save progress: ${error.code} ${error.message}`);
    });
  }

  private togglePlay(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      this.player.playOrPause();
      this.playing = !this.playing;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] play/pause: ${e.code} ${e.message}`);
    }
  }

  private seekTo(seconds: number): void {
    if (this.player === undefined) {
      return;
    }
    const target: number = Math.max(0, Math.min(this.duration, seconds));
    try {
      this.player.seek(target);
      this.pos = target;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] seek: ${e.code} ${e.message}`);
    }
  }

  private cycleSpeed(): void {
    if (this.player === undefined) {
      return;
    }
    let index: number = SPEEDS.indexOf(this.speed);
    if (index < 0) {
      index = 1;
    }
    index = (index + 1) % SPEEDS.length;
    const next: number = SPEEDS[index];
    try {
      this.player.setSpeed(next);
      this.speed = next;
      this.toast(`倍速 ${next}x`);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] speed: ${e.code} ${e.message}`);
    }
  }

  private toggleSubs(): void {
    if (this.player === undefined) {
      return;
    }
    try {
      const st = this.player.state;
      if (st === undefined || st === null) {
        this.toast('内核还没就绪');
        return;
      }
      const tracks = st.tracks;
      if (tracks === undefined || tracks === null) {
        this.toast('没有可选的轨道');
        return;
      }
      const subsList: SubtitleTrack[] = tracks.subs === undefined || tracks.subs === null ? [] : tracks.subs;
      const audioList: AudioTrack[] = tracks.audio === undefined || tracks.audio === null ? [] : tracks.audio;
      this.subTracks = subsList;
      this.audioTracks = audioList;
      const subs: string[] = [];
      const audios: string[] = [];
      for (let i = 0; i < subsList.length; i++) {
        subs.push(this.trackLabel(subsList[i].title, subsList[i].lang, i));
      }
      for (let i = 0; i < audioList.length; i++) {
        audios.push(this.trackLabel(audioList[i].title, audioList[i].lang, i));
      }
      this.subLabels = subs;
      this.audioLabels = audios;
      this.panelKind = 'subs';
      this.loadSubSources();
      this.showPanel = true;
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] tracks: ${e.code} ${e.message}`);
      this.toast('读轨道失败');
    }
  }


  /** 打开字幕面板时拉取来源，并自动套用上次的选择。 */
  private async loadSubSources(): Promise<void> {
    if (this.metaId <= 0) {
      this.subHint = '没有拿到条目 id，无法查询字幕';
      return;
    }
    this.subBusy = true;
    try {
      const res = await SubtitleClient.list(this.metaId);
      this.localSubs = res.local === undefined || res.local === null ? [] : res.local;
      this.extSubs = res.cached === undefined || res.cached === null ? [] : res.cached;
      this.subHint = res.hint === undefined || res.hint === null ? '' : res.hint;
      if (res.choice !== undefined && res.choice !== null && res.choice.subtitle_id.length > 0) {
        this.applySub(res.choice.subtitle_id);
      }
    } catch (error) {
      console.error(`[amane] subtitles: ${JSON.stringify(error)}`);
    } finally {
      this.subBusy = false;
    }
  }

  /** 所有来源统一走这里：一个 subtitle_id → 一条远程字幕轨道。 */
  private applySub(id: string): void {
    if (this.player === undefined) {
      return;
    }
    try {
      const url: string = SubtitleClient.streamUrl(id, true);
      this.player.setSubtitleTrack(SubtitleTrack.uri(url, '', 'chi', 'external'));
      SubtitleClient.remember(this.metaId, id).catch(() => {
        // 记住失败不影响播放
      });
      this.showPanel = false;
    } catch (error) {
      console.error(`[amane] apply sub: ${JSON.stringify(error)}`);
      this.toast('加载字幕失败');
    }
  }

  private async useLocalSub(name: string): Promise<void> {
    try {
      const item: SubtitleItem = await SubtitleClient.loadLocal(this.metaId, name);
      this.applySub(item.id);
    } catch (error) {
      console.error(`[amane] local sub: ${JSON.stringify(error)}`);
      this.toast('读取同目录字幕失败');
    }
  }

  private async importSub(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const item: SubtitleItem = await SubtitleClient.importFromPhone(ctx);
      this.applySub(item.id);
    } catch (error) {
      console.error(`[amane] import sub: ${JSON.stringify(error)}`);
      this.toast('导入字幕失败');
    }
  }

  private async addSubUrl(): Promise<void> {
    const raw: string = this.subUrlInput.trim();
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      this.toast('请填写 http(s) 字幕地址');
      return;
    }
    try {
      const item: SubtitleItem = await SubtitleClient.addUrl(raw);
      this.subUrlInput = '';
      this.applySub(item.id);
    } catch (error) {
      console.error(`[amane] url sub: ${JSON.stringify(error)}`);
      this.toast('抓取字幕失败');
    }
  }

  private trackLabel(title: string, lang: string, index: number): string {
    if (title !== undefined && title !== null && title.length > 0) {
      return title;
    }
    if (lang !== undefined && lang !== null && lang.length > 0) {
      return `轨道 ${lang}`;
    }
    return `轨道 ${index + 1}`;
  }

  private pickSub(index: number): void {
    if (this.player === undefined) {
      return;
    }
    try {
      if (index < 0) {
        this.player.disableSubtitleTrack();
      } else if (index < this.subTracks.length) {
        this.player.setSubtitleTrack(this.subTracks[index]);
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] pick sub: ${e.code} ${e.message}`);
    }
    this.showPanel = false;
  }

  private pickAudio(index: number): void {
    if (this.player === undefined) {
      return;
    }
    try {
      if (index >= 0 && index < this.audioTracks.length) {
        this.player.setAudioTrack(this.audioTracks[index]);
      }
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] pick audio: ${e.code} ${e.message}`);
    }
    this.showPanel = false;
  }

  private applyVolume(value: number): void {
    if (this.player === undefined) {
      return;
    }
    try {
      this.player.setVolume(value);
    } catch (error) {
      const e = error as BusinessError;
      console.error(`[amane] volume: ${e.code} ${e.message}`);
    }
  }

  private toast(text: string): void {
    this.hint = text;
    setTimeout(() => {
      if (this.hint === text) {
        this.hint = '';
      }
    }, 1200);
  }

  /** 一眼分辨「请求没成功」和「带宽不够」：码率长期高于链路能力就会反复缓冲。 */
  private diagnostics(): string {
    const state: string = this.buffering ? '缓冲中' : (this.playing ? '播放中' : '等待数据');
    const rate: string = this.bitrate > 0 ? (this.bitrate / 1000000).toFixed(1) : '--';
    const cache: number = Math.round(this.bufPct);
    return `${state} · 码率 ${rate} Mbps · 缓存 ${cache}%`;
  }

  private seekPreviewLabel(): string {
    const value: number = this.seekPreview >= 0 ? this.seekPreview : this.pos;
    return `${clock(value)} / ${clock(this.duration)}`;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.surfaceReady && this.player !== undefined) {
        PlayerSurface({ player: this.player as Player })
          .width('100%')
          .height('100%')
      }

      // 控件层
      if (this.showControls) {
        Column() {
          Row({ space: 10 }) {
            Text('‹')
              .fontSize(26)
              .fontColor('#FFFFFF')
              .width(40)
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                router.back();
              })
            Column({ space: 1 }) {
              Text(this.metaNumber)
                .fontSize(13)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
              Text(this.metaTitle)
                .fontSize(10)
                .fontColor('#B3FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('58%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(`${this.speed}x`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor('#33000000')
              .borderRadius(12)
              .onClick(() => {
                this.cycleSpeed();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 })

          Text(this.diagnostics())
            .fontSize(10)
            .fontColor('#99FFFFFF')
            .width('100%')
            .padding({ left: 16, right: 16, top: 2 })

          Blank()

          Column({ space: 6 }) {
            Row({ space: 10 }) {
              Text(clock(this.seekPreview >= 0 ? this.seekPreview : this.pos))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .width(52)
              Slider({
                value: this.seekPreview >= 0 ? this.seekPreview : this.pos,
                min: 0,
                max: this.duration > 0 ? this.duration : 1,
                step: 1
              })
                .layoutWeight(1)
                .selectedColor(Theme.ACCENT)
                .trackColor('#4DFFFFFF')
                .trackThickness(3)
                .blockColor('#FFFFFF')
                .blockSize({ width: 12, height: 12 })
                .onChange((value: number, mode: SliderChangeMode) => {
                  if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                    this.seekPreview = value;
                  } else if (mode === SliderChangeMode.End) {
                    this.seekTo(value);
                    this.seekPreview = -1;
                  }
                })
              Text(clock(this.duration))
                .fontSize(11)
                .fontColor('#B3FFFFFF')
                .width(52)
                .textAlign(TextAlign.End)
            }
            .width('100%')

            Row({ space: 22 }) {
              Text(this.playing ? '❚❚' : '▶')
                .fontSize(16)
                .fontColor('#FFFFFF')
                .width(34)
                .height(30)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.togglePlay();
                })
              Text('字幕')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor('#33000000')
                .borderRadius(12)
                .onClick(() => {
                  this.toggleSubs();
                })
              Text('音轨')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor('#33000000')
                .borderRadius(12)
                .onClick(() => {
                  this.panelKind = 'audio';
                  this.toggleSubs();
                  this.panelKind = 'audio';
                })
              Blank()
              Text(this.volume > 0 ? '🔊' : '🔇')
                .fontSize(14)
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.volume = this.volume > 0 ? 0 : 100;
                  this.applyVolume(this.volume);
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 14, top: 10 })
          .linearGradient({
            angle: 0,
            colors: [['#00000000', 0.0], ['#CC000000', 1.0]]
          })
        }
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#99000000', 0.0], ['#00000000', 0.35], ['#CC000000', 1.0]]
        })
      }

      // 中央提示
      if (this.seekPreview >= 0) {
        Text(this.seekPreviewLabel())
          .fontSize(15)
          .fontColor('#FFFFFF')
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
      } else if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
      } else if (this.volumeHint >= 0) {
        Text(`音量 ${this.volumeHint}%`)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#B3000000')
          .borderRadius(10)
      }

      if (this.buffering) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color('#FFFFFF')
          Text(this.diagnostics())
            .fontSize(11)
            .fontColor('#B3FFFFFF')
        }
      }

      if (this.errorText.length > 0) {
        Column({ space: 10 }) {
          Text('播放失败')
            .fontSize(15)
            .fontColor('#FFFFFF')
          Text(this.errorText)
            .fontSize(11)
            .fontColor('#B3FFFFFF')
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 40, right: 40 })
            .textAlign(TextAlign.Center)
          Row({ space: 10 }) {
            Button('重试')
              .height(36)
              .backgroundColor(Theme.ACCENT)
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                this.errorText = '';
                this.openMedia();
              })
            Button('返回')
              .height(36)
              .backgroundColor('#33FFFFFF')
              .fontColor('#FFFFFF')
              .fontSize(13)
              .onClick(() => {
                router.back();
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#B3000000')
      }

      // 字幕 / 音轨面板
      if (this.showPanel) {
        Column() {
          Blank()
          Column({ space: 2 }) {
            Row() {
              Text(this.panelKind === 'subs' ? '字幕' : '音轨')
                .fontSize(14)
                .fontColor(Theme.TEXT)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('关闭')
                .fontSize(12)
                .fontColor(Theme.TEXT_FAINT)
                .onClick(() => {
                  this.showPanel = false;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })

            if (this.panelKind === 'subs') {
              this.PanelRow('不使用字幕', -1)
              ForEach(this.subLabels, (label: string, index: number) => {
                this.PanelRow(label, index)
              }, (label: string, index: number) => `sub-${index}`)

              Text('外挂字幕').fontSize(11).fontColor(Theme.TEXT_FAINT)
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 4 })
              if (this.localSubs.length === 0 && this.subHint.length > 0) {
                Text(this.subHint)
                  .fontSize(10)
                  .fontColor(Theme.TEXT_FAINT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 2, bottom: 4 })
                  .maxLines(3)
              }
              ForEach(this.localSubs, (item: LocalCandidate) => {
                Text(`同目录 · ${item.name}`)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => {
                    this.useLocalSub(item.name);
                  })
              }, (item: LocalCandidate) => `local-${item.name}`)
              ForEach(this.extSubs, (item: SubtitleItem) => {
                Text(`${item.name} · ${item.source}`)
                  .fontSize(12)
                  .fontColor(Theme.TEXT)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => {
                    this.applySub(item.id);
                  })
              }, (item: SubtitleItem) => `ext-${item.id}`)
              Row() {
                Button('手机导入')
                  .fontSize(11)
                  .height(30)
                  .onClick(() => {
                    this.importSub();
                  })
                Button('手动 URL')
                  .fontSize(11)
                  .height(30)
                  .onClick(() => {
                    this.addSubUrl();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 6 })
              TextInput({ placeholder: 'https://.../subtitle.srt' })
                .fontSize(11)
                .height(32)
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.subUrlInput = value;
                })
            } else {
              ForEach(this.audioLabels, (label: string, index: number) => {
                this.PanelRow(label, index)
              }, (label: string, index: number) => `audio-${index}`)
            }
            Blank().height(12)
          }
          .width('46%')
          .backgroundColor('#E614141A')
          .borderRadius({ topLeft: 14, topRight: 14 })
          .margin({ bottom: 16 })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showPanel = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1 })
          .onAction(() => {
            this.showControls = !this.showControls;
          }),
        TapGesture({ count: 2 })
          .onAction(() => {
            this.togglePlay();
            this.toast(this.playing ? '播放' : '暂停');
          }),
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart(() => {
            this.panKind = 'seek';
            this.panStartPos = this.pos;
            this.seekPreview = this.pos;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.panKind === 'seek') {
              const delta: number = event.offsetX / 400 * Math.min(this.duration, 600);
              this.seekPreview = Math.max(0, Math.min(this.duration, this.panStartPos + delta));
            }
          })
          .onActionEnd(() => {
            if (this.panKind === 'seek' && this.seekPreview >= 0) {
              this.seekTo(this.seekPreview);
            }
            this.panKind = '';
            this.seekPreview = -1;
          }),
        PanGesture({ direction: PanDirection.Vertical })
          .onActionStart((event: GestureEvent) => {
            if (event.fingerList.length > 0 && event.fingerList[0].localX > 300) {
              this.panKind = 'volume';
              this.panBase = this.volume;
            } else {
              this.panKind = 'bright';
              this.panBase = this.bright * 100;
            }
          })
          .onActionUpdate((event: GestureEvent) => {
            const delta: number = -event.offsetY / 3;
            if (this.panKind === 'volume') {
              this.volume = Math.max(0, Math.min(100, this.panBase + delta));
              this.applyVolume(this.volume);
              this.volumeHint = Math.round(this.volume);
            } else if (this.panKind === 'bright') {
              this.bright = Math.max(0.05, Math.min(1, (this.panBase + delta) / 100));
              if (this.win !== undefined) {
                this.win.setWindowBrightness(this.bright).catch((err: BusinessError) => {
                  console.error(`[amane] brightness: ${err.code} ${err.message}`);
                });
              }
              this.volumeHint = Math.round(this.bright * 100);
            }
          })
          .onActionEnd(() => {
            this.panKind = '';
            this.volumeHint = -1;
          })
      )
    )
  }

  @Builder
  PanelRow(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontColor(Theme.TEXT)
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick(() => {
        if (this.panelKind === 'subs') {
          this.pickSub(index);
        } else {
          this.pickAudio(index);
        }
      })
  }
}
