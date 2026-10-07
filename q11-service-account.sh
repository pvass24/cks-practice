#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q11 — ServiceAccount Token Hardening"
NAMESPACE="serviceaccount"
SA_NAME="monitor-sa"
DEPLOY_NAME="monitor"

do_setup() {
  header "$QUESTION — SETUP"

  info "Creating namespace, ServiceAccount, and insecure Deployment..."

  # Create namespace
  kubectl create namespace "$NAMESPACE" 2>/dev/null || info "Namespace $NAMESPACE already exists"

  # Create ServiceAccount with default automount (true)
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA_NAME
  namespace: $NAMESPACE
EOF

  # Create Deployment using the SA — NO projected volume, default automount
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
    spec:
      serviceAccountName: $SA_NAME
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
EOF

  # Wait for deployment
  kubectl rollout status deployment/$DEPLOY_NAME -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

  echo ""
  pass "Setup complete."
  echo ""
  echo "TASK: Harden the ServiceAccount token setup:"
  echo "  1. Set automountServiceAccountToken: false on the ServiceAccount $SA_NAME"
  echo "  2. Set automountServiceAccountToken: false on the Deployment pod spec"
  echo "  3. Add a projected volume with serviceAccountToken source"
  echo "  4. Set expirationSeconds on the projected serviceAccountToken"
  echo "  5. Mount the projected volume as readOnly"
  echo ""
  echo "Namespace: $NAMESPACE"
  echo ""
  echo "Hints:"
  echo "  kubectl edit sa $SA_NAME -n $NAMESPACE"
  echo "  kubectl edit deploy $DEPLOY_NAME -n $NAMESPACE"
  echo ""
  timer_start
}

do_check() {
  header "$QUESTION — CHECK"

  local score=0
  local total=5

  # Check 1: SA has automountServiceAccountToken: false
  local sa_automount
  sa_automount=$(kubectl get sa "$SA_NAME" -n "$NAMESPACE" -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null)
  if [ "$sa_automount" = "false" ]; then
    pass "ServiceAccount $SA_NAME has automountServiceAccountToken: false"
    ((score++))
  else
    fail "ServiceAccount $SA_NAME does not have automountServiceAccountToken: false"
  fi

  # Get pod spec JSON
  local pod_spec
  pod_spec=$(kubectl get deploy "$DEPLOY_NAME" -n "$NAMESPACE" -o json 2>/dev/null)

  if [ -z "$pod_spec" ]; then
    fail "Deployment $DEPLOY_NAME not found in namespace $NAMESPACE"
    score_report "$score" "$total"
    return
  fi

  # Check 2: Deployment pod spec has automountServiceAccountToken: false
  local deploy_automount
  deploy_automount=$(echo "$pod_spec" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('spec',{}).get('template',{}).get('spec',{}).get('automountServiceAccountToken','NOT_SET'))
" 2>/dev/null)
  if [ "$deploy_automount" = "False" ] || [ "$deploy_automount" = "false" ]; then
    pass "Deployment pod spec has automountServiceAccountToken: false"
    ((score++))
  else
    fail "Deployment pod spec does not have automountServiceAccountToken: false (got: $deploy_automount)"
  fi

  # Check 3: Pod has a projected volume with serviceAccountToken source
  local has_projected_sa
  has_projected_sa=$(echo "$pod_spec" | python3 -c "
import sys, json
d = json.load(sys.stdin)
volumes = d.get('spec',{}).get('template',{}).get('spec',{}).get('volumes',[])
for v in volumes:
    proj = v.get('projected',{})
    sources = proj.get('sources',[])
    for s in sources:
        if 'serviceAccountToken' in s:
            print('yes')
            sys.exit(0)
print('no')
" 2>/dev/null)
  if [ "$has_projected_sa" = "yes" ]; then
    pass "Projected volume with serviceAccountToken source exists"
    ((score++))
  else
    fail "No projected volume with serviceAccountToken source found"
  fi

  # Check 4: serviceAccountToken has expirationSeconds set
  local has_expiration
  has_expiration=$(echo "$pod_spec" | python3 -c "
import sys, json
d = json.load(sys.stdin)
volumes = d.get('spec',{}).get('template',{}).get('spec',{}).get('volumes',[])
for v in volumes:
    proj = v.get('projected',{})
    sources = proj.get('sources',[])
    for s in sources:
        sat = s.get('serviceAccountToken',{})
        if 'expirationSeconds' in sat:
            print('yes')
            sys.exit(0)
print('no')
" 2>/dev/null)
  if [ "$has_expiration" = "yes" ]; then
    pass "serviceAccountToken has expirationSeconds set"
    ((score++))
  else
    fail "serviceAccountToken does not have expirationSeconds set"
  fi

  # Check 5: volumeMount exists and is readOnly
  local has_readonly_mount
  has_readonly_mount=$(echo "$pod_spec" | python3 -c "
import sys, json
d = json.load(sys.stdin)
containers = d.get('spec',{}).get('template',{}).get('spec',{}).get('containers',[])
for c in containers:
    mounts = c.get('volumeMounts',[])
    for m in mounts:
        if m.get('readOnly') == True:
            print('yes')
            sys.exit(0)
print('no')
" 2>/dev/null)
  if [ "$has_readonly_mount" = "yes" ]; then
    pass "Volume mount is readOnly"
    ((score++))
  else
    fail "No readOnly volume mount found"
  fi

  score_report "$score" "$total"

  if [ "${CKS_TIMER_START:-}" ]; then
    timer_stop "15 minutes"
  fi
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<SOLUTION
1. Edit the ServiceAccount to disable automount:

   kubectl edit sa $SA_NAME -n $NAMESPACE

   Add:
     automountServiceAccountToken: false

2. Edit the Deployment:

   kubectl edit deploy $DEPLOY_NAME -n $NAMESPACE

   The pod spec should look like:

   spec:
     serviceAccountName: $SA_NAME
     automountServiceAccountToken: false
     containers:
     - name: nginx
       image: nginx:1.25
       ports:
       - containerPort: 80
       volumeMounts:
       - name: sa-token
         mountPath: /var/run/secrets/kubernetes.io/serviceaccount
         readOnly: true
     volumes:
     - name: sa-token
       projected:
         sources:
         - serviceAccountToken:
             path: token
             expirationSeconds: 3600

3. Wait for rollout:

   kubectl rollout status deploy/$DEPLOY_NAME -n $NAMESPACE

VERIFICATION:
   Run: ./q11-service-account.sh check
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
