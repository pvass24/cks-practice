#!/bin/bash
source "$(dirname "$0")/lib.sh"

MODE="${1:-check}"

case "$MODE" in

# ─────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────
setup)
  header "Q02 — ImagePolicyWebhook Setup"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  info "Creating /etc/kubernetes/webhook/ directory..."
  sudo mkdir -p /etc/kubernetes/webhook

  # admission-config.yml — top-level AdmissionConfiguration
  # admission-config.yml — AdmissionConfiguration
  # User must: change defaultAllow to false, change allowTTL to 100
  info "Writing admission-config.yml (defaultAllow: true, allowTTL: 50 — fix both)..."
  sudo tee /etc/kubernetes/webhook/admission-config.yml > /dev/null <<'ADMEOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/webhook/kube-config.yml
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: true
ADMEOF

  # kube-config.yml — kubeconfig pointing to the webhook server
  # User must: fill in the server URL
  info "Writing kube-config.yml (server: empty — fill in webhook URL)..."
  sudo tee /etc/kubernetes/webhook/kube-config.yml > /dev/null <<'KCEOF'
apiVersion: v1
kind: Config
clusters:
  - name: image-checker
    cluster:
      certificate-authority: /etc/kubernetes/pki/ca.crt
      server: ""
contexts:
  - name: image-checker
    context:
      cluster: image-checker
      user: api-server
current-context: image-checker
preferences: {}
users:
  - name: api-server
    user:
      client-certificate: /etc/kubernetes/pki/apiserver.crt
      client-key: /etc/kubernetes/pki/apiserver.key
KCEOF

  echo ""
  pass "Setup complete. Config files created."
  echo ""
  echo -e "  ${BOLD}Context:${NC}"
  echo "  A team needs to enforce image validation using an external webhook."
  echo "  The webhook config files have been partially created but contain errors."
  echo ""
  echo -e "  ${BOLD}Task:${NC}"
  echo "  Enable and configure the ImagePolicyWebhook admission controller."
  echo ""
  echo "  Fix the following files:"
  echo ""
  echo -e "    ${BOLD}1. /etc/kubernetes/webhook/admission-config.yml${NC}"
  echo "       - Set defaultAllow to false (fail-closed)"
  echo "       - Set allowTTL to 100"
  echo ""
  echo -e "    ${BOLD}2. /etc/kubernetes/webhook/kube-config.yml${NC}"
  echo "       - Set the webhook server URL to: https://image-checker.example.com:1323/image_policy"
  echo ""
  echo -e "    ${BOLD}3. /etc/kubernetes/manifests/kube-apiserver.yaml${NC}"
  echo "       - Add ImagePolicyWebhook to --enable-admission-plugins"
  echo "       - Add --admission-control-config-file=/etc/kubernetes/webhook/admission-config.yml"
  echo "       - Add volume + volumeMount for /etc/kubernetes/webhook"
  echo ""
  echo -e "  ${CYAN}Recovery: sudo cp $PRISTINE_DIR/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml${NC}"
  echo ""
  echo "  When ready: ./run.sh 2 check"
  echo ""
  timer_start
  ;;

