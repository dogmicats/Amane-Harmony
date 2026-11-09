#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 AI 助手用的部署 CLI（纯标准库，幂等，全部命令支持 --json）。

    python tools/agentctl.py doctor --json
    python tools/agentctl.py plan --json [--mode docker|python]
    python tools/agentctl.py apply --yes [--mode docker|python]
    python tools/agentctl.py status --json
    python tools/agentctl.py rollback --json
    python tools/agentctl.py upgrade --json

设计原则：agent 只做调度，不做判断。所有判据来自本 CLI 的结构化输出与退出码，
不需要 LLM 自己拼 compose 或猜路径。任何命令都**不回显 token**。
退出码：0 成功 / 1 前置条件不满足 / 2 用法错误 / 3 执行失败 / 4 需要人工确认。
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import sqlite3
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / ".env"
BACKUP = ROOT / ".env.agentctl-backup"
COMPOSE = ROOT / "deploy" / "compose.example.yml"
SERVER = ROOT / "server" / "server.py"

PLACEHOLDER_PREFIXES = ("replace-", "your-", "/path/to/", "<")


def emit(payload: dict, as_json: bool, code: int = 0) -> int:
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(payload.get("summary", json.dumps(payload, ensure_ascii=False)))
    return code


def token_present() -> bool:
    val = os.environ.get("AMANE_TOKEN", "")
    if val and not val.lower().startswith(PLACEHOLDER_PREFIXES):
        return True
    data = os.environ.get("AMANE_DATA", "")
    return bool(data) and (Path(data) / "token").is_file()


def doctor(mode: str, as_json: bool) -> int:
    checks: list[dict] = []
    missing: list[str] = []

    def add(key: str, ok: bool, detail: str, required: bool = True) -> None:
        checks.append({"key": key, "ok": ok, "detail": detail})
        if required and not ok:
            missing.append(key)

    py = sys.version_info
    add("python", py >= (3, 9), f"{py.major}.{py.minor}.{py.micro}")
    add("server_source", SERVER.is_file(), str(SERVER.relative_to(ROOT)) if SERVER.exists() else "缺失")
    add("compose_template", COMPOSE.is_file(), "deploy/compose.example.yml")

    data_dir = os.environ.get("AMANE_DATA", "")
    data_ok = bool(data_dir) and Path(data_dir).is_dir() and not data_dir.startswith("/path/to/")
    add("amane_data", data_ok, "<已设置>" if data_ok else "AMANE_DATA 未设置或不可读")
    db_ok = data_ok and (Path(data_dir) / "amane.db").is_file()
    add("amane_db", db_ok, "<已设置>" if db_ok else "amane.db 不可读（服务必须与 Amane 同机/共享 data）")
    add("amane_token", token_present(), "<已设置>" if token_present() else "AMANE_TOKEN 未提供")

    user_data = os.environ.get("DATA_DIR", str(ROOT / "data"))
    p = Path(user_data)
    writable = p.exists() and os.access(p, os.W_OK) or (not p.exists() and os.access(p.parent, os.W_OK))
    add("data_dir_writable", writable, user_data)

    port = int(os.environ.get("PORT", "8770") or 8770)
    with socket.socket() as s:
        s.settimeout(0.4)
        port_free = s.connect_ex(("127.0.0.1", port)) != 0
    add("port_free", port_free, f"{port} 可用" if port_free else f"{port} 已被占用（可能服务已在运行）", required=False)

    media = os.environ.get("MEDIA_ROOT", "")
    add("media_root", bool(media) and Path(media).is_dir(),
        "已配置" if media and Path(media).is_dir() else "未配置（字幕「同目录」来源不可用，其它来源不受影响）",
        required=False)
    add("media_path_map", bool(os.environ.get("MEDIA_PATH_MAP", "")),
        "已配置" if os.environ.get("MEDIA_PATH_MAP") else "未配置", required=False)

    if mode == "docker":
        add("docker", shutil.which("docker") is not None,
            "已安装" if shutil.which("docker") else "未找到 docker（CI 里会验证，当前环境不影响 doctor）",
            required=False)
    try:
        compile(SERVER.read_text(encoding="utf-8"), "server.py", "exec")
        add("server_syntax", True, "编译通过")
    except (OSError, SyntaxError) as exc:
        add("server_syntax", False, str(exc))

    payload = {"command": "doctor", "mode": mode, "ok": not missing,
               "missing": missing, "checks": checks,
               "summary": "环境就绪 ✓" if not missing else f"待补全：{', '.join(missing)}"}
    return emit(payload, as_json, 0 if not missing else 1)


