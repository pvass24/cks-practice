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

  ISTIO_VERSION="1.26.0"

  # Install Istio CLI if not present
  if ! command -v istioctl &>/dev/null; then
    info "Downloading Istio ${ISTIO_VERSION}..."
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION TARGET_ARCH=x86_64 sh -
    ISTIO_DIR="istio-${ISTIO_VERSION}"
    if [ -d "$ISTIO_DIR" ]; then
      export PATH="$PWD/$ISTIO_DIR/bin:$PATH"
      echo "export PATH=$PWD/$ISTIO_DIR/bin:\$PATH" >> ~/.bashrc
      pass "Istio CLI installed"
    else
      fail "Istio download failed."
      exit 1
    fi
  else
    info "Istio CLI already installed."
    ISTIO_DIR=$(ls -d istio-* 2>/dev/null | head -1)
  fi

  # Configure Cilium to co-exist with Istio (required on Killercoda)
  if kubectl -n kube-system get configmap cilium-config &>/dev/null 2>&1; then
    info "Configuring Cilium for Istio co-existence..."
    kubectl -n kube-system patch configmap cilium-config --type merge -p '{"data":{"kubeProxyReplacement":"true"}}' 2>/dev/null || true
    kubectl -n kube-system patch configmap cilium-config --type merge -p '{"data":{"socketLB.hostNamespaceOnly":"true"}}' 2>/dev/null || true
    kubectl -n kube-system patch configmap cilium-config --type merge -p '{"data":{"cni-exclusive":"false"}}' 2>/dev/null || true
    kubectl -n kube-system patch configmap cilium-config --type merge -p '{"data":{"bpf-lb-sock-hostns-only":"true"}}' 2>/dev/null || true
    kubectl -n kube-system rollout restart daemonset cilium 2>/dev/null || true
    pass "Cilium patched for Istio"
    sleep 10
  fi

  # Install Istio control plane
  if kubectl get pods -n istio-system 2>/dev/null | grep -q "istiod.*Running"; then
    info "Istio control plane already running."
  else
    info "Installing Istio control plane (demo profile)..."
    istioctl install --set profile=demo -y ${ISTIO_DIR:+--manifests=$ISTIO_DIR/manifests} || true

    info "Waiting for istiod to be ready (up to 120s)..."
    for i in $(seq 1 24); do
      if kubectl get pods -n istio-system 2>/dev/null | grep -q "istiod.*Running"; then
        pass "Istio control plane is ready."
        break
      fi
      if [ "$i" -eq 24 ]; then
        fail "Istio control plane not ready after 120s"
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
  INJECTION_LABEL=$(kubectl get ns istio-example -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)
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
