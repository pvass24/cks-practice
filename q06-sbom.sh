#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q06 — BOM/SBOM Tool Setup"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires bom tool on kubeadm — run on Killercoda"
    exit 0
  fi

  # Install bom tool if not present
  if ! command -v bom &>/dev/null; then
    info "Installing bom tool..."
    BOM_VERSION="v0.6.0"
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
    esac
    curl -L "https://github.com/kubernetes-sigs/bom/releases/download/${BOM_VERSION}/bom-${ARCH}-linux" -o /tmp/bom
    sudo install /tmp/bom /usr/local/bin/bom
    rm -f /tmp/bom
    info "bom installed."
  else
    info "bom tool already installed."
  fi

  # Create namespace
  info "Creating namespace sbom..."
  kubectl create ns sbom --dry-run=client -o yaml | kubectl apply -f -

  # Deploy with 3 containers using different image tags
  # One container uses an image with libcrypto3 3.1.4-r5 (vulnerable)
  info "Deploying sbom workload with 3 containers..."
  kubectl apply -n sbom -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sbom
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sbom
  template:
    metadata:
      labels:
        app: sbom
    spec:
      containers:
        - name: web
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
        - name: logger
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo heartbeat; sleep 60; done"]
        - name: crypto-util
          image: alpine:3.18.6
          command: ["sh", "-c", "sleep infinity"]
EOF

  kubectl -n sbom rollout status deployment/sbom --timeout=60s 2>/dev/null || true

  # Remove any existing report
  rm -f ~/report.spdx

  echo ""
  pass "Setup complete."
  echo ""
  info "TASK: Generate an SBOM and remove the vulnerable container."
  info "  1. Exec into each container and find which one has libcrypto3 version 3.1.4-r5"
  info "  2. Generate an SBOM report at ~/report.spdx using the bom tool"
  info "  3. Edit the deployment to remove the vulnerable container (should go from 3 to 2 containers)"
  info "  Namespace: sbom | Deployment: sbom"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q06 — BOM/SBOM Tool Check"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires bom tool on kubeadm — run on Killercoda"
    exit 0
  fi

  SCORE=0

  # Check 1: ~/report.spdx exists
  if [ -f ~/report.spdx ]; then
    pass "~/report.spdx exists ($(wc -l < ~/report.spdx) lines)"
    SCORE=$((SCORE + 1))
  else
    fail "~/report.spdx not found — generate it with bom"
  fi

  # Check 2: Deployment has exactly 2 containers
  CONTAINER_COUNT=$(kubectl get deployment sbom -n sbom -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null | wc -w)
  if [ "$CONTAINER_COUNT" -eq 2 ]; then
    pass "Deployment sbom has exactly 2 containers"
    SCORE=$((SCORE + 1))
  else
    fail "Deployment sbom has $CONTAINER_COUNT containers (expected 2)"
  fi

  # Check 3: The removed container was crypto-util (the one with libcrypto3 3.1.4-r5)
  CONTAINERS=$(kubectl get deployment sbom -n sbom -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)
  if ! echo "$CONTAINERS" | grep -q 'crypto-util'; then
    pass "Vulnerable container 'crypto-util' (libcrypto3 3.1.4-r5) was removed"
    SCORE=$((SCORE + 1))
  else
    fail "Container 'crypto-util' still present — this is the vulnerable one to remove"
  fi

  score_report $SCORE 3
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q06 — BOM/SBOM Tool Solution"

  echo -e "${BOLD}1. Find the vulnerable container:${NC}"
  echo "   # Get the pod name"
  echo "   POD=\$(kubectl -n sbom get pod -l app=sbom -o name | head -1)"
  echo ""
  echo "   # Exec into each container and check for libcrypto3"
  echo "   kubectl -n sbom exec \$POD -c web -- apk list 2>/dev/null | grep libcrypto"
  echo "   kubectl -n sbom exec \$POD -c logger -- cat /etc/os-release 2>/dev/null  # busybox, no apk"
  echo "   kubectl -n sbom exec \$POD -c crypto-util -- apk list 2>/dev/null | grep libcrypto"
  echo ""
  echo "   # The crypto-util container (alpine:3.18.6) has libcrypto3 3.1.4-r5"
  echo ""
  echo -e "${BOLD}2. Generate an SBOM with bom:${NC}"
  echo "   bom generate -n sbom -i alpine:3.18.6 -o ~/report.spdx"
  echo "   # Or for the whole deployment:"
  echo "   bom generate -n sbom --image alpine:3.18.6 --output ~/report.spdx"
  echo ""
  echo -e "${BOLD}3. Remove the vulnerable container from the deployment:${NC}"
  echo "   kubectl -n sbom edit deployment sbom"
  echo "   # Remove the entire crypto-util container block from spec.template.spec.containers"
  echo ""
  echo "   # Or patch it:"
  cat <<'PATCHEOF'
   kubectl -n sbom get deployment sbom -o json | \
     jq 'del(.spec.template.spec.containers[] | select(.name == "crypto-util"))' | \
     kubectl apply -f -
PATCHEOF
  echo ""
  echo -e "${BOLD}Verification:${NC}"
  echo "   kubectl -n sbom get deployment sbom -o jsonpath='{.spec.template.spec.containers[*].name}'"
  echo "   # Should show: web logger"
  echo "   ls -la ~/report.spdx"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
