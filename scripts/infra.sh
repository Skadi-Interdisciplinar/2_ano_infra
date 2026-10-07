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

install_argocd() {
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
  kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
  kubectl apply -f "$ROOT/infra/argocd-application.yaml"
}

up() {
  ensure_state_bucket
  terraform_init
  terraform -chdir="$ROOT/terraform" apply -input=false -auto-approve
  install_argocd
  echo "Infra pronta. O Argo CD observa k8s/ na branch main."
}

down() {
  ensure_state_bucket
  terraform_init
  terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve
  aws s3 rm "s3://${BUCKET}" --recursive
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
}

"$ACTION"
