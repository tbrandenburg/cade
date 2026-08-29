# `opa test governance/opa/policy` pins the ALLOW/DENY behavior of
# build_authz.rego against regressions, mirroring lab_authz_test.rego's
# structure/conventions.
package build.authz_test

import data.build.authz
import rego.v1

test_coder_workspace_image_allowed if {
	authz.allow with input as {"image": "cade/coder-workspace:latest", "command": ["make", "test"]}
}

test_embedded_linux_workspace_image_allowed if {
	authz.allow with input as {"image": "cade/embedded-linux-workspace:latest", "command": ["make", "build"]}
}

test_arbitrary_image_denied if {
	not authz.allow with input as {"image": "alpine:latest", "command": ["sh", "-c", "rm -rf /"]}
}

test_missing_image_denied if {
	not authz.allow with input as {"command": ["echo", "hi"]}
}

test_empty_input_denied if {
	not authz.allow with input as {}
}
