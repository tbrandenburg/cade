# Backend contract and offline Azure preparation — #136–#140

Status: scoped offline and Docker/Coder validation passed; human desktop acceptance
remains pending. Azure runtime is **NOT LIVE TESTED**.
Last coordinator verification: 2026-11-09T08:07:45+01:00.

## Scope and ownership

- #136/#137: strict external BackendConnection declarations, offline validation,
  and the four unchanged Docker environment/template mappings.
- #138: catalog-selected publication/verification and visible retirement risk.
- #139: one additive `generic-linux-azure` template, static validation only.
- #140: non-mutating offline doctor and existing-infrastructure owner handoff.

Foundation work preceded parallel publisher/template/onboarding work in isolated,
gitignored `.worktrees/` directories. The coordinator owns integration and final
verification. Existing unrelated worktrees and running platform services are not
test teardown targets. Coder/Terraform remains the lifecycle engine.

## Baseline and safety checks

`git remote -v` showed only `origin`, pointing to `tbrandenburg/cade`; this is not
a fork/upstream workflow. The initial coordinator tree was clean. `ss -ltnp`
confirmed the live Coder listener on 7080 and existing application listeners on
3000/5173 before any test service was started. Tests reserve loopback port 0.

The healthy Coder 2.38.6 deployment and matching CLI were reused. Expired
authentication was replaced by a temporary validation token; a temporary bootstrap
admin was removed using a separate existing-owner token. No user CLI config was
changed and secret values were not printed. Azure authentication was not used.

`make doctor` reported **13 passed, 2 failed**: 44 GB free (<100 GB baseline) and
7080 occupied by the existing Coder instance. Its AppArmor warning did not prove
a runtime blocker: an actual new Docker workspace started with
`AppArmorProfile=cade-bwrap-workspace`. No security profile was weakened or loaded
by this work. The inspection-warning distinction is tracked separately in #133.

Baseline commands:

```text
python3 -m unittest discover -s tests -v
  5 tests, OK (before backend additions)
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
  59 tests, OK, 214.264s
uv run --project temporal --frozen pytest temporal/tests -q
  15 passed in 0.66s
```

The first script-suite invocation exceeded its 120-second tool limit and was
inconclusive. A repeat with a 360-second tool limit produced the summary above.
The running stack uses an explicit deployment project, not the checkout's default;
its labels were verified before `COMPOSE_PROJECT_NAME=<verified-project> make status`
showed 21 running services. No `make up`/stack recreation was needed or performed.

## Live retirement experiment

A disposable Coder-only Terraform template (no VM/container resources) isolated
this check from existing Docker templates:

```bash
coder templates push backend-retirement-qa -d <disposable-template> --yes
coder templates edit backend-retirement-qa --deprecated '<retirement message>' --yes
```

The edit reported success. The real template API still returned
`deprecated:false` and an empty `deprecation_message`; an ordinary temporary member's
`POST /api/v2/users/me/workspaces` returned **201**, creating a real workspace.
`GET /api/v2/entitlements` reported `has_license:false` and
`template_rbac.entitlement:not_entitled`, `enabled:false`; template ACL GET returned
**403**. Therefore this deployment does not establish a per-template retirement
boundary through that CLI flag. Selection is not access revocation.

Both probe workspaces, the temporary member and probe template were deleted
through the Coder API. No existing workspace or persistent volume was removed.

## Unrelated finding

The pre-change workspace image's default sandbox settings were root-owned `0600`.
Real `coder ssh backend-docker-qa` reached the agent but reported startup failure:

```text
cp: cannot open '/etc/cade/srt-settings.default.json' for reading: Permission denied
```

