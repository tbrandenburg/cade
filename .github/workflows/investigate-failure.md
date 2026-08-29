---
on:
  workflow_run:
    workflows: ["local-capability", "embedded-build"]
    types: [completed]
    branches: [main]

if: github.event.workflow_run.conclusion == 'failure'

engine:
  id: pi
model: copilot/gpt-5.4

permissions:
  contents: read
  actions: read
  issues: read
  copilot-requests: write

tools:
  github:
    mode: gh-proxy
    toolsets: [repos, actions, issues]
  edit:
  cli-proxy: true

network:
  allowed:
    - defaults
    - github
    - threat-detection

safe-outputs:
  create-issue:
    title-prefix: "[ci-investigation] "
    labels: [automation, ci-investigation]
    max: 1

runs-on: [self-hosted, linux, private-lab, docker]
---

# CI Failure Investigator

One of the deterministic capability workflows -
`.github/workflows/local-capability.yml` (hello-service) or
`.github/workflows/embedded-build.yml` (embedded-sim firmware) - just
failed (run `${{ github.event.workflow_run.id }}`,
${{ github.event.workflow_run.html_url }}, commit
`${{ github.event.workflow_run.head_sha }}`).

Your job is to **investigate, not fix**:

1. Inspect the failed run: its jobs, steps, and logs (use the GitHub Actions
   tools available to you — do not guess).
2. Inspect the relevant repository files referenced by the failure - e.g.
   `examples/hello-service/hello.py` / `test_hello.py` / `Makefile` for a
   `local-capability` failure, or
   `examples/embedded-sim/src/checksum.c` / `src/main.c` /
   `tests/test_checksum.c` / `Dockerfile.ci` for an `embedded-build`
   failure - to understand what changed or what the failure implies.
3. Check for any open GitHub issue describing the same regression (e.g.
   titled "Embedded simulator regression: ..." for an `embedded-build`
   failure) and reference it in your findings if one exists - do not
   create a duplicate report of an already-tracked regression, just
   correlate the two.
4. Describe the probable root cause in plain terms: what failed, why, and
   which file/line is most likely responsible.
5. Produce exactly one bounded output: a single GitHub issue (via
   `safe-outputs.create-issue`) summarizing your findings. Include the run
   URL, the failing step name, your root-cause hypothesis, and (if found)
   a reference to the related open issue from step 3.

Constraints — do not:

- Deploy anything, modify infrastructure, or touch the Docker host.
- Push commits, open pull requests, or write to any file in this
  repository.
- Take any action other than creating the single investigation issue
  described above.

If you cannot determine a root cause with confidence, say so explicitly in
the issue rather than guessing.
