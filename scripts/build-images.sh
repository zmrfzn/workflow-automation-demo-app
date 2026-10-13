#!/bin/bash
# Build the v1 and v2 app images plus the controller and loadgen locally.
# Usage: scripts/build-images.sh [registry-prefix]   (default: ghcr.io/zmrfzn)
set -euo pipefail

cd "$(dirname "$0")/.."
REG="${1:-ghcr.io/zmrfzn}"
LAB_TAG="${LAB_TAG:-1}"

for rel in v1 v2; do
  docker build --build-arg RELEASE="$rel" -t "$REG/workflow-automation-app:$rel" app
done
docker build -t "$REG/workflow-automation-controller:$LAB_TAG" controller
docker build -t "$REG/workflow-automation-loadgen:$LAB_TAG" loadgen
docker images "$REG/*"
