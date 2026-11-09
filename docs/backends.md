# Workspace backends

## Three separate concepts

- **Environment (what):** the developer experience, e.g. `generic-linux` or
  `embedded-linux`. Environment names are not inferred from template names.
- **BackendConnection (where):** a named, explicitly enabled execution location
  and references to existing infrastructure, owned by a separate deployment repo.
- **Implementation (how):** a concrete Coder/Terraform template declared by CADE
  in `/workspace/catalog.yaml`. Connections never contain template paths/lists.

Coder/Terraform remains the lifecycle engine. There is no additional controller,
provider class hierarchy, runtime API, or enterprise Terraform-state reader.
Docker Compose hosting Coder/Postgres/Temporal is the **control-plane deployment**;
Docker running workspaces is a **workspace backend**. Disabling workspace Docker
must not stop Compose or alter its networks, volumes or security controls.

| Environment | Connection | Implementation |
| --- | --- | --- |
| `generic-linux` | `docker-local` | `docker-workspace` |
| `embedded-linux` | `docker-local` | `embedded-linux` |
| `devcontainer` | `docker-local` | `devcontainer` |
| `ai-agent` | `docker-local` | `agent-workspace` |
| `generic-linux` | `azure-remote-dev-env` | `generic-linux-azure` (offline preparation; NOT LIVE TESTED) |

## External deployment declarations

The product owns schema, examples, compatibility catalog and template code.
A customer deployment repository owns reviewed connection declarations, for example:

```text
cade/                              # product checkout
  workspace/backend-connection.schema.json
  workspace/catalog.yaml
  workspace/examples/
  coder/templates/
cade-deployment/                   # separate repository; example name only
  backends/docker-local.yaml
  backends/azure-remote-dev-env.yaml
```

Copy the examples from `/workspace/examples/` to the external directory.
`CADE_BACKENDS_DIR` selects that directory; `--dir` overrides the environment.
Neither an enterprise monorepo checkout nor raw Terraform state is needed.

Python 3.10+ and these pinned direct dependencies are required. Installation
may access PyPI; validation and resolution themselves are offline and read-only.
Use a project-local virtual environment, not system-wide package installation:

```bash
python3 -m venv .venv-backends
.venv-backends/bin/python -m pip install -r scripts/requirements-backends.txt
source .venv-backends/bin/activate
python3 scripts/backends-config.py validate --dir ../cade-deployment/backends
CADE_BACKENDS_DIR=../cade-deployment/backends python3 scripts/backends-config.py validate
```

Success prints `Valid BackendConnections: N`; invalid declarations exit 1 with
concise, value-free diagnostics. This proves syntax and reference consistency,
not Docker/Azure reachability, authentication, permissions, quota or deployability.
No Docker, Coder, Azure CLI, network calls or mutation are performed.

### Versioned minimal contract

`/workspace/backend-connection.schema.json` (JSON Schema 2020-12) is authoritative.
Each top-level `*.yaml`/`*.yml` file contains one declaration. Files are read in
lexical order; other extensions are ignored. Duplicate names/keys, YAML aliases,
merges, explicit tags, non-string keys, unknown fields and schema versions fail
closed. Input is bounded to 64 KiB/file and 20 levels. Errors do not echo declaration
values.

The v1alpha1 names/provider pairs are `docker-local`/`docker` and
`azure-remote-dev-env`/`azure`. Other pairs require an explicit contract/catalog
extension, not guessed combinations. Required fields are `apiVersion`, `kind`,
`metadata.name`, `spec.provider`, `spec.enabled` (boolean), `spec.config`.
Docker config is only `endpoint: local`. Azure config permits only
`subscriptionId`, `region`, `resourceGroup`, `subnetId`, `identity.method` and
optional `identity.clientId`. No `profile`, template paths, passwords, client
secrets, tokens or credential objects are accepted at any level. Nonsecret
subscription/subnet/managed-identity IDs may be committed after customer review.

