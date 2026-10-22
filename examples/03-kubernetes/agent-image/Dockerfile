# The SRE agent as a container: bobi + Claude Code + the barndoor CLI + the
# agent package. Built from the repository root (see the Tiltfile):
#   docker build -f examples/03-kubernetes/agent-image/Dockerfile .
FROM node:20-bookworm-slim AS node

FROM python:3.12-slim-bookworm

ARG TARGETARCH
ARG BOBI_VERSION=0.58.0
ARG CLAUDE_VERSION=stable
# https://downloads.barndoor.ai/barndoor-cli/index.json lists every release
# and its checksums.
ARG BARNDOOR_CLI_VERSION=v0.1.244
ARG BARNDOOR_CLI_SHA256_AMD64=6e3fdf04d1ec2d7a390eef0240724afbc04aefe27293ce4b06903b5ebc6104da
ARG BARNDOOR_CLI_SHA256_ARM64=5681850306df363a17f976430dfe5c9f8596763ca4336ab0239da8415676c892

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/*

# bobi's embedded event server is a Node program; bookworm's nodejs is too old.
COPY --from=node /usr/local/bin/node /usr/local/bin/node

RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) sum="${BARNDOOR_CLI_SHA256_AMD64}" ;; \
      arm64) sum="${BARNDOOR_CLI_SHA256_ARM64}" ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/barndoor \
      "https://downloads.barndoor.ai/barndoor-cli/${BARNDOOR_CLI_VERSION}/barndoor-${BARNDOOR_CLI_VERSION}-linux-${TARGETARCH:-amd64}"; \
    echo "${sum}  /usr/local/bin/barndoor" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/barndoor

RUN pip install --no-cache-dir "bobi==${BOBI_VERSION}"

RUN useradd --uid 10001 --create-home --shell /bin/bash bobi \
    && mkdir -p /data && chown bobi:bobi /data

USER bobi
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"

COPY --chown=bobi:bobi agent/ /opt/sre/agent/
COPY --chown=bobi:bobi examples/03-kubernetes/agent-image/entrypoint.sh /opt/sre/entrypoint.sh

ENV HOME=/home/bobi \
    PATH=/opt/sre/agent/bin:/home/bobi/.local/bin:/usr/local/bin:/usr/bin:/bin \
    BOBI_HOME=/data/bobi \
    CLAUDE_CONFIG_DIR=/data/claude \
    SRE_INCIDENT_DIR=/data/incidents \
    BARNDOOR_BIN=/usr/local/bin/barndoor \
    BOBI_EVENT_SERVER=http://localhost:8080 \
    BOBI_ES_BIND=0.0.0.0 \
    BOBI_COMMUNICATION_STYLE=off \
    PYTHONUNBUFFERED=1

EXPOSE 8080
ENTRYPOINT ["/opt/sre/entrypoint.sh"]
