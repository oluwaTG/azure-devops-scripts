terraform {

  backend "azurerm" {
    use_azuread_auth    = true
  }

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # version = "4.14.0" #tmp

      # version = "=3.106.1"
      # version = "~> 3.89"
    }
    azapi = {
      source = "Azure/azapi"
    }
    azuread = {
      source = "hashicorp/azuread"
      # version = "=2.7.0"
    }
  }
}

# Configure the Microsft Azure provider
provider "azurerm" {
  features {}
  storage_use_azuread = true
}

provider "azurerm" {
  features {}
  subscription_id = var.provider_aliases.azurerm.hub
  alias           = "hub"
  resource_provider_registrations = "none"
}

provider "azurerm" {
  features {}
  subscription_id = var.provider_aliases.azurerm.bastion
  alias           = "bastion"
  resource_provider_registrations = "none"
}

provider "azapi" {
}


