# Operations — devenv-cloud

Operational runbooks not covered by the `Makefile` help text.

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
