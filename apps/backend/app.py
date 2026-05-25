import os
import time
import json
import random
import logging
import asyncio
import httpx
from fastapi import FastAPI, Response, Request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource

# ── Structured JSON logging ────────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": "backend",
            "message": record.getMessage(),
            "logger": record.name,
        })

handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("backend")

# ── OpenTelemetry setup ────────────────────────────────────────────────────────
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
resource = Resource.create({
    "service.name": "backend",
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("backend")

# ── Prometheus metrics ─────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "path", "status_code"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)

MOCKDB_URL = os.getenv("MOCKDB_URL", "http://mock-db:8080")

# ── Failure injection state ────────────────────────────────────────────────────
# degraded: adds latency + error rate to simulate database dependency failure
_degraded = False
DEGRADED_LATENCY_SECONDS = float(os.getenv("DEGRADED_LATENCY_SECONDS", "3.0"))
DEGRADED_ERROR_RATE = float(os.getenv("DEGRADED_ERROR_RATE", "0.4"))

# ── App ────────────────────────────────────────────────────────────────────────
app = FastAPI(title="backend")
FastAPIInstrumentor.instrument_app(app)
HTTPXClientInstrumentor().instrument()


@app.get("/health")
def health():
    return {"status": "ok", "service": "backend", "degraded": _degraded}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/inject-failure")
def inject_failure():
    global _degraded
    _degraded = True
    log.warning("Failure injection ENABLED — degraded mode active")
    return {"degraded": True, "latency_seconds": DEGRADED_LATENCY_SECONDS, "error_rate": DEGRADED_ERROR_RATE}


@app.post("/restore")
def restore():
    global _degraded
    _degraded = False
    log.info("Failure injection DISABLED — normal mode restored")
    return {"degraded": False}


@app.get("/status")
def status():
    return {"degraded": _degraded}


@app.get("/process")
async def process(request: Request):
    start = time.time()
    status_code = 200

    with tracer.start_as_current_span("backend.process") as span:
        span.set_attribute("backend.degraded", _degraded)

        try:
            if _degraded:
                # Simulate slow database response due to connection pool exhaustion
                log.warning(f"Degraded mode: injecting {DEGRADED_LATENCY_SECONDS}s latency before db call")
                await asyncio.sleep(DEGRADED_LATENCY_SECONDS)

                # Simulate database timeout for a percentage of requests
                if random.random() < DEGRADED_ERROR_RATE:
                    log.error("Database connection timeout — mock-db did not respond within threshold")
                    span.set_attribute("error", True)
                    span.set_attribute("error.type", "db_timeout")
                    status_code = 503
                    return Response(
                        content=json.dumps({
                            "error": "database timeout",
                            "detail": "mock-db connection pool exhausted",
                        }),
                        status_code=503,
                        media_type="application/json",
                    )

            log.info("Calling mock-db /query")
            async with httpx.AsyncClient(timeout=8.0) as client:
                resp = await client.get(f"{MOCKDB_URL}/query")
            db_status = resp.status_code
            db_result = resp.json()
            span.set_attribute("mockdb.status_code", db_status)
            log.info(f"mock-db responded with status={db_status}")

            return {"service": "backend", "db_response": db_result, "degraded": _degraded}

        except httpx.TimeoutException:
            status_code = 504
            log.error("mock-db request timed out")
            span.set_attribute("error", True)
            span.set_attribute("error.type", "db_timeout")
            return Response(
                content=json.dumps({"error": "mock-db timeout"}),
                status_code=504,
                media_type="application/json",
            )
        except Exception as e:
            status_code = 500
            log.error(f"Unexpected error: {e}")
            span.set_attribute("error", True)
            return Response(
                content=json.dumps({"error": str(e)}),
                status_code=500,
                media_type="application/json",
            )
        finally:
            duration = time.time() - start
            REQUEST_COUNT.labels("GET", "/process", str(status_code)).inc()
            REQUEST_LATENCY.labels("GET", "/process", str(status_code)).observe(duration)
