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
    username   = var.username
    public_key = var.public_key
  }))
}

resource "azurerm_managed_disk" "home" {
  name                 = "home"
  location             = var.location
  resource_group_name  = azurerm_resource_group.main.name
  create_option        = "Empty"
  storage_account_type = "Standard_LRS"
  disk_size_gb         = "16"
}

resource "azurerm_virtual_machine_data_disk_attachment" "home" {
  managed_disk_id    = azurerm_managed_disk.home.id
  virtual_machine_id = azurerm_linux_virtual_machine.main.id
  lun                = 10
  caching            = "ReadWrite"
}

data "azurerm_subscription" "primary" {}

resource "azurerm_user_assigned_identity" "subscription" {
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name                = "uaid"
}

resource "azurerm_role_assignment" "uami" {
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.subscription.principal_id
}

resource "azurerm_automation_account" "scheduler" {
  name                = "vm-scheduler-${var.resource_group_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.subscription.id]
  }
}

resource "azurerm_automation_runbook" "vm_power" {
  name                    = "vm-power-runbook"
  location                = var.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler.name
  runbook_type            = "PowerShell"
  content                 = <<EOF
    Param(
      [string]$powerstate
    )

    $resourcegroupname = "${azurerm_resource_group.main.name}"
    $vmname            = "${azurerm_linux_virtual_machine.main.name}"
    $uami              = "${azurerm_user_assigned_identity.subscription.client_id}"
    $automationaccount = "${azurerm_automation_account.scheduler.name}"

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
  name                    = "start-vm-schedule"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler.name
  frequency               = "Day"
  start_time              = var.start_time
  timezone                = var.timezone
}

resource "azurerm_automation_job_schedule" "start_vm" {
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler.name
  runbook_name            = azurerm_automation_runbook.vm_power.name
  schedule_name           = azurerm_automation_schedule.start_vm.name

  parameters = {
    powerstate = "start"
  }
}

resource "azurerm_automation_schedule" "stop_vm" {
  name                    = "stop-vm-schedule"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler.name
  frequency               = "Day"
  start_time              = var.stop_time
  timezone                = var.timezone
}

resource "azurerm_automation_job_schedule" "stop_vm" {
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.scheduler.name
  runbook_name            = azurerm_automation_runbook.vm_power.name
  schedule_name           = azurerm_automation_schedule.stop_vm.name

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

output "start_time" {
  value = formatdate("hh:mm", azurerm_automation_schedule.start_vm.start_time)
}

output "stop_time" {
  value = formatdate("hh:mm", azurerm_automation_schedule.stop_vm.start_time)
}
