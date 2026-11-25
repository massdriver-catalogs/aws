#!/usr/bin/env bash
# Runs Massdriver automations for Tendwell on this computer. Each automation
# gets its own process and event destination, all behind one ngrok tunnel;
# Ctrl-C deletes the destinations.
#
#   ./automations.sh                    every automation below
#   ./automations.sh statuspage router  only these
#
# Needs go, ngrok with an auth token, jq, a clone of massdriver-automations
# (AUTOMATIONS_SRC, default: next to this repository), and a mass with
# `mass event destination`. Run ./deploy.sh bootstrap first: it makes the
# Automations service account, the autodeploy and autorollback attributes, and
# the Developer Sandboxes project.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${AUTOMATIONS_SRC:-$HERE/../../../massdriver-automations}
INSPECTOR=${NGROK_INSPECTOR:-127.0.0.1:4040}
DEFAULT=(statuspage drift autodeploy-downstream rollback-on-failure freeze-guard router sandbox-on-join)

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# destination_flags <name>: what each automation's README subscribes to,
# narrowed to Tendwell.
destination_flags() {
  case $1 in
    statuspage)
      flags=(--event-type 'alarm.*' --event-type alarm_state.created
        --event-type deployment.started --event-type deployment.completed
        --event-type deployment.failed --event-type deployment.aborted --event-type 'instance.*'
        --condition '(.data.attributes["md-project"] | IN("visits", "care", "billing")) and (.data.metadata.deployment_action // "PROVISION") != "PLAN"') ;;
    drift)
      flags=(--event-type deployment.completed --event-type deployment.failed --event-type deployment.aborted
        --condition '.data.metadata.deployment_action == "PLAN"') ;;
    autodeploy-downstream)
      flags=(--event-type deployment.completed --condition '.data.metadata.deployment_action == "PROVISION"') ;;
    rollback-on-failure)
      flags=(--event-type deployment.failed --attribute md-environment=dev
        --condition '.data.metadata.deployment_action == "PROVISION" and .data.attributes["autorollback"] == "true"') ;;
    freeze-guard)
      flags=(--event-type group.created --event-type group.updated --event-type group.deleted) ;;
    router)
      flags=(--event-type deployment.failed --event-type deployment.completed --event-type deployment.proposed
        --event-type alarm_state.created --event-type group_membership.added --event-type group_membership.removed
        --condition '(.data.metadata.deployment_action // "") != "PLAN"') ;;
    sandbox-on-join)
      flags=(--event-type group_membership.added --event-type group_membership.removed --event-type deployment.completed
        --condition '((.type | startswith("group_membership.")) and .data.entity.account_id != null and (.data.entity.group_name | IN("Patient Experience", "Clinical", "Revenue", "Platform Engineering"))) or (.type == "deployment.completed" and .data.metadata.deployment_action == "DECOMMISSION" and .data.attributes.sandbox == "true")') ;;
    *) die "$1 isn't set up for Tendwell; choose from: ${DEFAULT[*]}" ;;
  esac
}

# automation_env <name>: settings beyond the common ones.
automation_env() {
  case $1 in
    statuspage) echo "STATUSPAGE_CONFIG=$HERE/automations/statuspage.yaml STATE_DIR=$work/state/statuspage" ;;
    drift) echo "DRIFT_CONFIG=$HERE/automations/drift.yaml DRIFT_RUN_TOKEN=$drift_token STATE_DIR=$work/state/drift" ;;
    freeze-guard) echo "FREEZE_WINDOWS_FILE=$HERE/automations/freeze-guard.yaml FREEZE_ADMIN_TOKEN=$admin_token STATE_DIR=$work/state/freeze-guard" ;;
    autodeploy-downstream) echo "AUTODEPLOY_CONFIG=$HERE/automations/autodeploy.yaml" ;;
    router) echo "ROUTER_CONFIG=$HERE/automations/router.yaml" ;;
    sandbox-on-join) echo "SANDBOX_CONFIG=$HERE/automations/sandboxes.yaml" ;;
  esac
}

