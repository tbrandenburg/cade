# Backend contract and offline Azure preparation — #136–#140

Status: integration validation in progress. Azure runtime is **NOT LIVE TESTED**.
Last evidence collection began 2026-11-09 (local offset +01:00).

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

Integrated offline checks, live catalog publishing/drift/persistence validation,
adversarial review and cleanup are recorded below when completed. Human desktop
VS Code acceptance is not implied by Coder SSH or Terraform static validation.
