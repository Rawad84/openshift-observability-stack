#!/usr/bin/env bash
# Restore the backend to normal (healthy) mode.
# Clears the degraded flag — subsequent requests will be fast and successful.
set -euo pipefail

NAMESPACE="app-scenario"
BACKEND_ROUTE=$(oc get route backend -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Stop the inject-failure.sh traffic loop first (Ctrl+C in that terminal) before restoring."
echo ""
echo "=== Restoring backend to normal mode ==="
RESULT=$(curl -sf -X POST "https://${BACKEND_ROUTE}/restore")
echo "$RESULT" | python3 -m json.tool

echo ""
echo "=== Confirming status ==="
curl -sf "https://${BACKEND_ROUTE}/status" | python3 -m json.tool

echo ""
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
INTERVAL="${INTERVAL:-0.2}"
echo "=== Sending continuous traffic to confirm recovery (Ctrl+C to stop) ==="
echo "    URL: https://${FRONTEND_ROUTE}/"
echo "    Interval: ${INTERVAL}s"
echo ""
echo "Metrics will reflect recovery within ~1-2 minutes (next scrape + recording rule interval)."
echo ""

COUNT=0
while true; do
  COUNT=$((COUNT + 1))
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${FRONTEND_ROUTE}/")
  echo "  [$(date '+%H:%M:%S')] Request ${COUNT}: HTTP ${STATUS}"
  sleep "${INTERVAL}"
done
