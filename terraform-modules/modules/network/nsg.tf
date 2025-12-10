# ---------------------------------------------------------------
# Dynamic Network Security Groups
# ---------------------------------------------------------------

resource "azurerm_network_security_group" "nsg" {
  for_each = var.network.nsg  # each key is the subnet name (e.g., web, db, appgw)

  name                = "nsg-${each.key}"
  location            = var.network.location
  resource_group_name = var.resource_group.name
  tags                = var.tags

  # Dynamic rules
  dynamic "security_rule" {
    for_each = each.value  # each.value is the map of rules (e.g., AllowSSH, AllowAppGW)

    content {
      name                        = security_rule.key
      priority                    = security_rule.value.priority
      protocol                    = lookup(security_rule.value, "protocol", "Tcp")
      source_port_range           = "*"
      source_address_prefix       = security_rule.value.ip_range
      destination_address_prefix  = "*"
      destination_port_ranges     = split(",", security_rule.value.port)
      access                      = lookup(security_rule.value, "action", "Allow")
      direction                   = lookup(security_rule.value, "direction", "Inbound")
    }
  }
}
