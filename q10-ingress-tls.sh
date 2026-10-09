#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q10 — Ingress with HTTPS Setup"

  # Install ingress-nginx controller
  info "Checking for ingress-nginx controller..."
  if ! kubectl get ns ingress-nginx &>/dev/null; then
    info "Installing ingress-nginx controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml
    info "Waiting for ingress-nginx controller to be ready..."
    kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s 2>/dev/null || true
  else
    info "ingress-nginx already installed."
  fi

  # Create production namespace
  info "Creating namespace production..."
  fresh_namespace "production"

  # Deploy web app and service
  info "Deploying web application..."
  kubectl apply -n production -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.25
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF

  kubectl -n production rollout status deployment/web --timeout=60s 2>/dev/null || true

  # Generate self-signed TLS cert
  info "Generating TLS certificate for web.k8s.local..."
  CERT_DIR=$(mktemp -d)
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/tls.key" \
    -out "$CERT_DIR/tls.crt" \
    -subj "/CN=web.k8s.local/O=CKS Practice" \
    2>/dev/null

  # Create TLS secret
  info "Creating TLS secret web-ingress-tls..."
  kubectl -n production create secret tls web-ingress-tls \
    --cert="$CERT_DIR/tls.crt" \
    --key="$CERT_DIR/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -

  rm -rf "$CERT_DIR"

  # Add /etc/hosts entry if not present
  if ! grep -q 'web.k8s.local' /etc/hosts 2>/dev/null; then
    info "Adding /etc/hosts entry for web.k8s.local..."
    echo "127.0.0.1 web.k8s.local" | sudo tee -a /etc/hosts > /dev/null
  fi

  echo ""
  pass "Setup complete."
  echo ""
  info "TASK: Create an Ingress resource for HTTPS access."
  info "  1. Create Ingress 'web-ingress' in namespace 'production'"
  info "  2. Configure TLS with secretName 'web-ingress-tls'"
  info "  3. Set host to 'web.k8s.local'"
  info "  4. Add annotation for ssl-redirect or force-ssl-redirect"
  info "  5. Route traffic to service 'web' on port 80"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q10 — Ingress with HTTPS Check"

  SCORE=0

  # Check 1: Ingress web-ingress exists in production
  if kubectl get ingress web-ingress -n production &>/dev/null; then
    pass "Ingress 'web-ingress' exists in namespace 'production'"
    SCORE=$((SCORE + 1))
  else
    fail "Ingress 'web-ingress' not found in namespace 'production'"
  fi

  # Check 2: Ingress has TLS configured with secretName web-ingress-tls
  TLS_SECRET=$(kubectl get ingress web-ingress -n production -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
  if [ "$TLS_SECRET" = "web-ingress-tls" ]; then
    pass "Ingress has TLS configured with secretName 'web-ingress-tls'"
    SCORE=$((SCORE + 1))
  else
    fail "Ingress TLS secretName is '$TLS_SECRET' (expected 'web-ingress-tls')"
  fi

  # Check 3: Ingress has host web.k8s.local
  HOSTS=$(kubectl get ingress web-ingress -n production -o jsonpath='{.spec.rules[*].host}' 2>/dev/null)
  TLS_HOSTS=$(kubectl get ingress web-ingress -n production -o jsonpath='{.spec.tls[0].hosts[*]}' 2>/dev/null)
  if echo "$HOSTS" | grep -q 'web.k8s.local'; then
    pass "Ingress has host 'web.k8s.local'"
    SCORE=$((SCORE + 1))
  else
    fail "Ingress host is '$HOSTS' (expected 'web.k8s.local')"
  fi

  # Check 4: Ingress has ssl-redirect or force-ssl-redirect annotation
  ANNOTATIONS=$(kubectl get ingress web-ingress -n production -o json 2>/dev/null | grep -E '(ssl-redirect|force-ssl-redirect)' || true)
  if [ -n "$ANNOTATIONS" ]; then
    pass "Ingress has SSL redirect annotation"
    SCORE=$((SCORE + 1))
  else
    fail "Ingress missing ssl-redirect or force-ssl-redirect annotation"
  fi

  # Bonus: curl test on kubeadm (informational only)
  if [ "$ENV_TYPE" = "kubeadm" ]; then
    info "Testing HTTPS endpoint..."
    CURL_RESULT=$(curl -sk https://web.k8s.local 2>/dev/null | head -5)
    if [ -n "$CURL_RESULT" ]; then
      info "HTTPS response received from web.k8s.local"
    else
      info "No HTTPS response — ingress controller may need time to sync"
    fi
  else
    info "Skipping curl test on kind (ingress controller may not have external IP)"
  fi

  score_report $SCORE 4
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q10 — Ingress with HTTPS Solution"

  echo -e "${BOLD}Create the Ingress YAML:${NC}"
  cat <<'YAMLEOF'

   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
     namespace: production
     annotations:
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
       nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
   spec:
     ingressClassName: nginx
     tls:
       - hosts:
           - web.k8s.local
         secretName: web-ingress-tls
     rules:
       - host: web.k8s.local
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: web
                   port:
                     number: 80

YAMLEOF

  echo -e "${BOLD}Apply:${NC}"
  echo "   kubectl apply -f ingress.yaml"
  echo ""
  echo -e "${BOLD}Verification:${NC}"
  echo "   kubectl -n production get ingress web-ingress"
  echo "   kubectl -n production describe ingress web-ingress"
  echo "   curl -sk https://web.k8s.local    # Should return nginx welcome page"
  echo "   curl -sI http://web.k8s.local     # Should get 308 redirect to HTTPS"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
