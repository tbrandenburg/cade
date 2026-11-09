#!/usr/bin/env bash
# Build the workspace image with a restrictive source mode and check its defaults.
# Run from the repository root: bash scripts/test-workspace-image-permissions.sh
# Optionally set CACERT to a CA bundle for TLS-intercepting proxies.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cade-issue-164.XXXXXXXX")
image="cade/issue-164-image-permissions:${tmp##*.}"
cleanup() {
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/coder/workspace-apps" "$tmp/coder/omnigent" "$tmp/agent-host"
cp "$root/coder/Dockerfile" "$tmp/coder/Dockerfile"
cp "$root/coder/workspace-apps/node-red-settings.js" "$tmp/coder/workspace-apps/"
cp "$root/coder/omnigent/"{launch,relay,seed}.py "$tmp/coder/omnigent/"
cp "$root/agent-host/srt-settings.json" "$tmp/agent-host/srt-settings.json"
chmod 600 "$tmp/agent-host/srt-settings.json"
test "$(stat -c '%a' "$tmp/agent-host/srt-settings.json")" = 600
test -s "$tmp/agent-host/srt-settings.json"

secret=()
if [[ -n ${CACERT:-} ]]; then
  secret=(--secret "id=cacert,src=$CACERT")
fi
docker buildx build --load -t "$image" -f "$tmp/coder/Dockerfile" "${secret[@]}" \
  --build-context "agent-host=$tmp/agent-host" "$tmp/coder"

docker run --rm -i --network none --entrypoint sh "$image" -c '
  set -eu
  file=/etc/cade/srt-settings.default.json
  test "$(id -un)" = coder
  test "$(id -u)" != 0
  stat -c "Packaged directory: %a %u:%g %n" /etc/cade
  test "$(stat -c "%a %u:%g" /etc/cade)" = "755 0:0"
  test ! -w /etc/cade
  stat -c "Packaged defaults: %a %u:%g %n" "$file"
  test "$(stat -c "%a %u:%g" "$file")" = "644 0:0"
  test -r "$file"
  test ! -w "$file"
  test ! -x "$file"
  cp "$file" /tmp/srt-settings.json
  cmp "$file" /tmp/srt-settings.json
  cmp - /tmp/srt-settings.json
  if (printf modified > "$file") 2>/dev/null; then
    echo "Non-root user unexpectedly modified packaged defaults" >&2
    exit 1
  fi
  echo "Workspace image defaults: non-root read and content verified; write denied"
' < "$tmp/agent-host/srt-settings.json"
