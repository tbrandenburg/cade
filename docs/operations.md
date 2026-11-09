# Operations — cade

Operational runbooks not covered by the `Makefile` help text.

## Renewing the Temporal Coder token

The `temporal-svc` token lasts seven days. Authenticate the Coder CLI as an
owner, then run `make coder-svc-token`; it creates the service user if needed
and prints a **private file path**, never the token. Set
`CODER_WORKSPACE_REAP_ACTION=delete` when running the command only if the
deployment uses delete rather than the default stop policy.

Install the token during a quiet maintenance window and stop at the first
error. Use the actual worker's
Compose project and working directory, not another checkout's `.env`. The
example below handles the usual single-`compose.yaml` deployment; if the
worker uses overrides, use its original Compose files instead. Set `TOKEN_FILE`
to the path printed by `make coder-svc-token` and do not print its contents.

```bash
DEPLOY=$(docker inspect temporal-worker --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
PROJECT=$(docker inspect temporal-worker --format '{{index .Config.Labels "com.docker.compose.project"}}')
FILES=$(docker inspect temporal-worker --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
test "$FILES" = "$DEPLOY/compose.yaml" || { echo 'Use the original Compose overrides.' >&2; exit 1; }
```

Back up the environment privately and replace only the token. The backup is
kept next to the token file for rollback; neither belongs in a build context.

```bash
python3 - "$DEPLOY/.env" "$TOKEN_FILE" <<'PY'
import os, sys, tempfile
from pathlib import Path

env, token_file = map(Path, sys.argv[1:])
original, token = env.read_bytes(), token_file.read_bytes().strip()
if not token or b'\n' in token:
    raise SystemExit('Invalid token file')
lines = original.splitlines(keepends=True)
indexes = [i for i, line in enumerate(lines) if line.startswith(b'CODER_WORKSPACE_API_TOKEN=')]
if len(indexes) != 1:
    raise SystemExit('Expected one CODER_WORKSPACE_API_TOKEN entry')
backup = token_file.with_name('env.before')
fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as stream:
    stream.write(original)
lines[indexes[0]] = b'CODER_WORKSPACE_API_TOKEN=' + token + b'\n'
with tempfile.TemporaryDirectory(prefix='.cade-token-', dir=env.parent) as directory:
    staged = Path(directory) / '.env'
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(b''.join(lines))
    os.replace(staged, env)
PY
```

Recreate only the worker, then check its real Coder identity. Keep the prior
token valid until this succeeds; on failure, restore `env.before` to the
deployment `.env` and recreate the worker again.

```bash
env -i PATH="$PATH" HOME="$HOME" docker compose -p "$PROJECT" --project-directory "$DEPLOY" \
  -f "$DEPLOY/compose.yaml" up -d --no-deps --no-build --pull never --force-recreate temporal-worker
docker exec temporal-worker python -c 'import json,os,urllib.request; r=urllib.request.Request(os.getenv("CODER_URL","http://coder:7080")+"/api/v2/users/me",headers={"Coder-Session-Token":os.environ["CODER_WORKSPACE_API_TOKEN"]}); x=urllib.request.urlopen(r,timeout=10); u=json.load(x); assert x.status==200 and u["username"]=="temporal-svc"; print("Temporal Coder authentication OK")'
```

