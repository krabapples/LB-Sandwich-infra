# GENERAL

subscription_id = null # TODO: Put the Azure Subscription ID here only in case you cannot use an environment variable!

region              = "North Europe"
resource_group_name = "transit-vnet-common"
name_prefix         = "example-"
tags = {
  "createdBy"     = "Palo Alto Networks"
  "createdWith"   = "Terraform"
  "xdr-exclusion" = "yes"
}

# NETWORK

vnets = {
  "transit" = {
    name          = "transit"
    address_space = ["10.0.0.0/25"]
    network_security_groups = {
      "management" = {
        name = "mgmt-nsg"
        rules = {
          mgmt_inbound = {
            name                       = "vmseries-management-allow-inbound"
            priority                   = 100
            direction                  = "Inbound"
            access                     = "Allow"
            protocol                   = "Tcp"
            source_address_prefixes    = ["1.1.1.1/32"] # TODO: Whitelist IP addresses that will be used to manage the appliances
            source_port_range          = "*"
            destination_address_prefix = "10.0.0.0/28"
            destination_port_ranges    = ["22", "443"]
          }
        }
      }
      "public" = {
        name = "public-nsg"
      }
    }
    route_tables = {
      "management" = {
        name = "mgmt-rt"
        routes = {
          "public_blackhole" = {
            name           = "public-blackhole-udr"
            address_prefix = "10.0.0.16/28"
            next_hop_type  = "None"
          }
          "private_blackhole" = {
            name           = "private-blackhole-udr"
            address_prefix = "10.0.0.32/28"
            next_hop_type  = "None"
          }
        }
      }
      "public" = {
        name = "public-rt"
        routes = {
          "mgmt_blackhole" = {
            name           = "mgmt-blackhole-udr"
            address_prefix = "10.0.0.0/28"
            next_hop_type  = "None"
          }
          "private_blackhole" = {
            name           = "private-blackhole-udr"
            address_prefix = "10.0.0.32/28"
            next_hop_type  = "None"
          }
        }
      }
      "private" = {
        name = "private-rt"
        routes = {
          "default" = {
            name                = "default-udr"
            address_prefix      = "0.0.0.0/0"
            next_hop_type       = "VirtualAppliance"
            next_hop_ip_address = "10.0.0.46"
          }
          "mgmt_blackhole" = {
            name           = "mgmt-blackhole-udr"
            address_prefix = "10.0.0.0/28"
            next_hop_type  = "None"
          }
          "public_blackhole" = {
            name           = "public-blackhole-udr"
            address_prefix = "10.0.0.16/28"
            next_hop_type  = "None"
          }
        }
      }
    }
    subnets = {
      "management" = {
        name                            = "mgmt-snet"
        address_prefixes                = ["10.0.0.0/28"]
        network_security_group_key      = "management"
        route_table_key                 = "management"
        enable_storage_service_endpoint = true
      }
      "public" = {
        name                       = "public-snet"
        address_prefixes           = ["10.0.0.16/28"]
        network_security_group_key = "public"
        route_table_key            = "public"
      }
      "private" = {
        name             = "private-snet"
        address_prefixes = ["10.0.0.32/28"]
        route_table_key  = "private"
      }
    }
  }
}

vnet_peerings = {
  /* Uncomment the section below to peer Transit VNET with Panorama VNET (if you have one)
  "vmseries-to-panorama" = {
    local_vnet_name            = "example-transit"
    remote_vnet_name           = "example-panorama-vnet"
    remote_resource_group_name = "example-panorama"
  }
  */
}

# LOAD BALANCING

load_balancers = {
  "public" = {
    name = "public-lb"
    nsg_auto_rules_settings = {
      nsg_vnet_key = "transit"
      nsg_key      = "public"
      source_ips   = ["1.1.1.1/32"] # TODO: Whitelist public IP addresses that will be used to access LB
    }
    health_probes = {
      http = {
        name         = "http-probe"
        protocol     = "Http"
        request_path = "/unauth/php/health.php"
      }
    }
    frontend_ips = {
      "app1" = {
        name             = "app1"
        public_ip_name   = "public-lb-app1-pip"
        create_public_ip = true
        in_rules = {
          "balanceHttp" = {
            name             = "HTTP"
            protocol         = "Tcp"
            port             = 80
            health_probe_key = "http"
          }
        }
      }
    }
  }
  "private" = {
    name     = "private-lb"
    vnet_key = "transit"
    health_probes = {
      http = {
        name         = "http-probe"
        protocol     = "Http"
        request_path = "/unauth/php/health.php"
      }
    }
    frontend_ips = {
      "ha-ports" = {
        name               = "private-vmseries"
        subnet_key         = "private"
        private_ip_address = "10.0.0.46"
        in_rules = {
          HA_PORTS = {
            name             = "HA-ports"
            port             = 0
            protocol         = "All"
            health_probe_key = "http"
          }
        }
      }
    }
  }
}

appgws = {}

vmseries        = {}
test_infrastructure = {}
