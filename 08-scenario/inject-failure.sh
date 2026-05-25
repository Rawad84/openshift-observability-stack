#!/usr/bin/env bash
# Inject failure into the backend service.
# This simulates database connection pool exhaustion:
#   - Every request to backend /process adds 3s latency (DEGRADED_LATENCY_SECONDS)
#   - 40% of requests return HTTP 503 with "database timeout" error (DEGRADED_ERROR_RATE)
#
# Effect on the signal chain:
#   frontend → (slow/error) → backend → (simulated timeout) → mock-db
#
# Root cause is NOT obvious from frontend metrics alone:
#   - Frontend shows: high latency, high error rate (502/504)
#   - Backend logs show: "Database connection timeout — mock-db did not respond"
#   - Traces show: slow backend span, no mock-db span (request aborted before DB call)
#   - Network flows show: backend→mock-db connection count drops during degraded window
set -euo pipefail

NAMESPACE="app-scenario"
BACKEND_ROUTE=$(oc get route backend -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "=== Injecting failure into backend ==="
RESULT=$(curl -sf -X POST "https://${BACKEND_ROUTE}/inject-failure")
echo "$RESULT" | python3 -m json.tool

echo ""
echo "=== Confirming degraded status ==="
curl -sf "https://${BACKEND_ROUTE}/status" | python3 -m json.tool

echo ""
echo "=== Generating continuous traffic to keep alerts firing ==="
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "Sending 5 requests/sec (Ctrl+C to stop — alerts need ~5 min of sustained traffic to fire)..."
echo "Keep this running while you investigate in the OCP Console."
echo ""

SUCCESS=0; ERRORS=0; COUNT=0
while true; do
  COUNT=$((COUNT + 1))
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 "https://${FRONTEND_ROUTE}/")
  if [[ "$STATUS" == "200" ]]; then
    SUCCESS=$((SUCCESS + 1))
  else
    ERRORS=$((ERRORS + 1))
  fi
  printf "\r  Requests: %d  |  OK: %d  |  Errors: %d  |  Error rate: %d%%" \
    "$COUNT" "$SUCCESS" "$ERRORS" "$((ERRORS * 100 / COUNT))"
  sleep 0.2
done
