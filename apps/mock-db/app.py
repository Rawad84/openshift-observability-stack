import os
import time
import json
import random
import logging
import sqlite3
from fastapi import FastAPI, Response
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource

# ── Structured JSON logging ────────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": "mock-db",
            "message": record.getMessage(),
            "logger": record.name,
        })

handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("mock-db")

# ── OpenTelemetry setup ────────────────────────────────────────────────────────
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
resource = Resource.create({
    "service.name": "mock-db",
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("mock-db")

# ── Prometheus metrics ─────────────────────────────────────────────────────────
QUERY_COUNT = Counter(
    "db_queries_total",
    "Total database queries",
    ["status"],
)
QUERY_LATENCY = Histogram(
    "db_query_duration_seconds",
    "Database query latency",
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0],
)

# ── SQLite on PVC ──────────────────────────────────────────────────────────────
DB_PATH = os.getenv("DB_PATH", "/data/mock-db.db")
DB_STATEMENT = "SELECT id, value, score FROM records ORDER BY RANDOM() LIMIT 1"

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS records (
            id    INTEGER PRIMARY KEY,
            value TEXT    NOT NULL,
            score REAL    NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS query_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            record_id  INTEGER NOT NULL,
            score      REAL    NOT NULL,
            queried_at TEXT    NOT NULL
        )
    """)
    if conn.execute("SELECT COUNT(*) FROM records").fetchone()[0] == 0:
        conn.executemany(
            "INSERT INTO records (id, value, score) VALUES (?, ?, ?)",
            [(i, f"record-{i}", round(random.uniform(0.1, 1.0), 4)) for i in range(1, 101)],
        )
        conn.commit()
        log.info(f"Database initialised at {DB_PATH} with 100 records")
    conn.close()

# ── App ────────────────────────────────────────────────────────────────────────
app = FastAPI(title="mock-db")
FastAPIInstrumentor.instrument_app(app)


@app.on_event("startup")
def startup():
    init_db()


@app.get("/health")
def health():
    return {"status": "ok", "service": "mock-db", "db": DB_PATH}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/query")
def query():
    start = time.time()
    with tracer.start_as_current_span("mock-db.query") as span:
        span.set_attribute("db.system", "sqlite")
        span.set_attribute("db.name", DB_PATH)
        span.set_attribute("db.statement", DB_STATEMENT)

        conn = sqlite3.connect(DB_PATH)
        row = conn.execute(DB_STATEMENT).fetchone()
        conn.execute(
            "INSERT INTO query_log (record_id, score, queried_at) VALUES (?, ?, datetime('now'))",
            (row[0], row[2]),
        )
        conn.commit()
        conn.close()

        record = {"id": row[0], "value": row[1], "score": row[2]}
        span.set_attribute("db.rows_returned", 1)

        duration = time.time() - start
        QUERY_COUNT.labels("success").inc()
        QUERY_LATENCY.observe(duration)

        log.info(f"Query completed in {duration:.3f}s, returned record id={record['id']}")
        return {"service": "mock-db", "record": record, "query_time_ms": round(duration * 1000, 2)}
