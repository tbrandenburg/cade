#!/usr/bin/env bash
# print-urls.sh — Print browser URLs for the platform's main web UIs after
# `make up`. Reads ports from .env (falling back to compose.yaml defaults)
# so the output always matches what was actually published to the host.
#
# Usage: scripts/print-urls.sh

set -u

ENV_FILE="${ENV_FILE:-.env}"

port() {
  local var="$1" default="$2"
  if [ -f "$ENV_FILE" ]; then
    local value
    value="$(grep -E "^${var}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    [ -n "$value" ] && { echo "$value"; return; }
  fi
  echo "$default"
}

coder_port="$(port CODER_HTTP_PORT 7080)"
temporal_ui_port="$(port TEMPORAL_UI_PORT 8088)"
grafana_port="$(port GRAFANA_PORT 3001)"

echo ""
echo "Platform stack is up. Main web UIs:"
echo "  Coder (workspaces)      http://localhost:${coder_port}"
echo "  Temporal (workflows)    http://localhost:${temporal_ui_port}"
echo "  Grafana (observability) http://localhost:${grafana_port}  (login: admin / GRAFANA_ADMIN_PASSWORD in .env, default 'admin')"
echo ""
echo "Run 'make status' to confirm every service is (healthy)/Up before using them."
