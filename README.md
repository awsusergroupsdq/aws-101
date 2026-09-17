# aws-101

We are back! AWS 101 para todos 🐱

Contenido hands-on de la segunda mitad del evento: desplegar una app de
demo en AWS de dos formas distintas (EC2 y Fargate), usando OpenTofu y
GitHub Actions.

## Antes de arrancar — checklist

- [ ] **Una cuenta de AWS propia**, con un usuario IAM (no hace falta ser
      admin — alcanza con permisos para EC2, ECS, ECR, IAM y SSM).
- [ ] **Access Key ID + Secret Access Key** de ese usuario IAM — los vas a
      cargar como Secrets en tu fork.
- [ ] **Un fork de este repo** en tu propia cuenta de GitHub (botón
      **Fork**, arriba a la derecha).
- [ ] *(Opcional)* `tofu` + `docker` (con el daemon corriendo) + `aws` CLI
      instalados, solo si querés probar los pasos en tu máquina antes de
      usar GitHub Actions — ver "Opción B" en
      [infra/README.md](infra/README.md#cómo-usar).

## Estructura

- [`docker/app/`](docker/app) — la app de demo: una página que llama a
  [thecatapi.com](https://thecatapi.com) y muestra gatos random.
- [`infra/`](infra) — dos stacks de OpenTofu **alternativos** (`base-ec2/` y
  `base-fargate/`) para desplegar la app. **Un solo `tofu apply` provisiona
  y despliega** (no hay un paso de deploy separado). Ver
  [infra/README.md](infra/README.md) para el detalle de diseño.
- [`.github/workflows/`](.github/workflows) — los 3 workflows del workshop:
  `01-provision-ec2` / `01-provision-fargate` (provisionan **y despliegan**
  la app en el mismo `apply`) y `03-destroy` (limpieza al terminar).
