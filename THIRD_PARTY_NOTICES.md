# Third-party notices

本仓库源码为 MIT。以下内容涉及随 HAP 分发或运行时用到的第三方组件。

| 组件 | 许可 | 说明 |
|---|---|---|
| [`@mpv-ohos/mpv-arkts`](https://ohpm.openharmony.cn/#/cn/detail/@mpv-ohos%2Fmpv-arkts) 1.0.0 | MIT | ArkUI 侧的 mpv 封装，提供播放与字幕轨道接口。 |
| libmpv / mpv | GPL-2.0-or-later（取决于构建选项） | 随 HAP 打包的 `libmpv.so`。其源码可从 [mpv 项目](https://github.com/mpv-player/mpv) 获取；重新分发时请遵循对应许可与源码提供义务。 |
| FFmpeg / 相关解码库 | 随 libmpv 构建而定（常见 LGPL-2.1+ / GPL-2+） | 请以你实际使用的 libmpv 构建为准，自行核对许可与源码获取说明。 |
| [Amane](https://github.com/sqzw-x/amane) | GPL-3.0 | **上游服务，本仓库不包含其任何源码**。仅通过 HTTP API 与只读 SQLite 交互。 |

> 本仓库不分发任何媒体文件或字幕文件，也不打包上述二进制（HAP 由使用者自行从本仓库源码构建；Releases 中的 HAP 由维护者构建，其中包含 libmpv）。
> 若你重新构建并分发 HAP，请自行确认所用 libmpv 的许可并附上相应的源码获取说明。
