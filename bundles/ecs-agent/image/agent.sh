#!/usr/bin/env bash
set -uo pipefail

: "${AGENT_GOAL:?AGENT_GOAL is not set}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is not set}"
: "${MASSDRIVER_API_KEY:?MASSDRIVER_API_KEY is not set}"

name=${AGENT_NAME:-agent}
model=${AGENT_MODEL:-claude-opus-5-5}
effort=${AGENT_EFFORT:-medium}
interval=${AGENT_INTERVAL_SECONDS:-900}
budget=${AGENT_BUDGET_USD:-2}
notes="$HOME/NOTES.md"
mcp_config="$HOME/mcp.json"

log() { printf '%s agent: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# ECS sends SIGTERM to stop the task. Pass it on so a run in progress ends
# cleanly instead of being killed after the stop timeout.
child=
trap '[ -n "$child" ] && kill -TERM "$child" 2>/dev/null; wait; exit 0' TERM INT

if [ -n "${AGENT_MISE_TOOLS:-}" ]; then
  log "installing $AGENT_MISE_TOOLS"
  # shellcheck disable=SC2086 # one tool per word
  mise use --global --yes $AGENT_MISE_TOOLS || log "mise couldn't install every tool; carrying on without them"
fi

if [ -n "${AGENT_MCP_CONFIG:-}" ]; then
  printf '%s' "$AGENT_MCP_CONFIG" >"$mcp_config"
else
  echo '{"mcpServers": {"massdriver": {"type": "stdio", "command": "mcp-server"}}}' >"$mcp_config"
fi
touch "$notes"

system=$(cat <<EOF
You are $name, an agent that works on one goal in a Massdriver organization, around the clock, in runs.
You act as the Massdriver service account "$name". Everything you change is in the organization's audit log
under that name, and you can only do what its groups allow. If something is denied, say what you needed and why
in your notes; don't look for a way around it.

Use the massdriver MCP tools first. The mass CLI is on the PATH and already signed in, for anything they don't
cover. curl, jq, dig, nc, ping, traceroute, ss, ip, tcpdump, openssl and git are there for troubleshooting, and
mise installs other tools (mise use --global <tool>@<version>).

$notes is your memory between runs. Read it first. Before you finish, rewrite it: what you checked, what you
changed and why, what is still open, and what to look at first next run. Keep it short. A restart of the task
empties it.

Every deploy, proposal and plan you start carries a message a person can act on without opening anything else:
what changes, why (the failed deployment, alarm or drift that led you there, by ID), what you expect to happen,
and how to undo it. People approve your proposals from that message alone.

Finish the run when there's nothing more to do on the goal right now. The next run starts on its own.
EOF
)

run=0
while :; do
  run=$((run + 1))
  log "run $run with $model at $effort effort, up to \$$budget"
  claude --print "Goal:
$AGENT_GOAL

This is run $run. It is $(date -u +%FT%TZ)." \
    --append-system-prompt "$system" \
    --model "$model" \
    --effort "$effort" \
    --max-budget-usd "$budget" \
    --mcp-config "$mcp_config" \
    --strict-mcp-config \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose &
  child=$!
  wait "$child"
  status=$?
  child=
  [ "$status" -eq 0 ] || log "run $run ended with status $status"

  log "next run in ${interval}s"
  sleep "$interval" &
  child=$!
  wait "$child"
  child=
done
