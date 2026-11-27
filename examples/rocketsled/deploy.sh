#!/usr/bin/env bash
# Stands up the Rocketsled example: Fauxroku and Fauxcel in a Massdriver organization.
#
#   ./deploy.sh role              make the IAM role Massdriver deploys with, in the current AWS account
#   ./deploy.sh publish           publish the resource types and bundles both PaaSes use
#   ./deploy.sh bootstrap         apply bootstrap.tf and set each environment's AWS credential
#   ./deploy.sh provision         deploy the shared platform and each template's image repository
#   ./deploy.sh fork <runtime> <id> [add-on...]
#                                 fork a customer environment from a runtime's template and deploy
#                                 it with the add-ons named, the way a Rocketsled server does, e.g.
#                                 ./deploy.sh fork ruby staging db  or  ./deploy.sh fork static demo
#   ./deploy.sh env               write .env for the Rocketsled servers (fauxroku.yaml, fauxcel.yaml)
#   ./deploy.sh servers [paas]    run both websites on the platform's cluster, at fauxroku.<DOMAIN>
#                                 and fauxcel.<DOMAIN>, from a Rocketsled checkout (ROCKETSLED_DIR,
#                                 default ../rocketsled next to this repository)
#   ./deploy.sh costs             connect Massdriver's cost reporting to this AWS account
#   ./deploy.sh all               role, publish, bootstrap, provision and env
#   ./deploy.sh teardown          remove every customer environment, then everything above
#
# Needs: mass (signed in, or MASSDRIVER_API_KEY and MASSDRIVER_ORG_ID set), tofu, jq, python3 with
# PyYAML, docker, and AWS CLI credentials for the account the PaaSes deploy into.
#
# Settings, from the environment:
#   DOMAIN             the DNS zone Fauxroku apps live under, e.g. apps.example.com; an app's web
#                      dynos answer at <environment id>.<DOMAIN>                    (provision)
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
BUNDLES=(vpc dns-zone ecs-cluster ecr-repository codebase ecs-service postgres valkey http-api lambda-function dynamodb-table s3-bucket)
APPS=(fauxroku-node fauxroku-ruby fauxroku-python fauxroku-worker fauxcel-functions fauxcel-static rocketsled-server)
RUNTIMES=(node ruby python functions static)
# The bundles above reference these, even where the connection is optional.
TYPES=(aws-vpc aws-dns-zone aws-ecs-cluster aws-ecr-repository aws-codebase source-repository app-project aws-postgres aws-valkey aws-http-api aws-dynamodb-table aws-s3-bucket website)

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
Deploys into $(aws_target), region us-east-1, with each bundle's Development preset:
  - Fauxroku's shared platform: a VPC with a NAT instance and flow logs, a Route 53 hosted zone
    for ${DOMAIN:-<DOMAIN>} with a wildcard certificate${PARENT_ZONE_ID:+ (delegated by an NS record added to zone $PARENT_ZONE_ID)},
    an ECS cluster and one public load balancer every Fauxroku app shares.
  - In each of the five runtime templates (node, ruby, python, functions, static): an ECR
    repository and its codebase, so every environment of that runtime pulls from one place.
  - The static site's file server image, built and pushed to the static template's repository.
Cost: about \$25/month while it runs, most of it the load balancer. Nothing else in the
templates is deployed. Remove it with: ./deploy.sh teardown
PLAN
}

fork_plan() {
  local runtime=$1 id=$2
  shift 2
  echo "Forks $runtime-template into $runtime-$id and deploys it into $(aws_target), with the"
  echo "cheapest presets:"
  case "$runtime" in
    node | ruby | python) echo "  - Web dynos: one 0.25 vCPU, 0.5 GB Fargate Spot task at https://$runtime-$id.<DOMAIN> (~\$2/month)." ;;
    functions) echo "  - An HTTP API and one 256 MB arm64 Lambda function: nothing while idle." ;;
    static) echo "  - An HTTP API, the file server function and a files bucket: nothing while idle." ;;
  esac
  local addon
  for addon in "$@"; do
    case "$addon" in
      worker) echo "  - Worker dynos: one more Spot task, with no address (~\$2/month)." ;;
      db) echo "  - Postgres: db.t4g.micro, 20 GB, no standby (~\$15/month)." ;;
      cache) echo "  - Key-Value Store: ElastiCache Serverless Valkey, 1 GB limit (~\$6/month at its minimum)." ;;
      kv) echo "  - KV: an on-demand DynamoDB table (per request)." ;;
      blob) echo "  - Blob: an S3 bucket (per GB stored)." ;;
    esac
  done
  echo "Remove it with: ./deploy.sh teardown"
}

