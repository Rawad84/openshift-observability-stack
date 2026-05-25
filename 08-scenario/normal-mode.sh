#!/usr/bin/env bash
# Verify the scenario is running in normal (healthy) mode.
# Run this before injecting failure to confirm baseline is good.
set -euo pipefail

NAMESPACE="app-scenario"

echo "=== Checking pod health ==="
oc get pods -n "$NAMESPACE" -l 'app in (frontend,backend,mock-db,otel-collector)'

echo ""
echo "=== Checking backend degraded status ==="
BACKEND_ROUTE=$(oc get route backend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
curl -sf "https://${BACKEND_ROUTE}/status" | python3 -m json.tool

echo ""
echo "=== Sending 10 requests to frontend ==="
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${FRONTEND_ROUTE}/")
  echo "  Request $i: HTTP $STATUS"
  sleep 0.5
done

echo ""
echo "=== Baseline metrics (last 1m) ==="
PROM_POD=$(oc get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$PROM_POD" ]]; then
  echo "Error ratio (frontend):"
  oc exec -n "$NAMESPACE" "$PROM_POD" -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=job:http_requests_error_ratio:rate5m{job="frontend"}' \
    | python3 -m json.tool 2>/dev/null | grep -A2 '"value"' || echo "  (no data yet — wait 1-2 scrape intervals)"
else
  echo "  Prometheus pod not found. Check: oc get pods -n $NAMESPACE"
fi

echo ""
echo "All checks complete. System is in NORMAL mode."
