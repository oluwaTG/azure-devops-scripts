# # Resource health alerts for NAT gateway.

# resource "azurerm_monitor_activity_log_alert" "resource_health" {
#   for_each            = var.network 
#   name                = "alert-${azurerm_virtual_network.vnet[each.key].name}-resource-health"
#   resource_group_name = var.monitoring.resource_group.name
#   location            = "global"
#   scopes              = [azurerm_virtual_network.vnet[each.key].id]
#   description         = "Alert triggers when ${azurerm_virtual_network.vnet[each.key].name} resource Health is  Degraded, Unavailable and Unknown."

#   # Define alert conditions
#   criteria {
#     category = "ResourceHealth"
#     level    = "Critical"
#     resource_health {
#       current  = ["Degraded", "Unavailable", "Unknown"]
#       previous = ["Available", "Degraded", "Unavailable", "Unknown"]
#       reason   = ["PlatformInitiated", "UserInitiated", "Unknown"]
#     }
#     resource_type = "Microsoft.Network/virtualNetworks"
#   }
#   dynamic "action" {
#     for_each = var.monitoring.platform_action_groups
#     content {
#       action_group_id = action.value.id
#     }
#   }
#   enabled = true
#   tags    = var.tags
# }
