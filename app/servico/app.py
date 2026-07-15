import os
import sys
import time
import random
import logging
from flask import Flask, jsonify, request
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
)
import redis

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("servico")

app = Flask(__name__)

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
BASE_DELAY_MS = int(os.getenv("PROCESSING_DELAY_MS", "50"))

# ── Prometheus Metrics ──
REQUEST_COUNT = Counter(
    "servico_requests_total",
    "Total de requisicoes recebidas pelo servico",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "servico_request_duration_seconds",
    "Latencia total das requisicoes no servico",
    ["method", "endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0]
)
PROCESSING_LATENCY = Histogram(
    "servico_processing_duration_seconds",
    "Latencia do processamento (computacao ou cache)",
    ["source"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0]
)
CACHE_HITS = Counter(
    "servico_cache_hits_total",
    "Total de cache hits no Redis"
)
CACHE_MISSES = Counter(
    "servico_cache_misses_total",
    "Total de cache misses no Redis"
)
CACHE_ERRORS = Counter(
    "servico_cache_errors_total",
    "Total de erros ao acessar o Redis"
)
ACTIVE_REQUESTS = Gauge(
    "servico_active_requests",
    "Numero de requisicoes sendo processadas agora"
)
COMPUTATION_COUNT = Counter(
    "servico_computations_total",
    "Total de computacoes realizadas (sem cache)"
)

# ── Redis (lazy init with retry) ──
_redis_client = None
_redis_failed = False

def get_redis():
    global _redis_client, _redis_failed
    if _redis_client is not None:
        return _redis_client
    if _redis_failed:
        return None
    for attempt in range(1, 4):
        try:
            _redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True, socket_connect_timeout=2)
            _redis_client.ping()
            logger.info(f"Connected to Redis (attempt {attempt})")
            return _redis_client
        except redis.RedisError:
            logger.warning(f"Redis connection attempt {attempt}/3 failed")
            if attempt < 3:
                time.sleep(2)
    _redis_failed = True
    logger.warning("Redis unavailable after 3 attempts, running without cache")
    return None

def get_delay():
    r = get_redis()
    if r is None:
        return BASE_DELAY_MS
    try:
        val = r.get("servico:delay_ms")
        return int(val) if val else BASE_DELAY_MS
    except (redis.RedisError, ValueError):
        return BASE_DELAY_MS

def get_cached(key):
    r = get_redis()
    if r is None:
        return None
    try:
        return r.get(key)
    except redis.RedisError:
        CACHE_ERRORS.inc()
        return None

def set_cached(key, value, ttl=30):
    r = get_redis()
    if r is None:
        return
    try:
        r.setex(key, ttl, value)
    except redis.RedisError:
        CACHE_ERRORS.inc()

@app.before_request
def _start_timer():
    request._prom_start = time.time()
    ACTIVE_REQUESTS.inc()

@app.teardown_request
def _end_timer(exc=None):
    ACTIVE_REQUESTS.dec()

@app.after_request
def _record_metrics(response):
    elapsed = time.time() - getattr(request, "_prom_start", time.time())
    endpoint = request.path
    method = request.method
    REQUEST_LATENCY.labels(method=method, endpoint=endpoint).observe(elapsed)
    REQUEST_COUNT.labels(method=method, endpoint=endpoint, status=response.status_code).inc()
    return response

@app.route("/process", methods=["GET"])
def process():
    start = time.time()
    cached = get_cached("process_result")
    if cached:
        elapsed = time.time() - start
        CACHE_HITS.inc()
        PROCESSING_LATENCY.labels(source="cache").observe(elapsed)
        logger.info("Returning cached result")
        return jsonify({"value": cached, "source": "cache", "timestamp": time.time()})

    CACHE_MISSES.inc()
    COMPUTATION_COUNT.inc()
    delay = get_delay() / 1000.0
    time.sleep(delay)
    result = str(random.randint(1000, 9999))
    set_cached("process_result", result)
    elapsed = time.time() - start
    PROCESSING_LATENCY.labels(source="compute").observe(elapsed)
    logger.info(f"Computed new result: {result} (delay={delay*1000:.0f}ms)")

    return jsonify({"value": result, "source": "compute", "timestamp": time.time()})

@app.route("/health", methods=["GET"])
def health():
    db_status = "connected" if get_redis() else "disconnected"
    return jsonify({"status": "healthy", "database": db_status})

@app.route("/metrics", methods=["GET"])
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

@app.route("/process/flush", methods=["POST"])
def flush_cache():
    r = get_redis()
    if r is None:
        return jsonify({"flushed": False, "error": "Redis unavailable"}), 503
    try:
        r.delete("process_result")
        logger.info("Cache flushed")
        return jsonify({"flushed": True})
    except redis.RedisError as e:
        return jsonify({"flushed": False, "error": str(e)}), 500

@app.route("/admin/slow", methods=["POST"])
def admin_slow():
    delay_param = request.args.get("ms")
    if delay_param is None:
        current = get_delay()
        return jsonify({"delay_ms": current, "base_ms": BASE_DELAY_MS})
    try:
        new_delay = int(delay_param)
        r = get_redis()
        if r:
            r.set("servico:delay_ms", str(new_delay))
        logger.info(f"Delay changed to {new_delay}ms")
        return jsonify({"delay_ms": new_delay})
    except ValueError:
        return jsonify({"error": "Invalid delay value"}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
