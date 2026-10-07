#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT/artifacts"
CONTEXT_DIR="$ROOT/build-context"
CLUSTER_NAME="${CLUSTER_NAME_OVERRIDE:-skadi}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

BACKEND_REPO="Skadi-Interdisciplinar/2_ano_backend"
FRONTEND_REPO="Skadi-Interdisciplinar/2_ano_frontend"
IA_REPO="Skadi-Interdisciplinar/2_ano_back_ia"
BACKEND_WORKFLOW="build.yml"
FRONTEND_WORKFLOW="build.yaml"
IA_WORKFLOW="build.yml"
BACKEND_ARTIFACT="skadi-api"
FRONTEND_ARTIFACT="skadi_frontend"
IA_ARTIFACT="python-dist"

required_cmds=(aws docker kubectl)
if [[ "${ARTIFACTS_PREFETCHED:-}" != "true" ]]; then
  required_cmds+=(gh)
fi
for cmd in "${required_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Comando '$cmd' nao encontrado. Instale antes de continuar." >&2
    exit 1
  fi
done

if [[ -n "${GH_PAT:-}" ]]; then
  export GH_TOKEN="$GH_PAT"
fi

require_real() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "None" || "$value" == *"MOCK_"* ]]; then
    echo "Valor ausente para $name. Preencha o secret do GitHub com o dado real da Aiven ou do Learner Lab." >&2
    exit 1
  fi
}

latest_run() {
  local repo="$1"
  local workflow="$2"
  local run_id
  run_id="$(gh run list --repo "$repo" --workflow "$workflow" --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
  if [[ -z "$run_id" || "$run_id" == "null" ]]; then
    echo "Nenhum build bem-sucedido em $repo. Rode o workflow na branch main desse repositorio." >&2
    exit 1
  fi
  echo "$run_id"
}

copy_frontend_dist() {
  local source="$1"
  local destination="$2"
  mkdir -p "$destination"
  if [[ -f "$source/index.html" ]]; then
    cp -a "$source"/. "$destination"/
  elif [[ -f "$source/dist/index.html" ]]; then
    cp -a "$source/dist"/. "$destination"/
  else
    echo "O artefato do frontend nao contem index.html." >&2
    exit 1
  fi
}

TAG="$(date +%Y%m%d%H%M%S)"
BACKEND_IMAGE="skadi-backend:${TAG}"
FRONTEND_IMAGE="skadi-frontend:${TAG}"
IA_IMAGE="skadi-ia:${TAG}"

DB_URL_VALUE="${DB_URL:-}"
DB_USERNAME_VALUE="${DB_USERNAME:-}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-}"
SECURITY_KEY_VALUE="${SECURITY_KEY:-}"
EXPIRATION_VALUE="${EXPIRATION_TIME:-3600}"

require_real DB_URL "$DB_URL_VALUE"
require_real DB_USERNAME "$DB_USERNAME_VALUE"
require_real DB_PASSWORD "$DB_PASSWORD_VALUE"
require_real SECURITY_KEY "$SECURITY_KEY_VALUE"

rm -rf "$CONTEXT_DIR"
mkdir -p "$CONTEXT_DIR/backend" "$CONTEXT_DIR/frontend/dist" "$CONTEXT_DIR/ia/dist"

if [[ "${ARTIFACTS_PREFETCHED:-}" == "true" ]]; then
  if [[ ! -d "$ARTIFACTS_DIR/backend" || ! -d "$ARTIFACTS_DIR/frontend" || ! -d "$ARTIFACTS_DIR/ia" ]]; then
    echo "ARTIFACTS_PREFETCHED esta ligado, mas artifacts/backend, artifacts/frontend ou artifacts/ia nao existe." >&2
    exit 1
  fi
else
  rm -rf "$ARTIFACTS_DIR"
  mkdir -p "$ARTIFACTS_DIR/backend" "$ARTIFACTS_DIR/frontend" "$ARTIFACTS_DIR/ia"
  gh run download "$(latest_run "$BACKEND_REPO" "$BACKEND_WORKFLOW")" --repo "$BACKEND_REPO" --name "$BACKEND_ARTIFACT" --dir "$ARTIFACTS_DIR/backend"
  gh run download "$(latest_run "$FRONTEND_REPO" "$FRONTEND_WORKFLOW")" --repo "$FRONTEND_REPO" --name "$FRONTEND_ARTIFACT" --dir "$ARTIFACTS_DIR/frontend"
  gh run download "$(latest_run "$IA_REPO" "$IA_WORKFLOW")" --repo "$IA_REPO" --name "$IA_ARTIFACT" --dir "$ARTIFACTS_DIR/ia"
fi

