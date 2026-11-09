# generic-linux-azure — offline preparation (#139 / A4)

**NOT LIVE TESTED.** This is the `generic-linux` environment implemented on
the optional `azure-remote-dev-env` backend, not an Azure control-plane
deployment. No subscription, Azure login, plan or apply was used for offline
validation. Do not enable a deployment connection until B1 (#141); agent,
bootstrap and durability require B2 (#142), and profiles require B3 (#143).

## Ownership and deployment inputs

The customer owns the existing workspace RG, network RG/VNet/subnet, security
groups, routing, DNS, policy and provisioner managed identity. This template
reads the workspace RG and references the subnet by full ID; the subnet may
be in a **different network RG**, but must be in the **same subscription**.
It never creates shared infrastructure, a public IP, an identity, RBAC or
network security rules. The managed Azure inventory is exactly one home
disk, and, while started, one private NIC, one VM (including its OS disk)
and one home-disk attachment. No Docker provider, socket or sandbox is used.

The publisher maps `BackendConnection.spec.config` fields to these
**template-wide Terraform variables**, never user-editable Coder parameters:

| Config field | Terraform variable | Required |
|---|---|---|
| `subscriptionId` | `subscription_id` | yes |
| `region` | `location` | yes |
| `resourceGroup` | `resource_group_name` | yes |
| `subnetId` | `subnet_id` | yes |
| `identity.clientId` | `managed_identity_client_id` | no; default `""` |

AzureRM 4.55.0 uses MSI explicitly, disables CLI auth and disables automatic
resource-provider registration. The enterprise must pre-register Compute
and Network and grant the provisioner scoped workspace-resource CRUD,
workspace RG read and subnet read/join permission (including the network
RG when separate). It needs no shared-network or RG create/delete rights.
Client IDs are nonsecret selectors, not credentials. The workspace VM does
**not** receive the provisioner's managed identity.

For B1, set/verify `ARM_USE_MSI=true`, `ARM_SUBSCRIPTION_ID`, the relevant
`ARM_TENANT_ID` and optional `ARM_CLIENT_ID` in the **actual Terraform
provisioner execution environment**, matching the published variables.
Unset client-secret/OIDC/certificate credentials there: MSI configuration
is not an RBAC boundary. Empty `managed_identity_client_id` leaves AzureRM's
environment/system identity selection intact. Host MSI is not proof MSI
works inside containerized Coder/Compose: verify IMDS reachability and
identity selection from that provisioner before enabling anything.

## Profile gate and tooling

The sole workspace parameter is immutable `profile`, default `Small`.
Both Coder validation and an unconditional home-disk Terraform lifecycle
precondition require its actual value to equal `Small`; NIC/VM depend on
that disk. VM size is fixed, not a user-supplied SKU. Removing a UI option
is not the security control.

| Profile | Candidate size | Enablement |
|---|---|---|
| Small | `Standard_D16ds_v5`, 16 vCPU / 64 GiB | only permitted value; availability/quota/cost unverified |
| Medium | `Standard_E64ds_v5`, 64 vCPU / 512 GiB | NOT enabled; B3 approval + live verification + template change |
| Large | `Standard_M128s`, 128 vCPU / 2 TiB | NOT enabled; B3 approval + live verification + template change |

Small is the issue's relative profile name, **not a low-cost SKU**. No live
resizing is promised. Ubuntu 22.04 Gen2 (`latest` image version, intentionally
not a validated immutable image build) installs git, curl, a shell, C/C++
build basics, CMake and Ninja. Coder SSH supports desktop VS Code Remote SSH
and the server installed by that client; no browser code-server is bundled.
There is no embedded, AI-agent or devcontainer environment support here.

## Bootstrap and secrets

The private VM must reach the configured `CODER_ACCESS_URL` and its agent
download endpoints, Ubuntu package mirrors and Azure IMDS. No public SSH
or inbound Internet path is created. Existing routing/DNS must provide
that connectivity; an internal Docker-only Coder hostname is insufficient.

Agent authentication uses `azure-instance-identity`, not an embedded token.
Coder associates the agent with the Azure VM through the init-script
reference. B2 must prove that actual Coder association and Azure signed
instance-document authentication. `custom_data` is marked sensitive, and
the init script is root-owned, group-readable/executable by coder, outside
the retained home. Agent stdout/stderr are suppressed rather than sent to
cloud-init/journal logs. Do not add tokens, passwords or shell tracing;
protect Coder's Terraform state and Azure custom-data read access regardless.
The committed `bootstrap.pub` is a public-only disposable key whose private
half was discarded, needed solely for Azure's admin-key requirement; normal
access is through Coder. No password or private key is in source/state.

`cade-home.service` waits at most six minutes for SCSI LUN 10, validates the
whole-disk layout, and mounts `/home/coder` **before** the agent can start.
An existing ext4 filesystem is mounted without formatting. A signature-free
disk is formatted **only after a full-device zero scan**; nonzero data,
unknown signatures, partitions, read/probe errors or mount failures stop
bootstrap. There is no force-format/repair/OS-home fallback. A 32 GiB first
zero scan may be slow (service timeout 30 minutes). Existing damaged data
requires operator recovery, never automated reformatting. UID 1001 is fixed
for home ownership. Reboot remounts via the dependency service, not `nofail`.

## Lifecycle, deletion and recovery

Resource names/tags use the immutable Coder workspace UUID, not owner/name.
Renaming a workspace therefore does not intentionally rename its disks.

| Operation | VM / NIC / attachment / OS disk | 32 GiB StandardSSD home |
|---|---|---|
| Start | create (fresh OS, packages/bootstrap) | create once or attach existing state resource |
| Stop | destroy; OS disk deletion explicitly enabled | retain, detached, still billable |
| Restart | recreate compute, not in-place VM deallocate/resume | same disk and byte data intended |
| Coder workspace delete / Terraform destroy | destroy | **destroy, data lost** |

There is deliberately no `prevent_destroy` that blocks Coder deletion and no
claim of survival after workspace delete/recreate (a new workspace has a new
UUID). Back up/snapshot home **before deleting a workspace** or changing
subscription/RG/region/template settings that replace the disk. Stop/start
persistence is a design intention until B2 proves it with a byte-exact marker.

If provisioning/state loss or an interrupted deletion leaves orphaned
resources, inventory by `Coder_Workspace_ID`/`CADE_Backend` tags and verify
the workspace UUID, disk name, attachment and backup before mutation. Stop
the workspace, snapshot the disk and preserve Terraform/Coder state. With
operator approval, recover the original workspace state or import the
identified disk into its `azurerm_managed_disk.home` address using the real
disk ID; review the resulting cloud plan for replacement before starting.
Do not blindly create/format a replacement disk, attach one disk to two
workspaces, delete an orphan by name alone, or delete the customer RG/subnet.
Recovery/import/snapshot operations are future live operator procedures,
**not commands performed by these offline checks**. Disabling a backend is
neither resource deletion nor access revocation.

## Reproduce offline validation

From the repository root, with Terraform **1.14.5** on PATH:

```bash
python3 -m pip install -r scripts/requirements-backends.txt
terraform -chdir=coder/templates/generic-linux-azure fmt -check
terraform -chdir=coder/templates/generic-linux-azure init -backend=false -input=false -lockfile=readonly
terraform -chdir=coder/templates/generic-linux-azure validate
TERRAFORM=terraform python3 -m unittest discover -s tests -p test_azure_template.py -v
python3 -m unittest discover -s tests -p test_backends_config.py -v
```

Provider downloads require ordinary Internet access; init/validate and the
tests require no Azure credentials or APIs. Tests run only static inspection,
shell syntax and provider-free `terraform console` expressions, never plan
or apply. `.terraform.lock.hcl` pins Coder 2.20.0/AzureRM 4.55.0; it is tracked
explicitly despite the repository-wide ignore. No additional Terraform
modules/providers are needed. Re-run these checks when pins change.

Design sources: [official Coder Azure Linux template](https://registry.coder.com/templates/coder/azure-linux),
[upstream sample source](https://github.com/coder/registry/tree/main/registry/coder/templates/azure-linux),
[AzureRM 4.55.0 VM reference](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.55.0/website/docs/r/linux_virtual_machine.html.markdown),
[MSI](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.55.0/website/docs/guides/managed_service_identity.html.markdown),
[provider options](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.55.0/website/docs/index.html.markdown).
Unlike the sample, this implementation does not own the RG/network and does
not let cloud-init's disk setup format an unverified existing disk.
