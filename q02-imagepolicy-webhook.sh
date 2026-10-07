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

  # Mount webhook volume in kube-apiserver static pod
  info "Adding webhook volume mount to kube-apiserver..."
  APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

  # Check if volume mount already exists
  if ! sudo grep -q "webhook" "$APISERVER_MANIFEST" 2>/dev/null; then
    # Add volume mount under containers[0].volumeMounts
    sudo sed -i '/volumeMounts:/a\    - name: webhook-config\n      mountPath: /etc/kubernetes/webhook\n      readOnly: true' "$APISERVER_MANIFEST"
    # Add volume under volumes
    sudo sed -i '/volumes:/a\  - name: webhook-config\n    hostPath:\n      path: /etc/kubernetes/webhook\n      type: DirectoryOrCreate' "$APISERVER_MANIFEST"
  fi

  # Add admission-control-config-file flag if not present
  if ! sudo grep -q "admission-control-config-file" "$APISERVER_MANIFEST" 2>/dev/null; then
    sudo sed -i '/--enable-admission-plugins/a\    - --admission-control-config-file=/etc/kubernetes/webhook/admission-config.yml' "$APISERVER_MANIFEST"
  fi

  # Wait for API server to come back after manifest change
  info "Waiting for API server to restart..."
  sleep 10
  for i in $(seq 1 30); do
    if kubectl get nodes &>/dev/null; then
      pass "API server is healthy"
      break
    fi
    if [ "$i" -eq 30 ]; then
      fail "API server did not come back — check: crictl logs \$(crictl ps -a | grep apiserver | head -1 | awk '{print \$1}')"
      exit 1
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

  score_report $SCORE 4
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
