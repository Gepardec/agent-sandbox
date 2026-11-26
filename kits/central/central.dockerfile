# syntax=docker/dockerfile:1.7
# JetBrains Central CLI as an overlay: a pinned, digest-checked release tarball
# holding one binary, extracted into /out/usr/local/bin at build time.
ARG BASE_IMAGE=docker/sandbox-templates:shell-docker
FROM ${BASE_IMAGE} AS build

ARG CENTRAL_VERSION=2.9.0
ARG TARGETARCH

USER root

RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) arch="x86_64"; \
        sha256=f4c870c2f25fa3ecefaa9f116cddaba565ef1e627382ba65f25eae19eb800ad7 ;; \
      arm64) arch="arm64"; \
        sha256=58d599cb0413111953ab68833c0995065d1825421945f51ed08e54c98fd86bbf ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/central.tgz \
      "https://jetbrains-central-cli.s3.eu-west-1.amazonaws.com/central/${CENTRAL_VERSION}/central_${CENTRAL_VERSION}_linux_${arch}.tar.gz"; \
    echo "${sha256}  /tmp/central.tgz" | sha256sum -c -; \
    mkdir -p /out/usr/local/bin; \
    tar -C /out/usr/local/bin -xzf /tmp/central.tgz central; \
    rm /tmp/central.tgz; \
    chmod 0755 /out/usr/local/bin/central; \
    chown 0:0 /out/usr/local/bin/central; \
    reported="$(/out/usr/local/bin/central --version | head -1)"; \
    echo "central --version: ${reported}"; \
    case "${reported}" in *"${CENTRAL_VERSION}"*) ;; \
      *) echo "pin mismatch: kit declares ${CENTRAL_VERSION}, central reports '${reported}'" >&2; exit 1 ;; \
    esac

FROM scratch
COPY --from=build /out /
