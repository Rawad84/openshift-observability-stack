# Investigation Guide

---

## How to read this guide

Each step begins with the **Troubleshooting Panel** — korrel8r automatically correlates signals from a single firing alert so you can see metrics, logs, traces, events, and network flows in one place. The manual PromQL / Logs / Traces steps that follow are the drill-down once you know what to look for.

---

## Baseline — what normal looks like

Before investigating, it helps to know what a healthy trace looks like. During normal operation (`normal-mode.sh`) a full request produces this span waterfall:

```
frontend.handle_request   [~50ms total]
└── GET /process          [~45ms — HTTP call to backend]
    └── backend.process   [~40ms]
        └── GET /query    [~30ms — HTTP call to mock-db]
            └── mock-db.query [~20ms]
                  db.system:    sqlite
                  db.name:      /data/mock-db.db
                  db.statement: SELECT id, value, score FROM records ORDER BY RANDOM() LIMIT 1
                  db.rows_returned: 1
```

Three key things to note:
- `mock-db.query` is always present in healthy traces
- `db.system: sqlite` confirms mock-db reads from its PVC-backed SQLite database
- End-to-end latency is under 100ms

Keep this picture in mind — any deviation from it is a signal.

---

## Step 1 — Open the Troubleshooting Panel from a firing alert

Before starting, inject the failure and wait for alerts to fire:

```bash
./08-scenario/inject-failure.sh
```

Wait **2–3 minutes** for `FrontendHighErrorRate` or `FrontendHighLatency` to appear in the Alerts tab. Alerts have a `for: 5m` hold-off — they will not fire instantly.

Then:

1. OCP Console → **Observe → Alerting → Alerts** tab
2. Find `FrontendHighErrorRate` or `FrontendHighLatency` in the list
3. Click the **instance name** in the firing alert row (the value under the "Name" column, not the alerting rule link above it)
4. The alert detail page opens — the **Troubleshooting Panel** sidebar appears on the right

> The Troubleshooting Panel only appears on the alert *instance* detail page. Clicking the alerting rule name takes you to the rule definition page, which does not show the panel.

**What korrel8r surfaces automatically:**

| Signal | What you see |
|--------|-------------|
| `alert:alert` | The firing `FrontendHighErrorRate` alert |
| `metric:metric` | Frontend request rate and error rate metrics |
| `log:application` | Recent application logs from the frontend pod |
| `k8s:Event` | Kubernetes events for the frontend deployment |
| `k8s:Pod` | Frontend pods |
| `netflow:network` | Network flows to/from the frontend pod |
| `trace:span` | Traces tagged with the frontend pod name |

**What you know:** The symptom is on the frontend — high error rate, high latency.  
**What you don't know yet:** Is the frontend itself broken, or is it a downstream dependency?

---

## Step 2 — Check whether the backend is also degraded

The frontend calls the backend on every request. Check if the problem is upstream.

**In the Troubleshooting Panel:** the panel is scoped to the frontend alert. To check backend signals, switch to PromQL manually.

```promql
# Backend error ratio
job:http_requests_error_ratio:rate5m{job="backend"}

# Backend p99 latency
job:http_request_duration_seconds:p99{job="backend"}

# mock-db query latency — is the database itself slow?
histogram_quantile(0.99, rate(db_query_duration_seconds_bucket[5m]))
```

**What you see:**
- Backend error ratio is elevated (~40%)
- Backend p99 latency is 3s+
- mock-db query latency is normal (5–50ms) — the database is responding fine

**New hypothesis:** The backend is the problem. But if mock-db is healthy, why is the backend timing out against it?

---

## Step 3 — Read the backend error logs

Observe → **Logs**  
Filter: namespace = `app-scenario`, application = `backend`, severity = `error` or `warning`

**What you see:**
```
backend: "Degraded mode: injecting 3.0s latency before db call"
backend: "Database connection timeout — mock-db did not respond within threshold"
```

