> Gap-fill for docs/plan/steps/in-review/00101-openbao-tls-key-permissions.md

# Gap: step's deliverables never committed to git

## Why this matters

Independent re-verification of step `00101-openbao-tls-key-permissions.md`
found the on-disk fix correctly applied (`governance/openbao/certs/openbao.key`
is `640`, `scripts/openbao-gen-cert.sh` generates future keys at `640` with a
documented rationale, `docs/security.md`'s M12 section documents the
tightening) — but neither of the two files this step was supposed to modify
has ever been committed:

```
$ git status --short
 M docs/security.md
?? scripts/openbao-gen-cert.sh
$ git log --all --oneline -- scripts/openbao-gen-cert.sh
(empty)
```

Per `AGENTS.md`'s "Before trusting any 'blocker' or 'done' claim" section:
"uncommitted files don't exist for a workspace that clones from the remote
(the single biggest cause of false 'done' claims)" and "Commit + push every
deliverable as the *first* action of a step, before writing the milestone
report." A workspace/CI run that clones the repo fresh would get the
original `chmod 644` script and would be missing the key-permission
rationale from `docs/security.md` entirely — silently reintroducing the
world-readable-private-key issue this gap-fill step exists to close.

Note: this repo's broader M12 working tree also has many other unrelated
untracked/modified files (`governance/`, other `scripts/openbao-*.sh`,
`mcp/lab-sim/...`, etc.) — those are out of scope for this gap (they belong
to milestone `00100-governance-foundation.md` and other steps, not this
one). This gap is scoped strictly to the two files `00101` itself touched.

## Fix

1. `git add scripts/openbao-gen-cert.sh docs/security.md`.
2. Commit with a message describing the TLS private-key permission
   tightening (e.g. `fix(governance): tighten OpenBao TLS key to 0640`).
3. Push the commit.
4. Confirm via `git log --oneline -- scripts/openbao-gen-cert.sh` and
   `git diff origin/<default-branch> -- docs/security.md` that both files
   are now present in the remote history, not just the local working tree.