# ─────────────────────────────────────────
# CHECK
# ─────────────────────────────────────────
check)
  header "Q02 — ImagePolicyWebhook Check"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  SCORE=0

  # Check 1: defaultAllow is false in admission-config.yml
  if sudo grep -q 'defaultAllow: false' /etc/kubernetes/webhook/admission-config.yml 2>/dev/null; then
    pass "defaultAllow is set to false"
    SCORE=$((SCORE + 1))
  else
    fail "defaultAllow is still true (must be false)"
    echo -e "        ${YELLOW}Why: fail-closed means if the webhook is unreachable, ALL images"
    echo -e "        are rejected. This prevents unscanned images from running.${NC}"
  fi

  # Check 2: allowTTL is 100
  if sudo grep -q 'allowTTL: 100' /etc/kubernetes/webhook/admission-config.yml 2>/dev/null; then
    pass "allowTTL is set to 100"
    SCORE=$((SCORE + 1))
  else
    local current_ttl=$(sudo grep 'allowTTL' /etc/kubernetes/webhook/admission-config.yml 2>/dev/null | awk '{print $2}')
    fail "allowTTL = ${current_ttl:-missing} (should be 100)"
    echo -e "        ${YELLOW}Why: allowTTL controls how long (seconds) an allowed image is cached"
    echo -e "        before re-checking with the webhook.${NC}"
  fi

  # Check 2: kube-config.yml has a non-empty server URL
  SERVER_URL=$(sudo grep -A2 'cluster:' /etc/kubernetes/webhook/kube-config.yml 2>/dev/null | grep 'server:' | head -1 | awk '{print $2}' | tr -d '"')
  if [ -n "$SERVER_URL" ] && [ "$SERVER_URL" != '""' ]; then
    pass "kube-config.yml server URL is set: $SERVER_URL"
    SCORE=$((SCORE + 1))
  else
    fail "kube-config.yml server URL is empty"
  fi

  # Check 3: kube-apiserver has ImagePolicyWebhook in admission plugins
  APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
  if sudo grep -q 'ImagePolicyWebhook' "$APISERVER_MANIFEST" 2>/dev/null; then
    PLUGINS_LINE=$(sudo grep 'enable-admission-plugins' "$APISERVER_MANIFEST" | head -1)
    if echo "$PLUGINS_LINE" | grep -q 'ImagePolicyWebhook'; then
      pass "kube-apiserver has --enable-admission-plugins containing ImagePolicyWebhook"
      SCORE=$((SCORE + 1))
    else
      fail "ImagePolicyWebhook found in manifest but not in --enable-admission-plugins flag"
    fi
  else
    fail "kube-apiserver manifest does not contain ImagePolicyWebhook"
  fi

  # Check 4: admission-control-config-file flag points to the config
  if sudo grep -q 'admission-control-config-file=/etc/kubernetes/webhook/admission-config.yml' "$APISERVER_MANIFEST" 2>/dev/null; then
    pass "--admission-control-config-file is set correctly"
    SCORE=$((SCORE + 1))
  else
    fail "--admission-control-config-file not set or wrong path"
  fi

  # Check 5: volume mount for webhook-config exists
  if sudo grep -q 'webhook-config\|/etc/kubernetes/webhook' "$APISERVER_MANIFEST" 2>/dev/null; then
    pass "Volume mount for /etc/kubernetes/webhook exists"
    SCORE=$((SCORE + 1))
  else
    fail "Missing volume/volumeMount for /etc/kubernetes/webhook in API server manifest"
  fi

  # Check 6: Test pod gets denied by the webhook
  if kubectl get nodes &>/dev/null; then
    test_output=$(kubectl run webhook-test --image=nginx --restart=Never 2>&1 || true)
    kubectl delete pod webhook-test --ignore-not-found &>/dev/null 2>&1 || true
    if echo "$test_output" | grep -qi "denied\|forbidden\|rejected\|error"; then
      pass "Test pod was DENIED by ImagePolicyWebhook"
      SCORE=$((SCORE + 1))
    else
      fail "Test pod was NOT denied — webhook may not be enforcing"
      echo -e "        ${YELLOW}Why: With defaultAllow: false, the webhook should reject pods"
      echo -e "        when the webhook server denies or is unreachable.${NC}"
    fi
  else
    fail "API server is down — cannot test pod denial"
    echo -e "        ${YELLOW}Did you set the server URL BEFORE enabling the plugin?${NC}"
    echo -e "        ${CYAN}Fix order: URL first → defaultAllow false → enable plugin${NC}"
  fi

  score_report $SCORE 7
  ;;

# ─────────────────────────────────────────
# SOLUTION
# ─────────────────────────────────────────
solution)
  header "Q02 — ImagePolicyWebhook Solution"

  echo -e "${CYAN}Three changes needed:${NC}"
  echo ""
  echo -e "${BOLD}1. Set defaultAllow to false${NC}"
  echo "   Edit /etc/kubernetes/webhook/admission-config.yml:"
  echo "     Change:  defaultAllow: true"
  echo "     To:      defaultAllow: false"
  echo ""
  echo -e "${BOLD}2. Set webhook server URL${NC}"
  echo "   Edit /etc/kubernetes/webhook/kube-config.yml:"
  echo '     Change:  server: ""'
  echo "     To:      server: https://image-policy-webhook.kube-system:1323/image_policy"
  echo ""
  echo -e "${BOLD}3. Enable ImagePolicyWebhook admission plugin${NC}"
  echo "   Edit /etc/kubernetes/manifests/kube-apiserver.yaml:"
  echo "     Add ImagePolicyWebhook to --enable-admission-plugins:"
  echo "     --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook"
  echo ""
  echo "   Also ensure the admission-control-config-file flag points to:"
  echo "     --admission-control-config-file=/etc/kubernetes/webhook/admission-config.yml"
  echo ""
  echo "   Wait for kube-apiserver to restart (~30s), then verify:"
  echo "     kubectl -n kube-system get pod kube-apiserver-* -o yaml | grep ImagePolicyWebhook"
  ;;

*)
  echo "Usage: $0 {setup|check|solution}"
  exit 1
  ;;
esac
