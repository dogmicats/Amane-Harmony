/*
 * 自动生成：public 通道构建配置（由 _publish/.local/build_release.py 产出）。
 *
 * 公开发布版刻意不带任何服务器地址或凭据：四个值全为空，
 * 用户首次启动请在「设置 → 连接」里填写。改这里等于给所有用户塞默认值，请勿这么做。
 */
export class BuildConfig {
  static readonly CHANNEL: string = 'public';
  static readonly APP_VERSION: string = '2.1.1';
  static readonly MIN_SERVER: string = '2.1.1';
  static readonly DEFAULT_AMANE: string = '';
  static readonly DEFAULT_USER: string = '';
  static readonly DEFAULT_WAN: string = '';
  static readonly DEFAULT_TOKEN: string = '';
  // 自动入库依赖部署者自建的 ingest worker，公开版默认关闭该 UI
  static readonly ENABLE_INGEST: boolean = false;
}
