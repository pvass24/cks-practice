#!/bin/bash
source "$(dirname "$0")/lib.sh"

QUESTION="Q16 — Docker Daemon Security"
DOCKER_SERVICE="/lib/systemd/system/docker.service"
DOCKER_SOCKET="/lib/systemd/system/docker.socket"

do_setup() {
  header "$QUESTION — SETUP"

  if ! requires_kubeadm; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  info "Creating insecure Docker configuration..."

  # Create user 'developer' and add to docker group
  if ! id developer &>/dev/null; then
    useradd -m developer
    info "Created user 'developer'"
  fi
  usermod -aG docker developer
  info "Added 'developer' to docker group"

  # Add TCP 2375 to docker.service ExecStart
  if [ -f "$DOCKER_SERVICE" ]; then
    cp "$DOCKER_SERVICE" "${DOCKER_SERVICE}.bak"

    # Add -H tcp://0.0.0.0:2375 to ExecStart if not already present
    if ! grep -q 'tcp://0.0.0.0:2375' "$DOCKER_SERVICE"; then
      sed -i 's|ExecStart=/usr/bin/dockerd|ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2375|' "$DOCKER_SERVICE"
      info "Added TCP 2375 listener to docker.service"
    fi
  else
    fail "Docker service file not found at $DOCKER_SERVICE"
    exit 1
  fi

  # Reload and restart docker
  systemctl daemon-reload
  systemctl restart docker
  info "Docker daemon reloaded and restarted"

  echo ""
  pass "Setup complete. Docker is now insecure."
  echo ""
  echo "TASK: Secure the Docker daemon:"
  echo "  1. Remove user 'developer' from the docker group"
  echo "  2. Ensure docker.socket SocketGroup is root (not docker)"
  echo "  3. Remove the tcp://0.0.0.0:2375 listener from docker.service"
  echo "  4. Reload and restart docker (daemon-reload + restart)"
  echo ""
  echo "Files to check:"
  echo "  - $DOCKER_SERVICE"
  echo "  - $DOCKER_SOCKET"
  echo ""
  echo "Commands to know:"
  echo "  gpasswd -d developer docker"
  echo "  systemctl daemon-reload"
  echo "  systemctl restart docker"
  echo ""
  timer_start
}

do_check() {
  header "$QUESTION — CHECK"

  if [ "$ENV_TYPE" != "kubeadm" ]; then
    skip "Requires kubeadm cluster — run on Killercoda"
    exit 0
  fi

  local score=0
  local total=4

  # Check 1: User 'developer' is NOT in docker group
  if id developer &>/dev/null; then
    if ! groups developer 2>/dev/null | grep -qw docker; then
      pass "User 'developer' is NOT in the docker group"
      ((score++))
    else
      fail "User 'developer' is still in the docker group"
    fi
  else
    pass "User 'developer' does not exist (also acceptable)"
    ((score++))
  fi

  # Check 2: docker.socket SocketGroup is root (not docker)
  if [ -f "$DOCKER_SOCKET" ]; then
    local socket_group
    socket_group=$(grep 'SocketGroup' "$DOCKER_SOCKET" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if [ "$socket_group" = "root" ] || [ -z "$socket_group" ]; then
      pass "docker.socket SocketGroup is root"
      ((score++))
    else
      fail "docker.socket SocketGroup is '$socket_group' (should be root)"
    fi
  else
    info "docker.socket not found at $DOCKER_SOCKET — checking systemctl"
    if systemctl cat docker.socket 2>/dev/null | grep -q 'SocketGroup=docker'; then
      fail "docker.socket SocketGroup is docker (should be root)"
    else
      pass "docker.socket SocketGroup is root"
      ((score++))
    fi
  fi

  # Check 3: docker.service does NOT have tcp://0.0.0.0:2375
  if grep -q 'tcp://0.0.0.0:2375' "$DOCKER_SERVICE" 2>/dev/null; then
    fail "docker.service still has tcp://0.0.0.0:2375 listener"
  else
    pass "docker.service does NOT have tcp://0.0.0.0:2375"
    ((score++))
  fi

  # Check 4: docker is running without TCP (daemon-reload was run)
  if systemctl is-active docker &>/dev/null; then
    # Verify docker is actually not listening on 2375
    if ! ss -tlnp 2>/dev/null | grep -q ':2375'; then
      pass "Docker is running and NOT listening on TCP 2375"
      ((score++))
    else
      fail "Docker is still listening on TCP 2375 — did you daemon-reload + restart?"
    fi
  else
    fail "Docker is not running"
  fi

  score_report "$score" "$total"

  if [ "${CKS_TIMER_START:-}" ]; then
    timer_stop "10 minutes"
  fi
}

do_solution() {
  header "$QUESTION — SOLUTION"

  cat <<SOLUTION
1. Remove 'developer' from the docker group:

   gpasswd -d developer docker

2. Edit $DOCKER_SOCKET — change SocketGroup:

   [Socket]
   ...
   SocketGroup=root    # was: docker

3. Edit $DOCKER_SERVICE — remove TCP listener:

   Change:
     ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2375 ...
   To:
     ExecStart=/usr/bin/dockerd ...

   (Remove the -H tcp://0.0.0.0:2375 part)

4. Reload and restart:

   systemctl daemon-reload
   systemctl restart docker

5. Verify:

   ss -tlnp | grep 2375           # should return nothing
   groups developer                # should NOT include 'docker'
   docker ps                       # should still work as root

VERIFICATION:
   Run: ./q16-docker-config.sh check
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
