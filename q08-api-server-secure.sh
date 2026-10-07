#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q08 — API Server Hardening"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

do_setup() {
  header "$QUESTION — SETUP"

  if ! requires_kubeadm; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  info "Weakening API server and creating anonymous ClusterRoleBinding..."

  # Remove --anonymous-auth flag if present (defaults to true when absent)
  if [ -f "$APISERVER_MANIFEST" ]; then
    cp "$APISERVER_MANIFEST" "${APISERVER_MANIFEST}.bak"
    sed -i '/--anonymous-auth/d' "$APISERVER_MANIFEST"
  else
    fail "API server manifest not found at $APISERVER_MANIFEST"
    exit 1
  fi

  # Back up admin.conf
  if [ -f /etc/kubernetes/admin.conf ]; then
    cp /etc/kubernetes/admin.conf /etc/kubernetes/admin.conf.bak
    info "Backed up admin.conf"
  fi

  # Create insecure ClusterRoleBinding: system:anonymous -> cluster-admin
  kubectl create clusterrolebinding system:anonymous \
    --clusterrole=cluster-admin \
    --user=system:anonymous \
    2>/dev/null || info "ClusterRoleBinding system:anonymous already exists"

  echo ""
  pass "Setup complete. The API server is now weakened."
  echo ""
  echo "TASK: Harden the kube-apiserver:"
  echo "  1. Set --anonymous-auth=false"
  echo "  2. Ensure --authorization-mode=Node,RBAC"
  echo "  3. Ensure --enable-admission-plugins contains NodeRestriction"
  echo "  4. Delete the system:anonymous ClusterRoleBinding"
  echo ""
  echo "File to edit:"
  echo "  - $APISERVER_MANIFEST"
  echo ""
  echo "Also run: kubectl delete clusterrolebinding system:anonymous"
  echo ""
  timer_start
}

do_check() {
  header "$QUESTION — CHECK"

  local score=0
  local total=4

  if [ "$ENV_TYPE" = "kubeadm" ]; then
    # Check 1: kube-apiserver has --anonymous-auth=false
    if grep -q '\-\-anonymous-auth=false' "$APISERVER_MANIFEST" 2>/dev/null; then
      pass "API server has --anonymous-auth=false"
      score=$((score + 1))
    else
      fail "API server missing --anonymous-auth=false"
    fi

    # Check 2: kube-apiserver has --authorization-mode=Node,RBAC
    if grep -q '\-\-authorization-mode=Node,RBAC' "$APISERVER_MANIFEST" 2>/dev/null; then
      pass "API server has --authorization-mode=Node,RBAC"
      score=$((score + 1))
    else
      fail "API server missing --authorization-mode=Node,RBAC"
    fi

    # Check 3: kube-apiserver has NodeRestriction admission plugin
    if grep '\-\-enable-admission-plugins' "$APISERVER_MANIFEST" 2>/dev/null | grep -q 'NodeRestriction'; then
      pass "API server has NodeRestriction admission plugin"
      score=$((score + 1))
    else
      fail "API server missing NodeRestriction in --enable-admission-plugins"
    fi
  else
    skip "API server manifest checks require kubeadm (checks 1-3)"
    skip "  --anonymous-auth=false"
    skip "  --authorization-mode=Node,RBAC"
    skip "  NodeRestriction admission plugin"
  fi

  # Check 4: ClusterRoleBinding system:anonymous does NOT exist (works on both kind and kubeadm)
  if kubectl get clusterrolebinding system:anonymous &>/dev/null; then
    fail "ClusterRoleBinding system:anonymous still exists — delete it!"
  else
    pass "ClusterRoleBinding system:anonymous does not exist"
    score=$((score + 1))
  fi

  score_report "$score" "$total"

  if [ "${CKS_TIMER_START:-}" ]; then
    timer_stop "10 minutes"
  fi
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<'SOLUTION'
1. Edit /etc/kubernetes/manifests/kube-apiserver.yaml:

   Add or ensure these flags in the kube-apiserver command:
     --anonymous-auth=false
     --authorization-mode=Node,RBAC
     --enable-admission-plugins=NodeRestriction

   Example (in the spec.containers[0].command section):
     - kube-apiserver
     - --anonymous-auth=false
     - --authorization-mode=Node,RBAC
     - --enable-admission-plugins=NodeRestriction
     ... (other existing flags)

2. Delete the insecure ClusterRoleBinding:

   kubectl delete clusterrolebinding system:anonymous

3. Wait for API server to restart (static pod picks up manifest changes):

   watch crictl ps    # or: kubectl get pods -n kube-system

VERIFICATION:
   Run: ./q08-api-server-secure.sh check
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
