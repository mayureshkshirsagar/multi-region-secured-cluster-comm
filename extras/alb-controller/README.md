### AWS Load Balancer Controller (for C2)

Service type=LoadBalancer on EKS now uses the AWS Load Balancer Controller. Install it in cluster C2 to provision an internal NLB for `k8s/c2-echo.yaml`.

High-level steps (run from a workstation with private access to EKS API):
- Ensure IRSA is enabled (it is in our Terraform module)
- Create IAM policy for the controller (from AWS docs)
- Create an IAM role for service account (SA `aws-load-balancer-controller` in `kube-system`)
- Helm install the controller with the cluster name and region values

Reference: AWS docs "Install AWS Load Balancer Controller on EKS".

Example Helm (adjust as needed):

```bash
CLUSTER=$(terraform -chdir=../.. output -raw c2_cluster_name)
REGION=$(terraform -chdir=../.. output -raw region_b)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Create the IAM policy (once per account)
POLICY_ARN=$(aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --query 'Policy.Arn' --output text || aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn | [0]" --output text)

# Create OIDC provider if not present (EKS module usually creates it)
# aws eks --region $REGION describe-cluster --name $CLUSTER --query "cluster.identity.oidc.issuer" --output text

# Create IAM role for SA (use eksctl or terraform in production). Here is eksctl one-liner example:
# eksctl create iamserviceaccount \
#   --name aws-load-balancer-controller \
#   --namespace kube-system \
#   --cluster $CLUSTER \
#   --attach-policy-arn $POLICY_ARN \
#   --approve \
#   --region $REGION

# Install chart
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set region=$REGION \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --kube-context C2
```

After installation, apply `k8s/c2-echo.yaml` and wait for the Service to obtain an NLB. Confirm it's `internal` and note its name.