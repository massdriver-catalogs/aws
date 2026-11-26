#!/usr/bin/env bash
# Publishes the official Massdriver resource types from
# massdriver-cloud/massdriver-resource-types, so the organization has every
# platform feature they turn on, not just the ones this catalog's bundles use.
set -euo pipefail

TYPES=(
  massdriver-service-account
  massdriver-kubernetes-cluster
  massdriver-wireguard-tunnel
)
SOURCE=${MASSDRIVER_RESOURCE_TYPES_REPO:-https://github.com/massdriver-cloud/massdriver-resource-types.git}

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
git clone --quiet --depth 1 "$SOURCE" "$dir"

for type in "${TYPES[@]}"; do
  mass repository create "$type" -t resource-type >/dev/null 2>&1 || true
  # A published version can't change, so one the organization already has is current.
  if out=$(mass resource-type publish "$dir/$type" 2>&1); then
    echo "$out"
  elif grep -q "already exists" <<<"$out"; then
    echo "$type is already published"
  else
    echo "$out" >&2
    exit 1
  fi
done
