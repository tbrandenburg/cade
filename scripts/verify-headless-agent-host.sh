#!/usr/bin/env bash
# Credential-free launcher: only file paths, never a token, enter argv.
set -euo pipefail
fail() { printf '%s\n' '{"initialized":false,"error":"unsupported-node"}'; exit 1; }
node=$(type -P node) || fail
node=$(/usr/bin/realpath -- "$node") || fail
/usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/nonexistent \
  /usr/bin/timeout 10 "$node" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
  >/dev/null 2>&1 || fail
directory=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/nonexistent \
  "$node" "$directory/lib/headless-agent-host.mjs" "$@"
