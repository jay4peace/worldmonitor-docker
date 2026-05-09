# =============================================================================
# World Monitor — Docker Image
# =============================================================================
# Multi-stage build:
#   cloner   — fetches the source code from GitHub
#   builder  — installs deps, compiles TS handlers, builds Vite frontend
#   final    — nginx (static) + node (API) under supervisord
# =============================================================================

# ── Stage 0: Cloner ──────────────────────────────────────────────────────────
FROM alpine/git AS cloner
WORKDIR /src
ARG WORLDMONITOR_VERSION=main
RUN git clone --depth 1 --branch ${WORLDMONITOR_VERSION} https://github.com/koala73/worldmonitor.git .

# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

# Copy package files first to cache npm ci layer
COPY --from=cloner /src/package.json /src/package-lock.json ./

# Install root dependencies (layer-cached until package.json changes)
RUN npm ci --ignore-scripts

# Copy the rest of the source
COPY --from=cloner /src ./

# Compile TypeScript API handlers → self-contained ESM bundles
# Output is api/**/*.js alongside the source .ts files
RUN node docker/build-handlers.mjs

# Build Vite frontend (outputs to dist/)
# Skip blog build — blog-site has its own deps not installed here
RUN npx tsc && npx vite build

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM node:22-alpine AS final

# nginx + supervisord
RUN apk add --no-cache nginx supervisor gettext && \
    mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
             /tmp/nginx-uwsgi /tmp/nginx-scgi /var/log/supervisor && \
    addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# API server
COPY --from=builder /app/src-tauri/sidecar/local-api-server.mjs ./local-api-server.mjs
COPY --from=builder /app/src-tauri/sidecar/package.json ./package.json

# API handler modules (JS originals + compiled TS bundles)
COPY --from=builder /app/api ./api

# Static data files used by handlers at runtime
COPY --from=builder /app/data ./data

# Built frontend static files
COPY --from=builder /app/dist /usr/share/nginx/html

# Nginx + supervisord configs
COPY --from=builder /app/docker/nginx.conf /etc/nginx/nginx.conf.template
COPY --from=builder /app/docker/supervisord.conf /etc/supervisor/conf.d/worldmonitor.conf
COPY --from=builder /app/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Ensure writable dirs for non-root
RUN chown -R appuser:appgroup /app /tmp/nginx-client-body /tmp/nginx-proxy \
    /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi /var/log/supervisor \
    /var/lib/nginx /var/log/nginx

USER appuser

EXPOSE 8080

# Healthcheck via nginx
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:8080/api/health || exit 1

CMD ["/app/entrypoint.sh"]
