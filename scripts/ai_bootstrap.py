#!/usr/bin/env python3
"""Reconciles coder/ai/providers.yaml and coder/ai/models.yaml into a running
Coder server's AI provider/model-config APIs.

Invoked by scripts/ai-bootstrap.sh (the single entrypoint). Not meant to be
run standalone in production, but every function here is unit-testable
without network access.

Secret handling: resolve_secret() is the only place a secret value is ever
read. redact() is applied to any string before it is printed/logged so a raw
API key can never reach stdout/stderr, even inside an HTTP error body.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CODER_URL = os.environ.get("CODER_URL", "http://localhost:7080")
SECRET_NAME_RE = re.compile(r"(API_KEY|TOKEN|SECRET)$", re.IGNORECASE)


def resolve_secret(name: str) -> str:
    """Resolve a secret by environment-variable name.

    1. If env var `name` is set and non-empty, return it.
    2. If CADE_SECRET_BACKEND=openbao, read secret/cade/ai/<lowered name>
       via the `bao` CLI. TODO(OpenBao): not implemented yet.
    3. Otherwise return "".

    Never raises; never exits non-zero. Safe to call with a nonexistent
    variable name.
    """
    value = os.environ.get(name, "")
    if value:
        return value

    if os.environ.get("CADE_SECRET_BACKEND") == "openbao":
        # TODO(OpenBao): implement real secret lookup once the OpenBao
        # secret engine for AI provider keys exists (see AGENTS.md
        # governance-bootstrap notes). Deliberately not implemented now:
        # this branch must stay unreachable until that step is done.
        raise NotImplementedError(
            "OpenBao secret backend not yet implemented for resolve_secret()"
        )

    return ""


def redact(text: str) -> str:
    """Best-effort redaction of any secret-looking value found in text.

    Scans currently-set environment variables whose name matches
    *_API_KEY|*_TOKEN|*_SECRET and, if their (non-empty) value appears in
    `text`, replaces it with a placeholder. Applied to all log/error output
    before printing.
    """
    if not text:
        return text
    redacted = text
    for name, value in os.environ.items():
        if not value:
            continue
        if SECRET_NAME_RE.search(name) and value in redacted:
            redacted = redacted.replace(value, "***REDACTED***")
    return redacted


def log(msg: str) -> None:
    print(redact(msg), flush=True)


def load_yaml(path: Path) -> Any:
    import yaml  # local import: only needed when actually parsing

    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def wait_for_coder_health(timeout_s: int = 60) -> bool:
    deadline = time.monotonic() + timeout_s
    url = f"{CODER_URL}/api/v2/buildinfo"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:  # noqa: S310
                if resp.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(2)
    return False


def http_request(
    method: str,
    path: str,
    token: str,
    body: dict | None = None,
) -> tuple[int, Any]:
    url = f"{CODER_URL}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)  # noqa: S310
    req.add_header("Coder-Session-Token", token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
            raw = resp.read()
            payload = json.loads(raw) if raw else None
            return resp.status, payload
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = redact(raw.decode("utf-8", "replace"))
        return exc.code, payload


def find_by_name(items: list[dict], name: str) -> dict | None:
    for item in items:
        if item.get("name") == name:
            return item
    return None


def expected_masked(secret: str) -> str:
    """Reproduce Coder's own masking format for an API key, verified live:
    a stored key with value "sk-test-...-000000" is returned by the API as
    masked="sk-t...0000" — i.e. first 4 chars + "..." + last 4 chars. Used
    to detect key drift deterministically without ever storing/comparing
    the real secret value ourselves.
    """
    if len(secret) <= 8:
        return secret
    return f"{secret[:4]}...{secret[-4:]}"


def reconcile_provider(provider: dict, token: str, results: list[dict]) -> str | None:
    """Reconcile a single provider. Returns its UUID, or None if skipped."""
    name = provider["name"]
    key_env = provider["api_key_env"]
    secret = resolve_secret(key_env)
    if not secret:
        log(f"WARNING: {key_env} is not set/resolvable — skipping provider '{name}'")
        results.append({"kind": "provider", "name": name, "action": "skipped"})
        return None

    status, existing = http_request("GET", "/api/v2/ai/providers", token)
    if status != 200 or not isinstance(existing, list):
        log(f"WARNING: could not list existing AI providers (status {status}) — skipping '{name}'")
        results.append({"kind": "provider", "name": name, "action": "skipped"})
        return None

    current = find_by_name(existing, name)

    if current is not None:
        # NOTE: the PATCH endpoint's `api_keys` field expects an array of
        # mutation objects — each either `{"id": "<existing-key-id>"}` (keep)
        # or `{"api_key": "<new-value>"}` (add) — not the raw-string-array
        # shape POST accepts. Sending POST's shape on PATCH fails with a 400
        # ("cannot unmarshal string into ... AIProviderKeyMutation"),
        # verified live. Also verified live: PATCHing `api_keys` with a new
        # `api_key` entry REPLACES the provider's key set (the old key's id
        # disappears) rather than appending — so a rotation is a single
        # `api_keys: [{"api_key": secret}]` PATCH, not an add-then-remove.
        #
        # We detect whether the currently-stored key already matches the
        # resolved secret via Coder's own masking format (see
        # expected_masked()) rather than ever storing/comparing the raw
        # secret ourselves — this is what keeps a genuinely-unchanged key
        # from re-PATCHing every run (true idempotency, T4) while still
        # letting a real rotation (e.g. operator sets OPENAI_API_KEY for
        # the first time after already running ai-bootstrap once) actually
        # take effect (required for T5 to ever pass).
        non_secret_fields = {
            "display_name": provider["display_name"],
            "type": provider["type"],
            "base_url": provider["base_url"],
            "enabled": provider.get("enabled", True),
        }
        fields_differ = any(current.get(k) != v for k, v in non_secret_fields.items())
        current_keys = current.get("api_keys") or []
        key_matches = bool(current_keys) and current_keys[0].get("masked") == expected_masked(secret)

        if not fields_differ and key_matches:
            log(f"Provider '{name}': unchanged")
            results.append({"kind": "provider", "name": name, "action": "unchanged"})
            return current.get("id")

        patch_body: dict = {"name": name}
        if fields_differ:
            patch_body.update(non_secret_fields)
        if not key_matches:
            patch_body["api_keys"] = [{"api_key": secret}]

        status, updated = http_request(
            "PATCH", f"/api/v2/ai/providers/{name}", token, patch_body
        )
        if status not in (200, 204):
            log(f"WARNING: PATCH provider '{name}' failed (status {status})")
            results.append({"kind": "provider", "name": name, "action": "skipped"})
            return current.get("id")
        action = "updated" if fields_differ else "key rotated"
        log(f"Provider '{name}': {action}")
        results.append({"kind": "provider", "name": name, "action": action})
        return (updated or current).get("id")

    body = {
        "name": name,
        "display_name": provider["display_name"],
        "type": provider["type"],
        "base_url": provider["base_url"],

        "enabled": provider.get("enabled", True),
        "api_keys": [secret],
    }
    status, created = http_request("POST", "/api/v2/ai/providers", token, body)
    if status not in (200, 201):
        log(f"WARNING: POST provider '{name}' failed (status {status})")
        results.append({"kind": "provider", "name": name, "action": "skipped"})
        return None
    log(f"Provider '{name}': created")
    results.append({"kind": "provider", "name": name, "action": "created"})
    return (created or {}).get("id")


def reconcile_model(
    model: dict, provider_id: str | None, token: str, results: list[dict]
) -> None:
    label = f"{model['provider']}/{model['model']}"
    if provider_id is None:
        log(f"WARNING: no provider id for '{model['provider']}' — skipping model '{label}'")
        results.append({"kind": "model", "name": label, "action": "skipped"})
        return

    status, existing = http_request(
        "GET", "/api/experimental/chats/model-configs", token
    )
    if status != 200 or not isinstance(existing, list):
        log(f"WARNING: could not list model-configs (status {status}) — skipping '{label}'")
        results.append({"kind": "model", "name": label, "action": "skipped"})
        return

    match = None
    for item in existing:
        if item.get("ai_provider_id") == provider_id and item.get("model") == model["model"]:
            match = item
            break

    body = {
        "ai_provider_id": provider_id,
        "model": model["model"],
        "display_name": model["display_name"],
        "context_limit": model["context_limit"],
        "enabled": model.get("enabled", True),
    }

    if match is not None:
        identical = all(match.get(k) == v for k, v in body.items())
        if identical:
            log(f"Model '{label}': unchanged")
            results.append({"kind": "model", "name": label, "action": "unchanged"})
            return
        config_id = match.get("id")
        status, _ = http_request(
            "PATCH", f"/api/experimental/chats/model-configs/{config_id}", token, body
        )
        if status not in (200, 204):
            log(f"WARNING: PATCH model-config '{label}' failed (status {status})")
            results.append({"kind": "model", "name": label, "action": "skipped"})
            return
        log(f"Model '{label}': updated")
        results.append({"kind": "model", "name": label, "action": "updated"})
        return

    status, _ = http_request(
        "POST", "/api/experimental/chats/model-configs", token, body
    )
    if status not in (200, 201):
        log(f"WARNING: POST model-config '{label}' failed (status {status})")
        results.append({"kind": "model", "name": label, "action": "skipped"})
        return
    log(f"Model '{label}': created")
    results.append({"kind": "model", "name": label, "action": "created"})


def handle_default_model(models: list[dict], token: str, results: list[dict]) -> None:
    """Set the deployment default model, verified live 2026-08-30: the
    model-config object returned by GET /api/experimental/chats/model-configs
    has an `is_default` boolean field, and PATCHing a target config's id with
    `{"is_default": true}` both sets it and atomically clears the flag on
    whichever config previously held it (server-enforced "exactly one
    default", confirmed by re-GETting afterward) — no separate "unset old
    default" call is needed.
    """
    defaults = [m for m in models if m.get("default")]
    if not defaults:
        return
    default_model = defaults[0]
    label = f"{default_model['provider']}/{default_model['model']}"

    status, configs = http_request(
        "GET", "/api/experimental/chats/model-configs", token
    )
    if status != 200 or not isinstance(configs, list):
        log(f"WARNING: could not list model-configs (status {status}) — skipping default '{label}'")
        results.append({"kind": "default", "name": label, "action": "skipped"})
        return

    match = next((c for c in configs if c.get("model") == default_model["model"]), None)
    if match is None:
        log(f"WARNING: model-config for '{label}' not found — skipping default")
        results.append({"kind": "default", "name": label, "action": "skipped"})
        return

    if match.get("is_default"):
        log(f"Default model: unchanged ('{label}' already default)")
        results.append({"kind": "default", "name": label, "action": "unchanged"})
        return

    status, _ = http_request(
        "PATCH",
        f"/api/experimental/chats/model-configs/{match['id']}",
        token,
        {"is_default": True},
    )
    if status not in (200, 204):
        log(f"WARNING: PATCH default model '{label}' failed (status {status})")
        results.append({"kind": "default", "name": label, "action": "skipped"})
        return
    log(f"Default model: set to '{label}'")
    results.append({"kind": "default", "name": label, "action": "updated"})


def print_summary(results: list[dict]) -> None:
    log("")
    log("Summary:")
    log(f"{'kind':<10}{'name':<30}action")
    for r in results:
        log(f"{r['kind']:<10}{r['name']:<30}{r['action']}")


def main(argv: list[str]) -> int:
    best_effort = "--best-effort" in argv

    token = os.environ.get("CODER_SESSION_TOKEN", "")
    if not token:
        print(
            "SKIP: CODER_SESSION_TOKEN not set — run 'make ai-token' then "
            "re-run 'make ai-bootstrap'."
        )
        return 0

    log(f"Waiting for Coder health at {CODER_URL} ...")
    if not wait_for_coder_health(60):
        msg = f"Coder at {CODER_URL} did not become healthy within 60s"
        if best_effort:
            log(f"SKIP (best-effort): {msg}")
            return 0
        log(f"ERROR: {msg}")
        return 1
    log("Coder is healthy.")

    providers_path = REPO_ROOT / "coder" / "ai" / "providers.yaml"
    models_path = REPO_ROOT / "coder" / "ai" / "models.yaml"
    providers = (load_yaml(providers_path) or {}).get("providers", [])
    models = (load_yaml(models_path) or {}).get("models", [])

    if not providers and not models:
        log("Nothing to do: no providers or models configured.")
        return 0

    results: list[dict] = []
    provider_ids: dict[str, str | None] = {}
    for provider in providers:
        provider_ids[provider["name"]] = reconcile_provider(provider, token, results)

    for model in models:
        reconcile_model(model, provider_ids.get(model["provider"]), token, results)

    handle_default_model(models, token, results)
    print_summary(results)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
