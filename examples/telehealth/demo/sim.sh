#!/usr/bin/env bash
# Makes a Tendwell stage look busy for a demo: real traffic against the apps, banners and
# header links on the canvas, a merge queue of pull requests on the project page, alarms
# that fire and clear, results on deployments, labeled metadata on instances, and deploys
# that change nothing.
#
#   ./sim.sh traffic [minutes]          steady requests to visits, care and billing
#   ./sim.sh banners [minutes]          a calm banner every few minutes on the visits canvas
#   ./sim.sh flap [minutes]             a banner that changes level every 30 seconds
#   ./sim.sh links                      header links on the visits canvas
#   ./sim.sh prs [minutes]              a merge queue of pull requests on the visits project
#   ./sim.sh alarms [minutes]           fire and clear random alarms outside visits
#   ./sim.sh metadata                   labeled metadata on the visits instances
#   ./sim.sh results [instance]         step, changes and compliance results on a deployment
#   ./sim.sh deploys [count]            deploys that change nothing, across care and billing
#   ./sim.sh all [minutes]              traffic, banners, prs and alarms together
#   ./sim.sh clear                      remove what this script wrote
#
# Settings, from the environment:
#   STAGE     dev (default) or prod
#   DOMAIN    the parent domain from bootstrap.sh; the apps answer at <app>.<STAGE>.<DOMAIN>
#   MASS      the mass CLI, with the `alpha stash` commands (default: mass)
#   AWS_REGION  where the alarms live (default: us-east-1)
#
# Every stash entry this script writes expires on its own, except the metadata labels and
# deployment results, which `clear` removes.

set -euo pipefail

STAGE=${STAGE:-dev}
MASS=${MASS:-mass}
AWS_REGION=${AWS_REGION:-us-east-1}
: "${DOMAIN:?set DOMAIN, the parent domain the stages use}"
ORG=$($MASS whoami -o json | jq -r .organization.id)
VISITS=https://visits.$STAGE.$DOMAIN
ENV=visits-$STAGE

say() { printf '%s %s\n' "$(date +%T)" "$*"; }
stash() { $MASS alpha stash "$@" >/dev/null; }
json() { stash set "$1" "$2" --format json "${@:3}"; }
minutes() { echo $(( ${1:-10} * 60 )); }

cmd_traffic() {
  local end=$((SECONDS + $(minutes "${1:-20}")))
  say "traffic for ${1:-20} minutes"
  while [ $SECONDS -lt $end ]; do
    seq 20 | xargs -P 3 -I{} sh -c "curl -s -o /dev/null -m 8 $VISITS/slots; curl -s -o /dev/null -m 8 $VISITS/appointments" 2>/dev/null || true
    for app in care billing; do
      seq 10 | xargs -P 2 -I{} curl -s -o /dev/null -m 8 "https://$app.$STAGE.$DOMAIN/" 2>/dev/null || true
    done
    sleep 5
  done
}

banner() {
  json "env:$ENV.md/v1/banner" "$(jq -nc --arg m "$1" --arg l "$2" '{message: $m, level: $l}')" --ttl 900
  say "banner [$2] $1"
}

cmd_banners() {
  local end=$((SECONDS + $(minutes "${1:-30}"))) i=0
  local msgs=(
    "info|Clinics are open. Booking traffic is normal."
    "info|Merge queue is shipping to $STAGE."
    "info|Reminders are sending on time."
    "warning|A pull request failed checks. The merge queue retries it after a fix."
    "info|$STAGE is healthy."
  )
  while [ $SECONDS -lt $end ]; do
    IFS='|' read -r level msg <<<"${msgs[$((i % ${#msgs[@]}))]}"
    banner "$msg" "$level"
    i=$((i + 1))
    sleep 240
  done
}

cmd_flap() {
  local end=$((SECONDS + $(minutes "${1:-10}"))) i=0
  local msgs=(
    "info|Clinics are open. Booking traffic is normal."
    "warning|Reminder latency is climbing. Watching the queue."
    "error|Reminder sender is failing to send SMS. Investigating."
    "warning|SMS sending recovered. Draining the backlog."
  )
  while [ $SECONDS -lt $end ]; do
    IFS='|' read -r level msg <<<"${msgs[$((i % ${#msgs[@]}))]}"
    banner "$msg" "$level"
    i=$((i + 1))
    sleep 30
  done
  banner "$STAGE is healthy." info
}

cmd_links() {
  json "env:$ENV.md/v1/links" "$(jq -nc --arg v "$VISITS" --arg s "https://statuspage.$STAGE.$DOMAIN/$STAGE/" \
    '{links: [{label: "Booking API", url: "\($v)/slots"}, {label: "Status page", url: $s}]}')" --ttl 3600
  say "header links on $ENV"
}

