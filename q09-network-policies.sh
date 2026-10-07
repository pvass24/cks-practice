#!/bin/bash
# CKS Practice — Q09: NetworkPolicy
source "$(dirname "$0")/lib.sh"

NS_PROD="production"
NS_DB="database"

do_setup() {
  header "Q09 Setup — NetworkPolicy"

  info "Creating namespace '$NS_PROD' with label env=production..."
  kubectl create namespace "$NS_PROD" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null
  kubectl label namespace "$NS_PROD" env=production --overwrite

  info "Creating namespace '$NS_DB' with label env=database..."
  kubectl create namespace "$NS_DB" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null
  kubectl label namespace "$NS_DB" env=database --overwrite

  info "Cleaning any existing NetworkPolicies..."
  kubectl delete networkpolicy --all -n "$NS_PROD" 2>/dev/null || true
  kubectl delete networkpolicy --all -n "$NS_DB" 2>/dev/null || true

  info "Setup complete."
  echo ""
  echo -e "  ${BOLD}TASK: Create two NetworkPolicies to control ingress traffic${NC}"
  echo ""
  echo "  1. Name:       deny-policy"
  echo "     Namespace:  production"
  echo "     Behavior:   Select ALL pods, deny ALL ingress traffic"
  echo ""
  echo "  2. Name:       allow-from-production"
  echo "     Namespace:  database"
  echo "     Behavior:   Allow ingress from namespaces with label env=production"
  echo ""
  echo "  When ready: ./run.sh 9 check"
}

do_check() {
  header "Q09 Check — NetworkPolicy"

  local score=0
  local total=6

  # 1. Namespace production has label env=production
  local label_prod
  label_prod=$(kubectl get namespace "$NS_PROD" -o jsonpath='{.metadata.labels.env}' 2>/dev/null || true)
  if [ "$label_prod" = "production" ]; then
    pass "Namespace '$NS_PROD' has label env=production"
    score=$((score + 1))
  else
    fail "Namespace '$NS_PROD' missing or label env != production"
  fi

  # 2. Namespace database has label env=database
  local label_db
  label_db=$(kubectl get namespace "$NS_DB" -o jsonpath='{.metadata.labels.env}' 2>/dev/null || true)
  if [ "$label_db" = "database" ]; then
    pass "Namespace '$NS_DB' has label env=database"
    score=$((score + 1))
  else
    fail "Namespace '$NS_DB' missing or label env != database"
  fi

  # 3. NetworkPolicy deny-policy exists in production
  if kubectl get networkpolicy deny-policy -n "$NS_PROD" &>/dev/null; then
    pass "NetworkPolicy 'deny-policy' exists in '$NS_PROD'"
    score=$((score + 1))
  else
    fail "NetworkPolicy 'deny-policy' not found in '$NS_PROD'"
  fi

  # 4. deny-policy selects all pods and denies all ingress
  local deny_json
  deny_json=$(kubectl get networkpolicy deny-policy -n "$NS_PROD" -o json 2>/dev/null || echo "{}")

  local pod_selector
  pod_selector=$(echo "$deny_json" | jq -r '.spec.podSelector // empty')
  local policy_types
  policy_types=$(echo "$deny_json" | jq -r '.spec.policyTypes[]? // empty' 2>/dev/null)
  local ingress_rules
  ingress_rules=$(echo "$deny_json" | jq -r '.spec.ingress // empty')

  local ps_empty=false
  if echo "$deny_json" | jq -e '.spec.podSelector == {} or .spec.podSelector.matchLabels == null' &>/dev/null; then
    ps_empty=true
  fi

  local has_ingress_type=false
  if echo "$policy_types" | grep -q "Ingress"; then
    has_ingress_type=true
  fi

  local no_ingress_rules=false
  if [ -z "$ingress_rules" ] || [ "$ingress_rules" = "null" ]; then
    no_ingress_rules=true
  fi

  if [ "$ps_empty" = "true" ] && [ "$has_ingress_type" = "true" ] && [ "$no_ingress_rules" = "true" ]; then
    pass "deny-policy: selects all pods, denies all ingress"
    score=$((score + 1))
  else
    fail "deny-policy: podSelector empty=$ps_empty, Ingress type=$has_ingress_type, no ingress rules=$no_ingress_rules"
  fi

  # 5. NetworkPolicy allow-from-production exists in database
  if kubectl get networkpolicy allow-from-production -n "$NS_DB" &>/dev/null; then
    pass "NetworkPolicy 'allow-from-production' exists in '$NS_DB'"
    score=$((score + 1))
  else
    fail "NetworkPolicy 'allow-from-production' not found in '$NS_DB'"
  fi

  # 6. allow-from-production allows ingress from namespaceSelector env=production
  local allow_json
  allow_json=$(kubectl get networkpolicy allow-from-production -n "$NS_DB" -o json 2>/dev/null || echo "{}")

  local ns_match
  ns_match=$(echo "$allow_json" | jq -r '.spec.ingress[0].from[0].namespaceSelector.matchLabels.env // empty' 2>/dev/null)
  if [ "$ns_match" = "production" ]; then
    pass "allow-from-production: allows ingress from namespaceSelector env=production"
    score=$((score + 1))
  else
    fail "allow-from-production: namespaceSelector.matchLabels.env='$ns_match' (expected 'production')"
  fi

  score_report "$score" "$total"
}

do_solution() {
  header "Q09 Solution — NetworkPolicy"

  echo "1. deny-policy in '$NS_PROD' (deny all ingress):"
  echo ""
  cat <<'SOL'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-policy
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
SOL

  echo ""
  echo "2. allow-from-production in '$NS_DB':"
  echo ""
  cat <<'SOL'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-production
  namespace: database
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          env: production
SOL

  echo ""
  info "Apply both with: kubectl apply -f <file>"
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
