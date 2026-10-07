#!/bin/bash
# CKS Practice — Q13: Dockerfile + Deployment Hardening
source "$(dirname "$0")/lib.sh"

DOCKER_DIR="$HOME/cks/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile"
DEPLOY_YAML="$DOCKER_DIR/deployment.yaml"

do_setup() {
  header "Q13 Setup — Dockerfile + Deployment Hardening"

  info "Creating directory $DOCKER_DIR..."
  mkdir -p "$DOCKER_DIR"

  info "Creating insecure Dockerfile at $DOCKERFILE..."
  cat > "$DOCKERFILE" <<'EOF'
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y nginx

USER root

COPY app /app

ENTRYPOINT ["/app"]
EOF

  info "Creating insecure deployment.yaml at $DEPLOY_YAML..."
  cat > "$DEPLOY_YAML" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insecure-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: insecure-app
  template:
    metadata:
      labels:
        app: insecure-app
    spec:
      containers:
      - name: app
        image: insecure-app:latest
        securityContext:
          privileged: true
          readOnlyRootFilesystem: false
          runAsUser: 0
EOF

  echo ""
  info "Setup complete. Fix the following security issues:"
  info ""
  info "  1. $DOCKERFILE — Change USER from root to a non-root user"
  info "  2. $DEPLOY_YAML — Set privileged to false"
  info "  3. $DEPLOY_YAML — Set readOnlyRootFilesystem to true"
  info "  4. $DEPLOY_YAML — Set runAsUser to a non-zero UID"
  info ""
  info "When ready, run: $0 check"
}

do_check() {
  header "Q13 Check — Dockerfile + Deployment Hardening"

  local score=0
  local total=4

  # 1. Dockerfile USER is not root/0
  if [ ! -f "$DOCKERFILE" ]; then
    fail "Dockerfile not found at $DOCKERFILE"
  else
    local user_line
    user_line=$(grep -i "^USER" "$DOCKERFILE" | tail -1 || true)
    if [ -z "$user_line" ]; then
      fail "No USER directive found in Dockerfile"
    else
      local user_val
      user_val=$(echo "$user_line" | awk '{print $2}')
      if [ "$user_val" = "root" ] || [ "$user_val" = "0" ]; then
        fail "Dockerfile USER is '$user_val' (must not be root or 0)"
      else
        pass "Dockerfile USER is '$user_val' (not root)"
        score=$((score + 1))
      fi
    fi
  fi

  # 2. deployment.yaml privileged is false
  if [ ! -f "$DEPLOY_YAML" ]; then
    fail "deployment.yaml not found at $DEPLOY_YAML"
  else
    local priv
    priv=$(grep -E "^\s*privileged:" "$DEPLOY_YAML" | awk '{print $2}' | tr -d '[:space:]')
    if [ "$priv" = "false" ]; then
      pass "deployment.yaml: privileged=false"
      score=$((score + 1))
    else
      fail "deployment.yaml: privileged='$priv' (must be false)"
    fi
  fi

  # 3. deployment.yaml readOnlyRootFilesystem is true
  if [ -f "$DEPLOY_YAML" ]; then
    local rofs
    rofs=$(grep -E "^\s*readOnlyRootFilesystem:" "$DEPLOY_YAML" | awk '{print $2}' | tr -d '[:space:]')
    if [ "$rofs" = "true" ]; then
      pass "deployment.yaml: readOnlyRootFilesystem=true"
      score=$((score + 1))
    else
      fail "deployment.yaml: readOnlyRootFilesystem='$rofs' (must be true)"
    fi
  fi

  # 4. deployment.yaml runAsUser is not 0
  if [ -f "$DEPLOY_YAML" ]; then
    local rau
    rau=$(grep -E "^\s*runAsUser:" "$DEPLOY_YAML" | awk '{print $2}' | tr -d '[:space:]')
    if [ -z "$rau" ]; then
      fail "deployment.yaml: runAsUser not found"
    elif [ "$rau" = "0" ]; then
      fail "deployment.yaml: runAsUser=0 (must not be 0)"
    else
      pass "deployment.yaml: runAsUser=$rau (not 0)"
      score=$((score + 1))
    fi
  fi

  score_report "$score" "$total"
}

do_solution() {
  header "Q13 Solution — Dockerfile + Deployment Hardening"

  echo "1. Dockerfile — change USER root to a non-root user:"
  echo ""
  cat <<'SOL'
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y nginx && \
    useradd -r -s /bin/false appuser

USER appuser

COPY app /app

ENTRYPOINT ["/app"]
SOL

  echo ""
  echo "2. deployment.yaml — fix the securityContext:"
  echo ""
  cat <<'SOL'
        securityContext:
          privileged: false
          readOnlyRootFilesystem: true
          runAsUser: 10000
SOL
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
