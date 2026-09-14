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

**No hay backend remoto.** El `tofu apply` corre dentro de un job de GitHub
Actions (workflows `01-provision-*`), y el archivo de state vive solo
mientras ese job está corriendo — no se guarda como artifact, ni en S3, ni
en ningún otro lado. Es una decisión deliberada para mantener el workshop
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

## Orden de uso durante el workshop

1. **`01 - Provision: EC2`** o **`01 - Provision: Fargate`** (action: `plan`
   primero para revisar, después `apply`) — elegí uno.
2. **`02 - Deploy App`** (target: `ec2` o `fargate`, según lo que hayas
   provisionado) — build de la imagen desde [`docker/app`](../docker/app),
   push a ECR, y deploy (SSM en EC2, `force-new-deployment` en Fargate).
3. Al terminar la charla: **`03 - Destroy`** con el `target` correspondiente
   y escribiendo `destroy` en la confirmación, para no dejar nada corriendo
   en la cuenta.

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
