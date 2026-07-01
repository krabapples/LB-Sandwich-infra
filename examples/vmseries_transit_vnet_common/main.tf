# Create or source a Resource Group

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group
resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = "${var.name_prefix}${var.resource_group_name}"
  location = var.region

  tags = var.tags
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group
data "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

locals {
  resource_group = var.create_resource_group ? azurerm_resource_group.this[0] : data.azurerm_resource_group.this[0]
}

# Manage the network required for the topology

module "vnet" {
  source = "../../modules/vnet"

  for_each = var.vnets

  name                   = each.value.create_virtual_network ? "${var.name_prefix}${each.value.name}" : each.value.name
  create_virtual_network = each.value.create_virtual_network
  resource_group_name    = coalesce(each.value.resource_group_name, local.resource_group.name)
  region                 = var.region

  address_space           = each.value.address_space
  dns_servers             = each.value.dns_servers
  vnet_encryption         = each.value.vnet_encryption
  ddos_protection_plan_id = each.value.ddos_protection_plan_id

  subnets = each.value.subnets

  network_security_groups = {
    for k, v in each.value.network_security_groups : k => merge(v, { name = "${var.name_prefix}${v.name}" })
  }
  route_tables = {
    for k, v in each.value.route_tables : k => merge(v, { name = "${var.name_prefix}${v.name}" })
  }

  tags = var.tags
}

module "vnet_peering" {
  source = "../../modules/vnet_peering"

  for_each = var.vnet_peerings

  local_peer_config = {
    name                = "peer-${each.value.local_vnet_name}-to-${each.value.remote_vnet_name}"
    resource_group_name = coalesce(each.value.local_resource_group_name, local.resource_group.name)
    vnet_name           = each.value.local_vnet_name
  }
  remote_peer_config = {
    name                = "peer-${each.value.remote_vnet_name}-to-${each.value.local_vnet_name}"
    resource_group_name = coalesce(each.value.remote_resource_group_name, local.resource_group.name)
    vnet_name           = each.value.remote_vnet_name
  }

  depends_on = [module.vnet]
}

module "public_ip" {
  source = "../../modules/public_ip"

  region = var.region
  public_ip_addresses = {
    for k, v in var.public_ips.public_ip_addresses : k => merge(v, {
      name                = "${var.name_prefix}${v.name}"
      resource_group_name = coalesce(v.resource_group_name, local.resource_group.name)
    })
  }
  public_ip_prefixes = {
    for k, v in var.public_ips.public_ip_prefixes : k => merge(v, {
      name                = "${var.name_prefix}${v.name}"
      resource_group_name = coalesce(v.resource_group_name, local.resource_group.name)
    })
  }

  tags = var.tags
}

module "natgw" {
  source = "../../modules/natgw"

  for_each = var.natgws

  create_natgw        = each.value.create_natgw
  name                = each.value.create_natgw ? "${var.name_prefix}${each.value.name}" : each.value.name
  resource_group_name = coalesce(each.value.resource_group_name, local.resource_group.name)
  region              = var.region
  zone                = try(each.value.zone, null)
  idle_timeout        = each.value.idle_timeout
  subnet_ids          = { for v in each.value.subnet_keys : v => module.vnet[each.value.vnet_key].subnet_ids[v] }

  public_ip = try(merge(each.value.public_ip, {
    name = "${each.value.public_ip.create ? var.name_prefix : ""}${each.value.public_ip.name}"
    id   = try(module.public_ip.pip_ids[each.value.key], null)
  }), null)
  public_ip_prefix = try(merge(each.value.public_ip_prefix, {
    name = "${each.value.public_ip_prefix.create ? var.name_prefix : ""}${each.value.public_ip_prefix.name}"
    id   = try(module.public_ip.ippre_ids[each.value.key], null)
  }), null)

  tags       = var.tags
  depends_on = [module.vnet]
}

# Create test infrastructure

resource "random_password" "test" {
  count = anytrue([for _, v in var.test_infrastructure : v.authentication.password == null]) ? 1 : 0

  length           = 16
  min_lower        = 16 - 4
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "_%@"
}

