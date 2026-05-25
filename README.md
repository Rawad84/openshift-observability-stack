# OpenShift Observability Signal Correlation Scenario

A hands-on scenario demonstrating how to correlate metrics, logs, traces, network flows, and Kubernetes events to identify the root cause of a service degradation — using the OpenShift Cluster Observability Operator (COO) and the Troubleshooting Panel UIPlugin.

---

## What this scenario demonstrates

**The core problem:** When a symptom (frontend errors) and a root cause (backend degradation) are in different services, no single signal tells the full story. You need to correlate signals across layers.

**The scenario:**

```
User → frontend → backend → mock-db (SQLite on PVC)
```

1. **Normal mode:** All three services healthy, requests complete in <100ms.
2. **Degraded mode:** Backend `/inject-failure` is called. Backend adds 3s latency and returns 503 for 40% of requests. Frontend shows high error rate and latency — the symptom appears to be a frontend problem.
3. **Investigation:** Walk through metrics → logs → traces → network flows → events to identify the actual root cause (backend degradation, not frontend, not mock-db).
4. **Resolution:** Call backend `/restore`. Recovery visible in metrics within 2 minutes.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Namespace: app-scenario                                        │
│                                                                 │
│  ┌──────────┐   HTTP    ┌──────────┐   HTTP    ┌──────────┐    │
│  │ frontend │ ────────► │ backend  │ ────────► │ mock-db  │    │
│  │ :8080    │           │ :8080    │           │ :8080    │    │
│  └──────────┘           └──────────┘           └────┬─────┘    │
│                                                      │          │
│                                               SQLite on PVC     │
│                                               (mock-db-storage) │
│       │ traces               │ traces               │ traces    │
│       └──────────────────────┴──────────────────────┘          │
│                              │                                  │
│                    ┌─────────────────┐                          │
│                    │  otel-collector  │                          │
│                    │  :4317 (gRPC)   │                          │
│                    └────────┬────────┘                          │
│                             │ OTLP                              │
│                          Tempo (cluster)                        │
│                                                                 │
│  Prometheus (MonitoringStack)  ←──── scrapes /metrics           │
│  Loki (LokiStack)              ←──── collects container logs    │
│  Network Observability         ←──── eBPF flow data             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Signal coverage

| Signal | Source | Console location |
|--------|--------|------------------|
| Metrics | Prometheus (MonitoringStack) | Observe → Dashboards / Metrics |
| Logs | Loki (ClusterLogForwarder) | Observe → Logs |
| Traces | Tempo (via OTel Collector) | Observe → Traces |
| Network flows | eBPF (FlowCollector) | Observe → Network Traffic |
| K8s events | Kubernetes API | Troubleshooting Panel sidebar |
| Correlated view | Troubleshooting Panel UIPlugin | Observe → any signal → panel |

---

## How the Troubleshooting Panel correlation works

The OCP Troubleshooting Panel is powered by **korrel8r**, which walks a graph of rules to find related signals. The full chain (alert → pods → logs / traces / events / network flows) requires three things to be true simultaneously:

### 0. The full observability stack must be deployed

korrel8r can only surface a signal type if the backing store is present and reachable. Each signal type depends on a specific component:

| Signal in panel | Required component |
|----------------|-------------------|
| `log:application` | LokiStack + ClusterLogForwarder (`04-logging/`) |
| `trace:span` | TempoMonolithic + OTel Collector (`05-tracing/`) |
| `netflow:network` | FlowCollector + NetObserv LokiStack (`06-netflow/`) |
| `k8s:Event`, `k8s:Pod` | Kubernetes API — always available |
| `metric:metric` | Prometheus (UWM or MonitoringStack — `03-observability/`) |

If any of these components is missing, korrel8r silently returns zero results for that signal type. The panel still opens — it just shows fewer signal categories.

### 1. Alert rules must carry a `deployment` label

korrel8r's `AlertToDeployment` rule uses `{{.Labels.deployment}}` to navigate from a firing alert to a Kubernetes Deployment. Without this label the correlation stops at the alert — no logs, traces, events, or network flows are surfaced regardless of what's deployed.

Every alert in `03-observability/prometheusrules.yaml` and `03-observability/uwm-prometheusrules.yaml` already includes this label:

```yaml
labels:
  severity: critical
  deployment: frontend   # ← required by korrel8r AlertToDeployment rule
```

If you add new alert rules, include a `deployment` label matching the Deployment name.

### 2. Traces must carry Kubernetes resource attributes

korrel8r's `PodToTrace` rule queries Tempo for spans tagged with `k8s.pod.name`. Without this attribute in the trace resource, traces are never surfaced in the Troubleshooting Panel even if they exist in Tempo.

The three required attributes are:

