#!/usr/bin/env bash
# Stands up Tendwell Supply's seven PHP apps partway through a PHP 7 runtime upgrade.
#
#   ./deploy.sh bootstrap    apply bootstrap.tf, publish the runtimes and apps, and point dev at the platform
#   ./deploy.sh runtimes     publish every runtime version in runtimes.txt that isn't published yet
#   ./deploy.sh publish      publish every app version in versions.txt that isn't published yet
#   ./deploy.sh image        deploy the registry and codebase, then build and push an image per PHP version
#   ./deploy.sh deploy       put each instance on its version from versions.txt and deploy it
#   ./deploy.sh all          bootstrap and deploy
#   ./deploy.sh teardown     decommission dev and destroy what bootstrap.tf made
#
# Needs the telehealth example's platform-dev environment deployed in the same organization,
# mass (signed in), tofu, jq, python3 with PyYAML, docker, and AWS CLI credentials for the
# account the platform runs in.
#
#   YES=1        skip the confirmation before anything changes in AWS
#   DEV=1        publish development releases instead of stable versions
#   REPUBLISH=1  with DEV=1, publish every version again, e.g. after changing a guide

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$(cd "$HERE/../.." && pwd)"
PROJECT=phpfleet
ENV=$PROJECT-dev
MESSAGE="php-fleet"

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
  - An ECR repository for the PHP images.
  - Seven Fargate Spot services, 0.25 vCPU and 0.5 GB each, one task apiece, each at
    <app>.<dev zone> on the cluster's load balancer, with five CloudWatch alarms.
Cost: roughly \$20/month while it runs.
Remove it with: ./deploy.sh teardown
PLAN
}

# The tables without their headers.
versions() { tail -n +2 "$HERE/versions.txt"; }
runtimes() { tail -n +2 "$HERE/runtimes.txt"; }

tags() { mass repository get "$1" -o json 2>/dev/null | jq -r '.tags[]?.tag' || true; }

# release <repository> <version>: the published tag for that version, if any.
# A development release is the newest <version>-dev.<timestamp>.
release() {
  if [ -n "${DEV:-}" ]; then
    tags "$1" | grep "^$2-dev\." | sort | tail -1 || true
  else
    tags "$1" | grep -x "$2" || true
  fi
}

publish_flags() { [ -z "${DEV:-}" ] || echo --development; }

# Already published, unless a development release is being redone.
skip_publish() { [ -z "${REPUBLISH:-}" ] || [ -z "${DEV:-}" ] && [ -n "$(release "$1" "$2")" ]; }

# assemble_runtime <runtime> <version> <dir>: ecs-service with PHP's defaults,
# so the PHP runtimes never drift from the runtime every other app runs on.
assemble_runtime() {
  cp -R "$CATALOG/bundles/ecs-service/." "$3/"
  cp "$HERE/runtimes/$1/README.md" "$3/"
  python3 - "$3/massdriver.yaml" "$HERE/runtimes/$1/runtime.yaml" "$2" <<'PY'
import json, sys, yaml
path, overlay, version = sys.argv[1], sys.argv[2], sys.argv[3]
spec = yaml.safe_load(open(path))
spec.update(yaml.safe_load(open(overlay)))
spec["version"] = version
params = spec["params"]
params["properties"]["port"]["default"] = 80
for example in params["examples"]:
    example["port"] = 80
spec.setdefault("app", {}).setdefault("envs", {})["PHP_VERSION"] = json.dumps(version)
yaml.safe_dump(spec, open(path, "w"), sort_keys=False, width=100)
PY
}

cmd_runtimes() {
  local runtime version tmp
  while read -r runtime version; do
    if skip_publish "$runtime" "$version"; then
      log "skip $runtime $version, already published"
      continue
    fi
    log "publish $runtime $version"
    tmp=$(mktemp -d)
    assemble_runtime "$runtime" "$version" "$tmp"
    # shellcheck disable=SC2046
    mass bundle publish $(publish_flags) --bundle-directory "$tmp"
    rm -rf "$tmp"
  done < <(runtimes)
}

