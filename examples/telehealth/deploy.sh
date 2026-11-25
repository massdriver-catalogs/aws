#!/usr/bin/env bash
# Stands up Tendwell Health in a Massdriver organization.
#
#   ./deploy.sh role                    make the IAM role Massdriver deploys with, in the current AWS account
#   ./deploy.sh costs                   send the AWS account's costs to Massdriver, per instance
#   ./deploy.sh setup                   custom attributes, organization settings, bundle repositories and grants
#   ./deploy.sh publish                 publish the catalog, then the example apps
#   ./deploy.sh bootstrap               apply bootstrap.tf and set each environment's AWS credential
#   ./deploy.sh provision <stage>       deploy the platform, then every app, into dev or prod
#   ./deploy.sh ship <app> <stage>      build an app's image, push it and deploy it
#   ./deploy.sh all <stage>             role, costs, setup, publish, bootstrap, provision and ship every app
#   ./deploy.sh teardown                decommission everything, then undo bootstrap, costs and role
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
#   YES=1             skip the confirmation before anything changes in AWS
#   REDEPLOY=1        provision redeploys instances that are already up, from the preset;
#                     apps go back to the placeholder until shipped again

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
APPS=(visits care billing)

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

CONFIRMED=${YES:-}

# Everything here creates real, billed AWS infrastructure with administrator
# access, so nothing runs until a person has read what it will do.
confirm() {
  [ -n "$CONFIRMED" ] && return
  printf '\n%s\n\n' "$1" >&2
  [ -r /dev/tty ] || die "no terminal to confirm on; rerun with YES=1 once you've read the above"
  local answer
  read -r -p "Type yes to continue: " answer </dev/tty
  [ "$answer" = yes ] || die "stopped; nothing was changed"
  CONFIRMED=1
}

aws_target() {
  local account identity
  account=$(aws sts get-caller-identity --query Account --output text) || die "no AWS credentials; sign in with the AWS CLI first"
  identity=$(aws sts get-caller-identity --query Arn --output text)
  echo "AWS account $account, as $identity"
}

role_plan() {
  cat <<PLAN
In $(aws_target):
  - An IAM OIDC identity provider for ${ISSUER:-api.massdriver.cloud}, or your organization added to the existing one.
  - An IAM role, massdriver-<org>, with AdministratorAccess. Any deployment in your Massdriver
    organization can assume it, and bundles use it to create and delete anything in the account.
PLAN
}

costs_plan() {
  cat <<PLAN
In $(aws_target):
  - A daily Cost and Usage Report, written to a new S3 bucket in us-east-1.
  - An IAM user, massdriver-costs-<org>, that can only read that bucket and resource tags, and its access key.
Then connects the AWS Cost and Usage Reports integration in your Massdriver organization with that key.
Massdriver shows costs on every instance once AWS writes the first report, within 24 hours.
PLAN
}

stage_plan() {
  local stage=$1 cost='roughly $80/month while it runs (Development presets)'
  [ "$stage" = prod ] && cost="several hundred dollars a month or more (Production presets: Multi-AZ databases, a NAT gateway per zone)"
  cat <<PLAN
Deploys the $stage stage into $(aws_target), region us-east-1:
  - A VPC with a NAT for internet egress, and flow logs.
  - A Route 53 hosted zone for $stage.${DOMAIN:-<DOMAIN>}, with a certificate${PARENT_ZONE_ID:+, delegated by an NS record added to zone $PARENT_ZONE_ID}.
  - An ECS cluster and a public load balancer.
  - RDS PostgreSQL and RDS MariaDB, a serverless Valkey cache, a DynamoDB table, an SQS queue,
    and two S3 buckets.
  - An ECR repository per app in the apps project, the first time any stage deploys.
  - Two Lambda functions behind API Gateway, and two Fargate services.
  - IAM roles and security groups for all of it.
Cost: $cost.
Remove it with: ./deploy.sh teardown
PLAN
}

stage_arg() {
  case "${1:-}" in
    dev | prod) echo "$1" ;;
    *) die "stage must be dev or prod" ;;
  esac
}

# Params come from the bundle's own presets, so this script never drifts from
# what the catalog recommends: Development for dev, Production for prod.
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
  provisioned "$instance" && return
  log "deploy $instance"
  local before
  before=$(latest_deployment "$instance")
  preset "$bundle" "$stage" | jq "$filter" | mass instance deploy "$instance" --params - -m "deploy.sh provision $stage" --follow || true
  wait_for "$instance" "$before"
}

