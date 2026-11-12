#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""脱敏自检（纯标准库，可随公开仓库分发）。

    python tools/scan_secrets.py --path .
    python tools/scan_secrets.py --path . --hap dist/Amane.hap
    python tools/scan_secrets.py --path . --json

设计要点：
  * 本文件只含**泛化正则**，不写任何真实用户名 / 域名 / token 前缀，
    否则规则文件本身就会变成泄露源。
  * 需要按已知真实值精确扫描时，用 --rules 指向一份**本地私有**规则文件
    （每行一个字符串，# 开头为注释）。CI 不提供该文件，只跑泛化规则。
  * 占位符（example / replace / your / ${...} / <...>）不算命中。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

# (编号, 正则, 说明) —— 只描述"形状"，不含任何真实值
PATTERNS = [
    ("bearer", r"Bearer\s+[A-Za-z0-9_\-]{24,}", "明文 Bearer 凭据"),
    ("private_ip", r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b", "内网 IP"),
    ("storage_path", r"/vol[12]/1000/", "NAS 绝对路径"),
    ("personal_path", r"[A-Za-z]:\\(?:Users|Documents|softwares)\\", "个人电脑绝对路径"),
    ("assigned_secret", r"(?:api[_-]?token|password|passwd|secret|api[_-]?key)\s*[:=]\s*['\"][^'\"<$\s]{8,}['\"]", "疑似口令赋值"),
    ("long_random", r"\b[A-Za-z0-9_-]{40,}\b", "长随机串（疑似密钥）"),
    ("email", r"\b[\w.+-]+@(?!example\.(?:com|org|net))[\w.-]+\.[A-Za-z]{2,}\b", "真实风格邮箱"),
]
COMPILED = [(name, re.compile(pat), desc) for name, pat, desc in PATTERNS]

# 明显是占位符或模板变量的行，跳过
PLACEHOLDER = re.compile(
    r"(?:replace[-_]|your[-_]|example\.|<[^>]+>|\$\{|\{\$|placeholder|TODO|xxx+|dummy|sample)",
    re.IGNORECASE)

SKIP_FILES = {"tools/scan_secrets.py"}  # 自身含规则字面量
SKIP_DIRS = {".git", "__pycache__", "node_modules", "oh_modules", ".hvigor", "build", "dist"}

# 校验和是**故意公开**的：发布清单的 client.sha256、SHA256SUMS、Release 说明都要它。
# 64 位十六进制必然命中 long_random，按“同行有摘要语义”豁免，否则每次发布 CI 必红。
DIGEST_CTX = re.compile(r"(?:sha256|sha512|digest|checksum|SHA256SUMS)", re.IGNORECASE)
BINARY_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".so", ".hap", ".abc", ".p12", ".p7b", ".cer"}
# 原生库 / 编译产物里长字符串常量和邮箱形状是常态，跑这两条必然误报。
# 二进制改由「有明确语义的规则 + --rules 精确黑名单」全量兜底。
BINARY_SKIP_RULES = {"email", "long_random"}
EXTRA_RULES: list[str] = []


def load_rules(path: str | None) -> None:
    if not path:
        return
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            EXTRA_RULES.append(line)


def scan_text(text: str, label: str) -> list[dict]:
    hits: list[dict] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if PLACEHOLDER.search(line):
            continue
        for name, rx, desc in COMPILED:
            if name == "long_random" and DIGEST_CTX.search(line):
                continue
            if rx.search(line):
                hits.append({"file": label, "line": lineno, "rule": name, "desc": desc,
                             "excerpt": line.strip()[:120]})
        for secret in EXTRA_RULES:
            if secret in line:
                hits.append({"file": label, "line": lineno, "rule": "exact", "desc": "命中私有规则",
                             "excerpt": "<redacted>"})
    return hits


def scan_tree(base: Path) -> tuple[list[dict], int]:
    hits: list[dict] = []
    count = 0
    for path in sorted(base.rglob("*")):
        if not path.is_file() or any(part in SKIP_DIRS for part in path.parts):
            continue
        rel = path.relative_to(base).as_posix()
        if rel in SKIP_FILES or rel.endswith("secrets.rules"):
            continue
        count += 1
        if path.suffix.lower() in BINARY_EXT:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        hits.extend(scan_text(text, rel))
    return hits, count


def scan_hap(hap: Path) -> tuple[list[dict], int]:
    """HAP 是 zip：逐文件读 bytes，按 latin-1 解码后跑同样的形状规则。"""
    hits: list[dict] = []
    count = 0
    with zipfile.ZipFile(hap) as z:
        for name in z.namelist():
            data = z.read(name)
            count += 1
            text = data.decode("latin-1", errors="ignore")
            for rx_name, rx, desc in COMPILED:
                if rx_name in BINARY_SKIP_RULES:
                    continue  # 见 BINARY_SKIP_RULES 注释；精确黑名单仍逐字节检查
                if rx.search(text):
                    hits.append({"file": f"{hap.name}::{name}", "line": 0,
                                 "rule": rx_name, "desc": desc, "excerpt": "<binary>"})
                    break
            for secret in EXTRA_RULES:
                if secret.encode("utf-8", errors="ignore") in data or secret in text:
                    hits.append({"file": f"{hap.name}::{name}", "line": 0,
                                 "rule": "exact", "desc": "命中私有规则（二进制）",
                                 "excerpt": "<redacted>"})
                    break
    return hits, count


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", default=".", help="要扫描的目录")
    ap.add_argument("--hap", help="额外逐文件扫描 HAP 包")
    ap.add_argument("--rules", help="本地私有精确规则文件（不入库）")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    load_rules(args.rules)
    base = Path(args.path).resolve()
    hits, files = scan_tree(base)
    entries = files
    if args.hap:
        h_hits, h_entries = scan_hap(Path(args.hap))
        hits.extend(h_hits)
        entries += h_entries

    result = {"scanned_files": files, "scanned_entries": entries,
              "rules": len(COMPILED), "exact_rules": len(EXTRA_RULES),
              "hits": hits, "ok": not hits}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"扫描 {files} 个文件 / {entries} 个条目，泛化规则 {len(COMPILED)} 条，"
              f"精确规则 {len(EXTRA_RULES)} 条")
        for h in hits:
            print(f"  HIT {h['file']}:{h['line']} [{h['rule']}] {h['desc']}  {h['excerpt']}")
        print("结论：" + ("可以发布 ✓" if not hits else f"{len(hits)} 处命中，禁止发布"))
    return 0 if not hits else 1


if __name__ == "__main__":
    raise SystemExit(main())
