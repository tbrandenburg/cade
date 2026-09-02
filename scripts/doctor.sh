#!/usr/bin/env bash
# doctor.sh — Host preparation check for the private dev platform (Milestone M0).
#
# Verifies the host meets the baseline requirements before any service is
# brought up: OS, architecture, required tooling, disk space, outbound
# connectivity, and port availability.
#
# Usage: scripts/doctor.sh
# Exit code: 0 if all required checks PASS, 1 otherwise.

set -u

MIN_DISK_GB="${DOCTOR_MIN_DISK_GB:-100}"
REQUIRED_PORTS="${DOCTOR_REQUIRED_PORTS:-7080}"
CONNECT_TIMEOUT="${DOCTOR_CONNECT_TIMEOUT:-5}"
ENV_FILE="${ENV_FILE:-.env}"

PASS_COUNT=0
FAIL_COUNT=0

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'
  C_RED='\033[0;31m'
  C_YELLOW='\033[0;33m'
  C_RESET='\033[0m'
else
  C_GREEN=''
  C_RED=''
  C_YELLOW=''
  C_RESET=''
fi

pass() {
  printf "${C_GREEN}[PASS]${C_RESET} %s\n" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf "${C_RED}[FAIL]${C_RESET} %s\n" "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$1"
}

# ── Linux host ────────────────────────────────────────────────────────────
check_os() {
  local os
  os="$(uname -s)"
  if [ "$os" = "Linux" ]; then
    pass "Linux host detected ($os)"
  else
    fail "Not a Linux host (detected: $os)"
  fi
}

# ── Architecture ──────────────────────────────────────────────────────────
check_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      pass "Architecture is x86-64 ($arch)"
      ;;
    *)
      fail "Unsupported architecture: $arch (expected x86_64)"
      ;;
  esac
}

# ── Docker available ──────────────────────────────────────────────────────
check_docker_available() {
  if command -v docker >/dev/null 2>&1; then
    pass "Docker CLI available ($(docker --version 2>/dev/null))"
  else
    fail "Docker CLI not found in PATH"
  fi
}

# ── Docker daemon reachable ───────────────────────────────────────────────
check_docker_daemon() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker daemon reachability: docker CLI missing, cannot check"
    return
  fi
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable"
  else
    fail "Docker daemon is not reachable (is it running? do you have permission?)"
  fi
}

# ── Docker Compose available ──────────────────────────────────────────────
check_compose_available() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    pass "Docker Compose plugin available ($(docker compose version 2>/dev/null))"
  elif command -v docker-compose >/dev/null 2>&1; then
    pass "Docker Compose (standalone) available ($(docker-compose --version 2>/dev/null))"
  else
    fail "Docker Compose plugin not found (expected 'docker compose')"
  fi
}

# ── Git available ─────────────────────────────────────────────────────────
check_git() {
  if command -v git >/dev/null 2>&1; then
    pass "Git available ($(git --version 2>/dev/null))"
  else
    fail "Git not found in PATH"
  fi
}

# ── curl available ────────────────────────────────────────────────────────
check_curl() {
  if command -v curl >/dev/null 2>&1; then
    pass "curl available ($(curl --version 2>/dev/null | head -n1))"
  else
    fail "curl not found in PATH"
  fi
}

# ── jq available ──────────────────────────────────────────────────────────
check_jq() {
  if command -v jq >/dev/null 2>&1; then
    pass "jq available ($(jq --version 2>/dev/null))"
  else
    fail "jq not found in PATH"
  fi
}

# ── Disk space ─────────────────────────────────────────────────────────────
check_disk_space() {
  local avail_kb avail_gb
  avail_kb="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -z "${avail_kb:-}" ]; then
    fail "Could not determine available disk space"
    return
  fi
  avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -ge "$MIN_DISK_GB" ]; then
    pass "Disk space: ${avail_gb} GB free (>= ${MIN_DISK_GB} GB required)"
  else
    fail "Disk space: only ${avail_gb} GB free (< ${MIN_DISK_GB} GB required)"
  fi
}

