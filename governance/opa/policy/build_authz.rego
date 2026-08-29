# Issue #5 gap-fill — OPA policy for `demo/build_activity.py`'s
# `run_build_command` Activity. The MVP shipped with no authorization gate
# at all (any workflow reaching the `demo-durable-workflow` task queue
# could request execution of an arbitrary Docker image + arbitrary
# command); this closes that gap the same way `lab_authz.rego` gates the
# M11 Lab Simulator: allow/deny logic lives here, evaluated live via OPA's
# decision API (POST /v1/data/build/authz/allow), never hardcoded in the
# Activity.
#
# Behavior: allow only images in an explicit allow-list of predefined
# workspace images (the whole point of the issue - "run workflows in
# predefined workspaces with build tools installed", not arbitrary images).
# Fail-closed default: any other image is denied, including an unset/
# missing `input.image`.
package build.authz

import rego.v1

default allow := false

allowed_images := {
	"cade/coder-workspace:latest",
	"cade/embedded-linux-workspace:latest",
}

allow if {
	input.image in allowed_images
}
