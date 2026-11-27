#!/usr/bin/env bash
# Stands up the Rocketsled example: Fauxroku and Fauxcel in a Massdriver organization.
#
#   ./deploy.sh role              make the IAM role Massdriver deploys with, in the current AWS account
#   ./deploy.sh publish           publish the resource types and bundles both PaaSes use
#   ./deploy.sh bootstrap         apply bootstrap.tf and set each environment's AWS credential
#   ./deploy.sh provision         deploy Fauxroku's shared platform; pin both templates
#   ./deploy.sh fork <paas> <id>  fork a customer environment from a template and deploy it, the
#                                 way a Rocketsled server does, e.g. ./deploy.sh fork fauxcel demo
#   ./deploy.sh env               write .env for the Rocketsled servers (fauxroku.yaml, fauxcel.yaml)
#   ./deploy.sh all               role, publish, bootstrap, provision and env
#   ./deploy.sh teardown          remove every customer environment, then everything above
#
# Needs: mass (signed in, or MASSDRIVER_API_KEY and MASSDRIVER_ORG_ID set), tofu, jq, python3 with
# PyYAML, and AWS CLI credentials for the account the PaaSes deploy into.
#
# Settings, from the environment:
#   DOMAIN             the DNS zone Fauxroku apps live under, e.g. apps.example.com; an app's web
#                      dynos answer at fauxroku-<id>.<DOMAIN>                    (provision)
#   PARENT_ZONE_ID     Route 53 zone of DOMAIN's parent in the same account. When set, the zone
#                      is delegated from it automatically; otherwise delegate by hand.
#   ISSUER             Massdriver's token issuer host; api.massdriver.cloud unless self-hosted
#   YES=1              skip the confirmation before anything changes in AWS
#   REDEPLOY=1         redeploy instances that are already up
#
# Bundles are published as development releases, and every instance is pinned to the one just
# published.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
BUNDLES=(vpc dns-zone ecs-cluster ecs-service postgres valkey http-api lambda-function dynamodb-table s3-bucket)
APPS=(fauxroku-web fauxroku-worker fauxcel-app)
# The bundles above reference these, even where the connection is optional.
TYPES=(aws-vpc aws-dns-zone aws-ecs-cluster aws-codebase aws-postgres aws-valkey aws-http-api aws-dynamodb-table aws-s3-bucket website)

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

provision_plan() {
  cat <<PLAN
Deploys Fauxroku's shared platform into $(aws_target), region us-east-1, with each bundle's
Development preset:
  - A VPC with a NAT instance for internet egress, and flow logs.
  - A Route 53 hosted zone for ${DOMAIN:-<DOMAIN>}, with a wildcard certificate${PARENT_ZONE_ID:+, delegated by an NS record added to zone $PARENT_ZONE_ID}.
  - An ECS cluster and one public load balancer every Fauxroku app shares.
Cost: about \$25/month while it runs, most of it the load balancer. Fauxcel shares nothing and
deploys nothing here. Nothing is deployed in either template.
Remove it with: ./deploy.sh teardown
PLAN
}

fork_plan() {
  case "$1" in
    fauxroku) cat <<PLAN
Forks fauxroku-template into fauxroku-$2 and deploys it into $(aws_target), with the cheapest
presets:
  - Web dynos: one 0.25 vCPU, 0.5 GB Fargate Spot task at https://fauxroku-$2.<DOMAIN> (~\$2/month).
  - Worker dynos: one more, with no address (~\$2/month).
  - Postgres: db.t4g.micro, 20 GB, no standby (~\$15/month).
  - Key-Value Store: ElastiCache Serverless Valkey, 1 GB limit (~\$6/month at its minimum).
Cost: about \$25/month on top of the platform. Remove it with: ./deploy.sh teardown
PLAN
      ;;
    fauxcel) cat <<PLAN
Forks fauxcel-template into fauxcel-$2 and deploys it into $(aws_target), with the cheapest
presets: an API Gateway HTTP API, one 256 MB arm64 Lambda function, an on-demand DynamoDB table
and an S3 bucket.
Cost: nothing while idle; cents per million requests. Remove it with: ./deploy.sh teardown
PLAN
      ;;
  esac
}

