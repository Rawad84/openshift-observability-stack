#!/usr/bin/env bash
# Build all three app images and deploy the full observability scenario.
# Run from the root of the observability_scenario directory.
#
# Usage:
#   ./build-and-deploy.sh              # full deploy
#   ./build-and-deploy.sh --build-only # build images only, do not deploy
#   ./build-and-deploy.sh --skip-build # skip image builds, apply manifests only
#
# Environment overrides:
#   GRAFANA_NS=<ns>            Namespace where Grafana Operator is installed (default: openshift-operators)
#   STORAGE_CLASS=<name>       PVC StorageClass for LokiStack/Tempo volumes (default: cluster default)
#   OBC_STORAGE_CLASS=<name>   StorageClass for NooBaa OBC provisioning (default: openshift-storage.noobaa.io)
set -euo pipefail

NAMESPACE="app-scenario"
export GRAFANA_NS="${GRAFANA_NS:-openshift-operators}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ONLY=false
SKIP_BUILD=false

for arg in "$@"; do
  case $arg in
    --build-only) BUILD_ONLY=true ;;
    --skip-build) SKIP_BUILD=true ;;
  esac
done

# ── Pre-flight: StorageClass detection ───────────────────────────────────────
export STORAGE_CLASS="${STORAGE_CLASS:-$(oc get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')}"
if [[ -z "$STORAGE_CLASS" ]]; then
  echo "ERROR: No default StorageClass found. Set STORAGE_CLASS=<name> and re-run."
  exit 1
fi

export OBC_STORAGE_CLASS="${OBC_STORAGE_CLASS:-openshift-storage.noobaa.io}"
if ! oc get storageclass "$OBC_STORAGE_CLASS" &>/dev/null; then
  echo "ERROR: OBC StorageClass '$OBC_STORAGE_CLASS' not found."
  echo "       This scenario requires ODF with NooBaa for S3 bucket provisioning."
  echo "       Override with: OBC_STORAGE_CLASS=<name> ./build-and-deploy.sh"
  exit 1
fi

echo "StorageClass (PVC): $STORAGE_CLASS"
echo "StorageClass (OBC): $OBC_STORAGE_CLASS"
echo ""

# ── Step 1: Namespace ─────────────────────────────────────────────────────────
echo "=== Step 1: Namespace ==="
oc apply -f "$SCRIPT_DIR/01-namespaces/namespace.yaml"
oc project "$NAMESPACE"

# ── Step 2: Build app images ──────────────────────────────────────────────────
if [[ "$SKIP_BUILD" != "true" ]]; then
  echo ""
  echo "=== Step 2: Build app images ==="
  if ! oc get pods -n openshift-image-registry -l docker-registry=default \
      --field-selector=status.phase=Running 2>/dev/null | grep -q "Running"; then
    echo "ERROR: OpenShift internal image registry is not running."
    echo "       Enable it with:"
    echo "         oc patch configs.imageregistry.operator.openshift.io cluster \\"
    echo "           --type merge --patch '{\"spec\":{\"managementState\":\"Managed\",\"storage\":{\"emptyDir\":{}}}}'"
    exit 1
  fi
  oc apply -f "$SCRIPT_DIR/02-apps/imagestreams.yaml"
  oc apply -f "$SCRIPT_DIR/02-apps/buildconfigs.yaml"

  for app in frontend backend mock-db; do
    if oc get imagestreamtag "${app}:latest" -n "$NAMESPACE" &>/dev/null; then
      echo "  $app image already exists — skipping build."
    else
      echo "  Building $app..."
      oc start-build "$app" --from-dir="$SCRIPT_DIR/apps/$app" --follow -n "$NAMESPACE"
    fi
  done
fi

[[ "$BUILD_ONLY" == "true" ]] && { echo "Build complete (--build-only)."; exit 0; }

