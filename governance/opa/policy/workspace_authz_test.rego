# `opa test governance/opa/policy` pins the ALLOW/DENY behavior of
# workspace_authz.rego against regressions, mirroring build_authz_test.rego's
# structure/conventions.
package workspace.authz_test

import data.workspace.authz
import rego.v1

test_create_allowed_for_temporal_svc_valid_name if {
	authz.allow with input as {"action": "create", "workspace_name": "tw-demo", "owner": "temporal-svc"}
}

test_start_allowed_for_temporal_svc_valid_name if {
	authz.allow with input as {"action": "start", "workspace_name": "tw-demo-2", "owner": "temporal-svc"}
}

test_create_denied_wrong_owner if {
	not authz.allow with input as {"action": "create", "workspace_name": "tw-demo", "owner": "some-other-user"}
}

test_create_denied_malformed_name if {
	not authz.allow with input as {"action": "create", "workspace_name": "not-tw-prefixed", "owner": "temporal-svc"}
}

test_create_denied_malformed_name_uppercase if {
	not authz.allow with input as {"action": "create", "workspace_name": "tw-Demo", "owner": "temporal-svc"}
}

test_stop_allowed_for_temporal_svc if {
	authz.allow with input as {"action": "stop", "workspace_name": "tw-demo", "owner": "temporal-svc"}
}

test_stop_denied_wrong_owner if {
	not authz.allow with input as {"action": "stop", "workspace_name": "tw-demo", "owner": "some-other-user"}
}

test_delete_allowed_with_reap_action_delete if {
	authz.allow with input as {"action": "delete", "workspace_name": "tw-demo", "owner": "temporal-svc", "reap_action": "delete"}
}

test_delete_denied_with_reap_action_stop if {
	not authz.allow with input as {"action": "delete", "workspace_name": "tw-demo", "owner": "temporal-svc", "reap_action": "stop"}
}

test_delete_denied_missing_reap_action if {
	not authz.allow with input as {"action": "delete", "workspace_name": "tw-demo", "owner": "temporal-svc"}
}

test_missing_input_denied if {
	not authz.allow with input as {}
}

test_missing_action_denied if {
	not authz.allow with input as {"workspace_name": "tw-demo", "owner": "temporal-svc"}
}
