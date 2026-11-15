"""meta 相关端点（从 Handler 拆出的 mixin）。

方法之间通过 `self.xxx` 互相调用 —— mixin 不 import 别的 mixin，
由 Handler 的 MRO 在运行时解析，所以拆到哪个文件都不影响调用。

顶部 `export_to(globals())` 把 core.logic 的所有名字（含 `_` 开头）注入本模块命名空间：
`import *` 会跳过私有名，而这里的方法大量用到 `_local_path_for` / `_json_dict` 这类，
漏一个就是运行时 NameError（2026-11-14 踩过）。
"""
from __future__ import annotations

import core.logic as _L

_L.export_to(globals())


class MetaMixin(object):
    @route("GET", r"/api/user/meta_override/(\d+)")
    def meta_override_get(self, query, metadata_id, *_) -> None:
        mid = int(metadata_id)
        ov = meta_override_map([mid]).get(mid) or {"fields": {}, "cover": ""}
        self._json({"ok": True, "data": {"id": mid, "fields": ov["fields"],
                                         "cover": ov["cover"]}})

    @route("PUT", r"/api/user/meta_override/(\d+)")
    def meta_override_put(self, query, metadata_id, *_) -> None:
        """部分更新：只存你传上来的键；传空串 / 空数组 = 清掉这个键的覆盖。"""
        mid = int(metadata_id)
        patch, err = clean_override(self._body())
        if err:
            return self._error(422, err)
        with user_db() as conn:
            row = conn.execute(
                "SELECT fields, cover FROM meta_override WHERE metadata_id = ?",
                (mid,)).fetchone()
            fields: dict = _json_dict(row["fields"]) if row else {}
            cover = str(row["cover"] or "") if row else ""
            for key, value in patch.items():
                if value == "" or value == []:
                    fields.pop(key, None)
                else:
                    fields[key] = value
            if fields or cover:
                conn.execute(
                    "INSERT INTO meta_override(metadata_id, fields, cover, updated_at) "
                    "VALUES(?,?,?,?) ON CONFLICT(metadata_id) DO UPDATE SET "
                    "fields = excluded.fields, cover = excluded.cover, "
                    "updated_at = excluded.updated_at",
                    (mid, json.dumps(fields, ensure_ascii=False), cover, now_iso()))
            else:
                # 一个字段都没改、也没有自定义封面 → 不留空壳记录
                conn.execute("DELETE FROM meta_override WHERE metadata_id = ?", (mid,))
        invalidate_item_caches()
        self._json({"ok": True, "data": {"id": mid, "fields": fields, "cover": cover}})

    @route("DELETE", r"/api/user/meta_override/(\d+)")
    def meta_override_delete(self, query, metadata_id, *_) -> None:
        """恢复默认：字段覆盖与自定义封面一起清掉（图还留在 photos 里，不删文件）。"""
        with user_db() as conn:
            removed = conn.execute(
                "DELETE FROM meta_override WHERE metadata_id = ?",
                (int(metadata_id),)).rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})

    @route("POST", r"/api/user/meta_override/clear")
    def meta_override_clear(self, query, *_) -> None:
        """清空所有本地修改（设置页），要二次确认。"""
        body = self._body()
        if body.get("confirm") is not True:
            return self._error(422, "要带 {\"confirm\": true} 才清")
        with user_db() as conn:
            removed = conn.execute("DELETE FROM meta_override").rowcount
        invalidate_item_caches()
        self._json({"ok": True, "data": {"removed": int(removed or 0)}})
