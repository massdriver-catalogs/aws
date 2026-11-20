#!/usr/bin/env bash
# Stands up Tendwell Health in a Massdriver organization without GitHub Actions.
#
#   ./deploy.sh role                    make the IAM role Massdriver deploys with, in the current AWS account
#   ./deploy.sh publish                 publish the catalog, then the example apps
#   ./deploy.sh bootstrap               apply bootstrap.tf and set each environment's AWS credential
#   ./deploy.sh provision <stage>       deploy the platform, then every app, into dev, staging or prod
#   ./deploy.sh ship <app> <stage>      build an app's image, push it and deploy it
#   ./deploy.sh all <stage>             role, publish, bootstrap, provision and ship every app
#
# Needs: mass (signed in, or MASSDRIVER_API_KEY and MASSDRIVER_ORG_ID set), tofu, jq, python3 with
# PyYAML, docker, and AWS CLI credentials for the account the apps deploy into.
#
# Settings, from the environment:
#   DOMAIN            parent domain; each stage gets <stage>.<DOMAIN>    (provision)
#   PARENT_ZONE_ID    Route 53 zone for DOMAIN in the same account. When set, each stage's
#                     zone is delegated from it automatically; otherwise delegate by hand.
#   PROD_ROLE_ARN     a role in a separate prod account; prod uses the role from `role` otherwise
#   ISSUER            Massdriver's token issuer host; api.massdriver.cloud unless self-hosted

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
APPS=(visits care billing)

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

stage_arg() {
  case "${1:-}" in
    dev | staging | prod) echo "$1" ;;
    *) die "stage must be dev, staging or prod" ;;
  esac
}

# Params come from the bundle's own presets, so this script never drifts from
# what the catalog recommends: Development for dev and staging, Production for prod.
preset() {
  local bundle=$1 stage=$2 name=Development
  [ "$stage" = prod ] && name=Production
  python3 - "$CATALOG/bundles/$bundle/massdriver.yaml" "$name" <<'PY'
import json, sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
for example in spec["params"]["examples"]:
    if example.get("__name") == sys.argv[2]:
        example.pop("__name")
        print(json.dumps(example))
        break
else:
    sys.exit(f"no preset {sys.argv[2]} in {sys.argv[1]}")
PY
}

# deploy <instance> <bundle> <stage> [jq filter applied to the preset]
deploy() {
  local instance=$1 bundle=$2 stage=$3 filter=${4:-.}
  log "deploy $instance"
  preset "$bundle" "$stage" | jq "$filter" | mass instance deploy "$instance" --params - -m "deploy.sh provision $stage" --follow
}

# Grants are immutable and creating one twice fails, so reruns skip existing ones.
share() {
  mass resource grant create "$@" >/dev/null 2>&1 || true
}

# Apps in different projects connect through remote references. Massdriver
# only takes one while the instance isn't deployed, so reruns keep the first.
connect() {
  local instance=$1 field=$2 resource=$3
  log "connect $instance.$field to $resource"
  mass instance remote-reference set "$instance" "$field" "$resource" ||
    echo "kept $instance's existing $field connection" >&2
}

publish_type() {
  local name
  name=$(awk '/^name:/ { print $2; exit }' "$1/massdriver.yaml")
  log "publish resource type $name"
  mass repository create "$name" -t resource-type >/dev/null 2>&1 || true
  mass resource-type publish "$1"
}

publish_bundle() {
  local name
  name=$(awk '/^name:/ { print $2; exit }' "$1/massdriver.yaml")
  log "publish bundle $name"
  mass repository create "$name" -t bundle >/dev/null 2>&1 || true
  mass bundle publish --bundle-directory "$1"
}