# ── Step 3: Deploy applications ───────────────────────────────────────────────
echo ""
echo "=== Step 3: Deploy applications ==="
oc apply -f "$SCRIPT_DIR/02-apps/pvc.yaml"
oc apply -f "$SCRIPT_DIR/02-apps/deployments.yaml"
oc apply -f "$SCRIPT_DIR/02-apps/services.yaml"
oc apply -f "$SCRIPT_DIR/02-apps/routes.yaml"

# ── Step 4: MonitoringStack + UWM ────────────────────────────────────────────
echo ""
echo "=== Step 4: MonitoringStack + User Workload Monitoring ==="
oc apply -f "$SCRIPT_DIR/03-observability/monitoringstack.yaml"
oc apply -f "$SCRIPT_DIR/03-observability/servicemonitors.yaml"
oc apply -f "$SCRIPT_DIR/03-observability/prometheusrules.yaml"
oc apply -f "$SCRIPT_DIR/03-observability/prometheus-route.yaml"

# UWM exposes app-scenario metrics and alerts in OCP Console → Observe
# and is required for the Troubleshooting Panel (korrel8r) to correlate signals.
oc apply -f "$SCRIPT_DIR/03-observability/uwm-config.yaml"
echo "Waiting for UWM Prometheus to start..."
for i in $(seq 1 24); do
  oc get pods -n openshift-user-workload-monitoring 2>/dev/null \
    | grep -q "prometheus-user-workload" && { echo "  UWM ready."; break; }
  echo "  ($i/24) waiting 5s..."
  sleep 5
done
oc apply -f "$SCRIPT_DIR/03-observability/uwm-servicemonitors.yaml"
oc apply -f "$SCRIPT_DIR/03-observability/uwm-prometheusrules.yaml"

# ── Step 5: Grafana (optional) ────────────────────────────────────────────────
echo ""
echo "=== Step 5: Grafana (optional — requires Grafana Operator) ==="
if oc get crd grafanas.grafana.integreatly.org &>/dev/null; then
  echo "  Grafana namespace: $GRAFANA_NS"
  envsubst '$GRAFANA_NS' < "$SCRIPT_DIR/03-observability/grafana.yaml"            | oc apply -f -
  echo "  Waiting for Grafana pod to be ready..."
  oc rollout status deployment/grafana-a-deployment -n "$GRAFANA_NS" --timeout=120s 2>/dev/null || true
  envsubst '$GRAFANA_NS' < "$SCRIPT_DIR/03-observability/grafana-datasource.yaml" | oc apply -f -

  # Platform Prometheus datasource — reads cAdvisor metrics from Thanos Querier
  # Apply SA and ClusterRoleBinding first (no token needed yet)
  envsubst '$GRAFANA_NS' < "$SCRIPT_DIR/03-observability/grafana-platform-datasource.yaml" | \
    grep -v "GrafanaDatasource" | oc apply -f - 2>/dev/null || true

  echo "  Waiting for platform Prometheus SA token to be populated..."
  for i in $(seq 1 12); do
    export PLATFORM_TOKEN=$(oc get secret grafana-platform-prometheus-token -n "$GRAFANA_NS" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    [[ -n "$PLATFORM_TOKEN" ]] && { echo "  Token ready."; break; }
    echo "  ($i/12) waiting 5s..."
    sleep 5
  done
  [[ -z "$PLATFORM_TOKEN" ]] && { echo "ERROR: SA token not populated."; exit 1; }

  # Embed the real token into the CR — operator reconciles from CR, so token stays correct
  envsubst '$GRAFANA_NS $PLATFORM_TOKEN' < "$SCRIPT_DIR/03-observability/grafana-platform-datasource.yaml" | oc apply -f -

  envsubst '$GRAFANA_NS' < "$SCRIPT_DIR/03-observability/grafana-dashboard.yaml"  | oc apply -f -
else
  echo "  Grafana Operator not installed — skipping."
  echo "  Install 'Grafana Operator' from OperatorHub and re-run with --skip-build."
fi

# ── Step 6: Tracing — Tempo ───────────────────────────────────────────────────
echo ""
echo "=== Step 6: Tracing — TempoMonolithic ==="
TEMPO_NS="openshift-tracing"
oc apply -f "$SCRIPT_DIR/05-tracing/namespace.yaml"

envsubst '$OBC_STORAGE_CLASS' < "$SCRIPT_DIR/05-tracing/objectbucketclaim.yaml" | oc apply -f -
echo "Waiting for OBC tempo-bucket to be Bound..."
for i in $(seq 1 36); do
  PHASE=$(oc get obc tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "$PHASE" == "Bound" ]] && { echo "  OBC Bound."; break; }
  echo "  ($i/36) OBC phase: $PHASE — waiting 5s..."
  sleep 5