bundle_dir() {
  case "$1" in
    fauxroku-* | fauxcel-*) echo "$HERE/applications/$1/bundle" ;;
    *) echo "$CATALOG/bundles/$1" ;;
  esac
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
  local out
  # A published version can't change, so one the organization already has is current.
  if ! out=$(mass resource-type publish "$1" 2>&1); then
    grep -q "already exists" <<<"$out" || die "$out"
  fi
  echo "$out" >&2
}

publish_bundle() {
  local name
  name=$(awk '/^name:/ { print $2; exit }' "$1/massdriver.yaml")
  log "publish bundle $name"
  # A bundle publishes only into a repository that exists; bootstrap adopts it afterwards.
  mass repository create "$name" -t bundle >/dev/null 2>&1 || true
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

costs_plan() {
  cat <<PLAN
In $(aws_target):
  - An IAM user, massdriver-costs-<org>, that can only read the account's massdriver-costs Cost and
    Usage Report and resource tags, and its access key.
Then connects the AWS Cost and Usage Reports integration in your Massdriver organization with that key.
PLAN
}

# The Terraform provider can't manage integrations, so the key goes over the API.
# An organization has one integration per type; a rerun leaves a connected one alone.
cmd_costs() {
  local org status values
  confirm "$(costs_plan)"
  org=$(org_id)

  log "read-only user for the cost and usage report"
  (cd "$HERE/costs" && tofu init -input=false >/dev/null && tofu apply -input=false -auto-approve -var "organization=$org")

  status=$(graphql "$(jq -n --arg org "$org" '{
    query: "query($org: ID!) { integration(organizationId: $org, id: \"aws-cost-and-usage-reports\") { status } }",
    variables: {org: $org}
  }')" | jq -r '.data.integration.status // empty')
  if [ -n "$status" ]; then
    log "AWS Cost and Usage Reports integration is already $status"
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
    die "couldn't connect the integration; it needs an organization admin"
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
  log "publish Massdriver resource types"
  "$CATALOG/scripts/publish-massdriver-types.sh"
  publish_type "$CATALOG/platforms/aws-iam-role"
  for type in "${TYPES[@]}"; do publish_type "$CATALOG/resource-types/$type"; done
  for bundle in "${BUNDLES[@]}" "${APPS[@]}"; do publish_bundle "$(bundle_dir "$bundle")"; done
}

cmd_bootstrap() {
  require_role
  log "apply bootstrap.tf"
  # Some mass versions fail to list repositories ("Project not found"); a new organization has none to adopt.
  # Everything publish created is adopted too, since listing can fail.
  { mass repository list -t bundle -o json 2>/dev/null || echo '[]'; } |
    jq --rawfile published <(awk '{ print $1 }' "$HERE/.dev-versions" 2>/dev/null || true) \
      '{existing_bundle_repositories: ([(. // [])[].name] + ($published | split("\n") | map(select(. != ""))) | unique)}' \
      >"$HERE/existing.auto.tfvars.json"
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

static_image() {
  build_image static-template-registry "$HERE/applications/fauxcel-static/src"
}

is_fauxroku() {
  case "$1" in node | ruby | python) return 0 ;; *) return 1 ;; esac
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

  local runtime field instance
  for runtime in "${RUNTIMES[@]}"; do
    log "$runtime-template"
    # Forks copy the template's defaults: Fauxroku environments land in the
    # platform's VPC and behind its load balancer, and every environment pulls
    # from its runtime's codebase, connecting nothing.
    if is_fauxroku "$runtime"; then
      for field in network.network cluster.cluster; do
        share "platform-main-$field" --condition "md-project=$runtime"
        mass environment default "$runtime-template" "platform-main-$field" >/dev/null
      done
    fi
    deploy "$runtime-template-registry" ecr-repository
    deploy "$runtime-template-codebase" codebase '.share_with_project = false'
    share "$runtime-template-codebase.codebase" --condition "md-project=$runtime"
    mass environment default "$runtime-template" "$runtime-template-codebase.codebase" >/dev/null
    # Forks take the template's versions, so customers run the release just published.
    for instance in $(mass instance list "$runtime-template" -o json | jq -r '.[].id'); do pin "$instance"; done
  done

  static_image >/dev/null
}