# Reruns pick up where a failed run stopped instead of redeploying everything.
provisioned() {
  [ -z "${REDEPLOY:-}" ] && [ "$(mass instance get "$1" -o json 2>/dev/null | jq -r .status)" = PROVISIONED ] &&
    log "skip $1, already provisioned (REDEPLOY=1 redeploys it)"
}

# The log stream can end, or the API can blip, while a deployment is still
# running. Later steps read this instance's outputs, so wait for the result.
latest_deployment() {
  mass deployment list "$1" -o json 2>/dev/null | jq -r '.[0].id // empty' || true
}

# wait_for <instance> <deployment id from before the deploy>
wait_for() {
  local latest status
  for _ in $(seq 1 240); do
    latest=$(mass deployment list "$1" -o json 2>/dev/null | jq -c '.[0] // empty') || { sleep 15; continue; }
    if [ -z "$latest" ] || [ "$(jq -r .id <<<"$latest")" = "${2:-}" ]; then
      die "$1: the deploy didn't start; see the error above"
    fi
    status=$(jq -r .status <<<"$latest")
    case "$status" in
      COMPLETED) return ;;
      PROPOSED) die "$1: the deployment waits for a second person's approval; approve it in Massdriver, then rerun" ;;
      FAILED | ABORTED | REJECTED) die "$1: deployment $status; see mass deployment logs" ;;
      *) sleep 15 ;;
    esac
  done
  die "$1: still $status after an hour; see mass deployment logs"
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
  mass bundle publish --bundle-directory "$1"
}

# bootstrap.tf names the organization in the onboarding credential.
organization_var() {
  TF_VAR_organization_id=$(mass whoami -o json | jq -r .organization.id)
  export TF_VAR_organization_id
}

require_roles() {
  [ -f "$HERE/terraform.tfvars.json" ] || [ -f "$HERE/terraform.tfvars" ] || [ -n "${TF_VAR_aws_accounts:-}" ] ||
    die "no AWS roles; run ./deploy.sh role, or copy terraform.tfvars.example to terraform.tfvars"
}

# Attributes, bundle repositories and who may use each bundle come before
# anything is published or placed on a canvas.
cmd_setup() {
  require_roles
  organization_var
  log "define custom attributes, organization settings, bundle repositories and their grants"
  mass repository list -t bundle -o json | jq '{existing_bundle_repositories: [(. // [])[].name]}' \
    >"$HERE/existing.auto.tfvars.json"
  (cd "$HERE" && tofu init -input=false >/dev/null &&
    # Adopt attributes an earlier run, or a person, already defined; a missing one just fails to import.
    for key in team data_classification; do
      tofu state list "massdriver_custom_attribute.$key" 2>/dev/null | grep -q . ||
        tofu import -input=false "massdriver_custom_attribute.$key" "$key" >/dev/null 2>&1 || true
    done &&
    tofu apply -input=false -auto-approve \
      -target=massdriver_organization_settings.this -target=massdriver_oci_repository_grant.bundle)
}

