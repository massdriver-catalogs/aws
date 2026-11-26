#!/usr/bin/env bash
# Stands up Tendwell Supply's seven PHP apps partway through an ECS service runtime upgrade.
#
#   ./deploy.sh bootstrap    apply bootstrap.tf, publish the apps, and point dev at the platform
#   ./deploy.sh runtimes     make sure ecs-service has the three development releases the apps build on
#   ./deploy.sh publish      publish every app version in versions.txt that isn't published yet
#   ./deploy.sh image        deploy the registry and codebase, then build and push the PHP image
#   ./deploy.sh deploy       put each instance on its version from versions.txt and deploy it
#   ./deploy.sh all          runtimes, bootstrap, image and deploy
#   ./deploy.sh teardown     decommission dev and destroy what bootstrap.tf made
#
# Needs the telehealth example's platform-dev environment deployed in the same organization,
# mass (signed in), tofu, jq, python3 with PyYAML, docker, and AWS CLI credentials for the
# account the platform runs in.
#
#   YES=1        skip the confirmation before anything changes in AWS
#   REPUBLISH=1  publish every version in versions.txt again, e.g. after changing a guide

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
PROJECT=phpfleet
ENV=$PROJECT-dev
RUNTIME=ecs-service

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

confirm() {
  [ -n "${YES:-}" ] && return
  printf '\n%s\n\n' "$1" >&2
  [ -r /dev/tty ] || die "no terminal to confirm on; rerun with YES=1 once you've read the above"
  local answer
  read -r -p "Type yes to continue: " answer </dev/tty
  [ "$answer" = yes ] || die "stopped; nothing was changed"
  YES=1
}

deploy_plan() {
  cat <<PLAN
Deploys into AWS account $(aws sts get-caller-identity --query Account --output text), on the platform's dev cluster:
  - An ECR repository for the PHP image.
  - Seven Fargate Spot services, 0.25 vCPU and 0.5 GB each, one task apiece, each at
    <app>.<dev zone> on the cluster's load balancer, with five CloudWatch alarms.
Cost: roughly \$20/month while it runs.
Remove it with: ./deploy.sh teardown
PLAN
}

# versions.txt without its header: app, version, runtime, instance.
versions() { tail -n +2 "$HERE/versions.txt"; }

apps() { versions | awk '{ print $1 }' | uniq; }

tags() { mass repository get "$1" -o json 2>/dev/null | jq -r '.tags[]?.tag' || true; }

runtime_base() { awk '/^version:/ { print $2; exit }' "$CATALOG/bundles/$RUNTIME/massdriver.yaml"; }

# The development releases of the runtime's current version, oldest first.
dev_releases() { tags "$RUNTIME" | grep "^$(runtime_base)-dev\." | sort || true; }

# runtime_constraint <dev1|dev2|dev3|latest>
runtime_constraint() {
  case "$1" in
    latest) echo "$RUNTIME" ;;
    dev[1-3])
      local release
      release=$(dev_releases | sed -n "${1#dev}p")
      [ -n "$release" ] || die "$RUNTIME has no $1 release; run ./deploy.sh runtimes"
      echo "$RUNTIME@$release"
      ;;
    *) die "unknown runtime $1 in versions.txt" ;;
  esac
}

# runtime_label <constraint>: the runtime version an app built with it runs on.
runtime_label() {
  case "$1" in
    *@*) echo "$RUNTIME ${1#*@}" ;;
    *) echo "$RUNTIME $(tags "$RUNTIME" | grep -v -- -dev | sort -V | tail -1)" ;;
  esac
}

# published <app> <version>: the newest development release of that version, if any.
published() { tags "$(bundle_name "$1")" | grep "^$2-dev\." | sort | tail -1 || true; }

bundle_name() { awk '/^name:/ { print $2; exit }' "$HERE/applications/$1/massdriver.yaml"; }

