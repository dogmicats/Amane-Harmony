#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import base64
import hashlib
import io
import json
import mimetypes
import os
import random
import re
import select
import socket
import sqlite3
import sys
import threading
import time
import traceback
import unicodedata
from collections import OrderedDict
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, build_opener, ProxyHandler, urlopen


# 路径 / 环境 / 常量已搬到 core/config.py（2.6.1.87 拆模块第一步）。
# 入口名与 `python3 server.py` 的用法不变；这里只是把定义换成导入，
# 所以原来能用的模块级名字（USER_DB / AMANE_DB / PORT / AMANE_TOKEN …）全部照旧可用。
from core.config import (  # noqa: E402  (必须在常量之后，读的是同一批环境变量)
    AMANE_BASE, AMANE_DATA, AMANE_DB, AMANE_TOKEN, DATA_DIR, FINISH_RATIO,
    IMAGE_CACHE, PHOTO_DIR, PORT, PUBLIC_AMANE_URL, ROOT_DIR, UPSTREAM_CONF,
    USE_LOCAL_PLAY, USER_DB, _read_secret, save_photo,
)

# ---- 以下为原 server.py 同名定义，已移入 core/config.py ----
#   FINISH_RATIO / _upstream_conf / UPSTREAM_CONF / _default_data_dirs /
#   _resolve_data_dir / _reachable / _resolve_base / AMANE_BASE / AMANE_DATA /
#   DATA_DIR / PHOTO_DIR / _PYLIB_DIR(副作用) / PORT / PUBLIC_AMANE_URL /
#   USER_DB / AMANE_DB / IMAGE_CACHE / _read_secret / AMANE_TOKEN / USE_LOCAL_PLAY /
#   save_photo


# --------------------------------------------------------------------------- #
# 上游能力自检（P1）
#
# 上游在持续发版，旁挂靠「只读它的表 + 调它的 HTTP」活着。逐个版本适配是无底洞，
# 所以只做一件事：**启动后看一眼需要的东西还在不在**，缺了就报出来并降级，
# 而不是等某个页面 500 了再猜。完整的能力矩阵与漂移比对在 tools/upstream.py。
# --------------------------------------------------------------------------- #

# 旁挂真正依赖的「能力」：列在就用，不在就降级（不是所有上游版本都有）。





# 外链图片只允许这些主机，避免把这个端口变成任意 URL 代理


# 日志已搬到 core/log.py（2.6.1.89 拆模块第二步）。
# 这里保留 `log` 这个名字对外可用：server.py 内部还有几百处 `log(...)` 调用，
# 拆模块期间不做批量改名（改一处引一批风险，收益却只是好看）。
from core.log import log  # noqa: E402,F401


# --------------------------------------------------------------------------- #
# 关键词相关性：清单页搜索框统一口径（2.4.6.21）
#
# 各清单（影片库 / 演员 / 标签·系列·导演 / 收藏）除了「指定筛选」，还要能直接打
# 关键词搜。只做 LIKE 有两个问题：一是全角/大小写/连字符不同就搜不到，二是命中
# 之后没有「像不像」的顺序 —— 搜「三上」时「三上悠亜」和「三上理子」谁在前全看
# 作品数。所以这里给出一套归一化 + 分档打分：
#
#   0 完全相等      normalize 之后一模一样（SPSD-014 = spsd014）
#   1 前缀          名字以关键词开头
#   2 词首          多词名字里任一词以关键词开头（Yui Hatano ← hatano）
#   3 包含          名字里带这段
#   4 子序列        字符按序出现即可（大桥未久 ← 大桥久），只对短查询开放
#   None 不命中
#
# 为什么做成 SQLite 函数：过滤（IS NOT NULL）和排序（升序）都得在 SQL 里一次
# 完成，否则「先取一页再排」会让分页算不准；这几张表都只有几千~几万行，全表过
# 一次 Python 回调在可接受范围内。
# --------------------------------------------------------------------------- #
# 关键词相关性已搬到 core/text.py（2.6.1.89）。这三个名字被 db 层
# （`conn.create_function("amane_rel", 2, rel_score)`）和检索端点共用，
# 留在 server.py 会形成 core → 入口的反向依赖。
from core.text import _SEP_RE, _norm_kw, _subseq, rel_score  # noqa: E402,F401


