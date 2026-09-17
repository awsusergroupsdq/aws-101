# Infra — AWS 101

Dos stacks de OpenTofu **alternativos** para desplegar `cat-app` (ver
[docker/app](../docker/app)): elegí uno u otro, no los corras a la vez.
**Un solo `tofu apply` hace todo** — provisiona la infra, buildea la imagen,
la publica en ECR y la despliega. No hay un paso de "deploy" separado.

| Stack | Cómputo | Cuándo usarlo |
|---|---|---|
| [`base-ec2/`](base-ec2) | Una instancia EC2 con Docker | Para explicar EC2 "clásico" + SSM |
| [`base-fargate/`](base-fargate) | ECS Fargate (serverless) | Para explicar containers gestionados |

Ambos crean un repo de **ECR llamado `cat-app`** (mismo nombre en los dos):
si aplicás uno con el otro ya desplegado, `tofu apply` va a fallar porque el
repo ya existe. Destruí un stack completo (workflow **03-destroy**, incluye
el ECR) antes de provisionar el otro.

## Decisión de diseño: todo pasa por `tofu apply`, un solo comando

Cada stack tiene, además de los recursos de infra, dos `null_resource` con
`local-exec` (ver el final de cada `main.tf`):

1. **`null_resource.build_and_push`** — hace `docker build --platform
   linux/amd64` + `docker push` a ECR. Se dispara de nuevo cada vez que
   cambia el contenido de `docker/app` (está hasheado en el `trigger`), así
   que correr `tofu apply` otra vez después de editar la app también la
   redespliega, sin tocar el resto de la infra.
2. **`null_resource.deploy`** — en EC2, espera a que el agente de SSM esté
   online y manda el `docker pull` + `run` remoto; en Fargate, hace
   `force-new-deployment` y espera a que el servicio estabilice.

**Por qué está armado así:** al principio el deploy vivía en un workflow de
GitHub Actions aparte (`02-deploy-app`), que había que acordarse de correr
después de provisionar. En la práctica eso generaba un estado a medio
armar — instancia/cluster levantados pero sin la app corriendo todavía
("connection refused" al abrir la IP) — cada vez que alguien corría
`01-provision-*` y se olvidaba el segundo paso. Meter el build+push+deploy
adentro del propio `apply` (vía `local-exec`) elimina ese paso intermedio:
**si `tofu apply` terminó bien, la app ya está andando.**

**Consecuencia:** `docker` y `aws` CLI dejan de ser "opcionales solo para
probar en local" — son **requeridos** en cualquier lugar donde corra
`tofu apply`, workflow de GitHub Actions incluido. Los runners
`ubuntu-latest` de GitHub Actions ya traen ambos preinstalados, así que la
Opción A de abajo no necesita nada extra.

## State local/efímero

