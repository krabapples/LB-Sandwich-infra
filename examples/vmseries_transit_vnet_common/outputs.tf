output "natgw_public_ips" {
  description = "Nat Gateways Public IP resources."
  value = length(var.natgws) > 0 ? { for k, v in var.natgws : k => {
    pip        = try(coalesce(module.public_ip.pip_ip_addresses[v.public_ip.key], module.natgw[k].natgw_pip), null)
    pip_prefix = try(coalesce(module.public_ip.ippre_ip_prefixes[v.public_ip_prefix.key], module.natgw[k].natgw_pip_prefix), null)
  } } : null
}

output "lb_frontend_ips" {
  description = "IP Addresses of the load balancers."
  value       = length(var.load_balancers) > 0 ? { for k, v in module.load_balancer : k => v.frontend_ip_configs } : null
}
