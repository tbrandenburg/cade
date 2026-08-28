# `opa test governance/opa/policy` pins the ALLOW/DENY behavior of
# lab_authz.rego against regressions - the standard OPA mechanism per M12's
# step file, not a substitute for the live decision-API check in
# scripts/verify-governance.sh.
package lab.authz_test

import data.lab.authz
import rego.v1

test_read_device_allowed if {
	authz.allow with input as {"action": "read_device"}
}

test_run_test_allowed if {
	authz.allow with input as {"action": "run_test"}
}

test_flash_device_with_approval_allowed if {
	authz.allow with input as {"action": "flash_device", "approved": true}
}

test_flash_device_without_approval_denied if {
	not authz.allow with input as {"action": "flash_device", "approved": false}
}

test_flash_device_missing_approval_denied if {
	not authz.allow with input as {"action": "flash_device"}
}

test_unknown_action_denied if {
	not authz.allow with input as {"action": "delete_fleet"}
}
