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
  if kind get clusters 2>/dev/null | grep -q .; then
    echo "kind"
  elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node-role\.kubernetes\.io/control-plane}' &>/dev/null 2>&1; then
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

timer_start() {
  export CKS_TIMER_START=$(date +%s)
  echo -e "${CYAN}Timer started. GO.${NC}"
}

timer_stop() {
  local end=$(date +%s)
  local elapsed=$((end - CKS_TIMER_START))
  local mins=$((elapsed / 60))
  local secs=$((elapsed % 60))
  echo ""
  echo -e "${BOLD}Time: ${mins}m ${secs}s${NC}"
  if [ -n "${1:-}" ]; then
    echo -e "Target: $1"
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
