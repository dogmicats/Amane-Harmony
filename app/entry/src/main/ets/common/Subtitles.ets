import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { httpGet, httpPost, httpPut } from './Http';
import { Store } from './Store';

/**
 * 外挂字幕客户端。
 *
 * 所有来源（同目录 / 手机导入 / 手动 URL）最终都拿到一个 subtitle_id，
 * 播放页只负责把 streamUrl() 交给 SubtitleTrack.uri()，不必关心字幕从哪来。
 * 在线字幕源未启用：服务端 /api/user/subtitles/providers 恒返回空数组。
 */

export interface SubtitleItem {
  id: string;
  name: string;
  source: string;
  lang: string;
  size: number;
}

export interface LocalCandidate {
  name: string;
  size: number;
  lang: string;
}

export interface SubtitleChoice {
  item_id: number;
  subtitle_id: string;
}

export interface SubtitleListResult {
  local: LocalCandidate[];
  cached: SubtitleItem[];
  choice: SubtitleChoice | null;
  providers: string[];
}

export class SubtitleClient {
  private static q(): string {
    return `token=${encodeURIComponent(Store.I.token)}`;
  }

  /** 给 mpv 的字幕地址。asVtt=true 时服务端把 SRT 转成 WebVTT 兜底。 */
  static streamUrl(id: string, asVtt: boolean): string {
    const fmt: string = asVtt ? '&format=vtt' : '';
    return `${Store.I.user}/api/user/subtitle/${id}?${SubtitleClient.q()}${fmt}`;
  }

  static async list(itemId: number): Promise<SubtitleListResult> {
    const url: string =
      `${Store.I.user}/api/user/subtitles?item_id=${itemId}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as SubtitleListResult;
  }

  /** 把视频同目录的字幕读进服务端缓存，返回统一的 subtitle_id。 */
  static async loadLocal(itemId: number, name: string): Promise<SubtitleItem> {
    const url: string = `${Store.I.user}/api/user/subtitles/local` +
      `?item_id=${itemId}&name=${encodeURIComponent(name)}&${SubtitleClient.q()}`;
    const text: string = await httpGet(url, Store.I.token);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 手机文件选择器 → 读字节 → base64 上传 → 服务端缓存。 */
  static async importFromPhone(ctx: common.UIAbilityContext): Promise<SubtitleItem> {
    const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await view.select(opts);
    if (uris.length === 0) {
      throw new Error('未选择文件');
    }
    const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer;
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    const b64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
    const parts: string[] = uris[0].split('/');
    const name: string = parts.length > 0 ? parts[parts.length - 1] : 'phone-subtitle.srt';
    const url: string = `${Store.I.user}/api/user/subtitles/import?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ filename: name, content: b64 });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 手动字幕 URL：由服务端抓取（带超时与体积上限），不直接交给播放器。 */
  static async addUrl(subUrl: string): Promise<SubtitleItem> {
    const url: string = `${Store.I.user}/api/user/subtitles/url?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ url: subUrl });
    const text: string = await httpPost(url, Store.I.token, body);
    return JSON.parse(text) as SubtitleItem;
  }

  /** 记住该片上次选的字幕。 */
  static async remember(itemId: number, subId: string): Promise<void> {
    const url: string = `${Store.I.user}/api/user/subtitles/choice?${SubtitleClient.q()}`;
    const body: string = JSON.stringify({ item_id: itemId, subtitle_id: subId });
    await httpPut(url, Store.I.token, body);
  }
}
