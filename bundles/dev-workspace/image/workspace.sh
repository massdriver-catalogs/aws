#!/usr/bin/env bash
# workspace         keep the sandbox running (the container's entrypoint)
# workspace shell   a login shell as the developer, from an ECS Exec session
set -uo pipefail

env_file=/run/workspace/env

if [ "${1:-}" = shell ]; then
  shift
  # ECS Exec sessions start as root with none of the task's settings.
  if [ "$(id -u)" = 0 ]; then
    exec su -l dev "$@"
  fi
  exec bash -l "$@"
fi

log() { printf '%s workspace: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# Shells opened later through ECS Exec or su don't inherit the task's
# environment, so it's kept where the login profile reads it. /run is not on
# the persistent volume, so secrets never outlive the task.
umask 077
: >"$env_file"
for name in $(compgen -e | grep -E '^(MASSDRIVER_|ANTHROPIC_|GH_TOKEN$|GITHUB_TOKEN$|WORKSPACE_|AWS_)'); do
  printf 'export %s=%q\n' "$name" "${!name}" >>"$env_file"
done
umask 022

mkdir -p "$HOME/.config/opencode" "$HOME/.local/bin"

# The developer may have edited these; only fill in what's missing.
massdriver_env='{"MASSDRIVER_API_KEY": "${MASSDRIVER_API_KEY}", "MASSDRIVER_ORGANIZATION_ID": "${MASSDRIVER_ORGANIZATION_ID}", "MASSDRIVER_URL": "${MASSDRIVER_URL}"}'
claude_json="$HOME/.claude.json"
[ -s "$claude_json" ] || echo '{}' >"$claude_json"
tmp=$(mktemp)
jq --argjson env "$massdriver_env" \
  '.mcpServers.massdriver //= {type: "stdio", command: "mcp-server", args: [], env: $env}' \
  "$claude_json" >"$tmp" && mv "$tmp" "$claude_json"

opencode_json="$HOME/.config/opencode/opencode.json"
[ -s "$opencode_json" ] || echo '{"$schema": "https://opencode.ai/config.json"}' >"$opencode_json"
tmp=$(mktemp)
jq '.mcp.massdriver //= {type: "local", command: ["mcp-server"], enabled: true}' \
  "$opencode_json" >"$tmp" && mv "$tmp" "$opencode_json"

[ -z "${WORKSPACE_GIT_NAME:-}" ] || git config --global user.name "$WORKSPACE_GIT_NAME"
[ -z "${WORKSPACE_GIT_EMAIL:-}" ] || git config --global user.email "$WORKSPACE_GIT_EMAIL"
if [ -n "${GH_TOKEN:-}" ]; then
  # Reads the token when git asks, so it's never written into ~/.gitconfig.
  git config --global credential.https://github.com.helper \
    '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
fi

if [ -n "${WORKSPACE_MISE_TOOLS:-}" ]; then
  log "installing $WORKSPACE_MISE_TOOLS"
  # shellcheck disable=SC2086 # one tool per word
  mise use --global --yes $WORKSPACE_MISE_TOOLS || log "mise couldn't install every tool; carrying on without them"
fi

log "ready"
exec sleep infinity
