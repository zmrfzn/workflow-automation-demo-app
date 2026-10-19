#!/bin/bash
# Print the values Workflow Automation needs to call the controller: its public URL and the token.
# The URL follows the Instruqt service-tab pattern for host wfa-infra, port 5001.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env is missing. Run ./lab/wire-credentials.sh first." >&2; exit 1; }
[ -n "${_SANDBOX_ID:-}" ] || { echo "_SANDBOX_ID is not set: this only works on the Instruqt VM." >&2; exit 1; }

echo "Controller URL: https://wfa-infra-5001-${_SANDBOX_ID}.env.play.instruqt.com"
echo "Token:          $(grep -E '^ROLLBACK_SECRET=' .env | cut -d= -f2-)"
