locals {
  network_resource_group_name        = "Z${var.environment.prefix}RG-${var.environment.name}-Network"
}

module "network-resource-group" {
  for_each = var.environment.region.secondary == null ? toset([var.environment.region.primary]) : toset([var.environment.region.primary, var.environment.region.secondary])
  source   = "./modules/resource-group"
  name     = "${local.network_resource_group_name}-${var.region_name_mapper[each.key]}"
  location = each.key
  tags     = merge(var.tags, { Region = each.key })
}

module "network" {
  for_each = var.network
  source   = "./modules/network"
  providers = {
    azurerm         = azurerm
    azurerm.hub     = azurerm.hub
    azurerm.bastion = azurerm.bastion
  }
  environment = {
    name   = var.environment.name
    type   = var.environment.type
    region = each.key
  }
  monitoring         = module.monitoring.monitoring[each.key]
  region_name_mapper = var.region_name_mapper
  resource_group     = module.network-resource-group[each.key]
  network = {
    location                = each.key
    address_space           = each.value.address_space
    subnet_address_prefixes = each.value.subnet_address_prefixes
    nsg                     = each.value.nsg
    nat_gateway             = each.value.nat_gateway
    dns_servers             = each.value.dns_servers
    internal_firewall_ip    = each.value.internal_firewall_ip
    private_dns_zone_links  = each.value.private_dns_zone_links
    peering                 = each.value.peering
    diagnostics             = each.value.diagnostics
  }
  tags = merge(var.tags, { Region = each.key })
}