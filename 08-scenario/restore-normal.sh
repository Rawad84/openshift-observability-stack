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
echo "=== Sending 5 requests to confirm recovery ==="
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
for i in $(seq 1 5); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${FRONTEND_ROUTE}/")
  echo "  Request $i: HTTP $STATUS"
  sleep 0.5
done

echo ""
echo "System restored to NORMAL mode."
echo "Metrics will reflect recovery within ~1-2 minutes (next scrape + recording rule interval)."
