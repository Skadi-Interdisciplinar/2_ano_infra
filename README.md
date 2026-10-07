# Infra do Skadi

Este repositório empacota os artefatos já gerados pelo backend, pelo frontend e pela IA, monta um container de cada um e sobe os três no EKS. As imagens não vão para um repositório: o deploy importa os arquivos direto no nó do cluster.

- Backend: artefato `skadi-api` do repositório `Skadi-Interdisciplinar/2_ano_backend` (JAR Java 21, porta 8080).
- Frontend: artefato `skadi_frontend` do repositório `Skadi-Interdisciplinar/2_ano_frontend` (build estática do Vite). O nginx serve o site, encaminha `/api/` para o Service `skadi-backend` e `/ia/` para o Service `skadi-ia`.
- IA: artefato `python-dist` do repositório `Skadi-Interdisciplinar/2_ano_back_ia` (wheel Python 3.11). O container instala o wheel e sobe o uvicorn na porta 8000.

O cluster fica na AWS Academy, região `us-east-1`. O Terraform cria a VPC e o EKS. Não há NAT Gateway: o nó `t3.medium` fica em sub-rede pública. O Postgres fica na Aiven, fora da AWS. O control plane do EKS cobra enquanto o cluster existir. Ao terminar a sessão, dispare o workflow **Infra** em `down`.

## Credenciais

Nenhuma senha ou chave fica no repositório. O arquivo [credentials.example.env](credentials.example.env) só tem valores `MOCK_`. O host, a porta, o usuário e a senha do Postgres você copia da página de conexão do serviço na Aiven.

O `AWS_SESSION_TOKEN` da Academy expira em algumas horas. Se o workflow responder `ExpiredToken`, gere as credenciais de novo no lab, atualize os três secrets da AWS e dispare outra vez.

O download dos artefatos acontece no GitHub Actions. O secret `GH_PAT` precisa de `actions:read` em `2_ano_backend`, `2_ano_frontend` e `2_ano_back_ia`.

O `.env` de cada aplicação existe só para rodar no seu PC. O cluster não lê esse arquivo. Os workflows de build do backend, do frontend e da IA também não usam secrets de senha. Tudo o que o pod precisa está nos repository secrets deste repositório `2_ano_infra`.

A URL do Redis não é secret. O Deployment da API aponta para `redis://skadi-redis:6379/0`. O nome do stream e a retenção continuam com o padrão do `application.properties` do backend (`skadi:leituras:temperatura` e `72`).

## O que sobe no cluster

No namespace `skadi`:

| Recurso | Função |
| --- | --- |
| Deployment `skadi-backend` | Pod da API. `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `SECURITY_KEY` e `EXPIRATION_TIME` vêm do Secret `skadi-backend`. `REDIS_URL` aponta para o Redis do cluster. |
| Service `skadi-backend` | ClusterIP na porta 8080. Só o frontend, dentro do cluster, fala com a API. |
| Deployment `skadi-redis` | Redis 7, imagem pública `redis:7-alpine`. |
| Service `skadi-redis` | ClusterIP na porta 6379. Só a API fala com ele. |
| Deployment `skadi-frontend` | Pod do nginx com a build do React. |
| Service `skadi-frontend` | LoadBalancer na porta 80. Este é o endereço público. |
| Deployment `skadi-ia` | Pod do agente Python. O uvicorn procura `app` em `agente_ia.main`, `agente_ia.app` ou `agente_ia.api`. |
| Service `skadi-ia` | ClusterIP na porta 8000. O nginx encaminha `/ia/` para este Service. |

O Secret real é criado pelo deploy com os secrets do GitHub, preenchidos a partir da Aiven. [k8s/backend-secret.example.yaml](k8s/backend-secret.example.yaml) mostra o formato, com valores mockados, e não entra no Kustomize.

Quem aplica Deployment e Service é o Argo CD. A Application em [infra/argocd-application.yaml](infra/argocd-application.yaml) observa a pasta `k8s/` na `main` e sincroniza sozinha.

## Secrets do GitHub

Cadastre estes secrets só no repositório `2_ano_infra`. Não cadastre os mesmos valores nos repositórios do backend, do frontend ou da IA.

| Secret | Origem |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Learner Lab |
| `AWS_SECRET_ACCESS_KEY` | Learner Lab |
| `AWS_SESSION_TOKEN` | Learner Lab |
| `GH_PAT` | Token com `actions:read` em `2_ano_backend`, `2_ano_frontend` e `2_ano_back_ia` |
| `DB_URL` | JDBC da Aiven, com `sslmode=require` |
| `DB_USERNAME` | Usuário da Aiven, em geral `avnadmin` |
| `DB_PASSWORD` | Senha da Aiven |
| `SECURITY_KEY` | Chave que você inventa para assinar o JWT |
| `EXPIRATION_TIME` | `3600` |

## Criar a infra

No repositório, abra Actions, escolha **Infra** e rode `workflow_dispatch` com a ação `up`.

O job roda `terraform apply` na pasta [terraform/](terraform/) e depois instala o Argo CD. Leva em torno de 20 minutos. O state do Terraform fica num bucket S3 `skadi-tfstate-<conta>`, também criado por esse job. O banco não entra nesse apply: ele já existe na Aiven.

A interface do Argo CD fica no cluster. A senha inicial do usuário `admin`:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

O valor do secret está em base64. Abra `https://localhost:8080`.

## Publicar os artefatos

Os workflows de build do backend, do frontend e da IA precisam ter rodado com sucesso na `main`, e a infra precisa estar no ar. Abra Actions, escolha **Deploy Skadi** e rode `workflow_dispatch`.

O workflow baixa os artefatos com `actions/download-artifact`:

- `skadi-api`, de `2_ano_backend`
- `skadi_frontend`, de `2_ano_frontend`
- `python-dist`, de `2_ano_back_ia`

Com os arquivos já no runner, `scripts/deploy.sh` monta as três imagens a partir dos Dockerfiles, grava cada uma num arquivo e importa no containerd do nó. Os dados da Aiven viram o Secret `skadi-backend` no cluster. A tag fica em `k8s/kustomization.yaml`, o workflow envia esse arquivo para a `main` e o Argo CD sobe os Pods com `imagePullPolicy: Never`, usando a imagem que já está no nó.

O endereço público aparece no final do job, ou depois, com `kubectl` apontando para o cluster:

```powershell
kubectl -n skadi get svc skadi-frontend --watch
```

Abra o hostname na porta 80. Chamadas do browser para `/api/...` seguem para a API. Chamadas para `/ia/...` seguem para o agente.

## Encerrar

Dispare o workflow **Infra** com a ação `down`. O `terraform destroy` apaga o cluster e a VPC, e o job remove o bucket do state. O serviço da Aiven continua existindo até você apagá-lo no console deles. Sem o destroy o crédito do lab continua caindo.
