#!/usr/bin/env bash
# Drive continuous traffic to the frontend in normal (healthy) mode.
# Runs indefinitely until interrupted with Ctrl+C.
# Usage:
#   ./08-scenario/normal-mode.sh          # default: 1 request/second
#   INTERVAL=2 ./08-scenario/normal-mode.sh  # 1 request every 2 seconds
set -euo pipefail

NAMESPACE="app-scenario"
INTERVAL="${INTERVAL:-0.2}"

echo "=== Checking pod health ==="
oc get pods -n "$NAMESPACE" -l 'app in (frontend,backend,mock-db,otel-collector)'

echo ""
echo "=== Checking backend degraded status ==="
BACKEND_ROUTE=$(oc get route backend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
curl -sf "https://${BACKEND_ROUTE}/status" | python3 -m json.tool

echo ""
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "=== Sending continuous traffic to frontend (Ctrl+C to stop) ==="
echo "    URL: https://${FRONTEND_ROUTE}/"
echo "    Interval: ${INTERVAL}s"
echo ""

COUNT=0
while true; do
  COUNT=$((COUNT + 1))
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${FRONTEND_ROUTE}/")
  echo "  [$(date '+%H:%M:%S')] Request ${COUNT}: HTTP ${STATUS}"
  sleep "${INTERVAL}"
done
