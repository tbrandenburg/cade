"""Offline resource/lifecycle contracts; no plan, apply, Coder or Azure calls."""

import importlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "coder/templates/generic-linux-azure"
sys.path.insert(0, str(ROOT / "scripts"))
backend = importlib.import_module("backend_config")


class AzureTemplateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.main = (TEMPLATE / "main.tf").read_text()
        cls.variables = (TEMPLATE / "variables.tf").read_text()
        cls.bootstrap = (TEMPLATE / "mount-home.sh").read_text()

    def block(self, kind: str, resource: str, name: str) -> str:
        match = re.search(
            rf'^{kind} "{resource}" "{name}" {{\n.*?^}}', self.main, re.M | re.S
        )
        self.assertIsNotNone(match, (kind, resource, name))
        return match.group()

    def console(self, expression: str) -> object:
        terraform = shutil.which(os.environ.get("TERRAFORM", "terraform"))
        self.assertIsNotNone(terraform, "Set TERRAFORM to a Terraform 1.14.5 binary")
        with tempfile.TemporaryDirectory(prefix="cade-azure-expr-") as directory:
            result = subprocess.run(
                [terraform, f"-chdir={directory}", "console", "-no-color"],
                input=f"jsonencode({expression})\n",
                env={"PATH": os.environ["PATH"], "TF_IN_AUTOMATION": "1"},
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(json.loads(result.stdout))

    def test_exact_workspace_owned_azure_inventory(self) -> None:
        resources = re.findall(
            r'^resource "(azurerm_[^"]+)" "([^"]+)"', self.main, re.M
        )
        self.assertEqual(
            resources,
            [
                ("azurerm_managed_disk", "home"),
                ("azurerm_network_interface", "main"),
                ("azurerm_linux_virtual_machine", "main"),
                ("azurerm_virtual_machine_data_disk_attachment", "home"),
            ],
        )
        self.assertIn('data "azurerm_resource_group" "workspace"', self.main)
        nic = self.block("resource", "azurerm_network_interface", "main")
        self.assertRegex(nic, r"subnet_id\s+= var.subnet_id")
        self.assertNotIn("public_ip_address_id", nic)
        self.assertNotRegex(self.main, r"(?i)source\s*=.*(docker|tls|cloudinit)")

    def test_template_variable_and_identity_contract(self) -> None:
        self.assertEqual(
            re.findall(r'^variable "([^"]+)"', self.variables, re.M),
            [
                "subscription_id",
                "location",
                "resource_group_name",
                "subnet_id",
                "managed_identity_client_id",
            ],
        )
        self.assertEqual(
            re.findall(r'^data "coder_parameter" "([^"]+)"', self.main, re.M),
            ["profile"],
        )
        self.assertRegex(self.main, r"use_msi\s+= true")
        self.assertRegex(self.main, r"use_cli\s+= false")
        self.assertRegex(self.main, r'resource_provider_registrations\s+= "none"')
        self.assertRegex(
            self.variables,
            r'(?s)variable "managed_identity_client_id".*?default\s+= ""',
        )
        self.assertNotRegex(
            self.main, r"(?m)^\s*(identity|admin_password|client_secret)\s*[={]"
        )

    def test_profile_gate_evaluates_actual_parameter_not_ui(self) -> None:
        home = self.block("resource", "azurerm_managed_disk", "home")
        condition = re.search(
            r"condition\s+= (data.coder_parameter.profile.value[^\n]+)", home
        ).group(1)
        expressions = [
            condition.replace("data.coder_parameter.profile.value", json.dumps(value))
            for value in (
                "Small",
                "Medium",
                "Large",
                "Standard_M128s",
                "small",
                "",
                "Small\n",
            )
        ]
        self.assertEqual(
            self.console("[" + ",".join(expressions) + "]"),
            [True, False, False, False, False, False, False],
        )
        self.assertRegex(self.main, r'size\s+= "Standard_D16ds_v5"')
        self.assertNotIn("Standard_E64ds_v5", self.main)
        self.assertNotIn("Standard_M128s", self.main)
        self.assertIn("depends_on = [azurerm_managed_disk.home]", self.main)
        self.assertIn('regex = "^Small$"', self.main)

    def test_variable_validations_evaluate_offline(self) -> None:
        subscription = "11111111-2222-3333-4444-555555555555"
        subnet = f"/subscriptions/{subscription}/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/dev"
        cases = {
            "subscription_id": (subscription, "<subscription-id>"),
            "location": ("swedencentral", "Sweden Central"),
            "resource_group_name": ("rg-cade-workspaces", "invalid/group"),
            "subnet_id": (subnet, subnet.replace(subscription, "-" * 36)),
            "managed_identity_client_id": ("", "<client-id>"),
        }
        expressions = []
        for name, values in cases.items():
            block = re.search(
                rf'^variable "{name}" {{\n.*?^}}', self.variables, re.M | re.S
            ).group()
            condition = re.search(r"condition\s+= ([^\n]+)", block).group(1)
            expressions.extend(
                condition.replace(f"var.{name}", json.dumps(value)) for value in values
            )
        self.assertEqual(
            self.console("[" + ",".join(expressions) + "]"), [True, False] * 5
        )
        self.assertEqual(len(expressions), 10)

    def test_same_subscription_different_network_rg(self) -> None:
        condition = re.search(r"condition\s+= (lower\(split[^\n]+)", self.main).group(1)
        subscription = "11111111-2222-3333-4444-555555555555"
        subnet = f"/subscriptions/{subscription}/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/shared/subnets/dev"
        expressions = [
            condition.replace("var.subnet_id", json.dumps(value)).replace(
                "var.subscription_id", json.dumps(subscription)
            )
            for value in (subnet, subnet.replace("11111111", "99999999"))
        ]
        self.assertEqual(self.console("[" + ",".join(expressions) + "]"), [True, False])
        self.assertNotIn("var.resource_group_name", condition)
        self.assertIn("network RG may differ", self.variables)

    def test_home_and_compute_lifetimes(self) -> None:
        home = self.block("resource", "azurerm_managed_disk", "home")
        self.assertNotRegex(home, r"(?m)^\s*count\s*=")
        self.assertIn('name                 = "${local.prefix}-home"', home)
        self.assertIn('prefix = "cade-${data.coder_workspace.me.id}"', self.main)
        self.assertNotIn("prevent_destroy", self.main)
        self.assertRegex(self.main, r"delete_os_disk_on_deletion\s+= true")
        for resource, name in (
            ("azurerm_network_interface", "main"),
            ("azurerm_linux_virtual_machine", "main"),
            ("azurerm_virtual_machine_data_disk_attachment", "home"),
        ):
            self.assertRegex(
                self.block("resource", resource, name),
                r"count\s+= data.coder_workspace.me.start_count",
            )
        attachment = self.block(
            "resource", "azurerm_virtual_machine_data_disk_attachment", "home"
        )
        self.assertIn("azurerm_managed_disk.home.id", attachment)
        self.assertRegex(attachment, r"lun\s+= 10")

    def test_real_cloud_init_render_and_mount_before_agent(self) -> None:
        expression = f'templatefile({json.dumps(str(TEMPLATE / "cloud-init.tftpl"))}, {{init_script="aW5pdA==", mount_home="bW91bnQ="}})'
        document = yaml.safe_load(self.console(expression))
        files = {item["path"]: item for item in document["write_files"]}
        service = files["/etc/systemd/system/coder-agent.service"]["content"]
        self.assertIn("Requires=cade-home.service", service)
        self.assertIn("After=cade-home.service network-online.target", service)
        self.assertIn("ConditionPathIsMountPoint=/home/coder", service)
        self.assertIn("StandardOutput=null", service)
        self.assertIn("StandardError=null", service)
        self.assertEqual(files["/opt/cade/agent-init"]["permissions"], "0750")
        self.assertEqual(files["/opt/cade/mount-home"]["permissions"], "0700")
        self.assertNotIn("disk_setup", document)
        self.assertNotIn("fs_setup", document)
        self.assertEqual(
            document["runcmd"][-1],
            ["systemctl", "enable", "--now", "coder-agent.service"],
        )

    def test_bootstrap_refuses_nonblank_partitioned_and_probe_errors(self) -> None:
        result = subprocess.run(
            ["bash", "-n", str(TEMPLATE / "mount-home.sh")],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set -euo pipefail", self.bootstrap)
        self.assertIn("device=/dev/disk/azure/scsi1/lun10", self.bootstrap)
        self.assertIn(
            "Partitioned home disk requires operator recovery.", self.bootstrap
        )
        self.assertIn("0:ext4) ;;", self.bootstrap)
        self.assertIn("signatures=$(wipefs --no-act", self.bootstrap)
        self.assertIn(
            'cmp --silent --bytes="$bytes" "$device" /dev/zero || fail', self.bootstrap
        )
        self.assertIn(
            "Unsupported or unreadable filesystem; refusing format.", self.bootstrap
        )
        self.assertEqual(self.bootstrap.count("mkfs.ext4"), 1)
        self.assertNotIn("mkfs.ext4 -F", self.bootstrap)
        self.assertLess(
            self.bootstrap.index("cmp --silent"), self.bootstrap.index("mkfs.ext4")
        )
        self.assertLess(
            self.bootstrap.index("mkfs.ext4"), self.bootstrap.index("mount -t ext4")
        )
        self.assertNotIn("|| mkfs", self.bootstrap)

    def test_no_agent_credentials_or_unpinned_providers(self) -> None:
        self.assertRegex(self.main, r'auth\s+= "azure-instance-identity"')
        self.assertIn("custom_data = sensitive(base64encode(templatefile", self.main)
        self.assertNotIn(".token", self.main)
        self.assertNotIn(
            "CODER_AGENT_TOKEN", (TEMPLATE / "cloud-init.tftpl").read_text()
        )
        lock = (TEMPLATE / ".terraform.lock.hcl").read_text()
        for provider, version in (
            ("coder/coder", "2.20.0"),
            ("hashicorp/azurerm", "4.55.0"),
        ):
            self.assertIn(f'provider "registry.terraform.io/{provider}"', lock)
            self.assertIn(f'version     = "{version}"', lock)
            self.assertIn(f'version = "= {version}"', self.main)
        self.assertTrue(
            (TEMPLATE / "bootstrap.pub").read_text().startswith("ssh-ed25519 ")
        )
        self.assertFalse((TEMPLATE / "bootstrap").exists())

    def test_catalog_azure_opt_in_preserves_four_docker_defaults(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cade-azure-select-") as directory:
            path = Path(directory)
            default = backend.resolve(path / "missing")
            self.assertEqual(len(default), 4)
            self.assertEqual({entry["backend"] for entry in default}, {"docker-local"})
            shutil.copy(
                ROOT / "tests/fixtures/backends/azure-enabled-external-subnet.yaml",
                path,
            )
            selected = backend.resolve(path)
            self.assertEqual(
                selected,
                [
                    {
                        "environment": "generic-linux",
                        "backend": "azure-remote-dev-env",
                        "template": "generic-linux-azure",
                        "path": "coder/templates/generic-linux-azure",
                    }
                ],
            )
            self.assertEqual(len(backend.load_catalog()), 5)
            self.assertFalse(
                yaml.safe_load(
                    (ROOT / "workspace/examples/azure-remote-dev-env.yaml").read_text()
                )["spec"]["enabled"]
            )


if __name__ == "__main__":
    unittest.main()
