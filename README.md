## Multi-Region Secured Cluster Communication (AWS EKS + PrivateLink)

This repo provisions two private EKS clusters in different AWS regions and enables least-privilege, private, cross-region service-to-service communication from Cluster C1 to a single service in Cluster C2 using AWS PrivateLink (Interface Endpoint in C1 to a VPC Endpoint Service in C2 backed by an internal NLB created by a Kubernetes Service in C2).

### Architecture
- Two VPCs and private EKS clusters: `C1` in `var.region_a`, `C2` in `var.region_b`.
- In `C2`, a simple echo app is exposed via a Kubernetes `Service` annotated to create an internal NLB (via AWS Load Balancer Controller).
- A VPC Endpoint Service (PrivateLink provider) is created in `C2` that points to the internal NLB.
- An Interface VPC Endpoint is created in `C1` that connects to that service (cross-region supported).
- Security is restricted via PrivateLink allowed principals and the Interface Endpoint security group (inbound only from C1 node SG).
- Optional: a small SSM-managed EC2 bastion in each VPC to reach private EKS APIs from inside the VPC (no public IPs).

### Prerequisites
- Terraform >= 1.5
- AWS credentials configured with sufficient privileges
- kubectl and two contexts (you will generate kubeconfigs after clusters are up)
- Helm (if you install AWS Load Balancer Controller via Helm)
- Python 3 + boto3 (for verification tool)

### Variables (defaults in `variables.tf`)
- `region_a` (default `us-east-1`) → C1
- `region_b` (default `us-west-2`) → C2
- `create_bastion_instances` (default `false`) → Set to `true` to create one EC2 per VPC (SSM-enabled, no public IP)
- `bastion_instance_type` (default `t3.micro`)

### Apply order (recommended staging)
1) Provision network + clusters

```bash
terraform init
terraform apply -var create_bastion_instances=true \
  -target=module.vpc_c1 -target=module.vpc_c2 -target=module.eks_c1 -target=module.eks_c2
```

2) Generate kubeconfigs locally (private endpoint only). From your machine (must be able to reach cluster private endpoints via VPN/DirectConnect/bastion/VPC endpoint):

```bash
aws eks --region $(terraform output -raw region_a) update-kubeconfig --name $(terraform output -raw c1_cluster_name) --alias C1
aws eks --region $(terraform output -raw region_b) update-kubeconfig --name $(terraform output -raw c2_cluster_name) --alias C2
```

3) Install AWS Load Balancer Controller in C2 (required for Service type=LoadBalancer with NLB). You can use Helm. IAM role for service account (IRSA) is enabled by the EKS module output; see `extras/alb-controller/` for manifests and notes. Apply per your environment.

4) Deploy the echo app and Service in C2 to create the internal NLB:

```bash
kubectl --context C2 apply -f k8s/c2-echo.yaml
```

Wait until the `Service` is provisioned and an internal NLB appears in AWS (tag `kubernetes.io/service-name=default/echo-lb`).

5) Provision PrivateLink (provider in C2 + interface endpoint in C1):

```bash
cd privatelink
terraform init
terraform apply \
  -var region_a=$(terraform -chdir=.. output -raw region_a) \
  -var region_b=$(terraform -chdir=.. output -raw region_b)
```

The module discovers the NLB by tag from step 4, then creates:
- VPC Endpoint Service in C2 pointing to the NLB
- Interface VPC Endpoint in C1 targeting that service

6) Test from C1
- Create a test pod:

```bash
kubectl --context C1 apply -f k8s/c1-testpod.yaml
```

- Get the Interface Endpoint DNS from Terraform output and curl from the test pod:

```bash
IEP_HOST=$(terraform -chdir=privatelink output -raw interface_endpoint_dns)
kubectl --context C1 exec -it pod/tester -- sh -c "curl -s -m 5 http://$IEP_HOST"
```

You should receive: `hello from c2`.

### Verification tool
Use the Python tool to assert:
- NLB is internal
- Endpoint service exists (C2)
- Interface endpoint exists (C1)
- Curl from a C1 test pod to the interface endpoint succeeds

```bash
python3 scripts/verify_privatelink_connectivity.py \
  --region-c1 $(terraform output -raw region_a) \
  --region-c2 $(terraform output -raw region_b) \
  --nlb-name $(terraform -chdir=privatelink output -raw nlb_name) \
  --service-name $(terraform -chdir=privatelink output -raw endpoint_service_name) \
  --kubectl-context-c1 C1 \
  --target-host $(terraform -chdir=privatelink output -raw interface_endpoint_dns)
```

### Revocation demo
- Disable by removing allowed principals or deleting the Interface Endpoint in `C1` (or set the endpoint policy to deny). Then re-run the verification tool to see failure.

### Notes
- Both clusters use private endpoints only; ensure your execution environment has private network access to EKS endpoints. If enabled, use SSM Session Manager to reach the bastion instances (`aws ssm start-session --target <instance-id>`).
- Costs: PrivateLink and EC2 incur charges; this is a demo footprint.
