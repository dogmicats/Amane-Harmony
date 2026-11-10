/*
 * 自动生成：public 通道构建配置（由 _publish/.local/build_release.py 产出）。
 *
 * 公开发布版刻意不带任何服务器地址或凭据：四个默认值全为空，
 * 用户首次启动请在「我的 → 连接」里填写。改这里等于给所有用户塞默认值，请勿这么做。
 */
export class BuildConfig {
  static readonly CHANNEL: string = 'public';
  static readonly APP_VERSION: string = '2.3.0';
  static readonly MIN_SERVER: string = '2.3.0';
  static readonly DEFAULT_AMANE: string = '';
  static readonly DEFAULT_USER: string = '';
  static readonly DEFAULT_WAN: string = '';
  static readonly DEFAULT_TOKEN: string = '';
  // 服务端公开扩展：随本仓库一起发布，保持开启
  static readonly ENABLE_ACTORS: boolean = true;
  static readonly ENABLE_FACETS: boolean = true;
  static readonly ENABLE_SUBTITLES: boolean = true;
}
