output "resource_group" {
  value = {
    name = var.resource_group.name
    id   = var.resource_group.id
  }
}

output "vnet" {
  value = {
    name     = azurerm_virtual_network.vnet.name
    id       = azurerm_virtual_network.vnet.id
    location = azurerm_virtual_network.vnet.location
  }
}

output "subnets" {
  value = {
    for k, s in azurerm_subnet.subnets :
    k => {
      name = s.name
      id   = s.id
      cidr = s.address_prefixes
    }
  }
}
