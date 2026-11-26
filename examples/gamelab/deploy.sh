#!/usr/bin/env bash
# Stands up Gamelab in a Massdriver organization.
#
#   ./deploy.sh role            make the IAM role Massdriver deploys with, in the current AWS account
#   ./deploy.sh setup           attributes, organization settings, bundle repositories and grants
#   ./deploy.sh publish         publish the resource types and bundles Gamelab uses, and the server
#   ./deploy.sh bootstrap       apply bootstrap.tf and set each environment's AWS credential
#   ./deploy.sh provision       deploy the platform, the lab template and the Gamelab server
#   ./deploy.sh images          build both images and push them to their registries
#   ./deploy.sh ship            build the server's image again and deploy it
#   ./deploy.sh password        print Gamelab's address and sign-in password
#   ./deploy.sh all             role, setup, publish, bootstrap and provision
#   ./deploy.sh teardown        remove every lab, then everything above
#
# Needs: mass (signed in, or MASSDRIVER_API_KEY and MASSDRIVER_ORG_ID set), tofu, jq, python3 with
# PyYAML, docker, and AWS CLI credentials for the account Gamelab deploys into.
#
# Settings, from the environment:
#   DOMAIN             the DNS zone Gamelab gets, e.g. gamelab.example.com; the server answers at
#                      play.<DOMAIN>                                               (provision)
#   PARENT_ZONE_ID     Route 53 zone of DOMAIN's parent in the same account. When set, the zone
#                      is delegated from it automatically; otherwise delegate by hand.
#   ISSUER             Massdriver's token issuer host; api.massdriver.cloud unless self-hosted
#   DEV=1              publish development releases and pin each instance to the one just
#                      published, for organizations that only take development releases
#   YES=1              skip the confirmation before anything changes in AWS
#   REDEPLOY=1         provision redeploys instances that are already up

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
APP="$HERE/applications/gamelab"
BUNDLES=(vpc dns-zone ecs-cluster ecr-repository codebase ecs-service postgres valkey lab-box)
# The bundles above reference these, even where the connection is optional.
TYPES=(aws-vpc aws-dns-zone aws-ecs-cluster aws-ecr-repository aws-codebase aws-postgres aws-valkey lab-endpoint source-repository app-project)
SUBDOMAIN=play

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
Deploys Gamelab into $(aws_target), region us-east-1:
  - A VPC with a NAT for internet egress, and flow logs.
  - A Route 53 hosted zone for ${DOMAIN:-<DOMAIN>}, with a certificate${PARENT_ZONE_ID:+, delegated by an NS record added to zone $PARENT_ZONE_ID}.
  - An ECS cluster and a public load balancer.
  - Two ECR repositories, and the Gamelab server and lab box images built and pushed to them.
  - The Gamelab server, one small Fargate task at https://$SUBDOMAIN.${DOMAIN:-<DOMAIN>}.
  - IAM roles and security groups for all of it.
Cost: roughly \$60/month while it runs, before any labs; each lab adds \$13 to \$105/month
by plan and extras, plus what its helper spends on Claude.
Remove it with: ./deploy.sh teardown
PLAN
}

