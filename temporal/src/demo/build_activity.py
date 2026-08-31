"""Issue #5 Activity: run a real build/test command inside an ephemeral
container built from a predefined workspace image (e.g.
`cade/coder-workspace:latest`), so a durable Temporal workflow can prove it
ran "in a predefined workspace with build tools installed" rather than only
calling the lab-sim MCP capability (`demo/e2e_activities.py`).

Deliberately minimal (MVP slice of the issue's larger plan, see AGENTS.md /
the issue's "Implementation Plan" section): one Activity, one container run,
no volume mounts of host paths, no image build step. Gap-fill: authorization
is now gated by OPA's `build.authz` policy (`governance/opa/policy/
build_authz.rego`), mirroring `mcp/lab-sim/src/lab_sim/policy.py`'s pattern
— evaluated live via OPA's decision API, fail-closed on deny or on any
transport error (never fail open on a privileged action). Uses its own
Docker daemon connection (`BUILD_DOCKER_HOST`, see `demo/config.py`) that is
intentionally separate from anything else this worker may reach.
"""

import re

import docker
import httpx
from docker.errors import ImageNotFound
from temporalio import activity

from demo.config import BUILD_DOCKER_HOST, OPA_URL

OPA_DECISION_PATH = "/v1/data/build/authz/allow"

# Issue #8 gap-fill: docker-py's `containers.run(..., remove=True)` (with
# the default `detach=False`) removes the container client-side, AFTER
# `container.wait()` returns — it does NOT set the daemon-side
# `AutoRemove` flag (verified by reading docker-py's own source: that
# path is only taken when `detach=True`). If this Activity's process
# (i.e. `temporal-worker`) is killed between `container.start()` and the
# final `container.remove()` call — e.g. a mid-Activity worker
# crash/restart — the container is orphaned on the Docker daemon side;
# nothing else ever cleans it up. Every container this Activity starts is
# labeled with a key stable across Temporal retry attempts of the *same*
# Activity task (workflow ID + Activity ID, not the attempt number), so a
# retried attempt can find and remove its own previous attempt's
# leftover container before starting a new one.
LABEL_KEY = "cade.build-activity.task-key"


def _task_key() -> str:
    """A key stable across retries of one Activity task (same workflow +
    same Activity ID), but unique per Activity invocation site."""
    info = activity.info()
    raw = f"{info.workflow_id}-{info.activity_id}"
    # Docker label values allow arbitrary strings, but keep it simple/safe.
    return re.sub(r"[^A-Za-z0-9_.-]", "_", raw)[:255]


def _reap_previous_attempt(client: docker.DockerClient, task_key: str) -> None:
    """Best-effort cleanup of any container left behind by a previous,
    crashed attempt of this same Activity task. Never raises — a failure
    here must not block the current attempt from running."""
    try:
        stale = client.containers.list(
            all=True, filters={"label": f"{LABEL_KEY}={task_key}"}
        )
        for container in stale:
            activity.logger.warning(
                "run_build_command: reaping orphaned container %s from a "
                "previous attempt of task_key=%s",
                container.id,
                task_key,
            )
            container.remove(force=True)
    except docker.errors.APIError as exc:  # noqa: BLE001 - best-effort only
        activity.logger.warning(
            "run_build_command: orphan-container reap failed (non-fatal): %s",
            exc,
        )



def _opa_allows(image: str, command: list[str]) -> bool:
    """Query OPA's decision API for `build.authz.allow`. Fails closed: any
    transport error, timeout, or non-boolean-true result is treated as a
    denial (mirrors `lab_sim.policy.check_allowed`)."""
    payload = {"input": {"image": image, "command": command}}
    try:
        response = httpx.post(f"{OPA_URL}{OPA_DECISION_PATH}", json=payload, timeout=5.0)
        response.raise_for_status()
        result = response.json().get("result")
    except httpx.HTTPError:
        return False
    return result is True