bundle_dir() {
  case "$1" in
    fauxroku-* | fauxcel-*) echo "$HERE/applications/$1/bundle" ;;
    *) echo "$CATALOG/bundles/$1" ;;
  esac
}

dev_version() {
  local version
  version=$(awk -v b="$1" '$1 == b { print $2 }' "$HERE/.dev-versions" 2>/dev/null)
  [ -n "$version" ] || die "no development release of $1 recorded; run ./deploy.sh publish"
  echo "$version"
}

# Params come from the bundle's own presets, so this script never drifts from
# what the catalog recommends.
preset() {
  local bundle=$1 name=${2:-Development}
  python3 - "$(bundle_dir "$bundle")/massdriver.yaml" "$name" <<'PY'
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

# deploy <instance> <bundle> [jq filter applied to the preset]
deploy() {
  local instance=$1 bundle=$2 filter=${3:-.}
  pin "$instance"
  provisioned "$instance" && return
  log "deploy $instance"
  local before
  before=$(latest_deployment "$instance")
  preset "$bundle" | jq "$filter" | mass instance deploy "$instance" --params - -m "deploy.sh" --follow || true
  wait_for "$instance" "$before"
}

# Reruns pick up where a failed run stopped instead of redeploying everything.
provisioned() {
  [ -z "${REDEPLOY:-}" ] && [ "$(mass instance get "$1" -o json 2>/dev/null | jq -r .status)" = PROVISIONED ] &&
    log "skip $1, already provisioned (REDEPLOY=1 redeploys it)"
}

latest_deployment() {
  mass deployment list "$1" -o json 2>/dev/null | jq -r '.[0].id // empty' || true
}

# The log stream can end, or the API can blip, while a deployment is still
# running. Later steps read this instance's outputs, so wait for the result.
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
      PROPOSED) die "$1: the deployment waits for approval; approve it in Massdriver, then rerun" ;;
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
  local out version
  out=$(mass bundle publish --development --bundle-directory "$1")
  echo "$out" >&2
  version=$(grep -o "$name:[^ ]*-dev\.[0-9TZ]*" <<<"$out" | head -1 | cut -d: -f2)
  [ -n "$version" ] || die "couldn't read the development version of $name"
  # latest+dev resolves to the newest stable release, so instances are pinned to exactly this one.
  touch "$HERE/.dev-versions"
  { grep -v "^$name " "$HERE/.dev-versions" || true; echo "$name $version"; } >"$HERE/.dev-versions.new"
  mv "$HERE/.dev-versions.new" "$HERE/.dev-versions"
}

# pin <instance>: runs the instance on the development release publish recorded.
pin() {
  local bundle version
  bundle=$(mass instance get "$1" -o json | jq -r '.bundle.name // .bundle.id')
  version=$(awk -v b="$bundle" '$1 == b { print $2 }' "$HERE/.dev-versions" 2>/dev/null)
  [ -n "$version" ] || die "no development release of $bundle recorded; run ./deploy.sh publish"
  mass instance version "$1@$version" >/dev/null
}

require_role() {
  [ -f "$HERE/terraform.tfvars.json" ] || [ -f "$HERE/terraform.tfvars" ] || [ -n "${TF_VAR_aws_role:-}" ] ||
    die "no AWS role; run ./deploy.sh role, or copy terraform.tfvars.example to terraform.tfvars"
}

tf_output() {
  (cd "$HERE" && tofu output -raw "$1")
}

org_id() {
  mass whoami -o json | jq -r .organization.id
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
  printf '%s' "$1" | curl -sS -X POST "${url:-https://api.massdriver.cloud}/api/v2" \
    -H @<(printf 'Authorization: %s\n' "$auth") -H 'content-type: application/json' --data-binary @-
}

