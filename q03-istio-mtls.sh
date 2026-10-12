#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q03 — Istio mTLS Setup"

  if [ "$ENV_TYPE" = "unknown" ]; then
    skip "No Kubernetes cluster detected"
    exit 0
  fi

  # Install Istio if not present
  if ! command -v istioctl &>/dev/null; then
    info "Downloading Istio CLI..."
    curl -L https://istio.io/downloadIstio | sh -
    ISTIO_DIR=$(ls -d istio-* 2>/dev/null | head -1)
    if [ -n "$ISTIO_DIR" ]; then
      sudo cp "$ISTIO_DIR/bin/istioctl" /usr/local/bin/
    else
      fail "Istio download failed."
      exit 1
    fi
  else
    info "Istio CLI already installed."
  fi

  # Install/verify Istio control plane with retry
  if kubectl get pods -n istio-system 2>/dev/null | grep -q "istiod.*Running"; then
    info "Istio control plane already running."
  else
    info "Installing Istio control plane (minimal profile + control-plane toleration)..."
    cat > /tmp/istio-operator.yaml <<'IOEOF'
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: minimal
  components:
    pilot:
      k8s:
        tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
IOEOF
    istioctl install -f /tmp/istio-operator.yaml -y || true

    info "Waiting for istiod to be ready (up to 120s)..."
    for i in $(seq 1 24); do
      if kubectl get pods -n istio-system 2>/dev/null | grep -q "istiod.*Running"; then
        pass "Istio control plane is ready."
        break
      fi
      if [ "$i" -eq 24 ]; then
        info "Retrying Istio install..."
        istioctl install -f /tmp/istio-operator.yaml -y || true
        kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=90s 2>/dev/null || true
      fi
      sleep 5
    done
  fi

  # Create fresh namespace WITHOUT istio-injection label
  info "Creating fresh namespace istio-example (without injection label)..."
  fresh_namespace "istio-example"

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

  if [ "$ENV_TYPE" = "unknown" ]; then
    skip "No Kubernetes cluster detected"
    exit 0
  fi

  SCORE=0

  # Check 1: Namespace has istio-injection=enabled
  INJECTION_LABEL=$(kubectl get ns istio-example -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)
  if [ "$INJECTION_LABEL" = "enabled" ]; then
    pass "Namespace istio-example has istio-injection=enabled"
    SCORE=$((SCORE + 1))
  else
    fail "Namespace istio-example missing istio-injection=enabled label (got: '$INJECTION_LABEL')"
  fi

  # Check 2: Pods have istio-proxy sidecar (2 containers per pod)
  PODS_WITH_SIDECAR=0
  TOTAL_PODS=0
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      TOTAL_PODS=$((TOTAL_PODS + 1))
      CONTAINER_COUNT=$(echo "$line" | awk -F/ '{print $2}')
      if [ "$CONTAINER_COUNT" -ge 2 ] 2>/dev/null; then
        PODS_WITH_SIDECAR=$((PODS_WITH_SIDECAR + 1))
      fi
    fi
  done < <(kubectl get pods -n istio-example --no-headers 2>/dev/null | awk '{print $2}')

  if [ "$TOTAL_PODS" -gt 0 ] && [ "$PODS_WITH_SIDECAR" -eq "$TOTAL_PODS" ]; then
    pass "All pods in istio-example have istio-proxy sidecar ($PODS_WITH_SIDECAR/$TOTAL_PODS)"
    SCORE=$((SCORE + 1))
  else
    fail "Not all pods have sidecar containers ($PODS_WITH_SIDECAR/$TOTAL_PODS with 2+ containers)"
  fi

  # Check 3: PeerAuthentication with mode STRICT exists
  PA_MODE=$(kubectl get peerauthentication default -n istio-example -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "MISSING")
  if [ "$PA_MODE" = "STRICT" ]; then
    pass "PeerAuthentication 'default' exists with mode STRICT"
    SCORE=$((SCORE + 1))
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
