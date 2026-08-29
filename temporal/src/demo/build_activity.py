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

import docker
import httpx
from docker.errors import ImageNotFound
from temporalio import activity

from demo.config import BUILD_DOCKER_HOST, OPA_URL

OPA_DECISION_PATH = "/v1/data/build/authz/allow"


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


@activity.defn(name="run_build_command")
async def run_build_command(
    image: str, command: list[str], workdir: str = "/workspace"
) -> dict:
    """Run `command` inside a short-lived container from `image`, capture
    stdout/stderr and the exit code, then remove the container. Fails
    closed: any Docker-level error (missing image, daemon unreachable,
    etc.) is returned as a structured error dict rather than raised, so a
    bad `image`/`command` input surfaces as a clear workflow result instead
    of an opaque Activity exception with a Temporal retry storm behind it.
    Also fails closed if OPA denies the request or is unreachable.
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