# Types before the bundles that use them, and runtimes before the apps built on them.
cmd_publish() {
  local dir app
  log "publish Massdriver resource types"
  "$CATALOG/scripts/publish-massdriver-types.sh"
  for dir in "$CATALOG"/platforms/*/ "$CATALOG"/resource-types/*/; do publish_type "${dir%/}"; done
  for app in "${APPS[@]}"; do publish_type "$HERE/applications/$app/resource-type"; done
  for dir in "$CATALOG"/bundles/*/; do publish_bundle "${dir%/}"; done
  for app in "${APPS[@]}"; do publish_bundle "$HERE/applications/$app/bundle"; done
}

# Trusts the organization's deployment identity tokens, the same setup as the
# aws-iam-role credential's AWS CLI instructions. Safe to rerun.
cmd_role() {
  local issuer=${ISSUER:-api.massdriver.cloud} org account provider trust arn
  confirm "$(role_plan)"
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

# Reads the same profile mass does, so every step talks to the same organization.
profile_value() {
  python3 - "$1" <<'PY'
import os, sys, yaml
home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
config = yaml.safe_load(open(os.path.join(home, "massdriver", "config.yaml")))
name = os.environ.get("MASSDRIVER_PROFILE") or config.get("current_profile") or "default"
print(config["profiles"][name].get(sys.argv[1], ""))
PY
}

graphql() {
  local key=${MASSDRIVER_API_KEY:-$(profile_value api_key)} org auth
  org=${MASSDRIVER_ORG_ID:-${MASSDRIVER_ORGANIZATION_ID:-$(profile_value organization_id)}}
  case "$key" in
    md_*) auth="Bearer $key" ;;
    *) auth="Basic $(printf '%s:%s' "$org" "$key" | base64 | tr -d '\n')" ;;
  esac
  local url=${MASSDRIVER_URL:-$(profile_value url)}
  curl -sS -X POST "${url:-https://api.massdriver.cloud}/api/v2" \
    -H "Authorization: $auth" -H 'content-type: application/json' -d "$1"
}

# The Terraform provider can't manage integrations, so the key goes over the API.
# An organization has one integration per type; a rerun leaves a connected one alone.
cmd_costs() {
  local org status values
  confirm "$(costs_plan)"
  org=$(mass whoami -o json | jq -r .organization.id)

  log "cost and usage report and read-only user"
  (cd "$HERE/costs" && tofu init -input=false >/dev/null && tofu apply -input=false -auto-approve -var "organization=$org")

  status=$(graphql "$(jq -n --arg org "$org" '{
    query: "query($org: ID!) { integration(organizationId: $org, id: \"aws-cost-and-usage-reports\") { status } }",
    variables: {org: $org}
  }')" | jq -r '.data.integration.status // empty')
  if [ -n "$status" ]; then
    log "AWS Cost and Usage Reports integration is already $status"
    [ "$status" != DISABLED ] ||
      echo "warning: an organization admin can turn it back on under Integrations > AWS Cost and Usage Reports" >&2
    return
  fi

  log "connect the AWS Cost and Usage Reports integration"
  values=$(cd "$HERE/costs" && tofu output -json massdriver_integration_config)
  graphql "$(jq -n --arg org "$org" --argjson v "$values" '{
    query: "mutation($org: ID!, $input: CreateIntegrationInput!) { createIntegration(organizationId: $org, id: \"aws-cost-and-usage-reports\", input: $input) { successful messages { message } } }",
    variables: {org: $org, input: {
      config: ({bucket_name: $v.bucket_name, region: $v.bucket_region} | tojson),
      auth: ({access_key_id: $v.access_key_id, secret_access_key: $v.secret_access_key} | tojson)
    }}
  }')" | jq -e -r 'if .data.createIntegration.successful then "connected"
    else error([(.data.createIntegration.messages // [])[].message, (.errors // [])[].message] | join("; ")) end' >&2 ||
    # Costs are optional, and connecting them needs an organization admin.
    cat >&2 <<EOF
warning: couldn't connect the integration; everything else carries on.
  An organization admin can connect it under Integrations > AWS Cost and Usage Reports,
  with the values from: (cd $HERE/costs && tofu output -json massdriver_integration_config)
EOF
}

cmd_bootstrap() {
  require_roles
  organization_var

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
    exit 1
  ) &
  DELEGATING=$!
}

# onboard <app> <stage>: the app's registry and codebase live in the apps
# project, one per app, so dev and prod run the same images. The app's
# environments get the codebase as a default. Its GitHub repository and Massdriver
# project stay undeployed, but connected to the onboarding credential.
onboard() {
  local app=$1 stage=$2
  deploy "apps-$app-registry" ecr-repository dev
  deploy "apps-$app-codebase" codebase dev '.share_with_project = false'
  share "apps-$app-codebase.codebase" --condition "md-project=$app"
  mass environment default "$app-$stage" "apps-$app-codebase.codebase" >/dev/null
  local credential
  credential=$(cd "$HERE" && tofu output -raw onboarding_credential)
  connect "apps-$app-project" massdriver "$credential"
  connect "apps-$app-repo" massdriver "$credential"
}

cmd_provision() {
  local stage
  stage=$(stage_arg "${1:-}")
  [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=tendwell.example"
  local zone="$stage.$DOMAIN"
  confirm "$(stage_plan "$stage")"

  log "platform-$stage"
  deploy "platform-$stage-network" vpc "$stage"
  delegate "$zone"
  deploy "platform-$stage-dns" dns-zone "$stage" ".domain = \"$zone\""
  [ -z "${DELEGATING:-}" ] || wait "$DELEGATING" || die "couldn't delegate $zone from $PARENT_ZONE_ID; see the error above"
  deploy "platform-$stage-cluster" ecs-cluster "$stage"
  # An account has one GitHub OIDC provider. Dev creates it in the nonprod
  # account unless one is already there, and prod creates its own unless
  # everything runs in one account.
  if ! provisioned "platform-$stage-oidc"; then
    log "deploy platform-$stage-oidc"
    before=$(latest_deployment "platform-$stage-oidc")
    case "$stage" in
      dev) aws iam list-open-id-connect-providers --output json |
        jq '{adopt_existing_provider: any(.OpenIDConnectProviderList[]; .Arn | endswith("/token.actions.githubusercontent.com"))}' ;;
      prod) (cd "$HERE" && tofu output -json one_account) | jq '{adopt_existing_provider: .}' ;;
    esac | mass instance deploy "platform-$stage-oidc" --params - -m "deploy.sh provision $stage" --follow || true
    wait_for "platform-$stage-oidc" "$before"
  fi

  for field in network.network dns.zone cluster.cluster; do
    share "platform-$stage-$field" --condition "md-environment=$stage"
  done
  for app in "${APPS[@]}"; do
    for field in network.network dns.zone cluster.cluster; do
      mass environment default "$app-$stage" "platform-$stage-$field" >/dev/null
    done
  done

  for app in "${APPS[@]}"; do onboard "$app" "$stage"; done

  log "visits-$stage"
  deploy "visits-$stage-api" http-api "$stage" '.subdomain = "visits"'
  deploy "visits-$stage-slots" dynamodb-table "$stage"
  deploy "visits-$stage-reminders" sqs-queue "$stage"
  deploy "visits-$stage-app" lambda-function "$stage" \
    '.routes = ["GET /health", "GET /slots", "GET /appointments", "GET /appointments/{id}", "POST /appointments"]'
  deploy "visits-$stage-notifier" lambda-function "$stage" \
    '.routes = ["GET /reminders"] | .consume_queue = true'
  share "visits-$stage-app.visits" --condition md-project=care

  log "care-$stage"
  deploy "care-$stage-charts" postgres "$stage" '.database_name = "care"'
  deploy "care-$stage-sessions" valkey "$stage"
  deploy "care-$stage-documents" s3-bucket "$stage"
  connect "care-$stage-app" visits "visits-$stage-app.visits"
  deploy "care-$stage-app" ecs-service "$stage" '.subdomain = "care" | .health_check_path = "/health"'
  share "care-$stage-app.care" --condition md-project=billing

  log "billing-$stage"
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

  local registry url region tag image before
  registry=$(mass resource get "apps-$app-registry.repository" -o json)
  url=$(jq -r '.payload.url' <<<"$registry")
  region=$(jq -r '.payload.region' <<<"$registry")
  tag="$(git -C "$HERE" rev-parse --short HEAD)-$(date +%s)"
  image="$url:$tag"

  log "build and push $image"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}"
  # The base images are public. Docker sends any saved public.ecr.aws login with
  # the pull, and a stale one, or one from an account that can't pull, gets a 403.
  docker logout public.ecr.aws >/dev/null 2>&1 || true
  docker build --platform linux/arm64 --provenance=false -t "$image" "$HERE/applications/$app/src"
  docker push "$image"

  local instances=("$app-$stage-app")
  [ "$app" = visits ] && instances+=("$app-$stage-notifier")
  for instance in "${instances[@]}"; do
    log "deploy $instance"
    before=$(latest_deployment "$instance")
    mass instance deploy "$instance" --patch ".image_uri = \"$image\"" -m "Ship $tag" --follow || true
    wait_for "$instance" "$before"
  done
}

teardown_plan() {
  cat <<PLAN
Deletes Tendwell Health from your Massdriver organization and $(aws_target):
  - Empties the S3 buckets, then decommissions every instance in billing, care, visits and
    platform, dev and prod, then each app's registry and codebase in apps, then every developer
    sandbox. Their data is gone for good: databases take no final snapshot.
  - Destroys what bootstrap.tf made: projects, environments, groups, policies, credentials,
    the onboarding service account, bundle grants, attributes and organization settings.
  - Disconnects the AWS Cost and Usage Reports integration and deletes the report, its bucket
    and its IAM user.
  - Deletes the massdriver-<org> role, and removes the organization from the Massdriver OIDC
    provider, deleting the provider when no other organization uses it.
Published bundles and resource types stay, so ./deploy.sh all can stand it back up.
PLAN
}

empty_bucket() {
  local versions
  log "empty s3://$1"
  aws s3 rm "s3://$1" --recursive --only-show-errors
  while :; do
    versions=$(aws s3api list-object-versions --bucket "$1" --max-items 1000 --output json \
      --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}')
    [ "$(jq '.Objects | length' <<<"$versions")" -gt 0 ] || return 0
    aws s3api delete-objects --bucket "$1" --delete "$versions" >/dev/null
  done
}

# decommission <environment>: waits until nothing in it is deployed.
decommission() {
  local env=$1 instances live bucket
  instances=$(mass instance list "$env" -o json 2>/dev/null | jq '. // []' || echo '[]')
  live=$(jq -r '[.[] | select(.status == "PROVISIONED" or .status == "FAILED")] | length' <<<"$instances")
  [ "$live" -gt 0 ] || { log "skip $env, nothing deployed"; return; }

  # S3 won't delete a bucket that still holds files.
  for id in $(jq -r '.[] | select(.status != "INITIALIZED" and .status != "DECOMMISSIONED") | .id' <<<"$instances"); do
    bucket=$(mass resource get "$id.bucket" -o json 2>/dev/null | jq -r '.payload.name // empty' || true)
    [ -z "$bucket" ] || empty_bucket "$bucket"
  done

  log "decommission $env"
  mass environment decommission "$env" >/dev/null
  local idle=0 busy latest id
  for _ in $(seq 1 240); do
    sleep 15
    instances=$(mass instance list "$env" -o json 2>/dev/null) || continue
    jq -e 'all(.[]; .status == "INITIALIZED" or .status == "DECOMMISSIONED")' <<<"$instances" >/dev/null && return
    busy=0
    for id in $(jq -r '.[] | select(.status == "PROVISIONED" or .status == "FAILED") | .id' <<<"$instances"); do
      latest=$(mass deployment list "$id" -o json 2>/dev/null | jq -r '.[0] | "\(.action) \(.status)"' || true)
      [ "$latest" != "DECOMMISSION FAILED" ] ||
        die "$id failed to decommission; see mass deployment logs, fix it, and rerun ./deploy.sh teardown"
      case "$latest" in *COMPLETED | *FAILED | *ABORTED | *REJECTED) ;; *) busy=1 ;; esac
    done
    # Massdriver sometimes stops partway down a chain of links, leaving the
    # rest deployed and nothing running. Once it's been quiet a minute, destroy
    # what's left; anything still in use refuses and is tried again.
    [ "$busy" = 1 ] && idle=0 || idle=$((idle + 1))
    [ "$idle" -ge 4 ] || continue
    for id in $(jq -r '.[] | select(.status == "PROVISIONED") | .id' <<<"$instances"); do
      mass instance destroy "$id" --force -m "deploy.sh teardown" >/dev/null 2>&1 || true
    done
    idle=0
  done
  die "$env: still decommissioning after an hour"
}

# Massdriver won't decommission a resource another environment uses by default.
# release <org> <resource prefix> <environment>...: unsets those defaults.
release() {
  local org=$1 prefix=$2 env id
  shift 2
  for env in "$@"; do
    for id in $(mass environment get "$env" -o json 2>/dev/null |
      jq -r --arg p "$prefix" '.defaults[]? | select(.resource.id | startswith($p)) | .id'); do
      graphql "$(jq -n --arg org "$org" --arg id "$id" '{
        query: "mutation($org: ID!, $id: UUID!) { removeEnvironmentDefault(organizationId: $org, id: $id) { successful } }",
        variables: {org: $org, id: $id}
      }')" | jq -e '.data.removeEnvironmentDefault.successful' >/dev/null || die "couldn't unset $env's $prefix defaults"
    done
  done
}

cmd_teardown() {
  local org account provider stage project status
  confirm "$(teardown_plan)"
  org=$(mass whoami -o json | jq -r .organization.id)
  account=$(aws sts get-caller-identity --query Account --output text)

  # Apps first: the platform's zone and cluster hold their records and rules.
  for stage in dev prod; do
    for project in billing care visits; do decommission "$project-$stage"; done
    release "$org" "platform-$stage-" "${APPS[@]/%/-$stage}"
    decommission "platform-$stage"
  done
  for app in "${APPS[@]}"; do
    release "$org" "apps-$app-" "$app-dev" "$app-prod"
    # Drop the connections to the onboarding credential before bootstrap.tf deletes it.
    for component in project repo; do
      mass instance remote-reference remove "apps-$app-$component" massdriver >/dev/null 2>&1 || true
    done
    decommission "apps-$app"
  done

  export TF_VAR_organization_id=$org
  # sandbox-on-join forks these from the template, outside bootstrap.tf.
  for env in $(mass environment list sandboxes -o json 2>/dev/null | jq -r '(. // [])[] | select(.id != "sandboxes-template") | .id'); do
    decommission "$env"
    mass environment delete "$env" --force >/dev/null
  done

  log "destroy bootstrap.tf"
  # Destroying the settings leaves the org's default tags in place, and an
  # attribute that's still a default tag can't be deleted.
  (cd "$HERE" && tofu init -input=false >/dev/null &&
    trap 'rm -f teardown_override.tf' EXIT &&
    printf 'resource "massdriver_organization_settings" "this" {\n  default_tags = []\n}\n' >teardown_override.tf &&
    tofu apply -input=false -auto-approve -target=massdriver_organization_settings.this &&
    rm teardown_override.tf &&
    tofu destroy -input=false -auto-approve)

  status=$(graphql "$(jq -n --arg org "$org" '{
    query: "query($org: ID!) { integration(organizationId: $org, id: \"aws-cost-and-usage-reports\") { status } }",
    variables: {org: $org}
  }')" | jq -r '.data.integration.status // empty')
  if [ -n "$status" ]; then
    log "disconnect the AWS Cost and Usage Reports integration"
    graphql "$(jq -n --arg org "$org" '{
      query: "mutation($org: ID!) { deleteIntegration(organizationId: $org, id: \"aws-cost-and-usage-reports\") { successful } }",
      variables: {org: $org}
    }')" | jq -e '.data.deleteIntegration.successful' >/dev/null || die "couldn't disconnect the integration"
  fi
  log "delete the cost and usage report"
  (cd "$HERE/costs" && tofu init -input=false >/dev/null &&
    bucket=$(tofu output -json massdriver_integration_config 2>/dev/null | jq -r '.bucket_name // empty') &&
    { [ -z "$bucket" ] || ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null || empty_bucket "$bucket"; } &&
    tofu destroy -input=false -auto-approve -var "organization=$org")

  log "delete role massdriver-$org"
  if aws iam get-role --role-name "massdriver-$org" >/dev/null 2>&1; then
    for arn in $(aws iam list-attached-role-policies --role-name "massdriver-$org" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "massdriver-$org" --policy-arn "$arn"
    done
    aws iam delete-role --role-name "massdriver-$org"
  fi
  provider="arn:aws:iam::$account:oidc-provider/${ISSUER:-api.massdriver.cloud}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" >/dev/null 2>&1; then
    aws iam remove-client-id-from-open-id-connect-provider --open-id-connect-provider-arn "$provider" --client-id "massdriver:$org"
    [ "$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" --query 'length(ClientIDList)')" != 0 ] ||
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$provider"
  fi
  rm -f "$HERE/terraform.tfvars.json"
  log "done"
}

case "${1:-}" in
  role) cmd_role ;;
  costs) cmd_costs ;;
  setup) cmd_setup ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  provision) cmd_provision "${2:-}" ;;
  ship) cmd_ship "${2:-}" "${3:-}" ;;
  teardown) cmd_teardown ;;
  all)
    stage=$(stage_arg "${2:-}")
    [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=tendwell.example"
    confirm "$(role_plan)

$(costs_plan)

In your Massdriver organization: defines the team and data_classification attributes and sets
them as default tags, turns off granting new bundles to every project, creates a
repository and access grant for every bundle, publishes the catalog and the Tendwell apps, then
creates the platform, apps, visits, care and billing projects, their environments, five groups
with their policies, and the AWS credentials.

$(stage_plan "$stage")

Then builds the three app images with Docker, pushes them to ECR and deploys them."
    cmd_role
    cmd_costs
    cmd_setup
    cmd_publish
    cmd_bootstrap
    cmd_provision "$stage"
    for app in "${APPS[@]}"; do cmd_ship "$app" "$stage"; done
    ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
