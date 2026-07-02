# LB-Sandwich-infra

Terraform deployment for the **network infrastructure layer** of an Azure load balancer sandwich (transit VNet) topology. This repository provisions the VNet, subnets, NSGs, route tables, NAT gateways, and optional test infrastructure — everything the firewalls need to run, but without the firewalls themselves.

The firewall and load balancer layer is deployed separately by [LB-Sandwich-fw](https://github.com/krabapples/LB-Sandwich-fw).

---

## Architecture

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │  Public LB  │  (deployed in LB-Sandwich-fw)
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
       ┌──────▼──────┐           ┌──────▼──────┐
       │  VM-Series  │           │  VM-Series  │   (deployed in LB-Sandwich-fw)
       └──────┬──────┘           └──────┬──────┘
              └────────────┬────────────┘
                    ┌──────▼──────┐
                    │  Private LB │  (deployed in LB-Sandwich-fw)
                    └──────┬──────┘
                           │
            ┌──────────────┴──────────────┐
     ┌──────▼──────┐               ┌──────▼──────┐
     │  App1 VNet  │               │  App2 VNet  │   (optional test infra, deployed here)
     │  + Bastion  │               │  + Bastion  │
     └─────────────┘               └─────────────┘
```

### Transit VNet subnets

| Subnet       | CIDR           | Purpose                                            |
|--------------|----------------|----------------------------------------------------|
| management   | 10.0.0.0/28    | Firewall management interfaces; NSG + route table  |
| public       | 10.0.0.16/28   | Firewall untrust interfaces; NSG + route table     |
| private      | 10.0.0.32/28   | Firewall trust interfaces; route table             |

Route tables enforce blackhole routes between subnets to prevent traffic from bypassing the firewalls.

---

## What this repository deploys

| Resource | Description |
|---|---|
| `azurerm_resource_group` | Resource group for all resources (optional — can use existing) |
| `azurerm_virtual_network` | Transit VNet containing all firewall subnets |
| `azurerm_subnet` | Management, public, and private subnets |
| `azurerm_network_security_group` | NSG for management subnet (restricts SSH/HTTPS to whitelisted IPs) and public subnet |
| `azurerm_route_table` | UDRs per subnet enforcing blackhole routes and default route via firewall |
| `azurerm_virtual_network_peering` | Optional peering to Panorama VNet or spoke VNets |
| `azurerm_public_ip` / `azurerm_public_ip_prefix` | Optional pre-allocated public IPs or prefixes |
| `azurerm_nat_gateway` | Optional NAT Gateway for outbound internet access |
| Test VNets + VMs + Azure Bastion | Optional spoke VNets with test VMs and Bastion hosts for validating firewall traffic |

---

## Prerequisites

- Terraform >= 1.5
- Azure CLI authenticated (`az login`) **or** the `ARM_SUBSCRIPTION_ID` environment variable set
- An Azure subscription with sufficient quota for the resources above

No existing Azure resources are required — this repository can start from scratch.

---

## Usage

### Step 1 — Clone the repository

```bash
git clone https://github.com/krabapples/LB-Sandwich-infra.git
cd LB-Sandwich-infra
```

### Step 2 — Create your tfvars file

```bash
cp example.tfvars terraform.tfvars
```

Open `terraform.tfvars` and fill in the required values (see [Variable reference](#variable-reference) below).

### Step 3 — Initialize Terraform

```bash
terraform init
```

This will download all modules from the PaloAltoNetworks GitHub repository (pinned to `v3.5.1`).

### Step 4 — Review the plan

```bash
terraform plan -var-file=terraform.tfvars
```

### Step 5 — Deploy

```bash
terraform apply -var-file=terraform.tfvars
```

### Step 6 — Pass outputs to LB-Sandwich-fw

After a successful apply, retrieve the subnet IDs needed by [LB-Sandwich-fw](https://github.com/krabapples/LB-Sandwich-fw):

```bash
terraform output subnet_ids
```

Copy the values into the `subnet_ids` variable in your LB-Sandwich-fw `terraform.tfvars`.

---

## Variable reference

### General

| Variable | Type | Default | Description |
|---|---|---|---|
| `subscription_id` | `string` | — | Azure Subscription ID. Can be omitted if `ARM_SUBSCRIPTION_ID` env var is set |
| `name_prefix` | `string` | `""` | Prefix added to all created resource names |
| `create_resource_group` | `bool` | `true` | When `true`, creates a new resource group. When `false`, sources an existing one by `resource_group_name` |
| `resource_group_name` | `string` | — | Name of the resource group to create or source |
| `region` | `string` | — | Azure region for all resources |
| `tags` | `map(string)` | `{}` | Tags applied to all resources |

### Network

| Variable | Type | Default | Description |
|---|---|---|---|
| `vnets` | `map(object)` | — | VNet definitions including subnets, NSGs, and route tables. See below |
| `vnet_peerings` | `map(object)` | `{}` | VNet peering configurations (e.g. to Panorama) |
| `public_ips` | `object` | — | Pre-allocated public IP addresses and prefixes |
| `natgws` | `map(object)` | `{}` | NAT Gateway definitions |

#### VNet structure

Each entry in `vnets` supports:
- `name` — VNet name
- `address_space` — list of CIDR blocks
- `subnets` — map of subnet definitions, each with:
  - `name`, `address_prefixes`
  - `network_security_group_key` — links to an NSG defined in the same VNet entry
  - `route_table_key` — links to a route table defined in the same VNet entry
  - `enable_storage_service_endpoint` — set to `true` on management subnet for bootstrap storage access
- `network_security_groups` — map of NSG definitions with inbound/outbound rules
- `route_tables` — map of route table definitions with UDR entries

#### Route table design

The example uses blackhole UDRs to enforce traffic through the firewalls:

| Route table | Blackhole routes | Purpose |
|---|---|---|
| mgmt-rt | public subnet, private subnet | Prevents management subnet from routing directly into the dataplane |
| public-rt | mgmt subnet, private subnet | Prevents the untrust interface from reaching management or trust |
| private-rt | mgmt subnet, public subnet; default → firewall | Forces all outbound traffic from trust through the firewall |

### Test infrastructure (optional)

| Variable | Type | Default | Description |
|---|---|---|---|
| `test_infrastructure` | `map(object)` | `{}` | Spoke VNets with test VMs and Azure Bastion hosts, peered to the transit VNet |

Each test environment entry supports:
- `vnets` — spoke VNet with subnets, NSGs, and route tables. Set `hub_vnet_key` to peer it to the transit VNet
- `spoke_vms` — Linux test VMs that run a simple HTTP/HTTPS server on startup (via cloud-init)
- `bastions` — Azure Bastion host for accessing test VMs without a public IP
- `authentication` — admin credentials for the test VMs (password auto-generated if not set)

The spoke VMs boot with a minimal web server (`python3 -m http.server`) so you can immediately test HTTP traffic through the firewalls after deployment.

---

## Outputs

| Output | Description |
|---|---|
| `subnet_ids` | Resource IDs for each subnet in each VNet. Pass the transit VNet subnet IDs to LB-Sandwich-fw |
| `natgw_public_ips` | Public IP addresses assigned to NAT Gateways |
| `test_vms_usernames` | Admin username for test VMs |
| `test_vms_passwords` | Admin password for test VMs (sensitive) |
| `test_vms_ips` | Private IP addresses of test VMs |
| `test_lb_frontend_ips` | Frontend IPs of test load balancers (if configured) |

### Getting subnet IDs for LB-Sandwich-fw

```bash
terraform output subnet_ids
```

This returns a nested map. The values you need for LB-Sandwich-fw are under the `"transit"` key:

```hcl
subnet_ids = {
  "transit" = {
    "management" = "/subscriptions/.../subnets/mgmt-snet"
    "public"     = "/subscriptions/.../subnets/public-snet"
    "private"    = "/subscriptions/.../subnets/private-snet"
  }
}
```

---

## Relationship with LB-Sandwich-fw

This repository is intentionally decoupled from the firewall layer. The split allows you to:

- Deploy or tear down firewalls independently without touching the network
- Reuse the same network for multiple firewall deployments (e.g. staging vs. production firewalls)
- Drop firewalls in from [LB-Sandwich-fw](https://github.com/krabapples/LB-Sandwich-fw) or any other deployment tool

When using both repositories together, the typical workflow is:

```
1. terraform apply  (in LB-Sandwich-infra)  →  network ready
2. terraform output subnet_ids              →  copy transit VNet subnet IDs
3. Fill subnet_ids into terraform.tfvars    (in LB-Sandwich-fw)
4. terraform apply  (in LB-Sandwich-fw)     →  firewalls and LBs ready
```

---

## Module sources

All modules are sourced from the upstream PaloAltoNetworks repository, pinned to a specific release:

```
github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules//modules/vnet?ref=v3.5.1
github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules//modules/vnet_peering?ref=v3.5.1
github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules//modules/public_ip?ref=v3.5.1
github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules//modules/natgw?ref=v3.5.1
github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules//modules/test_infrastructure?ref=v3.5.1
```

To upgrade to a newer release, update the `?ref=` tag in `main.tf` and run `terraform init -upgrade`.