# --------------------------------------------------------------------------- #
# 检索归一化：简繁 + 拼音（2.5.1）
#
# 目标只有一个：**输得不准也要搜得到**。
#   * 输繁体（癡女）要命中简体（痴女）—— 逐字 t2s，只改查询侧，不动库里的数据；
#   * 输拼音首字母（scg）要命中中文名（搜查官）—— 预先算好「名字 → 首字母/全拼」，
#     命中后拿回 (kind, name) 再拼回原 WHERE，**不建影片级索引**（那要几万行）。
#
# 两张表是离线生成后随代码部署的静态数据（`tools/gen_cjk_tables.py`）：
#   data/t2s.tsv     繁 → 简
#   data/pinyin.tsv  汉字 → 首字母 / 全拼
# 部署镜像 python:3.12-slim 装不了 pypinyin / opencc，所以运行时只读这两张表；
# 表缺失时所有新能力**静默降级**，检索行为与没做这个功能时完全一致。
#
# data/alias.tsv 是「俗称 → 库里真有的名字」的补丁表（牛头人 / ntr → 那个日文标签）：
# 俗称本身不是任何一条记录的名字，拼音引擎无从命中，只能靠这张小表桥接。
# 它是**数据**，加词不用改代码。
# --------------------------------------------------------------------------- #


















# 只索引名字，不索引到影片：命中 (kind, name) 之后拼回原 WHERE（见 browsing 里的
# _PY_COND）。建影片级索引要几万~几十万行，且每次入库都得重算，不划算。








# 折叠别名的范围（2.5.1.18）：
#   * tag / actor —— 人们真的会照着打字的名字，必须收；
#   * series —— 只收短名。库里 240 个含日文异体字的系列**全是长日文标题**，
#     没人会把「10発中出しするまで…」简化了再打，收进来只是白占地方。






# (kind, name) → 拼进 WHERE 的片段。tag 走子查询，series 是标量，actor 在
# metadata.actors 里（逗号分隔的规范名，用 LIKE 足够）。
# 一个词最多扩出几条名字条件（见 search_clauses 的说明）










































# --------------------------------------------------------------------------- #
# 扩展宿主（Extension Host）
#
# 核心服务只提供通用能力：收藏 / 观看历史 / 首页聚合 / 图片代理 / 播放流代理。
# 个性化能力（例如把网盘库搬到本地库）放在 extensions/ 下，按
# /app/extensions.json 清单动态加载。scope=private 的扩展不随公版发布，
# 因此 public 部署既没有这些端点，也不包含任何个人库拓扑信息。
# --------------------------------------------------------------------------- #







# --------------------------------------------------------------------------- #
# 数据库
# --------------------------------------------------------------------------- #

# 数据库连接已搬到 core/db.py（2.6.1.89 拆模块第三步）。
# 名字原样保留：server.py 里上千处 `with user_db() as conn` 一行都不用改。
from core.db import amane_db, user_db  # noqa: E402,F401




from core.util import now_iso, _json_list, _json_dict  # noqa: E402,F401


def _deploy_info() -> dict:
    """本次部署的来源（`deploy_dev.py` 打包时写入 `deploy-info.json`）。

    为什么要有：8771 只有一个实例，谁部署谁生效。以前被覆盖了**界面上看不出来**，
    只能感觉「刚才还好好的怎么没了」，也不知道是谁什么时候换的。
    现在 `/ping` 里直接带着 commit / 部署人 / 时间，一调就知道手上跑的是哪份代码。

    缺文件时返回空 dict，老部署不受影响（纯新增字段）。
    """
    try:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deploy-info.json")
        with open(p, "r", encoding="utf-8") as f:
            d = json.load(f)
        return {
            "commit": str(d.get("commit", ""))[:12],
            "branch": str(d.get("branch", "")),
            "deployed_by": str(d.get("by", "")),
            "deployed_at": str(d.get("at", "")),
            # 空串 = 干净（等于从该 commit 部署）；有值 = 当时带未提交改动，值为 diff 指纹
            "dirty": str(d.get("dirty", "")),
        }
    except Exception:  # noqa: BLE001
        return {}



# --------------------------------------------------------------------------- #
# 播放采样与报表统计（2.5.3）
#
# 为什么另起一张表：`history` 是**覆盖式**的（一片一行，只留最后位置）。拖一下进度、
# 再看一遍，之前那次就被盖掉，写进去改不回来 —— 用它算「最常看哪一段」永远算不准，
# 而且越用越偏。所以采样改成**只追加**：每次上报新增一行，永不改旧行；口径错了就
# 按新口径整批重算，不靠猜。
#
# 分层（派生层随时可 DROP 重建，见 POST /api/user/stats/rebuild）：
#   play_progress  原始采样（只 INSERT；明细保留 STATS_KEEP_DAYS 天）
#   stats_daily    按 (日, 片)：观看秒数 / 采样数 / 最大位置 / 当日是否看完
#   stats_hour     按 (日, 小时)：时段与星期分布
#   stats_heat     按 (片, 5% 分桶)：热度条；metadata_id = 0 那一份是全库合计
#   stats_meta     口径版本、已消费到的采样 id、清洗计数（JSON）
#
# 归日/归时一律用**客户端上报的本地日期与小时**（local_date / local_hour）：
# 容器时区是 UTC，按服务端算会把「同一晚看的两部」劈成两天。老客户端不带这两个
# 字段时按服务端本地时间兜底，并在 quality 里体现为估算。
# --------------------------------------------------------------------------- #



