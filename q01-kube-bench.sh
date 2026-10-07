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

  if [ -f "$KUBELET_CONFIG" ]; then
    cp "$KUBELET_CONFIG" "${KUBELET_CONFIG}.bak"

    python3 - "$KUBELET_CONFIG" <<'PYEOF'
import yaml, sys
config_path = sys.argv[1]
with open(config_path, "r") as f:
    config = yaml.safe_load(f)

config.setdefault("authentication", {})
config["authentication"].setdefault("anonymous", {})
config["authentication"]["anonymous"]["enabled"] = True

config["authentication"].setdefault("webhook", {})
config["authentication"]["webhook"]["enabled"] = False

config.setdefault("authorization", {})
config["authorization"]["mode"] = "AlwaysAllow"

with open(config_path, "w") as f:
    yaml.dump(config, f, default_flow_style=False)
print("  kubelet config weakened.")
PYEOF
  else
    fail "Kubelet config not found at $KUBELET_CONFIG"
    exit 1
  fi

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

  echo ""
  echo -e "${BOLD}  Kubelet Config: $KUBELET_CONFIG${NC}"
  echo "  ─────────────────────────────────────────"

  # Check 1: kubelet anonymous.enabled is false
  local anon_val=$(python3 -c "
import yaml
with open('$KUBELET_CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('authentication',{}).get('anonymous',{}).get('enabled','MISSING'))
" 2>/dev/null || echo "ERROR")

  if [ "$anon_val" = "False" ]; then
    pass "anonymous.enabled = false"
    score=$((score + 1))
  else
    fail "anonymous.enabled = $anon_val (should be false)"
    echo -e "        ${YELLOW}Why: Anonymous auth lets unauthenticated requests hit the kubelet API"
    echo -e "        on port 10250. An attacker can list pods, exec into containers,"
    echo -e "        and read logs without any credentials.${NC}"
    echo -e "        ${CYAN}Fix: authentication.anonymous.enabled: false${NC}"
  fi

  # Check 2: kubelet authorization.mode is Webhook
  local auth_mode=$(python3 -c "
import yaml
with open('$KUBELET_CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('authorization',{}).get('mode','MISSING'))
" 2>/dev/null || echo "ERROR")

  if [ "$auth_mode" = "Webhook" ]; then
    pass "authorization.mode = Webhook"
    score=$((score + 1))
  else
    fail "authorization.mode = $auth_mode (should be Webhook)"
    echo -e "        ${YELLOW}Why: AlwaysAllow means ANY authenticated request is authorized —"
    echo -e "        no RBAC checks. Webhook delegates to the API server's RBAC.${NC}"
    echo -e "        ${CYAN}Fix: authorization.mode: Webhook${NC}"
  fi

  # Check 3: kubelet authentication.webhook.enabled is true
  local webhook_val=$(python3 -c "
import yaml
with open('$KUBELET_CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('authentication',{}).get('webhook',{}).get('enabled','MISSING'))
" 2>/dev/null || echo "ERROR")

  if [ "$webhook_val" = "True" ]; then
    pass "authentication.webhook.enabled = true"
    score=$((score + 1))
  else
    fail "authentication.webhook.enabled = $webhook_val (should be true)"
    echo -e "        ${YELLOW}Why: Without webhook auth, the kubelet can't verify bearer tokens"
    echo -e "        against the API server. This breaks the authentication chain.${NC}"
    echo -e "        ${CYAN}Fix: authentication.webhook.enabled: true${NC}"
  fi

  echo ""
  echo -e "${BOLD}  ETCD Manifest: $ETCD_MANIFEST${NC}"
  echo "  ─────────────────────────────────────────"

  # Check 4: etcd has --client-cert-auth=true
  local etcd_val=$(grep -o '\-\-client-cert-auth=[a-z]*' "$ETCD_MANIFEST" 2>/dev/null | head -1)

  if echo "$etcd_val" | grep -q 'true'; then
    pass "etcd --client-cert-auth=true"
    score=$((score + 1))
  else
    fail "etcd ${etcd_val:-missing} (should be --client-cert-auth=true)"
    echo -e "        ${YELLOW}Why: Without client cert auth, anyone with network access to etcd"
    echo -e "        (port 2379) can read ALL cluster secrets in plaintext.${NC}"
    echo -e "        ${CYAN}Fix: --client-cert-auth=true in etcd.yaml command args${NC}"
  fi

  echo ""

  # Restart check
  if kubectl get nodes &>/dev/null; then
    pass "Cluster is healthy — kubectl works"
  else
    fail "Cluster unreachable — did you restart kubelet?"
    echo -e "        ${CYAN}Run: systemctl daemon-reload && systemctl restart kubelet${NC}"
  fi

  score_report "$score" "$total"

  if [ "$score" -eq "$total" ]; then
    echo ""
    echo -e "  ${GREEN}Clean sweep. On the exam that's ~8 points in under 5 minutes.${NC}"
    echo -e "  ${GREEN}The pattern: kube-bench run | grep FAIL → fix → restart → verify.${NC}"
  elif [ "$score" -ge 3 ]; then
    echo ""
    echo -e "  ${YELLOW}Almost there. Review the FAIL items above — the 'Why' explains${NC}"
    echo -e "  ${YELLOW}what the attacker gains if you miss it.${NC}"
  else
    echo ""
    echo -e "  ${RED}Multiple items missed. Use the hints: ./run.sh 1 hint${NC}"
  fi
}

do_hint() {
  local level="${2:-1}"
  header "$QUESTION — HINT $level"

  case "$level" in
    1)
      cat <<'HINT'
SPEED: Find all failures instantly:

  kube-bench run 2>/dev/null | grep "\[FAIL\]"

Each FAIL line has a check number (e.g. 4.2.1). After fixing,
verify just that one check:

  kube-bench run --check 4.2.1
HINT
      ;;
    2)
      cat <<'HINT'
SPEED: Find kubelet config path without guessing:

  ps -ef | grep kubelet | grep -- --config

SPEED: Jump straight to the auth section in vi:

  vi /var/lib/kubelet/config.yaml
  /anonymous          ← search for it

ETCD is a static pod — editing the manifest auto-restarts it.
Kubelet is a systemd service — you must restart it manually.
HINT
      ;;
    3)
      cat <<'HINT'
SPEED: The 3 kubelet fields are all in the first 10 lines:

  anonymous.enabled    false
  webhook.enabled      true
  authorization.mode   Webhook (not AlwaysAllow)

SPEED: One-liner restart:

  systemctl daemon-reload && systemctl restart kubelet

SPEED: Verify node is healthy after:

  kubectl get nodes
HINT
      ;;
    *)
      echo "No more hints. Run: ./run.sh 1 solution"
      ;;
  esac
  echo ""
  echo "Next hint: ./run.sh 1 hint $((level + 1))"
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<'SOLUTION'

  ┌─────────────────────────────────────────────────┐
  │  EXAM SPEED RUN — Total time target: 5 minutes  │
  └─────────────────────────────────────────────────┘

  STEP 1: Find the failures (30 seconds)
  ───────────────────────────────────────
  kube-bench run 2>/dev/null | grep "\[FAIL\]"

  You're looking for kubelet (4.2.x) and etcd (2.x) failures.
  Ignore everything else — the question tells you what to fix.


  STEP 2: Find the kubelet config (10 seconds)
  ─────────────────────────────────────────────
  ps -ef | grep kubelet | grep -- --config

  This shows: --config=/var/lib/kubelet/config.yaml
  That's your file. Open it:

  vi /var/lib/kubelet/config.yaml


  STEP 3: Fix kubelet — 3 fields (2 minutes)
  ───────────────────────────────────────────
  The authentication/authorization block should look like:

    authentication:
      anonymous:
        enabled: false        ← blocks unauthenticated access
      webhook:
        enabled: true         ← tokens verified by API server
    authorization:
      mode: Webhook           ← RBAC enforced, not AlwaysAllow

  WHY THESE MATTER:
  • anonymous=true → anyone can hit kubelet:10250 without creds
  • webhook=false  → bearer tokens aren't verified
  • AlwaysAllow    → every request is authorized, no RBAC


  STEP 4: Fix etcd (1 minute)
  ────────────────────────────
  vi /etc/kubernetes/manifests/etcd.yaml

  Find in the command args:
    --client-cert-auth=false

  Change to:
    --client-cert-auth=true

  WHY: Without this, anyone with network access to port 2379
  can read ALL cluster secrets without presenting a certificate.

  NOTE: etcd.yaml is a static pod manifest — kubelet auto-restarts
  it when you save. No manual restart needed for etcd.


  STEP 5: Restart kubelet (30 seconds)
  ─────────────────────────────────────
  systemctl daemon-reload && systemctl restart kubelet

  NOTE: daemon-reload first because kubelet is a systemd service.
  Always pair these two commands.


  STEP 6: Verify (30 seconds)
  ────────────────────────────
  kubectl get nodes               ← node should be Ready
  kube-bench run --check 4.2.1    ← verify individual fix
  ./run.sh 1 check                ← full grading


  COMMON MISTAKES:
  ────────────────
  ✗ Editing kube-apiserver.yaml instead of kubelet config.yaml
    → kubelet settings are NOT in the API server manifest

  ✗ Forgetting systemctl restart kubelet after config change
    → kubelet doesn't watch its config file like static pods do

  ✗ Confusing authentication.webhook with authorization.webhook
    → authentication.webhook.enabled = verify tokens (true)
    → authorization.mode = check RBAC permissions (Webhook)

SOLUTION
}

case "${1:-}" in
  setup)    do_setup ;;
  check)    do_check ;;
  hint)     do_hint "$@" ;;
  solution) do_solution ;;
  *)
    echo "Usage: $0 {setup|check|hint [1-3]|solution}"
    exit 1
    ;;
esac
