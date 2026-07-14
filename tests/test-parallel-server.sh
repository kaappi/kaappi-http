#!/bin/bash
# http-listen-parallel concurrency test: a burst of concurrent requests must
# all be served correctly, whether the platform uses the kernel-balanced
# SO_REUSEPORT path (Linux) or the acceptor/worker fallback (Darwin). Each
# response echoes the request path, so a cross-wired connection shows up as a
# mismatch, not just a timeout.
set +e

KAAPPI="${KAAPPI:-zig-out/bin/kaappi}"
LIB_PATH="${LIB_PATH:-lib}"
PORT=19878
NREQ=48
CONC=12
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $name"; echo "    expected: $expected"; echo "    got:      $actual"
    fi
}

DIR="$(cd "$(dirname "$0")" && pwd)"
NET_DIR="${NET_DIR:-$DIR/../../kaappi-net}"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:+$DYLD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
$KAAPPI --lib-path "$NET_DIR/lib" --lib-path "$LIB_PATH" "$DIR/test-parallel-server-app.scm" &
SERVER_PID=$!
RES="$(mktemp)"
cleanup() { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -f "$RES"; true; }
trap cleanup EXIT

# Wait for the server to accept connections (up to ~6s).
LISTENING=no
for i in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" 2>/dev/null; then LISTENING=yes; break; fi
    sleep 0.1
done
check "server is listening" "yes" "$LISTENING"

echo "=== $NREQ concurrent requests, $CONC at a time ==="
seq 1 "$NREQ" | xargs -P "$CONC" -I{} sh -c '
    r=$(curl -s --max-time 8 "http://127.0.0.1:'"$PORT"'/req{}")
    [ "$r" = "ok:/req{}" ] && echo OK || echo "BAD {}: [$r]"
' > "$RES" 2>&1
OKN=$(grep -c '^OK$' "$RES")
check "all $NREQ requests served correctly" "$NREQ" "$OKN"
[ "$OKN" -ne "$NREQ" ] && { echo "--- failures ---"; grep -v '^OK$' "$RES" | head -5; }

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; true
trap - EXIT
[ "$FAIL" -eq 0 ]
