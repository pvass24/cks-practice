#!/bin/bash
# CKS Practice Suite — Shared library
# Source this in each question script

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Environment detection
detect_env() {
  if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
    echo "kubeadm"
  elif kind get clusters 2>/dev/null | grep -q . 2>/dev/null; then
    echo "kind"
  elif kubectl get nodes &>/dev/null 2>&1; then
    echo "kubeadm"
  else
    echo "unknown"
  fi
}

ENV_TYPE=$(detect_env)

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }

header() {
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  CKS Practice — $1${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
  echo ""
}

requires_kubeadm() {
  if [ "$ENV_TYPE" != "kubeadm" ]; then
    echo -e "${YELLOW}This question requires a kubeadm cluster (SSH to nodes).${NC}"
    echo -e "${YELLOW}Run on Killercoda or a real kubeadm cluster.${NC}"
    return 1
  fi
  return 0
}

CKS_STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache/cks-practice}"
CKS_TIMER_PID_FILE="$CKS_STATE_DIR/timer.pid"
CKS_TIMER_START_FILE="$CKS_STATE_DIR/timer-start"

_ensure_state_dir() {
  install -d -m 700 "$CKS_STATE_DIR" 2>/dev/null || mkdir -p "$CKS_STATE_DIR"
  chmod 700 "$CKS_STATE_DIR"
}

_validate_numeric() {
  local val="$1"
  if echo "$val" | grep -qE '^[0-9]+$'; then
    echo "$val"
  else
    date +%s
  fi
}

timer_start() {
  _ensure_state_dir
  timer_kill_bg
  export CKS_TIMER_START=$(date +%s)
  install -m 600 /dev/null "$CKS_TIMER_START_FILE"
  echo "$CKS_TIMER_START" > "$CKS_TIMER_START_FILE"

  (
    while true; do
      local start=$(_validate_numeric "$(cat "$CKS_TIMER_START_FILE" 2>/dev/null || echo "$CKS_TIMER_START")")
      local now=$(date +%s)
      local elapsed=$((now - start))
      local mins=$((elapsed / 60))
      local secs=$((elapsed % 60))
      printf '\033]0;⏱ CKS Timer: %02d:%02d\007' "$mins" "$secs"
      sleep 1
    done
  ) &
  install -m 600 /dev/null "$CKS_TIMER_PID_FILE"
  echo $! > "$CKS_TIMER_PID_FILE"
  disown

  echo -e "${CYAN}⏱  Timer started — watch your terminal title bar.${NC}"
  echo -e "${CYAN}   Stop with: ./run.sh timer stop${NC}"
}

timer_kill_bg() {
  if [ -f "$CKS_TIMER_PID_FILE" ]; then
    local pid=$(cat "$CKS_TIMER_PID_FILE" 2>/dev/null)
    pid=$(_validate_numeric "${pid:-0}")
    if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$CKS_TIMER_PID_FILE"
  fi
  printf '\033]0;%s\007' "CKS Practice"
}

timer_stop() {
  local start=$(_validate_numeric "$(cat "$CKS_TIMER_START_FILE" 2>/dev/null || echo "${CKS_TIMER_START:-$(date +%s)}")")
  local end=$(date +%s)
  local elapsed=$((end - start))
  local mins=$((elapsed / 60))
  local secs=$((elapsed % 60))
  timer_kill_bg
  echo ""
  echo -e "  ${BOLD}⏱  Time: ${mins}m ${secs}s${NC}"
  if [ -n "${1:-}" ]; then
    echo -e "  Target: $1"
  fi
}

score_report() {
  local passed=$1
  local total=$2
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
  if [ "$passed" -eq "$total" ]; then
    echo -e "  ${GREEN}Score: ${passed}/${total} — FULL PASS${NC}"
  else
    echo -e "  ${RED}Score: ${passed}/${total}${NC}"
  fi
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
}
