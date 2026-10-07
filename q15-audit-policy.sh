#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q15 — Audit Logging"
POLICY_DIR="/etc/kubernetes/logpolicy"
POLICY_FILE="$POLICY_DIR/policy.yaml"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUDIT_LOG_DIR="/var/log/kubernetes/audit"

do_setup() {
  header "$QUESTION — SETUP"

  if ! requires_kubeadm; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  info "Creating baseline audit policy directory and weak policy..."

  # Create policy directory
  mkdir -p "$POLICY_DIR"
  mkdir -p "$AUDIT_LOG_DIR"

  # Create baseline policy with only None rules (user must replace)
  cat > "$POLICY_FILE" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    resources:
    - group: ""
      resources: ["events"]
  - level: None
    resources:
    - group: ""
      resources: ["endpoints", "services", "services/status"]
EOF

  info "Baseline policy written to $POLICY_FILE"

  # Clear any existing audit logs
  rm -f "$AUDIT_LOG_DIR"/*.log 2>/dev/null || true

  # Add volume and volumeMount to kube-apiserver (but NOT the flags)
  if [ -f "$APISERVER_MANIFEST" ]; then
    cp "$APISERVER_MANIFEST" "${APISERVER_MANIFEST}.bak"

    # Check if volumes already have the audit entries
    if ! grep -q 'name: audit-policy' "$APISERVER_MANIFEST"; then
      # Add volumeMount for audit policy and logs
      python3 -c "
import yaml, sys

with open('$APISERVER_MANIFEST') as f:
    manifest = yaml.safe_load(f)

containers = manifest['spec']['containers']
volumes = manifest['spec'].get('volumes', [])
vol_mounts = containers[0].get('volumeMounts', [])

# Add audit policy volume + mount if not present
policy_vol = {'name': 'audit-policy', 'hostPath': {'path': '$POLICY_DIR', 'type': 'DirectoryOrCreate'}}
policy_mount = {'name': 'audit-policy', 'mountPath': '$POLICY_DIR', 'readOnly': True}

log_vol = {'name': 'audit-log', 'hostPath': {'path': '$AUDIT_LOG_DIR', 'type': 'DirectoryOrCreate'}}
log_mount = {'name': 'audit-log', 'mountPath': '$AUDIT_LOG_DIR'}

if not any(v.get('name') == 'audit-policy' for v in volumes):
    volumes.append(policy_vol)
    vol_mounts.append(policy_mount)

if not any(v.get('name') == 'audit-log' for v in volumes):
    volumes.append(log_vol)
    vol_mounts.append(log_mount)

manifest['spec']['volumes'] = volumes
containers[0]['volumeMounts'] = vol_mounts

with open('$APISERVER_MANIFEST', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False)
" 2>/dev/null || info "Could not auto-patch volumes — you may need to add them manually"
    fi

    # Remove audit flags if present (user must add them)
    sed -i '/--audit-policy-file/d' "$APISERVER_MANIFEST"
    sed -i '/--audit-log-path/d' "$APISERVER_MANIFEST"
  fi

  echo ""
  pass "Setup complete."
  echo ""
  echo "TASK: Configure Kubernetes audit logging:"
  echo ""
  echo "  1. Edit the audit policy at: $POLICY_FILE"
  echo "     Required rules (in order):"
  echo "       a. Namespaces: RequestResponse level"
  echo "       b. ConfigMaps in namespace 'frontend': Request level"
  echo "       c. ConfigMaps and Secrets everywhere: Metadata level"
  echo "       d. Catch-all: Metadata level"
  echo ""
  echo "  2. Add API server flags in $APISERVER_MANIFEST:"
  echo "       --audit-policy-file=$POLICY_FILE"
  echo "       --audit-log-path=$AUDIT_LOG_DIR/audit.log"
  echo ""
  echo "  (Volumes are already mounted for you.)"
  echo ""
  timer_start
}

do_check() {
  header "$QUESTION — CHECK"

  local score=0
  local total=7

  # Checks 1-5: Policy file validation (works on both kind and kubeadm)
  if [ -f "$POLICY_FILE" ]; then
    # Check 1: Policy file exists and is valid YAML
    if python3 -c "import yaml; yaml.safe_load(open('$POLICY_FILE'))" 2>/dev/null; then
      pass "Audit policy file exists and is valid YAML"
      score=$((score + 1))
    else
      fail "Audit policy file is not valid YAML"
    fi

    # Parse the policy rules with python for robust checking
    local policy_checks
    policy_checks=$(python3 -c "
import yaml, sys

with open('$POLICY_FILE') as f:
    policy = yaml.safe_load(f)

rules = policy.get('rules', [])
results = {'namespaces_rr': False, 'cm_frontend_req': False, 'cm_secrets_meta': False, 'catchall_meta': False}

for r in rules:
    level = r.get('level', '')
    resources_list = r.get('resources', [])
    namespaces = r.get('namespaces', [])
    resource_names = []
    for res in resources_list:
        resource_names.extend(res.get('resources', []))

    # Check: namespaces at RequestResponse
    if 'namespaces' in resource_names and level == 'RequestResponse':
        results['namespaces_rr'] = True

    # Check: configmaps in frontend at Request
    if 'configmaps' in resource_names and 'frontend' in namespaces and level == 'Request':
        results['cm_frontend_req'] = True

    # Check: configmaps and secrets at Metadata
    if 'configmaps' in resource_names and 'secrets' in resource_names and level == 'Metadata':
        results['cm_secrets_meta'] = True

    # Check: catch-all Metadata (no resources, no namespaces filter)
    if level == 'Metadata' and not resources_list and not namespaces:
        results['catchall_meta'] = True

for k, v in results.items():
    print(f'{k}={v}')
" 2>/dev/null)

    # Check 2: namespaces at RequestResponse
    if echo "$policy_checks" | grep -q 'namespaces_rr=True'; then
      pass "Policy has namespaces at RequestResponse level"
      score=$((score + 1))
    else
      fail "Policy missing: namespaces at RequestResponse level"
    fi

    # Check 3: configmaps in frontend at Request
    if echo "$policy_checks" | grep -q 'cm_frontend_req=True'; then
      pass "Policy has configmaps in 'frontend' namespace at Request level"
      score=$((score + 1))
    else
      fail "Policy missing: configmaps in 'frontend' at Request level"
    fi

    # Check 4: configmaps+secrets at Metadata
    if echo "$policy_checks" | grep -q 'cm_secrets_meta=True'; then
      pass "Policy has configmaps+secrets at Metadata level"
      score=$((score + 1))
    else
      fail "Policy missing: configmaps+secrets at Metadata level"
    fi

    # Check 5: catch-all Metadata
    if echo "$policy_checks" | grep -q 'catchall_meta=True'; then
      pass "Policy has catch-all Metadata rule"
      score=$((score + 1))
    else
      fail "Policy missing: catch-all Metadata rule"
    fi
  else
    fail "Audit policy file not found at $POLICY_FILE"
    fail "(Skipping policy content checks)"
  fi

  # Checks 6-7: API server flags (kubeadm only)
  if [ "$ENV_TYPE" = "kubeadm" ]; then
    # Check 6: --audit-policy-file flag
    if grep -q '\-\-audit-policy-file' "$APISERVER_MANIFEST" 2>/dev/null; then
      pass "API server has --audit-policy-file flag"
      score=$((score + 1))
    else
      fail "API server missing --audit-policy-file flag"
    fi

    # Check 7: --audit-log-path flag
    if grep -q '\-\-audit-log-path' "$APISERVER_MANIFEST" 2>/dev/null; then
      pass "API server has --audit-log-path flag"
      score=$((score + 1))
    else
      fail "API server missing --audit-log-path flag"
    fi
  else
    skip "API server flag checks require kubeadm (checks 6-7)"
    skip "  --audit-policy-file"
    skip "  --audit-log-path"
  fi

  score_report "$score" "$total"

  if [ "${CKS_TIMER_START:-}" ]; then
    timer_stop "20 minutes"
  fi
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<SOLUTION
1. Edit the audit policy at $POLICY_FILE:

   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
     # Namespaces — full request + response bodies
     - level: RequestResponse
       resources:
       - group: ""
         resources: ["namespaces"]

     # ConfigMaps in frontend namespace — request bodies only
     - level: Request
       resources:
       - group: ""
         resources: ["configmaps"]
       namespaces: ["frontend"]

     # ConfigMaps and Secrets everywhere — metadata only
     - level: Metadata
       resources:
       - group: ""
         resources: ["configmaps", "secrets"]

     # Catch-all — everything else at Metadata
     - level: Metadata

2. Add flags to $APISERVER_MANIFEST (in spec.containers[0].command):

     - --audit-policy-file=$POLICY_FILE
     - --audit-log-path=$AUDIT_LOG_DIR/audit.log

3. Wait for API server to restart (manifest change triggers static pod restart).

4. Verify logs appear:

   ls -la $AUDIT_LOG_DIR/audit.log

VERIFICATION:
   Run: ./q15-audit-policy.sh check
SOLUTION
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