bundle_name() { awk '/^name:/ { print $2; exit }' "$HERE/applications/$1/massdriver.yaml"; }

# runtime_release <runtime@version>: the published runtime it names.
runtime_release() {
  local found
  found=$(release "${1%@*}" "${1#*@}")
  [ -n "$found" ] || die "$1 isn't published; run ./deploy.sh runtimes"
  echo "${1%@*}@$found"
}

cmd_publish() {
  local app version runtime built tmp
  while read -r app version runtime _; do
    if skip_publish "$(bundle_name "$app")" "$version"; then
      log "skip $app $version, already published"
      continue
    fi
    built=$(runtime_release "$runtime")
    log "publish $app $version on $built"
    tmp=$(mktemp -d)
    cp "$HERE/applications/$app/massdriver.yaml" "$HERE/applications/$app/operator.md" "$tmp/"
    sed -i.bak -e "s/^version: .*/version: $version/" -e "s|^  runtime: .*|  runtime: $built|" "$tmp/massdriver.yaml"
    # The guide can't read the bundle's version or runtime, so they're written in.
    sed -i.bak -e "s/^- \*\*Version:\*\* .*/- **Version:** $version/" \
      -e "s/^- \*\*Built on:\*\* .*/- **Built on:** ${built/@/ }/" "$tmp/operator.md"
    rm "$tmp"/*.bak
    # shellcheck disable=SC2046
    mass bundle publish $(publish_flags) --bundle-directory "$tmp"
    rm -rf "$tmp"
  done < <(versions)
}

environment_defaults() { mass environment get "$1" -o json | jq -r '.defaults[]?.resource.id'; }

# set_default <environment> <resource>, unless it's already a default.
set_default() { environment_defaults "$1" | grep -qx "$2" || mass environment default "$1" "$2" >/dev/null; }

cmd_bootstrap() {
  log "apply bootstrap.tf"
  cd "$HERE"
  tofu init -input=false >/dev/null
  # A component needs a published bundle, and publishing needs the repository.
  tofu apply -input=false -auto-approve -target=massdriver_oci_repository_grant.bundle
  cmd_runtimes
  cmd_publish
  tofu apply -input=false -auto-approve

  log "point $ENV at the platform's dev network, zone, cluster and AWS credential"
  local credential resource
  credential=$(mass environment get platform-dev -o json |
    jq -r '.defaults[] | select(.resource.resourceType.id | startswith("aws-iam-role@")) | .resource.id')
  [ -n "$credential" ] || die "platform-dev has no AWS credential; deploy the telehealth example first"
  for resource in "$credential" platform-dev-network.network platform-dev-dns.zone platform-dev-cluster.cluster; do
    set_default "$ENV" "$resource"
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
  preset "$bundle" | jq "${3:-.}" | mass instance deploy "$instance" --params - -m "$MESSAGE: set up" || true
  wait_for "$instance" "$before"
}

# image <php version>: the app image on that PHP, built once per source change.
image() {
  local registry url region tag
  registry=$(mass resource get "$ENV-registry.repository" -o json)
  url=$(jq -r .payload.url <<<"$registry")
  region=$(jq -r .payload.region <<<"$registry")
  tag="$(git -C "$HERE" log -1 --format=%h -- src)-php$1"
  if aws ecr describe-images --region "$region" --repository-name "${url#*/}" --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    log "reuse $url:$tag"
  else
    log "build and push $url:$tag"
    aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${url%%/*}" >&2
    # A stale saved public.ecr.aws login turns the public base image pull into a 403.
    docker logout public.ecr.aws >/dev/null 2>&1 || true
    docker build --platform linux/arm64 --provenance=false --build-arg "PHP_VERSION=$1" -t "$url:$tag" "$HERE/src" >&2
    docker push "$url:$tag" >&2
  fi
  echo "$url:$tag"
}

cmd_image() {
  confirm "$(deploy_plan)"
  deploy_once "$ENV-registry" ecr-repository
  deploy_once "$ENV-codebase" codebase '.share_with_project = false'
  # The apps pull their images with the codebase's policy.
  # A resource has to be granted to an environment before it can be its default.
  mass resource grant create "$ENV-codebase.codebase" --condition md-project=phpfleet >/dev/null 2>&1 || true
  set_default "$ENV" "$ENV-codebase.codebase"
  local runtime
  for runtime in $(versions | awk '$4 == "runs" { print $3 }' | sort -u); do
    image "${runtime#*@}" >/dev/null
  done
}

# deploy_app <app> <version> <runtime@version>
deploy_app() {
  local app=$1 instance="$ENV-$1" found image current before
  found=$(release "$(bundle_name "$app")" "$2")
  [ -n "$found" ] || die "$app $2 isn't published; run ./deploy.sh publish"
  image=$(image "${3#*@}")
  current=$(mass instance get "$instance" -o json | jq -r '"\(.status) \(.deployedVersion) \(.params.image_uri // "")"')
  if [ "$current" = "PROVISIONED $found $image" ]; then
    log "skip $instance, already runs $found"
    return
  fi
  log "deploy $instance $found"
  mass instance version "$instance@$found" >/dev/null
  before=$(latest_deployment "$instance")
  preset ecs-service |
    jq --arg app "$app" --arg image "$image" \
      '.image_uri = $image | .port = 80 | .spot = true | .subdomain = $app | .health_check_path = "/"' |
    mass instance deploy "$instance" --params - -m "$MESSAGE: $app $2 on ${3/@/ }" >/dev/null || true
  wait_for "$instance" "$before"
}

# The apps deploy three at a time; seven OpenTofu runs at once can time out starting providers.
cmd_deploy() {
  cmd_image
  local app version runtime instance pid pids=() failed=0
  while read -r app version runtime instance; do
    [ "$instance" = runs ] || continue
    deploy_app "$app" "$version" "$runtime" &
    pids+=($!)
    [ "${#pids[@]}" -lt 3 ] && continue
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    pids=()
  done < <(versions)
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || failed=1; done
  [ "$failed" = 0 ] || die "some apps didn't deploy; see above"
}

cmd_teardown() {
  confirm "Decommissions every instance in $ENV, then destroys the $PROJECT project, its components, its runtimes and its app bundles."
  local instance
  if mass environment get "$ENV" >/dev/null 2>&1; then
    for instance in $(mass instance list "$ENV" -o json | jq -r '.[] | select(.status == "PROVISIONED" or .status == "FAILED") | .id' | sort -r); do
      case "$instance" in "$ENV-codebase" | "$ENV-registry") continue ;; esac
      log "decommission $instance"
      mass instance destroy "$instance" --force -m "$MESSAGE: teardown" --follow >/dev/null || true
    done
    for instance in "$ENV-codebase" "$ENV-registry"; do
      [ "$(mass instance get "$instance" -o json 2>/dev/null | jq -r .status)" = INITIALIZED ] && continue
      log "decommission $instance"
      mass instance destroy "$instance" --force -m "$MESSAGE: teardown" --follow >/dev/null || true
    done
  fi
  log "destroy bootstrap.tf"
  (cd "$HERE" && tofu init -input=false >/dev/null && tofu destroy -input=false -auto-approve)
}

case "${1:-}" in
  runtimes) cmd_runtimes ;;
  publish) cmd_publish ;;
  bootstrap) cmd_bootstrap ;;
  image) cmd_image ;;
  deploy) cmd_deploy ;;
  all) cmd_bootstrap && cmd_deploy ;;
  teardown) cmd_teardown ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
