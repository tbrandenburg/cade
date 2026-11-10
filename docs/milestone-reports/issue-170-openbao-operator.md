# Issue #170 — OpenBao operator and isolated recovery evidence

Coordinator verification: 2026-11-09 on branch `fix/issue-170-openbao-operator`.
Scope: bootstrap/operator administration and stopped copied-storage recovery,
not an upgrade or recovery of the running deployment.

## Root cause and correction

The initial root was revoked without provisioning another usable writer.
`devenv-cloud-read` only permitted reads, while forced rotation could return
success after finding revoked root. The old bootstrap/re-unseal paths also
bypassed TLS and supplied secrets in subprocess arguments; rotation used a
fixed plaintext temporary file.

The shell entry points now share a small standard-library Python helper
using the installed `bao` CLI, verified mounted CA trust, stdin-only token
and JSON transport, owner-only private input, and bounded subprocess calls.
No additional Python dependency, service, normal listener change, or Compose
change is required. Existing data-directory ownership is no longer modified.

One fixed built-in userpass account, `cade-operator`, receives only
read/create/update at `secret/data/devenv-cloud/*`. Its sessions are
five-minute non-renewable batch tokens with no default policy. Bootstrap
verifies fresh login and stored writes before revoking root. Ordinary runs
only unseal; explicit resume and forced operator-authenticated rotation are
separate modes. Existing administrators can provision the operator without
rotating stored credentials or revoking their own token.

## Research used before implementation

- Context7 resolved `/websites/openbao` and queried userpass token-policy,
  TTL, and login configuration. Returned material included 2.5 documentation,
  so the actual contract was checked against official 2.6 documentation and
  pinned 2.6.5 source.
