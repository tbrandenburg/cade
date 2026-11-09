#!/usr/bin/env bash
set -euo pipefail

id="$(docker compose ps --all -q coder)"
if [[ -z "$id" || "$id" == *$'\n'* ]]; then
  echo "ERROR: expected one Coder container after startup" >&2
  exit 1
fi
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
  case "$state" in
    'running healthy') echo 'Coder is healthy'; exit 0 ;;
    'exited '*|'dead '*|*' unhealthy'|*' none')
      echo "ERROR: Coder startup failed ($state)" >&2
      exit 1 ;;
  esac
  sleep 2
done
echo "ERROR: timed out waiting for Coder health" >&2
exit 1
