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
  local vpc_id lbs clbs instances enis eni
  vpc_id="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
    --query "Vpcs[0].VpcId" --output text)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    return 0
  fi

  lbs="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text)"
  for lb in $lbs; do
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$lb"
  done

  clbs="$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" --output text)"
  for name in $clbs; do
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name"
  done

  instances="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)"
  if [[ -n "$instances" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $instances
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $instances
  fi

  for _ in 1 2 3 4 5 6; do
    enis="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=available" \
      --query "NetworkInterfaces[].NetworkInterfaceId" --output text)"
    if [[ -z "$enis" ]]; then
      break
    fi
    for eni in $enis; do
      aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
    done
    sleep 10
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
