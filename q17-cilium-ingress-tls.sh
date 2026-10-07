#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q17 — HTTPS Ingress with Cilium"
NAMESPACE="production"
HOSTNAME="web.k8s.local"

do_setup() {
  header "$QUESTION — SETUP"

  if ! requires_kubeadm; then
    skip "Requires kubeadm cluster with Cilium — run on Killercoda"
    exit 0
  fi

  info "Checking for Cilium..."
  if ! kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -q Running; then
    info "Cilium not detected — installing..."
    # Install Cilium CLI
    if ! command -v cilium &>/dev/null; then
      CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
      CLI_ARCH=amd64
      curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
      sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
      rm -f cilium-linux-${CLI_ARCH}.tar.gz
    fi
    cilium install --set ingressController.enabled=true --set ingressController.loadbalancerMode=dedicated
    info "Waiting for Cilium to be ready..."
    cilium status --wait
    pass "Cilium installed with ingress controller"
  else
    pass "Cilium already running"
    # Ensure ingress controller is enabled
    info "Verifying Cilium ingress controller is enabled..."
  fi

  # Create namespace
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "Namespace '$NAMESPACE' ready"

  # Deploy web app
  if ! kubectl get deployment web-deployment -n "$NAMESPACE" &>/dev/null; then
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deployment
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: $NAMESPACE
spec:
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: 80
EOF
    kubectl wait --for=condition=available deployment/web-deployment \
        -n "$NAMESPACE" --timeout=120s
    pass "Web app deployed"
  else
    pass "Web app already exists"
  fi

  # Generate TLS cert + create secret
  kubectl delete secret web-tls -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  local TLS_DIR="/tmp/cks-q17-tls"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$TLS_DIR/web.key" \
      -out "$TLS_DIR/web.crt" \
      -subj "/CN=$HOSTNAME" 2>/dev/null
  kubectl -n "$NAMESPACE" create secret tls web-tls \
      --cert="$TLS_DIR/web.crt" \
      --key="$TLS_DIR/web.key"
  pass "TLS secret 'web-tls' created"

  # Delete any existing ingress
  kubectl delete ingress web-ingress -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  echo ""
  info "Setup complete."
  echo ""
  echo -e "  ${BOLD}TASK: Create an Ingress in the '${NAMESPACE}' namespace${NC}"
  echo ""
  echo "  Name:       web-ingress"
  echo "  Namespace:  ${NAMESPACE}"
  echo "  Hostname:   ${HOSTNAME}"
  echo "  Backend:    web-service on port 80 (all paths)"
  echo "  TLS:        terminate using secret 'web-tls'"
  echo "  Redirect:   force HTTP → HTTPS"
  echo "  Controller: Cilium"
  echo ""
  echo "  When ready: ./run.sh 17 check"
}

do_check() {
  header "$QUESTION — CHECK"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires kubeadm cluster with Cilium — run on Killercoda"
    exit 0
  fi

  local score=0
  local total=5

  echo ""
  echo -e "${BOLD}  Ingress: web-ingress in $NAMESPACE${NC}"
  echo "  ─────────────────────────────────────────"

  # Check 1: Ingress exists
  if kubectl get ingress web-ingress -n "$NAMESPACE" &>/dev/null; then
    pass "Ingress 'web-ingress' exists"
    score=$((score + 1))
  else
    fail "Ingress 'web-ingress' not found in '$NAMESPACE'"
    echo -e "        ${CYAN}Create it with: kubectl apply -f ingress.yaml${NC}"
    score_report "$score" "$total"
    return
  fi

  # Check 2: IngressClass is cilium
  local ingclass=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
  if [ "$ingclass" = "cilium" ]; then
    pass "ingressClassName = cilium"
    score=$((score + 1))
  else
    fail "ingressClassName = '$ingclass' (should be 'cilium')"
    echo -e "        ${YELLOW}Why: The question asks for Cilium, not nginx. Cilium's ingress${NC}"
    echo -e "        ${YELLOW}controller uses its own class name.${NC}"
    echo -e "        ${CYAN}Fix: spec.ingressClassName: cilium${NC}"
  fi

  # Check 3: TLS configured with correct secret
  local tlsSecret=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
  local tlsHost=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o jsonpath='{.spec.tls[0].hosts[0]}' 2>/dev/null)
  if [ "$tlsSecret" = "web-tls" ] && [ "$tlsHost" = "$HOSTNAME" ]; then
    pass "TLS: secret=web-tls, host=$HOSTNAME"
    score=$((score + 1))
  else
    fail "TLS config: secret='$tlsSecret' host='$tlsHost' (expected web-tls / $HOSTNAME)"
    echo -e "        ${CYAN}Fix: spec.tls[].secretName: web-tls, hosts: [$HOSTNAME]${NC}"
  fi

  # Check 4: Host rule and backend
  local ruleHost=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
  local backend=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' 2>/dev/null)
  if [ "$ruleHost" = "$HOSTNAME" ] && [ "$backend" = "web-service" ]; then
    pass "Rule: $HOSTNAME → web-service"
    score=$((score + 1))
  else
    fail "Rule: host='$ruleHost' backend='$backend' (expected $HOSTNAME → web-service)"
  fi

  # Check 5: HTTPS redirect — Cilium uses its own annotation
  local annotations=$(kubectl get ingress web-ingress -n "$NAMESPACE" -o json 2>/dev/null)
  local has_redirect=false

  # Check for Cilium force-https annotation
  if echo "$annotations" | grep -q 'ingress.cilium.io/force-https'; then
    has_redirect=true
  fi
  # Also accept the standard ssl-redirect annotation
  if echo "$annotations" | grep -q 'ingress.cilium.io/ssl-redirect'; then
    has_redirect=true
  fi

  if [ "$has_redirect" = "true" ]; then
    pass "HTTPS redirect annotation present"
    score=$((score + 1))
  else
    fail "No HTTPS redirect annotation found"
    echo -e "        ${YELLOW}Why: Without the redirect, HTTP requests pass through unencrypted.${NC}"
    echo -e "        ${YELLOW}Cilium uses its own annotation — not the nginx one.${NC}"
    echo -e "        ${CYAN}Fix: Add annotation: ingress.cilium.io/force-https: \"enabled\"${NC}"
    echo -e "        ${CYAN}  or: ingress.cilium.io/ssl-redirect: \"enabled\"${NC}"
  fi

  echo ""

  score_report "$score" "$total"

  if [ "$score" -eq "$total" ]; then
    echo ""
    echo -e "  ${GREEN}Full pass. Cilium ingress is the new exam standard — nginx is fading.${NC}"
    echo -e "  ${GREEN}Remember: ingressClassName: cilium + ingress.cilium.io/ annotations.${NC}"
  fi
}