locals {
  test_vm_authentication = {
    for k, v in var.test_infrastructure : k =>
    merge(
      v.authentication,
      {
        password = coalesce(v.authentication.password, try(random_password.test[0].result, null))
      }
    )
  }

  web_server_cloud_init = <<-EOT
    #cloud-config
    write_files:
      - path: /var/www/html/index.html
        content: |
          <html><body>Initializing...</body></html>
      - path: /etc/systemd/system/http-server.service
        content: |
          [Unit]
          Description=Simple HTTP server
          After=network.target
          [Service]
          ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www/html
          Restart=always
          [Install]
          WantedBy=multi-user.target
      - path: /usr/local/bin/https-server.py
        content: |
          import ssl, http.server
          ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
          ctx.load_cert_chain('/tmp/cert.pem', '/tmp/key.pem')
          srv = http.server.HTTPServer(
              ('', 443), http.server.SimpleHTTPRequestHandler)
          srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
          srv.serve_forever()
      - path: /etc/systemd/system/https-server.service
        content: |
          [Unit]
          Description=Simple HTTPS server
          After=network.target
          [Service]
          ExecStartPre=/usr/bin/openssl req -x509 -newkey rsa:2048 \
              -keyout /tmp/key.pem -out /tmp/cert.pem \
              -days 365 -nodes -subj "/CN=localhost"
          ExecStart=/usr/bin/python3 /usr/local/bin/https-server.py
          WorkingDirectory=/var/www/html
          Restart=always
          [Install]
          WantedBy=multi-user.target
    runcmd:
      - echo "<html><body>Hello from $(hostname)</body></html>" > /var/www/html/index.html
      - systemctl daemon-reload
      - systemctl enable http-server https-server
      - systemctl start http-server https-server
  EOT
}

module "test_infrastructure" {
  source = "../../modules/test_infrastructure"

  for_each = var.test_infrastructure

  resource_group_name = try(
    "${var.name_prefix}${each.value.resource_group_name}", "${local.resource_group.name}-testenv"
  )
  region = var.region
  vnets = { for k, v in each.value.vnets : k => merge(v, {
    name = "${var.name_prefix}${v.name}"
    hub_vnet_name = try(var.vnets[v.hub_vnet_key].create_virtual_network ?
    "${var.name_prefix}${var.vnets[v.hub_vnet_key].name}" : var.vnets[v.hub_vnet_key].name, null)
    hub_resource_group_name = try(
      coalesce(var.vnets[v.hub_vnet_key].resource_group_name, local.resource_group.name), null
    )
    network_security_groups = { for kv, vv in v.network_security_groups : kv => merge(vv, {
      name = "${var.name_prefix}${vv.name}" })
    }
    route_tables = { for kv, vv in v.route_tables : kv => merge(vv, {
      name = "${var.name_prefix}${vv.name}" })
    }
    local_peer_config  = try(v.local_peer_config, {})
    remote_peer_config = try(v.remote_peer_config, {})
  }) }
  load_balancers = { for k, v in each.value.load_balancers : k => merge(v, {
    name         = "${var.name_prefix}${v.name}"
    backend_name = coalesce(v.backend_name, "${v.name}-backend")
    public_ip_name = v.frontend_ips.create_public_ip ? (
      "${var.name_prefix}${v.frontend_ips.public_ip_name}"
    ) : v.frontend_ips.public_ip_name
    public_ip_id             = try(module.public_ip.pip_ids[v.frontend_ips.public_ip_key], null)
    public_ip_address        = try(module.public_ip.pip_ip_addresses[v.frontend_ips.public_ip_key], null)
    public_ip_prefix_id      = try(module.public_ip.ippre_ids[v.frontend_ips.public_ip_prefix_key], null)
    public_ip_prefix_address = try(module.public_ip.ippre_ip_prefixes[v.frontend_ips.public_ip_prefix_key], null)
  }) }
  authentication = local.test_vm_authentication[each.key]
  spoke_vms = { for k, v in each.value.spoke_vms : k => merge(v, {
    name           = "${var.name_prefix}${v.name}"
    interface_name = "${var.name_prefix}${coalesce(v.interface_name, "${v.name}-nic")}"
    disk_name      = "${var.name_prefix}${coalesce(v.disk_name, "${v.name}-osdisk")}"
    custom_data    = base64encode(coalesce(v.custom_data, local.web_server_cloud_init))
  }) }
  bastions = { for k, v in each.value.bastions : k => merge(v, {
    name           = "${var.name_prefix}${v.name}"
    public_ip_name = v.public_ip_key != null ? null : "${var.name_prefix}${coalesce(v.public_ip_name, "${v.name}-pip")}"
    public_ip_id   = try(module.public_ip.pip_ids[v.public_ip_key], null)
  }) }

  tags       = var.tags
  depends_on = [module.vnet]
}
