output "endpoint_service_name" { value = aws_vpc_endpoint_service.c2_service.service_name }
output "nlb_name" { value = data.aws_lb.c2_nlb.name }
output "interface_endpoint_id" { value = aws_vpc_endpoint.c1_interface.id }

# First DNS name (for convenience)
output "interface_endpoint_dns" {
  value = element([for e in aws_vpc_endpoint.c1_interface.dns_entry : e.dns_name], 0)
}

# Full list of DNS names
output "interface_endpoint_dns_list" {
  value = [for e in aws_vpc_endpoint.c1_interface.dns_entry : e.dns_name]
}

output "c1_endpoint_security_group_id" { value = aws_security_group.c1_interface_ep.id }
