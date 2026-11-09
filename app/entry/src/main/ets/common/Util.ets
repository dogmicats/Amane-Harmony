import { MediaItem } from './Types';

/** 展示用的格式化函数。 */

export function clock(seconds: number): string {
  if (!isFinite(seconds) || seconds <= 0) {
    return '00:00';
  }
  const total: number = Math.floor(seconds);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    return `${hh}:${mm}:${ss}`;
  }
  return `${mm}:${ss}`;
}

export function runtimeText(minutes: number): string {
  if (!minutes || minutes <= 0) {
    return '';
  }
  const h: number = Math.floor(minutes / 60);
  const m: number = Math.round(minutes % 60);
  if (h <= 0) {
    return `${m} 分钟`;
  }
  return m > 0 ? `${h} 小时 ${m} 分` : `${h} 小时`;
}

export function sizeText(bytes: number): string {
  if (!bytes || bytes <= 0) {
    return '';
  }
  let value: number = bytes;
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let unit: number = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value = value / 1024;
    unit++;
  }
  return `${value.toFixed(unit >= 3 ? 2 : 0)} ${units[unit]}`;
}

/** 继续观看的剩余时间描述。 */
export function remainText(position: number, duration: number): string {
  if (duration <= 0) {
    return '';
  }
  const left: number = duration - position;
  if (left <= 60) {
    return '即将播完';
  }
  return `剩 ${clock(left)}`;
}

export function dateText(iso: string): string {
  if (iso.length < 10) {
    return iso;
  }
  return iso.substring(0, 10);
}

export function scoreText(score: number): string {
  if (!score || score <= 0) {
    return '';
  }
  return score.toFixed(1);
}

/**
 * 把「只有列表字段」的条目补成完整 MediaItem，好让各页面共用同一个 PosterCard。
 * 分类页 / 演员作品页 / 共演结果都只有 id/number/title/release/poster/score，
 * 其余字段给安全默认值即可（PosterCard 只读这几个）。
 */
export function posterItem(
  id: number, number: string, title: string, release: string, poster: string, score: number,
  marks: string[] = []
): MediaItem {
  const item: MediaItem = {
    id: id, number: number, title: title, plot: '', actors: [], tags: [], studio: '', series: '',
    release: release, runtime: 0, content_type: '', score: score, poster: poster, fanart: '',
    updated_at: '', position: 0, duration: 0, marks: marks
  };
  return item;
}

/** 标记配色：破解粉 / 流出橙 / 无码青 / 中字蓝，与详情页保持一致。 */
export function markColor(label: string): string {
  if (label === '破解') {
    return '#FF6B8A';
  }
  if (label === '流出') {
    return '#FFB454';
  }
  if (label === '无码') {
    return '#7FE3C0';
  }
  return '#8FC6FF';
}
