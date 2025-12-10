variable "environment" {
  type = object({
    name = string
    type = string           # dev,test,prod
    geo  = optional(string) 
    prefix = string
    region = object({
      primary   = string
      secondary = string
    })
    zones = map(list(number))
  })
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment.type)
    error_message = "Valid values for var: environment.type are (dev, test, prod)."
  }
}

variable "region_name_mapper" {
  type = map(string)
  default = {
    "canadacentral"             = "CA"
  }
}

variable "provider_aliases" {
  type = object({
    azurerm = object({
      hub     = string # subscription id
      bastion = string # subscription id
    })
  })
}

variable "network" {
  type = map(object({
    address_space = string
    subnet_address_prefixes = map(string)
    nsg = optional(map(map(object({ # subnet -> rule -> (ip_range, port, priority, action)
      ip_range = string
      port     = string
      priority = number
      action   = optional(string, "Allow")
      direction = optional(string, "Inbound")
      protocol  = optional(string, "Tcp")
    }))), {})
    nat_gateway            = bool
    dns_servers            = list(string)
    internal_firewall_ip   = string
    private_dns_zone_links = list(string)
    peering = object({
      enabled = bool
      vnets = map(object({
        vnet_name           = string
        resource_group_name = string
        vnet_id             = string
      }))
    })
    diagnostics = optional(bool, true)
  }))
}

variable "tags" {
  type = map(string)
}