JAR="$(find "$ARTIFACTS_DIR/backend" -type f -name '*.jar' ! -name '*original*' ! -name '*plain*' ! -name '*sources*' ! -name '*javadoc*' -printf '%s %p\n' | sort -nr | awk 'NR==1 { $1=""; sub(/^ /, ""); print }')"
if [[ -z "$JAR" ]]; then
  echo "Nenhum .jar encontrado no artefato $BACKEND_ARTIFACT." >&2
  exit 1
fi
cp "$JAR" "$CONTEXT_DIR/backend/app.jar"
cp "$ROOT/docker/frontend/nginx.conf" "$CONTEXT_DIR/frontend/nginx.conf"
copy_frontend_dist "$ARTIFACTS_DIR/frontend" "$CONTEXT_DIR/frontend/dist"

WHEEL="$(find "$ARTIFACTS_DIR/ia" -type f -name '*.whl' -printf '%s %p\n' | sort -nr | awk 'NR==1 { $1=""; sub(/^ /, ""); print }')"
if [[ -z "$WHEEL" ]]; then
  echo "Nenhum .whl encontrado no artefato $IA_ARTIFACT." >&2
  exit 1
fi
cp "$WHEEL" "$CONTEXT_DIR/ia/dist/"
cp "$ROOT/docker/ia/start.py" "$CONTEXT_DIR/ia/start.py"

docker build -f "$ROOT/docker/backend/Dockerfile" -t "$BACKEND_IMAGE" "$CONTEXT_DIR/backend"
docker build -f "$ROOT/docker/frontend/Dockerfile" -t "$FRONTEND_IMAGE" "$CONTEXT_DIR/frontend"
docker build -f "$ROOT/docker/ia/Dockerfile" -t "$IA_IMAGE" "$CONTEXT_DIR/ia"
docker save "$BACKEND_IMAGE" -o "$CONTEXT_DIR/backend.tar"
docker save "$FRONTEND_IMAGE" -o "$CONTEXT_DIR/frontend.tar"
docker save "$IA_IMAGE" -o "$CONTEXT_DIR/ia.tar"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

kubectl create namespace skadi --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic skadi-backend --namespace skadi \
  --from-literal="DB_URL=${DB_URL_VALUE}" \
  --from-literal="DB_USERNAME=${DB_USERNAME_VALUE}" \
  --from-literal="DB_PASSWORD=${DB_PASSWORD_VALUE}" \
  --from-literal="SECURITY_KEY=${SECURITY_KEY_VALUE}" \
  --from-literal="EXPIRATION_TIME=${EXPIRATION_VALUE}" \
  --dry-run=client -o yaml | kubectl apply -f -

import_image() {
  local name="$1"
  local tar="$2"
  kubectl -n skadi delete pod "import-${name}" --ignore-not-found --wait=true
  kubectl -n skadi apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: import-${name}
  namespace: skadi
spec:
  restartPolicy: Never
  hostPID: true
  containers:
    - name: import
      image: busybox:1.36
      command: ["sleep", "600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: images
          mountPath: /images
  volumes:
    - name: images
      hostPath:
        path: /var/lib/skadi-images
        type: DirectoryOrCreate
EOF
  kubectl -n skadi wait --for=condition=Ready "pod/import-${name}" --timeout=180s
  kubectl -n skadi cp "$tar" "import-${name}:/images/${name}.tar"
  kubectl -n skadi exec "import-${name}" -- nsenter -t 1 -m -u -i -n -p -- ctr -n k8s.io images import "/var/lib/skadi-images/${name}.tar"
  kubectl -n skadi exec "import-${name}" -- nsenter -t 1 -m -u -i -n -p -- rm -f "/var/lib/skadi-images/${name}.tar"
  kubectl -n skadi delete pod "import-${name}" --wait=false
}

import_image backend "$CONTEXT_DIR/backend.tar"
import_image frontend "$CONTEXT_DIR/frontend.tar"
import_image ia "$CONTEXT_DIR/ia.tar"

cat > "$ROOT/k8s/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: skadi
resources:
  - namespace.yaml
  - backend-deployment.yaml
  - backend-service.yaml
  - frontend-deployment.yaml
  - frontend-service.yaml
  - ia-deployment.yaml
  - ia-service.yaml
  - redis-deployment.yaml
  - redis-service.yaml
images:
  - name: skadi-backend
    newName: skadi-backend
    newTag: "${TAG}"
  - name: skadi-frontend
    newName: skadi-frontend
    newTag: "${TAG}"
  - name: skadi-ia
    newName: skadi-ia
    newTag: "${TAG}"
EOF

echo "Imagens importadas no no do cluster: $BACKEND_IMAGE, $FRONTEND_IMAGE e $IA_IMAGE"
echo "O Argo CD aplica k8s/ quando este kustomization.yaml chegar na main."