# 派生表的索引单独放着：老库升级时要先 DROP 再建，索引不能跟建表语句一起跑
# （老表没有 scope 列时会 "no such column: scope"，服务直接起不来）。







































# --------------------------------------------------------------------------- #
# 报表 v2（2.5.3 第二批）：弃片 / 流失曲线 / 吃灰 / 转化漏斗 / 评分冲突
#
# 全部只读**派生层** `stats_daily`（它已经是「按日 × 按片」的聚合）加两张小表
# （`favorites` / `user_ratings`），**不碰 `play_progress` 明细** —— 明细几十万行，
# 每开一次页面扫一遍会明显变慢。派生层每次 rebuild 都会跟着更新，所以不另建表。
# --------------------------------------------------------------------------- #













# --------------------------------------------------------------------------- #
# Tier 图（2.5.4）：把星级排成五档，一次「生成」= 一张快照
#
# 为什么是快照而不是每次现算：图是要存历史、挑一张挂在统计页上的（用户能留几张对比）。
# 快照存**筛选条件 + 每档的条目 id/展示图/文字**，之后库里的评分变了也不动这张图 ——
# 要更新就重新生成，旧的自然留在历史里。图只存 URL，不存二进制。
#
# 五档固定（用户定，不许改档名）：5 夯 / 4 顶级 / 3 人上人 / 2 NPC / 1 拉完了。
# 分档、排序、上限、默认条件**全在服务端算**，客户端只渲染（契约见
# `docs/TASKS/2.5.4-tierlist.md` §4）。
# --------------------------------------------------------------------------- #



# 2.5.5 元数据覆盖层：只存**被改过的字段**，amane 库一个字都不写。
# 为什么不写回库：库是刮削产物，写回去下次刮削就冲掉，删了也不好找回。

# 2.5.6 投屏令牌：电视 / 盒子只认这一种「只能读媒体」的短时凭证。
#
# 为什么不能直接把主 token 交给电视：那是万能钥匙（能改覆盖层、能删快照），
# 一旦进了电视的日志或第三方 App 就等于泄露。这里发的是**只读媒体专用**的：
# 仅 `/play` `/streams` `/photo` `/studio-logo` 四条 GET/HEAD 路径认它，别的一律 401。

# 2.5.5.4 分类封面：系列 / 标签 / 厂牌 / 演员 / 媒体库也能换封面（含动图）。
# key 一律用**名字**，不用 id —— 用户自己新起的系列在库里没有 id，
# 用名字才能让「新建的分类」和「库里的分类」走同一套封面。




























# --------------------------------------------------------------------------- #
# amane 元数据（直读 SQLite）
# --------------------------------------------------------------------------- #


# 联想搜索可选的类型。顺序即客户端 chip 的默认顺序，也是返回结果里的排序。
# film 由核心自己查；其余实体由扩展通过 `suggest_entities` 钩子补，核心不直连它们的表。

# 搜索历史只留最近 N 条：它是「最近搜过」的快捷入口，不是操作日志。




# 出演时岁数：上游没有这个字段，用 metadata.release − actors.birthday 现算周岁。
#
# 2026-11-10 用户定：这个功能是给女演员做的 —— 男演员的岁数默认既不在详情页显示、
# 也不参与筛选/排序；要算男性（「有人就喜欢看小孩男孩或大叔」）用
# cast_age_gender=male 显式切过去。性别取值只有 FEMALE / MALE（上游另有 UNKNOWN，
# 不属于任何一档，天然不参与）。
#
# 与扩展 /item/{id}/cast 的 _age_of() 同口径：只有 18–90 岁才算有效（客户端分桶
# 从 18 起）。上游有少量脏生日（只读抽查升序头部先出现 4/5/6 岁、收紧到 10 岁后
# 仍有 12 岁），不滤掉会把这些片顶到首页，也和详情页对不上。聚合里用 CASE 把
# 异常值变 NULL，SQLite 的 MIN/MAX 自动忽略 NULL；不能用 HAVING，相关子查询里
# 不想再套一层派生表。

# 对外只认这两个值；其他（含空）一律回落 female。
# 客户端 key -> 上游 actors.gender 的取值。





