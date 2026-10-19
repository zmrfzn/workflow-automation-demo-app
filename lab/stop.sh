#!/bin/bash
# Pause the traffic between challenges: stop loadgen only. shop-api, the controller and
# Redis keep running. ./lab/start.sh (or `docker compose start loadgen`) resumes it.
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose stop loadgen
echo "Traffic stopped. Run ./lab/start.sh to resume it."
