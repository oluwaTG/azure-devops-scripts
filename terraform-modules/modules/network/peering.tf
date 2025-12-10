// vNET Peering with vNET HUB

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # version               = "~> 3.89"
      configuration_aliases = [azurerm.hub, azurerm.bastion]
    }
  }
}

locals {
  hub     = lookup(var.network.peering.vnets, "hub", null)
  bastion = lookup(var.network.peering.vnets, "bastion", null)
  vnets = {
    for k, v in var.network.peering.vnets : k => v
    if startswith(v.vnet_name, "vnet") && !contains(["hub", "bastion"], k)
  }
}

data "azurerm_virtual_network" "hub" {
  count               = var.network.peering.enabled == true && local.hub != null ? 1 : 0
  provider            = azurerm.hub
  name                = local.hub.vnet_name
  resource_group_name = local.hub.resource_group_name
}

resource "azurerm_virtual_network_peering" "hub_peering" {
  count = var.network.peering.enabled == true && local.hub != null ? 1 : 0

  name                         = "${azurerm_virtual_network.vnet.name}-to-${local.hub.vnet_name}"
  resource_group_name          = var.resource_group.name
  virtual_network_name         = azurerm_virtual_network.vnet.name
  remote_virtual_network_id    = local.hub.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = true
}

resource "azurerm_virtual_network_peering" "hub_to_vnet_peering" {
  count                        = var.network.peering.enabled == true && local.hub != null ? 1 : 0
  provider                     = azurerm.hub
  name                         = "${local.hub.vnet_name}-to-${azurerm_virtual_network.vnet.name}"
  resource_group_name          = data.azurerm_virtual_network.hub[0].resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.hub[0].name
  remote_virtual_network_id    = azurerm_virtual_network.vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
}


resource "azurerm_virtual_network_peering" "vnets_peering" {
  for_each                     = local.vnets
  name                         = "${azurerm_virtual_network.vnet.name}-to-${each.value.vnet_name}"
  resource_group_name          = var.resource_group.name
  virtual_network_name         = azurerm_virtual_network.vnet.name
  remote_virtual_network_id    = each.value.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}