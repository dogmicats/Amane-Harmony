#!/usr/bin/env bash
# amane-user 自动升级助手（跑在**宿主机**上，不是容器里）
#
# 为什么需要它：App 没有在你机器上执行 docker 的能力，服务端要换镜像/重建容器，
# 只能由一个**有 docker 权限、跑在宿主机上**的进程来做。这个脚本就是那个进程，
# 装成 systemd timer 后每 10 分钟看一次：
#
#   只看 GitHub 上最新 Release → 比当前版本新 → 备份 data/ → 拉代码或镜像 →
#   重建容器 → 轮询 /api/user/ping 确认真的起来了 → 把结果写进 data/
#
# App 里的「自动升级」开关和「立即升级」按钮，改的就是这个脚本读的那两个 JSON；
# 没装脚本时 App 会显示原来的手动步骤，两者不冲突。
#
# 用法：
#   sudo bash deploy/auto-update.sh --install      装成定时任务并立刻启用
#        bash deploy/auto-update.sh --check        只报告，不动任何东西（默认）
#        bash deploy/auto-update.sh --status       看上次升级结果
#        bash deploy/auto-update.sh --apply        立刻升一次（忽略开关）
#        bash deploy/auto-update.sh --enable       打开自动升级
#        bash deploy/auto-update.sh --disable      关掉自动升级（手动 --apply 仍可用）
#        sudo bash deploy/auto-update.sh --uninstall
#
# 安全边界：
#   * 只动本仓库、本容器、本服务的 data/，不碰 Amane 本体和反代。
#   * 只升同一个大版本（2.x → 2.y）；大版本跳变只提示、不自动做。
#   * 升级前把 data/ 备份成 data.bak-<时间>，保留最近 3 份。
#   * 升级后必须 /api/user/ping 报出新版本号，否则状态记 failed 并给出回滚路径。
#   * 有未提交改动 / 不是 git 目录 → 直接失败，不 reset、不覆盖用户文件。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=""
CONTAINER="amane-user"
SERVICE="amane-user"
REPO_SLUG="dogmicats/Amane-Harmony"
UNIT="amane-auto-update"
KEEP_BACKUPS=3

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# ---------- 定位环境 ----------
pick_compose() {
  for f in "$REPO/deploy/compose.yml" "$REPO/deploy/compose.example.yml"; do
    [ -f "$f" ] && { COMPOSE="$f"; return 0; }
  done
  return 1
}

compose_bin() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; return; fi
  echo ""
}

# data/ 在宿主机上的真实路径：优先问容器自己的挂载，问不到就退回仓库里的 data/
host_data_dir() {
  local src
  src="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null)"
  if [ -n "$src" ] && [ -d "$src" ]; then echo "$src"; return; fi
  # compose 里的 `./data` 是相对 compose 文件所在目录（deploy/），不是仓库根
  echo "$REPO/deploy/data"
}

port_of() {
  local p
  p="$(grep -A12 "^  $SERVICE:" "$COMPOSE" 2>/dev/null | grep -oE '"[0-9]{2,5}:8770"' | head -n1 | tr -dc '0-9:')"
  echo "${p%%:*}" | grep -E '^[0-9]+$' || echo 8770
}

py_json() { python3 -c "$1" 2>/dev/null; }

read_field() {  # read_field <file> <key>
  local f="$1" k="$2"
  [ -f "$f" ] || return 0
  python3 - "$f" "$k" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    sys.exit(0)
v=d.get(sys.argv[2],"")
print("" if v is None else v)
PY
}

write_state() {  # write_state <state> <message> [from] [to]
  local data="$1" state="$2" msg="$3" from="${4:-}" to="${5:-}"
  python3 - "$data/auto_update.state.json" "$state" "$msg" "$from" "$to" <<'PY' 2>/dev/null
import json,os,sys,datetime
path,state,msg,frm,to=sys.argv[1:6]
now=datetime.datetime.now().astimezone().isoformat(timespec="seconds")
try:
    old=json.load(open(path,encoding="utf-8"))
except Exception:
    old={}
old.update({"installed":True,"state":state,"message":msg,"at":now})
if state in ("idle","checking"):
    old["checked_at"]=now
if frm: old["from"]=frm
if to: old["to"]=to
tmp=path+".tmp"
with open(tmp,"w",encoding="utf-8") as fh:
    json.dump(old,fh,ensure_ascii=False,indent=2); fh.write("\n")
os.replace(tmp,path)
PY
}

