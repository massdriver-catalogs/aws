FROM debian:bookworm-slim

ARG TARGETARCH
ARG MASS_VERSION=2.6.0
ARG MCP_SERVER_VERSION=0.2.1
ARG MISE_VERSION=2026.11.14
ARG CLAUDE_CODE_VERSION=2.1.332

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl dnsutils git iproute2 iputils-ping jq less libcap2-bin \
      netcat-openbsd openssl procps tcpdump traceroute unzip xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 # The agent runs as a regular user; this lets it capture packets without root.
 && setcap cap_net_raw+eip /usr/bin/tcpdump

RUN set -eu; \
    cd /tmp; \
    case "$TARGETARCH" in amd64) mise_arch=x64 ;; arm64) mise_arch=arm64 ;; *) echo "unsupported $TARGETARCH" >&2; exit 1 ;; esac; \
    mass="mass-${MASS_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/massdriver-cloud/mass/releases/download/${MASS_VERSION}/${mass}"; \
    curl -fsSL -o mass.sums "https://github.com/massdriver-cloud/mass/releases/download/${MASS_VERSION}/checksums.txt"; \
    grep " ${mass}\$" mass.sums | sha256sum -c -; \
    tar -xzf "$mass" -C /usr/local/bin mass; \
    mcp="mcp-server_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/massdriver-cloud/mcp-server/releases/download/v${MCP_SERVER_VERSION}/${mcp}"; \
    curl -fsSL -o mcp.sums "https://github.com/massdriver-cloud/mcp-server/releases/download/v${MCP_SERVER_VERSION}/checksums.txt"; \
    grep " ${mcp}\$" mcp.sums | sha256sum -c -; \
    tar -xzf "$mcp" -C /usr/local/bin mcp-server; \
    mise="mise-v${MISE_VERSION}-linux-${mise_arch}"; \
    curl -fsSLO "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${mise}"; \
    curl -fsSL -o mise.sums "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/SHASUMS256.txt"; \
    grep "  \./${mise}\$\|  ${mise}\$" mise.sums | sed "s|\./||" | sha256sum -c -; \
    install -m 0755 "$mise" /usr/local/bin/mise; \
    rm -f /tmp/*

RUN useradd --create-home --uid 10001 --shell /bin/bash agent
USER agent
WORKDIR /home/agent

ENV PATH=/home/agent/.local/bin:/home/agent/.local/share/mise/shims:$PATH \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

RUN curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_CODE_VERSION" \
 && claude --version

COPY --chown=agent:agent --chmod=0755 agent.sh /usr/local/bin/agent

ENTRYPOINT ["/usr/local/bin/agent"]
