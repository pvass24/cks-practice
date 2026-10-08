#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q07 — Worker Node Upgrade Setup"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires multi-node kubeadm cluster — run on Killercoda"
    exit 0
  fi

  # Get node info
  CONTROL_PLANE=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  WORKER=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -z "$WORKER" ]; then
    fail "No worker node found. This question requires a 2-node cluster."
    exit 1
  fi

  CP_VERSION=$(kubectl get node "$CONTROL_PLANE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)
  WORKER_VERSION=$(kubectl get node "$WORKER" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)

  info "Cluster nodes:"
  info "  Control plane: $CONTROL_PLANE ($CP_VERSION)"
  info "  Worker:        $WORKER ($WORKER_VERSION)"

  if [ "$CP_VERSION" = "$WORKER_VERSION" ]; then
    info "Both nodes are at the same version."
    info "For this exercise, the control plane should already be upgraded"
    info "and the worker should be one minor version behind."
    info "If using Killercoda, use the 'Kubernetes Upgrade' scenario."
  fi

  echo ""
  pass "Setup complete (environment check only)."
  echo ""
  info "TASK: Upgrade the worker node to match the control plane version."
  info "  Control plane: $CONTROL_PLANE ($CP_VERSION)"
  info "  Worker node:   $WORKER ($WORKER_VERSION)"
  info ""
  info "  Steps:"
  info "  1. Drain the worker node"
  info "  2. SSH to the worker and upgrade kubeadm, then run kubeadm upgrade node"
  info "  3. Upgrade kubelet and kubectl on the worker"
  info "  4. Restart kubelet"
  info "  5. Uncordon the worker node"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q07 — Worker Node Upgrade Check"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires multi-node kubeadm cluster — run on Killercoda"
    exit 0
  fi

  SCORE=0

  CONTROL_PLANE=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  WORKER=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -z "$WORKER" ]; then
    fail "No worker node found."
    score_report 0 3
    exit 0
  fi

  CP_VERSION=$(kubectl get node "$CONTROL_PLANE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)
  WORKER_VERSION=$(kubectl get node "$WORKER" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)

  # Check 1: Worker kubelet version matches control plane
  if [ "$CP_VERSION" = "$WORKER_VERSION" ]; then
    pass "Worker kubelet version matches control plane ($WORKER_VERSION)"
    SCORE=$((SCORE + 1))
  else
    fail "Worker kubelet version ($WORKER_VERSION) does not match control plane ($CP_VERSION)"
  fi

  # Check 2: Worker node is Ready
  WORKER_STATUS=$(kubectl get node "$WORKER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  WORKER_SCHED=$(kubectl get node "$WORKER" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
  if [ "$WORKER_STATUS" = "True" ] && [ "$WORKER_SCHED" != "true" ]; then
    pass "Worker node $WORKER is Ready and schedulable"
    SCORE=$((SCORE + 1))
  elif [ "$WORKER_STATUS" = "True" ] && [ "$WORKER_SCHED" = "true" ]; then
    fail "Worker node is Ready but still cordoned (run: kubectl uncordon $WORKER)"
  else
    fail "Worker node $WORKER is not Ready (status: $WORKER_STATUS)"
  fi

  # Check 3: kubeadm, kubelet, kubectl all same version on worker
  # This requires SSH access — we check what we can from the control plane
  # The kubelet version is already checked above; for kubeadm/kubectl we attempt SSH
  if command -v ssh &>/dev/null; then
    KUBEADM_VER=$(ssh "$WORKER" "kubeadm version -o short" 2>/dev/null || echo "unknown")
    KUBECTL_VER=$(ssh "$WORKER" "kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | awk -F'\"' '{print \$4}'" 2>/dev/null || echo "unknown")
    KUBELET_VER_SSH=$(ssh "$WORKER" "kubelet --version 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "unknown")

    if [ "$KUBEADM_VER" != "unknown" ] && [ "$KUBECTL_VER" != "unknown" ] && [ "$KUBELET_VER_SSH" != "unknown" ]; then
      if [ "$KUBEADM_VER" = "$KUBELET_VER_SSH" ] || [ "$KUBEADM_VER" = "$CP_VERSION" ]; then
        pass "Worker tools consistent: kubeadm=$KUBEADM_VER kubelet=$KUBELET_VER_SSH"
        SCORE=$((SCORE + 1))
      else
        fail "Version mismatch on worker: kubeadm=$KUBEADM_VER kubelet=$KUBELET_VER_SSH kubectl=$KUBECTL_VER"
      fi
    else
      info "Cannot SSH to worker to verify tool versions — scoring based on kubelet version only"
      if [ "$CP_VERSION" = "$WORKER_VERSION" ]; then
        pass "Kubelet version matches (SSH unavailable for full tool check)"
        SCORE=$((SCORE + 1))
      else
        fail "Kubelet version mismatch (SSH unavailable for full tool check)"
      fi
    fi
  else
    info "SSH not available — checking kubelet version only"
    if [ "$CP_VERSION" = "$WORKER_VERSION" ]; then
      pass "Kubelet version matches control plane (SSH unavailable for full check)"
      SCORE=$((SCORE + 1))
    else
      fail "Kubelet version mismatch"
    fi
  fi

  score_report $SCORE 3
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q07 — Worker Node Upgrade Solution"

  # Determine current versions for the solution text
  CONTROL_PLANE=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "controlplane")
  WORKER=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "node01")
  CP_VERSION=$(kubectl get node "$CONTROL_PLANE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "v1.31.0")
  # Strip the 'v' prefix for apt package versions
  VERSION_NUM="${CP_VERSION#v}"
  MINOR_VERSION=$(echo "$VERSION_NUM" | cut -d. -f1,2)

  echo -e "${BOLD}Full upgrade procedure for worker node '$WORKER' to $CP_VERSION:${NC}"
  echo ""
  echo -e "${BOLD}Step 1: Drain the worker node (from control plane):${NC}"
  echo "   kubectl drain $WORKER --ignore-daemonsets --delete-emptydir-data"
  echo ""
  echo -e "${BOLD}Step 2: SSH to the worker node:${NC}"
  echo "   ssh $WORKER"
  echo ""
  echo -e "${BOLD}Step 3: Upgrade kubeadm on the worker:${NC}"
  echo "   sudo apt-get update"
  echo "   sudo apt-get install -y kubeadm=${VERSION_NUM}-*"
  echo ""
  echo -e "${BOLD}Step 4: Run kubeadm upgrade on the worker:${NC}"
  echo "   sudo kubeadm upgrade node"
  echo ""
  echo -e "${BOLD}Step 5: Upgrade kubelet and kubectl:${NC}"
  echo "   sudo apt-get install -y kubelet=${VERSION_NUM}-* kubectl=${VERSION_NUM}-*"
  echo "   sudo systemctl daemon-reload"
  echo "   sudo systemctl restart kubelet"
  echo ""
  echo -e "${BOLD}Step 6: Exit SSH and uncordon (from control plane):${NC}"
  echo "   exit"
  echo "   kubectl uncordon $WORKER"
  echo ""
  echo -e "${BOLD}Verification:${NC}"
  echo "   kubectl get nodes"
  echo "   # Both nodes should show $CP_VERSION and STATUS Ready"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