| Attribute | Example value | Used by |
|-----------|--------------|---------|
| `k8s.pod.name` | `frontend-6d8f9b-xk2p` | korrel8r `PodToTrace` rule |
| `k8s.namespace.name` | `app-scenario` | korrel8r scoping |
| `k8s.deployment.name` | `frontend` | Tempo tag filtering |

Both options below are active in this scenario. Neither requires app code changes.

#### Option A — Collector-side enrichment

The OTel Collector in `05-tracing/otel-collector.yaml` is configured with the **`k8sattributesprocessor`**. It enriches every incoming span batch by looking up the source IP of the gRPC connection in the Kubernetes pod cache, then attaching the pod's metadata automatically.

```yaml
processors:
  k8sattributes:
    auth_type: serviceAccount   # reads pods via the otel-collector ServiceAccount
    pod_association:
      - sources:
        - from: connection      # resolves the sending pod by its connection IP
```

The collector's `ServiceAccount` and `ClusterRole` (defined in the same file) grant the necessary `get/list/watch` permissions on pods and namespaces.

> **Caveat:** very fast spans exported before the pod-watch cache populates after a cold collector restart may be missing k8s attributes. The cache is warm within a few seconds of startup; this is only a transient issue.

#### Option B — Deployment manifest env var

`OTEL_RESOURCE_ATTRIBUTES` is set in `02-apps/deployments.yaml` for all three apps. The OTel SDK reads this env var automatically and merges it into the span resource at startup.

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE),k8s.deployment.name=frontend"
```

> **Note:** If your app calls `Resource.create({...})` with a hardcoded dict, the explicit dict takes precedence and this env var will be silently ignored. In that case enrich the dict to read `POD_NAME` / `POD_NAMESPACE` from the environment, or rely solely on Option A.

The apps in this scenario set only `service.name` in `Resource.create()` — Options A and B provide the k8s attributes without any further code changes.

---

## Cluster resource requirements

The full stack requires two worker nodes at minimum. The table below shows the request footprint of components deployed by this scenario (platform overhead — operators, OCP monitoring, etc. — is excluded and already present on the nodes).

| Component | CPU request | Memory request | Notes |
|---|---|---|---|
| frontend + backend + mock-db | 30m | 192 Mi | mock-db uses a 1Gi PVC for SQLite storage |
| OTel Collector | 50m | 128 Mi | |
| MonitoringStack Prometheus | 100m | 256 Mi | |
| TempoMonolithic | ~500m | ~1 GiB | |
| Logging LokiStack (`1x.pico`, 7 pods) | ~500m | ~400 Mi | Actual observed ~40Mi/pod; `1x.pico` honors resource overrides |
| NetObserv LokiStack (`1x.pico`, 7 pods) | ~500m | ~400 Mi | Same |
| Vector / ClusterLogForwarder (DaemonSet) | ~150m | ~768 Mi | 256Mi request × 3 nodes; 1Gi limit per pod to avoid OOMKill on startup |
| FlowCollector eBPF agent + processor | ~200m | ~350 Mi | |
| **Scenario total** | **~2.1 CPU** | **~3.5 GiB** | |

**Minimum recommended per worker node: 8 CPU / 24 GiB RAM**

On a freshly provisioned cluster roughly half of each worker's capacity is already consumed by platform components (OCP monitoring, operators, DNS, etc.). Two 8 CPU / 24 GiB workers leave ~9 CPU / ~26 GiB free — enough to absorb the scenario stack with headroom.

> **Storage:** ODF with NooBaa is required. The script provisions three S3 buckets via `ObjectBucketClaim` (one each for Loki logging, Loki netobserv, and Tempo) and reads credentials directly from the OBC-generated Secrets. External S3 is not supported without manually pre-creating the storage secrets.

---

## Prerequisites

All operators must be installed before deploying this scenario. See `00-prerequisites/notes.md` for full details and verification commands.

| Operator / Component | Required for |
|---|---|
| OpenShift Data Foundation (ODF) | S3 bucket provisioning via NooBaa (Loki × 2, Tempo) |
| Cluster Observability Operator | MonitoringStack, UIPlugins |
| Red Hat OpenShift Logging + Loki Operator | Observe → Logs, ClusterLogForwarder |
| Tempo Operator | Observe → Traces |
| Red Hat build of OpenTelemetry Operator | OTel Collector |
| Network Observability Operator | Observe → Network Traffic |
| Grafana Operator | Grafana dashboards (optional) |

---

## Quick start

### 1. Deploy

```bash
# From the root of this directory:
./build-and-deploy.sh
```

This will:
1. Create the `app-scenario` namespace
2. Build all three app images using OpenShift's internal registry
3. Deploy frontend, backend, mock-db, otel-collector
4. Apply MonitoringStack, ServiceMonitors, PrometheusRules
5. Apply ClusterLogForwarder, UIPlugins, FlowCollector

### 2. Validate

```bash
./08-scenario/validate-all.sh
```

### 3. Confirm normal baseline

```bash
./08-scenario/normal-mode.sh
```

### 4. Run the scenario

```bash
# Inject failure (simulates database dependency degradation)
./08-scenario/inject-failure.sh

