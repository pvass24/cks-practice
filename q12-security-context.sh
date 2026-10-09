#!/bin/bash
# CKS Practice — Q12: Security Context Hardening
source "$(dirname "$0")/lib.sh"

NAMESPACE="sec-ns"
DEPLOYMENT="secdep"

do_setup() {
  header "Q12 Setup — Security Context Hardening"

  info "Creating namespace '$NAMESPACE'..."
  fresh_namespace "$NAMESPACE"

  info "Deploying '$DEPLOYMENT' with NO securityContext..."
  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secdep
  namespace: sec-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secdep
  template:
    metadata:
      labels:
        app: secdep
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
      volumes:
      - name: tmp
        emptyDir: {}
      - name: cache
        emptyDir: {}
EOF

  info "Setup complete."
  echo ""
  echo -e "  ${BOLD}TASK: Harden the deployment with a securityContext${NC}"
  echo ""
  echo "  Deployment: secdep"
  echo "  Namespace:  sec-ns"
  echo ""
  echo "  Requirements:"
  echo "    - runAsUser: 32000"
  echo "    - readOnlyRootFilesystem: true"
  echo "    - allowPrivilegeEscalation: false"
  echo "    - Keep existing volumeMounts for /tmp and /var/cache/nginx"
  echo ""
  echo "  When ready: ./run.sh 12 check"
}

do_check() {
  header "Q12 Check — Security Context Hardening"

  local score=0
  local total=4

  # 1. Deployment exists
  if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    pass "Deployment '$DEPLOYMENT' exists in '$NAMESPACE'"
    score=$((score + 1))
  else
    fail "Deployment '$DEPLOYMENT' not found in '$NAMESPACE'"
  fi

  # 2. Pod is Running
  local ready
  ready=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  if [ "$ready" -gt 0 ] 2>/dev/null; then
    pass "Deployment has $ready Running pod(s)"
    score=$((score + 1))
  else
    fail "No Running pods (readyReplicas=$ready)"
  fi

  # 3. securityContext: runAsUser=32000, readOnlyRootFilesystem=true, allowPrivilegeEscalation=false
  local rau
  rau=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}' 2>/dev/null || true)
  local rofs
  rofs=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null || true)
  local ape
  ape=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || true)

  if [ "$rau" = "32000" ] && [ "$rofs" = "true" ] && [ "$ape" = "false" ]; then
    pass "securityContext: runAsUser=32000, readOnlyRootFilesystem=true, allowPrivilegeEscalation=false"
    score=$((score + 1))
  else
    fail "securityContext: runAsUser=$rau (want 32000), readOnlyRootFilesystem=$rofs (want true), allowPrivilegeEscalation=$ape (want false)"
  fi

  # 4. volumeMounts for /tmp and /var/cache/nginx
  local mounts
  mounts=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' 2>/dev/null || true)

  local has_tmp=false
  local has_cache=false
  if echo "$mounts" | grep -q "/tmp"; then
    has_tmp=true
  fi
  if echo "$mounts" | grep -q "/var/cache/nginx"; then
    has_cache=true
  fi

  if [ "$has_tmp" = "true" ] && [ "$has_cache" = "true" ]; then
    pass "volumeMounts exist for /tmp and /var/cache/nginx"
    score=$((score + 1))
  else
    fail "volumeMounts: /tmp=$has_tmp, /var/cache/nginx=$has_cache"
  fi

  score_report "$score" "$total"
}

do_solution() {
  header "Q12 Solution — Security Context Hardening"

  echo "Update the container spec in the deployment:"
  echo ""
  cat <<'SOL'
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged
        ports:
        - containerPort: 8080
        securityContext:
          runAsUser: 32000
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
SOL

  echo ""
  info "Apply with: kubectl edit deployment secdep -n sec-ns"
  info "Or: kubectl apply -f <updated-manifest>"
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
