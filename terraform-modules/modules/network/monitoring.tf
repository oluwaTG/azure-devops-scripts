locals {
  log_categories    = ["VMprotectionalerts"]
  metric_categories = ["AllMetrics"]
}

resource "azurerm_monitor_diagnostic_setting" "settings" {
  count                          = var.monitoring.diagnostics.enabled && var.network.diagnostics ? 1 : 0
  name                           = azurerm_virtual_network.vnet.name
  target_resource_id             = azurerm_virtual_network.vnet.id
  log_analytics_workspace_id     = var.monitoring.log_analytics.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = local.log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = local.metric_categories
    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    ignore_changes = [log_analytics_destination_type]
  }
}
