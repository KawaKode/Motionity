# syntax=docker/dockerfile:1
#
# Motionity is a static app, so the runtime image is a static file server and
# nothing else: no Node, no shell tooling, ~8 MB of base image.
#
# Build:  docker build -t motionity:latest .
# Run:    docker run --rm -p 8080:8080 motionity:latest
#
# WITH_FFMPEG=0 drops the 23 MB ffmpeg.wasm core from the image and disables
# MP4/GIF export, which then reports itself as unavailable. It no longer falls
# back to downloading the encoder at run time: the old asm.js build came from a
# public archive.org mirror with no integrity check. Everything else, WEBM
# export included, is unaffected.

FROM node:22-alpine AS vendor
ARG WITH_FFMPEG=1
WORKDIR /app
# ffmpeg.wasm is a runtime dependency, so --omit=dev pulls it in without
# dragging electron and electron-builder (~400 MB) into the build.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY scripts/vendor.mjs scripts/
COPY src/index.html src/
RUN if [ "$WITH_FFMPEG" = "1" ]; then \
      node scripts/vendor.mjs; \
    else \
      node scripts/vendor.mjs --skip-ffmpeg; \
    fi

FROM ghcr.io/static-web-server/static-web-server:2-alpine

COPY --chown=65534:65534 src/ /public/
COPY --from=vendor --chown=65534:65534 /app/src/vendor/ /public/vendor/

ENV SERVER_ROOT=/public \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=8080 \
    SERVER_COMPRESSION=true \
    SERVER_COMPRESSION_LEVEL=default \
    SERVER_CACHE_CONTROL_HEADERS=true \
    SERVER_LOG_LEVEL=warn \
    SERVER_SECURITY_HEADERS=false \
    SERVER_HEALTH=true

USER 65534:65534
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q --spider http://127.0.0.1:8080/health || exit 1

# NOTE: browsers expose WebCodecs (the fast exporter) and IndexedDB (project
# saving) only in a secure context. Reaching this container over plain http://
# from another machine disables both. Publish it behind TLS, or keep access on
# http://localhost.
