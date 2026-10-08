# One-shot Pi reviewer image for pi-review.sh. Built on first use.
# Bump PI_VERSION here and the tag in pi-review.sh together.
FROM node:22-bookworm-slim
ARG PI_VERSION=0.73.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates ripgrep jq python3 make \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "@mariozechner/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force
# Providers Pi does not ship: Alibaba Model Studio / Qwen Cloud, pay-as-you-go
# (dashscope) and the Token Plan (qwen-token-plan). Same models, separate keys.
COPY models.json /opt/pi-agent/models.json
RUN chmod 1777 /opt/pi-agent
ENV PI_OFFLINE=1 PI_TELEMETRY=0 HOME=/tmp PI_CODING_AGENT_DIR=/opt/pi-agent
WORKDIR /work
ENTRYPOINT ["pi"]
