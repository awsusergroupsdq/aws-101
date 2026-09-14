# Imagen mínima para servir una página estática.
# Sin build step: index.html se sirve tal cual con nginx.
FROM nginx:alpine

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/ >/dev/null || exit 1