cmd_role() {
  local issuer=${ISSUER:-api.massdriver.cloud} org account provider trust arn
  confirm "$(role_plan)"
  org=$(org_id)
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

  jq -n --arg arn "$arn" '{aws_role: {arn: $arn}}' >"$HERE/terraform.tfvars.json"
  echo "$arn" >&2
}


# Types before the bundles that use them, and the runtimes before the apps built on them.
cmd_publish() {
  local type bundle
  publish_type "$CATALOG/platforms/aws-iam-role"
  for type in "${TYPES[@]}"; do publish_type "$CATALOG/resource-types/$type"; done
  for bundle in "${BUNDLES[@]}" "${APPS[@]}"; do publish_bundle "$(bundle_dir "$bundle")"; done
}

cmd_bootstrap() {
  require_role
  log "apply bootstrap.tf"
  # Some mass versions fail to list repositories ("Project not found"); a new organization has none to adopt.
  { mass repository list -t bundle -o json 2>/dev/null || echo '[]'; } |
    jq '{existing_bundle_repositories: [(. // [])[].name]}' >"$HERE/existing.auto.tfvars.json"
  (cd "$HERE" && tofu init -input=false >/dev/null && tofu apply -input=false -auto-approve)

  log "set each environment's AWS credential"
  local credential env
  credential=$(tf_output aws_credential)
  for env in $(cd "$HERE" && tofu output -json environments | jq -r 'keys[]'); do
    mass environment default "$env" "$credential" >/dev/null
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

cmd_provision() {
  [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=apps.example.com"
  confirm "$(provision_plan)"

  log "platform-main"
  deploy platform-main-network vpc
  delegate "$DOMAIN"
  deploy platform-main-dns dns-zone ".domain = \"$DOMAIN\""
  [ -z "${DELEGATING:-}" ] || wait "$DELEGATING" || die "couldn't delegate $DOMAIN from $PARENT_ZONE_ID; see the error above"
  deploy platform-main-cluster ecs-cluster

  # Forks copy the template's defaults, so every Fauxroku environment lands in
  # the platform's VPC and behind its load balancer, connecting nothing.
  local field part
  for field in network.network cluster.cluster; do
    share "platform-main-$field" --condition "md-project=fauxroku"
    mass environment default fauxroku-template "platform-main-$field" >/dev/null
  done

  # Forks take the template's versions, so customers run the release just published.
  for part in web worker db cache; do pin "fauxroku-template-$part"; done
  for part in api app kv blob; do pin "fauxcel-template-$part"; done
}

# fork_params <paas> <component> <id>: the bundle and the cheapest params a
# customer environment starts with. Web dynos get the environment's own
# subdomain, the one param a preset can't know (massdriver-cloud/rocketsled#11).
fork_params() {
  case "$1/$2" in
    fauxroku/web) echo fauxroku-web; preset ecs-service | jq -c --arg s "fauxroku-$3" '.subdomain = $s | .spot = true' ;;
    fauxroku/worker) echo fauxroku-worker; preset ecs-service | jq -c '.subdomain = "" | .spot = true' ;;
    fauxroku/db) echo postgres; preset postgres | jq -c . ;;
    fauxroku/cache) echo valkey; preset valkey | jq -c . ;;
    fauxcel/api) echo http-api; preset http-api | jq -c '.subdomain = ""' ;;
    fauxcel/app) echo fauxcel-app; preset lambda-function | jq -c . ;;
    fauxcel/kv) echo dynamodb-table; preset dynamodb-table | jq -c . ;;
    fauxcel/blob) echo s3-bucket; preset s3-bucket | jq -c . ;;
    *) die "no component $2 in $1" ;;
  esac
}