# 维度过滤：分类墙（标签/系列/制片商/导演）、演员作品、共演结果这些列表页，
# 本质上都是「某个维度下的影片列表」。统一由 browse 承接，新加的筛选（我的评分、
# 收藏夹）和排序（我的评分）才能一处生效，不用每个端点各写一遍。
# 同一个参数里多值用逗号 = AND（演员作品页的「本人 + 合作演员」就是这个口径）。
# 每个 SQL 都以 m.id 为锚点，{marks} 是占位符个数、{n} 是多值个数。




# 排序键按「哪个性别 + 哪个方向」预生成：升序比该性别里最年轻的那位，
# 降序比最年长的那位（2.4.5.4 用户定，不再固定取最年轻）。

# 排序键 -> (SQL 表达式, 默认方向)。评分在 scores JSON 里，只有 javdb 一个来源。








































# --------------------------------------------------------------------------- #
# 元数据覆盖层（2.5.5）
#
# 用户在手机上改片名 / 演员 / 标签 / 封面时，**只写 user.db 的 meta_override**，
# amane 的库一个字都不动（它是刮削产物，写回去下次刮削就冲掉）。
# 读的时候「覆盖优先」：列表、详情、搜索、收藏、观看记录都吃同一份合并结果，
# 客户端不做合并判断。批量取一页时只查一次（`meta_override_map`），别逐条查。
# --------------------------------------------------------------------------- #

















# --------------------------------------------------------------------------- #
# GIF 轮播封面（2.5.5.5）
#
# 用一部片自己的剧照拼一段循环动图，存成普通封面（`meta_override.cover`），
# 客户端 Image 就会自己播 —— 不需要另建一套「动图播放器」。
# 依赖 Pillow（可选）：容器镜像没带，装在 /data/pylibs，见文件头。
# --------------------------------------------------------------------------- #



























# 投屏令牌的进程内缓存：媒体请求（尤其 Range）会连打十几次，
# 每次都查 SQLite 没必要；命中就 60 秒内不再查库。














# --------------------------------------------------------------------------- #
# 相似影片：详情页底部推荐
#
# 四种信号的强弱差得很远：同系列几乎是「同一部片的不同集」，同演员次之，
# 共同标签是口味相近；同厂牌 / 同年份只是弱相关 —— 只按厂牌选，GIGA 的 1857 部
# 能把一整屏填满，那不叫相似。所以后两者只加分，不单独进候选。
# --------------------------------------------------------------------------- #









# --------------------------------------------------------------------------- #
# 全库统计摘要（2.5.7.21 · 每日推荐理由的「全库级」事实）
# --------------------------------------------------------------------------- #
# 口径与 query_meta / count_meta 一致：只算「还有文件的片」。
# 一次全表扫拿齐评分分布与各维度计数，按「日期 + amane.db 小时级 mtime」缓存；
# home 自己的 5 分钟缓存不会触发重扫。下发给客户端时只保留这一批卡片涉及的键，
# 所以响应体积不随全库规模膨胀。服务端老版本没有这个字段时，客户端自动跳过全库族。










# --------------------------------------------------------------------------- #
# 首页聚合
# --------------------------------------------------------------------------- #















# --------------------------------------------------------------------------- #
# 每日推荐横幅：只挑「真横图」，并把真实宽高比带给客户端
#
# 为什么不能直接用 pick_fanart：它的候选里混着竖版样图（147x200、600x800），
# 拉到 16:9 只裁中间一条，看起来又糊又不像横幅。这里逐张验证尺寸（结果落
# user.db 的 img_dims，第二次起零下载），并让客户端按真实比例定宽。
# --------------------------------------------------------------------------- #













# --------------------------------------------------------------------------- #
# 剧照宽高比：详情页瀑布流的地基
#
# 剧照里横图竖图混着来（16:9 截图 + 竖版海报），详情页原来一律按 190x107 铺开，
# 竖版就只剩中间一条。瀑布流要按真实比例各自定高，所以这里把比例一起下发。
# 尺寸复用 img_dims（横幅预热已经在量），没量过的先给 0 让客户端自己量，
# 同时后台补一刀，下次进同一部片子就准了。
# --------------------------------------------------------------------------- #





















# --------------------------------------------------------------------------- #
# 备份 / 回滚快照（2.6.1.54）
#
# 导入是会改用户数据的动作，出错必须能退回去。做法：**导入前先拍一张这五张表的快照**
# 落到 `DATA_DIR/backup/import-<ts>.json`，回滚就是把快照整表灌回去。
# 快照只留最近 BACKUP_KEEP 份（rules/20 §A.1：会写文件的自动化必须自带保留策略）。
# --------------------------------------------------------------------------- #













# --------------------------------------------------------------------------- #
# 图片代理
# --------------------------------------------------------------------------- #





