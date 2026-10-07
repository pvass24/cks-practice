#!/bin/bash
# CKS Practice — Q14: TLS Secret
source "$(dirname "$0")/lib.sh"

NAMESPACE="bright-banyan"
SECRET_NAME="bright-banyan"
DEPLOYMENT="bright-banyan"
TLS_DIR="$HOME/tls"

do_setup() {
  header "Q14 Setup — TLS Secret"

  info "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null

  info "Generating TLS cert and key at $TLS_DIR/..."
  mkdir -p "$TLS_DIR"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$TLS_DIR/banyan.key" \
    -out "$TLS_DIR/banyan.crt" \
    -subj "/CN=bright-banyan/O=cks-practice" \
    2>/dev/null

  info "Removing any existing secret '$SECRET_NAME'..."
  kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true

  info "Creating deployment '$DEPLOYMENT' that mounts secret '$SECRET_NAME'..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT}
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/tls
          readOnly: true
      volumes:
      - name: tls-certs
        secret:
          secretName: ${SECRET_NAME}
EOF

  echo ""
  info "Setup complete. The pod is pending because the TLS secret does not exist yet."
  info ""
  info "Create a TLS secret named '$SECRET_NAME' in namespace '$NAMESPACE'"
  info "using the cert and key at:"
  info "  $TLS_DIR/banyan.crt"
  info "  $TLS_DIR/banyan.key"
  info ""
  info "When ready, run: $0 check"
}

do_check() {
  header "Q14 Check — TLS Secret"

  local score=0
  local total=4

  # 1. Namespace exists
  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    pass "Namespace '$NAMESPACE' exists"
    ((score++))
  else
    fail "Namespace '$NAMESPACE' not found"
  fi

  # 2. Secret exists
  if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    pass "Secret '$SECRET_NAME' exists in '$NAMESPACE'"
    ((score++))
  else
    fail "Secret '$SECRET_NAME' not found in '$NAMESPACE'"
  fi

  # 3. Secret type is kubernetes.io/tls
  local stype
  stype=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null || true)
  if [ "$stype" = "kubernetes.io/tls" ]; then
    pass "Secret type is kubernetes.io/tls"
    ((score++))
  else
    fail "Secret type is '$stype' (expected kubernetes.io/tls)"
  fi

  # 4. Deployment has at least 1 Running pod
  local ready
  ready=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  if [ "$ready" -gt 0 ] 2>/dev/null; then
    pass "Deployment '$DEPLOYMENT' has $ready Running pod(s)"
    ((score++))
  else
    fail "Deployment '$DEPLOYMENT' has no Running pods (readyReplicas=$ready)"
    info "Hint: The pod may need a moment after the secret is created. Wait and re-check."
  fi

  score_report "$score" "$total"
}

do_solution() {
  header "Q14 Solution — TLS Secret"

  echo "Create the TLS secret with:"
  echo ""
  cat <<SOL
kubectl create secret tls ${SECRET_NAME} \\
  --cert=${TLS_DIR}/banyan.crt \\
  --key=${TLS_DIR}/banyan.key \\
  -n ${NAMESPACE}
SOL

  echo ""
  info "The pod should start automatically once the secret exists."
  info "If it doesn't, try deleting the pod to force a restart:"
  echo "  kubectl delete pod -l app=${DEPLOYMENT} -n ${NAMESPACE}"
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
