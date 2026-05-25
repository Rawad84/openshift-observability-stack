import os
import time
import json
import logging
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
            "service": "frontend",
            "message": record.getMessage(),
            "logger": record.name,
        })

handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("frontend")

# ── OpenTelemetry setup ────────────────────────────────────────────────────────
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
resource = Resource.create({
    "service.name": "frontend",
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("frontend")

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

BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:8080")

# ── App ────────────────────────────────────────────────────────────────────────
app = FastAPI(title="frontend")
FastAPIInstrumentor.instrument_app(app)
HTTPXClientInstrumentor().instrument()


@app.get("/health")
def health():
    return {"status": "ok", "service": "frontend"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
async def root(request: Request):
    start = time.time()
    status_code = 200

    with tracer.start_as_current_span("frontend.handle_request") as span:
        span.set_attribute("http.method", "GET")
        span.set_attribute("http.route", "/")

        try:
            log.info("Calling backend /process")
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.get(f"{BACKEND_URL}/process")
            status_code = resp.status_code
            result = resp.json()
            span.set_attribute("backend.status_code", status_code)
            log.info(f"Backend responded with status={status_code}")

            if status_code >= 500:
                log.error(f"Backend returned error: {result}")
                span.set_attribute("error", True)
                return Response(
                    content=json.dumps({"error": "backend error", "detail": result}),
                    status_code=502,
                    media_type="application/json",
                )

            return {"service": "frontend", "backend_response": result}

        except httpx.TimeoutException:
            status_code = 504
            log.error("Backend request timed out")
            span.set_attribute("error", True)
            span.set_attribute("error.message", "backend timeout")
            return Response(
                content=json.dumps({"error": "backend timeout"}),
                status_code=504,
                media_type="application/json",
            )
        except Exception as e:
            status_code = 500
            log.error(f"Unexpected error calling backend: {e}")
            span.set_attribute("error", True)
            return Response(
                content=json.dumps({"error": str(e)}),
                status_code=500,
                media_type="application/json",
            )
        finally:
            duration = time.time() - start
            REQUEST_COUNT.labels("GET", "/", str(status_code)).inc()
            REQUEST_LATENCY.labels("GET", "/", str(status_code)).observe(duration)