# --------------------------------------------------------------------------- #
# 扩展可复用的通用能力
#
# 核心只提供「怎么安全地去上游取数、怎么把外链图片变成客户端能加载的 URL」，
# 不认识任何具体扩展。扩展由 ExtensionHost.load() 注入这两个函数，
# 因此不必自己读 /amane-data/token，也不会和核心的白名单判断产生分叉。
# --------------------------------------------------------------------------- #

from core.upstream import amane_get, amane_post  # noqa: E402,F401








# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

# 路由表与 @route 装饰器已搬到 core/router.py（2.6.1.90）。
# ROUTES 是可变全局：这里拿到的是同一个 list 对象，下面 138 个 @route 装饰器
# 往里面追加的东西，main() 遍历时都能看到。
from core.router import ROUTES, route  # noqa: E402,F401
from core.image import (  # noqa: E402,F401
    IMAGE_TOKEN, IMG_HOST_ALLOW, IMG_PROBE_BYTES, _b64url, _dims_get, _dims_put,
    _host_ok_cache, _image_size, _img_proxy, _unb64url, host_allowed, image_dims,
    public_image,
)
from core.ext import EXT, ExtensionHost  # noqa: E402,F401











# 业务逻辑全部搬到 core/logic.py（2.6.1.92）。
# 用 star import 是刻意的：Handler 里 138 个方法引用了上百个逻辑函数，
# 逐个列举既长又容易漏；拆 mixin 之后会改成显式 import。
from core.logic import *  # noqa: E402,F401,F403

# ★ `import *` 不会导入下划线开头的名字 ★
# `_bootstrap_name_pinyin` / `_local_path_for` / `_json_dict` 这类全是私有命名，
# star import 一律跳过 —— 但 main() 和 Handler 的方法里用得很频繁。
# 2026-11-14 这里漏了一次：容器起来就 `NameError: _bootstrap_name_pinyin is not defined`。
# 下面把 logic 里所有单下划线名都补进本模块的全局表，一次性解决。
import core.logic as _logic_mod  # noqa: E402

for _n in dir(_logic_mod):
    if _n.startswith('_') and not _n.startswith('__'):
        globals()[_n] = getattr(_logic_mod, _n)
del _n

