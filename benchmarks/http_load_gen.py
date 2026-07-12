#!/usr/bin/env python3
"""Minimal concurrent HTTP/1.1 load generator for KEP-0001 Phase 7 server
benchmarks -- no wrk/hey/ab available in that workspace. One request per
connection (Connection: close), measuring connects/sec and latency
percentiles at a given concurrency level."""
import socket
import sys
import time
import threading

host = "127.0.0.1"
port = int(sys.argv[1])
concurrency = int(sys.argv[2])
total_requests = int(sys.argv[3]) if len(sys.argv) > 3 else concurrency * 5

request = (
    b"GET / HTTP/1.1\r\n"
    b"Host: 127.0.0.1\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

latencies = [None] * total_requests
errors = [None] * total_requests
next_idx = [0]
lock = threading.Lock()


def worker():
    while True:
        with lock:
            i = next_idx[0]
            if i >= total_requests:
                return
            next_idx[0] += 1
        try:
            start = time.time()
            sock = socket.create_connection((host, port), timeout=10)
            sock.sendall(request)
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            sock.close()
            elapsed = time.time() - start
            body = b"".join(chunks)
            if b"Hello, World!" not in body:
                errors[i] = f"bad body: {body[:80]!r}"
            latencies[i] = elapsed
        except Exception as e:
            errors[i] = str(e)


start_all = time.time()
threads = [threading.Thread(target=worker) for _ in range(concurrency)]
for t in threads:
    t.start()
for t in threads:
    t.join(timeout=60)
elapsed_all = time.time() - start_all

ok_latencies = sorted(l for l in latencies if l is not None)
n_ok = len(ok_latencies)
n_err = sum(1 for e in errors if e is not None)


def pct(p):
    if not ok_latencies:
        return float("nan")
    idx = min(len(ok_latencies) - 1, int(len(ok_latencies) * p))
    return ok_latencies[idx]


rps = n_ok / elapsed_all if elapsed_all > 0 else float("nan")
print(f"concurrency={concurrency} total={total_requests} ok={n_ok} errors={n_err} "
      f"elapsed={elapsed_all:.3f}s rps={rps:.1f} "
      f"p50={pct(0.50)*1000:.2f}ms p99={pct(0.99)*1000:.2f}ms max={ok_latencies[-1]*1000 if ok_latencies else float('nan'):.2f}ms")
if n_err:
    seen = {}
    for e in errors:
        if e:
            seen[e] = seen.get(e, 0) + 1
    for e, c in list(seen.items())[:5]:
        print(f"  error x{c}: {e}")
sys.exit(0 if n_err == 0 else 1)