Disabled Azure can contain placeholders or omit its infrastructure fields. When
enabled, it requires UUID subscription ID, region name, resource group, full
existing subnet resource ID, and `identity.method: managedIdentity`. The subnet's
subscription must match the declared subscription ID (case insensitive). An
externally owned subnet may live in a different network resource group from the
workspace `resourceGroup`. `clientId`, when supplied, must be
a UUID; omit it for system-assigned Managed Identity. The offline doctor's `--profile
Small` is an operational flag, **not** a connection field. No cloud API verifies
these references in this validator.

### Selection and non-destructive retirement

- No directory selected (unset/empty environment variable), or a selected path
  that does not exist: legacy enabled `docker-local`.
- Existing empty directory: zero selected connections; no implicit Docker.
- Existing directory: only its declarations apply; omitted Docker is not selected.
- Invalid/unreadable declarations/directory (including dangling symlinks): error,
  not legacy fallback. A private readable/searchable directory is supported.
- `enabled: false`: not selected for deployment/publishing. **Not** Azure RBAC,
  a revocation action, or removal of a published Coder template.

Omitting/disabling a connection never deletes workspaces or data. Operators must
inventory existing workspaces, explicitly restrict creation/use of the previously
published template through Coder's supported controls, communicate retirement and
arrange backup/migration before any separately approved cleanup. Configuration
selection does not automatically implement those access restrictions; do not
infer enforcement from the flag. Publishing surfaces the persisted-template risk
instead of performing destructive or presumed access-control changes.

Shared resource groups, subnets and identities are externally owned. Individual
workspace VMs/NICs/disks are implementation-managed by Coder/Terraform; declaring
a reference does not transfer ownership or authorize deletion of shared resources.

## Compatibility catalog shape

The CADE-owned `/workspace/catalog.yaml` has integer `version: 1` and
`implementations`, an ordered list of exact `environment`, `backend`, `template`,
`path` entries. Only supported combinations are listed, not a Cartesian product.
Paths are existing repository-contained Coder template directories. Environment /
backend pairs and published template names must be unique. Connection provider
and name are validated independently of which implementations currently exist.

The catalog contains four Docker rows, in the order shown above, followed by one
Azure row. Default resolution still selects exactly four Docker implementations;
Azure requires an explicit enabled connection. Existing Docker names, images,
workspace/container/home-volume names and security controls are unchanged.
`make up` remains independent of the resolver. `make templates-push` consumes the
selected catalog, building only the selected templates' Docker prerequisites;
embedded and agent images depend on the generic image build. Azure-only publishing
does not build a Docker image. Before this change, the Makefile explicitly built
and published four hardcoded Docker templates; Compose startup is unchanged.

```bash
python3 scripts/backends-config.py resolve --dir ../cade-deployment/backends
python3 scripts/backends-config.py resolve --dir ../cade-deployment/backends --format json
python3 scripts/backends-config.py resolve --dir ../cade-deployment/backends --backend docker-local
```

Text output is tab-separated `environment`, `backend`, `template`, `path`, one
entry per line, without a header. JSON output is an array of the original four-key
catalog entries. Empty selection is no text lines or `[]`, respectively; it is a
successful result, not legacy fallback. Unknown backend filters are errors. Paths
are relative to the CADE checkout, **not** to the external deployment repo or CWD.

### Importable integration API

Add the CADE `scripts/` directory to the importing program's Python module search
path and `import backend_config`. Dependencies are the same as the CLI.

- `ROOT: Path`: this product checkout, derived from the module location.
- `load_connections(directory: Path | None = None) -> dict[str, Connection]`:
  validated original declarations keyed by connection name (including disabled
  declarations); missing-directory legacy mode returns the Docker example.
- `load_catalog(root: Path = ROOT) -> list[Implementation]`: validated original
  catalog entries in source order; `root` changes catalog/template-path lookup.
- `resolve(directory: Path | None = None, root: Path = ROOT) -> list[Implementation]`:
  enabled connection selection joined to the validated catalog, in catalog order.
- `validate_connection(document: object) -> Connection`: validate and return the
  unchanged declaration. `validate_azure_config(config: ProviderConfig) -> None`:
  reusable enabled-Azure syntax/correspondence checks for a later doctor/preflight.
- `ConfigError(ValueError)`: invalid/unreadable inputs; its message is safe for
  diagnostics without printing declarations or exception tracebacks.

`Connection`, `ProviderConfig`, and `Implementation` are TypedDicts. `root` does
not replace the product schema/examples or alter environment-directory precedence.
Azure publishing translates `subscriptionId` → `subscription_id`, `region`
→ `location`, `resourceGroup` → `resource_group_name`, `subnetId` → `subnet_id`, and
optional `identity.clientId` → `managed_identity_client_id`; absent client ID uses
the implementation's empty/system-assigned default. This read-only validator
does not invoke that publishing behavior.

## Publishing and variable verification

Publishing/verification additionally needs the pinned HCL parser. Install the
publishing requirements (which include the backend requirements), then activate
the venv or set Make's `PYTHON` explicitly:

```bash
(
  set -euo pipefail
  .venv-backends/bin/python -m pip install -r scripts/requirements-template-publishing.txt
  export CADE_BACKENDS_DIR=/path/to/cade-deployment/backends
  make templates-push PYTHON="$PWD/.venv-backends/bin/python"
  make backend-templates-push BACKEND=docker-local PYTHON="$PWD/.venv-backends/bin/python"
  make templates-verify-vars PYTHON="$PWD/.venv-backends/bin/python"
)
```

The legacy target publishes the selected catalog in source order. The targeted
target requires a known, enabled connection. Docker image builds use the existing
Make targets and dirty-tree refusal; commit the relevant files before building.
Only Azure's five nonsecret connection variables are sent for Azure. Docker keeps
the existing `repo_url` override behavior. Neither operation creates Azure VMs
locally; **publishing an enabled Azure template can still run provider/data-source
operations in Coder**, so do not publish Azure until B1 prerequisites are accepted.
Use the stubbed dispatcher tests for offline Azure publication acceptance.

Both commands inspect authenticated Coder template state first. Missing/expired
authentication, an unavailable API, missing expected templates/variables, unknown
implementations, or drift fail with nonzero status. The verifier parses HCL
defaults and checks known publishing overrides; sensitive variables require secure
manual verification rather than printing their contents. An explicit empty
`variables.tf` denotes an implementation with no variables; a missing file is an
error. The standalone verifier accepts `--expected-repo-url URL`; without it,
`devcontainer.repo_url` is checked against its blank Terraform default.
Configure `CODER_URL` to the direct API-serving Coder URL: authenticated HTTP
redirects, including same-origin redirects, are rejected before forwarding the
session header. A login/proxy redirect is a configuration error, not a reason to
disable this protection.

Publishing and verification retain the existing `.env` loading behavior for
unset/empty environment values; the read-only configuration CLI reads its explicit
`--dir`/exported `CADE_BACKENDS_DIR`, not `.env`. Keep deployment selection exported
when comparing their results. No declaration directory still means legacy Docker.

### Retirement block

If an omitted/disabled backend has a catalog template visible in the server's
published-template list, **RETIREMENT BLOCK** stops publication/verification before
builds or pushes. This is intentionally conservative: it does not infer a creation
restriction from deprecated metadata, template visibility, or unverified ACLs.
Targeted publishing does not bypass this check. Keep a Docker connection explicitly
enabled if its published templates should remain usable alongside targeted Azure.

On unlicensed Coder 2.38.6, a live probe found that a successful `templates edit
--deprecated` left persisted `deprecated:false` and ordinary-member creation
returned 201. `template_rbac` was not entitled; ACL access returned 403. Therefore
do not prescribe deprecation/private CLI flags as guaranteed OSS retirement.
Inventory users/workspaces and escalate to the platform owner. Establish a tested
creation-denial control on the actual deployment, plan migration/backups and
operator-led retirement without deleting live workspaces. This tooling does not
automatically clear the conservative block after a manual ACL edit; do not claim
it has verified those permissions. An operator must resolve the publication/config
mismatch deliberately, or keep the connection selected while access is managed
separately. No automatic template/workspace/disk deletion occurs.

## Offline validation

```bash
python3 -m unittest discover -s tests -p test_backends_config.py
python3 -m unittest discover -s tests -p test_templates_push.py
python3 -m unittest discover -s tests -p test_template_vars.py
```

For acceptance, validate copies in an external temporary deployment directory.
Enable Azure with placeholder IDs: it must fail. Disable it: it must pass.
Duplicate a declaration or misspell `subscriptionId`: either must fail without
printing its value. Remove the directory: legacy Docker returns. Creating an
empty directory instead intentionally selects nothing.

References used for the parser/schema decisions:
[JSON Schema object validation](https://json-schema.org/understanding-json-schema/reference/object),
[PyYAML SafeLoader](https://pyyaml.org/wiki/PyYAMLDocumentation), and
[python-jsonschema validators](https://python-jsonschema.readthedocs.io/en/stable/api/jsonschema/validators/).
