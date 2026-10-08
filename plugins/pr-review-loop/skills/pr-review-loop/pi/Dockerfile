# One-shot Pi reviewer image for pi-review.sh. Built on first use.
# Bump PI_VERSION here and the tag in pi-review.sh together.
FROM node:22-bookworm-slim
ARG PI_VERSION=0.73.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates ripgrep jq python3 make \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "@mariozechner/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force
ENV PI_OFFLINE=1 PI_TELEMETRY=0 HOME=/tmp
WORKDIR /work
ENTRYPOINT ["pi"]
