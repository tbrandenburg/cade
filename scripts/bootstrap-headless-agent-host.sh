#!/usr/bin/env bash
# Download evaluation tools only; never start a host or accept server terms.
set -euo pipefail
fail() { printf '%s\n' 'bootstrap: Node.js >=20 is required'; exit 1; }
node=$(type -P node) || fail
node=$(/usr/bin/realpath -- "$node") || fail
# Never start Node with inherited NODE_OPTIONS, even for the prerequisite check.
/usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/nonexistent \
  /usr/bin/timeout 10 "$node" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
  >/dev/null 2>&1 || fail
directory=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
# npm and build-tool shebangs must resolve the selected interpreter too.
exec /usr/bin/env -i PATH="$(/usr/bin/dirname -- "$node"):/usr/local/bin:/usr/bin:/bin" HOME=/nonexistent \
  /bin/bash "$directory/lib/bootstrap-headless-agent-host.sh" "$node" "$@"
