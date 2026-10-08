#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q05 — Falco /dev/mem Detection Setup"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires Falco on kubeadm — run on Killercoda"
    exit 0
  fi

  # Install Falco if not present
  if ! command -v falco &>/dev/null && ! systemctl is-active falco &>/dev/null 2>&1; then
    info "Installing Falco..."
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" | sudo tee /etc/apt/sources.list.d/falcosecurity.list
    sudo apt-get update -y
    sudo apt-get install -y falco
    info "Falco installed."
  else
    info "Falco already installed."
  fi

  # Create namespace
  info "Creating namespace neuron..."
  kubectl create ns neuron --dry-run=client -o yaml | kubectl apply -f -

  # Deploy 3 deployments — one will read /dev/mem (the offending one)
  info "Deploying facebook, instagram, and tinder workloads..."
  kubectl apply -n neuron -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: facebook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: facebook
  template:
    metadata:
      labels:
        app: facebook
    spec:
      containers:
        - name: facebook
          image: nginx:1.25
          command: ["sh", "-c", "nginx -g 'daemon off;'"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: instagram
spec:
  replicas: 1
  selector:
    matchLabels:
      app: instagram
  template:
    metadata:
      labels:
        app: instagram
    spec:
      containers:
        - name: instagram
          image: busybox:1.36
          command: ["sh", "-c", "while true; do cat /dev/mem 2>/dev/null || true; sleep 30; done"]
          securityContext:
            privileged: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tinder
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tinder
  template:
    metadata:
      labels:
        app: tinder
    spec:
      containers:
        - name: tinder
          image: httpd:2.4
EOF

  kubectl -n neuron rollout status deployment/facebook --timeout=60s 2>/dev/null || true
  kubectl -n neuron rollout status deployment/instagram --timeout=60s 2>/dev/null || true
  kubectl -n neuron rollout status deployment/tinder --timeout=60s 2>/dev/null || true

  # Clear local rules file
  info "Clearing Falco local rules..."
  sudo tee /etc/falco/falco_rules.local.yaml > /dev/null <<'CLEAREOF'
# Add your custom rules here
CLEAREOF

  echo ""
  pass "Setup complete."
  echo ""
  info "TASK: Detect the pod reading /dev/mem using Falco and scale it down."
  info "  1. Write a Falco rule in /etc/falco/falco_rules.local.yaml to detect reads of /dev/mem"
  info "  2. Run Falco to identify which deployment's pod is reading /dev/mem"
  info "  3. Scale the offending deployment to 0 replicas"
  info "  Namespace: neuron | Deployments: facebook, instagram, tinder"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q05 — Falco /dev/mem Detection Check"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires Falco on kubeadm — run on Killercoda"
    exit 0
  fi

  SCORE=0

  # Check 1: Falco rules file has a rule for /dev/mem
  if sudo grep -q '/dev/mem' /etc/falco/falco_rules.local.yaml 2>/dev/null; then
    pass "Falco local rules contain a rule for /dev/mem"
    SCORE=$((SCORE + 1))
  else
    fail "No /dev/mem rule found in /etc/falco/falco_rules.local.yaml"
  fi

  # Check 2: One deployment is scaled to 0
  SCALED_DOWN=0
  OFFENDER=""
  for DEPLOY in facebook instagram tinder; do
    REPLICAS=$(kubectl get deployment "$DEPLOY" -n neuron -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$REPLICAS" = "0" ]; then
      ((SCALED_DOWN++))
      OFFENDER="$DEPLOY"
    fi
  done

  if [ "$SCALED_DOWN" -eq 1 ]; then
    pass "One deployment scaled to 0: $OFFENDER"
    SCORE=$((SCORE + 1))
  elif [ "$SCALED_DOWN" -eq 0 ]; then
    fail "No deployments scaled to 0 — identify and scale down the offending deployment"
  else
    fail "Multiple deployments scaled to 0 — only the offending one should be scaled down"
  fi

  # Check 3: Other deployments still running
  RUNNING=0
  for DEPLOY in facebook instagram tinder; do
    REPLICAS=$(kubectl get deployment "$DEPLOY" -n neuron -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ "$REPLICAS" -gt 0 ] 2>/dev/null; then
      ((RUNNING++))
    fi
  done

  if [ "$RUNNING" -ge 2 ]; then
    pass "Other deployments still have replicas > 0 ($RUNNING running)"
    SCORE=$((SCORE + 1))
  else
    fail "Expected at least 2 deployments still running (found $RUNNING)"
  fi

  score_report $SCORE 3
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q05 — Falco /dev/mem Detection Solution"

  echo -e "${BOLD}1. Create a Falco rule to detect /dev/mem access:${NC}"
  echo "   Edit /etc/falco/falco_rules.local.yaml:"
  cat <<'RULEEOF'

   - rule: Detect /dev/mem Read
     desc: Detect any process reading /dev/mem
     condition: open_read and fd.name = "/dev/mem"
     output: >
       /dev/mem read detected
       (user=%user.name command=%proc.cmdline container_id=%container.id
       container_name=%container.name k8s_pod=%k8s.pod.name
       k8s_ns=%k8s.ns.name image=%container.image.repository)
     priority: CRITICAL
     tags: [filesystem]

RULEEOF

  echo -e "${BOLD}2. Run Falco to identify the offending pod:${NC}"
  echo "   sudo falco --dry-run       # validate rules"
  echo "   sudo falco -M 30           # run for 30 seconds and watch output"
  echo "   # Look for the pod name in the output — it will be from the 'instagram' deployment"
  echo ""
  echo -e "${BOLD}3. Scale the offending deployment to 0:${NC}"
  echo "   kubectl -n neuron scale deployment/instagram --replicas=0"
  echo ""
  echo -e "${BOLD}Verification:${NC}"
  echo "   kubectl -n neuron get deployments"
  echo "   # instagram should have 0/0 READY, facebook and tinder still running"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