from api.stats import StatsMixin  # noqa: E402
from api.home import HomeMixin  # noqa: E402
from api.browse import BrowseMixin  # noqa: E402
from api.search import SearchMixin  # noqa: E402
from api.item import ItemMixin  # noqa: E402
from api.mine import MineMixin  # noqa: E402
from api.tier import TierMixin  # noqa: E402
from api.meta import MetaMixin  # noqa: E402
from api.virtual import VirtualMixin  # noqa: E402
from api.cover import CoverMixin  # noqa: E402
from api.cast import CastMixin  # noqa: E402
from api.backup import BackupMixin  # noqa: E402
from api.upgrade import UpgradeMixin  # noqa: E402
from api.stream import StreamMixin  # noqa: E402
from api.misc import MiscMixin  # noqa: E402
from api.play import PlayMixin  # noqa: E402
from api.storage import StorageMixin  # noqa: E402
class Handler(StorageMixin, PlayMixin, MiscMixin, StreamMixin, UpgradeMixin, BackupMixin, CastMixin, CoverMixin, VirtualMixin, MetaMixin, TierMixin, MineMixin, ItemMixin, SearchMixin, BrowseMixin, HomeMixin, StatsMixin, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"amane-user/{VERSION}"

    # -- 基础设施 ---------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if os.environ.get("VERBOSE"):
            log(f"{self.address_string()} {fmt % args}")

    def _json(self, payload: dict | list, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, detail: str) -> None:
        self._json({"detail": detail}, status)

    def _authed(self, query: dict) -> bool:
        if not AMANE_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {AMANE_TOKEN}":
            return True
        return (query.get("token") or [""])[0] == AMANE_TOKEN

    # 投屏令牌只放行这四类**只读媒体**路径（2.5.6）。
    # 电视 / 盒子拿到的就是这个 `ct`，绝不能让它顺手改数据或删快照。
    CAST_PATHS = ("/api/user/play/", "/api/user/streams/",
                  "/api/user/photo/", "/api/user/studio-logo/",
                  # 电视要能自己拉字幕与封面（都是只读的东西）
                  "/api/user/subtitle/", "/api/user/subtitles",
                  "/api/user/cast/cover/")

    def _cast_ok(self, path: str, method: str, query: dict) -> bool:
        if method not in ("GET", "HEAD"):
            return False
        token = (query.get("ct") or [""])[0]
        if not re.fullmatch(r"[0-9a-f]{32}", token or ""):
            return False
        if not path.startswith(self.CAST_PATHS):
            return False
        return cast_token_valid(token)

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0 or length > 16 * 1024 * 1024:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    # -- 分发 -------------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_HEAD(self) -> None:  # noqa: N802
        # mpv 会用 HEAD 探测长度/类型，只回头部不读流
        self._dispatch("HEAD")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        try:
            if parsed.path == "/img":
                return self._image(query)
            if parsed.path == "/api/user/ping":
                return self._json({"ok": True, "version": VERSION, "time": now_iso(),
                                   **_deploy_info()})
            if not self._authed(query) and not self._cast_ok(parsed.path, method, query):
                return self._error(401, "缺少或无效的 token")
            for m, regex, fn in ROUTES:
                if m != method:
                    continue
                match = regex.match(parsed.path)
                if match:
                    return fn(self, query, *match.groups())
            return self._error(404, "not found")
        except BrokenPipeError:
            return
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR {method} {self.path}: {exc}\n{traceback.format_exc()}")
            return self._error(500, str(exc))

    # -- 图片 -------------------------------------------------------------

    def _image(self, query: dict) -> None:
        url = (query.get("u") or [""])[0]
        encoded = (query.get("b") or [""])[0]
        token = (query.get("t") or [""])[0]
        if IMAGE_TOKEN and token != IMAGE_TOKEN and not self._authed(query):
            return self._error(401, "图片 token 无效")
        if encoded:
            try:
                url = _unb64url(encoded)
            except (ValueError, UnicodeDecodeError):
                return self._error(400, "b 解码失败")
        if not url:
            return self._error(400, "缺少 u")
        if not (url.startswith("http://") or url.startswith("https://")):
            return self._error(400, "只代理 http(s) 图片")
        try:
            data, ctype = serve_image(url)
        except ValueError as exc:
            return self._error(400, str(exc))
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            # 旁挂自己取不到（出海被挡 / 源站 5xx / 超时）→ **302 回原始地址**，
            # 让客户端用自己的网络兜底（用户 2026-11-14 23:26 明确要求）。
            # 直接 502 的话，手机明明能上却看到一张破图 —— 头像、海报都会这样。
            log(f"图片代理抓取失败，302 回源: {url[:120]} | {exc}")
            self.send_response(302)
            self.send_header("Location", url)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        self.wfile.write(data)



    # -- 播放流代理 -------------------------------------------------------
    #
    # 为什么不直连 amane：@mpv-ohos/mpv-arkts 1.0.0 的 httpHeaders 实现有 bug，
    # 会把 "Authorization" 编成 "%65%authorization"（Caddy access.log 实锤），
    # amane 一律 401；而 /api/playback 又不像 /api/resources 那样认 ?token=。
    # 于是客户端只把 token 放进 URL（mpv 对 query 没有任何加工），由这里补正确的
    # Bearer 头回源，Range / 206 / Content-Range 原样透传。
    # 纯标准库流式转发，不在内存里攒整个文件；ThreadingHTTPServer 每路一个线程。

    PLAY_HOP_HEADERS = (
        "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
        "ETag", "Last-Modified", "Cache-Control",
    )

    # 同一部片的并发流登记簿（source/mid → 会话列表）。
    #
    # **只清理真正僵住的流**（客户端已经不再读、write 卡住），绝不按「同片只留一路」
    # 来掐：mp4 的 moov 常常在文件尾部，mpv 正常播放就会另开一条连接读索引，
    # 两条连接互掐会变成「永远建不完缓冲」（2026-11-10 实测把用户坑了一次）。
    _stream_lock = threading.Lock()
    _stream_sessions: dict[str, list] = {}


    # ------------------------------------------------------------ 数据备份
    BACKUP_FORMAT = "amane-backup/1"







    # ---- 服务端自动升级（2026-11-13）-------------------------------------- #
    # 现实约束：App 没有在用户机器上执行 docker 的能力，真正的升级必须由宿主机上
    # 的 `deploy/auto-update.sh` 定时器做。这里只做「开关 / 立即升级 / 状态」三件事，
    # 三个小 JSON 都落在 DATA_DIR —— 定时器读的是宿主机上同一个卷，所以两边能对上。
    # 状态文件不存在 = 这台机器没装助手，客户端就该退回原来的手动步骤。


    @staticmethod
    def _read_json_dict(path: str) -> dict:
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    @staticmethod
    def _write_json_dict(path: str, payload: dict) -> None:
        """原子写：先写 .tmp 再 replace，定时器不会读到半个文件。"""
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, path)






    # ---- 网盘源块缓存 ---------------------------------------------------- #
    #
    # 为什么必须有它：像 MIDE-776 这种文件，**音轨和视频轨在文件里各占一大片**
    # （1800s 处视频在 2.21GB、音频在 3.16GB），解复用器必须来回跳 —— ffmpeg 实测
    # 8 秒里 seek 了 389 次，每次 seek 都是一条新的 Range 请求。每条都回源 CD2
    # （冷区首字节 0.3~4.6s）的话，播放器永远填不满缓存（HUD 缓存秒数 0.1s 0.1s 爬）。
    #
    # 做法：块任务（_PlayJob）边下边用 —— 客户端不必等整块下完就能拿到开头的数据；
    # 块按 1MiB 对齐存进 LRU，并**并行**预取后面若干块。这样 CD2 的冷启动延迟被
    # 多个块同时摊掉，播放点前面始终有几秒到十几秒的余量。
    # 4MiB：实测这类「音轨与视频轨各占一大片」的文件，解复用器每秒来回跳十几次，
    # 1MiB 块每次跳都要回源一次（首字节 40–300ms）。块放大到 4MiB 后，
    # 一个区域被命中一次就能连续供好几秒画面，来回次数直接降到 1/4。
    PLAY_BLOCK = 4 * 1024 * 1024
    PLAY_CACHE_VERSION = 4
    PLAY_READAHEAD = 2
    PLAY_MAX_JOBS = 96
    PLAY_CACHE_BYTES = int(os.environ.get("AMANE_PLAY_CACHE_MB", "512")) * 1024 * 1024
    # 多久「没写过东西」才算僵尸流。**不能设 1.5 秒**：mpv 自己的缓存满了会正常停止读取
    # 十几秒甚至更久，早先按 1.5 秒判死，就会出现「播着播着又被判死 → 重新起流 →
    # 再缓存」的死循环（本地片也一样，所以不是网盘的问题）。
    PLAY_STALL_DROP = float(os.environ.get("AMANE_PLAY_STALL_DROP", "30"))
    _play_lock = threading.Lock()
    _play_blocks: OrderedDict = OrderedDict()
    _play_stat: dict = {"bytes": 0}
    _play_jobs: dict = {}
    _play_meta: dict[str, dict] = {}
    # 每条 session 上一次读到的块号（判断是否顺序读）
    _play_seq: dict[str, int] = {}








    # 元信息落盘：服务一重启，第一次打开也不用再去上游探一次 HEAD
    # （CD2 冷区首字节 0.3~4.6s，那一下就是用户感知到的「进去要等」）。
    _meta_disk_ready: dict = {"loaded": False}
    _meta_disk_lock = threading.Lock()















    # -- 播放缓存管理（1.3.35） -------------------------------------------- #
    #
    # 客户端「设置 → 高级 → 清理缓存」用它显示占用 / 一键清空。
    # 以前清的是手机沙箱里 mpv 的 stream-cache（作用有限），现在真正管用的是
    # 服务端这份按块落盘的缓存 —— 同一个文件第二次打开基本不用回源。


    # -- 预告片 -----------------------------------------------------------
    #
    # 预告片是几十秒的小视频（几 MB），不需要 play 那套分块缓存 + 预读：
    # Range 原样透传给 mpv 就够，省一层内存缓存也省一路预取线程。
    #
    # 两种上游，**鉴权头必须分开**：
    #   * 已在 amane 的 Resource 库里（刮削时下载下来的）→ /api/resources/{hash}，
    #     带 Bearer 回源；
    #   * 还只有外链（老数据或站点只给外链）→ 直接去源站拉，**绝不能带 Bearer**，
    #     那是把实例 token 白送给第三方站点。


    # -- 首页 / 浏览 -------------------------------------------------------








    # ---- 搜索历史 ---------------------------------------------------------
    # 「上次搜过什么」放服务端而不是本地偏好：重装包、换设备都还在，
    # 与收藏 / 观看记录同一套思路。只留最近 SEARCH_HISTORY_KEEP 条 —— 它是快捷入口，
    # 不是审计日志。



    # ---- 检索索引（拼音）-------------------------------------------------


    # ---- 检索别名（俗称 → 库里真有的名字）---------------------------------
    #
    # 与演员别名（amane 自带的 actor_aliases，3836 条）同一个思路：
    # 「搜查官」在库里叫「女检察官」、「ntr」在库里叫「寝取」，用户按自己的说法搜，
    # 系统负责翻译。别名**只影响检索**，不改任何一条元数据。














    # ---- 播放器批注（R23） --------------------------------------------- #
    #
    # 一条批注 = 「某个时间点 + 一句话」。播放到那一刻从画面上滚过；汇总页点一条
    # 直接跳到那部片的那个位置。纯自用，不做社交、不进摘要。
    #






    # -- 收藏 -------------------------------------------------------------





    # -- 历史 -------------------------------------------------------------





    # -- 报表（2.5.3）-------------------------------------------------------
    #
    # 五个读端点一次定好，页面只渲染、不在页面里算（docs/TASKS/2.5.3-report-next.md §2）。
    # 统一信封 {"ok", "version", "confidence", "data"}：confidence = full / sparse / estimate，
    # `ok:false` 一律带 reason —— 样本不足时客户端显示「还在积累」，不许显示成 0 误导人。
    # 加新统计项 = 加一个端点 + 页面加一块，不动已有项。













    # -- 报表 v2（2.5.3 第二批）---------------------------------------------
    #
    # 四块新统计，各自独立端点、独立空态，**不改已有块**。判据全在服务端，页面只渲染。






    # -- Tier 图（2.5.4）---------------------------------------------------
    #
    # 五档固定、分档与上限全在服务端；生成即落快照（筛选条件 + 条目 + 展示图），
    # 之后再改评分也不动旧图，要更新就重新生成。契约见 `docs/TASKS/2.5.4-tierlist.md` §4。







    # -- 元数据覆盖层（2.5.5）---------------------------------------------
    #
    # 只写 user.db 的 `meta_override`，amane 的库一个字不动；读接口「覆盖优先」。
    # 契约见 `docs/TASKS/2.5.5-metadata-cover.md` §1。





    # -- 自建分类的管理（2.5.5.16）-----------------------------------------
    #
    # 用户自己起的系列 / 标签只存在于覆盖层，库里没有它们。这里给一个「只看自建」
    # 的列表与删除入口 —— **不碰库里原有的分类**（那是别人的资产，暂不开放修改）。









    # -- 投屏令牌（2.5.6）--------------------------------------------------
    #
    # 投屏时要把播放地址交给电视 / 盒子，而主 token 是万能钥匙（能改覆盖层、能删快照）。
    # 这里发的 `ct` 是**只读媒体专用**的短时凭证：只认 GET/HEAD 的
    # /play /streams /photo /studio-logo，别的路径一律 401。







    # -- 分类封面（2.5.5.4）：系列 / 标签 / 厂牌 / 演员 / 媒体库 ----------------
    #
    # key 用**名字**而不是 id：用户自己新起的系列在库里没有 id，用名字才能让
    # 「新建的分类」和「库里的分类」共用一套封面。媒体库用 `lib-<id>`。