# fork_preset <runtime> <component> <id>: the bundle whose presets the
# component uses, and the jq filter applied to its cheapest one. Web dynos get
# the environment's own subdomain, the one param a preset can't know
# (massdriver-cloud/rocketsled#11).
fork_preset() {
  case "$2" in
    web) echo "ecs-service .subdomain=\"$1-$3\"|.spot=true" ;;
    worker) echo 'ecs-service .subdomain=""|.spot=true' ;;
    app) echo 'lambda-function .' ;;
    site) echo "lambda-function .image_uri=\"$(static_image)\"" ;;
    api) echo 'http-api .subdomain=""' ;;
    db) echo 'postgres .' ;;
    cache) echo 'valkey .' ;;
    kv) echo 'dynamodb-table .' ;;
    blob | files) echo 's3-bucket .' ;;
  esac
}

# fork <runtime> <id> [add-on...]: what a Rocketsled server does for a
# customer. Only the runtime's own components and the add-ons named are
# deployed; the rest stay on the canvas, linked and undeployed.
cmd_fork() {
  local runtime=${1:-} id=${2:-} base addons addon component spec
  shift 2 || true
  case "$runtime" in
    node | ruby | python) base="web" addons="worker db cache" ;;
    functions) base="api app" addons="kv blob" ;;
    static) base="files api site" addons="" ;;
    *) die "usage: ./deploy.sh fork node|ruby|python|functions|static <id> [add-on...]" ;;
  esac
  [[ "$id" =~ ^[a-z0-9]{1,20}$ && "$id" != template ]] || die "the id is 1-20 lowercase letters or digits, and not template"
  for addon in "$@"; do
    [[ " $addons " == *" $addon "* ]] || die "$runtime has no add-on $addon; it has: ${addons:-none}"
  done
  confirm "$(fork_plan "$runtime" "$id" "$@")"

  if ! mass environment get "$runtime-$id" >/dev/null 2>&1; then
    log "fork $runtime-template into $runtime-$id"
    mass environment fork "$runtime-template" "$id" --name "$id" --copy-environment-defaults >/dev/null
  fi
  # Add-ons first: the runtime reads them when it deploys. A worker is the
  # exception; it's a consumer like web.
  for component in $(printf '%s\n' "$@" | grep -vx worker) $base $(printf '%s\n' "$@" | grep -x worker); do
    spec=$(fork_preset "$runtime" "$component" "$id")
    deploy "$runtime-$id-$component" "${spec%% *}" "${spec#* }"
  done
}

# The Rocketsled servers read their Massdriver keys from here. The values are
# never printed. Session secrets and passwords are kept across runs, so nobody is signed out.
cmd_env() {
  local keys paas secret
  keys=$(cd "$HERE" && tofu output -json server_api_keys)
  umask 077
  {
    echo "MASSDRIVER_ORGANIZATION_ID=$(org_id)"
    echo "FAUXROKU_MASSDRIVER_API_KEY=$(jq -r .fauxroku <<<"$keys")"
    echo "FAUXCEL_MASSDRIVER_API_KEY=$(jq -r .fauxcel <<<"$keys")"
    for paas in FAUXROKU FAUXCEL; do
      secret=$(env_value "${paas}_SESSION_SECRET")
      echo "${paas}_SESSION_SECRET=${secret:-$(openssl rand -hex 32)}"
      secret=$(env_value "${paas}_PASSWORD")
      echo "${paas}_PASSWORD=${secret:-$(openssl rand -base64 12 | tr -d '/+=')}"
    done
  } >"$HERE/.env.new"
  mv "$HERE/.env.new" "$HERE/.env"
  log "wrote $HERE/.env"
}