# Params come from the bundle's own presets, so this script never drifts from
# what the catalog recommends.
preset() {
  local bundle=$1 name=${2:-Development}
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

# deploy <instance> <bundle> [jq filter applied to the preset]
deploy() {
  local instance=$1 bundle=$2 filter=${3:-.}
  pin "$instance"
  provisioned "$instance" && return
  log "deploy $instance"
  local before
  before=$(latest_deployment "$instance")
  preset "$bundle" | jq "$filter" | mass instance deploy "$instance" --params - -m "deploy.sh provision" --follow || true
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
  if [ -z "${DEV:-}" ]; then
    mass bundle publish --bundle-directory "$1"
    return
  fi
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

# pin <instance>: with DEV, runs the instance on the development release publish recorded.
pin() {
  [ -n "${DEV:-}" ] || return 0
  local bundle version
  bundle=$(mass instance get "$1" -o json | jq -r '.bundle.name // .bundle.id')
  version=$(awk -v b="$bundle" '$1 == b { print $2 }' "$HERE/.dev-versions" 2>/dev/null)
  [ -n "$version" ] || die "no development release of $bundle recorded; run DEV=1 ./deploy.sh publish"
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

# set_secret <instance> <name> <value>. The value travels in the environment
# and on stdin, so it never shows in a process list.
set_secret() {
  graphql "$(SECRET_VALUE=$3 jq -n --arg org "$(org_id)" --arg id "$1" --arg n "$2" '{
    query: "mutation($org: ID!, $id: ID!, $input: SetInstanceSecretInput!) { setInstanceSecret(organizationId: $org, id: $id, input: $input) { successful messages { message } } }",
    variables: {org: $org, id: $id, input: {name: $n, value: env.SECRET_VALUE}}
  }')" | jq -e '.data.setInstanceSecret.successful' >/dev/null || die "couldn't set $2 on $1"
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

# Attributes, bundle repositories and who may use each bundle come before
# anything is published or placed on a canvas.
cmd_setup() {
  require_role
  log "define attributes, organization settings, bundle repositories and their grants"
  # Some mass versions fail to list repositories ("Project not found"); a new organization has none to adopt.
  { mass repository list -t bundle -o json 2>/dev/null || echo '[]'; } |
    jq '{existing_bundle_repositories: [(. // [])[].name]}' >"$HERE/existing.auto.tfvars.json"
  (cd "$HERE" && tofu init -input=false >/dev/null &&
    # Adopt attributes an earlier run, or a person, already defined; a missing one just fails to import.
    for key in lab_plan player_age; do
      tofu state list "massdriver_custom_attribute.$key" 2>/dev/null | grep -q . ||
        tofu import -input=false "massdriver_custom_attribute.$key" "$key" >/dev/null 2>&1 || true
    done &&
    tofu apply -input=false -auto-approve \
      -target=massdriver_organization_settings.this -target=massdriver_oci_repository_grant.bundle \
      -target=massdriver_custom_attribute.lab_plan -target=massdriver_custom_attribute.player_age)
}

# Types before the bundles that use them, and the runtime before the server built on it.
cmd_publish() {
  local dir bundle
  log "publish Massdriver resource types"
  "$CATALOG/scripts/publish-massdriver-types.sh"
  publish_type "$CATALOG/platforms/aws-iam-role"
  for type in "${TYPES[@]}"; do publish_type "$CATALOG/resource-types/$type"; done
  for bundle in "${BUNDLES[@]}"; do publish_bundle "$CATALOG/bundles/$bundle"; done
  publish_bundle "$APP/bundle"
}

cmd_bootstrap() {
  require_role
  log "apply bootstrap.tf"
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

# build_image <registry instance> <directory> [tag suffix]: builds into that
# registry and prints the image. Tags are immutable, so an image already
# built from this commit is reused.
build_image() {
  local registry url region tag image
  registry=$(mass resource get "$1.repository" -o json)
  url=$(jq -r '.payload.url' <<<"$registry")
  region=$(jq -r '.payload.region' <<<"$registry")
  tag=$(git -C "$CATALOG" rev-parse --short HEAD)${3:-}
  image="$url:$tag"
  if aws ecr describe-images --region "$region" --repository-name "${url#*/}" --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    log "reuse $image"
    echo "$image"
    return
  fi
  log "build and push $image"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}" >&2
  # The base images are public. Docker sends any saved public.ecr.aws login with
  # the pull, and a stale one, or one from an account that can't pull, gets a 403.
  docker logout public.ecr.aws >/dev/null 2>&1 || true
  docker build --platform linux/arm64 --provenance=false -t "$image" "$2" >&2
  docker push "$image" >&2
  echo "$image"
}

cmd_images() {
  build_image labs-template-registry "$CATALOG/bundles/lab-box/image" >/dev/null
  build_image gamelab-main-registry "$APP/src"
}

# deploy_server <image>: the server's secrets come from bootstrap.tf, so they
# are never typed or printed.
deploy_server() {
  local image=$1 org
  org=$(org_id)
  set_secret gamelab-main-app GAMELAB_PASSWORD "$(tf_output gamelab_password)"
  set_secret gamelab-main-app SESSION_SECRET "$(tf_output session_secret)"
  set_secret gamelab-main-app MASSDRIVER_API_KEY "$(tf_output server_api_key)"
  deploy gamelab-main-app ecs-service ". + $(jq -n -c --arg image "$image" --arg org "$org" --arg sub "$SUBDOMAIN" '{
    image_uri: $image, port: 8080, subdomain: $sub, health_check_path: "/healthz",
    environment: [{name: "MASSDRIVER_ORGANIZATION_ID", value: $org}]
  }')"
}

cmd_provision() {
  [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=gamelab.example.com"
  confirm "$(provision_plan)"

  log "platform-main"
  deploy platform-main-network vpc
  delegate "$DOMAIN"
  deploy platform-main-dns dns-zone ".domain = \"$DOMAIN\""
  [ -z "${DELEGATING:-}" ] || wait "$DELEGATING" || die "couldn't delegate $DOMAIN from $PARENT_ZONE_ID; see the error above"
  deploy platform-main-cluster ecs-cluster

  local project field
  for project in gamelab labs; do
    for field in network.network dns.zone cluster.cluster; do
      share "platform-main-$field" --condition "md-project=$project"
    done
  done
  for field in network.network dns.zone cluster.cluster; do
    mass environment default gamelab-main "platform-main-$field" >/dev/null
  done
  # Labs copy the template's defaults when they're forked, so every lab lands
  # in the platform's VPC and cluster with the lab image, connecting nothing.
  for field in network.network cluster.cluster; do
    mass environment default labs-template "platform-main-$field" >/dev/null
  done

  log "labs-template"
  deploy labs-template-registry ecr-repository
  deploy labs-template-codebase codebase '.share_with_project = false'
  share labs-template-codebase.codebase --condition md-project=labs
  mass environment default labs-template labs-template-codebase.codebase >/dev/null
  # Forks take the template's versions, so labs run the same releases.
  local part
  for part in box saves scores; do pin "labs-template-$part"; done

  log "gamelab-main"
  deploy gamelab-main-registry ecr-repository
  deploy gamelab-main-codebase codebase '.share_with_project = false'

  local server
  build_image labs-template-registry "$CATALOG/bundles/lab-box/image" >/dev/null
  server=$(build_image gamelab-main-registry "$APP/src")
  deploy_server "$server"

  cmd_password
}

cmd_ship() {
  local image before
  image=$(build_image gamelab-main-registry "$APP/src" "-$(date +%s)")
  log "deploy gamelab-main-app"
  before=$(latest_deployment gamelab-main-app)
  mass instance deploy gamelab-main-app --patch ".image_uri = \"$image\"" -m "Ship ${image##*:}" --follow || true
  wait_for gamelab-main-app "$before"
}

cmd_password() {
  local domain
  domain=$(mass resource get platform-main-dns.zone -o json 2>/dev/null | jq -r '.payload.domain // empty' || true)
  printf '\nGamelab: https://%s.%s\nPassword: %s\n' "$SUBDOMAIN" "${domain:-<DOMAIN>}" "$(tf_output gamelab_password)" >&2
}

teardown_plan() {
  cat <<PLAN
Deletes Gamelab from your Massdriver organization and $(aws_target):
  - Decommissions and deletes every lab, with its games, databases and backups' source.
    Nothing is kept.
  - Decommissions the lab template, the Gamelab server and the platform.
  - Destroys what bootstrap.tf made: projects, environments, groups, policies, the server's
    service account, the AWS credential, bundle grants and attributes.
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
  local org account provider env labs
  confirm "$(teardown_plan)"
  org=$(org_id)
  account=$(aws sts get-caller-identity --query Account --output text)

  # The Gamelab server makes these, outside bootstrap.tf. Their boxes run on
  # the platform's cluster, so they go first, and the server goes before them
  # so it can't make another.
  decommission gamelab-main
  labs=$(mass environment list labs -o json 2>/dev/null | jq -r '(. // [])[] | select(.id != "labs-template") | .id')
  for env in $labs; do
    decommission "$env"
    mass environment delete "$env" --force >/dev/null
  done
  release "$org" "labs-template-" labs-template
  decommission labs-template

  release "$org" "platform-main-" gamelab-main labs-template
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
  setup) cmd_setup ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  provision) cmd_provision ;;
  images) cmd_images >/dev/null ;;
  ship) cmd_ship ;;
  password) cmd_password ;;
  teardown) cmd_teardown ;;
  all)
    [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=gamelab.example.com"
    confirm "$(role_plan)

In your Massdriver organization: defines the lab_plan and player_age attributes, turns off granting
new bundles to every project, creates a repository and access grant for every bundle, publishes the
bundles Gamelab uses and the Gamelab server, then creates the platform, gamelab and labs projects,
their environments, two groups with their policies, the Gamelab Server service account and the
AWS credential.

$(provision_plan)"
    cmd_role
    cmd_setup
    cmd_publish
    cmd_bootstrap
    cmd_provision
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
