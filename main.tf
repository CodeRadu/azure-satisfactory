terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

variable "resource_group_name" {
  type        = string
  description = "The name of the resource group."
}

variable "vm_type" {
  type        = string
  default     = "Standard_B2als_v2"
  description = "The type of virtual machine."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "The location where the resources will be deployed."
}

variable "username" {
  type        = string
  description = "The username for the virtual machine."
}

variable "public_key" {
  type        = string
  description = "The public key for SSH authentication."
}

variable "data_disk_size" {
  type        = number
  description = "The size of the data disk in GB."
}

variable "enable_start_schedule" {
  type        = bool
  default     = true
  description = "Enable the schedule for starting the virtual machine."
}

variable "enable_stop_schedule" {
  type        = bool
  default     = true
  description = "Enable the schedule for stopping the virtual machine."
}

variable "start_time" {
  type        = string
  description = "The time when the virtual machine will start."
}

variable "stop_time" {
  type        = string
  description = "The time when the virtual machine will stop."
}

variable "timezone" {
  type        = string
  default     = "UTC"
  description = "The timezone for the schedule."
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags = {
    Provisioned = true
  }
}

resource "azurerm_virtual_network" "main" {
  name                = "network"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "main" {
  name                 = "subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_public_ip" "main" {
  name                = "public_ip"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSatisfactory"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_ranges    = ["7777", "15000", "15777"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_network_interface" "main" {
  name                = "nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  ip_configuration {
    name                          = "Internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "main" {
  name           = "satisfactory"
  admin_username = "adminuser"
  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.admin.public_key_openssh
  }
  resource_group_name   = azurerm_resource_group.main.name
  location              = var.location
  network_interface_ids = [azurerm_network_interface.main.id]
  size                  = var.vm_type
  os_disk {
    name                 = "os"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  priority        = "Spot"
  eviction_policy = "Deallocate"
  user_data = base64encode(templatefile("config.yaml", {
    username      = var.username
    public_key    = var.public_key
    smb_share_url = "//${azurerm_storage_account.data.primary_file_host}/${azurerm_storage_share.data.name}"
    smb_username  = azurerm_storage_share.data.storage_account_name
    smb_password  = azurerm_storage_account.data.primary_access_key
  }))
}

resource "random_id" "storage_suffix" {
  byte_length = 4
}

resource "azurerm_storage_account" "data" {
  name                     = "data${random_id.storage_suffix.hex}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
}

resource "azurerm_storage_account_network_rules" "data" {
  storage_account_id         = azurerm_storage_account.data.id
  default_action             = "Allow"
  virtual_network_subnet_ids = [azurerm_subnet.main.id]
}

resource "azurerm_storage_share" "data" {
  name                 = "saves"
  storage_account_name = azurerm_storage_account.data.name
  access_tier          = "Hot"
  quota                = 10
  enabled_protocol     = "SMB"
  lifecycle {
    prevent_destroy = true # Prevent accidental deletion
  }
}

data "azurerm_subscription" "primary" {}

resource "azurerm_user_assigned_identity" "subscription" {
  count               = var.enable_start_schedule || var.enable_stop_schedule ? 1 : 0
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name                = "uaid"
}

resource "azurerm_role_assignment" "uami" {
  count                = var.enable_start_schedule || var.enable_stop_schedule ? 1 : 0
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.subscription[0].principal_id
}

resource "azurerm_automation_account" "scheduler" {
  count               = var.enable_start_schedule || var.enable_stop_schedule ? 1 : 0
  name                = "vm-scheduler-${var.resource_group_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.subscription[0].id]
  }
}

resource "azurerm_automation_runbook" "vm_power" {
  count                   = var.enable_start_schedule || var.enable_stop_schedule ? 1 : 0
  name                    = "vm-power-runbook"
  location                = var.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler[0].name
  runbook_type            = "PowerShell"
  content                 = <<EOF
    Param(
      [string]$powerstate
    )

    $resourcegroupname = "${azurerm_resource_group.main.name}"
    $vmname            = "${azurerm_linux_virtual_machine.main.name}"
    $uami              = "${azurerm_user_assigned_identity.subscription[0].client_id}"
    $automationaccount = "${azurerm_automation_account.scheduler[0].name}"

    $null = Disable-AzContextAutosave -Scope Process
   
    $AzureConnection = (Connect-AzAccount -Identity -AccountId $uami).context

    $AzureConnection
    $AzureContext = Set-AzContext -SubscriptionName $AzureConnection.Subscription -DefaultProfile $AzureConnection

    if ($powerstate -eq "start") {
      Start-AzVM -ResourceGroupName $resourcegroupname -Name $vmname -DefaultProfile $AzureContext
    } elseif ($powerstate -eq "stop") {
      Stop-AzVM -ResourceGroupName $resourcegroupname -Name $vmname -Force -DefaultProfile $AzureContext
    }
  EOF

  log_verbose  = false
  log_progress = true
}

resource "azurerm_automation_schedule" "start_vm" {
  count                   = var.enable_start_schedule ? 1 : 0
  name                    = "start-vm-schedule"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler[0].name
  frequency               = "Day"
  start_time              = var.start_time
  timezone                = var.timezone
}

resource "azurerm_automation_job_schedule" "start_vm" {
  count                   = var.enable_start_schedule ? 1 : 0
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler[0].name
  runbook_name            = azurerm_automation_runbook.vm_power[0].name
  schedule_name           = azurerm_automation_schedule.start_vm[0].name

  parameters = {
    powerstate = "start"
  }
}

resource "azurerm_automation_schedule" "stop_vm" {
  count                   = var.enable_stop_schedule ? 1 : 0
  name                    = "stop-vm-schedule"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler[0].name
  frequency               = "Day"
  start_time              = var.stop_time
  timezone                = var.timezone
}

resource "azurerm_automation_job_schedule" "stop_vm" {
  count                   = var.enable_stop_schedule ? 1 : 0
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler[0].name
  runbook_name            = azurerm_automation_runbook.vm_power[0].name
  schedule_name           = azurerm_automation_schedule.stop_vm[0].name

  parameters = {
    powerstate = "stop"
  }
}

output "username" {
  value = var.username
}

output "public_ip" {
  value = azurerm_public_ip.main.ip_address
}

output "start_schedule_enabled" {
  value = var.enable_start_schedule
}

output "stop_schedule_enabled" {
  value = var.enable_stop_schedule
}

output "start_time" {
  value = formatdate("hh:mm", var.start_time)
}

output "stop_time" {
  value = formatdate("hh:mm", var.stop_time)
}