# Investigate: see 08-scenario/investigation-guide.md

# Restore when done
./08-scenario/restore-normal.sh
```

---

## Investigation walkthrough

After `inject-failure.sh`, follow the step-by-step guide:

```
08-scenario/investigation-guide.md
```

The guide covers how to use the Troubleshooting Panel for initial correlated signal discovery, then drills into metrics, logs, traces, network flows, and K8s events to identify the root cause.

---

## Folder structure

```
observability_scenario/
├── README.md                          # This file
├── root-cause-template.md             # Guided RCA worksheet
├── build-and-deploy.sh                # One-shot build + deploy script
├── 00-prerequisites/
│   └── notes.md                       # Operator install guide + verification
├── 01-namespaces/
│   └── namespace.yaml
├── 02-apps/
│   ├── imagestreams.yaml
│   ├── buildconfigs.yaml
│   ├── pvc.yaml
│   ├── deployments.yaml
│   ├── services.yaml
│   └── routes.yaml
├── 03-observability/
│   ├── monitoringstack.yaml
│   ├── servicemonitors.yaml
│   └── prometheusrules.yaml
├── 04-logging/
│   ├── clusterlogforwarder.yaml
│   ├── logging-uiplugin.yaml
│   └── rbac.yaml
├── 05-tracing/
│   ├── otel-collector.yaml
│   └── distributed-tracing-uiplugin.yaml
├── 06-netflow/
│   └── flowcollector.yaml
├── 07-uiplugins/
│   ├── monitoring-uiplugin.yaml
│   └── troubleshooting-panel-uiplugin.yaml
├── 08-scenario/
│   ├── normal-mode.sh
│   ├── inject-failure.sh
│   ├── restore-normal.sh
│   └── validate-all.sh
└── apps/
    ├── frontend/
    │   ├── app.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── backend/
    │   ├── app.py
    │   ├── requirements.txt
    │   └── Dockerfile
    └── mock-db/
        ├── app.py
        ├── requirements.txt
        └── Dockerfile
```

---

## Failure injection details

The backend has two endpoints that control its degraded state:

| Endpoint | Method | Effect |
|----------|--------|--------|
| `/inject-failure` | POST | Sets `_degraded=True`. All `/process` requests get 3s extra latency + 40% return 503 |
| `/restore` | POST | Clears `_degraded=False`. Returns to normal immediately |
| `/status` | GET | Returns `{"degraded": true/false}` |
| `/health` | GET | Always returns healthy (pod is running, just degraded) |

The health check always returns OK — this is intentional. It simulates the real-world case where a pod passes its liveness probe but is internally degraded (e.g., database pool exhausted, downstream dependency broken).

---

## PromQL quick reference

```promql
# Traffic
rate(http_requests_total[5m])

# Error ratio per service
job:http_requests_error_ratio:rate5m

# p99 latency per service
job:http_request_duration_seconds:p99

# mock-db query latency
histogram_quantile(0.99, rate(db_query_duration_seconds_bucket[5m]))

# All targets up?
up{namespace="app-scenario"}
```

---

## Renaming the namespace

The scenario deploys into `app-scenario` by default. If you need to change the namespace, the following files have hardcoded references that must all be updated together — changing only the namespace metadata is not enough.

| File | What's hardcoded | Impact |
|---|---|---|
| `02-apps/services.yaml` | `monitoring.rhobs/stack: app-scenario` label | MonitoringStack won't discover services |
| `03-observability/monitoringstack.yaml` | `namespaceSelector: [app-scenario]` | Prometheus won't scrape the namespace |
| `03-observability/prometheusrules.yaml` | `namespace="app-scenario"` in PromQL | Alert expressions wrong |
| `03-observability/uwm-prometheusrules.yaml` | `namespace="app-scenario"` in PromQL | Same as above |
| `03-observability/grafana-datasource.yaml` | `app-scenario-stack-prometheus.app-scenario.svc` URL | Grafana can't reach Prometheus |
| `04-logging/clusterlogforwarder.yaml` | `namespaces: [app-scenario]` input filter | Won't collect logs from the namespace |
| `05-tracing/tempomonolithic.yaml` | `tenantId` contains `app-scenario` | Cosmetic only |

---

## Cleanup

```bash
oc delete namespace app-scenario
oc delete uiplugin monitoring distributed-tracing logging troubleshooting-panel
# Do NOT delete FlowCollector if other teams use it
```
