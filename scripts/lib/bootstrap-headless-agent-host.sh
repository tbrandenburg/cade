#!/usr/bin/env bash
# Private implementation; invoke through ../bootstrap-headless-agent-host.sh.
set -Eeuo pipefail
node=$1
shift
exec 3>&1
fail() { printf '%s\n' 'bootstrap: failed (see private install log if created)' >&3; exit 1; }
if [[ $# == 1 && $1 == --help ]]; then
  printf '%s\n' 'Usage: bootstrap-headless-agent-host.sh --install-root /existing/private/parent/new-directory'
  exit 0
fi
[[ $# == 2 && $1 == --install-root && $2 == /* && $EUID != 0 ]] || fail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail
root=$2
parent=$(dirname -- "$root")
[[ ! -e $root && ! -L $root && -d $parent && ! -L $parent ]] || fail
[[ $(realpath -- "$parent") == "$parent" && $(stat -c %u -- "$parent") == "$EUID" ]] || fail
[[ $(stat -c %a -- "$parent") == 700 && $(basename -- "$root") != .* ]] || fail
for tool in node npm git curl tar sha256sum timeout; do command -v "$tool" >/dev/null || fail; done
umask 077
mkdir -- "$root"
root=$(realpath -- "$root")
export HOME="$root/home"
mkdir -- "$HOME" "$root/cli" "$root/runtime-reference"
exec >"$root/install.log" 2>&1
trap fail ERR
cli_commit=04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1
client_commit=a88f9ba25105661fd6a63de41559362ddb2bbbe5
runtime_commit=6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1
download() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 600 "$1" -o "$2"
}
download "https://vscode.download.prss.microsoft.com/dbazure/download/stable/$cli_commit/vscode_cli_linux_x64_cli.tar.gz" "$root/cli.tar.gz"
printf '%s  %s\n' e079ddb70377cca515ab0cf5ca1ee4095a14e1f510af4b10a75b01c6018f9f02 "$root/cli.tar.gz" | sha256sum --check -
[[ $(tar -tzf "$root/cli.tar.gz") == code ]]
tar -xzf "$root/cli.tar.gz" -C "$root/cli" code
[[ $("$root/cli/code" --version) == "code 1.139.1 (commit $cli_commit)" ]]
download 'https://update.code.visualstudio.com/api/latest/server-linux-x64/stable' "$root/runtime-latest.json"
"$node" - "$root/runtime-latest.json" <<'JS'
const fs = require('node:fs');
const latest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (latest.productVersion !== '1.142.0' || latest.version !== '6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1') process.exit(1);
JS
download "https://update.code.visualstudio.com/commit:$runtime_commit/server-linux-x64/stable" "$root/runtime.tar.gz"
printf '%s  %s\n' f1ee2833c6323ee03e49d46351e834c44811c53d14ba178f5debdb84a5eb7876 "$root/runtime.tar.gz" | sha256sum --check -
tar -xzf "$root/runtime.tar.gz" -C "$root/runtime-reference" --strip-components=1
timeout --kill-after=5 300 git clone --no-checkout https://github.com/TylerLeonhardt/ahpx.git "$root/ahpx"
timeout --kill-after=5 300 git -C "$root/ahpx" fetch origin "$client_commit"
git -C "$root/ahpx" checkout --detach "$client_commit"
[[ $(git -C "$root/ahpx" rev-parse HEAD) == "$client_commit" ]]
cd -- "$root/ahpx"
timeout --kill-after=5 600 npm ci --ignore-scripts --no-audit --no-fund
timeout --kill-after=5 300 npm run build
timeout --kill-after=5 300 npm run typecheck
timeout --kill-after=5 300 ./node_modules/.bin/tsup src/client/index.ts --format esm --target node20 --out-dir proof-lib --dts
sha256sum proof-lib/index.js > "$root/client.sha256"
printf '%s\n' '{"cliVersion":"1.139.1","cliCommit":"04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1","clientCommit":"a88f9ba25105661fd6a63de41559362ddb2bbbe5","runtimeReferenceVersion":"1.142.0","runtimeReferenceCommit":"6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1","runtimeArchiveSha256":"f1ee2833c6323ee03e49d46351e834c44811c53d14ba178f5debdb84a5eb7876"}' > "$root/manifest.json"
printf '%s\n' '{"installed":true,"cliVersion":"1.139.1","runtimeReferenceVersion":"1.142.0","hostStarted":false}' >&3