names=("$@")
[ ${#names[@]} -gt 0 ] || names=("${DEFAULT[@]}")
for name in "${names[@]}"; do destination_flags "$name"; done

for tool in go ngrok jq curl mass; do command -v "$tool" >/dev/null || die "$tool isn't installed"; done
mass event destination --help >/dev/null 2>&1 ||
  die "this mass has no event destination commands; install it from main: go install github.com/massdriver-cloud/mass@main"
[ -f "$SRC/go.mod" ] || die "no massdriver-automations clone at $SRC; set AUTOMATIONS_SRC"

# Another run already holds the ports, and would get this run's events.
for port in $(seq 18080 $((18080 + ${#names[@]}))); do
  ! nc -z 127.0.0.1 "$port" 2>/dev/null || die "port $port is in use; is another automations.sh running?"
done

org=$(mass whoami -o json | jq -r .organization.id)
api_key=$(cd "$HERE" && tofu output -raw automations_api_key 2>/dev/null) ||
  die "no Automations service account; run ./deploy.sh bootstrap"
drift_token=$(openssl rand -hex 16)
admin_token=$(openssl rand -hex 16)
# The prefix pipe hides the terminal from the automations, which would
# otherwise pick colored text logs themselves.
log_format=json
colors=(36 35 33 34 32 96 95 93)
if [ -t 2 ]; then log_format=text; fi

work=$(mktemp -d)
destinations=()
cleanup() {
  trap - EXIT INT TERM
  local id
  for id in ${destinations[@]+"${destinations[@]}"}; do
    mass event destination delete "$id" --force >/dev/null 2>&1 || echo "couldn't delete event destination $id" >&2
  done
  [ ${#destinations[@]} -eq 0 ] || log "deleted the event destinations"
  pkill -f "$work/(massdriver-automations|proxy)" 2>/dev/null || true
  [ -z "${ngrok_pid:-}" ] || kill "$ngrok_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

log "build massdriver-automations from $SRC"
(cd "$SRC" && go build -o "$work/massdriver-automations" ./cmd/massdriver-automations)
go build -o "$work/proxy" "$HERE/automations/proxy.go"

proxy_port=18080
routes=()
port=$proxy_port
for name in "${names[@]}"; do
  port=$((port + 1))
  routes+=("$name=$port")
done
"$work/proxy" "$proxy_port" "${routes[@]}" 2>&1 | sed -u 's/^/[proxy] /' &

log "open an ngrok tunnel"
ngrok http "$proxy_port" --log stdout >"$work/ngrok.log" 2>&1 &
ngrok_pid=$!
for _ in $(seq 30); do
  tunnel=$(curl -fsS "http://$INSPECTOR/api/tunnels" 2>/dev/null |
    jq -r --arg p ":$proxy_port" '.tunnels[] | select(.config.addr | endswith($p)) | .public_url' 2>/dev/null || true)
  [ -n "$tunnel" ] && break
  sleep 1
done
[ -n "$tunnel" ] || die "ngrok didn't open a tunnel; its log ends: $(tail -3 "$work/ngrok.log")"

port=$proxy_port
for name in "${names[@]}"; do
  port=$((port + 1))
  destination="$name (local)"

  # A run that didn't get to clean up leaves its destination behind, and names are unique.
  mass event destination list -o json | jq -r --arg n "$destination" '.[]? | select(.name == $n) | .id' |
    while read -r stale; do mass event destination delete "$stale" --force >/dev/null; done

  destination_flags "$name"
  created=$(mass event destination create --name "$destination" --url "$tunnel/$name/hooks/massdriver" "${flags[@]}")
  id=$(sed -n 's/.*(ID: \([^)]*\)).*/\1/p' <<<"$created")
  secret=$(sed -n 's/.*Signing secret: \(whsec_[^ ]*\).*/\1/p' <<<"$created")
  [ -n "$id" ] && [ -n "$secret" ] || die "couldn't create the $name event destination"
  destinations+=("$id")

  mkdir -p "$work/state/$name"
  # shellcheck disable=SC2046 # automation_env returns KEY=value words without spaces
  env MASSDRIVER_ORGANIZATION_ID="$org" MASSDRIVER_API_KEY="$api_key" MASSDRIVER_SIGNING_SECRET="$secret" \
    PORT="$port" LOG_FORMAT="${LOG_FORMAT:-$log_format}" $(automation_env "$name") \
  prefix="[$name]"
  [ "$log_format" = json ] || prefix=$(printf '\033[%sm[%s]\033[0m' "${colors[$(((port - 18081) % ${#colors[@]}))]}" "$name")
  "$work/massdriver-automations" run "$name" 2>&1 | sed -u "s|^|$prefix |" &
  log "$name receives events at $tunnel/$name/hooks/massdriver"
done

cat >&2 <<EOF

Running ${names[*]} against $org. Ctrl-C stops them and deletes their event destinations.
  Requests:     http://$INSPECTOR
EOF
for name in "${names[@]}"; do
  case $name in
    statuspage) echo "  Status page:  $tunnel/statuspage/" >&2 ;;
    drift) echo "  Drift check:  curl -X POST -H 'Authorization: Bearer $drift_token' '$tunnel/drift/drift/run?check=dev'" >&2 ;;
    freeze-guard) echo "  Lift freeze:  curl -X POST -H 'Authorization: Bearer $admin_token' '$tunnel/freeze-guard/freeze/lift?window=after-hours'" >&2 ;;
  esac
done
echo >&2

wait
