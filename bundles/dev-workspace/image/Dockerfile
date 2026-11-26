FROM debian:bookworm-slim

ARG TARGETARCH
ARG MASS_VERSION=2.6.0
ARG MCP_SERVER_VERSION=0.2.1
ARG MISE_VERSION=2026.11.14
ARG CLAUDE_CODE_VERSION=2.1.332
ARG OPENCODE_VERSION=1.19.6
ARG OPENCODE_SHA256_ARM64=5b68c1f4c5e75b4134e664cc8f36d634d64208d4fcfe5bcf3b48bab699c2dbac
ARG OPENCODE_SHA256_AMD64=47734e08968b30cc22a0bffb6d9feeed76ad4aa743213a12122040392d09a057

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash bash-completion build-essential ca-certificates curl dnsutils fd-find git git-lfs htop \
      iproute2 iputils-ping jq less locales make nano netcat-openbsd openssh-client openssl procps \
      python3 python3-venv ripgrep rsync tmux traceroute tree unzip vim wget xz-utils zip \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

RUN set -eu; \
    cd /tmp; \
    case "$TARGETARCH" in \
      amd64) mise_arch=x64; oc_arch=x64; oc_sum="$OPENCODE_SHA256_AMD64" ;; \
      arm64) mise_arch=arm64; oc_arch=arm64; oc_sum="$OPENCODE_SHA256_ARM64" ;; \
      *) echo "unsupported $TARGETARCH" >&2; exit 1 ;; \
    esac; \
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
    # OpenCode publishes no checksum file; the digests are GitHub's, from the release's asset list.
    oc="opencode-linux-${oc_arch}.tar.gz"; \
    curl -fsSLO "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${oc}"; \
    echo "${oc_sum}  ${oc}" | sha256sum -c -; \
    tar -xzf "$oc" -C /usr/local/bin opencode; \
    rm -rf /tmp/*

# /home is the developer's persistent volume and hides anything installed
# under it, so Claude Code is installed elsewhere and copied onto the PATH.
RUN HOME=/opt/claude bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s "$0"' "$CLAUDE_CODE_VERSION" \
 && install -m 0755 "$(readlink -f /opt/claude/.local/bin/claude)" /usr/local/bin/claude \
 && rm -rf /opt/claude \
 && claude --version

RUN useradd --create-home --uid 10001 --shell /bin/bash dev \
 && install -d -o dev -g dev -m 0700 /run/workspace

COPY --chmod=0755 workspace.sh /usr/local/bin/workspace
COPY --chmod=0644 profile.sh /etc/profile.d/workspace.sh
RUN printf '\n. /etc/profile.d/workspace.sh\n' >>/etc/bash.bashrc

ENV LANG=en_US.UTF-8 \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1

USER dev
WORKDIR /home/dev

ENTRYPOINT ["/usr/local/bin/workspace"]