**No hay backend remoto.** Para el workshop en sí, el `tofu apply` corre
dentro de un job de GitHub Actions (workflows `01-provision-*`), y ahí el
archivo de state vive solo mientras ese job está corriendo — no se guarda
como artifact, ni en S3, ni en ningún otro lado. (Si en cambio corrés
`tofu apply` en local — ver "Opción B" en la sección [Cómo usar](#cómo-usar)
más abajo — el state queda en tu disco entre corridas, como cualquier uso
normal de Terraform/OpenTofu.) Es una decisión deliberada para mantener el
workshop simple (sin bucket + DynamoDB de locking que configurar antes de
la charla).

Esto tiene dos consecuencias directas en el código, y son intencionales —
**no son bugs**:

1. **Los nombres de los recursos están hardcodeados** en los `.tf`
   (`cat-webserver`, `cat-cluster`, `cat-service`, `cat-app`) en vez de
   generarse dinámicamente y pasarse vía `output` de tofu. No hay state
   persistente del que leer esos outputs entre workflows distintos.
2. **El destroy busca los recursos por tag/nombre con AWS CLI** (ver
   abajo), no con `terraform_remote_state` ni `tofu output`.

**Consecuencia para `03-destroy`:** como el state nunca persiste entre runs
de GitHub Actions, un `tofu destroy` en CI no tendría ningún state del que
partir — destruiría "nada" y dejaría los recursos reales huérfanos en la
cuenta. Por eso `03-destroy.yml` **no usa `tofu destroy`**: es una plantilla
que borra los mismos recursos directamente por AWS CLI, buscándolos por el
mismo nombre/tag hardcodeado que usan los stacks. Verificá siempre en la
consola de AWS después de correrlo.

Si en algún momento se suma un backend remoto (S3 + DynamoDB, o Terraform
Cloud), esto deja de aplicar y se podría volver a un flujo con outputs +
`tofu destroy` normal — pero es un cambio de diseño a propósito, no algo
para hacer sin avisar.

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

Un stack (EC2 o Fargate), un solo `apply` para tener todo andando. Dos
formas de correrlo: vía GitHub Actions (la forma pensada para el workshop)
o en local (para armar/probar todo antes de la charla).

### Opción A — GitHub Actions (recomendado para el día del workshop)

Requiere tener cargados los Secrets/Variables de la [tabla de
arriba](#secrets-y-variables-necesarios-en-el-repo-de-github) en el repo.

1. Pestaña **Actions** del repo → elegí **`01 - Provision: EC2`** o
   **`01 - Provision: Fargate`** → **Run workflow** → `action: plan` primero
   para revisar qué va a crear, corré de nuevo con `action: apply` cuando
   estés conforme. Al terminar, la app ya está desplegada — el resumen del
   job trae el `tofu output` completo (IP, comandos de SSH/exec, etc.).
2. ¿Cambiaste algo en `docker/app`? Corré el mismo workflow de nuevo con
   `action: apply` — el `null_resource` detecta el cambio y redespliega
   solo la app, sin tocar el resto de la infra.
3. Al terminar la charla: **`03 - Destroy`** → **Run workflow** → mismo
   `target`, y escribí `destroy` en el campo `confirm` para que corra.

### Opción B — Local (para armar/iterar antes del workshop)

Necesitás `tofu`, `docker` (con el daemon corriendo) y `aws` CLI con
credenciales configuradas (`aws configure` o variables
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` en tu
shell) — acá el state SÍ queda en tu disco (`infra/*/terraform.tfstate`,
gitignored), así que un `tofu destroy` local funciona normal, a diferencia
del workflow `03-destroy`.

```bash
# 1) Provisionar + desplegar (elegí un stack) — un solo comando
cd infra/base-ec2   # o infra/base-fargate
tofu init
tofu apply
tofu output   # IP, comando de SSH/exec, todo lo que necesitás sale de acá

# 2) ¿Cambiaste docker/app? Repetí el apply — redespliega solo la app
tofu apply

# 3) Al terminar: destruir el stack que hayas provisionado
tofu destroy
```

**Nota de arquitectura:** los runners de GitHub Actions (`ubuntu-latest`)
son amd64, igual que EC2/Fargate — la Opción A no necesita nada especial.
Pero si corrés `tofu apply` en local desde una Mac Apple Silicon (M1/M2/M3,
arm64), fijate que el `docker build` de los `null_resource` ya fuerza
`--platform linux/amd64` — no hace falta que hagas nada vos, pero por eso
el build tarda un poco más (emula la arquitectura) que un build nativo.

## Red

Ambos stacks usan la **VPC y subnets default** de la cuenta — no crean red
propia, para minimizar lo que hay que explicar/depurar en vivo.

## EC2 (`base-ec2/`)

- `t3.micro`, Amazon Linux 2023 (resuelta vía SSM Parameter Store).
- El deploy y cualquier comando remoto automatizado se hacen vía **SSM Run
  Command**, para lo cual la instancia tiene el rol
  `AmazonSSMManagedInstanceCore` — eso no depende de ningún puerto abierto.
- El security group abre `80/tcp` a todo el mundo (la demo) y `22/tcp`
  **solo a la IP del presentador**, para poder entrar por SSH a debuggear en
  vivo además de SSM. El `apply` genera un key pair nuevo (`tls_private_key`
  + `aws_key_pair`) y detecta tu IP pública automáticamente — todo queda
  en los outputs (`ssh_command`, `my_ip_cidr`, `ssh_private_key_pem`). Ver
  variable `my_ip_cidr` si querés fijar la IP a mano en vez de auto-detectarla.
- El `user_data` instala y arranca Docker. El `null_resource.deploy` espera
  a que el agente de SSM esté online (puede tardar uno o dos minutos desde
  que la instancia arranca) antes de mandar el `docker pull` + `run` —
  por eso el `apply` completo tarda un par de minutos, no es que se colgó.

## Fargate (`base-fargate/`)

- Cluster `cat-cluster`, servicio `cat-service`, 1 task deseada.
- Sin ALB: la task tiene IP pública asignada directamente
  (`assign_public_ip = true`), para no sumar el costo/complejidad de un load
  balancer en una demo corta. El output `find_ip_command` te da el comando
  de AWS CLI listo para conseguir esa IP.
- La task definition apunta a `cat-app:latest` en ECR desde el momento en
  que se crea el servicio, antes de que `null_resource.build_and_push` haya
  publicado la imagen — la primera task falla el pull (es esperado, y pasa
  en segundos), y `null_resource.deploy` la reemplaza con un
  `force-new-deployment` una vez que la imagen ya existe. Todo dentro del
  mismo `apply`.
- Fargate no tiene un host al que hacerle SSH, así que en vez de eso el
  servicio tiene **ECS Exec** habilitado (`enable_execute_command = true`
  + un task role con permisos de `ssmmessages:*`): shell interactivo dentro
  del container vía SSM, sin abrir ningún puerto. Los outputs
  `list_tasks_command` y `exec_command_template` te dan los comandos listos
  (necesitás el [Session Manager
  plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  de AWS CLI instalado en tu máquina).
