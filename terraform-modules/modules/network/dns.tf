
resource "azurerm_private_dns_zone_virtual_network_link" "dns-zone-link" {
  for_each              = toset(var.network.private_dns_zone_links)
  provider              = azurerm.hub
  name                  = "${azurerm_virtual_network.vnet.name}-link"
  resource_group_name   = element(split("/", each.value), 4)
  private_dns_zone_name = element(split("/", each.value), 8)
  virtual_network_id    = azurerm_virtual_network.vnet.id
  tags                  = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}
