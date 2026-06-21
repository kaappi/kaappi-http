#!/bin/bash
# Integrated HTTP server test — starts server, curls it, checks responses.
set -e

KAAPPI="${KAAPPI:-zig-out/bin/kaappi}"
LIB_PATH="${LIB_PATH:-lib}"
PORT=19876
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

# Start server in background
DIR="$(cd "$(dirname "$0")" && pwd)"
NET_DIR="${NET_DIR:-$DIR/../../kaappi-net}"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:+$DYLD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$DIR/..:$NET_DIR"
$KAAPPI --lib-path "$NET_DIR/lib" --lib-path "$LIB_PATH" "$DIR/test-server-app.scm" &
SERVER_PID=$!
sleep 0.5

cleanup() { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; }
trap cleanup EXIT

echo "=== GET / ==="
BODY=$(curl -s http://127.0.0.1:$PORT/)
check "GET / body" "Hello, World!" "$BODY"

echo "=== GET /json ==="
CT=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:$PORT/json)
BODY=$(curl -s http://127.0.0.1:$PORT/json)
check "GET /json body" '{"ok":true}' "$BODY"

echo "=== POST /echo ==="
BODY=$(curl -s -X POST -d "echo body" http://127.0.0.1:$PORT/echo)
check "POST /echo body" "echo body" "$BODY"

echo "=== GET /missing ==="
STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/missing)
check "GET /missing status" "404" "$STATUS"

echo "=== GET /query ==="
BODY=$(curl -s "http://127.0.0.1:$PORT/query?name=alice&age=30")
check "GET /query body" "name=alice;age=30;" "$BODY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
