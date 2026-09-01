#!/usr/bin/env bash
# derive-wildcard-access-url.sh — Best-effort default for
# CODER_WILDCARD_ACCESS_URL (Issue #86, follow-up to #83).
#
# CODER_WILDCARD_ACCESS_URL has no single correct default across every
# deployment topology (LAN server, cloud VM, Tailscale-only, air-gapped
# host), so this script only derives a value for the common
# single-NIC/LAN case: it asks the kernel for the default-route source
# IPv4 address (the address a browser on this network would actually use
# to reach this host) and composes a nip.io wildcard hostname from it.
#
# Usage:
#   scripts/derive-wildcard-access-url.sh            # print derived value (or a "could not derive" message); no side effects
#   scripts/derive-wildcard-access-url.sh --write     # additionally persist into $ENV_FILE (default .env), idempotently:
#                                                      #   - never overwrites an already-set, non-empty value
#                                                      #   - never duplicates the CODER_WILDCARD_ACCESS_URL= line
#                                                      #   - does nothing if no value could be derived
#
# ENV_FILE can be overridden (matches scripts/print-urls.sh's convention)
# for isolated testing against a scratch copy of .env.

set -u

ENV_FILE="${ENV_FILE:-.env}"
VAR_NAME="CODER_WILDCARD_ACCESS_URL"

# current_value VAR_FILE — the value currently set for VAR_NAME in
# ENV_FILE, or empty if unset/absent/no such file.
current_value() {
  [ -f "$ENV_FILE" ] || { echo ""; return; }
  grep -E "^${VAR_NAME}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-
}

# derive_ip — print the default-route source IPv4, or nothing if it
# can't be determined or looks like loopback/link-local.
derive_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"
  [ -z "$ip" ] && return 1
  case "$ip" in
    127.*|169.254.*) return 1 ;;
  esac
  echo "$ip"
}

main() {
  local write=0
  [ "${1:-}" = "--write" ] && write=1

  local existing
  existing="$(current_value)"
  if [ -n "$existing" ]; then
    echo "CODER_WILDCARD_ACCESS_URL already set to '${existing}' -- leaving untouched."
    return 0
  fi

  local ip derived
  if ! ip="$(derive_ip)"; then
    echo "Could not derive a default for CODER_WILDCARD_ACCESS_URL (no default route found, or it resolved to a loopback/link-local address). Leaving it empty -- set it manually in ${ENV_FILE} if you need subdomain-routed coder_app tiles (e.g. Jupyter, see .env.example)."
    return 0
  fi

  derived="*.${ip}.nip.io"
  echo "Derived CODER_WILDCARD_ACCESS_URL=${derived} (from default-route source IP ${ip})."

  if [ "$write" -eq 1 ]; then
    if [ -f "$ENV_FILE" ] && grep -qE "^${VAR_NAME}=" "$ENV_FILE" 2>/dev/null; then
      # Line exists but empty -- replace in place.
      local tmp
      tmp="$(mktemp)"
      awk -v var="$VAR_NAME" -v val="$derived" -F= '
        $1==var { print var "=" val; next }
        { print }
      ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    elif [ -f "$ENV_FILE" ]; then
      echo "${VAR_NAME}=${derived}" >> "$ENV_FILE"
    else
      echo "${VAR_NAME}=${derived}" > "$ENV_FILE"
    fi
    echo "Wrote ${VAR_NAME}=${derived} to ${ENV_FILE}."
  fi
}

main "$@"