current_version() {
  local port; port="$(port_of)"
  curl -fsS --max-time 5 "http://127.0.0.1:$port/api/user/ping" 2>/dev/null | python3 -c \
    'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

latest_tag() {
  curl -fsS --max-time 8 "https://api.github.com/repos/$REPO_SLUG/releases/latest" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
}

# 2.6.0 vs 2.7.1：只允许同一主版本内自动升
same_major() {
  [ "${1%%.*}" = "${2%%.*}" ]
}

# ---------- 动作 ----------
do_check() {
  pick_compose || { log "找不到 deploy/compose*.yml，这个目录不是部署目录"; exit 2; }
  local data cur latest en
  data="$(host_data_dir)"
  cur="$(current_version)"
  latest="$(latest_tag)"
  en="$(read_field "$data/auto_update.json" enabled)"
  log "仓库      : $REPO"
  log "compose   : $COMPOSE"
  log "data 目录 : $data"
  log "当前版本  : ${cur:-（服务没响应）}"
  log "最新版本  : ${latest:-（查不到，可能没网或被墙）}"
  log "自动升级  : ${en:-（未设置，默认关）}"
  if [ -n "$cur" ] && [ -n "$latest" ] && [ "${latest#v}" != "$cur" ]; then
    if same_major "$cur" "${latest#v}"; then
      log "结论      : 可以自动升到 ${latest#v}"
    else
      log "结论      : 跨大版本（${cur} → ${latest#v}），需要手动升级"
    fi
  else
    log "结论      : 已是最新或无法比较"
  fi
}

do_apply() {
  local force="${1:-0}" data cur latest want enabled lock
  pick_compose || { log "找不到 deploy/compose*.yml"; exit 2; }
  data="$(host_data_dir)"
  mkdir -p "$data" 2>/dev/null
  exec 9>"$data/.auto-update.lock" || { log "无法在 $data 建锁文件"; exit 2; }
  if ! flock -n 9; then log "另一轮升级正在进行，跳过"; exit 0; fi

  write_state "$data" checking "正在检查"
  cur="$(current_version)"
  enabled="$(read_field "$data/auto_update.json" enabled)"
  want="$(read_field "$data/auto_update.request.json" want)"
  latest="$(latest_tag)"
  [ -n "$want" ] || want="${latest#v}"

  if [ -z "$want" ]; then log "拿不到目标版本（网络？）"; write_state "$data" failed "查不到最新版本" "$cur" ""; exit 1; fi
  if [ -n "$cur" ] && [ "$want" = "$cur" ]; then
    log "已经是最新（$cur）"
    write_state "$data" idle "已是最新" "$cur" "$cur"
    rm -f "$data/auto_update.request.json"
    exit 0
  fi
  if [ "$force" != "1" ] && [ "$enabled" != "True" ] && [ "$enabled" != "true" ] && [ -z "$(read_field "$data/auto_update.request.json" want)" ]; then
    log "自动升级没开，也没有手动请求 → 什么都不做"
    write_state "$data" idle "自动升级未开启" "$cur" "$want"
    exit 0
  fi
  if [ -n "$cur" ] && ! same_major "$cur" "$want"; then
    log "跨大版本（$cur → $want），不自动做"
    write_state "$data" failed "跨大版本需要手动升级：$cur → $want" "$cur" "$want"
    exit 0
  fi
  if [ ! -d "$REPO/.git" ]; then
    log "这不是 git 目录，无法自动更新代码"
    write_state "$data" failed "部署目录不是 git 仓库，自动升级不适用" "$cur" "$want"
    exit 1
  fi
  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    log "仓库有未提交改动，先停下"
    write_state "$data" failed "部署目录有本地改动，未升级（避免覆盖）" "$cur" "$want"
    exit 1
  fi

  write_state "$data" upgrading "正在升级到 $want" "$cur" "$want"
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$data.bak-$stamp"
  log "备份 data → $backup"
  if ! cp -a "$data" "$backup" 2>/dev/null; then
    log "备份失败，放弃升级"
    write_state "$data" failed "备份 data 失败，未升级" "$cur" "$want"
    exit 1
  fi
  rm -f "$backup/.auto-update.lock"
  # 只留最近 N 份
  ls -1d "$data".bak-* 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    rm -rf "$old"
  done

  log "拉取代码"
  if ! git -C "$REPO" pull --ff-only >/dev/null 2>&1; then
    log "git pull 失败（可能有本地分支/冲突）"
    write_state "$data" failed "git pull 失败，未升级；备份在 $backup" "$cur" "$want"
    exit 1
  fi

  local cb mode
  cb="$(compose_bin)"
  [ -n "$cb" ] || { log "找不到 docker compose"; write_state "$data" failed "找不到 docker compose" "$cur" "$want"; exit 1; }
  if grep -A8 "^  $SERVICE:" "$COMPOSE" | grep -q '^[[:space:]]*image:'; then mode=image; else mode=build; fi
  log "重建容器（$mode）"
  if [ "$mode" = "image" ]; then
    # shellcheck disable=SC2086
    if ! $cb -f "$COMPOSE" pull "$SERVICE" >/dev/null 2>&1 || ! $cb -f "$COMPOSE" up -d "$SERVICE" >/dev/null 2>&1; then
      log "重建失败"
      write_state "$data" failed "镜像重建失败；备份在 $backup" "$cur" "$want"
      exit 1
    fi
  else
    if ! $cb -f "$COMPOSE" up -d --build "$SERVICE" >/dev/null 2>&1; then
      log "重建失败"
      write_state "$data" failed "容器重建失败；备份在 $backup" "$cur" "$want"
      exit 1
    fi
  fi

  log "等新版本响应（最多 120 秒）"
  local i now
  for i in $(seq 1 24); do
    sleep 5
    now="$(current_version)"
    if [ "$now" = "$want" ]; then
      log "升级完成：$cur → $now"
      write_state "$data" done "已升级到 $want" "$cur" "$now"
      rm -f "$data/auto_update.request.json"
      exit 0
    fi
  done
  log "升级后版本对不上（现在 ${now:-无响应}）"
  write_state "$data" failed "升级后服务没报出新版本；回滚：用 $backup 覆盖 data 后 docker compose up -d" "$cur" "$want"
  exit 1
}

do_enable() {
  local data; data="$(host_data_dir)"
  python3 - "$data/auto_update.json" <<'PY'
import json,os,sys,datetime
p=sys.argv[1]; os.makedirs(os.path.dirname(p) or ".",exist_ok=True)
json.dump({"enabled":True,"updated_at":datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
          open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
  log "自动升级已打开（$data/auto_update.json）"
}

do_disable() {
  local data; data="$(host_data_dir)"
  python3 - "$data/auto_update.json" <<'PY'
import json,os,sys,datetime
p=sys.argv[1]; os.makedirs(os.path.dirname(p) or ".",exist_ok=True)
json.dump({"enabled":False,"updated_at":datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
          open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
  log "自动升级已关闭（手动 --apply 仍可用）"
}

do_status() {
  local data; data="$(host_data_dir)"
  log "data 目录 : $data"
  for f in auto_update.json auto_update.request.json auto_update.state.json; do
    [ -f "$data/$f" ] && { log "--- $f"; cat "$data/$f"; }
  done
  systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -n 3
}

do_install() {
  local data cb
  pick_compose || { log "找不到 deploy/compose*.yml，请在仓库目录里运行"; exit 2; }
  cb="$(compose_bin)"
  [ -n "$cb" ] || { log "找不到 docker compose"; exit 2; }
  data="$(host_data_dir)"
  mkdir -p "$data"
  write_state "$data" idle "助手已安装" "" ""
  do_enable
  if ! command -v systemctl >/dev/null 2>&1; then
    log "这台机器没有 systemd；请自行把这条命令加进 cron（每 10 分钟）："
    log "  bash $REPO/deploy/auto-update.sh --apply"
    exit 0
  fi
  cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=amane-user auto update (check GitHub release, rebuild container)
After=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=$REPO
ExecStart=/bin/bash $REPO/deploy/auto-update.sh --apply
EOF
  cat >"/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Run amane-user auto update every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer" >/dev/null 2>&1 && log "定时器已装好：每 10 分钟检查一次" || {
    log "systemd 启用失败，可手动：systemctl enable --now $UNIT.timer"; exit 1; }
}

do_uninstall() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$UNIT.timer" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$UNIT.service" "/etc/systemd/system/$UNIT.timer"
    systemctl daemon-reload
  fi
  local data; data="$(host_data_dir)"
  rm -f "$data/auto_update.state.json" "$data/auto_update.request.json"
  log "已卸载定时器（开关文件保留；删掉 data/auto_update.json 即恢复默认关）"
}

case "${1:---check}" in
  --install)   do_install ;;
  --uninstall) do_uninstall ;;
  --check)     do_check ;;
  --apply)     do_apply 1 ;;
  --run)       do_apply 0 ;;
  --enable)    do_enable ;;
  --disable)   do_disable ;;
  --status)    do_status ;;
  -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" ;;
  *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
esac
