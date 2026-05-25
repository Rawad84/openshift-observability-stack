# Prerequisites

Install and verify these before deploying the scenario.

## 1. Cluster Observability Operator (COO)

```bash
# Check if installed
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability

# Install via OperatorHub: search "Cluster Observability Operator", stable channel
# Or apply manifests from the openshift-coo-observability repo (00-installation/)
```

## 2. Red Hat OpenShift Logging + Loki Operator

Required for: Observe → Logs, ClusterLogForwarder, Troubleshooting Panel (full functionality)

These are **two separate operators** — both must be installed:

| Operator | OperatorHub name | Provides |
|---|---|---|
| Logging Operator | `Red Hat OpenShift Logging` | ClusterLogForwarder, log collection via Vector |
| Loki Operator | `Loki Operator` (Red Hat) | LokiStack CRD, log storage |

```bash
# Verify both are installed
oc get csv -n openshift-logging | grep -E 'cluster-logging|loki'

# Verify LokiStack CRD is registered (comes from Loki Operator, not Logging Operator)
oc get crd lokistacks.loki.grafana.com
```

## 3. Tempo Operator + Red Hat build of OpenTelemetry Operator

Required for: Observe → Traces, distributed trace correlation

These are **two separate operators** — both must be installed:

| Operator | OperatorHub name | Provides |
|---|---|---|
| Tempo Operator | `Tempo Operator` (Red Hat) | TempoMonolithic CRD, trace storage |
| OpenTelemetry Operator | `Red Hat build of OpenTelemetry` | OTel Collector, trace ingestion from apps |

```bash
# Verify both are installed
oc get csv -A | grep -E 'tempo|opentelemetry'

# Verify CRDs are registered
oc get crd tempomonolithics.tempo.grafana.com
oc get crd opentelemetrycollectors.opentelemetry.io
```

## 4. Network Observability Operator

Required for: Observe → Network Traffic, FlowCollector, Troubleshooting Panel (network flows)

```bash
# Install Network Observability Operator from OperatorHub
# FlowCollector requires LokiStack for flow storage
oc get crd | grep flowcollector
oc get flowcollector cluster
```

## 5. OpenShift Data Foundation (ODF)

Required for: all S3 object storage (Loki logging, Loki netobserv, Tempo traces).

The scenario uses `ObjectBucketClaim` (OBC) resources backed by NooBaa, which ships with ODF. After an OBC is bound, NooBaa automatically creates a Secret and ConfigMap in the same namespace containing the bucket credentials. The deploy script reads those directly:

| Resource | Keys consumed |
|---|---|
| Secret `loki-bucket` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| ConfigMap `loki-bucket` | `BUCKET_NAME`, `BUCKET_HOST`, `BUCKET_PORT` |

This credential extraction is tightly coupled to the OBC/NooBaa format. **External S3 is not supported by the script as-is.** If you want to use an external S3 bucket instead you would need to pre-create the storage secrets manually in the format each operator expects, and skip the OBC steps.

```bash
# Check ODF is installed
oc get csv -n openshift-storage | grep odf

# Check NooBaa is running
oc get noobaa -n openshift-storage

# Check the OBC provisioner StorageClass exists
oc get storageclass openshift-storage.noobaa.io
```

## 6. Grafana Operator (optional)

Required for: Grafana dashboards (`03-observability/grafana.yaml`, `grafana-datasource.yaml`, `grafana-dashboard.yaml`)

The `build-and-deploy.sh` script skips Grafana silently if the operator is not installed — install it first or the dashboards will not be created.

```bash
# Install "Grafana Operator" from OperatorHub (community operator)
# Namespace: any — set GRAFANA_NS to match before running build-and-deploy.sh
# Default assumed by the script: openshift-operators

# Verify
oc get crd grafanas.grafana.integreatly.org
oc get grafana -n <GRAFANA_NS>
```

Before applying the manifests, create the credentials secret in the same namespace as the operator:

```bash
oc create secret generic grafana-admin-credentials \
  -n <GRAFANA_NS> \
  --from-literal=GF_SECURITY_ADMIN_USER=admin \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD=<your-password>
```

Then deploy with the namespace override if needed:

```bash
GRAFANA_NS=my-grafana-ns ./build-and-deploy.sh --skip-build
```

After deployment the Grafana instance is available via its Route:

```bash
oc get route -n <GRAFANA_NS> | grep grafana
```

The datasource points to the MonitoringStack Prometheus in `app-scenario`:

```
http://app-scenario-stack-prometheus.app-scenario.svc:9090
```

> **Note:** This Prometheus is scraped by the local MonitoringStack, not UWM. It holds the same `http_requests_total` and latency metrics but is separate from the OCP Console Observe view. If you only want UWM dashboards (OCP Console → Observe → Dashboards), Grafana is optional.

## 7. OpenShift Internal Registry

Required for building and storing the custom app images.

```bash
# Enable the internal registry if not already running
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

# Verify
oc get pods -n openshift-image-registry
```

## Verification summary

```bash
oc get csv -A | grep -E 'cluster-observability|cluster-logging|loki|tempo|netobserv|grafana|odf'
oc get crd | grep -E 'monitoringstack|lokistack|tempomonolithic|opentelemetrycollector|flowcollector|perses'
oc get noobaa -n openshift-storage
oc get storageclass openshift-storage.noobaa.io
oc get lokistack -A
oc get tempomonolithic -A
oc get flowcollector cluster
```
