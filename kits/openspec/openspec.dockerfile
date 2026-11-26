# syntax=docker/dockerfile:1.7
# OpenSpec CLI as an overlay: installed at build time into /out/usr/local, so
# nothing is downloaded when a sandbox is created. The launcher is a node
# script (#!/usr/bin/env node), so the composed base must provide node >= 22.20.
FROM node:24-slim AS build

ARG OPENSPEC_VERSION=2.2.0

RUN set -eu; \
    npm install -g --prefix /out/usr/local "@fission-ai/openspec@${OPENSPEC_VERSION}"; \
    reported="$(/out/usr/local/bin/openspec --version | head -1 | tr -d '[:space:]')"; \
    echo "openspec --version: ${reported}"; \
    [ "${reported#v}" = "${OPENSPEC_VERSION}" ] || { \
      echo "pin mismatch: kit declares ${OPENSPEC_VERSION}, openspec reports '${reported}'" >&2; \
      exit 1; \
    }; \
    chown -R 0:0 /out

FROM scratch
COPY --from=build /out /
