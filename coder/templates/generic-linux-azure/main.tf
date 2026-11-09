terraform {
  required_version = ">= 1.14.5, < 2.0.0"
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "= 2.20.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.55.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  client_id                       = var.managed_identity_client_id != "" ? var.managed_identity_client_id : null
  use_msi                         = true
  use_cli                         = false
  resource_provider_registrations = "none"
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}

data "coder_workspace" "me" {}

data "azurerm_resource_group" "workspace" {
  name = var.resource_group_name
}

data "coder_parameter" "profile" {
  name         = "profile"
  display_name = "Workspace profile"
  description  = "Small only; other profiles require separate approval and live validation."
  type         = "string"
  default      = "Small"
  mutable      = false
  option {
    name  = "Small (16 vCPU / 64 GiB)"
    value = "Small"
  }
  validation {
    regex = "^Small$"
    error = "Only Small is approved. Medium and Large are not enabled."
  }
}

locals {
  prefix = "cade-${data.coder_workspace.me.id}"
  tags = {
    Coder_Provisioned  = "true"
    Coder_Workspace_ID = data.coder_workspace.me.id
    CADE_Backend       = "azure-remote-dev-env"
  }
}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"
  auth = "azure-instance-identity"
  dir  = "/home/coder"
}

resource "azurerm_managed_disk" "home" {
  name                 = "${local.prefix}-home"
  location             = var.location
  resource_group_name  = data.azurerm_resource_group.workspace.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 32
  tags                 = local.tags

  lifecycle {
    precondition {
      condition     = data.coder_parameter.profile.value == "Small"
      error_message = "Only Small is approved; changing the rich parameter cannot enable another profile."
    }
    precondition {
      condition     = lower(split("/", var.subnet_id)[2]) == lower(var.subscription_id)
      error_message = "The existing subnet must be in the configured subscription (its RG may differ)."
    }
  }
}

resource "azurerm_network_interface" "main" {
  count               = data.coder_workspace.me.start_count
  name                = "${local.prefix}-nic"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workspace.name
  tags                = local.tags

  ip_configuration {
    name                          = "workspace"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
  depends_on = [azurerm_managed_disk.home]
}

resource "azurerm_linux_virtual_machine" "main" {
  count                           = data.coder_workspace.me.start_count
  name                            = "${local.prefix}-vm"
  computer_name                   = "cade-${substr(data.coder_workspace.me.id, 0, 8)}"
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.workspace.name
  size                            = "Standard_D16ds_v5"
  admin_username                  = "cadeadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.main[0].id]
  tags                            = local.tags

  # Azure requires a key; its private half was discarded. SSH access uses Coder.
  admin_ssh_key {
    username   = "cadeadmin"
    public_key = file("${path.module}/bootstrap.pub")
  }
  os_disk {
    name                 = "${local.prefix}-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
  custom_data = sensitive(base64encode(templatefile("${path.module}/cloud-init.tftpl", {
    init_script = base64encode(coder_agent.main.init_script)
    mount_home  = base64encode(file("${path.module}/mount-home.sh"))
  })))
}

resource "azurerm_virtual_machine_data_disk_attachment" "home" {
  count              = data.coder_workspace.me.start_count
  managed_disk_id    = azurerm_managed_disk.home.id
  virtual_machine_id = azurerm_linux_virtual_machine.main[0].id
  lun                = 10
  caching            = "ReadWrite"
}
