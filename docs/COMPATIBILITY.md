# 兼容性矩阵

本仓库不是 Amane 的插件，但 `amane-user` **直读上游 SQLite 的内部表结构**。上游改字段就可能需要同步适配，所以请把这张表当成部署前必读。

| 本仓库版本 | 验证过的上游 | 说明 |
|---|---|---|
| 2.3.0 | `sqzw-x/amane` main（2026-11 前后） | 播放代理块缓存 / 并行预取、共演检索导演筛选、分类收藏与随机排序、搜索联想、标签隐藏。依赖列同下。 |
| 2.2.0 | `sqzw-x/amane` main（2026-11 前后） | 首个功能完整版：服务端扩展层 + 演员 / 分类 / 字幕 / 播放器设置。`media_files` / `metadata` 依赖列见下。 |
| 2.1.x | 同上 | 发布链路联调版（首发 + 字幕修复），功能远少于 2.2.0，不建议继续使用。 |

CI 的 `schema-smoke.yml` 用最小 fixture 校验下列列存在；`upstream-watch.yml` 在上游发新 release 时自动开 issue 提醒复核。

## 依赖的 amane.db 列（只读）

| 表 | 列 | 用途 |
|---|---|---|
| `media_files` | `id`, `path`, `metadata_id`, `library_id`, `size`, `duration`, `definition`, `mosaic`, `has_subtitle_in_name`, `has_external_subtitle`, `oshash`, `created_at` | `created_at` 用于分类「最近更新」排序（2.3.0 起） |
| `metadata` | `id`, `number`, `title`, `plot`, `actors`, `tags`, `studio`, `series`, `release`, `runtime`, `content_type`, `poster_urls`, `thumb_urls`, `extrafanart_urls`, `scores`, `updated_at` | |
| `libraries` | `id`, `name` | |
| `tags` / `series` / `studios` / `publishers` / `directors` | `id`, `name`, `is_favorite` | 分类列表由旁挂服务直读自算（缩略图、收藏、时间维度都靠它） |
| `metadata_tags` / `metadata_directors` / `metadata_actors` | `tag_id` / `director_id` / `actor_id` + `metadata_id` | 分类与演员的作品关联 |
| `actors` | `id`, `name`, `gender` | 演员扩展直查（头像 / 作品 / 共演） |
| `actor_gallery` | `actor_id`, `url` | 演员写真库 |

`oshash` 是上游按需计算的 OpenSubtitles moviehash，本版本只把它透出到 `/api/user/item/{id}` 的 `files[]`，**不使用**（为将来的在线字幕源预留）。老条目里它可能是 NULL。

## 依赖的 Amane HTTP 接口

| 端点 | 用途 |
|---|---|
| `GET /api/health` | 客户端自动选路探测 |
| `GET /api/playback/{source}/{id}` | 播放流（由旁挂服务补 Bearer 头后转发） |
| `GET /api/actors*` / `GET /api/metadata*` | 演员扩展的列表 / 详情 / 头像（透传上游，本服务不建表不写库） |
| `POST /api/facets/{kind}/batch` | 分类收藏（「置为」语义，不是取反） |
| `PATCH /api/metadata/{id}` | 可选：元数据补写 |

## 字幕命名口径

对齐上游 `library/rules.py::has_companion_subtitle`：同目录、`stem` 相同或 `<stem>.` 开头、扩展名在库配置的 `subtitle_extensions`（默认 `.srt/.ass/.ssa/.vtt/.sub`）内。上游只把结果存成布尔 `has_external_subtitle`，**不存路径**，所以本服务自己重新扫一次同目录。

## 部署形态限制

旁挂服务必须能读到 `amane.db`（同机或共享存储）。跨主机纯 REST 回退不在本版本范围内。
