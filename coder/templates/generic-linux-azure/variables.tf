variable "subscription_id" {
  description = "Deployment subscription ID; authentication comes from the provisioner managed identity."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "location" {
  description = "Approved Azure region for workspace-owned resources, e.g. swedencentral."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure region name without spaces."
  }
}

variable "resource_group_name" {
  description = "Existing workspace resource group; never managed or deleted by this template."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_.()-]{1,90}$", var.resource_group_name)) && !endswith(var.resource_group_name, ".")
    error_message = "resource_group_name must be a valid existing resource group name."
  }
}

variable "subnet_id" {
  description = "Existing subnet resource ID in the same subscription; its network RG may differ from the workspace RG."
  type        = string
  validation {
    condition     = can(regex("(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.subnet_id))
    error_message = "subnet_id must be a full Azure subnet resource ID."
  }
}

variable "managed_identity_client_id" {
  description = "Optional user-assigned provisioner identity client ID; empty selects the environment/system identity. Never assigned to workspace VMs."
  type        = string
  default     = ""
  validation {
    condition     = var.managed_identity_client_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.managed_identity_client_id))
    error_message = "managed_identity_client_id must be empty or a UUID."
  }
}
