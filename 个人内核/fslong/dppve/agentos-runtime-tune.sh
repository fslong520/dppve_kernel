#!/usr/bin/env bash
# =============================================================================
# agentos-runtime-tune.sh — agentos 运行时优化落地脚本（openKylin 3.0 / 7.3.4-0-generic）
#
# 【用法】
#   ./agentos-runtime-tune.sh            # 落地优化（需 sudo 密码，脚本开头 sudo -v）
#   ./agentos-runtime-tune.sh --dry-run   # 干跑：只打印将做什么，不改任何系统文件
#   ./agentos-runtime-tune.sh --revert    # 回滚本次改动（删 99-agentos.conf、恢复备份、sysctl 还原）
#   ./agentos-runtime-tune-rollback.sh    # 同 --revert 的独立回滚脚本
#
# 【可选开关（环境变量）】
#   DISABLE_APPORT=1  启用 apport hook 注释（默认 0=不动 apport，最安全）
#                     ⚠ 警示：注释 apport hook 会禁用 Python 程序崩溃报告（apport），
#                       仅在你明确不需要崩溃上报时启用；默认关闭。
#
# 【不做的事（已核实，勿加）】
#   不改 HZ、不改 THP、不改 RCU_BOOST、不用 teo governor（cpuidle 现为 menu）、
#   不 echo +io（cgroup v2 subtree_control 已含 io）、不改内核配置重编。
#   无 energy_perf_bias 接口（intel_pstate 下 EPP 项不适用），不写 x86_energy_perf_policy。
#
# 【幂等/备份/回滚】
#   - 配置只写一次（先查同值行，已存在则跳过）；备份带时间戳到 /etc/sysctl.d/ 与
#     /etc/python3.12/ 的 .bak.<ts>；--revert 用最新备份恢复并删除本脚本写入的文件。
# =============================================================================
set -euo pipefail

# --- 常量：sysctl 绝对路径（普通用户 PATH 无 /usr/sbin，任务书实测） ---
SYSCTL=""
for p in /usr/sbin/sysctl /sbin/sysctl /usr/bin/sysctl; do
  if [ -x "$p" ]; then SYSCTL="$p"; break; fi
done
[ -n "$SYSCTL" ] || { echo "[ERR] 未找到 sysctl 可执行文件"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
CONF="/etc/sysctl.d/99-agentos.conf"
SITECUSTOMIZE="/etc/python3.12/sitecustomize.py"
BACKUP_DIR="/etc/sysctl.d/agentos-backups"
SITE_BACKUP=""
CONF_BACKUP=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }

# 当前值（读 /proc/sys，直读不依赖 sysctl PATH）
getv() { # getv vm.dirty_ratio -> 20
  local path="${1//./\/}"
  cat "/proc/sys/$path" 2>/dev/null || echo "(无此键)"
}

# 干跑模式
DRYRUN=0
REVERT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRYRUN=1 ;;
    --revert)  REVERT=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $a（--dry-run / --revert / --help）" ;;
  esac
done

