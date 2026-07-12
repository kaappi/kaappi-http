#!/bin/bash
# Fiber-server concurrency test — a slow client trickling its request body
# in one byte at a time must not block a fast client racing it. See
# slow-client.py and the KEP-0001 acceptance criterion for http-listen-fiber.
set +e

KAAPPI="${KAAPPI:-zig-out/bin/kaappi}"
LIB_PATH="${LIB_PATH:-lib}"
PORT=19877
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    got:      $actual"
    fi
}

DIR="$(cd "$(dirname "$0")" && pwd)"
NET_DIR="${NET_DIR:-$DIR/../../kaappi-net}"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:+$DYLD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
$KAAPPI --lib-path "$NET_DIR/lib" --lib-path "$LIB_PATH" "$DIR/test-fiber-server-app.scm" &
SERVER_PID=$!
sleep 0.5

SLOW_OUT="$(mktemp)"
cleanup() { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -f "$SLOW_OUT"; true; }
trap cleanup EXIT

echo "=== Slow client trickling a request body ==="
# 7 bytes at 0.3s apart = ~2.1s total, running in the background while a
# fast request races it.
python3 "$DIR/slow-client.py" $PORT 0.3 > "$SLOW_OUT" &
SLOW_PID=$!
sleep 0.5   # let the slow client connect and start trickling

echo "=== Fast client racing the slow one ==="
START=$(python3 -c 'import time; print(time.time())')
FAST_BODY=$(curl -s http://127.0.0.1:$PORT/)
END=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print($END - $START)")

check "fast client body" "Hello, World!" "$FAST_BODY"
FAST_OK=$(python3 -c "print('yes' if $ELAPSED < 1.0 else 'no')")
check "fast client not blocked by slow client" "yes" "$FAST_OK"

wait $SLOW_PID
check "slow client eventually completes" "trickle" "$(cat "$SLOW_OUT")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; true
trap - EXIT

[ "$FAIL" -eq 0 ]
