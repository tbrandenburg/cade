# M12 / M12.1 — Governance Foundation & E2E Denial Proof

Evidence captured for Phase 4 / Milestone M12 (Governance Foundation) and
M12.1 (E2E: Governance Denial Proof), per the evidence standard in
`docs/INITIAL.md` Section 3 Rule 2 and `docs/plan/plan.md` (M12/M12.1
section).

- **Timestamp (UTC):** 2026-08-28T19:57:40Z
- **Environment:** local Docker Compose stack (`docker compose ps` — see
  below), `opa` service `openpolicyagent/opa:1.9.0`, `openbao` service
  `openbao/openbao:2.6.2`, `lab-sim` MCP server (M11) live-wired to OPA's
  decision API via `mcp/lab-sim/src/lab_sim/policy.py`.

## Stack state at time of evidence capture

```
$ docker compose ps
NAME                  IMAGE                                  STATUS
coder                 ghcr.io/coder/coder:v2.36.3            Up (healthy)
coder-db              postgres:17.6-alpine                   Up (healthy)
lab-sim               devenv-cloud/lab-sim:latest             Up (healthy)
opa                   openpolicyagent/opa:1.9.0               Up
openbao               openbao/openbao:2.6.2                   Up
registry              registry:3.1.1                          Up (healthy)
runner-docker-proxy   tecnativa/docker-socket-proxy:v0.5.0    Up
runner-health         nginx:1.27-alpine                       Up (healthy)
temporal              temporalio/auto-setup:1.29.7            Up (healthy)
temporal-db           postgres:16.10-alpine                   Up (healthy)
temporal-ui           temporalio/ui:2.53.3                     Up (healthy)
temporal-worker       devenv-cloud/temporal-worker:latest      Up
```

## M12.1 — Live governance denial proof (this run)

Per the plan's binding instruction: *"attempt an unauthorized operation
against the live OPA decision endpoint (not a policy-file review, not
`opa test` alone)."* The following are direct, unmocked HTTP calls against
the running `opa` container's decision API (`http://127.0.0.1:8181`),
executed by the agent in this session, in addition to (not instead of) the
existing `opa test` suite and MCP round-trip check.

```
$ date -u +"%Y-%m-%dT%H:%M:%SZ"
2026-08-28T19:57:49Z

$ curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
    -d '{"input":{"action":"flash_device"}}'
{"result":false}

$ curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
    -d '{"input":{"action":"flash_device","approved":false}}'
{"result":false}

$ curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
    -d '{"input":{"action":"erase_device"}}'
{"result":false}
```

All three unauthorized attempts (implicit unapproved flash, explicit
unapproved flash, and an action with no matching `allow` rule at all) were
rejected live by OPA (`{"result":false}`) — a real policy-engine decision,
not a client-side check or a test-file assertion.

## Full validation run (`scripts/verify-governance.sh`)

This script runs three layers of proof: `opa test` (regression pins), the
live OPA decision API (ALLOW/DENY), and a full MCP tool round trip through
the actual M11 `lab-sim` server (proving the live wiring end-to-end, not
just the policy in isolation).

```
$ bash scripts/verify-governance.sh
==> [1/3] opa test governance/opa/policy
PASS: 6/6

==> [2/3] Live OPA decision API checks
    run_test -> {"result":true}
    flash_device (unapproved) -> {"result":false}

==> [3/3] Live MCP round trip through lab-sim (reserve -> run_test -> flash_device x2 -> release)
    reserved ecu-demo-01 -> e0b46e26b1248574
    run_test: is_error=False '{\n  "device": "ecu-demo-01",\n  "result": "pass"\n}'
    flash_device (unapproved): is_error=True 'Error executing tool flash_device'
    flash_device (approved): is_error=False 'flashed ecu-demo-01 with simulated firmware image'
    released ecu-demo-01
MCP round trip OK

==================================================================
M12 governance validation PASSED: opa test, live OPA decision API,
and a live MCP tool round trip all confirm run_test=ALLOW and
flash_device(unapproved)=DENY / flash_device(approved)=ALLOW.
==================================================================
```