OpenBao, if used as a separate record of this token, is not updated by this
procedure; administrative recovery is tracked in [#170](https://github.com/tbrandenburg/cade/issues/170).

## Self-hosted runner image rebuild / patch cadence (Milestone M2)

`runner/Dockerfile` is the highest-security-sensitivity image in the
platform (it executes code dispatched from GitHub). It pins:

- the base OS image by digest (`ubuntu:24.04@sha256:...`)
- the GitHub Actions Runner release by version + a hardcoded SHA-256
  checksum verified at build time

Both pins mean the image **will not silently drift** — which also means it
will not silently pick up security patches. Rebuild cadence:

- **Monthly**, at minimum: bump the `ubuntu:24.04` digest to the latest
  digest for that tag (`docker pull ubuntu:24.04 && docker inspect
  --format='{{index .RepoDigests 0}}' ubuntu:24.04`) and re-run
  `make runner-build`.
- **Within 48h of a GitHub Actions Runner security release**: check
  https://github.com/actions/runner/releases, bump `RUNNER_VERSION` and
  `RUNNER_SHA256` (the release asset's own checksum — recompute with
  `sha256sum` on the downloaded tarball since GitHub does not always
  publish it in the release notes body), and re-run `make runner-build`.
- **Immediately** on a disclosed CVE affecting either pin.

Because the runner is JIT/ephemeral (no persistent container), a rebuilt
image takes effect on the very next `scripts/runner-jit-start.sh` /
`runner-smoke.yml` run — no drain/replace procedure is needed.

## Rebuilding the runner image

```
make runner-build
```

Behind a corporate/TLS-intercepting proxy:

```
make runner-build CACERT=/path/to/ca-bundle.pem
```

## Observability stack (Milestone M13)

`docker compose up -d` starts `otel-collector`, `prometheus`, `loki`,
`alloy`, `cadvisor`, and `grafana` alongside the rest of the platform.
Grafana is the only observability service published to the host
(`127.0.0.1:${GRAFANA_PORT:-3001}`, default `http://localhost:3001`,
default credentials `admin` / `${GRAFANA_ADMIN_PASSWORD:-admin}` — change
before any non-local use). Prometheus and Loki are internal-only, reached
through Grafana's provisioned datasources (`prometheus`, `loki` uids).

### Minimum Dashboard layout

Provisioned from `observability/grafana/provisioning/dashboards/files/
phase4.json` (folder "Phase 4 — Observability", dashboard "Phase 4 -
Observability (Minimum Dashboard)"). Panels, top to bottom:

1. **Service uptime** — `time() - container_start_time_seconds{name!=""}`
   (cAdvisor), one series per container name.
2. **Temporal activity count** — `sum(temporal_activity_task_received_total)`.
3. **MCP request count (lab-sim)** — `sum(lab_sim_requests_total)`.
4. **Lab API request count (by tool)** — `sum(lab_sim_tool_calls_total) by (tool)`.
5. **Workflow failures** — `sum(temporal_workflow_failed_total)` (red
   threshold at 1).

### Finding/correlating one execution across services

1. Run the thing you want to trace (e.g. `make temporal-demo-start` for a
   workflow, or an MCP tool call against `lab-sim`) and note the wall-clock
   time.
2. In Grafana, open the Minimum Dashboard and narrow the time range to
   just around that timestamp — the metrics panels show the corresponding
   counter increment.
3. Switch to the **Loki** datasource (Explore, or a Loki panel) and query
   `{container=~"lab-sim|temporal-worker|temporal|runner-health"}`
   restricted to the same time window — every compose container's stdout/
   stderr is shipped there by `alloy` (Docker service discovery against
   `/var/run/docker.sock`). The read-only bind does not restrict Docker API
   privileges; access to the socket still grants host daemon control.
   Correlate the specific request/workflow by matching timestamps and
   identifiers (workflow_id, reservation_id, caller_id) that appear in the
   log lines across the different `container` label values.

### Migrating from Promtail

Before deploying Alloy on an existing installation, stop and remove the old
collector. This also works after checking out this revision, whose Compose file
no longer defines Promtail. The old service used the explicit container name
`promtail`; verify its Compose labels before acting on its immutable ID:
If the existing deployment uses a nondefault project, explicitly select it
with `COMPOSE_PROJECT_NAME` as described in the
[Coder upgrade procedure](/README.md#upgrading-coder-to-238) before continuing.

```bash
(
  set -euo pipefail
  project="$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
  id="$(docker inspect --format '{{.Id}}' promtail)"
  labels="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}' "$id")"
  if [ -z "$project" ] || [ "$labels" != "$project:promtail" ]; then
    printf 'Refusing to remove container with unexpected Compose labels: %s\n' "$labels" >&2
    exit 1
  fi
  docker stop "$id"
  docker rm "$id"
)
```

Before using `make up` to deploy this revision, complete the mandatory
[Coder upgrade and database backup procedure](/README.md#upgrading-coder-to-238)
if upgrading an existing deployment. Then deploy with `make up`. Compose does
not remove orphaned services by default, so omitting the removal could leave both collectors
running. Alloy's `alloy_data` volume stores Docker read positions across
restarts. Alloy does not import Promtail's Docker positions: its first start,
or loss of that volume, can replay Docker-retained log history and duplicate
entries. Check the relevant Loki streams during the cutover. Removing the old
collector avoids concurrent ingestion but does not itself prevent replay.
Alloy's Docker cursor has whole-second precision, so entries in the last
recorded second may also be re-sent after a restart; check the resulting Loki
streams rather than assuming exactly-once delivery.

For acceptance, before stopping Promtail emit distinct nonsecret stdout and
stderr markers in a disposable discovered container and record their Loki
timestamps and counts, using the same streams and time windows after cutover. Compare
the retained pre-cutover entries and counts after Alloy starts to detect replay;
allow ingestion to settle before each comparison. In Grafana Explore use
`{container="<name>", stream="stdout"} |= "<marker>"` and the corresponding
`stderr` selector. Also emit distinct markers after cutover, record their
timestamps and counts, restart Alloy, then query those **same pre-restart**
markers over the same time window and compare counts. Emit new post-restart
markers to check continued ingestion, and verify Promtail is absent. Report
missing or increased counts rather than assuming either is impossible: a test
fixture observed duplication at a whole-second cursor boundary. Loki query
results, retention, timestamp boundaries and deduplication can obscure what was
sent; these comparisons are diagnostic, not proof of exactly-once delivery.
For `docker exec` markers, write to `/proc/1/fd/1` or `/proc/1/fd/2` so Docker
captures them in the container log.

Prometheus targets (`otel-collector`, `temporal-server`, `temporal-worker`,
`lab-sim`, `cadvisor`) can be checked directly with `docker exec prometheus
wget -qO- http://localhost:9090/api/v1/targets` if a panel shows no data.

## Backup / Restore (Milestone M14)

```
make backup          # bash scripts/backup.sh [name]
make restore-test     # bash scripts/restore-test.sh [name]
```

See `docs/disaster-recovery.md` for the full procedure, what is/isn't
backed up, and the OpenBao `file`-backend deviation from the plan's
literal Raft-snapshot wording.

## Final Acceptance / Full End-to-End Scenario (Milestone M16)

See `AGENTS.md`'s "Agent Instructions" section for the step-by-step
walkthrough of the Final E2E Test Request (A–L) and the three Durability
Boundary Tests (UI/AHP, Worker/Temporal, Workspace/Coder).

## Workspace apps: JupyterLab and Node-RED (Issue #60)

Two independent, opt-in dashboard tiles on the `docker-workspace`
(`docker-workspace`) template, both off by default. Each app runs as a
plain in-workspace process (baked into `cade/coder-workspace:latest` at
build time by `coder/Dockerfile`, launched at workspace start by a
`coder_script`), bound to `127.0.0.1` inside the workspace container only.
**Neither app has its own login** — the only way to reach either is
through Coder's own authenticated agent/session proxy. Nothing is
published to the host or the platform's Docker networks.

### Enabling

- At workspace create time: `--parameter enable_jupyter=true` and/or
  `--parameter enable_nodered=true`.
- On an already-existing workspace (no delete/recreate needed):
  ```bash
  scripts/set-workspace-jupyter.sh <owner>/<workspace>            # enable
  scripts/set-workspace-jupyter.sh <owner>/<workspace> false      # disable
  scripts/set-workspace-nodered.sh <owner>/<workspace>            # enable
  scripts/set-workspace-nodered.sh <owner>/<workspace> false      # disable
  ```
  Both wrap the generic `scripts/set-workspace-parameter.sh` (same
  mechanism already used by `scripts/set-workspace-temporal-tile.sh`) —
  this stops (if running) and restarts the workspace container with the
  new parameter value; `docker_volume.home_volume` is untouched
  (Durability Test 3 applies).

### Where data lives

- JupyterLab: notebooks/files under `/home/coder/project` (the same
  cloned-repo directory every other tool in the workspace uses) —
  persistent home volume.
- Node-RED: flows/credentials under `/home/coder/.node-red` — persistent
  home volume. Palette nodes (including
  `@flowfuse/node-red-dashboard`/`@tbrandenburg/node-red-agents`) are
  installed globally at image-build time (`/usr/lib/node_modules`), not
  per-workspace — a brand-new home volume needs zero network access for
  the palette to be available. `@tbrandenburg/node-red-agents` is pinned
  to `>=0.3.8` (Issue #63). Earlier `0.3.x` releases declared
  `engines.node >=22`; `0.3.8` relaxed this to `>=20`. That constraint is
  compatible with the workspace image's Node 24. Re-check this pin whenever
  `coder/Dockerfile`'s `NODE_RED_AGENTS_VERSION` or `NODE_MAJOR` ARGs change.

### Where logs are

- `/tmp/jupyter.log`, `/tmp/node-red.log` inside the workspace container
  (`docker exec <container> tail -f /tmp/jupyter.log`).
- Coder's own `coder_script` log panel on the workspace page (each app's
  own script, isolated from the other and from the base
  `coder_agent.main.startup_script`).

### Verifying live

```bash
scripts/verify-workspace-jupyter.sh <owner>/<workspace>
scripts/verify-workspace-nodered.sh <owner>/<workspace>
```

Checks: `coder_app` slug presence, process liveness, loopback-only
listener, proxied HTTP round trip (with vs. without a session token), and
(Node-RED only) that the dashboard/agents palettes are discovered and
`/flows` returns real JSON.

### JupyterLab: fixed-prefix sidecar, no DNS required (Issue #94)

Superseded (Issue #94): #83's subdomain-routed (`subdomain = true` +
`CODER_WILDCARD_ACCESS_URL`) approach worked, but required every client's
DNS resolver to reach the public internet to resolve the `*.<ip>.nip.io`
wildcard hostname — a hard blocker in locked-down enterprise/private
networks with no external DNS path. `coder_app.jupyter` is now back to
plain path-based routing (`subdomain = false`, identical mechanism to
Node-RED's tile), fronted by a small in-workspace Caddy reverse-proxy
sidecar (127.0.0.1:8888) that unconditionally re-adds the workspace's own
fixed prefix (`/@<owner>/<workspace>/apps/jupyter`, known at
Terraform-plan time) to every bare/stripped request before forwarding it
to `jupyter-lab` (127.0.0.1:8889), which is launched with a matching
`--ServerApp.base_url`. This reconstructs the same invariant JupyterHub's
own `configurable-http-proxy` relies on (prefix-preserving proxy + a
matching `base_url`) — Coder's real path-based proxy still strips the
prefix with no `X-Forwarded-Prefix` header and no opt-out
(`coder/coder#14483`, see #60/#62/#76/#81 for the full history), but now
the sidecar restores it locally instead. **No DNS/wildcard hostname setup
of any kind is required** — `CODER_WILDCARD_ACCESS_URL` and its
auto-derivation machinery have been removed entirely (no template in this
repo uses `subdomain = true` anymore).

## OpenBao operator lifecycle

OpenBao 2.6.5 uses verified TLS, one local `cade-operator` userpass login,
and the existing KV v2 mount at `secret/`. Requirements: Python 3, Docker,
the running OpenBao container, and its mounted CA certificate. Bootstrap no
longer changes data-directory ownership or bypasses certificate verification.
Run the normal certificate/startup prerequisites before bootstrap.

```bash
# First bootstrap: hidden password prompt (16-72 UTF-8 bytes).
# Save the password in your password manager, separate from unseal shares.
make governance-bootstrap

# Automation: password-manager output over stdin, never a password argument.
# Replace password-manager-command with your own private retrieval command.
password-manager-command | bash scripts/openbao-init.sh --password-file -

# Or use an owner-only password file outside the repository/build contexts:
bash scripts/openbao-init.sh --password-file /private/operator-password

# Ordinary run: unseal only; does not need the operator password or valid root.
bash scripts/openbao-init.sh

# Explicit rotation: authenticates a fresh operator session; missing/wrong
# credentials return nonzero, even when the saved root token was revoked.
bash scripts/openbao-init.sh --force-rotate --password-file /private/operator-password
```

`FORCE_ROTATE=1` is the environment equivalent of `--force-rotate`.
Rotation creates fresh `coder-db`, `temporal-db`, and `lab-sim` records and
copies the optional Coder/Omnigent credentials from exported environment or
`.env`. It updates **stored records only**, not live consumers. Privately
reconcile consumers with stored versions before restarting affected services.
On a partial write failure, inspect versions before retrying; rotation is
not a multi-record transaction. Do not run blanket rotation to change just
one live service credential.

The operator policy grants **only read/create/update** on
`secret/data/devenv-cloud/*`; it cannot delete/list secrets, manage auth,
create tokens, or generate root. `devenv-cloud-read` stays read-only.
Sessions are five-minute non-renewable **batch** tokens, without `default`
policy, used in memory without the CLI login cache. They expire rather than
being individually revoked. The helper validates the login's policy and TTL
before use; no token, password, or share is supplied in process arguments.
Do not enable Python tracing/debuggers or shell tracing around secret input.

For a single record, put its desired JSON fields in an owner-only file
outside the repo, then use the same transport without printing values:

```bash
python3 - <<'PY'
import getpass, json, sys
from pathlib import Path
sys.path.insert(0, "scripts")
from openbao_client import login, private_read
operator = login(getpass.getpass("OpenBao operator password: "))
payload = json.loads(private_read(Path("/private/desired-fields.json")))
path = "secret/data/devenv-cloud/example"
operator.write(path, {"data": payload})
if operator.read(path)["data"]["data"] != payload:
    raise SystemExit("Stored record verification failed")
print("Stored record verified; values withheld")
PY
```

If provisioning/login fails during bootstrap, root is not deliberately
revoked. Preserve the private init file and password, fix permissions/TLS
or unlock the user with the still-valid administrator, then explicitly run:

```bash
bash scripts/openbao-init.sh --resume-bootstrap --password-file /private/operator-password
```

Resume provisions/verifies the operator, rotates stored records, and revokes
the saved bootstrap root. A plain re-unseal never implicitly resumes or
rotates. Keep `init.json` mode 600 (older checkouts may need `chmod 600`).
Bootstrap output needs an owned parent directory without group/world write
permission; a private owned subdirectory under shared `/tmp` is supported.
Initialization retains its exclusive file descriptor through the server call
and share write, rather than reopening the path.
Restore matching shares to a private file when needed; `BAO_INIT_FILE`
selects it. `BAO_CONTAINER` selects the exact container, `BAO_ADDR` must be
HTTPS, and `BAO_CACERT` selects the certificate path **inside that container**
(defaults: `openbao`, `https://127.0.0.1:8200`, `/openbao/certs/openbao.crt`).
The in-container CLI starts with a clean environment: inherited Agent addresses,
TLS bypass/server-name overrides, proxies, redirects, and token helpers/caches
cannot override these settings. Redirect following and CLI retries are disabled;
authentication uses only the explicit stdin token, never a cached login.
`BAO_ENV_FILE` optionally selects an alternative `.env` source; disposable
tests use it to avoid reading the deployment's credentials.

### Add the operator to an existing instance with a valid administrator

Export that administrator's token privately into an owner-only file outside
the repository. This mode does not require the old initial root and does
not rotate stored credentials or revoke the caller's administrator token:

```bash
bash scripts/openbao-init.sh --provision-operator \
  --admin-token-file /private/existing-admin-token \
  --password-file /private/operator-password
```

It intentionally creates/updates only the fixed `cade-operator` account and
the two scoped policies, preserving other userpass accounts. It refuses to
replace incompatible existing mounts. Revoke a temporary administrator via
`auth/token/revoke-self` using the private transport after verifying login.
For **no valid administrator**, use the isolated copied-storage recovery
procedure in [disaster recovery](/docs/disaster-recovery.md#openbao-locked-out-administration-recovery).
