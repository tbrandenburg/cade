> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Gap-fill for 00101-m0-host-milestone-report

## Why this matters

Step `00101-m0-host-milestone-report` was itself a gap-fill step whose entire
purpose was to create `docs/milestone-reports/M0-host.md`. Independent review
confirms:

- `scripts/doctor.sh` and `make doctor` work correctly (re-run independently:
  13/13 checks PASS, exit code 0).
- `docker run --rm hello-world` works correctly (re-run independently: exit
  code 0, expected "Hello from Docker!" output).
- **`docs/milestone-reports/M0-host.md` still does not exist on disk** (the
  `docs/milestone-reports/` directory is empty).

Step 00101 was moved to `in-review` without producing its own required
deliverable. `doc/plan/plan.md`'s final checklist lists this report as a
required artifact for M0 completion, and `docs/INITIAL.md` Rule 2 requires an
evidence-standard report (exact commands, full output, exit codes, timestamp)
before M0 can be considered complete. Without this file, M0/Phase 1 is not
actually done despite the underlying tooling being correct.

## Actions

1. Create `docs/milestone-reports/M0-host.md` containing, per the evidence
   standard in `docs/INITIAL.md` Rule 2:
   - OS version, Docker version, Docker Compose version, hostname, CPU, RAM,
     free disk space (capture with `hostnamectl`/`uname -a`, `docker
     --version`, `docker compose version`, `free -h`, `df -h`, `nproc`, etc.)
   - The exact commands run, in full.
   - Full output and exit codes for:
     - `docker run --rm hello-world`
     - `make doctor` (must show all checks PASS and exit 0)
   - A timestamp of when the evidence was captured.
   - If execution happens in a non-rebootable sandbox/container (as opposed to
     a real, rebootable target host), state this explicitly as a documented
     constraint rather than silently omitting the reboot step.
2. Commit the file.
3. Only then mark Phase 1 / M0 as complete in any tracking checklist.