- [2.6 userpass API](https://openbao.org/docs/2.6.x/api/auth/userpass/)
- [2.6 legacy root generation](https://openbao.org/docs/2.6.x/api/system/generate-root/)
- [2.6 authenticated root generation](https://openbao.org/docs/2.6.x/api/system/generate-root-token/)
- [Pinned listener defaults](https://github.com/openbao/openbao/blob/v2.6.5/website/content/docs/configuration/listener/tcp.mdx)
- [Pinned root-token decoding](https://github.com/openbao/openbao/blob/v2.6.5/sdk/helper/roottoken/decode.go)
- [Pinned token implementation](https://github.com/openbao/openbao/blob/v2.6.5/vault/token_store.go)
- Adversarial follow-up: Context7 `/openbao/openbao` queried Agent address
  precedence, redirects, token helpers, and cache configuration. Cross-checked
  [2.6 CLI configuration](https://openbao.org/docs/2.6.x/commands/) and
  [pinned CLI client construction](https://github.com/openbao/openbao/blob/v2.6.5/command/base.go)
  before hardening the in-container environment.

Live CLI details found and accounted for: `bao write` wraps raw system
responses in `data`, omits `auth.token_type` from its serialized login
response, and quorum output uses unpadded base64. Disabled legacy endpoints
return 405; unauthenticated authenticated-root endpoints return 403. Wrong
userpass credentials return 400 before lockout and 403 while locked out.

## Commands and observed results

Run from the repository root:
Ruff 0.14.6 was invoked using `/tmp/opencode/cade-170-validation/bin/ruff`;
the unit-test Python below is from the same validation environment.

```bash
bash -n scripts/openbao-init.sh scripts/openbao-reunseal.sh
shellcheck scripts/openbao-init.sh scripts/openbao-reunseal.sh
actionlint .github/workflows/openbao-check.yml
ruff check --select E,F,I,B,UP,SIM,C90 --config 'lint.mccabe.max-complexity=10' \
  scripts/openbao_admin.py scripts/openbao_client.py scripts/openbao_recover_operator.py \
  scripts/tests/openbao_tls_fixture.py scripts/tests/openbao_tls_e2e.py \
  scripts/tests/openbao_redirect_e2e.py \
  scripts/tests/test_openbao_private_input.py
ruff format --check \
  scripts/openbao_admin.py scripts/openbao_client.py scripts/openbao_recover_operator.py \
  scripts/tests/openbao_tls_fixture.py scripts/tests/openbao_tls_e2e.py \
  scripts/tests/openbao_redirect_e2e.py \
  scripts/tests/test_openbao_private_input.py
/tmp/opencode/cade-170-validation/bin/python -m unittest discover -s scripts/tests -p test_openbao_private_input.py -v
python3 scripts/tests/openbao_tls_e2e.py
git diff --check
```

- Bash syntax, ShellCheck, and focused workflow Actionlint: exit 0, no findings.
- Ruff: `All checks passed!`; `7 files already formatted`.
- Private-input tests: `Ran 9 tests in 0.115s ... OK` (permissions,
  no overwrite, retained initialization descriptor under path replacement,
  unsafe parent rejection before initialization, invalid/oversized/multiline
  input, FIFO/symlink refusal, damaged/unsafe journal rejection, and exact
  normal-listener denial statuses with transport/server-failure rejection).
- Final coordinator real Docker rerun: `Ran 3 tests in 144.354s ... OK`:
  - `PASS bootstrap, root revocation, TLS, scoped writes, rotation/unseal`
  - `PASS failed provisioning/login resume, read-only denial, copied-storage recovery`
  - `PASS failed recovery revoke retained privately; retry invalidated original root`
  - `PASS verified-TLS password request refused redirect; HTTP sink received zero requests`
- The recovery recipe's extracted Bash passed `bash -n` and ShellCheck;
  its two embedded Python blocks compiled successfully.
- `git diff --check`: exit 0.
- Final exact-name-prefix Docker inventory: **0 owned test containers remain**.

Coordinator regression gates, executed from this worktree:

```bash
/tmp/opencode/cade-170-validation/bin/python -m unittest discover -s scripts/tests -p 'test_*.py' -v
TERRAFORM=/tmp/opencode/cade-139/terraform /tmp/opencode/cade-170-validation/bin/python -m unittest discover -s tests -v
node --test scripts/tests/headless-agent-host.test.mjs
ruff check --select E4,E7,E9,F,C901 scripts/backend*.py scripts/backends-config.py scripts/templates_push.py scripts/template_vars.py scripts/doctor_azure.py tests
ruff format --check scripts/backend*.py scripts/backends-config.py scripts/templates_push.py scripts/template_vars.py scripts/doctor_azure.py tests
```

Results: **68 scripts tests passed** in 209.192s, **59 backend/catalog tests
passed** in 88.572s, **14 Node tests passed**, and the existing backend CI
lint/format checks passed (17 files formatted). The backend tests used their
declared template-publishing dependencies and Terraform 1.14.5. Initial
missing-dependency/tool and short-budget/concurrent timeout failures cleared
after environment setup and sequential reruns; no unrelated defect was
established. No dedicated typecheck target is configured for these helpers.
The destructive full-platform M16 scenario was not run on this shared host.

## Real Docker coverage and containment

Tests run OpenBao **2.6.5**, asserting the server version, using generated
test certificates and fresh dummy file-backend storage. Each uniquely named
container runs as the invoking non-root UID, drops capabilities, disallows
new privileges, uses `--network none`, and publishes no ports. `ss -ltn`
is checked without binding or disturbing existing services. Optional
integration environment sources are isolated from the deployment's `.env`.
Test subprocess output is checked for password/token/share leakage.
The redirect test additionally uses the local `nginx:1.27-alpine` image,
with the real 2.6.5 CLI copied from its owned OpenBao container. That owned
non-root, capability-dropped, portless container returns a real TLS HTTP 307
to an HTTP sink within the same isolated namespace; the TLS log confirms
the password request reached the redirect listener and the sink log stays
empty. No request bodies or authentication headers are logged.

The executable scenarios check missing CA and wrong hostname rejection,
root revocation (HTTP 403), fresh operator create/update/read, exact second
value/version without printing it, read-only write denial, out-of-prefix
write denial, auth/token creation denial, missing/wrong forced-rotation
credentials without changed versions, correct stdin password rotation, and
the actual automatic re-unseal entry point preserving stored versions.

Resume is tested with a real restricted credential failing provisioning and
an actually locked user failing fresh login. The valid bootstrap root stays
usable until an explicit successful resume revokes it. Existing-admin
provisioning is also exercised through the supported entry point.

The recovery scenario removes the usable userpass account, revokes its last
known administrator, stops the disposable source, copies its backend, and
preserves the original separately. Only the copy enables the legacy quorum
setting. The actual recovery helper verifies isolation, submits matching
shares privately, journals its temporary root privately before provisioning,
provisions/verifies the operator, revokes root, and verifies HTTP 403 with
that root. The copy is then
restarted with the repository's normal configuration; fresh operator writes
work, legacy unauthenticated generation returns 405, and authenticated root
generation without a login returns 403. The original backend fingerprint
is unchanged. No existing platform container, volume, credential, or host
configuration was changed.

The E2E is deliberately opt-in (`openbao_tls_e2e.py`, not `test_*.py`);
scoped unittest discovery does not start Docker or traverse `.worktrees/`.

## Adversarial findings addressed

1. **Inherited CLI configuration:** `docker exec` starts `env -i` inside
   the container, allowing only the selected HTTPS address/CA, fixed timeout,
   disabled redirects/retries, disabled cache/config, and stdin token. The
   real fixture inherits HTTP Agent addresses in both BAO/VAULT namespaces,
   TLS bypass flags, a false redirect setting, an incorrect TLS server name,
   a poisoned config, and a valid privileged token cache. Verified TLS
   operations still work; wrong CA/hostname and unauthenticated privileged
   calls still fail. The separate real redirect regression confirms no
   password request follows a redirect to HTTP.
2. **Initialization destination:** owned/non-group-or-world-writable parent
   validation and a pinned directory descriptor precede exclusive creation.
   The same file descriptor stays open across initialization and share
   persistence. A unit regression renames the destination and replaces it
   with a symlink during initialization: retained private output receives
   the synthetic root/shares and the target remains unchanged. A real
   server rejects a mode-777 output parent without initializing.
3. **Failed recovery-root revocation:** an owner-only, no-follow, locked
   `.recovery-pending` journal is durably prepared before quorum; the root
   is saved there before provisioning. Failed revoke retains that handle.
   A retry verifies/revokes the pending root before issuing another, and
   success clears the journal only after verified revocation. Real fault
    injection seals the real server before final revoke (no canned error);
    after rotation-free unseal, the first root is proven usable before
   retry and rejected with 403 afterward. Unsafe, malformed, empty, and
   unresolved-generating journals block recovery rather than reset state.
4. **Runbook denial oracle:** the shared normal-listener check requires
   exactly legacy 405 and authenticated 403; transport/TLS, 500, unexpected
   status, and successful requests do not count as denial evidence.

Harness setup corrections during validation: binary discovery now uses the
owned container's real CLI path; the non-root redirect listener uses private
temporary paths. Its default HTML redirect body produces a CLI parse error,
so acceptance checks the actual TLS 307 request log plus zero HTTP sink
requests rather than interpreting a generic client error as evidence.

## Regression gates and quality scope

The focused `openbao-check` workflow runs shell checks, Ruff format/complexity,
nine private-input tests, and the real TLS/recovery drill on hosted Ubuntu
when OpenBao source/tests/config change. It has read-only repository access,
15-minute job and eight-minute E2E budgets, and needs no deployment secrets.
It does not repeat the unrelated backend or workspace-image suites.

Scoped quality-drift assessment (not a repository-wide audit): runtime gates
6/10, test-size/ratio 2/10, source-size 2/10, complexity 8/10, branch coverage
0/10, mutation testing 0/10. The seven Python files have a largest source
file of 249 lines and a largest test file below 310 lines; tests and fixture
support are below twice the helper-source size. No test monster or complexity
violation was found in the changed scope. File-size warnings in CI would be
a small future improvement; coverage/mutation infrastructure is deferred for
this solo sandbox rather than added to a credential-recovery fix.

## Remaining boundaries / follow-up

- Runtime evidence is disposable, not proof the existing deployment has
  been migrated. Deployment/cutover remains a separate approved operation.
- A crash/lost response between quorum completion and durable token save
  leaves a `generating` marker. Automatic retry/cutover deliberately stops;
  preserve both backends and reconcile generated root accessors using
  quorum-authorized administration on the isolated copy. Do not delete the
  journal to bypass this safeguard. Disk failure after initialization or
  root issuance requires manual recovery, not a success claim.
- Rotation changes stored records, not live service credentials; reconcile
  consumers privately. Repeated explicit resume can rotate stored versions
  again. Partial multi-record rotation is not transactional.
- Legacy `scripts/backup.sh` / `scripts/restore-test.sh` remain outside this
  change: they retain TLS bypass/secret-argument patterns, and the M14
  disposable backup harness combines storage and init material. See the
  updated disaster-recovery warning: never retain that combined artifact as
  an operational backup. Store encrypted backend, shares, and operator
  password separately. Follow-up [#185](https://github.com/tbrandenburg/cade/issues/185)
  tracks hardening those legacy helpers; they were not modified here.
  inspection reproduction: `grep -nE 'BAO_SKIP_VERIFY|tls-skip-verify|init.json|operator unseal' scripts/backup.sh scripts/restore-test.sh`.
- Independent adversarial review identified three high and one medium
  finding, then confirmed those four findings resolved after focused fixes.
  Its remaining low documentation inconsistency about the temporary root
  journal was corrected in the security document. Credential administration
  and recovery remain high-risk; leave the PR for maintainer review.