def plan(mode: str, as_json: bool) -> int:
    steps = [
        {"step": "write_env", "target": ".env", "note": "写入非敏感的部署变量；token 由用户自行填入文件，不回显"},
        {"step": "ensure_data_dir", "target": os.environ.get("DATA_DIR", "./data")},
    ]
    if mode == "docker":
        steps.append({"step": "compose_up", "cmd": "docker compose -f deploy/compose.example.yml up -d",
                      "note": "使用只读挂载的 amane-data 与媒体卷"})
    else:
        steps.append({"step": "start_python", "cmd": "python server/server.py",
                      "note": "前台运行；常驻请用 deploy/systemd/amane-user.service"})
    steps.append({"step": "verify", "cmd": "GET /api/user/ping"})
    payload = {"command": "plan", "mode": mode, "steps": steps,
               "destructive": False, "requires_confirmation": True,
               "summary": f"计划 {len(steps)} 步，需用户确认后执行 apply --yes"}
    return emit(payload, as_json)


def apply(mode: str, confirmed: bool, as_json: bool) -> int:
    if not confirmed:
        return emit({"command": "apply", "ok": False,
                     "summary": "需要显式 --yes（且应先把 plan 给用户确认）"}, as_json, 4)
    done: list[str] = []
    try:
        if ENV_FILE.exists() and not BACKUP.exists():
            shutil.copy2(ENV_FILE, BACKUP)
            done.append("backup_env")
        template = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
        # 只写非敏感键；token 一律不写入、不回显
        lines = []
        for line in template.splitlines():
            if line.startswith("AMANE_TOKEN=") or line.startswith("IMAGE_TOKEN="):
                continue
            lines.append(line)
        ENV_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        try:
            os.chmod(ENV_FILE, 0o600)
        except OSError:
            pass
        done.append("write_env")
        (Path(os.environ.get("DATA_DIR", ROOT / "data"))).mkdir(parents=True, exist_ok=True)
        done.append("ensure_data_dir")
        if mode == "docker":
            if not shutil.which("docker"):
                return emit({"command": "apply", "ok": False, "done": done,
                             "summary": "当前环境没有 docker；请改用 --mode python，或到运行 Amane 的目标机上执行"},
                            as_json, 3)
            import subprocess
            cp = subprocess.run(["docker", "compose", "-f", str(COMPOSE), "up", "-d"],
                                cwd=ROOT, capture_output=True, text=True)
            if cp.returncode != 0:
                return emit({"command": "apply", "ok": False, "done": done,
                             "summary": f"compose up 失败（exit {cp.returncode}），可执行 rollback"},
                            as_json, 3)
            done.append("compose_up")
    except OSError as exc:
        return emit({"command": "apply", "ok": False, "done": done,
                     "summary": f"写入失败: {exc}"}, as_json, 3)
    return emit({"command": "apply", "ok": True, "done": done, "mode": mode,
                 "next": "python tools/agentctl.py status --json",
                 "summary": "已写入本地配置；token 请自行填入 .env（权限 600）后启动服务"}, as_json)


def status(as_json: bool) -> int:
    port = int(os.environ.get("PORT", "8770") or 8770)
    url = f"http://127.0.0.1:{port}/api/user/ping"
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        return emit({"command": "status", "ok": True, "url": url, "response": body,
                     "summary": "服务在线 ✓"}, as_json)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return emit({"command": "status", "ok": False, "url": url,
                     "summary": f"服务不可达：{type(exc).__name__}"}, as_json, 1)


def rollback(as_json: bool) -> int:
    done = []
    if BACKUP.exists():
        shutil.copy2(BACKUP, ENV_FILE)
        BACKUP.unlink()
        done.append("restore_env")
    elif ENV_FILE.exists():
        ENV_FILE.unlink()
        done.append("remove_env")
    return emit({"command": "rollback", "ok": True, "done": done,
                 "summary": "已回滚 agentctl 生成的 .env；data/ 与字幕缓存未改动"}, as_json)


def upgrade(as_json: bool) -> int:
    return emit({"command": "upgrade", "ok": False,
                 "summary": "请手动拉取新版本并阅读 CHANGELOG.md；本命令不自动改代码或删数据"},
                as_json, 2)


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("doctor", "plan", "status", "rollback", "upgrade"):
        s = sub.add_parser(name)
        s.add_argument("--json", action="store_true")
        s.add_argument("--mode", choices=("docker", "python"), default="docker")
    a = sub.add_parser("apply")
    a.add_argument("--json", action="store_true")
    a.add_argument("--mode", choices=("docker", "python"), default="docker")
    a.add_argument("--yes", action="store_true")
    args = ap.parse_args()
    if args.cmd == "doctor":
        return doctor(args.mode, args.json)
    if args.cmd == "plan":
        return plan(args.mode, args.json)
    if args.cmd == "apply":
        return apply(args.mode, args.yes, args.json)
    if args.cmd == "status":
        return status(args.json)
    if args.cmd == "rollback":
        return rollback(args.json)
    return upgrade(args.json)


if __name__ == "__main__":
    raise SystemExit(main())