cmd_prs() {
  local end=$((SECONDS + $(minutes "${1:-30}"))) n=490 p=0 q='[]'
  local pool=(
    "visits|maria|Waitlist emails when a slot opens"
    "visits|james|Retry bounced SMS reminders twice"
    "infra|renovate|Bump aws provider"
    "visits|priya|Show clinic address on the confirmation page"
    "care|dana|Attach intake forms to a session"
    "billing|lee|Round copays to the cent before posting"
    "visits|daniel|Paginate the appointments list"
    "infra|sofia|Alarm when the reminders queue backs up"
  )
  add() {
    IFS='|' read -r repo author title <<<"${pool[$((p % ${#pool[@]}))]}"
    p=$((p + 1)); n=$((n + 1))
    q=$(jq -c --arg r "$repo" --arg a "$author" --arg t "$title" --argjson n $n \
      '. + [{number: $n, repo: $r, author: $a, title: $t, state: "queued", url: "https://github.com/example/\($r)/pull/\($n)"}]' <<<"$q")
  }
  push() { json "visits.github/prs" "$(jq -c '{prs: .}' <<<"$q")" --label "Pull requests" --ttl 3600; }
  for _ in 1 2 3 4 5; do add; done
  push
  say "merge queue on the visits project"
  while [ $SECONDS -lt $end ]; do
    local i st new
    i=$(jq '[.[].state] | index("checks") // index("merging") // index("failed") // index("queued")' <<<"$q")
    st=$(jq -r ".[$i].state" <<<"$q")
    case $st in
      queued) new=checks ;;
      checks) if [ $((RANDOM % 7)) = 0 ]; then new=failed; else new=merging; fi ;;
      failed) new=checks ;;
      *) new=merged ;;
    esac
    q=$(jq -c --argjson i "$i" --arg s "$new" '.[$i].state = $s' <<<"$q")
    if [ "$new" = merged ]; then
      q=$(jq -c '(map(select(.state == "merged")) | .[-2:]) + map(select(.state != "merged"))' <<<"$q")
      add
    fi
    push
    say "#$(jq -r ".[$i].number" <<<"$q" 2>/dev/null) $new"
    sleep $((45 + RANDOM % 45))
  done
}

cmd_alarms() {
  local end=$((SECONDS + $(minutes "${1:-15}"))) firing=() alarms
  alarms=$(aws cloudwatch describe-alarms --region "$AWS_REGION" --alarm-name-prefix "$ORG-" \
    --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | grep -v -- "-visits-" || true)
  [ -n "$alarms" ] || { say "no alarms outside visits"; return; }
  set_state() {
    aws cloudwatch set-alarm-state --region "$AWS_REGION" --alarm-name "$1" --state-value "$2" --state-reason "Demo" >/dev/null
    say "$2 $1"
  }
  while [ $SECONDS -lt $end ]; do
    if [ ${#firing[@]} -gt 0 ] && [ $((RANDOM % 2)) = 0 ]; then
      local k=$((RANDOM % ${#firing[@]}))
      set_state "${firing[$k]}" OK
      firing=("${firing[@]:0:$k}" "${firing[@]:$((k + 1))}")
    else
      local a
      a=$(shuf -n1 <<<"$alarms" 2>/dev/null || awk -v r=$RANDOM 'BEGIN{srand(r)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' <<<"$alarms")
      set_state "$a" ALARM
      firing+=("$a")
    fi
    sleep $((20 + RANDOM % 40))
  done
  for a in "${firing[@]}"; do set_state "$a" OK; done
}

cmd_metadata() {
  stash set "visits-$STAGE-app.release" "$(date +%Y.%m.%d)-1" --label "Release"
  stash set "visits-$STAGE-app.oncall" "Dana Smith" --label "On call"
  json "visits-$STAGE-app.flags" '{"sms_reminders": true, "waitlist": false, "video_visits": true}' --label "Feature flags"
  json "visits-$STAGE-slots.capacity" '{"mode": "on-demand", "items": 1284}' --label "Capacity"
  stash set "visits-$STAGE-reminders.retention" "4 days" --label "Retention"
  say "metadata on the visits instances"
}

latest_deployment() {
  $MASS deployment list "$1" -o json | jq -r '[.[] | select(.status == "COMPLETED")][0].id // empty'
}

cmd_results() {
  local inst=${1:-visits-$STAGE-app} dep now
  dep=$(latest_deployment "$inst")
  [ -n "$dep" ] || { say "$inst has no completed deployment"; return 1; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json "$dep.md/v1/step/src" "$(jq -nc --arg t "$now" '{tool: "opentofu", action: "apply", status: "succeeded", finished_at: $t, duration_s: 142, message: "Apply complete! Resources: 1 added, 2 changed, 0 destroyed."}')" --label "OpenTofu step"
  json "$dep.md/v1/changes/src" '{"tool": "opentofu", "add": 1, "change": 2, "destroy": 0}' --label "Changes"
  json "$dep.md/v1/compliance/src" '{"tool": "checkov", "passed": 36, "failed": 0, "skipped": 2}' --label "Checkov"
  say "results on $inst deployment $dep"
}

cmd_deploys() {
  local count=${1:-6} i=0
  local instances=(care-$STAGE-app billing-$STAGE-app care-$STAGE-sessions billing-$STAGE-claims care-$STAGE-documents billing-$STAGE-ledger)
  while [ $i -lt "$count" ]; do
    local inst=${instances[$((i % ${#instances[@]}))]}
    $MASS instance deploy "$inst" -m "Routine redeploy, same config" >/dev/null && say "deploy $inst" || say "deploy $inst failed"
    i=$((i + 1))
    sleep 60
  done
}

cmd_all() {
  local m=${1:-20}
  cmd_links
  cmd_metadata
  cmd_traffic "$m" &
  cmd_banners "$m" &
  cmd_prs "$m" &
  cmd_alarms "$m" &
  wait
}

cmd_clear() {
  for k in md/v1/banner md/v1/links; do stash delete "env:$ENV.$k" --force || true; done
  stash delete "visits.github/prs" --force || true
  for k in release oncall flags; do stash delete "visits-$STAGE-app.$k" --force || true; done
  stash delete "visits-$STAGE-slots.capacity" --force || true
  stash delete "visits-$STAGE-reminders.retention" --force || true
  say "cleared"
}

case "${1:-}" in
  traffic | banners | flap | links | prs | alarms | metadata | results | deploys | all | clear) cmd="cmd_$1"; shift; "$cmd" "$@" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