Exit code: `0`. `run_test` → **ALLOW** (`{"result":true}`), `flash_device`
without approval → **DENY** (`{"result":false}`, and the MCP tool call
itself returns `is_error=True`), `flash_device` with `approved=true` →
**ALLOW**, exactly per the M12 Validation Milestone requirement.

## Policy source evaluated

`governance/opa/policy/lab_authz.rego` (package `lab.authz`), pinned by
`governance/opa/policy/lab_authz_test.rego` (`opa test`, 6/6 passing):

```rego
package lab.authz

default allow := false

allow if { input.action == "read_device" }
allow if { input.action == "run_test" }
allow if { input.action == "flash_device"; input.approved == true }
```

The MCP lab-server (`mcp/lab-sim/src/lab_sim/policy.py`) queries this
decision endpoint (`POST /v1/data/lab/authz/allow`) live before executing
`run_test`/`flash_device`; the allow/deny logic is not hardcoded in the MCP
server, and a transport failure to OPA fails closed (denied), not open.

## Credential-rotation log (Phase 1–3 credentials, carried over into OpenBao)

Rotated once via `scripts/openbao-init.sh` under the interim secret
handling rule (`docs/INITIAL.md` Section 3 Rule 3). New values live only in
OpenBao's `secret/devenv-cloud/*` KV store — never printed to a file or
committed to git. Full narrative in `docs/security.md` § "M12 — Governance
Foundation".

| Credential | Introduced | Rotated to (OpenBao path) |
|---|---|---|
| `CODER_PG_PASSWORD` (coder-db) | M1 | `secret/devenv-cloud/coder-db` |
| `TEMPORAL_PG_PASSWORD` (temporal-db) | M8 | `secret/devenv-cloud/temporal-db` |
| `LAB_SIM_TOKENS` (agent-a, agent-b) | M11 | `secret/devenv-cloud/lab-sim` |

OpenBao hardening applied and verified live in the same run that produced
this log:
- TLS-only listener (`governance/openbao/config/openbao.hcl`,
  self-signed cert from `scripts/openbao-gen-cert.sh`).
- `bao operator init` (5 key shares, threshold 3); unseal keys written once
  to `governance/openbao/unseal/init.json` (gitignored) for out-of-band
  relocation — never committed.
- Initial root token **revoked** after bootstrap (`docs/security.md` § M12
  records the live verification performed at bootstrap time: a
  `bao token lookup` issued with the revoked root token returned
  `403 permission denied`). At the time of this report's evidence capture
  the `openbao` container is sealed (requires operator-held unseal keys,
  by design — they are not stored in this repo); re-verifying token
  revocation was out of scope for this step, whose live-denial proof
  target is the OPA decision API used by M11/M12's `flash_device` policy,
  not OpenBao's seal state.
- Least-privilege `devenv-cloud-read` policy + `approle` auth method
  enabled for non-root access to `secret/data/devenv-cloud/*` going
  forward.

## Result

- ✅ WORKING — OPA live decision API rejects every unauthorized
  `flash_device`/unknown-action attempt tried against it in this session
  (three distinct attempts, all `{"result":false}`), while correctly
  allowing `run_test` and an approved `flash_device`.
- ✅ WORKING — `opa test` regression suite: 6/6 passing.
- ✅ WORKING — Live MCP round trip through the real `lab-sim` server
  confirms the same allow/deny outcomes through the actual execution path
  (not just the policy engine in isolation).
- ✅ WORKING — All Phase 1–3 credentials (coder-db, temporal-db, lab-sim
  tokens) rotated once into OpenBao (per `docs/security.md`); initial root
  token revocation was verified live at bootstrap time (see
  `docs/security.md` § M12) and was not re-tested in this run since
  OpenBao was sealed at time of capture.

No failures encountered in this run.