def _run_in_persistent_container(
    client: docker.DockerClient,
    container_name: str,
    command: list[str],
    workdir: str,
) -> dict:
    """Issue #49: run `command` via `docker exec` against an already-
    existing, still-`running` container (a real, pre-created Coder
    workspace, e.g. `coder-<owner>-<workspace>`) instead of creating/
    removing a throwaway one. Workspace lifecycle (create/stop/start/
    delete) stays entirely manual/out-of-band — this never starts, stops,
    or removes the target container. Fails closed with a structured error
    dict (never raises) if the container doesn't exist or isn't running,
    mirroring the ephemeral path's error-handling contract."""
    try:
        container = client.containers.get(container_name)
    except docker.errors.NotFound:
        return {"ok": False, "error": f"container not found: {container_name!r}"}
    except docker.errors.APIError as exc:
        return {"ok": False, "error": f"docker API error resolving container: {exc}"}

    if container.status != "running":
        return {
            "ok": False,
            "error": (
                f"container {container_name!r} is not running "
                f"(status={container.status!r})"
            ),
        }

    try:
        exit_code, (stdout, stderr) = container.exec_run(
            command, workdir=workdir, demux=True
        )
    except docker.errors.APIError as exc:
        return {"ok": False, "error": f"docker API error during exec: {exc}"}

    output = (stdout or b"") + (stderr or b"")
    activity.logger.info(
        "run_build_command: container=%s command=%s -> exit_code=%s",
        container_name,
        command,
        exit_code,
    )
    return {
        "ok": exit_code == 0,
        "exit_code": exit_code,
        "output": output.decode("utf-8", errors="replace"),
    }


@activity.defn(name="run_build_command")
async def run_build_command(
    image: str,
    command: list[str],
    workdir: str = "/workspace",
    container_name: str | None = None,
) -> dict:
    """Run `command` inside a short-lived container from `image`, capture
    stdout/stderr and the exit code, then remove the container. Fails
    closed: any Docker-level error (missing image, daemon unreachable,
    etc.) is returned as a structured error dict rather than raised, so a
    bad `image`/`command` input surfaces as a clear workflow result instead
    of an opaque Activity exception with a Temporal retry storm behind it.
    Also fails closed if OPA denies the request or is unreachable.

    Issue #49: when `container_name` is given, the command runs via
    `docker exec` against that already-existing, already-running
    container (a real, pre-created Coder workspace) instead of spinning
    up/removing an ephemeral one. `image` is still required and still
    passed through the same OPA `build.authz` check in this mode — it is
    used purely for the authz decision (mirroring what would normally run
    in that workspace), not to create anything. When `container_name` is
    None (default), behavior is completely unchanged from before this
    issue.
    """
    if not _opa_allows(image, command):
        activity.logger.warning(
            "run_build_command: denied by OPA build.authz policy image=%s command=%s",
            image,
            command,
        )
        return {"ok": False, "error": f"denied by build.authz policy for image={image!r}"}

    try:
        client = docker.DockerClient(base_url=BUILD_DOCKER_HOST)
    except Exception as exc:  # noqa: BLE001 - fail closed, see docstring
        return {"ok": False, "error": f"docker client init failed: {exc}"}

    if container_name is not None:
        try:
            return _run_in_persistent_container(client, container_name, command, workdir)
        finally:
            client.close()

    task_key = _task_key()
    _reap_previous_attempt(client, task_key)

    try:
        try:
            client.images.get(image)
        except ImageNotFound:
            return {"ok": False, "error": f"image not found locally: {image}"}

        try:
            output = client.containers.run(
                image,
                command=command,
                working_dir=workdir,
                remove=True,
                stdout=True,
                stderr=True,
                labels={LABEL_KEY: task_key},
            )
            activity.logger.info(
                "run_build_command: image=%s command=%s -> ok", image, command
            )
            return {
                "ok": True,
                "exit_code": 0,
                "output": output.decode("utf-8", errors="replace"),
            }
        except docker.errors.ContainerError as exc:
            activity.logger.info(
                "run_build_command: image=%s command=%s -> exit_code=%s",
                image,
                command,
                exc.exit_status,
            )
            return {
                "ok": False,
                "exit_code": exc.exit_status,
                "output": (exc.stderr or b"").decode("utf-8", errors="replace"),
            }
        except docker.errors.APIError as exc:
            return {"ok": False, "error": f"docker API error: {exc}"}
    finally:
        client.close()
