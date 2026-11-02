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

vpc_id() {
  aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || true
}

# O Service LoadBalancer cria um ELB fora do Terraform. A ENI dele segura a subnet.
delete_load_balancers() {
  local vpc_id="$1" lb name attempt left cleft
  local lbs clbs
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
  for attempt in $(seq 1 30); do
    left="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?VpcId=='${vpc_id}'])" --output text || echo 1)"
    cleft="$(aws elb describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancerDescriptions[?VPCId=='${vpc_id}'])" --output text || echo 1)"
    if [[ "$left" == "0" && "$cleft" == "0" ]]; then
      return 0
    fi
    echo "Aguardando o balanceador sair da VPC (${attempt})."
    sleep 10
  done
  echo "O balanceador da VPC ${vpc_id} nao terminou de sair." >&2
  return 1
}

# Depois que o cluster some, ENIs soltas ainda impedem o DeleteSubnet.
drain_vpc() {
  local vpc_id="$1" attempt instances eni attachment
  instances="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text || true)"
  if [[ -n "$instances" && "$instances" != "None" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $instances || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $instances || true
  fi
  for attempt in $(seq 1 24); do
    local enis
    enis="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query "NetworkInterfaces[].NetworkInterfaceId" --output text || true)"
    if [[ -z "$enis" || "$enis" == "None" ]]; then
      return 0
    fi
    echo "Aguardando ENIs da VPC sairem (${attempt}): ${enis}"
    for eni in $enis; do
      attachment="$(aws ec2 describe-network-interfaces --region "$REGION" \
        --network-interface-ids "$eni" \
        --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || true)"
      if [[ -n "$attachment" && "$attachment" != "None" ]]; then
        aws ec2 detach-network-interface --region "$REGION" --attachment-id "$attachment" --force || true
      fi
      aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
    done
    sleep 15
  done
  echo "A subnet continua com ENI. O destroy nao consegue apaga-la." >&2
  aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Subnet:SubnetId,Desc:Description}" \
    --output table >&2 || true
  return 1
}

desligar() {
  local vpc
  ensure_state_bucket
  terraform_init
  vpc="$(vpc_id)"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    delete_load_balancers "$vpc"
  fi
  terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve -target=aws_eks_cluster.this
  vpc="$(vpc_id)"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    drain_vpc "$vpc"
  fi
  terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve
  aws s3 rm "s3://${BUCKET}" --recursive
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
}

"$ACTION"
