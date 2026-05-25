#!/usr/bin/env bash
# End-to-end validation: checks all components of the observability scenario.
# Run after deploying everything to confirm the full signal chain is working.
set -uo pipefail

NAMESPACE="app-scenario"
PASS=0; FAIL=0; WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_warn() {
  local desc="$1"; shift
  if "$@" &>/dev/null 2>&1; then pass "$desc"; else warn "$desc"; fi
}

echo "========================================"
echo "  Observability Scenario Validation"
echo "========================================"

# ── Operators ────────────────────────────────────────────────────────────────
echo ""
echo "── Operators ────────────────────────────────────────────────────────────"
check      "Cluster Observability Operator CRD"  oc get crd monitoringstacks.monitoring.rhobs
check      "Loki Operator CRD"                   oc get crd lokistacks.loki.grafana.com
check      "Logging Operator CRD"                oc get crd clusterlogforwarders.observability.openshift.io
check      "Tempo Operator CRD"                  oc get crd tempomonolithics.tempo.grafana.com
check      "OTel Operator CRD"                   oc get crd opentelemetrycollectors.opentelemetry.io
check_warn "NetObserv Operator CRD"              oc get crd flowcollectors.flows.netobserv.io
check_warn "Grafana Operator CRD"                oc get crd grafanas.grafana.integreatly.org

# ── App pods ─────────────────────────────────────────────────────────────────
echo ""
echo "── App pods ─────────────────────────────────────────────────────────────"
check "frontend pod running"    oc get pod -n "$NAMESPACE" -l app=frontend --field-selector=status.phase=Running
check "backend pod running"     oc get pod -n "$NAMESPACE" -l app=backend --field-selector=status.phase=Running
check "mock-db pod running"     oc get pod -n "$NAMESPACE" -l app=mock-db --field-selector=status.phase=Running
check "otel-collector running"  oc get pod -n "$NAMESPACE" -l app=otel-collector --field-selector=status.phase=Running

# ── Prometheus / MonitoringStack ─────────────────────────────────────────────
echo ""
echo "── Prometheus / MonitoringStack ─────────────────────────────────────────"
check "MonitoringStack exists"    oc get monitoringstack app-scenario-stack -n "$NAMESPACE"
check "Prometheus pod running"    oc get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus" --field-selector=status.phase=Running
check "ServiceMonitor frontend"   oc get servicemonitor frontend -n "$NAMESPACE"
check "ServiceMonitor backend"    oc get servicemonitor backend -n "$NAMESPACE"
check "ServiceMonitor mock-db"    oc get servicemonitor mock-db -n "$NAMESPACE"
check "PrometheusRule (alerts)"   oc get prometheusrule app-scenario-alerts -n "$NAMESPACE"
check "PrometheusRule (recording)" oc get prometheusrule app-scenario-recording -n "$NAMESPACE"

# ── User Workload Monitoring ─────────────────────────────────────────────────
echo ""
echo "── User Workload Monitoring ─────────────────────────────────────────────"
check "UWM enabled (cluster-monitoring-config)"  oc get configmap cluster-monitoring-config -n openshift-monitoring
check "UWM Prometheus pod running"               oc get pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running
check "UWM ServiceMonitor frontend"              oc get servicemonitor frontend -n "$NAMESPACE"
check "UWM ServiceMonitor backend"               oc get servicemonitor backend -n "$NAMESPACE"

# ── Logging / LokiStack ──────────────────────────────────────────────────────
echo ""
echo "── Logging / LokiStack ──────────────────────────────────────────────────"
check "LokiStack exists"          oc get lokistack logging-loki -n openshift-logging
check "LokiStack ingester running" oc get pod -n openshift-logging -l app.kubernetes.io/component=ingester --field-selector=status.phase=Running
check "LokiStack gateway running"  oc get pod -n openshift-logging -l app.kubernetes.io/component=gateway --field-selector=status.phase=Running
check "ClusterLogForwarder"        oc get clusterlogforwarder app-scenario -n "$NAMESPACE"
check "Loki OBC Bound"             bash -c "oc get obc loki-bucket -n openshift-logging -o jsonpath='{.status.phase}' | grep -q Bound"
check "lokistack-storage secret"   oc get secret lokistack-storage -n openshift-logging