# Ecs-service's stable versions take a person's review, so the older runtime
# versions are development releases of the current one.
cmd_runtimes() {
  local count
  count=$(dev_releases | wc -l | tr -d ' ')
  while [ "$count" -lt 3 ]; do
    log "publish a development release of $RUNTIME"
    mass bundle publish --development --bundle-directory "$CATALOG/bundles/$RUNTIME"
    count=$((count + 1))
    sleep 2
  done
  dev_releases | head -3 | nl -w1 -s' ' | sed 's/^/dev/' >&2
}

cmd_publish() {
  local app version runtime constraint tmp
  while read -r app version runtime _; do
    if [ -z "${REPUBLISH:-}" ] && [ -n "$(published "$app" "$version")" ]; then
      log "skip $app $version, already published"
      continue
    fi
    log "publish $app $version on $runtime"
    constraint=$(runtime_constraint "$runtime")
    tmp=$(mktemp -d)
    cp "$HERE/applications/$app/massdriver.yaml" "$HERE/applications/$app/operator.md" "$tmp/"
    sed -i.bak -e "s/^version: .*/version: $version/" -e "s|^  runtime: .*|  runtime: $constraint|" "$tmp/massdriver.yaml"
    # The guide can't read the bundle's version or runtime, so they're written in.
    sed -i.bak -e "s/^- \*\*Version:\*\* .*/- **Version:** $version/" \
      -e "s/^- \*\*Built on:\*\* .*/- **Built on:** $(runtime_label "$constraint")/" "$tmp/operator.md"
    rm "$tmp"/*.bak
    mass bundle publish --development --bundle-directory "$tmp"
    rm -rf "$tmp"
  done < <(versions)
}

environment_defaults() { mass environment get "$1" -o json | jq -r '.defaults[]?.resource.id'; }

cmd_bootstrap() {
  log "apply bootstrap.tf"
  cd "$HERE"
  tofu init -input=false >/dev/null
  # A component needs a published bundle, and publishing needs the repository.
  tofu apply -input=false -auto-approve -target=massdriver_oci_repository_grant.app
  cmd_publish
  tofu apply -input=false -auto-approve

  log "point $ENV at the platform's dev network, zone, cluster and AWS credential"
  local credential have resource
  credential=$(mass environment get platform-dev -o json |
    jq -r '.defaults[] | select(.resource.resourceType.id | startswith("aws-iam-role@")) | .resource.id')
  [ -n "$credential" ] || die "platform-dev has no AWS credential; deploy the telehealth example first"
  have=$(environment_defaults "$ENV")
  for resource in "$credential" platform-dev-network.network platform-dev-dns.zone platform-dev-cluster.cluster; do
    grep -qx "$resource" <<<"$have" || mass environment default "$ENV" "$resource" >/dev/null
  done
}

latest_deployment() { mass deployment list "$1" -o json 2>/dev/null | jq -r '.[0].id // empty' || true; }

# wait_for <instance> <deployment id from before the deploy>
wait_for() {
  local latest status
  for _ in $(seq 1 120); do
    latest=$(mass deployment list "$1" -o json 2>/dev/null | jq -c '.[0] // empty') || { sleep 15; continue; }
    [ -n "$latest" ] && [ "$(jq -r .id <<<"$latest")" != "${2:-}" ] || die "$1: the deploy didn't start"
    status=$(jq -r .status <<<"$latest")
    case "$status" in
      COMPLETED) return ;;
      PROPOSED) die "$1: the deployment waits for approval" ;;
      FAILED | ABORTED | REJECTED) die "$1: deployment $status; see mass deployment logs" ;;
      *) sleep 15 ;;
    esac
  done
  die "$1: still $status after half an hour"
}

preset() {
  python3 - "$CATALOG/bundles/$1/massdriver.yaml" <<'PY'
import json, sys, yaml
for example in yaml.safe_load(open(sys.argv[1]))["params"]["examples"]:
    if example.pop("__name") == "Development":
        print(json.dumps(example))
PY
}

deploy_once() {
  local instance=$1 bundle=$2
  [ "$(mass instance get "$instance" -o json 2>/dev/null | jq -r .status)" = PROVISIONED ] && return
  log "deploy $instance"
  local before
  before=$(latest_deployment "$instance")
  preset "$bundle" | jq "${3:-.}" | mass instance deploy "$instance" --params - -m "php-fleet: set up" || true
  wait_for "$instance" "$before"
}

cmd_image() {
  confirm "$(deploy_plan)"
  deploy_once "$ENV-registry" ecr-repository
  deploy_once "$ENV-codebase" codebase '.share_with_project = false'

  local registry url region image
  registry=$(mass resource get "$ENV-registry.repository" -o json)
  url=$(jq -r .payload.url <<<"$registry")
  region=$(jq -r .payload.region <<<"$registry")
  image="$url:$(git -C "$HERE" log -1 --format=%h -- src)"
  if aws ecr describe-images --region "$region" --repository-name "${url#*/}" --image-ids "imageTag=${image##*:}" >/dev/null 2>&1; then
    log "reuse $image"
  else
    log "build and push $image"
    aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}" >&2
    # A stale saved public.ecr.aws login turns the public base image pull into a 403.
    docker logout public.ecr.aws >/dev/null 2>&1 || true
    docker build --platform linux/arm64 --provenance=false -t "$image" "$HERE/src" >&2
    docker push "$image" >&2
  fi
  echo "$image"
}

