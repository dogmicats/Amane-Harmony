#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成发布版更新清单，并给出把它推上 GitHub 的命令。

发布线（Amane-Harmony / 仓库 dogmicats/Amane-Harmony）
-----------------------------------------------------
    app/build.cmd 编出 HAP -> 本脚本生成 updates/update.json
    -> 建 Release 上传 hap + update.json -> push updates/update.json 到 main

客户端不打包清单，只保存一个**永远不带版本号的固定地址**；每次点「检查更新」
现取一次。所以发布新版 = 覆盖 GitHub 上那一个文件，旧版 App 不用升级就能看到。

为什么清单要放两处（互为备份）
------------------------------
1. 主源 Release asset
   https://github.com/<repo>/releases/latest/download/update.json
   由 GitHub 判定 latest，稳定指针、基本没有缓存延迟；与安装包同一次发布，
   清单里的 url 不会指向一个还不存在的 Release。
2. 镜像 仓库 main:updates/update.json
   raw.githubusercontent.com / jsDelivr 都能读；国内 GitHub 主源不通时客户端回退。
   .github/workflows/sync-update-manifest.yml 在 Release 发布后自动把 asset 同步回这里，
   避免两处靠人工维护走偏。

客户端默认顺序：Release latest asset -> 仓库 raw 镜像 -> jsDelivr 镜像
                -> 自有服务端 /api/user/update/manifest。
清单里带 sha256：即使清单走了 CDN 镜像，包仍按哈希校验，来路可验。

两条硬规矩
----------
* **顺序**：先编/签包 -> 上传 Release -> 再 push 清单。清单的 url 是 Release 永久链接，
  Release 还没建时用户点下载只会 404。
* **哈希**：sha256 是最终包的字节；重编、重签后必须重跑本脚本，否则客户端校验不过会删包。

用法
----
    python tools/publish_release.py --from-release                 # 从现有 Release 反查真实包信息
    python tools/publish_release.py --from-release --tag v2.5.0    # 指定 tag
    python tools/publish_release.py --hap path/to/Amane-2.5.0.hap --tag v2.5.0
    python tools/publish_release.py --hap ... --tag v2.5.0 --dry-run
    python tools/publish_release.py --hap ... --tag v2.5.0 --upload  # 额外把清单传为 Release asset

--from-release 用 `gh api` 读 Release 的 asset（name / size / digest / browser_download_url），
不需要本地包；digest 是 GitHub 自己算的 sha256，比手抄可靠。
本脚本**不会** push、不会建 Release（除 --upload 显式要求），发布动作留给人确认。
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_REPO = "dogmicats/Amane-Harmony"
MANIFEST = os.path.join(ROOT, "updates", "update.json")


def gh_exe() -> str:
    found = shutil.which("gh")
    if found:
        return found
    cand = r"C:\Program Files\GitHub CLI\gh.exe"
    return cand if os.path.isfile(cand) else ""


def repo_version() -> tuple[str, int, str]:
    with open(os.path.join(ROOT, "version.json"), encoding="utf-8") as fh:
        cfg = json.load(fh)
    app = cfg.get("app", {})
    return str(app.get("version", "")), int(app.get("code", 0)), str(cfg.get("server", {}).get("version", ""))


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def hap_meta(path: str) -> tuple[str, int]:
    """包内 module.json 的真实版本；读不到就回退 version.json。"""
    try:
        with zipfile.ZipFile(path) as z:
            app = json.loads(z.read("module.json"))["app"]
        ver, code = str(app.get("versionName", "")), int(app.get("versionCode", 0))
        if ver and code:
            return ver, code
    except Exception:  # noqa: BLE001
        pass
    ver, code, _ = repo_version()
    return ver, code


def from_release(repo: str, tag: str) -> dict:
    exe = gh_exe()
    if not exe:
        raise RuntimeError("找不到 gh（GitHub CLI），装好后重试，或用 --hap 走本地包")
    cmd = [exe, "api", f"repos/{repo}/releases/tags/{tag}",
           "--jq", "{assets:[.assets[]|{name,size,digest,browser_download_url}]}"]
    raw = subprocess.check_output(cmd, text=True, encoding="utf-8")
    data = json.loads(raw)
    haps = [a for a in data.get("assets", []) if a["name"].endswith(".hap")]
    if not haps:
        raise RuntimeError(f"{tag} 里没有 .hap asset，先上传包再生成清单")
    a = haps[0]
    digest = str(a.get("digest") or "")
    if digest.startswith("sha256:"):
        digest = digest[7:]
    if len(digest) != 64:
        raise RuntimeError(f"{a['name']} 没有可用的 sha256 digest，改用 --hap 本地算")
    ver, code, _ = repo_version()
    return {
        "name": a["name"], "url": a["browser_download_url"],
        "size": int(a["size"]), "sha256": digest.lower(),
        "version": ver, "code": code,
    }