# ── Tracing / Tempo ──────────────────────────────────────────────────────────
echo ""
echo "── Tracing / Tempo ──────────────────────────────────────────────────────"
check "TempoMonolithic exists"     oc get tempomonolithic platform -n openshift-tracing
check "Tempo gateway running"      oc get pod -n openshift-tracing -l app.kubernetes.io/component=gateway --field-selector=status.phase=Running
check "Tempo OBC Bound"            bash -c "oc get obc tempo-bucket -n openshift-tracing -o jsonpath='{.status.phase}' | grep -q Bound"
check "tempo-storage secret"       oc get secret tempo-storage -n openshift-tracing
check "OTel Collector service"     oc get svc otel-collector -n "$NAMESPACE"

# ── Network Observability (optional) ────────────────────────────────────────
echo ""
echo "── Network Observability (optional) ────────────────────────────────────"
if oc get crd flowcollectors.flows.netobserv.io &>/dev/null 2>&1; then
  check      "FlowCollector exists"         oc get flowcollector cluster
  check      "NetObserv LokiStack exists"   oc get lokistack loki -n netobserv
  check      "NetObserv LokiStack ingester" oc get pod -n netobserv -l app.kubernetes.io/component=ingester --field-selector=status.phase=Running
  check      "NetObserv OBC Bound"          bash -c "oc get obc loki-bucket -n netobserv -o jsonpath='{.status.phase}' | grep -q Bound"
else
  warn "Network Observability Operator not installed — skipping netflow checks"
fi

# ── UIPlugins ────────────────────────────────────────────────────────────────
echo ""
echo "── UIPlugins ────────────────────────────────────────────────────────────"
check      "Monitoring UIPlugin"            oc get uiplugin monitoring
check      "Distributed Tracing UIPlugin"   oc get uiplugin distributed-tracing
check      "Logging UIPlugin"               oc get uiplugin logging
check      "Troubleshooting Panel UIPlugin" oc get uiplugin troubleshooting-panel
check_warn "NetObserv UIPlugin"             oc get consoleplugin netobserv-plugin

# ── Routes and app connectivity ──────────────────────────────────────────────
echo ""
echo "── Routes and app connectivity ──────────────────────────────────────────"
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
BACKEND_ROUTE=$(oc get route backend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
check "Frontend route exists"  [[ -n "$FRONTEND_ROUTE" ]]
check "Backend route exists"   [[ -n "$BACKEND_ROUTE" ]]
if [[ -n "$FRONTEND_ROUTE" ]]; then
  check "Frontend /health returns 200"  bash -c "curl -skf 'https://${FRONTEND_ROUTE}/health' | grep -q ok"
  check "Frontend / returns 200"        bash -c "curl -skf 'https://${FRONTEND_ROUTE}/' | grep -q frontend"
fi
if [[ -n "$BACKEND_ROUTE" ]]; then
  check "Backend /health returns 200"  bash -c "curl -skf 'https://${BACKEND_ROUTE}/health' | grep -q ok"
  check "Backend not degraded"         bash -c "curl -skf 'https://${BACKEND_ROUTE}/status' | python3 -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if not d.get('degraded') else 1)\""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Results: ${PASS} passed  ${FAIL} failed  ${WARN} warnings"
echo "========================================"
if [[ $FAIL -eq 0 ]]; then
  echo "  All required checks passed."
  [[ $WARN -gt 0 ]] && echo "  Optional components not deployed: see warnings above."
  echo ""
  echo "  Run: ./08-scenario/inject-failure.sh  to start the scenario"
else
  echo "  Fix failing checks before running the scenario."
fi
exit $FAIL
