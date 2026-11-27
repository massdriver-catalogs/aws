#!/usr/bin/env bash
# lab         run the lab: the coding agent and the game server (the container's entrypoint)
# lab shell   a login shell as the player, from an ECS Exec session
set -uo pipefail

PLAYER=player
HOME_DIR=/home/$PLAYER
GAME_DIR=$HOME_DIR/game
AGENT_PORT=${AGENT_PORT:-4096}
GAME_PORT=${GAME_PORT:-8080}

if [ "${1:-}" = shell ]; then
  shift
  if [ "$(id -u)" = 0 ]; then
    exec su -l "$PLAYER" "$@"
  fi
  exec bash -l "$@"
fi

log() { printf '%s lab: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "start as root; the lab drops to the player itself"
# The agent can run any command in the lab, so it never listens without a password.
[ -n "${LAB_PASSWORD:-}" ] || die "LAB_PASSWORD is not set; refusing to start the agent without one"
[ -n "${ANTHROPIC_API_KEY:-}" ] || log "ANTHROPIC_API_KEY is not set; the agent will answer with an error until it is"

age=${PLAYER_AGE:-8}
[[ "$age" =~ ^[0-9]+$ ]] || die "PLAYER_AGE must be a number, got '$age'"
if [ "$age" -le 8 ]; then
  band=ages-5-8
elif [ "$age" -le 12 ]; then
  band=ages-9-12
else
  band=ages-13-17
fi
name=${PLAYER_NAME:-Player}
model=${LAB_MODEL:-claude-opus-5-5}

if [ -n "${GAMELAB_TABLE:-}" ]; then
  saves="- Saves & scores are on in this lab: what a game saves with \`lib/saves.js\` lasts, and the high-score list stays between visits.
"
else
  saves="- Saves & scores are off in this lab: \`lib/saves.js\` still works, but what a game saves lasts only until the game reloads. If the player wants saves that last, tell them to ask their grown-up about Saves & scores.
"
fi

# The prompt and settings live outside the player's home so the agent can't
# rewrite its own rules.
{
  cat /opt/gamelab/prompts/base.md
  printf '\n'
  cat "/opt/gamelab/prompts/$band.md"
  printf '\n## This lab\n\n'
  printf -- '- The player is %s, age %s. Use their first name; never ask for more about them.\n' "$name" "$age"
  printf -- '- The game lives in `%s`. The Play panel shows `index.html` from there, so open it in the Play panel instead of starting a server.\n' "$GAME_DIR"
  printf -- '- Game libraries are already here and load with no internet: `lib/phaser.min.js`, `lib/kaplay.mjs`, `lib/kaplay.js` and `lib/three.module.js` (an ES module: `import * as THREE from "./lib/three.module.js"`). Load them with a relative path, like `<script src="lib/phaser.min.js"></script>`.\n'
  printf '%s' "$saves"
} >/etc/gamelab/prompt.md

# Young players don't need the web; it's where the unsafe content is.
if [ "$age" -ge 13 ]; then web=allow; else web=deny; fi

jq -n \
  --rawfile prompt /etc/gamelab/prompt.md \
  --arg model "anthropic/$model" \
  --arg web "$web" \
  '{
    "$schema": "https://opencode.ai/config.json",
    share: "disabled",
    autoupdate: false,
    enabled_providers: ["anthropic"],
    model: $model,
    small_model: "anthropic/claude-haiku-5-5",
    default_agent: "gamelab",
    agent: {
      gamelab: {
        mode: "primary",
        description: "Builds browser games together with a young player.",
        prompt: $prompt
      }
    },
    # Gamelab shows the chat, not permission prompts, so nothing may wait on "ask".
    permission: {
      edit: {"*": "allow", "opencode.json": "deny", "**/opencode.json": "deny", ".opencode/**": "deny", "AGENTS.md": "deny"},
      bash: {
        "*": "allow",
        "sudo *": "deny", "su *": "deny", "ssh *": "deny", "scp *": "deny",
        "git push*": "deny", "curl *": "deny", "wget *": "deny",
        "opencode *": "deny", "npx localtunnel*": "deny", "npx ngrok*": "deny", "ngrok *": "deny", "cloudflared *": "deny"
      },
      external_directory: "deny",
      webfetch: $web,
      websearch: $web,
      question: "deny",
      doom_loop: "deny",
      skill: "deny"
    }
  }' >/etc/gamelab/opencode.json.tmp ||
  die "couldn't write the agent's settings"
mv /etc/gamelab/opencode.json.tmp /etc/gamelab/opencode.json
chmod 0644 /etc/gamelab/opencode.json /etc/gamelab/prompt.md

# A new lab starts with a page the player can see right away.
if [ ! -e "$GAME_DIR/index.html" ]; then
  log "first start: putting a hello page in $GAME_DIR"
  install -d -o "$PLAYER" -g "$PLAYER" "$GAME_DIR"
  sed "s/{{PLAYER_NAME}}/$(printf '%s' "$name" | sed 's/[&/\]/\\&/g')/g" /opt/gamelab/starter/index.html >"$GAME_DIR/index.html"
  chown "$PLAYER:$PLAYER" "$GAME_DIR/index.html"
fi
for dir in .local .local/share .local/state .cache .config; do
  install -d -o "$PLAYER" -g "$PLAYER" "$HOME_DIR/$dir"
done
ln -sfn /opt/gamelab/lib "$GAME_DIR/lib" 2>/dev/null || true

as_player() {
  setpriv --reuid=10001 --regid=10001 --init-groups --reset-env -- \
    env HOME="$HOME_DIR" USER="$PLAYER" PATH=/usr/local/bin:/usr/bin:/bin LANG="$LANG" \
    OPENCODE_CONFIG="$OPENCODE_CONFIG" OPENCODE_DISABLE_AUTOUPDATE=1 \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    "$@"
}

# The task role's credentials reach only the game server; the agent never
# sees them.
as_game_server() {
  setpriv --reuid=10002 --regid=10001 --clear-groups --reset-env -- \
    env HOME=/nonexistent PATH=/usr/local/bin:/usr/bin:/bin LANG="$LANG" \
    GAME_DIR="$GAME_DIR" GAME_PORT="$GAME_PORT" \
    GAMELAB_TABLE="${GAMELAB_TABLE:-}" GAMELAB_TABLE_REGION="${GAMELAB_TABLE_REGION:-${AWS_REGION:-}}" \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" \
    "$@"
}

cd "$GAME_DIR" || die "no game directory"

log "game server on :$GAME_PORT"
as_game_server node /opt/gamelab/game-server.mjs &
game=$!

log "agent ($model, rules for $band) on :$AGENT_PORT"
as_player env OPENCODE_SERVER_PASSWORD="$LAB_PASSWORD" \
  opencode serve --hostname 0.0.0.0 --port "$AGENT_PORT" &
agent=$!

trap 'kill "$game" "$agent" 2>/dev/null' TERM INT
# Either one stopping means the lab is broken; exit so ECS starts a new one.
wait -n "$game" "$agent"
status=$?
log "a lab process stopped (exit $status); stopping the lab"
kill "$game" "$agent" 2>/dev/null
wait
exit "$status"
