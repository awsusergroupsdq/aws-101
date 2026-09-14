# aws-101

We are back! AWS 101 para todos 🐱

Contenido hands-on de la segunda mitad del evento: desplegar una app de
demo en AWS de dos formas distintas (EC2 y Fargate), usando OpenTofu y
GitHub Actions.

## Estructura

- [`docker/app/`](docker/app) — la app de demo: una página que llama a
  [thecatapi.com](https://thecatapi.com) y muestra gatos random.
- [`infra/`](infra) — dos stacks de OpenTofu **alternativos** (`base-ec2/` y
  `base-fargate/`) para desplegar la app. Ver [infra/README.md](infra/README.md)
  para el detalle de diseño (por qué el state es local, cómo se autentica
  GitHub Actions, orden de uso).
- [`.github/workflows/`](.github/workflows) — los 4 workflows del workshop:
  `01-provision-ec2` / `01-provision-fargate` (infra), `02-deploy-app`
  (build + push + deploy) y `03-destroy` (limpieza al terminar).
