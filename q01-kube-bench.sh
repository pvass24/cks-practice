#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q01 — CIS Benchmark Fixes (Kubelet + ETCD)"
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
ETCD_MANIFEST="/etc/kubernetes/manifests/etcd.yaml"

do_setup() {
  header "$QUESTION — SETUP"

  if ! requires_kubeadm; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  # Install kube-bench if not present
  if ! command -v kube-bench &>/dev/null; then
    info "Installing kube-bench..."
    curl -sL https://github.com/aquasecurity/kube-bench/releases/download/v0.8.0/kube-bench_0.8.0_linux_amd64.tar.gz | tar xz -C /tmp
    sudo mv /tmp/kube-bench /usr/local/bin/
    sudo mkdir -p /etc/kube-bench
    if [ -d /tmp/cfg ]; then
      sudo cp -r /tmp/cfg /etc/kube-bench/
    fi
    pass "kube-bench installed"
  else
    pass "kube-bench already installed"
  fi

  info "Weakening kubelet config to create insecure baseline..."

  # Patch kubelet config: anonymous.enabled=true, webhook.enabled=false, authorization.mode=AlwaysAllow
  if [ -f "$KUBELET_CONFIG" ]; then
    cp "$KUBELET_CONFIG" "${KUBELET_CONFIG}.bak"

    # Set anonymous auth enabled
    sed -i 's/anonymous:/anonymous:\n    enabled: true/' "$KUBELET_CONFIG" 2>/dev/null || true
    sed -i '/anonymous:/{n;s/enabled: false/enabled: true/}' "$KUBELET_CONFIG"

    # Set webhook enabled false
    sed -i '/webhook:/{n;s/enabled: true/enabled: false/}' "$KUBELET_CONFIG"

    # Set authorization mode to AlwaysAllow
    sed -i 's/mode: Webhook/mode: AlwaysAllow/' "$KUBELET_CONFIG"
  else
    fail "Kubelet config not found at $KUBELET_CONFIG"
    exit 1
  fi

  # Patch etcd manifest: set --client-cert-auth=false
  if [ -f "$ETCD_MANIFEST" ]; then
    cp "$ETCD_MANIFEST" "${ETCD_MANIFEST}.bak"
    sed -i 's/--client-cert-auth=true/--client-cert-auth=false/' "$ETCD_MANIFEST"
  else
    fail "ETCD manifest not found at $ETCD_MANIFEST"
    exit 1
  fi

  # Restart kubelet
  systemctl restart kubelet
  info "Kubelet restarted."

  echo ""
  pass "Setup complete. The kubelet and etcd are now insecure."
  echo ""
  echo "TASK: A CIS benchmark scan has flagged critical violations."
  echo ""
  echo "  1. Run kube-bench to identify the failures:"
  echo "     kube-bench run --targets node"
  echo "     kube-bench run --targets etcd"
  echo ""
  echo "  2. Fix ALL reported violations in:"
  echo "     - $KUBELET_CONFIG"
  echo "     - $ETCD_MANIFEST"
  echo ""
  echo "  3. Restart affected components so changes take effect."
  echo ""
  echo "  When done: ./run.sh 1 check"
  echo ""
  timer_start
}

do_check() {
  header "$QUESTION — CHECK"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  local score=0
  local total=4

  # Check 1: kubelet anonymous.enabled is false
  if grep -A1 'anonymous:' "$KUBELET_CONFIG" 2>/dev/null | grep -q 'enabled: false'; then
    pass "Kubelet anonymous auth is disabled"
    score=$((score + 1))
  else
    fail "Kubelet anonymous auth is NOT disabled (anonymous.enabled should be false)"
  fi

  # Check 2: kubelet authorization.mode is Webhook
  if grep -q 'mode: Webhook' "$KUBELET_CONFIG" 2>/dev/null; then
    pass "Kubelet authorization mode is Webhook"
    score=$((score + 1))
  else
    fail "Kubelet authorization mode is NOT Webhook"
  fi

  # Check 3: kubelet authentication.webhook.enabled is true
  if sed -n '/^authentication:/,/^[a-z]/p' "$KUBELET_CONFIG" 2>/dev/null | grep -A2 'webhook:' | grep -q 'enabled: true'; then
    pass "Kubelet webhook authentication is enabled"
    score=$((score + 1))
  else
    fail "Kubelet webhook authentication is NOT enabled"
  fi

  # Check 4: etcd has --client-cert-auth=true
  if grep -q '\-\-client-cert-auth=true' "$ETCD_MANIFEST" 2>/dev/null; then
    pass "ETCD client-cert-auth is true"
    score=$((score + 1))
  else
    fail "ETCD client-cert-auth is NOT true"
  fi

  score_report "$score" "$total"

  if [ "${CKS_TIMER_START:-}" ]; then
    timer_stop "15 minutes"
  fi
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<'SOLUTION'
1. Edit /var/lib/kubelet/config.yaml:

   authentication:
     anonymous:
       enabled: false        # was: true
     webhook:
       enabled: true         # was: false
   authorization:
     mode: Webhook           # was: AlwaysAllow

2. Edit /etc/kubernetes/manifests/etcd.yaml:

   Change the etcd container command arg:
     --client-cert-auth=true   # was: false

3. Restart kubelet:

   systemctl restart kubelet

   (etcd restarts automatically when manifest changes — it's a static pod)

VERIFICATION:
   Run: ./q01-kube-bench.sh check
SOLUTION
}

case "${1:-}" in
  setup)    do_setup ;;
  check)    do_check ;;
  solution) do_solution ;;
  *)
    echo "Usage: $0 {setup|check|solution}"
    exit 1
    ;;
esac
