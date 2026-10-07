#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q03 — Istio mTLS Setup"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires Istio on kubeadm — run on Killercoda"
    exit 0
  fi

  # Install Istio if not present
  if ! command -v istioctl &>/dev/null; then
    info "Installing Istio..."
    curl -L https://istio.io/downloadIstio | sh -
    ISTIO_DIR=$(ls -d istio-* 2>/dev/null | head -1)
    if [ -n "$ISTIO_DIR" ]; then
      sudo cp "$ISTIO_DIR/bin/istioctl" /usr/local/bin/
      istioctl install --set profile=default -y
      info "Istio installed."
    else
      fail "Istio download failed."
      exit 1
    fi
  else
    info "Istio already installed."
    # Ensure Istio is running
    if ! kubectl get ns istio-system &>/dev/null; then
      istioctl install --set profile=default -y
    fi
  fi

  # Create namespace WITHOUT istio-injection label
  info "Creating namespace istio-example (without injection label)..."
  kubectl create ns istio-example --dry-run=client -o yaml | kubectl apply -f -
  # Explicitly remove injection label if present
  kubectl label ns istio-example istio-injection- 2>/dev/null || true

  # Deploy instagram and tinder without sidecars
  info "Deploying instagram and tinder workloads (no sidecars)..."
  kubectl apply -n istio-example -f - <<'EOF'
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
          image: nginx:1.25
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: instagram
spec:
  selector:
    app: instagram
  ports:
    - port: 80
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
          image: nginx:1.25
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: tinder
spec:
  selector:
    app: tinder
  ports:
    - port: 80
EOF

  kubectl -n istio-example rollout status deployment/instagram --timeout=60s 2>/dev/null || true
  kubectl -n istio-example rollout status deployment/tinder --timeout=60s 2>/dev/null || true

  echo ""
  pass "Setup complete."
  echo ""
  info "TASK: Enable Istio mTLS for the istio-example namespace."
  info "  1. Label the namespace for automatic sidecar injection"
  info "  2. Restart the deployments so sidecars are injected"
  info "  3. Create a PeerAuthentication resource to enforce STRICT mTLS"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q03 — Istio mTLS Check"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires Istio on kubeadm — run on Killercoda"
    exit 0
  fi

  SCORE=0

  # Check 1: Namespace has istio-injection=enabled
  INJECTION_LABEL=$(kubectl get ns istio-example -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)
  if [ "$INJECTION_LABEL" = "enabled" ]; then
    pass "Namespace istio-example has istio-injection=enabled"
    ((SCORE++))
  else
    fail "Namespace istio-example missing istio-injection=enabled label (got: '$INJECTION_LABEL')"
  fi

  # Check 2: Pods have istio-proxy sidecar (2 containers per pod)
  PODS_WITH_SIDECAR=0
  TOTAL_PODS=0
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      ((TOTAL_PODS++))
      CONTAINER_COUNT=$(echo "$line" | awk -F/ '{print $2}')
      if [ "$CONTAINER_COUNT" -ge 2 ] 2>/dev/null; then
        ((PODS_WITH_SIDECAR++))
      fi
    fi
  done < <(kubectl get pods -n istio-example --no-headers 2>/dev/null | awk '{print $2}')

  if [ "$TOTAL_PODS" -gt 0 ] && [ "$PODS_WITH_SIDECAR" -eq "$TOTAL_PODS" ]; then
    pass "All pods in istio-example have istio-proxy sidecar ($PODS_WITH_SIDECAR/$TOTAL_PODS)"
    ((SCORE++))
  else
    fail "Not all pods have sidecar containers ($PODS_WITH_SIDECAR/$TOTAL_PODS with 2+ containers)"
  fi

  # Check 3: PeerAuthentication with mode STRICT exists
  PA_MODE=$(kubectl get peerauthentication default -n istio-example -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
  if [ "$PA_MODE" = "STRICT" ]; then
    pass "PeerAuthentication 'default' exists with mode STRICT"
    ((SCORE++))
  else
    fail "PeerAuthentication 'default' not found or mode is not STRICT (got: '$PA_MODE')"
  fi

  score_report $SCORE 3
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q03 — Istio mTLS Solution"

  echo -e "${BOLD}1. Label the namespace for sidecar injection:${NC}"
  echo "   kubectl label ns istio-example istio-injection=enabled"
  echo ""
  echo -e "${BOLD}2. Restart deployments to inject sidecars:${NC}"
  echo "   kubectl -n istio-example rollout restart deployment/instagram"
  echo "   kubectl -n istio-example rollout restart deployment/tinder"
  echo ""
  echo -e "${BOLD}3. Create PeerAuthentication for STRICT mTLS:${NC}"
  cat <<'YAMLEOF'

   apiVersion: security.istio.io/v1beta1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: istio-example
   spec:
     mtls:
       mode: STRICT

YAMLEOF
  echo "   Apply with:"
  echo "   kubectl apply -f peerauthentication.yaml"
  echo ""
  echo -e "${BOLD}Verification:${NC}"
  echo "   kubectl get pods -n istio-example   # Should show 2/2 READY"
  echo "   kubectl get peerauthentication -n istio-example"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