# fork <paas> <id>: what a Rocketsled server does for a customer.
cmd_fork() {
  local paas=${1:-} id=${2:-} components component out bundle params instances='{}' config
  case "$paas" in
    fauxroku) components="web worker db cache" ;;
    fauxcel) components="api app kv blob" ;;
    *) die "usage: ./deploy.sh fork fauxroku|fauxcel <id>" ;;
  esac
  [[ "$id" =~ ^[a-z0-9]{1,20}$ && "$id" != template ]] || die "the id is 1-20 lowercase letters or digits, and not template"
  confirm "$(fork_plan "$paas" "$id")"

  for component in $components; do
    out=$(fork_params "$paas" "$component" "$id")
    bundle=$(head -1 <<<"$out")
    params=$(tail -1 <<<"$out")
    instances=$(jq -c --arg c "$component" --arg v "$(dev_version "$bundle")" --argjson p "$params" \
      '. + {($c): {version: $v, params: $p}}' <<<"$instances")
  done
  config=$(mktemp)
  jq -n --arg p "$paas" --argjson i "$instances" \
    '{project: $p, baseEnvironment: "template", copyEnvironmentDefaults: true, instances: $i}' >"$config"

  log "fork $paas-$id"
  mass environment preview "$id" -f "$config" -n "$id" --follow || true
  rm -f "$config"
}

# The Rocketsled servers read their Massdriver keys from here. The values are
# never printed.
cmd_env() {
  local keys
  keys=$(cd "$HERE" && tofu output -json server_api_keys)
  umask 077
  {
    echo "MASSDRIVER_ORGANIZATION_ID=$(org_id)"
    echo "FAUXROKU_MASSDRIVER_API_KEY=$(jq -r .fauxroku <<<"$keys")"
    echo "FAUXCEL_MASSDRIVER_API_KEY=$(jq -r .fauxcel <<<"$keys")"
  } >"$HERE/.env"
  log "wrote $HERE/.env"
}

teardown_plan() {
  cat <<PLAN
Deletes the Rocketsled example from your Massdriver organization and $(aws_target):
  - Decommissions and deletes every Fauxroku and Fauxcel customer environment, with their
    databases, tables and buckets. Nothing is kept.
  - Decommissions the shared platform.
  - Destroys what bootstrap.tf made: projects, templates, groups, policies, the servers' service
    accounts, the AWS credential and bundle grants.
  - Deletes the massdriver-<org> role, and removes the organization from the Massdriver OIDC
    provider, deleting the provider when no other organization uses it.
Published bundles and resource types stay, so ./deploy.sh all can stand it back up.
PLAN
}

# decommission <environment>: waits until nothing in it is deployed.
decommission() {
  local env=$1 instances live
  instances=$(mass instance list "$env" -o json 2>/dev/null | jq '. // []' || echo '[]')
  live=$(jq -r '[.[] | select(.status == "PROVISIONED" or .status == "FAILED")] | length' <<<"$instances")
  [ "$live" -gt 0 ] || { log "skip $env, nothing deployed"; return; }

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
  local org account provider env paas
  confirm "$(teardown_plan)"
  org=$(org_id)
  account=$(aws sts get-caller-identity --query Account --output text)

  # Rocketsled makes these, outside bootstrap.tf. Fauxroku's run on the
  # platform, so they go before it.
  for paas in fauxroku fauxcel; do
    for env in $(mass environment list "$paas" -o json 2>/dev/null | jq -r --arg t "$paas-template" '(. // [])[] | select(.id != $t) | .id'); do
      decommission "$env"
      mass environment delete "$env" --force >/dev/null
    done
  done

  release "$org" "platform-main-" fauxroku-template
  decommission platform-main

  log "destroy bootstrap.tf"
  (cd "$HERE" && tofu init -input=false >/dev/null && tofu destroy -input=false -auto-approve)

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
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  provision) cmd_provision ;;
  fork) cmd_fork "${2:-}" "${3:-}" ;;
  env) cmd_env ;;
  teardown) cmd_teardown ;;
  all)
    [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=apps.example.com"
    confirm "$(role_plan)

In your Massdriver organization: publishes the bundles both PaaSes use as development releases,
then creates the platform, fauxroku and fauxcel projects, the two templates, a group and service
account per PaaS for its Rocketsled server, and the AWS credential.

$(provision_plan)"
    cmd_role
    cmd_publish
    cmd_bootstrap
    cmd_provision
    cmd_env
    ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
