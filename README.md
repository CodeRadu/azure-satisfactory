# Azure Satisfactory

Deploy a Satisfactory server on Azure using Terraform.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html)
- An authenticated [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) session

## Usage

- Clone this repository
- Run `terraform init` to initialize the Terraform configuration
- Create a `terraform.tfvars` file with the following content:

```hcl
resource_group_name = "your_resource_group_name"
vm_type             = "your_vm_type"
location            = "your_location"
username            = "your_username"
public_key          = "your_public_key"
start_time          = "your_start_time"
stop_time           = "your_stop_time"
timezone            = "your_timezone"
```

- Replace the placeholders with your own values
- Run `terraform apply` to deploy the Satisfactory server. The server will automatically start and stop at the specified times every day.

## Optional

- You can ssh into the server using the credentials provided by the `terraform output` command.
