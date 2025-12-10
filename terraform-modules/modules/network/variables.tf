
variable "environment" {
  type = object({
    name   = string
    type   = string # non-prod, prod
    region = string
  })
}

variable "region_name_mapper" {
  type = map(string)
}

variable "resource_group" {
  type = object({
    name = string
    id   = string
  })
}

variable "network" {
  type = object({
    address_space = string
    location      = string
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
  })
}

variable "tags" {
  type = map(string)
}

variable "monitoring" {
  type = object({
    resource_group = object({
      name = string
      id   = string
    })
    action_groups = map(object({
      name = string
      id   = string
      resource_group = object({
        name = string
        id   = string
      })
    }))
    platform_action_groups = map(object({
      name = string
      id   = string
      resource_group = object({
        name = string
        id   = string
      })
    }))
    diagnostics = object({
      enabled = bool
    })
    log_analytics = object({
      name = string
      id   = string
      resource_group = object({
        name = string
        id   = string
      })
    })
  })
}
