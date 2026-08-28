#!/usr/bin/env bash
# Generates cache/registry/auth/htpasswd for the M7 `registry` compose
# service. Shells out to the `httpd:2.4-alpine` image's `htpasswd` binary
# via `docker run` so no local apache2-utils dependency is required.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <user> <password>" >&2
  exit 1
fi

user="$1"
password="$2"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/auth"
mkdir -p "$dir"

docker run --rm httpd:2.4-alpine htpasswd -Bbn "$user" "$password" > "$dir/htpasswd"

echo "Wrote $dir/htpasswd for user '$user'."
