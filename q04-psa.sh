#!/bin/bash
# CKS Practice — Q04: Pod Security Admission
source "$(dirname "$0")/lib.sh"

NAMESPACE="restricted"
DEPLOYMENT="nginx-unprivileged"
MANIFEST="$HOME/nginx-deployment.yaml"

do_setup() {
  header "Q04 Setup — Pod Security Admission"

  info "Creating namespace '$NAMESPACE' with PSA enforce=restricted..."
  fresh_namespace "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    --overwrite

  info "Creating non-compliant deployment manifest at $MANIFEST..."
  cat > "$MANIFEST" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-unprivileged
  namespace: restricted
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-unprivileged
  template:
    metadata:
      labels:
        app: nginx-unprivileged
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged
        ports:
        - containerPort: 8080
EOF

  info "Applying manifest (pods will be rejected by PSA)..."
  kubectl apply -f "$MANIFEST" 2>&1 || true

  info "Setup complete."
  echo ""
  echo -e "  ${BOLD}TASK: Fix the deployment manifest so pods comply with PSA restricted${NC}"
  echo ""
  echo "  Namespace:  restricted"
  echo "  Deployment: nginx-unprivileged"
  echo "  Manifest:   ~/nginx-deployment.yaml"
  echo ""
  echo "  Requirements:"
  echo "    - allowPrivilegeEscalation: false"
  echo "    - runAsNonRoot: true"
  echo "    - seccompProfile.type: RuntimeDefault"
  echo "    - capabilities.drop: [ALL]"
  echo ""
  echo "  When ready: ./run.sh 4 check"
}

do_check() {
  header "Q04 Check — Pod Security Admission"

  local score=0
  local total=5

  # 1. Namespace exists with enforce=restricted
  local label
  label=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)
  if [ "$label" = "restricted" ]; then
    pass "Namespace '$NAMESPACE' exists with enforce=restricted"
    score=$((score + 1))
  else
    fail "Namespace '$NAMESPACE' missing or enforce label not 'restricted'"
  fi

  # 2. Deployment exists
  if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    pass "Deployment '$DEPLOYMENT' exists in '$NAMESPACE'"
    score=$((score + 1))
  else
    fail "Deployment '$DEPLOYMENT' not found in '$NAMESPACE'"
  fi

  # 3. Pod is Running (not 0 replicas)
  local ready
  ready=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  if [ "$ready" -gt 0 ] 2>/dev/null; then
    pass "Deployment has $ready Running pod(s)"
    score=$((score + 1))
  else
    fail "No Running pods (readyReplicas=$ready)"
  fi

  # 4. allowPrivilegeEscalation: false AND capabilities.drop includes ALL
  local ape
  ape=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || true)
  local drop
  drop=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop}' 2>/dev/null || true)
  if [ "$ape" = "false" ] && echo "$drop" | grep -qi "ALL"; then
    pass "allowPrivilegeEscalation=false and capabilities.drop includes ALL"
    score=$((score + 1))
  else
    fail "allowPrivilegeEscalation=$ape, capabilities.drop=$drop (need false + ALL)"
  fi

  # 5. runAsNonRoot: true AND seccompProfile.type is RuntimeDefault
  local ranr
  ranr=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null || true)
  local seccomp
  seccomp=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.seccompProfile.type}' 2>/dev/null || true)
  if [ "$ranr" = "true" ] && [ "$seccomp" = "RuntimeDefault" ]; then
    pass "runAsNonRoot=true and seccompProfile.type=RuntimeDefault"
    score=$((score + 1))
  else
    fail "runAsNonRoot=$ranr, seccompProfile.type=$seccomp (need true + RuntimeDefault)"
  fi

  score_report "$score" "$total"
}

do_solution() {
  header "Q04 Solution — Pod Security Admission"

  echo "Fix the container spec in $MANIFEST with this securityContext:"
  echo ""
  cat <<'SOL'
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop:
              - ALL
SOL
  echo ""
  info "Then re-apply:"
  echo "  kubectl apply -f ~/nginx-deployment.yaml"
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
