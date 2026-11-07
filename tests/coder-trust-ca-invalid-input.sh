#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/trust"
printf '%s\n' 'old-system-bundle' > "$tmpdir/trust/ca-certificates.crt"
printf '%s\n' 'old-corporate-bundle' > "$tmpdir/trust/corporate-ca.pem"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'not-valid-base64' '-----END CERTIFICATE-----' > "$tmpdir/malformed.pem"
cat > "$tmpdir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker was called for malformed input\n' >> "$DOCKER_CALL_LOG"
printf '%s\n' 'overwritten' > "$TRUST_DIR/ca-certificates.crt"
printf '%s\n' 'overwritten' > "$TRUST_DIR/corporate-ca.pem"
DOCKER
chmod +x "$tmpdir/bin/docker"

if PATH="$tmpdir/bin:$PATH" DOCKER_CALL_LOG="$tmpdir/docker-calls" TRUST_DIR="$tmpdir/trust" \
  "$repo_root/scripts/coder-trust-ca.sh" "$tmpdir/malformed.pem"; then
  echo "ERROR: malformed PEM unexpectedly succeeded" >&2
  exit 1
fi

test ! -e "$tmpdir/docker-calls"
grep -qx 'old-system-bundle' "$tmpdir/trust/ca-certificates.crt"
grep -qx 'old-corporate-bundle' "$tmpdir/trust/corporate-ca.pem"
echo "PASS: malformed PEM did not call Docker or change either existing trust file"