run() { # 执行或干跑打印
  if [ "$DRYRUN" -eq 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

need_root() {
  if [ "$DRYRUN" -eq 1 ]; then return 0; fi
  if [ "$(id -u)" -ne 0 ]; then
    log "需要 sudo 密码（脚本整体以 root 运行更稳）..."
    sudo -v || die "sudo 认证失败"
    exec sudo -E env "DISABLE_APPORT=${DISABLE_APPORT:-0}" "$0" "$@"
  fi
}

# -----------------------------------------------------------------------------
# 回滚
# -----------------------------------------------------------------------------
do_revert() {
  log "== 回滚开始 =="
  # 1) 删除本脚本写入的 sysctl conf（仅在存在时）
  if [ -f "$CONF" ]; then
    run rm -f "$CONF"
    log "已删除 $CONF"
  else
    log "$CONF 不存在，跳过"
  fi
  # 2) 恢复 sitecustomize 备份（若曾改动）
  if [ -f "$SITECUSTOMIZE" ]; then
    local latest
    latest="$(ls -1t "${SITECUSTOMIZE}".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$latest" ]; then
      run cp -a "$latest" "$SITECUSTOMIZE"
      log "已恢复 $SITECUSTOMIZE ← $latest"
    else
      log "未找到 sitecustomize 备份，跳过（未改动过？）"
    fi
  fi
  # 3) sysctl 恢复任务书记录的原始值
  #    依据：首辅实测改前真实值 panic=0 dirty=20/10 swappiness=60 congestion=cubic qdisc=pfifo_fast
  local -a orig=(
    "kernel.panic=0"
    "vm.dirty_ratio=20"
    "vm.dirty_background_ratio=10"
    "vm.swappiness=60"
    "net.ipv4.tcp_congestion_control=cubic"
    "net.core.default_qdisc=pfifo_fast"
  )
  for kv in "${orig[@]}"; do
    run "$SYSCTL" -w "$kv"
    log "恢复 $kv"
  done
  # 4) 确认
  if [ "$DRYRUN" -eq 0 ]; then
    log "== 回滚后核对 =="
    for k in kernel.panic vm.dirty_ratio vm.dirty_background_ratio vm.swappiness \
             net.ipv4.tcp_congestion_control net.core.default_qdisc; do
      printf '  %s = %s\n' "$k" "$(getv "$k")"
    done
  fi
  log "== 回滚完成 =="
}

# -----------------------------------------------------------------------------
# 落地
# -----------------------------------------------------------------------------
do_tune() {
  log "== agentos 运行时优化（$(date '+%F %T')）=="

  # --- 0) sudo ---
  need_root "$@"

  # --- 1) sysctl 持久化文件 ---
  # 依据（首辅实测改前值 → 目标值）：
  #   kernel.panic: 0 → 30        防挂死：panic 30 秒自动重启（当前 0 是最危险项）
  #   vm.dirty_ratio: 20 → 10     收紧脏页上限，降低大量 IO 时的卡顿与丢数据风险
  #   vm.dirty_background_ratio: 10 → 5  同上，后台回写更早触发
  #   vm.swappiness: 60 → 10       倾向保留 page cache，配合大量磁盘 IO 场景
  #   net.core.default_qdisc: pfifo_fast → fq   BBR 官方推荐搭配 fq 队列
  #   net.ipv4.tcp_congestion_control: cubic → bbr  内核已内置（tcp_available 含 bbr）
  local -a items=(
    "kernel.panic = 30"
    "vm.dirty_ratio = 10"
    "vm.dirty_background_ratio = 5"
    "vm.swappiness = 10"
    "net.core.default_qdisc = fq"
    "net.ipv4.tcp_congestion_control = bbr"
  )

  # 幂等检测：若 conf 已存在且含全部目标行，跳过写入
  local need_write=1
  if [ -f "$CONF" ]; then
    local all_present=1
    for it in "${items[@]}"; do
      grep -qF "$it" "$CONF" || { all_present=0; break; }
    done
    [ "$all_present" -eq 1 ] && need_write=0
  fi

  if [ "$need_write" -eq 1 ]; then
    # 备份旧 conf（若存在）
    if [ -f "$CONF" ]; then
      CONF_BACKUP="${CONF}.bak.${TS}"
      run cp -a "$CONF" "$CONF_BACKUP"
      log "已备份 $CONF → $CONF_BACKUP"
    fi
    # 生成新 conf（heredoc，幂等：整文件重写而非追加）
    if [ "$DRYRUN" -eq 1 ]; then
      log "DRY-RUN: 将写入 $CONF："
      printf '  %s\n' "${items[@]}"
    else
      mkdir -p "$BACKUP_DIR"
      cat > "$CONF" <<EOF
# agentos 运行时优化（生成于 ${TS}，回滚见 agentos-runtime-tune.sh --revert）
# 依据：首辅实测改前值 panic=0 dirty=20/10 swappiness=60 cubic/pfifo_fast
kernel.panic = 30
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.swappiness = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
      chmod 644 "$CONF"
      log "已写入 $CONF"
    fi
  else
    log "$CONF 已含全部目标行，跳过写入（幂等）"
  fi

  # 改前值核对（/proc/sys 直读）
  log "== 改前值（/proc/sys 直读） =="
  for k in kernel.panic vm.dirty_ratio vm.dirty_background_ratio vm.swappiness \
           net.ipv4.tcp_congestion_control net.core.default_qdisc; do
    printf '  %s = %s\n' "$k" "$(getv "$k")"
  done

  # 立即生效（不等重启）
  if [ "$DRYRUN" -eq 1 ]; then
    log "DRY-RUN: 将执行 $SYSCTL --system"
  else
    "$SYSCTL" --system >/dev/null
    log "已执行 $SYSCTL --system（立即生效）"
  fi

  # 改后值核对
  log "== 改后值（/proc/sys 直读） =="
  for k in kernel.panic vm.dirty_ratio vm.dirty_background_ratio vm.swappiness \
           net.ipv4.tcp_congestion_control net.core.default_qdisc; do
    printf '  %s = %s\n' "$k" "$(getv "$k")"
  done

  # --- 2) apport hook（可选，默认不动） ---
  # 依据：/etc/python3.12/sitecustomize.py 含 apport hook，每次 python 启动多花 ~13.6ms；
  #       注释 hook 可省这 13.6ms，但会禁用 Python 崩溃报告——默认 DISABLE_APPORT=0 不动。
  if [ "${DISABLE_APPORT:-0}" = "1" ]; then
    warn "⚠ DISABLE_APPORT=1：将注释 apport hook——**这会影响崩溃报告功能**，请自行确认是否保留。"
    if [ -f "$SITECUSTOMIZE" ] && grep -q apport "$SITECUSTOMIZE"; then
      SITE_BACKUP="${SITECUSTOMIZE}.bak.${TS}"
      if [ "$DRYRUN" -eq 1 ]; then
        log "DRY-RUN: 将备份 $SITECUSTOMIZE → $SITE_BACKUP，并 sed 注释含 apport 的行"
      else
        cp -a "$SITECUSTOMIZE" "$SITE_BACKUP"
        log "已备份 $SITECUSTOMIZE → $SITE_BACKUP"
        sed -i 's/^\(\s*\)\(.*apport.*\)$/\1#\2/' "$SITECUSTOMIZE"
        log "已注释 apport 行（可用 --revert 从备份恢复）"
      fi
    else
      log "$SITECUSTOMIZE 不存在或不含 apport，跳过"
    fi
  else
    log "apport hook 保持不动（DISABLE_APPORT=0 默认）。如需启用：DISABLE_APPORT=1 $0"
    log "  ⚠ 提示：禁用 apport 会影响崩溃报告，用户可自行决定是否保留。"
  fi

  # --- 2b) qdisc 持久化冲突检测（T24 教训：/etc/sysctl.conf 最后加载会覆盖 99-agentos.conf） ---
  # 依据：sysctl --system 按文件名顺序加载，/etc/sysctl.conf 最后执行；若其中含
  #   net.core.default_qdisc=<非 fq> 行，会把本脚本写入的 fq 覆盖回去（重启也退回）。
  # 本检测**只告警不自动改** sysctl.conf——改动该文件超出本脚本授权范围。
  local conflict_lines
  conflict_lines="$(grep -nE '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=' /etc/sysctl.conf 2>/dev/null \
                    | grep -vE '=[[:space:]]*fq[[:space:]]*$' || true)"
  if [ -n "$conflict_lines" ]; then
    warn "⚠ 检测到 /etc/sysctl.conf 中存在 default_qdisc 非 fq 的冲突行："
    while IFS= read -r l; do
      warn "    /etc/sysctl.conf:$l"
    done <<< "$conflict_lines"
    warn "  该行会在 sysctl --system 末尾覆盖 99-agentos.conf 的 fq，重启后 qdisc 退回旧值。"
    warn "  处理：备份 /etc/sysctl.conf 后把该行改为 net.core.default_qdisc=fq（需 root，本脚本不代改）。"
  else
    log "冲突检测：/etc/sysctl.conf 无 default_qdisc 冲突行（或该文件不存在）✅"
  fi

  # --- 3) 不做的事（打印留档，避免误以为遗漏） ---
  log "以下项经核实**不纳入**（已最优/过时/越界）："
  log "  - HZ / THP / RCU_BOOST：当前已最优，改动无收益"
  log "  - teo governor：cpuidle 现为 menu，teo 建议已过时"
  log "  - echo +io：cgroup v2 subtree_control 已含 io"
  log "  - EPP / x86_energy_perf_policy：intel_pstate 下无 energy_perf_bias 接口，工具可能未装"
  log "  - 内核配置重编：超出本脚本范围"

  # --- 4) 验证命令清单 ---
  cat <<'EOF'

==================== 验证命令清单（请自行核对） ====================
# 1) sysctl 六项现值（期望 panic=30 dirty=10/5 swappiness=10 bbr fq）
/usr/sbin/sysctl kernel.panic vm.dirty_ratio vm.dirty_background_ratio \
  vm.swappiness net.ipv4.tcp_congestion_control net.core.default_qdisc
# 2) 持久化文件内容
cat /etc/sysctl.d/99-agentos.conf
# 3) BBR 可用性
/usr/sbin/sysctl net.ipv4.tcp_available_congestion_control   # 应含 bbr
# 4) apport 状态（若未启用 DISABLE_APPORT，应仍含 apport）
grep -n apport /etc/python3.12/sitecustomize.py || echo "apport 已被注释/不存在"
# 5) 回滚验证
./agentos-runtime-tune.sh --revert
# 6) 备份位置
ls -l /etc/sysctl.d/99-agentos.conf.bak.* /etc/python3.12/sitecustomize.py.bak.* 2>/dev/null
=====================================================================
EOF
  if [ "$DRYRUN" -eq 1 ]; then
    log "== 干跑完成（未写入任何配置、未改系统；以上仅为预览） =="
  else
    log "== 完成（配置已写入并生效；未改 live 内核/未重编） =="
  fi
}

# --- 入口 ---
if [ "$REVERT" -eq 1 ]; then
  need_root "$@"
  do_revert
else
  do_tune "$@"
fi
