#!/usr/bin/env bash
# =============================================================================
# agentos-runtime-tune-rollback.sh — agentos-runtime-tune.sh 的独立回滚脚本
# 等价于：./agentos-runtime-tune.sh --revert
# 撤销：删除 /etc/sysctl.d/99-agentos.conf、恢复 sitecustomize 备份、
#       sysctl 六项还原为首辅实测的改前值（panic=0 dirty=20/10 swappiness=60 cubic/pfifo_fast）
# 用法：./agentos-runtime-tune-rollback.sh [--dry-run]
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/agentos-runtime-tune.sh" --revert "$@"
