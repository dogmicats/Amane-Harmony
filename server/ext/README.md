# 服务端扩展

`extensions.json` 是本目录的唯一清单，`server.py` 的 `ExtensionHost` 在启动时读取它，
按条目 `entry` 加载 `ext/<id>/server_ext.py`。核心代码里没有任何扩展的名字，
删掉清单中的一条即整体关掉该能力，不需要改核心。

当前随公版发布三个（都由 `GET /api/user/extensions` 自证已加载）：

| id | 端点前缀 | 作用 |
|---|---|---|
| `actors` | `/api/user/actors` | 演员列表 / 详情 / 作品 / 共演 / 剧照 / 写真 |
| `facets` | `/api/user/facets` | 标签 / 系列 / 制片商 / 我的标签 分类浏览 |
| `subtitles` | `/api/user/subtitle*` | 外挂字幕：同目录 / 手机导入 / 手动 URL / 记住选择 |

扩展只通过 `install(api)` 拿到 `route / add_ddl / add_init / hook` 与注入的
`amane_get / public_image / save_photo`，**不 import `server.py`**，也不写 `amane.db`。