**What this means:**
- The backend is deliberately adding 3s latency *before* attempting the mock-db call
- 40% of requests return a simulated "database timeout" without ever contacting mock-db
- This is application-level degradation — the backend has an internal `_degraded` flag set

**Refined hypothesis:** The backend is degraded internally. mock-db is fine — the backend never reached it.

---

## Step 4 — Confirm with a distributed trace

Observe → **Traces**  
Filter: service = `frontend`, then sort by duration descending or filter duration > 3s

Open a slow trace (3s+). Read the span waterfall:

```
frontend.handle_request   [3.1s total]
└── GET /process          [3.1s — HTTP call to backend]
    └── backend.process   [3.1s]
        (no child span)
```

Compare this to the healthy baseline above. The `mock-db.query` span is completely absent.

**What this proves:**
- The 3s latency is inside `backend.process` itself — no downstream call was made
- mock-db was never contacted; its SQLite database was never read
- Storage I/O is ruled out: if disk were the problem, you would see a slow `mock-db.query` span here, not a missing one

---

## Step 5 — Rule out storage I/O explicitly

Even with the trace evidence, someone may argue that PVC I/O pressure caused the backend to fail before reaching mock-db. Close that argument with two checks.

**Check 1 — mock-db query latency during the incident**

```promql
histogram_quantile(0.99, rate(db_query_duration_seconds_bucket[5m]))
```

The queries that *do* complete (during healthy backend requests) show normal latency (< 50ms). The PVC is not under pressure.

**Check 2 — Container filesystem I/O for mock-db**

In OCP Console → Observe → Metrics (platform Prometheus):

```promql
# Read throughput for the mock-db container
rate(container_fs_reads_bytes_total{namespace="app-scenario", pod=~"mock-db.*"}[5m])

# Write throughput
rate(container_fs_writes_bytes_total{namespace="app-scenario", pod=~"mock-db.*"}[5m])
```

**What you see:** Flat or near-zero I/O during the incident window. The SQLite database is not being read at all — consistent with the trace showing mock-db was never called.

**Conclusion:** Storage I/O is not a factor. The mock-db PVC is idle during the incident because the backend never issued a query to reach it.

---

## Step 6 — Confirm with network flows

Observe → **Network Traffic**  
Filter: namespace = `app-scenario`, source workload = `backend`

**What you see:**
- Traffic from `backend` to `frontend` (responses): present, elevated latency visible
- Traffic from `backend` to `mock-db`: absent or significantly reduced during the incident window

This corroborates both the trace and the storage I/O check: the backend stopped sending requests to mock-db entirely.

---

## Step 7 — Rule out infrastructure failure

Back in the Troubleshooting Panel (from Step 1), click through to the backend pods and events:

**K8s Events:** No `OOMKilled`, no `BackOff`, no scheduling failures. The backend pod has been running continuously without restarts.

**Pod status:** `Running`, readiness probe passing. The pod reports itself healthy.

**Final conclusion:** This is a pure application-level degradation. The backend pod is running, healthy by all infrastructure metrics, passing health checks — but has an internal `_degraded=true` flag active that adds 3s latency and returns errors for 40% of requests. The root cause is not a storage issue, not a mock-db failure, not a network partition, not an OOM or crash — it is simulated application behaviour that mimics a connection-pool exhaustion scenario.

---

## Root cause summary

| Layer | Finding |
|-------|---------|
| Frontend | High error rate and latency — symptom only |
| Backend | `_degraded=true` flag active — root cause |
| mock-db | Healthy; SQLite queries complete in < 50ms |
| mock-db PVC I/O | Flat during incident — database never reached |
| Network | No flows from backend to mock-db during incident |
| Infrastructure | No pod restarts, no OOM, no scheduling issues |

**Resolution:** `./restore-normal.sh` — calls `POST /restore` on the backend, clears the degraded flag. Frontend error rate returns to baseline within one Prometheus scrape interval (~30s).
