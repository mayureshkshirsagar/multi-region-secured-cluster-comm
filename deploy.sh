#!/usr/bin/env bash
set -euo pipefail

# Run from repo root regardless of current directory
cd "$(dirname "$0")"

terraform init

# Optional plan (non-fatal if it fails due to missing providers yet)
terraform plan -out=tfplan || true

# Create core network + clusters first (fixing invalid target typo)
terraform apply \
  -target=module.vpc_c1 \
  -target=module.vpc_c2 \
  -target=module.eks_c1 \
  -target=module.eks_c2 \
  -auto-approve

# Apply remaining (no targets) to materialize outputs in state
terraform apply -auto-approve

echo "--- Terraform outputs ---"
terraform output || true

# Derive regions and cluster names from outputs (fallback to defaults if not present yet)
REGION_A="$(terraform output -raw region_a 2>/dev/null || echo us-east-1)"
REGION_B="$(terraform output -raw region_b 2>/dev/null || echo us-west-2)"
C1_NAME="$(terraform output -raw c1_cluster_name 2>/dev/null || echo c1-eks)"
C2_NAME="$(terraform output -raw c2_cluster_name 2>/dev/null || echo c2-eks)"

# Configure kubeconfigs (may require private network access to EKS API)./deploy.sh
aws eks --region "$REGION_A" update-kubeconfig --name "$C1_NAME" --alias C1 || true
aws eks --region "$REGION_B" update-kubeconfig --name "$C2_NAME" --alias C2 || true

# If SSH key output exists, save it; otherwise skip silently
if terraform output -raw bastion_ssh_private_key_pem >/dev/null 2>&1; then
  terraform output -raw bastion_ssh_private_key_pem > bastion.pem
  chmod 600 bastion.pem
  echo "Saved SSH key to bastion.pem"
else
  echo "No SSH key output present; skipping key save"
fi

echo "--- Next steps ---"
echo "1) Install AWS Load Balancer Controller in C2 (see extras/alb-controller/README.md)"
echo "2) Deploy echo app:    kubectl --context C2 apply -f k8s/c2-echo.yaml"
echo "3) After NLB is ready, provision PrivateLink:"
echo "   cd privatelink && terraform init && terraform apply -var region_a=$REGION_A -var region_b=$REGION_B -auto-approve"
echo "4) Test from C1: apply k8s/c1-testpod.yaml and curl the interface_endpoint_dns output"