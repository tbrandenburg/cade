# Azure remote development onboarding

**Status: offline preparation only. Live Azure checks NOT TESTED.** Passing the
doctor does not authorize publishing, provision resources, or establish that a
subscription can run this template. B1 [#141](https://github.com/tbrandenburg/cade/issues/141),
B2 [#142](https://github.com/tbrandenburg/cade/issues/142), and B3
[#143](https://github.com/tbrandenburg/cade/issues/143) own live acceptance.

## Owner handoff: minimum inputs and ownership

Reuse an approved subscription, an **existing dedicated workspace resource group**,
an **existing approved subnet**, a private Coder URL/host, and an approved managed
identity with scoped RBAC. No enterprise Terraform state access is required.
The subnet may be in a separate **network resource group**; it must belong to the
same subscription as the workspace RG. The offline doctor checks subscription-ID
correspondence, not the existence, ownership, or region of those resources.

| Owner | Owns | Does not transfer to CADE workspace state |
| --- | --- | --- |
| Enterprise infrastructure monorepo / platform owner | Subscription, workspace RG, VNet/subnet, NSG, firewall, NAT/egress, routes, peering, DNS, policy, identity, RBAC | Shared resource lifecycle and authorization |
| Separate CADE deployment repo / deployment operator | Reviewed `backends/*.yaml` opt-in references; optional Compose hosting settings | Enterprise state, secrets, template paths |
| CADE product/source | Schema, `/workspace/catalog.yaml`, Coder template implementation | Customer opt-in and shared infrastructure |
| `generic-linux-azure` template under Coder/Terraform | Per-workspace VM, NIC, OS disk and home disk | RG, network, identity or role assignments |
| Coder | Workspace create/start/stop/delete and Terraform state | A second CADE lifecycle controller |

Three names must remain distinct:
`generic-linux` is the environment; `azure-remote-dev-env` is the connection;
`generic-linux-azure` is the implementation. A4 (#139) owns the product catalog mapping
`generic-linux / azure-remote-dev-env / generic-linux-azure`; customer YAML
cannot select a Terraform path or invent another supported pairing.
See [backend contract](/docs/backends.md), [architecture](/docs/ARCHITECTURE.md),
and [security](/docs/security.md).

### Where the control plane runs

1. **CADE runs on an approved Azure Linux host:** reuse that host and the existing
   Docker Compose control plane. Verify capacity and its private Coder URL; do not
   stand up a second Coder server to enable Azure workspaces.
2. **No CADE host exists:** platform owners separately provision a minimal dedicated
   Linux host for the existing Docker Compose stack, with private access, persistent
   storage, backups, approved egress and an attached identity. Size it for the stack
   using [host requirements and quickstart](/README.md#quickstart), not the workspace
   VM profile. Run `make doctor` on that host before installation. Hosting approval
   and costs are separate from workspace provisioning. **No Kubernetes cluster.**

An on-premises host does not gain Azure managed identity by setting an environment
variable. If the selected execution context cannot use the approved identity,
stop and have the platform owner approve a suitable Azure host/execution path;
do not introduce client secrets into connection YAML as a workaround.

## Least-privilege authorization request

Only request an enterprise infra PR if the approved access is missing. Platform
owners make assignments through their existing reviewed workflow; CADE's offline
doctor never creates roles, assignments, resource groups or VMs.

- **Workspace RG scope:** prefer a custom role limited to VM, managed-disk and NIC
  read/write/delete and required VM lifecycle/attachment actions, plus RG read.
  Review the pinned template's actual API operations in B1 before finalizing it.
  This authorizes workspace-resource cleanup, **not deletion of the RG itself**.
  Exclude shared networking, public IP creation, identity mutation and
  `Microsoft.Authorization/roleAssignments/write`/`delete`.
- **Approved subnet resource scope:** custom role with
  `Microsoft.Network/virtualNetworks/subnets/read` and
  `Microsoft.Network/virtualNetworks/subnets/join/action`. NIC management stays in
  the workspace RG. Do not grant Network Contributor on the network RG just to
  attach a NIC. If the pinned provider needs parent-resource read, justify only
  that extra read at the narrowest parent scope during B1; no network writes.
- Do **not** request subscription-wide Contributor, Owner, User Access
  Administrator, runtime role-assignment rights or shared-RG deletion. Even
  dedicated-RG Contributor is broader than this contract; do not treat it as the
  default least-privilege role. Escalate a required exception to the platform owner.
- Platform owners attach the approved identity to the execution host. A client ID
  selects a user-assigned identity; it neither grants rights nor attaches it.
  The provisioner need not assign identities to workspace VMs. Avoid granting it
  Managed Identity Operator merely to authenticate as an identity attached by
  the platform owner. Resource-provider registration is a platform prerequisite,
  not a reason to grant subscription write privileges to the runtime.

### Actual provisioner authentication: future B1 gate

Terraform runs in a **Coder provisioner**, not the developer's terminal or inside
the workspace VM. With this Compose deployment, start by inspecting the built-in
provisioner in the Coder container. Do not assume host `az login`, an attached host
identity, or a successful metadata probe on the host proves the container works.

In the actual Terraform execution environment, review `ARM_USE_MSI=true`,
`ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID` and optional `ARM_CLIENT_ID` for a user-assigned
identity. Verify the pinned AzureRM provider's configuration and Coder's environment
forwarding; shell exports alone do not modify an existing container. The approved
deployment override must pass the required settings to the actual provisioner.
Keep auth settings separate from user-editable Coder workspace parameters.

During B1, verify access to Azure IMDS (`169.254.169.254`) **from that container /
execution context**, with the required metadata header and proxy bypass, then
verify an authenticated ARM read of the approved RG/subnet as the intended identity.
Record only status, principal/resource correspondence and safe diagnostics, never
tokens or raw metadata-token responses. Host/container networking or egress policy
may block this path; escalate rather than opening public ingress or using privileged
containers. External provisioner options depend on the deployed Coder version and
entitlements and are not an assumed OSS prerequisite.

The nonsecret publication mapping is frozen separately from authentication:

| Connection config | Terraform template variable |
| --- | --- |
| `subscriptionId` | `subscription_id` |
| `region` | `location` |
| `resourceGroup` | `resource_group_name` |
| `subnetId` | `subnet_id` |
| optional `identity.clientId` | `managed_identity_client_id` (absent uses default `''`) |

## Private connectivity and corporate trust

| Direction | Required verification in B1/B2 |
| --- | --- |
| Developer → private Coder URL | Approved VPN/private access, DNS resolution, TLS trust and authenticated dashboard/CLI |
| Workspace agent → Coder URL | Outbound HTTPS/WebSocket connectivity using the externally reachable `CODER_ACCESS_URL`, not a Docker-only service name or localhost |
| Provisioner → Azure | IMDS in its execution context; approved ARM/identity endpoints; Terraform registry/provider downloads or approved mirrors |
| Workspace → dependencies | Approved DNS, Git, package/OCI registries, agent/bootstrap downloads, and corporate CA trust |

Use the existing enterprise egress path (approved firewall/NAT if present). No new
public IP, inbound SSH, VNet/subnet/NSG, NAT, routes, peering or DNS changes are
automatically created by onboarding. If reachability is absent, request a separate
network-owner review rather than silently adding infrastructure. Direct developer
access to workspace SSH is not a prerequisite for the Coder agent tunnel.

Future live operators should run bounded DNS resolution and TLS-validated HTTPS
probes for each approved hostname from the **real source context** (developer,
provisioner, then workspace), and observe a real agent connection in Coder. A
`curl` status alone is not proof of WebSocket/agent operation. Install corporate
CA trust in the provisioner and workspace OS as needed; use the
[CA runbook](/README.md#self-signed--corporate-tls-intercepting-proxy-certificates).
Do not use `curl -k` or disable certificate validation to turn a failed check green.

## Offline declaration and doctor

Dependencies are pinned in `/scripts/requirements-backends.txt`; the doctor adds
no packages. Dependency installation may contact PyPI; the doctor itself does not
contact Azure, invoke `az`, Terraform, Coder or Docker, read login credentials, or
write configuration. Python 3.10+ and Bash are sufficient after installation:

```bash
(
  set -euo pipefail
  python3 -m venv .venv-backends
  .venv-backends/bin/python -m pip install -r scripts/requirements-backends.txt
  source .venv-backends/bin/activate
  bash scripts/doctor-azure.sh --offline \
    --config ../cade-deployment/backends/azure-remote-dev-env.yaml --profile Small
)
```

One deployment declaration (keep disabled until live prerequisites are accepted):

```yaml
apiVersion: cade.dev/v1alpha1
kind: BackendConnection
metadata:
  name: azure-remote-dev-env
spec:
  provider: azure
  enabled: false
  config:
    subscriptionId: "<subscription-id>"
    region: swedencentral
    resourceGroup: rg-cade-workspaces
    subnetId: "/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
    identity:
      method: managedIdentity
      # clientId: "<user-assigned-managed-identity-client-id>"
```

The shared schema/validator rejects unknown fields, credentials/template paths,
invalid enabled IDs, region/RG syntax and subscription/subnet mismatches. Disabled
placeholders are permitted, but unknown fields/inline credential keys are not.
IDs are not credentials; never put passwords, tokens, certificates or client
secrets here. Diagnostics do not echo declaration values. Inspect errors locally;
do not paste raw secret-bearing declarations into logs or review requests.

`--profile` is a separate doctor option, **not a config property**. Its default and
only permitted value is `Small`; unknown values, `Medium` and `Large` fail, including
for disabled declarations. Small's candidate `Standard_D16ds_v5` (16 vCPU/64 GiB)
still needs cost/quota/SKU approval: "Small" is a relative label, not a cheap-VM
claim. B3 must explicitly implement approval before Medium/Large can be enabled.
The doctor does not replace the template's enforced profile allowlist.

The explicit `--config` file must exist, be readable and be a regular file. Missing
paths, directories and dangling symlinks fail, even though A1 directory resolution
uses legacy Docker when a backend directory is absent. `CADE_BACKENDS_DIR` does not
override this file option. No online mode is implemented.

Success exits 0 and prints `Offline Azure declaration valid` followed by
`Live Azure checks NOT TESTED`. Invalid declarations exit 1 with a field/schema
diagnostic; invalid CLI usage exits 2 with the supported invocation.

### Disposable two-repo rehearsal (fictional IDs, zero Azure access)

From CADE source with the venv activated:

```bash
(
  set -euo pipefail
  rehearsal="$(mktemp -d)"
  mkdir -p "$rehearsal/infrastructure" "$rehearsal/cade-deployment/backends"
  cp tests/fixtures/doctor-azure/enabled.yaml \
    "$rehearsal/cade-deployment/backends/azure-remote-dev-env.yaml"
  bash scripts/doctor-azure.sh --offline --profile Small \
    --config "$rehearsal/cade-deployment/backends/azure-remote-dev-env.yaml"
  python3 -m unittest discover -s tests -p test_doctor_azure.py -v
)
```

The enabled fixture uses fictional UUIDs and a separate network RG; it is **not**
deployment approval. The real-CLI tests recreate the two-repo layout, reject ID/
subscription/RG/region/profile/secret/path mistakes and verify unchanged repository
bytes and no invocation of cloud/runtime CLIs. Review `/workspace/catalog.yaml` in
product source alongside the deployment file: the latter contains no template
path. No Azure resource or cloud cost is produced by these doctor invocations.

## Copyable reviews (two independent PRs)

### Optional enterprise infrastructure review request

```text
Title: Authorize existing-infrastructure CADE workspace provisioning
Owner: <platform owner>; approval/ticket: <reference>
Existing subscription / tenant: <IDs>; region: <approved region>
Existing workspace RG: <RG>; approved existing subnet: <full resource ID>
Actual Coder provisioner host/context and private Coder URL: <references>
Managed identity principal/client ID: <nonsecret IDs; attached by platform owner>
Request: custom scoped VM/NIC/disk lifecycle role at workspace RG + RG read;
subnet read/join at the approved subnet. Review exact provider operations in B1.
No RG deletion, subscription-wide Contributor, role-assignment privilege, public
IP or shared network changes. No enterprise Terraform state access for CADE.
Confirm private reachability, DNS/CA and existing approved egress; policy/provider
registration, SKU/quota, max concurrent workspaces, disk-retention cost and budget.
No access change needed? Record existing approval instead of opening this PR.
```

### Separate CADE deployment opt-in PR checklist

```text
Title: Opt into approved azure-remote-dev-env connection
[ ] Platform approval or existing authorization reference attached.
[ ] Private control-plane hosting decided separately; reuse Compose, no Kubernetes.
[ ] Only backends/azure-remote-dev-env.yaml references approved nonsecret IDs.
[ ] No profile/template path/secrets or enterprise state import in connection YAML.
[ ] Product catalog supplies generic-linux → azure-remote-dev-env → generic-linux-azure.
[ ] Offline doctor --profile Small passed; output attached, live checks NOT TESTED
    until B1–B3 acceptance is recorded. Keep enabled:false before that acceptance.
[ ] Actual provisioner identity/env/IMDS/RBAC, private agent connectivity, policy,
    region/SKU availability, quotas and cost controls verified before enabling.
[ ] Coder operator owns publication, lifecycle, backups, retention and disable plan.
[ ] Targeted publication/template variables inspected; existing Docker selection
    and control-plane hosting stay independent. No automatic apply from doctor.
```

## Disable, retirement and future live acceptance

`enabled: false` or omission stops **future selection/publication** only. It never
revokes a published Coder template, stops an existing workspace, deletes data or
removes shared infrastructure. Inventory workspace/template usage and agree a
backup/migration/retention plan with owners before separate cleanup.

**Do not assume `coder templates edit --deprecated` or template RBAC enforces this
on OSS.** Coordinator testing on unlicensed Coder 2.38.6 found a successful edit
left persisted `deprecated:false` and member creation returned 201; template RBAC
was `not_entitled` and ACL GET returned 403. Check the actual version/entitlements,
persisted state and a real member create attempt. Restriction is proven only by
rejected creation, not a CLI exit code or hidden dashboard tile.

If no tested per-template restriction exists, keep Azure unpublished. For an
existing publication, block the deployment/automation operationally, escalate to
the Coder/platform owner and establish a verified creation-denial control before
claiming retirement. Coordinate downtime if deployment-wide access/provisioning
must be paused; do not silently disable unrelated Docker users. No automatic
deletion of templates, workspaces or disks is part of this doctor.

Future online checks remain **NOT TESTED** here:

- B1: identity and ARM authorization from actual containerized provisioner;
  RG/subnet existence, same-subscription/region, policy, registered providers,
  routing/DNS/CA, approved egress, regional SKU availability, quotas and budget.
- B2: real create/start/stop/delete using Coder, agent connectivity through the
  private URL, home-disk byte persistence, explicit delete/retention behavior,
  resource inventory proving shared infrastructure unchanged and no public IP.
- B3: measured Small cost/performance, concurrency limits, approved profiles and
  enforced rejection of unapproved Medium/Large values through real create calls.

### Research references

- [AzureRM managed identity configuration](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity)
  (`ARM_USE_MSI`, client-ID selection and metadata endpoint; verify pinned version).
- [Microsoft managed identity Terraform guidance](https://learn.microsoft.com/en-us/azure/developer/terraform/authenticate-to-azure-with-managed-identity-for-azure-services)
  (do not copy its broad Contributor example into the scoped enterprise request).
- [Azure network RBAC actions](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/networking)
  (subnet read/join), [custom roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles).
- [Coder provisioners](https://coder.com/docs/admin/provisioners) and
  [provider authentication](https://coder.com/docs/admin/templates/extending-templates/provider-authentication)
  (Terraform execution context; deployment version/entitlements govern options).