env_value() {
  [ -f "$HERE/.env" ] && sed -n "s/^$1=//p" "$HERE/.env" | head -1
}

# set_secret <instance> <name> <.env key>: the value goes from .env to Massdriver unseen.
set_secret() {
  local value
  value=$(env_value "$3")
  [ -n "$value" ] || die "no $3 in .env; run ./deploy.sh env"
  graphql "$(jq -n --arg org "$(org_id)" --arg id "$1" --arg name "$2" --arg value "$value" '{
    query: "mutation($org: ID!, $id: ID!, $input: SetInstanceSecretInput!) { setInstanceSecret(organizationId: $org, id: $id, input: $input) { successful messages { message } } }",
    variables: {org: $org, id: $id, input: {name: $name, value: $value}}
  }')" | jq -e '.data.setInstanceSecret.successful' >/dev/null || die "couldn't set $2 on $1"
}

servers_plan() {
  cat <<PLAN
Runs the Fauxroku and Fauxcel websites in $(aws_target), on the platform's cluster:
  - The rocketsled project's image repository, and an image of Rocketsled with this example's
    configs and skins, built from ${ROCKETSLED_DIR:-../rocketsled}.
  - Two 0.25 vCPU, 0.5 GB Fargate Spot tasks at https://fauxroku.<DOMAIN> and https://fauxcel.<DOMAIN>
    (~\$4/month together). Each keeps its database on the task's disk; who owns which app is
    kept on the app's environment in Massdriver, so a new task loses nothing customers see.
PLAN
}

cmd_servers() {
  local rocketsled=${ROCKETSLED_DIR:-$CATALOG/../rocketsled} domain org site image hash paas upper port instance before field
  [ -f "$rocketsled/Dockerfile" ] || die "no Rocketsled checkout at $rocketsled; set ROCKETSLED_DIR"
  confirm "$(servers_plan)"
  domain=$(mass instance get platform-main-dns -o json | jq -r .params.domain)
  org=$(org_id)

  for field in network.network cluster.cluster; do
    share "platform-main-$field" --condition md-project=rocketsled
    mass environment default rocketsled-main "platform-main-$field" >/dev/null
  done
  mass environment default rocketsled-main "$(tf_output aws_credential)" >/dev/null
  deploy rocketsled-main-registry ecr-repository
  # The codebase is what lets the servers' tasks pull from the registry.
  deploy rocketsled-main-codebase codebase '.share_with_project = false'
  share rocketsled-main-codebase.codebase --condition md-project=rocketsled
  mass environment default rocketsled-main rocketsled-main-codebase.codebase >/dev/null

  log "build Rocketsled"
  docker build --platform linux/arm64 --provenance=false -t rocketsled:local "$rocketsled" >&2
  hash=$( (cd "$HERE" && tar cf - fauxroku.yaml fauxcel.yaml skins server) | shasum | cut -c1-8)
  image=$(build_server_image "$(git -C "$rocketsled" rev-parse --short HEAD)-$hash")
  site=$(static_image)
  local welcome=() runtime
  for runtime in node ruby python; do
    welcome+=("$(tr a-z A-Z <<<"$runtime")_WELCOME=$(build_image "$runtime-template-registry" "$HERE/applications/fauxroku-welcome" -welcome)")
  done

  for paas in ${1:-fauxroku fauxcel}; do
    instance=rocketsled-main-$paas
    upper=$(tr a-z A-Z <<<"$paas")
    port=8081
    [ "$paas" = fauxroku ] || port=8082
    set_secret "$instance" "${upper}_MASSDRIVER_API_KEY" "${upper}_MASSDRIVER_API_KEY"
    set_secret "$instance" "${upper}_SESSION_SECRET" "${upper}_SESSION_SECRET"
    set_secret "$instance" "${upper}_PASSWORD" "${upper}_PASSWORD"
    pin "$instance"
    log "deploy $instance"
    before=$(latest_deployment "$instance")
    preset ecs-service | jq --arg image "$image" --arg paas "$paas" --argjson port "$port" --arg org "$org" \
      --arg base "https://$paas.$domain" --arg base_var "${upper}_BASE_URL" --arg site "$site" '
      .image_uri = $image | .subdomain = $paas | .port = $port | .spot = true | .health_check_path = "/healthz"
      | .environment = [
          {name: "PAAS", value: $paas},
          {name: "MASSDRIVER_ORGANIZATION_ID", value: $org},
          {name: $base_var, value: $base},
          {name: "FAUXCEL_SITE_IMAGE", value: $site}
        ] + [$ARGS.positional[] | split("=") | {name: ("FAUXROKU_" + .[0]), value: (.[1:] | join("="))}]' --args "${welcome[@]}" | mass instance deploy "$instance" --params - -m "Rocketsled $paas website, $image" --follow || true
    wait_for "$instance" "$before"
    log "https://$paas.$domain"
  done
}

