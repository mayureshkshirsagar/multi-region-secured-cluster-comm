output "endpoint_service_name" { value = aws_vpc_endpoint_service.c2_service.service_name }
output "nlb_name" { value = data.aws_lb.c2_nlb.name }
output "interface_endpoint_id" { value = aws_vpc_endpoint.c1_interface.id }
output "interface_endpoint_dns" { value = one(aws_vpc_endpoint.c1_interface.dns_entry[*].dns_name) }
