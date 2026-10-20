#!/bin/bash
# Print the values Workflow Automation needs to call the controller: its public URL and the token.
# The URL is the VM's own hostname, not the Instruqt service-tab URL: that one needs a logged-in
# Instruqt session and answers New Relic with a 401. HTTPS on 5443 when the certificate is installed.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env is missing. Run ./lab/wire-credentials.sh first." >&2; exit 1; }
[ -n "${_SANDBOX_ID:-}" ] || { echo "_SANDBOX_ID is not set: this only works on the Instruqt VM." >&2; exit 1; }

HOST="wfa-infra.${_SANDBOX_ID}.instruqt.io"
if [ -s /etc/ssl/certs/sandbox.crt ] && docker ps --format '{{.Names}}' | grep -qx wfa-tls; then
    URL="https://${HOST}:5443"
else
    URL="http://${HOST}:5001"
    echo "Note: HTTPS is not running, so this is the plain HTTP address. Run ./lab/start.sh to enable it." >&2
fi

echo "Controller URL: ${URL}"
echo "Token:          $(grep -E '^ROLLBACK_SECRET=' .env | cut -d= -f2-)"