# deploy_app <app> <version> <runtime> <image>
deploy_app() {
  local app=$1 instance="$ENV-$1" release current before
  release=$(published "$app" "$2")
  [ -n "$release" ] || die "$app $2 isn't published; run ./deploy.sh publish"
  current=$(mass instance get "$instance" -o json | jq -r '"\(.status) \(.deployedVersion) \(.params.image_uri // "")"')
  if [ "$current" = "PROVISIONED $release $4" ]; then
    log "skip $instance, already runs $release"
    return
  fi
  log "deploy $instance $release"
  mass instance version "$instance@$release" >/dev/null
  before=$(latest_deployment "$instance")
  preset "$RUNTIME" |
    jq --arg app "$app" --arg image "$4" \
      '.image_uri = $image | .port = 80 | .spot = true | .subdomain = $app | .health_check_path = "/"' |
    mass instance deploy "$instance" --params - -m "$app $2 on $RUNTIME $3" >/dev/null || true
  wait_for "$instance" "$before"
}

cmd_deploy() {
  local image app version runtime pids=() failed=0 pid
  image=$(cmd_image | tail -1)
  while read -r app version runtime instance; do
    [ "$instance" = runs ] || continue
    deploy_app "$app" "$version" "$runtime" "$image" &
    pids+=($!)
  done < <(versions)
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  [ "$failed" = 0 ] || die "some apps didn't deploy; see above"
}

cmd_teardown() {
  confirm "Decommissions every instance in $ENV, then destroys the $PROJECT project, its components and its app bundles."
  local instances
  if mass environment get "$ENV" >/dev/null 2>&1; then
    instances=$(mass instance list "$ENV" -o json | jq -r '.[] | select(.status == "PROVISIONED" or .status == "FAILED") | .id')
    if [ -n "$instances" ]; then
      log "decommission $ENV"
      mass environment decommission "$ENV" >/dev/null
      for _ in $(seq 1 120); do
        sleep 15
        mass instance list "$ENV" -o json |
          jq -e 'all(.[]; .status == "INITIALIZED" or .status == "DECOMMISSIONED")' >/dev/null && break
      done
    fi
  fi
  log "destroy bootstrap.tf"
  (cd "$HERE" && tofu init -input=false >/dev/null && tofu destroy -input=false -auto-approve)
}

case "${1:-}" in
  runtimes) cmd_runtimes ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  image) cmd_image >/dev/null ;;
  deploy) cmd_deploy ;;
  all) cmd_runtimes && cmd_bootstrap && cmd_deploy ;;
  teardown) cmd_teardown ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
