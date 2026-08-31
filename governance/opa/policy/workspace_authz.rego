# Issue #54 gap-fill — OPA policy for `demo/workspace_activity.py`'s
# `ensure_coder_workspace` (create/start) and `reap_coder_workspaces`
# (stop/delete) Activities. Issue #50 shipped these with no authorization
# gate at all — any workflow reaching the `demo-durable-workflow` task
# queue could trigger workspace create/start/stop/delete via the
# `temporal-svc` token, with only Coder's own RBAC as a backstop. This
# mirrors `build_authz.rego`'s pattern exactly: allow/deny logic lives
# here, evaluated live via OPA's decision API
# (POST /v1/data/workspace/authz/allow), never hardcoded in the Activity.
#
# `input` shape: {"action": "create"|"start"|"stop"|"delete",
# "workspace_name": "tw-...", "owner": "temporal-svc",
# "reap_action": "<CODER_WORKSPACE_REAP_ACTION value>" (delete only)}.
#
# Fail-closed default: any other input, including a missing/empty one, is
# denied.
package workspace.authz

import rego.v1

default allow := false

# Byte-for-byte the same pattern already validated in Python by
# `workspace_activity.py`'s NAME_PATTERN (`^tw-[a-z0-9-]{1,29}$`) — do not
# invent a new constraint here.
workspace_name_pattern := `^tw-[a-z0-9-]{1,29}$`

allow if {
	input.action in {"create", "start"}
	input.owner == "temporal-svc"
	regex.match(workspace_name_pattern, input.workspace_name)
}

allow if {
	input.action == "stop"
	input.owner == "temporal-svc"
}

allow if {
	input.action == "delete"
	input.owner == "temporal-svc"
	input.reap_action == "delete"
}