done
PHASE=$(oc get obc tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
[[ "$PHASE" != "Bound" ]] && { echo "ERROR: OBC not Bound. Check: oc get obc tempo-bucket -n $TEMPO_NS"; exit 1; }

ACCESS_KEY=$(oc get secret tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
BUCKET_NAME=$(oc get configmap tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get configmap tempo-bucket -n "$TEMPO_NS" -o jsonpath='{.data.BUCKET_PORT}')
oc create secret generic tempo-storage -n "$TEMPO_NS" \
  --from-literal=endpoint="https://${BUCKET_HOST}:${BUCKET_PORT}" \
  --from-literal=bucket="$BUCKET_NAME" \
  --from-literal=access_key_id="$ACCESS_KEY" \
  --from-literal=access_key_secret="$SECRET_KEY" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f "$SCRIPT_DIR/05-tracing/tempo-s3-ca-configmap.yaml"
echo "Waiting for S3 CA bundle injection..."
for i in $(seq 1 12); do
  LEN=$(oc get configmap tempo-s3-ca -n "$TEMPO_NS" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | wc -c)
  [[ "$LEN" -gt 100 ]] && { echo "  CA bundle injected."; break; }
  sleep 5
done

envsubst '$STORAGE_CLASS' < "$SCRIPT_DIR/05-tracing/tempomonolithic.yaml" | oc apply -f -

# ── Step 7: Tracing — OTel Collector ─────────────────────────────────────────
echo ""
echo "=== Step 7: Tracing — OTel Collector ==="
oc apply -f "$SCRIPT_DIR/05-tracing/otel-serviceaccount.yaml"
oc apply -f "$SCRIPT_DIR/05-tracing/otel-rbac.yaml"

oc apply -f "$SCRIPT_DIR/05-tracing/otel-ca-configmap.yaml"
echo "Waiting for OTel CA bundle injection..."
for i in $(seq 1 12); do
  LEN=$(oc get configmap otel-tempo-ca -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | wc -c)
  [[ "$LEN" -gt 100 ]] && { echo "  CA bundle injected."; break; }
  sleep 5
done
oc apply -f "$SCRIPT_DIR/05-tracing/otel-collector.yaml"

# ── Step 8: Logging — LokiStack ───────────────────────────────────────────────
echo ""
echo "=== Step 8: Logging — LokiStack ==="
LOG_NS="openshift-logging"

if ! oc get crd lokistacks.loki.grafana.com &>/dev/null; then
  echo "ERROR: Loki Operator not installed — LokiStack CRD not found."
  echo "       Install 'Loki Operator' from OperatorHub and re-run."
  exit 1
fi
if ! oc get crd clusterlogforwarders.observability.openshift.io &>/dev/null; then
  echo "ERROR: Logging Operator not installed — ClusterLogForwarder CRD not found."
  echo "       Install 'Red Hat OpenShift Logging' from OperatorHub and re-run."
  exit 1
fi

envsubst '$OBC_STORAGE_CLASS' < "$SCRIPT_DIR/04-logging/objectbucketclaim.yaml" | oc apply -f -
echo "Waiting for OBC loki-bucket to be Bound..."
for i in $(seq 1 36); do
  PHASE=$(oc get obc loki-bucket -n "$LOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "$PHASE" == "Bound" ]] && { echo "  OBC Bound."; break; }
  echo "  ($i/36) OBC phase: $PHASE — waiting 5s..."
  sleep 5
done
PHASE=$(oc get obc loki-bucket -n "$LOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
[[ "$PHASE" != "Bound" ]] && { echo "ERROR: OBC not Bound. Check: oc get obc loki-bucket -n $LOG_NS"; exit 1; }

ACCESS_KEY=$(oc get secret loki-bucket -n "$LOG_NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret loki-bucket -n "$LOG_NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
BUCKET_NAME=$(oc get configmap loki-bucket -n "$LOG_NS" -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap loki-bucket -n "$LOG_NS" -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get configmap loki-bucket -n "$LOG_NS" -o jsonpath='{.data.BUCKET_PORT}')
oc create secret generic lokistack-storage -n "$LOG_NS" \
  --from-literal=access_key_id="$ACCESS_KEY" \
  --from-literal=access_key_secret="$SECRET_KEY" \
  --from-literal=bucketnames="$BUCKET_NAME" \
  --from-literal=endpoint="http://${BUCKET_HOST}:80" \
  --dry-run=client -o yaml | oc apply -f -

envsubst '$STORAGE_CLASS' < "$SCRIPT_DIR/04-logging/lokistack.yaml" | oc apply -f -

# ── Step 9: Logging — ClusterLogForwarder ─────────────────────────────────────
echo ""
echo "=== Step 9: Logging — ClusterLogForwarder ==="
oc apply -f "$SCRIPT_DIR/04-logging/rbac.yaml"

oc apply -f "$SCRIPT_DIR/04-logging/loki-ca-configmap.yaml"
echo "Waiting for Loki CA bundle injection..."
for i in $(seq 1 12); do
  LEN=$(oc get configmap loki-ca -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | wc -c)
  [[ "$LEN" -gt 100 ]] && { echo "  CA bundle injected."; break; }
  sleep 5
done
oc apply -f "$SCRIPT_DIR/04-logging/clusterlogforwarder.yaml"

# ── Step 10: Network Observability (optional) ─────────────────────────────────
echo ""
echo "=== Step 10: Network Observability (optional — requires NetObserv Operator) ==="
NETOBSERV_NS="netobserv"

if ! oc get crd flowcollectors.flows.netobserv.io &>/dev/null; then
  echo "  Network Observability Operator not installed — skipping."
  echo "  Install 'Network Observability' from OperatorHub and re-run with --skip-build."
else
  # Detect the namespace where NetObserv components run from the existing FlowCollector,
  # or fall back to the NETOBSERV_NS override (default: netobserv).
  NETOBSERV_NS="${NETOBSERV_NS:-$(oc get flowcollector cluster -o jsonpath='{.spec.namespace}' 2>/dev/null || echo "netobserv")}"
  if ! oc get namespace "$NETOBSERV_NS" &>/dev/null; then
    echo "  Creating namespace $NETOBSERV_NS..."
    oc create namespace "$NETOBSERV_NS"
  fi
  echo "  NetObserv namespace: $NETOBSERV_NS"

  export NETOBSERV_NS
  envsubst '$OBC_STORAGE_CLASS $NETOBSERV_NS' < "$SCRIPT_DIR/06-netflow/netobserv-loki-obc.yaml" | oc apply -f -
  echo "Waiting for OBC loki-bucket to be Bound..."
  for i in $(seq 1 36); do
    PHASE=$(oc get obc loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    [[ "$PHASE" == "Bound" ]] && { echo "  OBC Bound."; break; }
    echo "  ($i/36) OBC phase: $PHASE — waiting 5s..."
    sleep 5
  done
  PHASE=$(oc get obc loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "$PHASE" != "Bound" ]] && { echo "ERROR: OBC not Bound. Check: oc get obc loki-bucket -n $NETOBSERV_NS"; exit 1; }

  ACCESS_KEY=$(oc get secret loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
  SECRET_KEY=$(oc get secret loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
  BUCKET_NAME=$(oc get configmap loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.data.BUCKET_NAME}')
  BUCKET_HOST=$(oc get configmap loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.data.BUCKET_HOST}')
  BUCKET_PORT=$(oc get configmap loki-bucket -n "$NETOBSERV_NS" -o jsonpath='{.data.BUCKET_PORT}')
  oc create secret generic loki-storage -n "$NETOBSERV_NS" \
    --from-literal=access_key_id="$ACCESS_KEY" \
    --from-literal=access_key_secret="$SECRET_KEY" \
    --from-literal=bucketnames="$BUCKET_NAME" \
    --from-literal=endpoint="http://${BUCKET_HOST}:80" \
    --dry-run=client -o yaml | oc apply -f -

  envsubst '$STORAGE_CLASS $NETOBSERV_NS' < "$SCRIPT_DIR/06-netflow/netobserv-lokistack.yaml" | oc apply -f -

  echo "Waiting for NetObserv LokiStack to be Ready (up to 10 min)..."
  for i in $(seq 1 60); do
    LOKI_STATUS=$(oc get lokistack loki -n "$NETOBSERV_NS" -o json 2>/dev/null \
      | python3 -c "
import sys, json
obj = json.load(sys.stdin)
for c in obj.get('status', {}).get('conditions', []):
    if c.get('type') == 'Ready':
        print(c.get('status', 'False'))
        sys.exit(0)
print('False')
" 2>/dev/null || echo "False")
    [[ "$LOKI_STATUS" == "True" ]] && { echo "  LokiStack Ready."; break; }
    if [[ "$i" -eq 60 ]]; then
      echo "ERROR: LokiStack not Ready after 10 minutes. Check: oc describe lokistack loki -n $NETOBSERV_NS"
      exit 1
    fi
    echo "  ($i/60) not ready yet — waiting 10s..."
    sleep 10
  done

  if oc get flowcollector cluster &>/dev/null; then
    echo "  FlowCollector exists — patching Loki target..."
    oc patch flowcollector cluster --type=merge \
      -p '{"spec":{"loki":{"mode":"LokiStack","lokiStack":{"name":"loki","namespace":"netobserv"}}}}'
  else
    oc apply -f "$SCRIPT_DIR/06-netflow/flowcollector.yaml"
  fi
  echo "  FlowCollector applied."
fi

# ── Step 11: UIPlugins ────────────────────────────────────────────────────────
echo ""
echo "=== Step 11: UIPlugins ==="
oc apply -f "$SCRIPT_DIR/07-uiplugins/troubleshooting-panel-uiplugin.yaml"
oc apply -f "$SCRIPT_DIR/04-logging/logging-uiplugin.yaml"
oc apply -f "$SCRIPT_DIR/05-tracing/distributed-tracing-uiplugin.yaml"

# ── Wait for app pods ─────────────────────────────────────────────────────────
echo ""
echo "=== Waiting for app pods to be ready ==="
oc rollout status deployment/frontend      -n "$NAMESPACE" --timeout=120s
oc rollout status deployment/backend       -n "$NAMESPACE" --timeout=120s
oc rollout status deployment/mock-db       -n "$NAMESPACE" --timeout=120s
oc rollout status deployment/otel-collector -n "$NAMESPACE" --timeout=120s

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "=== Deploy complete ==="
echo ""
echo "Frontend URL: https://${FRONTEND_ROUTE}/"
echo ""
echo "Next steps:"
echo "  1. Run: ./08-scenario/validate-all.sh"
echo "  2. Run: ./08-scenario/inject-failure.sh   (to start the scenario)"
echo "  3. Investigate in OCP Console → Observe → Dashboards / Logs / Traces / Network Traffic"
echo "  4. Run: ./08-scenario/restore-normal.sh   (when done)"
