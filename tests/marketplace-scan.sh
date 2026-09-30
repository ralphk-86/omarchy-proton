#!/usr/bin/env bash
# The marketplace's own static security scan, run locally before submitting.
# A plugin with a root part can at best reach "review-required" with no
# findings; any finding, or a scan that errors out, blocks a listing.
#   tests/marketplace-scan.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKET="${1:-${MARKETPLACE_DIR:-}}"
if [[ -z "$MARKET" || ! -f "$MARKET/scripts/security-baseline-analysis.mjs" ]]; then
  cat <<TXT
usage: tests/marketplace-scan.sh <path to a checkout of omacom/omarchy-plugin-marketplace>

This script does not download anything. Get the scanner yourself, look at what
you got, then point this script at it.
TXT
  exit 2
fi
command -v node >/dev/null 2>&1 || { echo "needs node"; exit 1; }
echo "Marketplace security baseline:"
node "$REPO/tests/marketplace-scan.mjs" "$MARKET" "$REPO"
