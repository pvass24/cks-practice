#!/bin/bash
# CKS Practice Suite — Runner
# Usage:
#   ./run.sh              — list all questions
#   ./run.sh 9            — setup Q9 + start timer
#   ./run.sh 9 check      — grade your work
#   ./run.sh 9 solution   — show the answer
#   ./run.sh 9 reset      — tear down and re-setup

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"

question_name() {
  case $1 in
    1)  echo "CIS Benchmark — Kubelet & ETCD Hardening";;
    2)  echo "ImagePolicyWebhook Admission Controller";;
    3)  echo "Istio mTLS Enforcement";;
    4)  echo "Pod Security Admission (Restricted)";;
    5)  echo "Falco — Detect /dev/mem Access";;
    6)  echo "BOM/SBOM — Find Vulnerable Library";;
    7)  echo "Worker Node Upgrade (kubeadm)";;
    8)  echo "API Server Authentication & Authorization";;
    9)  echo "Network Policies";;
    10) echo "Ingress with TLS + HTTPS Redirect";;
    11) echo "ServiceAccount Token Hardening";;
    12) echo "Security Context Hardening";;
    13) echo "Dockerfile + Deployment Hardening";;
    14) echo "TLS Secret Creation";;
    15) echo "Audit Policy & Logging";;
    16) echo "Docker Daemon Security";;
    17) echo "HTTPS Ingress with Cilium";;
  esac
}

question_env() {
  case $1 in
    1|2|3|5|6|7|16|17) echo "kubeadm";;
    8|15)              echo "partial";;
    *)                 echo "any";;
  esac
}

question_target() {
  case $1 in
    1)  echo "8 min";;  2)  echo "10 min";; 3)  echo "8 min";;
    4)  echo "5 min";;  5)  echo "8 min";;  6)  echo "8 min";;
    7)  echo "8 min";;  8)  echo "5 min";;  9)  echo "6 min";;
    10) echo "6 min";;  11) echo "6 min";;  12) echo "5 min";;
    13) echo "3 min";;  14) echo "2 min";;  15) echo "10 min";;
    16) echo "5 min";;
    17) echo "5 min";;
  esac
}

get_script() {
  local num=$1
  local padded=$(printf "%02d" "$num")
  local script=$(ls "$DIR"/q${padded}-*.sh 2>/dev/null | head -1)
  if [ -z "$script" ]; then
    echo -e "${RED}No script found for Q${num}${NC}" >&2
    exit 1
  fi
  echo "$script"
}

list_questions() {
  header "CKS Practice Suite"
  echo -e "  Environment: ${BOLD}${ENV_TYPE}${NC}"
  echo ""
  printf "  ${BOLD}%-4s %-45s %-12s %-8s${NC}\n" "#" "Question" "Env" "Target"
  echo "  ────────────────────────────────────────────────────────────────────"
  for i in $(seq 1 17); do
    local env=$(question_env "$i")
    local marker=""
    if [ "$env" = "kubeadm" ] && [ "$ENV_TYPE" = "kind" ]; then
      marker="${RED}kubeadm${NC}"
    elif [ "$env" = "partial" ]; then
      marker="${YELLOW}partial${NC}"
    else
      marker="${GREEN}any${NC}"
    fi
    printf "  %-4s %-45s " "Q${i}" "$(question_name "$i")"
    echo -e "${marker}       $(question_target "$i")"
  done
  echo ""
  echo "  Usage:"
  echo "    ./run.sh <num>            Setup + timer"
  echo "    ./run.sh <num> check      Grade your work"
  echo "    ./run.sh <num> solution   Show the answer"
  echo "    ./run.sh <num> reset      Teardown + re-setup"
  echo ""
}

if [ $# -eq 0 ]; then
  list_questions
  exit 0
fi

NUM="$1"
MODE="${2:-setup}"
HINT_LEVEL="${3:-1}"

if [ "$NUM" = "all" ] && [ "$MODE" = "check" ]; then
  header "Grading All Questions"
  for i in $(seq 1 17); do
    script=$(get_script "$i")
    echo -e "\n${BOLD}Q${i}: $(question_name "$i")${NC}"
    bash "$script" check 2>/dev/null || true
  done
  exit 0
fi

SCRIPT=$(get_script "$NUM")
NAME=$(question_name "$NUM")
TARGET=$(question_target "$NUM")

case "$MODE" in
  setup)
    header "Q${NUM}: ${NAME}"
    echo -e "  Target time: ${BOLD}${TARGET}${NC}"
    echo ""
    bash "$SCRIPT" setup
    echo ""
    timer_start
    ;;
  check)
    header "Q${NUM}: ${NAME} — Grading"
    bash "$SCRIPT" check
    ;;
  hint)
    bash "$SCRIPT" hint "$HINT_LEVEL"
    ;;
  solution)
    header "Q${NUM}: ${NAME} — Solution"
    bash "$SCRIPT" solution
    ;;
  reset)
    header "Q${NUM}: ${NAME} — Reset"
    bash "$SCRIPT" setup
    echo ""
    timer_start
    ;;
  *)
    echo "Usage: ./run.sh <num> [setup|check|hint [1-3]|solution|reset]"
    exit 1
    ;;
esac
