# Infra — AWS 101

Dos stacks de OpenTofu **alternativos** para desplegar `cat-app` (ver
[docker/app](../docker/app)): elegí uno u otro, no los corras a la vez.

| Stack | Cómputo | Cuándo usarlo |
|---|---|---|
| [`base-ec2/`](base-ec2) | Una instancia EC2 con Docker | Para explicar EC2 "clásico" + SSM |
| [`base-fargate/`](base-fargate) | ECS Fargate (serverless) | Para explicar containers gestionados |

Ambos crean un repo de **ECR llamado `cat-app`** (mismo nombre en los dos):
si aplicás uno con el otro ya desplegado, `tofu apply` va a fallar porque el
repo ya existe. Destruí un stack completo (workflow **03-destroy**, incluye
el ECR) antes de provisionar el otro.

## Decisión de diseño: state local/efímero

**No hay backend remoto.** Para el workshop en sí, el `tofu apply` corre
dentro de un job de GitHub Actions (workflows `01-provision-*`), y ahí el
archivo de state vive solo mientras ese job está corriendo — no se guarda
como artifact, ni en S3, ni en ningún otro lado. (Si en cambio corrés
`tofu apply` en local — ver "Opción B" en la sección [Cómo usar](#cómo-usar)
más abajo — el state queda en tu disco entre corridas, como cualquier uso
normal de Terraform/OpenTofu.) Es una decisión deliberada para mantener el workshop
simple (sin bucket + DynamoDB de locking que configurar antes de la charla).

Esto tiene dos consecuencias directas en el código, y son intencionales —
**no son bugs**:

1. **Los nombres de los recursos están hardcodeados** en los `.tf`
   (`cat-webserver`, `cat-cluster`, `cat-service`, `cat-app`) en vez de
   generarse dinámicamente y pasarse vía `output` de tofu. No hay state
   persistente del que leer esos outputs entre workflows distintos.
2. **El workflow de deploy (`02-deploy-app`) busca los recursos por
   tag/nombre con AWS CLI** (`aws ec2 describe-instances --filters
   Name=tag:Name,Values=cat-webserver`, `aws ecs describe-services
   --cluster cat-cluster --services cat-service`), no con
   `terraform_remote_state` ni `tofu output`.

**Consecuencia para `03-destroy`:** como el state nunca persiste entre runs
de GitHub Actions, un `tofu destroy` en CI no tendría ningún state del que
partir — destruiría "nada" y dejaría los recursos reales huérfanos en la
cuenta. Por eso `03-destroy.yml` **no usa `tofu destroy`**: es una plantilla
que borra los mismos recursos directamente por AWS CLI, buscándolos por el
mismo nombre/tag hardcodeado que usan los stacks. Verificá siempre en la
consola de AWS después de correrlo.

Si en algún momento se suma un backend remoto (S3 + DynamoDB, o Terraform
Cloud), estas tres cosas dejan de aplicar y se podría volver a un flujo con
outputs + `tofu destroy` normal — pero es un cambio de diseño a propósito,
no algo para hacer sin avisar.

## Auth de GitHub Actions a AWS

Access keys estáticas en GitHub Secrets (`AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY`), **no OIDC**. Es una decisión consciente para
simplicidad de setup del workshop, no un descuido — no lo cambies sin que
te lo pidan.

### Secrets y variables necesarios en el repo de GitHub

| Nombre | Tipo | Descripción |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret | Access key del usuario/IAM que usa el workshop |
| `AWS_SECRET_ACCESS_KEY` | Secret | Secret key correspondiente |
| `AWS_REGION` | Variable (opcional) | Región a usar; default `us-east-1` si no se define |

## Cómo usar

El flujo siempre es el mismo — **provisionar → desplegar → (al final)
destruir** — elegí un stack (EC2 o Fargate) y no lo mezcles con el otro.
Dos formas de correrlo: vía GitHub Actions (la forma pensada para el
workshop) o en local (para armar/probar todo antes de la charla).

### Opción A — GitHub Actions (recomendado para el día del workshop)

Requiere tener cargados los Secrets/Variables de la [tabla de
arriba](#secrets-y-variables-necesarios-en-el-repo-de-github) en el repo.

1. Pestaña **Actions** del repo → elegí **`01 - Provision: EC2`** o
   **`01 - Provision: Fargate`** → **Run workflow** → `action: plan` primero
   para revisar qué va a crear, corré de nuevo con `action: apply` cuando
   estés conforme.
2. **`02 - Deploy App`** → **Run workflow** → `target: ec2` o `target:
   fargate` (el mismo que provisionaste). Buildea `docker/app`, lo publica
   en ECR y lo despliega.
3. Repetí el paso 2 cada vez que cambies algo en `docker/app` — no hace
   falta volver a provisionar.
4. Al terminar la charla: **`03 - Destroy`** → **Run workflow** → mismo
   `target`, y escribí `destroy` en el campo `confirm` para que corra.

### Opción B — Local (para armar/iterar antes del workshop)

Necesitás `tofu`, `docker` y `aws` CLI con credenciales configuradas
(`aws configure` o variables `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
/ `AWS_DEFAULT_REGION` en tu shell) — acá el state SÍ queda en tu disco
(`infra/*/terraform.tfstate`, gitignored), así que un `tofu destroy` local
funciona normal, a diferencia del workflow `03-destroy`.

```bash
# 1) Provisionar (elegí un stack)
cd infra/base-ec2   # o infra/base-fargate
tofu init
tofu plan
tofu apply

# 2) Build + push de la imagen (mismo repo ECR que acaba de crear el apply)
REPO_URI=$(aws ecr describe-repositories --repository-names cat-app --query 'repositories[0].repositoryUri' --output text)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
docker build --platform linux/amd64 -t "${REPO_URI}:latest" ../../docker/app   # ver nota de arquitectura abajo
docker push "${REPO_URI}:latest"

# 3a) Deploy a EC2: instancia por tag Name=cat-webserver, vía SSM
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=cat-webserver" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters commands="[\"docker pull ${REPO_URI}:latest\",\"docker stop cat-app || true\",\"docker rm cat-app || true\",\"docker run -d --name cat-app --restart unless-stopped -p 80:80 ${REPO_URI}:latest\"]"

# 3b) — o — Deploy a Fargate
aws ecs update-service --cluster cat-cluster --service cat-service --force-new-deployment
aws ecs wait services-stable --cluster cat-cluster --services cat-service

# 4) Al terminar: destruir el stack que hayas provisionado
cd infra/base-ec2   # o infra/base-fargate
tofu destroy
```

**Nota de arquitectura:** los runners de GitHub Actions (`ubuntu-latest`)
son amd64, igual que EC2/Fargate — la Opción A no necesita nada especial.
Pero si buildeás en local desde una Mac Apple Silicon (M1/M2/M3, arm64), el
container va a crashear en EC2/Fargate con `exec format error` si no forzás
la arquitectura con `--platform linux/amd64` como en el comando de arriba.

## Red

Ambos stacks usan la **VPC y subnets default** de la cuenta — no crean red
propia, para minimizar lo que hay que explicar/depurar en vivo.

## EC2 (`base-ec2/`)

- `t3.micro`, Amazon Linux 2023 (resuelta vía SSM Parameter Store).
- Sin acceso SSH: el security group solo abre `80/tcp` entrante. El deploy
  y cualquier comando remoto se hacen vía **SSM Run Command**, para lo cual
  la instancia tiene el rol `AmazonSSMManagedInstanceCore`.
- El `user_data` solo instala y arranca Docker — **no** corre el container.
  En el primer `apply` el repo de ECR todavía está vacío, así que el pull y
  el `docker run` los hace `02-deploy-app` la primera vez que se despliega.

## Fargate (`base-fargate/`)

- Cluster `cat-cluster`, servicio `cat-service`, 1 task deseada.
- Sin ALB: la task tiene IP pública asignada directamente
  (`assign_public_ip = true`), para no sumar el costo/complejidad de un load
  balancer en una demo corta. Buscá la IP en la consola de ECS después del
  deploy.
- La task definition apunta a `cat-app:latest` en ECR desde el primer
  `apply`, cuando el repo todavía está vacío — es normal que las tasks
  fallen el pull hasta que `02-deploy-app` publique la primera imagen.