def main() -> None:
    EXT.load()
    init_user_db()
    os.makedirs(IMAGE_CACHE, exist_ok=True)
    log(f"amane-user {VERSION} on :{PORT}  amane={AMANE_BASE}  db={USER_DB}")
    if not AMANE_TOKEN:
        log("WARN 没读到 amane token，接口将不校验鉴权")
    cjk_tables()
    _bootstrap_name_pinyin()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    # 起得来才算这次「换代码」成功：清掉 boot 标记，下次重启不再当成崩溃
    try:
        from core import upgrader as _U
        _U.boot_ok()
    except Exception:  # noqa: BLE001
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def _prefer_data_app() -> None:
    """启动前决定用哪份代码：`<DATA_DIR>/app`（升级后的）还是镜像里的。

    为什么不用挂卷（用户 2026-11-15 21:12 指出「还得改 compose 太麻烦」）：
    升级写进 `<DATA_DIR>/app` —— 那是**每个部署本来就有的数据卷**，
    所以老用户什么都不用改，而 `docker compose up -d` 重建容器也不会把升级冲掉。

    两条保护：
    1. 版本取新的那一份（镜像更新后不会被旧的 `/data/app` 盖回去）；
    2. 上次换了代码但没起起来（`.pending` 还在）→ 记一次失败，连续两次就回滚到 `app.prev`。
    """
    data = os.environ.get("DATA_DIR", "/data")
    cand = os.path.join(data, "app")
    entry = os.path.join(cand, "server.py")
    # 已经 exec 进这份代码了：`.pending` 要等 main() 里 listen 成功才清，
    # 这时再数一次就变成「同一次升级记两次失败」→ 直接回滚（2026-11-17 实测事故）。
    if os.environ.get("AMANE_DATA_APP_ACTIVE") == cand:
        return
    if not os.path.isfile(entry):
        return
    try:
        from core import upgrader as _U
        if _U.boot_guard(cand) == "rollback":
            return
        if not _U.candidate_is_newer(cand):
            log(f"跳过 {cand}：不比镜像里的 {VERSION} 新")
            return
        os.chdir(cand)
        sys.path.insert(0, cand)
        # 打了这个标记，exec 之后的新进程就不会把 `.pending` 再数一次（见函数开头）
        os.environ["AMANE_DATA_APP_ACTIVE"] = cand
        log(f"改用数据卷里的代码：{cand}")
        os.execv(sys.executable, [sys.executable, entry] + sys.argv[1:])
    except Exception as exc:  # noqa: BLE001
        log(f"WARN 切换到 {cand} 失败，继续用镜像代码：{exc}")


if __name__ == "__main__":
    _prefer_data_app()
    main()
