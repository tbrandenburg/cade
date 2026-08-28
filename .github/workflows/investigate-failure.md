---
on:
  workflow_run:
    workflows: ["local-capability"]
    types: [completed]
    branches: [main]

if: github.event.workflow_run.conclusion == 'failure'

engine:
  id: pi
model: copilot/gpt-5.4

permissions:
  contents: read
  actions: read
  copilot-requests: write

tools:
  github:
    mode: gh-proxy
    toolsets: [repos, actions]
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

The deterministic `local-capability` workflow (`.github/workflows/local-capability.yml`)
just failed (run `${{ github.event.workflow_run.id }}`,
${{ github.event.workflow_run.html_url }}, commit
`${{ github.event.workflow_run.head_sha }}`).

Your job is to **investigate, not fix**:

1. Inspect the failed run: its jobs, steps, and logs (use the GitHub Actions
   tools available to you — do not guess).
2. Inspect the relevant repository files referenced by the failure (e.g.
   `examples/hello-service/hello.py`, `examples/hello-service/test_hello.py`,
   `examples/hello-service/Makefile`) to understand what changed or what the
   failure implies.
3. Describe the probable root cause in plain terms: what failed, why, and
   which file/line is most likely responsible.
4. Produce exactly one bounded output: a single GitHub issue (via
   `safe-outputs.create-issue`) summarizing your findings. Include the run
   URL, the failing step name, and your root-cause hypothesis.

Constraints — do not:

- Deploy anything, modify infrastructure, or touch the Docker host.
- Push commits, open pull requests, or write to any file in this
  repository.
- Take any action other than creating the single investigation issue
  described above.

If you cannot determine a root cause with confidence, say so explicitly in
the issue rather than guessing.