do_hint() {
  local level="${2:-1}"
  header "$QUESTION — HINT $level"

  case "$level" in
    1)
      cat <<'HINT'
SPEED: Check what ingress classes are available:

  kubectl get ingressclass

Look for 'cilium' — that's your ingressClassName.

The Ingress spec is identical to nginx — only the class
and annotations change.
HINT
      ;;
    2)
      cat <<'HINT'
SPEED: Discover Cilium annotations:

  kubectl explain ingress.metadata.annotations

Or check the docs: search "cilium ingress" on docs.cilium.io

The key annotation for HTTPS redirect:

  ingress.cilium.io/force-https: "enabled"

NOT the nginx annotation (nginx.ingress.kubernetes.io/...)
HINT
      ;;
    3)
      cat <<'HINT'
The full Ingress structure:

  ingressClassName: cilium          ← not nginx
  annotations:
    ingress.cilium.io/force-https: "enabled"
  tls:
  - hosts: [web.k8s.local]
    secretName: web-tls
  rules:
  - host: web.k8s.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
HINT
      ;;
    *)
      echo "No more hints. Run: ./run.sh 17 solution"
      ;;
  esac
  echo ""
  echo "Next hint: ./run.sh 17 hint $((level + 1))"
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<'SOLUTION'

  ┌─────────────────────────────────────────────────┐
  │  EXAM SPEED RUN — Total time target: 5 minutes  │
  └─────────────────────────────────────────────────┘

  STEP 1: Check ingress class (10 seconds)
  ─────────────────────────────────────────
  kubectl get ingressclass

  Look for 'cilium'. That's your ingressClassName.


  STEP 2: Check existing resources (20 seconds)
  ──────────────────────────────────────────────
  kubectl get svc,secret -n production

  Confirm web-service exists and web-tls secret is there.


  STEP 3: Write the Ingress (3 minutes)
  ──────────────────────────────────────

  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: web-ingress
    namespace: production
    annotations:
      ingress.cilium.io/force-https: "enabled"
  spec:
    ingressClassName: cilium
    tls:
    - hosts:
      - web.k8s.local
      secretName: web-tls
    rules:
    - host: web.k8s.local
      http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: web-service
              port:
                number: 80

  Apply: kubectl apply -f ingress.yaml


  STEP 4: Verify (30 seconds)
  ────────────────────────────
  kubectl get ingress -n production
  ./run.sh 17 check


  KEY DIFFERENCES FROM NGINX:
  ───────────────────────────
  • ingressClassName: cilium  (not nginx)
  • ingress.cilium.io/force-https: "enabled"
    (not nginx.ingress.kubernetes.io/force-ssl-redirect)

  Everything else — tls block, rules, paths, backend — is identical.
  The Ingress API is the same regardless of controller.


  COMMON MISTAKES:
  ────────────────
  ✗ Using nginx annotation instead of cilium annotation
    → ingress.cilium.io/force-https, NOT nginx.ingress.kubernetes.io/...

  ✗ Using ingressClassName: nginx
    → Must match the actual IngressClass in the cluster

  ✗ Forgetting to check which IngressClass exists
    → Always run: kubectl get ingressclass first

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