# build_server_image <tag>: Rocketsled with the configs and skins, in the rocketsled registry.
build_server_image() {
  local registry url region image
  registry=$(mass resource get rocketsled-main-registry.repository -o json)
  url=$(jq -r '.payload.url' <<<"$registry")
  region=$(jq -r '.payload.region' <<<"$registry")
  image="$url:$1"
  if aws ecr describe-images --region "$region" --repository-name "${url#*/}" --image-ids "imageTag=$1" >/dev/null 2>&1; then
    log "reuse $image"
    echo "$image"
    return
  fi
  log "build and push $image"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}" >&2
  docker build --platform linux/arm64 --provenance=false --build-arg ROCKETSLED_IMAGE=rocketsled:local \
    -f "$HERE/server/Dockerfile" -t "$image" "$HERE" >&2
  docker push "$image" >&2
  echo "$image"
}

teardown_plan() {
  cat <<PLAN
Deletes the Rocketsled example from your Massdriver organization and $(aws_target):
  - Decommissions and deletes every customer environment of every runtime, with their
    databases, caches, tables and buckets. Nothing is kept.
  - Decommissions each template's image repository and codebase, with their images.
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
  local org account provider env runtime
  confirm "$(teardown_plan)"
  org=$(org_id)
  account=$(aws sts get-caller-identity --query Account --output text)

  # Rocketsled makes these, outside bootstrap.tf. They pull from the templates'
  # codebases and Fauxroku's run on the platform, so they go first.
  for runtime in "${RUNTIMES[@]}"; do
    for env in $(mass environment list "$runtime" -o json 2>/dev/null | jq -r --arg t "$runtime-template" '(. // [])[] | select(.id != $t) | .id'); do
      decommission "$env"
      mass environment delete "$env" --force >/dev/null
    done
    release "$org" "$runtime-template-" "$runtime-template"
    decommission "$runtime-template"
  done

  release "$org" "platform-main-" node-template ruby-template python-template
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
  costs) cmd_costs ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  provision) cmd_provision ;;
  fork) shift; cmd_fork "$@" ;;
  env) cmd_env ;;
  servers) shift; cmd_servers "$@" ;;
  teardown) cmd_teardown ;;
  all)
    [ -n "${DOMAIN:-}" ] || die "set DOMAIN, e.g. DOMAIN=apps.example.com"
    confirm "$(role_plan)

In your Massdriver organization: publishes the bundles both PaaSes use as development releases,
then creates the platform project and a project per runtime with its template, a group and
service account per PaaS for its Rocketsled server, and the AWS credential.

$(provision_plan)"
    cmd_role
    cmd_publish
    cmd_bootstrap
    cmd_provision
    cmd_env
    ;;
  *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
