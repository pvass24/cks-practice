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

# Restore API server to clean state between questions
# Removes ImagePolicyWebhook, audit flags, webhook volumes — anything previous Qs added
clean_apiserver() {
  if [ "$ENV_TYPE" != "kubeadm" ]; then
    return 0
  fi

  local manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  if [ ! -f "$manifest" ]; then
    return 0
  fi

  # Back up first if no backup exists
  if [ ! -f /root/kube-apiserver.yaml.clean ]; then
    # Only save as clean if API server is currently working
    if kubectl get nodes &>/dev/null 2>&1; then
      sudo cp "$manifest" /root/kube-apiserver.yaml.clean
    fi
  fi

  local needs_restart=false

  # Remove ImagePolicyWebhook from admission plugins
  if sudo grep -q 'ImagePolicyWebhook' "$manifest" 2>/dev/null; then
    sudo sed -i 's/,ImagePolicyWebhook//g; s/ImagePolicyWebhook,//g; s/ImagePolicyWebhook//g' "$manifest"
    needs_restart=true
  fi

  # Remove admission-control-config-file flag
  if sudo grep -q 'admission-control-config-file' "$manifest" 2>/dev/null; then
    sudo sed -i '/admission-control-config-file/d' "$manifest"
    needs_restart=true
  fi

  # Remove audit flags
  if sudo grep -q 'audit-log-path\|audit-policy-file\|audit-log-max' "$manifest" 2>/dev/null; then
    sudo sed -i '/audit-log-path/d; /audit-policy-file/d; /audit-log-maxage/d; /audit-log-maxbackup/d; /audit-log-maxsize/d' "$manifest"
    needs_restart=true
  fi

  # Remove webhook-config volume and mount
  if sudo grep -q 'webhook-config' "$manifest" 2>/dev/null; then
    sudo python3 -c "
import yaml
with open('$manifest') as f:
    m = yaml.safe_load(f)
c = m['spec']['containers'][0]
c['volumeMounts'] = [v for v in c.get('volumeMounts',[]) if v.get('name') not in ('webhook-config','audit-policy','audit-logs')]
m['spec']['volumes'] = [v for v in m['spec'].get('volumes',[]) if v.get('name') not in ('webhook-config','audit-policy','audit-logs')]
with open('$manifest','w') as f:
    yaml.dump(m, f, default_flow_style=False)
" 2>/dev/null || true
    needs_restart=true
  fi

  if [ "$needs_restart" = "true" ]; then
    info "Cleaned API server from previous question changes..."
    sleep 15
    for i in $(seq 1 20); do
      if kubectl get nodes &>/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
  fi

  # Clean up namespaces from previous questions (keep system namespaces)
  if kubectl get nodes &>/dev/null 2>&1; then
    for ns in production database restricted sec-ns sbom neuron serviceaccount token-ns bright-banyan security-test static-test trivy-scan istio-example; do
      if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        kubectl delete namespace "$ns" --ignore-not-found &>/dev/null 2>&1 || true
      fi
    done
    # Wait for any Terminating namespaces to finish
    for i in $(seq 1 15); do
      if ! kubectl get ns 2>/dev/null | grep -q Terminating; then
        break
      fi
      sleep 2
    done
  fi

  # Restore kubelet config if backup exists
  if [ -f /var/lib/kubelet/config.yaml.bak ]; then
    sudo cp /var/lib/kubelet/config.yaml.bak /var/lib/kubelet/config.yaml
    sudo systemctl restart kubelet &>/dev/null 2>&1 || true
  fi

  # Clean up leftover files from other questions
  rm -f ~/nginx-deployment.yaml ~/sbom-deployment.yaml ~/report.spdx 2>/dev/null || true
  rm -rf ~/cks/docker 2>/dev/null || true
  rm -rf ~/monitor 2>/dev/null || true
}

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
