## PrivateLink layer (C1 consumer -> C2 provider)

This Terraform config discovers the internal NLB created by `k8s/c2-echo.yaml` in region B (C2) and builds:
- VPC Endpoint Service in C2 (provider)
- Interface VPC Endpoint in C1 (consumer)

It assumes the root Terraform created VPCs and EKS clusters, and that the echo Service has already created an internal NLB with tag `kubernetes.io/service-name=default/echo-lb`.

Outputs:
- `endpoint_service_name`
- `nlb_name`
- `interface_endpoint_id`
- `interface_endpoint_dns`

Apply:
```bash
terraform init
terraform apply -var region_a=<REGION_A> -var region_b=<REGION_B>
```