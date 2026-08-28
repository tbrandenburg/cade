"""Healthcheck for the M11 Lab Simulator container.

The service requires bearer-token auth on every request (see
`lab_sim.server.BearerAuthMiddleware`), so a bare, unauthenticated request is
*expected* to return 401 - that counts as healthy here (the server is up and
correctly enforcing auth), mirroring the `registry` service's healthcheck
convention in `compose.yaml` for the same reason.
"""

import sys
import urllib.error
import urllib.request

try:
    urllib.request.urlopen("http://localhost:8300/mcp/", timeout=3)
except urllib.error.HTTPError as exc:
    sys.exit(0 if exc.code == 401 else 1)
except OSError:
    sys.exit(1)
else:
    sys.exit(0)