# ── Outbound HTTPS connectivity ────────────────────────────────────────────
check_https() {
  local host="$1"
  if ! command -v curl >/dev/null 2>&1; then
    fail "HTTPS connectivity to $host: curl missing, cannot check"
    return
  fi
  if curl --fail --silent --show-error --max-time "$CONNECT_TIMEOUT" \
      --output /dev/null "https://${host}"; then
    pass "Outbound HTTPS connectivity to $host"
  else
    # A non-2xx/3xx HTTP response still proves connectivity reached the host;
    # only treat curl exit codes that indicate no connection as a failure.
    local status
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time "$CONNECT_TIMEOUT" "https://${host}" 2>/dev/null)
    if [ -n "$status" ] && [ "$status" != "000" ]; then
      pass "Outbound HTTPS connectivity to $host (HTTP $status)"
    else
      fail "No outbound HTTPS connectivity to $host"
    fi
  fi
}

# ── Issue #23: scoped bwrap AppArmor profile loaded? ─────────────────────
# Read-only check only -- never loads/replaces the profile itself (see
# scripts/load-security-profiles.sh, which must be run manually as root).
check_security_profiles() {
  if ! command -v apparmor_parser >/dev/null 2>&1; then
    warn "apparmor_parser not found -- cannot check/load the Issue #23 scoped bwrap profile (srt/bwrap in agent-workspace, docker-workspace, embedded-linux will fail to start until this is resolved)"
    return
  fi
  if command -v aa-status >/dev/null 2>&1 && aa-status 2>/dev/null | grep -q "cade-bwrap-workspace"; then
    pass "Issue #23 AppArmor profile 'cade-bwrap-workspace' is loaded"
  else
    warn "Issue #23 AppArmor profile 'cade-bwrap-workspace' is NOT loaded -- run 'sudo scripts/load-security-profiles.sh' before pushing/using agent-workspace, docker-workspace, or embedded-linux templates (they will fail workspace creation outright otherwise, see AGENTS.md)"
  fi
}

# ── Issue #69: required local secrets present? ───────────────────────────
# Read-only checks only -- never generate anything themselves. A fresh
# clone before governance-bootstrap/registry-bootstrap has run is expected
# to warn here, not fail; but skipping the fix will crash-loop openbao/
# registry forever once `docker compose up -d` runs (see AGENTS.md Issue #69).
check_openbao_cert() {
  local cert="governance/openbao/certs/openbao.crt"
  if [ -f "$cert" ]; then
    pass "OpenBao TLS cert present at $cert"
  else
    warn "OpenBao TLS cert missing at $cert -- 'make up' now generates it automatically (via scripts/openbao-gen-cert.sh); if you see this after running 'make up', run 'make governance-bootstrap' to init/unseal OpenBao. Without the cert, openbao will crash-loop forever once 'docker compose up -d' runs."
  fi
}

check_registry_htpasswd() {
  local htpasswd="cache/registry/auth/htpasswd"
  if [ -f "$htpasswd" ]; then
    pass "Registry htpasswd present at $htpasswd"
  else
    warn "Registry htpasswd missing at $htpasswd -- run 'make registry-bootstrap USER=<user> PASSWORD=<password>' before 'docker compose up -d', otherwise the registry service will crash-loop forever (it has no way to auto-generate credentials for you)."
  fi
}

# ── Port availability ──────────────────────────────────────────────────────
check_ports() {
  local port in_use
  for port in $REQUIRED_PORTS; do
    in_use=""
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}\$" && in_use=1
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && in_use=1
    else
      warn "Port ${port}: neither 'ss' nor 'netstat' available, cannot verify"
      continue
    fi
    if [ -n "$in_use" ]; then
      fail "Port ${port} is already in use"
    else
      pass "Port ${port} is available"
    fi
  done
}

main() {
  echo "== cade host doctor (M0) =="
  echo

  check_os
  check_arch
  check_docker_available
  check_docker_daemon
  check_compose_available
  check_git
  check_curl
  check_jq
  check_disk_space
  check_https "github.com"
  check_https "update.code.visualstudio.com"
  check_https "vscode.download.prss.microsoft.com"
  check_security_profiles
  check_openbao_cert
  check_registry_htpasswd
  check_ports

  echo
  echo "== Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
