"""Issue #5 MVP Workflow: run a single build/test command inside a
predefined workspace image via `run_build_command`
(`demo/build_activity.py`). Deliberately separate from
`DemoDurableWorkflow` (M8's generic build simulation, no real container)
and `EmbeddedValidationWorkflow` (M15's lab-sim capability call) — this is
the only workflow that actually executes a command inside a container
built from the same image Coder workspaces run.
"""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from demo.build_activity import run_build_command

ACTIVITY_TIMEOUT = timedelta(minutes=5)
# `run_build_command` catches every Docker/OPA-level error itself and
# returns it as a structured `{"ok": False, ...}` dict — it never raises
# for a legitimate build/test failure, so a retry policy here can only
# ever fire for a genuine infra fault (e.g. an unhandled exception, or a
# Temporal Activity timeout caused by `temporal-worker` crashing
# mid-Activity, see Issue #8). 2 attempts lets the workflow recover
# automatically from exactly that crash scenario without ever retrying a
# real command failure (which would still return its first, correct
# result and never raise in the first place).
BUILD_RETRY_POLICY = RetryPolicy(maximum_attempts=2)

# Issue #8: small lookup table mapping a Coder workspace template name to
# its pre-built image tag, so a caller can say "docker-standard" instead
# of hardcoding "cade/coder-workspace:latest" everywhere. Kept in sync
# with `governance/opa/policy/build_authz.rego`'s `allowed_images` set
# (read-only reference for this issue's scope) — both entries here MUST
# stay on that allow-list or every templated call will be denied by OPA.
DEFAULT_IMAGE = "cade/coder-workspace:latest"
TEMPLATE_IMAGES: dict[str, str] = {
    "docker-standard": "cade/coder-workspace:latest",
    "embedded-linux": "cade/embedded-linux-workspace:latest",
}


def resolve_image(image: str | None, template: str | None) -> str:
    """Resolve the effective image to run. Precedence: an explicit
    `image` always wins (backward compatible with pre-#8 callers); else
    `template` is looked up in `TEMPLATE_IMAGES`; else fall back to the
    original hardcoded default. Raises ValueError for an unknown
    template rather than silently falling back, so a typo'd template
    name fails fast instead of running the wrong image."""
    if image:
        return image
    if template:
        if template not in TEMPLATE_IMAGES:
            raise ValueError(
                f"unknown template {template!r}; known templates: "
                f"{sorted(TEMPLATE_IMAGES)}"
            )
        return TEMPLATE_IMAGES[template]
    return DEFAULT_IMAGE


@workflow.defn(name="BuildWorkflow")
class BuildWorkflow:
    @workflow.run
    async def run(
        self,
        image: str | None,
        command: list[str],
        workdir: str = "/workspace",
        template: str | None = None,
    ) -> dict:
        resolved_image = resolve_image(image, template)
        return await workflow.execute_activity(
            run_build_command,
            args=[resolved_image, command, workdir],
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=BUILD_RETRY_POLICY,
        )