# Types before the bundles that use them, and runtimes before the apps built on them.
cmd_publish() {
  local dir app
  for dir in "$CATALOG"/platforms/*/ "$CATALOG"/resource-types/*/; do publish_type "${dir%/}"; done
  for app in "${APPS[@]}"; do publish_type "$HERE/applications/$app/resource-type"; done
  for dir in "$CATALOG"/bundles/*/; do publish_bundle "${dir%/}"; done
  for app in "${APPS[@]}"; do publish_bundle "$HERE/applications/$app/bundle"; done
}

# Trusts the organization's deployment identity tokens, the same setup as the
# aws-iam-role credential's AWS CLI instructions. Safe to rerun.
cmd_role() {
  local issuer=${ISSUER:-api.massdriver.cloud} org account provider trust arn
  org=$(mass whoami -o json | jq -r .organization.id)
  account=$(aws sts get-caller-identity --query Account --output text)
  provider="arn:aws:iam::$account:oidc-provider/$issuer"

  log "trust $issuer tokens for $org in account $account"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" >/dev/null 2>&1; then
    aws iam add-client-id-to-open-id-connect-provider --open-id-connect-provider-arn "$provider" --client-id "massdriver:$org"
  else
    aws iam create-open-id-connect-provider --url "https://$issuer" --client-id-list "massdriver:$org" >/dev/null
  fi

  trust=$(jq -n --arg p "$provider" --arg i "$issuer" --arg o "$org" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Federated: $p},
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {StringEquals: {"\($i):aud": "massdriver:\($o)", "\($i):sub": "org:\($o)"}}
    }]
  }')

  log "role massdriver-$org"
  if aws iam get-role --role-name "massdriver-$org" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "massdriver-$org" --policy-document "$trust"
  else
    aws iam create-role --role-name "massdriver-$org" --description "Massdriver provisioning for $org" \
      --assume-role-policy-document "$trust" >/dev/null
  fi
  aws iam attach-role-policy --role-name "massdriver-$org" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  arn=$(aws iam get-role --role-name "massdriver-$org" --query Role.Arn --output text)

  jq -n --arg nonprod "$arn" --arg prod "${PROD_ROLE_ARN:-$arn}" \
    '{aws_accounts: {nonprod: {arn: $nonprod}, prod: {arn: $prod}}}' >"$HERE/terraform.tfvars.json"
  echo "$arn" >&2
}

cmd_bootstrap() {
  [ -f "$HERE/terraform.tfvars.json" ] || [ -f "$HERE/terraform.tfvars" ] || [ -n "${TF_VAR_aws_accounts:-}" ] ||
    die "no AWS roles; run ./deploy.sh role, or copy terraform.tfvars.example to terraform.tfvars"

  log "apply bootstrap.tf"
  (cd "$HERE" && tofu init -input=false >/dev/null && tofu apply -input=false -auto-approve)

  log "set each environment's AWS credential"
  (cd "$HERE" && tofu output -json environments) |
    jq -r 'to_entries[] | "\(.key) \(.value.credential)"' |
    while read -r env credential; do
      mass environment default "$env" "$credential"
    done
}

# Route 53 creates the zone early in the deploy, and its certificate waits on
# delegation; delegating as soon as the zone appears lets the deploy finish.
delegate() {
  local domain=$1
  [ -n "${PARENT_ZONE_ID:-}" ] || {
    log "delegate $domain from its parent zone now; see the dns-zone operator guide"
    return
  }
  (
    for _ in $(seq 1 60); do
      zone=$(aws route53 list-hosted-zones-by-name --dns-name "$domain." --max-items 1 \
        --query "HostedZones[?Name=='$domain.'].Id | [0]" --output text 2>/dev/null || true)
      if [ -n "$zone" ] && [ "$zone" != None ]; then
        ns=$(aws route53 get-hosted-zone --id "$zone" --query 'DelegationSet.NameServers' --output json)
        aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" --change-batch "$(jq -n \
          --arg name "$domain." --argjson ns "$ns" \
          '{Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: "NS", TTL: 300, ResourceRecords: [$ns[] | {Value: .}]}}]}')" >/dev/null
        echo "delegated $domain" >&2
        exit 0
      fi
      sleep 10
    done
    echo "gave up waiting for the $domain zone to delegate it" >&2
  ) &
}

cmd_provision() {
  local stage
  stage=$(stage_arg "${1:-}")
  [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=tendwell.health"
  local zone="$stage.$DOMAIN"

  log "platform-$stage"
  deploy "platform-$stage-network" vpc "$stage"
  delegate "$zone"
  deploy "platform-$stage-dns" dns-zone "$stage" ".domain = \"$zone\""
  wait
  deploy "platform-$stage-cluster" ecs-cluster "$stage"
  # An account has one GitHub OIDC provider. Dev creates it in the nonprod
  # account, staging shares that account, and prod creates its own unless
  # everything runs in one account.
  case "$stage" in
    dev) echo '{"adopt_existing_provider": false}' ;;
    prod) (cd "$HERE" && tofu output -json one_account) | jq '{adopt_existing_provider: .}' ;;
  esac | if [ "$stage" != staging ]; then
    log "deploy platform-$stage-oidc"
    mass instance deploy "platform-$stage-oidc" --params - -m "deploy.sh provision $stage" --follow
  fi

  for field in network.network dns.zone cluster.cluster; do
    share "platform-$stage-$field" --condition "md-environment=$stage"
  done
  for app in "${APPS[@]}"; do
    for field in network.network dns.zone cluster.cluster; do
      mass environment default "$app-$stage" "platform-$stage-$field" >/dev/null
    done
  done

  log "visits-$stage"
  deploy "visits-$stage-registry" ecr-repository "$stage"
  deploy "visits-$stage-api" http-api "$stage" '.subdomain = "visits"'
  deploy "visits-$stage-slots" dynamodb-table "$stage"
  deploy "visits-$stage-reminders" sqs-queue "$stage"
  deploy "visits-$stage-app" lambda-function "$stage" \
    '.routes = ["GET /health", "GET /slots", "GET /appointments", "GET /appointments/{id}", "POST /appointments"] | .queue_access = "send"'
  deploy "visits-$stage-notifier" lambda-function "$stage" \
    '.routes = ["GET /reminders"] | .queue_access = "consume" | .consume_queue = true'
  share "visits-$stage-app.visits" --condition md-project=care

  log "care-$stage"
  deploy "care-$stage-registry" ecr-repository "$stage"
  deploy "care-$stage-charts" postgres "$stage" '.database_name = "care"'
  deploy "care-$stage-sessions" valkey "$stage"
  deploy "care-$stage-documents" s3-bucket "$stage"
  connect "care-$stage-app" visits "visits-$stage-app.visits"
  deploy "care-$stage-app" ecs-service "$stage" '.subdomain = "care" | .health_check_path = "/health"'
  share "care-$stage-app.care" --condition md-project=billing

  log "billing-$stage"
  deploy "billing-$stage-registry" ecr-repository "$stage"
  deploy "billing-$stage-ledger" mariadb "$stage" '.database_name = "billing"'
  deploy "billing-$stage-claims" s3-bucket "$stage"
  connect "billing-$stage-app" care "care-$stage-app.care"
  deploy "billing-$stage-app" ecs-service "$stage" '.subdomain = "billing" | .health_check_path = "/health"'

  log "done. Ship real images with: ./deploy.sh ship <app> $stage"
}

cmd_ship() {
  local app=${1:-} stage
  [[ " ${APPS[*]} " == *" $app "* ]] || die "app must be one of: ${APPS[*]}"
  stage=$(stage_arg "${2:-}")

  local registry url region tag image
  registry=$(mass resource get "$app-$stage-registry.repository" -o json)
  url=$(jq -r '(.payload // .data).url' <<<"$registry")
  region=$(jq -r '(.payload // .data).region' <<<"$registry")
  tag="$(git -C "$HERE" rev-parse --short HEAD)-$(date +%s)"
  image="$url:$tag"

  log "build and push $image"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}"
  docker build --platform linux/arm64 --provenance=false -t "$image" "$HERE/applications/$app/src"
  docker push "$image"

  local instances=("$app-$stage-app")
  [ "$app" = visits ] && instances+=("$app-$stage-notifier")
  for instance in "${instances[@]}"; do
    log "deploy $instance"
    mass instance deploy "$instance" --patch ".image_uri = \"$image\"" -m "Ship $tag" --follow
  done
}

case "${1:-}" in
  role) cmd_role ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  provision) cmd_provision "${2:-}" ;;
  ship) cmd_ship "${2:-}" "${3:-}" ;;
  all)
    stage=$(stage_arg "${2:-}")
    cmd_role
    cmd_publish
    cmd_bootstrap
    cmd_provision "$stage"
    for app in "${APPS[@]}"; do cmd_ship "$app" "$stage"; done
    ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
