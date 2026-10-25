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

PRISTINE_DIR="/root/.cks-pristine"

# One-time snapshot of all critical config files in their original state.
# Must be run BEFORE any question modifies configs. Use ./run.sh init
# to take the snapshot from a known-good cluster.
save_pristine() {
  if [ "$ENV_TYPE" != "kubeadm" ]; then
    return 0
  fi
  if [ -f "$PRISTINE_DIR/.saved" ]; then
    return 0
  fi

  # Refuse to snapshot a broken cluster
  if ! kubectl get nodes &>/dev/null 2>&1; then
    fail "Cannot save pristine snapshot — cluster is not healthy!"
    fail "Fix the cluster first, then run: ./run.sh init"
    return 1
  fi

  info "Saving pristine cluster config snapshot..."
  sudo mkdir -p "$PRISTINE_DIR"

  # API server manifest
  if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
    sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml "$PRISTINE_DIR/kube-apiserver.yaml"
  fi

  # etcd manifest
  if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
    sudo cp /etc/kubernetes/manifests/etcd.yaml "$PRISTINE_DIR/etcd.yaml"
  fi

  # Kubelet config
  if [ -f /var/lib/kubelet/config.yaml ]; then
    sudo cp /var/lib/kubelet/config.yaml "$PRISTINE_DIR/kubelet-config.yaml"
  fi

  # Docker daemon configs (for Q16)
  if [ -f /lib/systemd/system/docker.service ]; then
    sudo cp /lib/systemd/system/docker.service "$PRISTINE_DIR/docker.service"
  fi
  if [ -f /lib/systemd/system/docker.socket ]; then
    sudo cp /lib/systemd/system/docker.socket "$PRISTINE_DIR/docker.socket"
  fi

  sudo touch "$PRISTINE_DIR/.saved"
  pass "Pristine snapshot saved to $PRISTINE_DIR"
}

# Restore cluster to pristine state before each question.
# No sed, no guessing — just copy the originals back.
clean_apiserver() {
  if [ "$ENV_TYPE" != "kubeadm" ]; then
    return 0
  fi

  # Ensure we have a pristine snapshot
  save_pristine

  local needs_restart=false

  # Restore API server manifest
  if [ -f "$PRISTINE_DIR/kube-apiserver.yaml" ]; then
    if ! diff -q "$PRISTINE_DIR/kube-apiserver.yaml" /etc/kubernetes/manifests/kube-apiserver.yaml &>/dev/null 2>&1; then
      sudo cp "$PRISTINE_DIR/kube-apiserver.yaml" /etc/kubernetes/manifests/kube-apiserver.yaml
      needs_restart=true
      info "API server manifest restored from pristine snapshot"
    fi
  fi

  # Restore etcd manifest
  if [ -f "$PRISTINE_DIR/etcd.yaml" ]; then
    if ! diff -q "$PRISTINE_DIR/etcd.yaml" /etc/kubernetes/manifests/etcd.yaml &>/dev/null 2>&1; then
      sudo cp "$PRISTINE_DIR/etcd.yaml" /etc/kubernetes/manifests/etcd.yaml
      info "etcd manifest restored from pristine snapshot"
    fi
  fi

  # Restore kubelet config
  if [ -f "$PRISTINE_DIR/kubelet-config.yaml" ]; then
    if ! diff -q "$PRISTINE_DIR/kubelet-config.yaml" /var/lib/kubelet/config.yaml &>/dev/null 2>&1; then
      sudo cp "$PRISTINE_DIR/kubelet-config.yaml" /var/lib/kubelet/config.yaml
      sudo systemctl daemon-reload &>/dev/null 2>&1 || true
      sudo systemctl restart kubelet &>/dev/null 2>&1 || true
      needs_restart=true
      info "Kubelet config restored from pristine snapshot"
    fi
  fi

  # Restore docker configs
  if [ -f "$PRISTINE_DIR/docker.service" ]; then
    if ! diff -q "$PRISTINE_DIR/docker.service" /lib/systemd/system/docker.service &>/dev/null 2>&1; then
      sudo cp "$PRISTINE_DIR/docker.service" /lib/systemd/system/docker.service
      sudo systemctl daemon-reload &>/dev/null 2>&1 || true
      sudo systemctl restart docker &>/dev/null 2>&1 || true
      info "Docker service restored from pristine snapshot"
    fi
  fi
  if [ -f "$PRISTINE_DIR/docker.socket" ]; then
    if ! diff -q "$PRISTINE_DIR/docker.socket" /lib/systemd/system/docker.socket &>/dev/null 2>&1; then
      sudo cp "$PRISTINE_DIR/docker.socket" /lib/systemd/system/docker.socket
      info "Docker socket restored from pristine snapshot"
    fi
  fi

  # Remove webhook config dir left by Q2
  sudo rm -rf /etc/kubernetes/webhook 2>/dev/null || true

  # Wait for cluster to be healthy after any restores
  if [ "$needs_restart" = "true" ]; then
    info "Waiting for cluster to stabilize..."
    sleep 10
    for i in $(seq 1 30); do
      if kubectl get nodes &>/dev/null 2>&1; then
        pass "Cluster is healthy"
        break
      fi
      if [ "$i" -eq 30 ]; then
        fail "Cluster not healthy after 90s — may need manual intervention"
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
    for i in $(seq 1 15); do
      if ! kubectl get ns 2>/dev/null | grep -q Terminating; then
        break
      fi
      sleep 2
    done
  fi

  # Clean up leftover files from other questions
  rm -f ~/nginx-deployment.yaml ~/sbom-deployment.yaml ~/report.spdx 2>/dev/null || true
  rm -rf ~/cks/docker 2>/dev/null || true
  rm -rf ~/monitor 2>/dev/null || true
}

# Force-recreate a namespace: delete, wait for termination, create fresh
fresh_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null 2>&1; then
    kubectl delete namespace "$ns" --force --grace-period=0 --ignore-not-found &>/dev/null 2>&1 || true
    for i in $(seq 1 15); do
      if ! kubectl get namespace "$ns" &>/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
  kubectl create namespace "$ns"
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
