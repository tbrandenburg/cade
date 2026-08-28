#!/usr/bin/env bash
# verify-ahp-session.sh — Perform the actual AHP JSON-RPC-over-WebSocket
# handshake against a remote VS Code Agent Host (Milestone M4).
#
# AHP is JSON-RPC over WebSocket on a plain HTTP-Upgrade endpoint (verified
# hands-on in the independent ahp-sandbox POC, docs/POC.md step 7 there):
# a bare HTTP GET hangs (it is not a normal HTTP server), a WebSocket-upgrade
# request gets `HTTP/1.1 101 Switching Protocols`, and an `initialize`
# JSON-RPC call with `params: {"protocolVersions":["1.0.0"]}` returns a real
# handshake containing `protocolVersion`, `serverSeq`, `defaultDirectory`.
#
# This script proves AHP actually answers over the SSH-tunnelled connection,
# not just that some process/port is listening.
#
# Usage: scripts/verify-ahp-session.sh <coder-ssh-host> [remote-port] [connection-token]
#   e.g. scripts/verify-ahp-session.sh coder.my-workspace
#
# If [remote-port] is omitted, the script tries to discover it from the
# running Agent Host process's `--port` argument on the remote host. If
# [connection-token] is omitted, it tries to read it from the process's
# `--connection-token-file` argument.
#
# Exit code: 0 if the AHP `initialize` handshake succeeds, 1 otherwise.

set -euo pipefail

HOST="${1:-}"
REMOTE_PORT="${2:-}"
TOKEN="${3:-}"

if [ -z "$HOST" ]; then
  echo "Usage: $0 <coder-ssh-host> [remote-port] [connection-token]" >&2
  echo "Run scripts/configure-coder-ssh.sh first, then pass e.g. coder.<workspace-name>." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: 'node' not found on PATH (required for the WebSocket handshake client)." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

REMOTE_PS=""
if [ -z "$REMOTE_PORT" ] || [ -z "$TOKEN" ]; then
  REMOTE_PS="$(ssh "${SSH_OPTS[@]}" "$HOST" "ps -eo args= | grep -E 'agent host' | grep -v grep" || true)"
fi

if [ -z "$REMOTE_PORT" ]; then
  REMOTE_PORT="$(printf '%s\n' "$REMOTE_PS" | grep -oE -- '--port[= ][0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
fi
if [ -z "$REMOTE_PORT" ]; then
  echo "ERROR: could not discover the Agent Host's listening port on $HOST." >&2
  echo "Pass it explicitly: $0 $HOST <remote-port> [connection-token]" >&2
  echo "(run 'ssh $HOST ps -eo args= | grep \"agent host\"' to find it manually)" >&2
  exit 1
fi

if [ -z "$TOKEN" ]; then
  TOKEN_FILE="$(printf '%s\n' "$REMOTE_PS" | grep -oE -- '--connection-token-file[= ][^ ]+' | sed -E 's/.*[= ]//' | head -1 || true)"
  if [ -n "$TOKEN_FILE" ]; then
    TOKEN="$(ssh "${SSH_OPTS[@]}" "$HOST" "cat '$TOKEN_FILE'" || true)"
  fi
fi

LOCAL_PORT="${AHP_LOCAL_PORT:-18123}"

echo "Tunnelling 127.0.0.1:${LOCAL_PORT} -> ${HOST}:${REMOTE_PORT}..."
ssh "${SSH_OPTS[@]}" -f -N -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "$HOST"
TUNNEL_PID="$(pgrep -f "ssh.*-L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}.*${HOST}" | head -1 || true)"

cleanup() {
  if [ -n "${TUNNEL_PID:-}" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 1

AHP_URL="ws://127.0.0.1:${LOCAL_PORT}/" AHP_TOKEN="$TOKEN" node --input-type=module - <<'NODE_EOF'
const url = process.env.AHP_URL;
const token = process.env.AHP_TOKEN || "";

const headers = {};
if (token) {
  headers["x-coder-connection-token"] = token;
  headers["Authorization"] = `Bearer ${token}`;
}

const ws = new WebSocket(url, { headers });

const timeout = setTimeout(() => {
  console.error("FAIL: no response from Agent Host within 10s.");
  process.exit(1);
}, 10000);

ws.addEventListener("open", () => {
  ws.send(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersions: ["1.0.0"] },
    })
  );
});

ws.addEventListener("message", (event) => {
  clearTimeout(timeout);
  let msg;
  try {
    msg = JSON.parse(event.data.toString());
  } catch (err) {
    console.error("FAIL: response was not valid JSON:", event.data);
    process.exit(1);
  }

  const result = msg.result ?? msg;
  const hasHandshake =
    result &&
    typeof result === "object" &&
    "protocolVersion" in result &&
    "serverSeq" in result &&
    "defaultDirectory" in result;

  if (hasHandshake) {
    console.log("PASS: AHP initialize handshake succeeded.");
    console.log(JSON.stringify(result, null, 2));
    ws.close();
    process.exit(0);
  }

  console.error("FAIL: response missing protocolVersion/serverSeq/defaultDirectory:");
  console.error(JSON.stringify(msg, null, 2));
  process.exit(1);
});

ws.addEventListener("error", (err) => {
  clearTimeout(timeout);
  console.error("FAIL: WebSocket error:", err.message || err);
  process.exit(1);
});
NODE_EOF
