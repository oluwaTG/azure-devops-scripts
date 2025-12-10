# ---------------------------------------------------------------
# Purpose: Create the network resources for the environment
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# Virtual network for the resources
# ---------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.environment.name}-${var.region_name_mapper[var.network.location]}"
  location            = var.network.location
  resource_group_name = var.resource_group.name
  address_space       = [var.network.address_space]

  dns_servers = var.network.dns_servers
  tags        = var.tags

  lifecycle {
    ignore_changes = [ddos_protection_plan, subnet]
  }
}

# ---------------------------------------------------------------
# Dynamic Subnets (Creates subnet for each prefix != null)
# ---------------------------------------------------------------
resource "azurerm_subnet" "subnets" {
  for_each = {
    for subnet_key, prefix in var.network.subnet_address_prefixes :
    subnet_key => prefix
    if prefix != null
  }

  name                 = "sn-${each.key}"      # <-- dynamic subnet name
  resource_group_name  = var.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value]

  private_endpoint_network_policies = "Enabled"
}

# ---------------------------------------------------------------
# Dynamic NSG Association 
# Only associates NSG if subnet exists AND var.network.nsg contains that key
# ---------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  for_each = {
    for subnet_key, prefix in var.network.subnet_address_prefixes :
    subnet_key => subnet_key
    if prefix != null && contains(keys(var.network.nsg), subnet_key)
  }

  subnet_id                 = azurerm_subnet.subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg[each.key].id
}