This image-packaging permission dependence is tracked in
[#164](https://github.com/tbrandenburg/cade/issues/164), with reproduction and exact
logs. It is not repaired by changing the existing Dockerfile in this scope.
The required clean image rebuild and subsequent live check will determine whether
the readable checkout source resolves the stale image instance.

## Remaining verification

Human desktop VS Code acceptance remains pending; it is not implied by Coder SSH.
Live Azure identity/networking/lifecycle/profile approval remains in #141–#143.
This PR is not an Azure runtime completion claim and should not be auto-merged.

## Integrated offline validation

The initial combined 54-test run reported 29 assertion failures in publisher
fixtures: the expanded catalog referenced a template the fixture had not copied,
and a helper appended a duplicate Azure pair. The scoped correction materializes
catalog paths and replaces the Azure entry without weakening validation. Two
foundation assertions were updated to distinguish the five-row catalog from the
four-row default Docker selection.

Coordinator commands/results:

```bash
uv venv .venv-backends
uv pip install --python .venv-backends/bin/python -r scripts/requirements-template-publishing.txt
PATH="$PWD/.venv-backends/bin:$PATH" TERRAFORM=<terraform-1.14.5> \
  python3 -m unittest discover -s tests -q
# Ran 54 tests in 143.749s; OK (concurrent image-build load)
ruff check --select E4,E7,E9,F,C901 scripts/backend*.py scripts/backends-config.py scripts/templates_push.py scripts/template_vars.py scripts/doctor_azure.py tests
# All checks passed!
ruff format --check scripts/backend*.py scripts/backends-config.py scripts/templates_push.py scripts/template_vars.py scripts/doctor_azure.py tests
# 13 files formatted correctly
shellcheck scripts/doctor-azure.sh scripts/verify-template-vars.sh coder/templates/generic-linux-azure/mount-home.sh
# exit 0
terraform -chdir=coder/templates/generic-linux-azure fmt -check
terraform -chdir=coder/templates/generic-linux-azure init -backend=false -input=false -lockfile=readonly
terraform -chdir=coder/templates/generic-linux-azure validate -no-color
# init succeeded; Success! The configuration is valid.
```

Terraform was extracted from the existing 1.14.5 validation image to a private
temporary tool path. No Azure plan/apply/login or API access occurred. Tests run
actual Terraform expressions and cloud-init rendering in empty local directories.
There is no repository Python typecheck target/configuration; Ruff and runtime
imports were checked, not represented as a static typecheck.

A separate disposable `infrastructure/` + `cade-deployment/` Git-repository
rehearsal used fictional IDs with Azure/runtime credentials removed from the
environment. Twelve CLI/doctor invocations produced the expected outcomes:
valid examples/default Docker, disabled placeholders, enabled cross-RG references,
and rejection of enabled placeholders, unapproved profile, subscription mismatch,
inline password, missing RG, typo and duplicate declarations. Removing the directory
restored four-row legacy selection.

Against the real Coder server, a disabled Docker declaration produced
`RETIREMENT BLOCK` listing the four published Docker templates before builds or
pushes. `make -n up` output was byte-identical with/without that declaration.
The four original Terraform template directories and `compose.yaml` have zero diff.

Additional regression checks: Temporal **15 passed** (1.56s), hello-service
**3 passed**, and headless Agent Host unit tests **14 passed, zero skipped**.
The installed-client/manual Microsoft-host suite requires separate private
provisioning and is not claimed as executed by this backend change.

## Adversarial review and focused correction

The independent review found **critical 0, high 1, medium 1, low 0**. Its high
finding was reproduced independently: default urllib redirect handling forwarded
the synthetic Coder session header to another loopback origin. No real token was
used in the reproduction. The medium finding was a workflow path filter that
covered the doctor wrapper but missed `scripts/doctor_azure.py`.

A focused fixing agent added a client-local redirect rejection handler, real HTTP
regression tests for 301/302/303/307/308 and same/cross-origin destinations, direct
success/401/403 checks, and explicit doctor implementation paths in both workflow
filters. Redirect rejection occurs before the destination request, not after a
final-URL check. Operators must configure a direct Coder API URL; same-origin
redirects intentionally fail too. Independent re-review reported remaining
**critical 0, high 0, medium 0, low 0**, with 59 tests passing. The coordinator's
final root run passed **59 tests in 123.444s**; the final script regression run
passed **59 tests in 303.990s**. Ruff lint/complexity passed, **14 Python files**
passed format checking, ShellCheck passed and Terraform validation remained valid.

## Real Docker/Coder end-to-end evidence

No configuration directory was set in either the environment or `.env`. With a
temporary authenticated session and the publishing venv:

```bash
make templates-push PYTHON="$PWD/.venv-backends/bin/python"
# PUSHED docker-workspace
# PUSHED embedded-linux
# PUSHED devcontainer
# PUSHED agent-workspace
# Published 4 selected template(s).
make templates-verify-vars PYTHON="$PWD/.venv-backends/bin/python"
# PASS: 4 selected template(s) match expected variables.
```

This ran the four real image builds through the unchanged Make targets, then
imported/published the templates using real Coder/Terraform jobs. The readonly
catalog/doctor never initiated those jobs. A second publication used an explicit
external enabled Docker declaration:

```bash
CADE_BACKENDS_DIR=<external-deployment>/backends \
  make backend-templates-push BACKEND=docker-local PYTHON="$PWD/.venv-backends/bin/python"
# four cached image builds; four original template names pushed; no duplicates
```

Between runs, a real publish deliberately set
`devcontainer.repo_url=https://example.invalid/backend-drift.git`. Verification
failed nonzero with `DRIFT repo_url`. Targeted republication restored the intended
repository URL; verification passed again. Azure remained unselected/unpublished.
Automated dispatcher tests separately exercise the permitted offline stub-Azure
flow and assert zero Docker build calls.

Real workspaces were created with every rich parameter explicit and optional
integrations disabled, then updated to the newly published template versions:

```bash
coder create backend-docker-qa --template docker-workspace --yes \
  --parameter repo_url= --parameter github_token= --parameter agent_capable=false \
  --parameter temporal_owned=false --parameter enable_jupyter=false \
  --parameter enable_nodered=false --parameter enable_omnigent=false \
  --parameter omnigent_admin_username=admin --parameter omnigent_admin_password=
coder create backend-embedded-qa --template embedded-linux --yes \
  --parameter repo_url= --parameter github_token= --parameter agent_capable=false
coder update <workspace> --use-parameter-defaults
coder ssh --wait yes <workspace> -- 'sha256sum /home/coder/backend-qa-marker'
coder stop <workspace> --yes
coder start <workspace> --yes
coder ssh --wait yes <workspace> -- 'sha256sum /home/coder/backend-qa-marker'
```

Both template-specific tests passed: agent `connected`/lifecycle `ready`, the
marker hash remained byte-exact, container ID changed, home-volume name remained
stable and the AppArmor profile remained `cade-bwrap-workspace`. Docker marker
SHA-256 was `66ce79d8a9f3caff724f36fb45cf176d9f6c796f1915e7c630be1f110aa7413b`;
embedded marker was `e2ea7ccffe7824303c4c2dd221b4320f16e6546a20e72d27dbf57d4bd3b11764`.
The readable-source rebuild resolved the stale-image startup instance described
in #164; the underlying packaging-permission dependence remains that issue's scope.

### Scoped cleanup and preservation

Both test workspaces were deleted through Coder; their exact home volumes were
verified absent. Before restoring the four original active template versions, the
live source archives were compared against this checkout to reject an unrecognized
concurrent edit. Original active versions and four original workspace image tags
were then restored. Restored deployment variable verification passed; exactly four
unique Docker templates remained and no Azure template had been published. Test
template versions remain as inactive audit history rather than deleting history.

The validation token was expired; a real API request then returned **401**, and
the secret file was removed. Probe users/templates/workspaces were cleaned up.
No global Docker prune, platform restart, user CLI config modification, unrelated
worktree removal or termination of pre-existing processes occurred.

## Scoped quality-drift check

This scores **gate availability for the backend change**, not correctness or
coverage percentages. Existing repository-wide gate work is tracked in #158.

| Dimension | Score | Evidence / gap |
| --- | --- | --- |
| Suite runtime | 2/10 | Timed results exist; CI has a 15-minute job cap, no dedicated suite/per-file warning |
| Test size/ratio | 2/10 | Six changed test files are below 500 lines; approximately 2.2 test/source LOC ratio, no ratchet |
| Source size | 2/10 | Eight backend Python modules below 200 lines; manual check, no size gate |
| Complexity | 8/10 | CI runs Ruff C901 with default limit 10 as an error; local check passed |
| Branch coverage | 0/10 | No branch-coverage gate configured for these scripts; coverage was not measured |
| Mutation testing | 0/10 | No mutation gate configured; mutation effectiveness was not measured |
| Overall | 2.3/10 | Correctness evidence is separate from these missing quality metrics |

Prioritized follow-ups, outside the selected feature scope:

- **Critical, cheap:** suite-runtime and file-size warning annotations in PR CI
  (15–30 minutes, warning-first; do not block existing baselines).
- **High:** a measured branch-coverage baseline/ratchet for backend scripts
  (1–2 hours, PR CI; do not infer coverage from test count).
- **Medium:** a bounded weekly mutation check (1–2 hours setup plus measured run
  cost), once the existing validation-gate work in #158 establishes ownership.

Strengths in this change: source modules remain small, tests exercise the real
CLI and HTTP boundary, Terraform expressions are evaluated rather than copied as
expected logic, and real Coder lifecycle tests supplement offline fixtures.