def from_hap(path: str, repo: str, tag: str) -> dict:
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        raise RuntimeError(f"包不存在：{path}")
    ver, code = hap_meta(path)
    name = os.path.basename(path)
    return {
        "name": name,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
        "size": os.path.getsize(path), "sha256": sha256_of(path),
        "version": ver, "code": code,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 Amane-Harmony 发布版更新清单")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--hap", default="", help="本地已编/已签的 HAP 路径")
    src.add_argument("--from-release", action="store_true", help="从 GitHub Release 的 asset 反查")
    ap.add_argument("--tag", default="", help="Release tag；默认 v<version.json 的 app.version>")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--notes", default="", help="本次更新说明（App 里显示）")
    ap.add_argument("--out", default=MANIFEST)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--upload", action="store_true", help="额外执行 gh release upload 把清单传为该 tag 的 asset")
    args = ap.parse_args()

    ver, _, srv = repo_version()
    tag = args.tag or f"v{ver}"
    try:
        info = from_release(args.repo, tag) if args.from_release else from_hap(args.hap, args.repo, tag)
    except Exception as exc:  # noqa: BLE001
        print(f"取包信息失败：{exc}", file=sys.stderr)
        return 2

    manifest = {
        "published_at": datetime.now().astimezone().isoformat(timespec="minutes"),
        "channel": "public",
        "release": tag,
        "client": {
            "version": info["version"],
            "code": info["code"],
            "url": info["url"],
            "size": info["size"],
            "sha256": info["sha256"],
            "notes": args.notes or f"Amane-Harmony {info['version']}（{tag}）",
        },
        "server": {
            "version": srv,
            "notes": f"服务端代码版本 {srv}；升级步骤见 App 内「怎么升级服务端」",
        },
    }

    # 服务端升级步骤：**必须由这里生成**，不能只改镜像里那份 ——
    # sync-update-manifest.yml 会在 Release 发布后用 asset 覆盖 updates/update.json，
    # 手改镜像会被无声抹掉。文案源：updates/upgrade-howto.public.txt（逐行即步骤）。
    howto_src = os.path.join(ROOT, "updates", "upgrade-howto.public.txt")
    if os.path.isfile(howto_src):
        with open(howto_src, encoding="utf-8") as fh:
            howto = fh.read().strip()
        if howto:
            manifest["server"]["howto"] = howto
            print(f"  服务端步骤: {len(howto.splitlines())} 行（来自 updates/upgrade-howto.public.txt）")
    else:
        print("  提醒：没有 updates/upgrade-howto.public.txt，客户端会用自己的内置步骤（须为公开版文案）")

    print("== 将发布 ==")
    print(f"  仓库      : {args.repo}")
    print(f"  Release   : {tag}")
    print(f"  客户端    : {info['version']} / code {info['code']}")
    print(f"  包        : {info['name']}  ({info['size']:,} B)")
    print(f"  sha256    : {info['sha256']}")
    print(f"  url       : {info['url']}")
    print(f"  清单      : {args.out}")
    print(f"  主源      : https://github.com/{args.repo}/releases/latest/download/update.json")
    print(f"  镜像      : https://raw.githubusercontent.com/{args.repo}/main/updates/update.json")
    if args.dry_run:
        print("\n--dry-run：没写任何文件。")
        return 0

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print("\n== 清单已写；接下来按顺序做（本脚本不自动发布） ==")
    print(f"  1) 包若还没上传：gh release upload {tag} <包路径> -R {args.repo}")
    print(f"  2) 清单传为 Release asset：gh release upload {tag} {args.out} -R {args.repo} --clobber")
    print("     （或建新 Release：gh release create <tag> <包> updates/update.json --title ... --notes ...）")
    print("  3) 镜像入库：git add updates/update.json && git commit && git push")
    print("     之后 sync-update-manifest.yml 会在每次 Release 发布后自动保持两处一致")
    print("\n提醒：先传包再 push 清单；重签包必须重跑本脚本。")

    if args.upload:
        exe = gh_exe()
        if not exe:
            print("找不到 gh，跳过 --upload", file=sys.stderr)
            return 1
        subprocess.check_call([exe, "release", "upload", tag, args.out, "-R", args.repo, "--clobber"])
        print("清单已上传为 Release asset。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
