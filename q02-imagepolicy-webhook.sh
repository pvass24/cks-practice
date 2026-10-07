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

  # Back up kube-apiserver manifest
  APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
  info "Backing up kube-apiserver manifest to /root/kube-apiserver.yaml.bak..."
  sudo cp "$APISERVER_MANIFEST" /root/kube-apiserver.yaml.bak

  # Only add volume mount — user adds the flags themselves
  info "Adding webhook volume mount to kube-apiserver..."
  if ! sudo grep -q "webhook-config" "$APISERVER_MANIFEST" 2>/dev/null; then
    sudo sed -i '/volumeMounts:/a\    - name: webhook-config\n      mountPath: /etc/kubernetes/webhook\n      readOnly: true' "$APISERVER_MANIFEST"
    sudo sed -i '/volumes:/a\  - name: webhook-config\n    hostPath:\n      path: /etc/kubernetes/webhook\n      type: DirectoryOrCreate' "$APISERVER_MANIFEST"
  fi

  # Wait for API server to come back after volume mount change
  info "Waiting for API server to restart..."
  sleep 10
  for i in $(seq 1 30); do
    if kubectl get nodes &>/dev/null; then
      pass "API server is healthy"
      break
    fi
    if [ "$i" -eq 30 ]; then
      # Restore backup if API server won't come back
      info "Restoring API server backup..."
      sudo cp /root/kube-apiserver.yaml.bak "$APISERVER_MANIFEST"
      sleep 15
      if kubectl get nodes &>/dev/null; then
        pass "API server recovered from backup"
      else
        fail "API server still down — run: sudo cp /root/kube-apiserver.yaml.bak $APISERVER_MANIFEST"
        exit 1
      fi
    fi
    echo -n "."
    sleep 3
  done

  info "Deploying a simple webhook server pod..."
  kubectl apply -f - <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: image-policy-webhook
  namespace: kube-system
  labels:
    app: image-policy-webhook
spec:
  containers:
    - name: webhook
      image: registry.k8s.io/pause:3.9
      ports:
        - containerPort: 1323
PODEOF

  echo ""
  pass "Setup complete. Environment is ready."
  echo ""
  echo -e "  ${BOLD}TASK: Configure ImagePolicyWebhook admission controller${NC}"
  echo ""
  echo "  The webhook is reachable at:"
  echo "    https://image-policy-webhook.default"
  echo ""
  echo "  Two config files + one manifest to edit:"
  echo ""
  echo "    1. /etc/kubernetes/webhook/admission-config.yml"
  echo "       → set defaultAllow to false (fail-closed)"
  echo "       → set allowTTL to 100"
  echo ""
  echo "    2. /etc/kubernetes/webhook/kube-config.yml"
  echo "       → set the webhook server URL"
  echo ""
  echo "    3. /etc/kubernetes/manifests/kube-apiserver.yaml"
  echo "       → add ImagePolicyWebhook to --enable-admission-plugins"
  echo "       → add --admission-control-config-file pointing to admission-config.yml"
  echo ""
  echo "  ⚠  IMPORTANT: Set the server URL BEFORE enabling the plugin."
  echo "     Wrong order = API server crash (fail-closed with no endpoint)."
  echo "     Backup is at: /root/kube-apiserver.yaml.bak"
  echo ""
  echo "  Verify: Deploy a test pod and confirm it gets DENIED:"
  echo "    kubectl run test --image=nginx"
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

  # Check 5: Test pod gets denied by the webhook
  if kubectl get nodes &>/dev/null; then
    local test_output=$(kubectl run webhook-test --image=nginx --restart=Never 2>&1 || true)
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

  score_report $SCORE 5
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
