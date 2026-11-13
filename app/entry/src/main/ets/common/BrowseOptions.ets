/**
 * 浏览页共用的「筛选 / 排序选项」。
 *
 * ArkTS 是名义类型：两个字段一模一样的 interface 也不能互相赋值，所以 chip 选项
 * 只在这里定义一份，媒体库 BrowseGrid、搜索页、详情页跳转全部引用同一套 key，
 * 避免「18-24」在三处各拼一次 URL 拼出不同结果。
 *
 * 年龄分桶的 key 就是服务端 browse 的 cast_age_min-cast_age_max；
 * 岁数由服务端按「发行日 − 演员生日」现算，这里只负责把岁数归到哪一桶。
 * 性别口径（AGE_GENDERS / PREF_AGE_GENDER）也放在这里，默认女优。
 */
export interface ChipOption {
  key: string;
  label: string;
}

export interface SortOption {
  key: string;
  label: string;
  /** 选中时的默认方向，与服务端 SORTS 的默认值一致。 */
  def: string;
}

export const SORT_OPTIONS: SortOption[] = [
  { key: 'recent', label: '最近更新', def: 'desc' },
  { key: 'release', label: '发行日期', def: 'desc' },
  { key: 'score', label: '评分', def: 'desc' },
  // 用户自己打的分（ratings 扩展用 browse_sort 钩子给出分档 CASE 表达式）
  { key: 'myrating', label: '我的评分', def: 'desc' },
  { key: 'cast_age', label: '出演年龄', def: 'asc' },
  { key: 'number', label: '番号', def: 'asc' },
  { key: 'title', label: '标题', def: 'asc' },
  { key: 'runtime', label: '时长', def: 'desc' },
  // 2.5.7.7：按文件个数排 —— 多版本的排前面，方便从重复资源里挑着删
  { key: 'versions', label: '版本数', def: 'desc' },
  { key: 'random', label: '随机', def: 'desc' }
];

/**
 * 多版本（2.5.7.7）：browse 的 `multi` 参数。
 * 口径 = 该片在库里文件管理看到的文件条数（服务端现算 media_files，不缓存，
 * 所以删掉一个版本 / 新入库一个文件后，刷新列表就变）。
 */
export const VERSION_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '1', label: '多版本' },
  { key: '0', label: '单文件' }
];

export const AGE_BANDS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '18-24', label: '18–24 岁' },
  { key: '25-29', label: '25–29 岁' },
  { key: '30-34', label: '30–34 岁' },
  { key: '35-90', label: '35 岁以上' }
];

/**
 * 出演年龄看哪个性别：这个功能是给女演员做的，默认女优；男优只是可选
 * （「有人就喜欢看小孩男孩或大叔」）。key 就是服务端 browse 的 cast_age_gender，
 * 详情页徽章、媒体库筛选、搜索页筛选共用这一份。
 */
export const AGE_GENDERS: ChipOption[] = [
  { key: 'female', label: '女优' },
  { key: 'male', label: '男优' }
];

/** 全局偏好键：三处切换写的是同一个，切一处其他地方跟着变。 */
export const PREF_AGE_GENDER: string = 'ageGender';

export function ageGenderLabel(key: string): string {
  return key === 'male' ? '男优' : '女优';
}

/** browse 的性别参数：只认 female / male，其他一律按 female。 */
export function ageGenderParam(key: string): string {
  return `cast_age_gender=${key === 'male' ? 'male' : 'female'}`;
}

/**
 * 公开扩展 ratings：我自己打的分（与上游 javdb 评分的 SCORE_OPTIONS 分开）。
 * key 直接就是 browse 的 myrating 参数：1..5 = N 星以上，none = 未评分。
 * 所有带筛选的列表页共用这一份，别在各页各拼一套。
 */
export const MYRATING_OPTIONS: ChipOption[] = [
  { key: '', label: '全部' },
  { key: '5', label: '5 星' },
  { key: '4', label: '4 星以上' },
  { key: '3', label: '3 星以上' },
  { key: '2', label: '2 星以上' },
  { key: '1', label: '1 星以上' },
  { key: 'none', label: '未评分' }
];

export function sortLabelOf(key: string): string {
  for (let i = 0; i < SORT_OPTIONS.length; i++) {
    if (SORT_OPTIONS[i].key === key) {
      return SORT_OPTIONS[i].label;
    }
  }
  return '最近更新';
}

/** 外部指定初始排序时，用它取对应默认方向。 */
export function sortDefOf(key: string): string {
  for (let i = 0; i < SORT_OPTIONS.length; i++) {
    if (SORT_OPTIONS[i].key === key) {
      return SORT_OPTIONS[i].def;
    }
  }
  return 'desc';
}

/** 排序名按当前性别显示：cast_age → 「女优年龄 / 男优年龄」。 */
export function sortLabelWith(key: string, gender: string): string {
  return key === 'cast_age' ? `${ageGenderLabel(gender)}年龄` : sortLabelOf(key);
}

/** 某个具体岁数属于哪个分桶；0（资料不足）返回空串。 */
export function ageBandOf(age: number): string {
  if (age <= 0) {
    return '';
  }
  if (age < 25) {
    return '18-24';
  }
  if (age < 30) {
    return '25-29';
  }
  if (age < 35) {
    return '30-34';
  }
  return '35-90';
}

export function ageBandLabel(key: string): string {
  for (let i = 0; i < AGE_BANDS.length; i++) {
    if (AGE_BANDS[i].key === key) {
      return AGE_BANDS[i].label;
    }
  }
  return '';
}

/** 把「18-24」拆成 browse 需要的两个参数；key 为空返回空数组。 */
export function ageBandParams(key: string): string[] {
  const b: string[] = key.split('-');
  return b.length === 2 ? [`cast_age_min=${b[0]}`, `cast_age_max=${b[1]}`] : [];
}
