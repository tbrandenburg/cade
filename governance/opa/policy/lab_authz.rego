# M12 Governance Foundation — OPA policy for the M11 Lab Simulator MCP
# service. The MCP lab-server queries OPA's decision API
# (POST /v1/data/lab/authz/allow) before executing any privileged action; the
# allow/deny logic must live here, not be hardcoded in the MCP server.
#
# Behaviors (see docs/plan/steps/in-progress/00100-governance-foundation.md):
#   allow read_device
#   allow run_test
#   deny flash_device_without_approval (i.e. allow flash_device only when
#   input.approved == true)
package lab.authz

import rego.v1

default allow := false

allow if { input.action == "read_device" }

allow if { input.action == "run_test" }

allow if {
	input.action == "flash_device"
	input.approved == true
}
