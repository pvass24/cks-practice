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

CKS_TIMER_PID_FILE="/tmp/.cks-timer.pid"

timer_start() {
  timer_kill_bg
  export CKS_TIMER_START=$(date +%s)
  echo "$CKS_TIMER_START" > /tmp/.cks-timer-start

  # Background process updates terminal title every second
  (
    while true; do
      local start=$(cat /tmp/.cks-timer-start 2>/dev/null || echo "$CKS_TIMER_START")
      local now=$(date +%s)
      local elapsed=$((now - start))
      local mins=$((elapsed / 60))
      local secs=$((elapsed % 60))
      printf '\033]0;⏱ CKS Timer: %02d:%02d\007' "$mins" "$secs"
      sleep 1
    done
  ) &
  echo $! > "$CKS_TIMER_PID_FILE"
  disown

  echo -e "${CYAN}⏱  Timer started — watch your terminal title bar.${NC}"
  echo -e "${CYAN}   Stop with: ./run.sh timer stop${NC}"
}

timer_kill_bg() {
  if [ -f "$CKS_TIMER_PID_FILE" ]; then
    local pid=$(cat "$CKS_TIMER_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$CKS_TIMER_PID_FILE"
  fi
  printf '\033]0;%s\007' "CKS Practice"
}

timer_stop() {
  local start=$(cat /tmp/.cks-timer-start 2>/dev/null || echo "${CKS_TIMER_START:-$(date +%s)}")
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
