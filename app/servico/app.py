import os
import time
import random
import logging
from flask import Flask, jsonify
import redis

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("servico")

app = Flask(__name__)

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
PROCESSING_DELAY_MS = int(os.getenv("PROCESSING_DELAY_MS", "50"))

redis_client = None
try:
    redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True, socket_connect_timeout=2)
    redis_client.ping()
    logger.info("Connected to Redis")
except redis.RedisError:
    logger.warning("Redis unavailable, running without cache")

def get_cached(key):
    if redis_client is None:
        return None
    try:
        return redis_client.get(key)
    except redis.RedisError:
        return None

def set_cached(key, value, ttl=30):
    if redis_client is None:
        return
    try:
        redis_client.setex(key, ttl, value)
    except redis.RedisError:
        pass

@app.route("/process", methods=["GET"])
def process():
    cached = get_cached("process_result")
    if cached:
        logger.info("Returning cached result")
        return jsonify({"value": cached, "source": "cache", "timestamp": time.time()})

    delay = PROCESSING_DELAY_MS / 1000.0
    time.sleep(delay)
    result = str(random.randint(1000, 9999))
    set_cached("process_result", result)
    logger.info(f"Computed new result: {result}")

    return jsonify({"value": result, "source": "compute", "timestamp": time.time()})

@app.route("/health", methods=["GET"])
def health():
    db_status = "connected" if redis_client else "disconnected"
    return jsonify({"status": "healthy", "database": db_status})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
