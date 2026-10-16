#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="skadi"
ACTION="${1:-}"

if [[ "$ACTION" != "ligar" && "$ACTION" != "desligar" ]]; then
  echo "Uso: bash scripts/infra.sh up|down" >&2
  exit 1
fi

for cmd in aws terraform kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Comando '$cmd' nao encontrado." >&2
    exit 1
  fi
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="skadi-tfstate-${ACCOUNT}"

ensure_state_bucket() {
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    return 0
  fi
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

terraform_init() {
  terraform -chdir="$ROOT/terraform" init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="key=skadi/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true"
}

map_node_role() {
  # O Learner Lab so tem a LabRole. O EKS nao cria access entry para a role do
  # cluster, entao o no entra pelo ConfigMap aws-auth.
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::${ACCOUNT}:role/LabRole
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF
}

install_argocd() {
  map_node_role
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
  kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
  kubectl apply -f "$ROOT/infra/argocd-application.yaml"
}

ligar() {
  ensure_state_bucket
  terraform_init
  terraform -chdir="$ROOT/terraform" apply -input=false -auto-approve
  install_argocd
  echo "Infra pronta. O Argo CD observa k8s/ na branch main."
}

release_vpc() {
  local vpc_id lbs clbs instances enis eni igw subnet sg rt main_rt nat ep
  vpc_id="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
    --query "Vpcs[0].VpcId" --output text)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    return 0
  fi

  aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$CLUSTER_NAME" --region "$REGION" || true
  aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION" || true
  aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$REGION" || true

  lbs="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text || true)"
  for lb in $lbs; do
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$lb" || true
  done

  clbs="$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" --output text || true)"
  for name in $clbs; do
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name" || true
  done

  instances="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text || true)"
  if [[ -n "$instances" && "$instances" != "None" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $instances || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $instances || true
  fi

  for nat in $(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=pending,available" \
    --query "NatGateways[].NatGatewayId" --output text); do
    aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$nat" || true
  done

  for ep in $(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "VpcEndpoints[].VpcEndpointId" --output text); do
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$ep" || true
  done

  for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text); do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
  done

  for igw in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query "InternetGateways[].InternetGatewayId" --output text); do
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$vpc_id" || true
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw" || true
  done

  for subnet in $(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "Subnets[].SubnetId" --output text); do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet" || true
  done

  main_rt="$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)"
  for rt in $(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "RouteTables[].RouteTableId" --output text); do
    if [[ "$rt" != "$main_rt" ]]; then
      aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt" || true
    fi
  done

  for _ in 1 2; do
    for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
      aws ec2 delete-security-group --region "$REGION" --group-id "$sg" || true
    done
  done
}

desligar() {
  ensure_state_bucket
  terraform_init
  release_vpc
  terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve
  aws s3 rm "s3://${BUCKET}" --recursive
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
}

"$ACTION"
