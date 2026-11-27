FROM debian:bookworm-slim

ARG TARGETARCH
ARG NODE_VERSION=24.22.3
ARG MASS_VERSION=2.6.0
ARG MISE_VERSION=2026.11.14
ARG OPENCODE_VERSION=1.19.6
ARG OPENCODE_SHA256_ARM64=5b68c1f4c5e75b4134e664cc8f36d634d64208d4fcfe5bcf3b48bab699c2dbac
ARG OPENCODE_SHA256_AMD64=47734e08968b30cc22a0bffb6d9feeed76ad4aa743213a12122040392d09a057
ARG PHASER_VERSION=4.2.1
ARG KAPLAY_VERSION=3001.0.19
ARG THREE_VERSION=0.187.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less locales nano procps python3 \
      ripgrep unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

RUN set -eu; \
    cd /tmp; \
    case "$TARGETARCH" in \
      amd64) node_arch=x64; mise_arch=x64; oc_arch=x64; oc_sum="$OPENCODE_SHA256_AMD64" ;; \
      arm64) node_arch=arm64; mise_arch=arm64; oc_arch=arm64; oc_sum="$OPENCODE_SHA256_ARM64" ;; \
      *) echo "unsupported $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    node="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${node}"; \
    curl -fsSL -o node.sums "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep "  ${node}\$" node.sums | sha256sum -c -; \
    tar -xJf "$node" -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/include/*' --exclude='*/share/doc/*'; \
    mass="mass-${MASS_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/massdriver-cloud/mass/releases/download/${MASS_VERSION}/${mass}"; \
    curl -fsSL -o mass.sums "https://github.com/massdriver-cloud/mass/releases/download/${MASS_VERSION}/checksums.txt"; \
    grep " ${mass}\$" mass.sums | sha256sum -c -; \
    tar -xzf "$mass" -C /usr/local/bin mass; \
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
    rm -rf /tmp/*; \
    node --version; opencode --version

# Games load these from /play/lib/ with no build step and no CDN, so a lab
# works the same whether or not the agent ever runs npm.
RUN set -eu; \
    mkdir -p /opt/gamelab/lib /tmp/libs; \
    cd /tmp/libs; \
    npm install --no-audit --no-fund --ignore-scripts \
      "phaser@${PHASER_VERSION}" "kaplay@${KAPLAY_VERSION}" "three@${THREE_VERSION}" >/dev/null; \
    cp node_modules/phaser/dist/phaser.min.js /opt/gamelab/lib/phaser.min.js; \
    cp node_modules/kaplay/dist/kaplay.js /opt/gamelab/lib/kaplay.js; \
    cp node_modules/kaplay/dist/kaplay.mjs /opt/gamelab/lib/kaplay.mjs; \
    cp node_modules/three/build/three.module.js node_modules/three/build/three.core.js /opt/gamelab/lib/; \
    printf '{"phaser":"%s","kaplay":"%s","three":"%s"}\n' "$PHASER_VERSION" "$KAPLAY_VERSION" "$THREE_VERSION" >/opt/gamelab/lib/versions.json; \
    rm -rf /tmp/libs /root/.npm

# The game server runs as its own user, in the player's group, so it can read
# the game but the agent, running as the player, can't read its environment,
# where the AWS credentials for the saves table are.
RUN useradd --create-home --uid 10001 --shell /bin/bash player \
 && useradd --no-create-home --uid 10002 --gid 10001 --shell /usr/sbin/nologin gameserver \
 && install -d -m 0755 /etc/gamelab

COPY --chmod=0644 prompts/ /opt/gamelab/prompts/
COPY --chmod=0644 starter/ /opt/gamelab/starter/
COPY --chmod=0644 game-server.mjs /opt/gamelab/game-server.mjs
COPY --chmod=0644 screen.js saves.js /opt/gamelab/lib/
COPY --chmod=0755 lab.sh /usr/local/bin/lab

ENV LANG=en_US.UTF-8 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_CONFIG=/etc/gamelab/opencode.json \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# Starts as root only to write the agent's settings where the agent can't
# change them, then runs everything as the player.
WORKDIR /home/player
EXPOSE 4096 8080
ENTRYPOINT ["/usr/local/bin/lab"]
