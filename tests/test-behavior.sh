#!/bin/bash
# Behavioral tests for displaylink-watchdog daemon.
#
# Tests the compiled binary as a black box:
# - Starts and stays resident
# - Handles SIGTERM/SIGINT gracefully
# - Survives rapid restart cycles without leaking processes
# - Writes structured, parseable logs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/../displaylink-watchdog"
LOG="$HOME/scripts/logs/displaylink-watchdog.log"
PASSED=0
FAILED=0
TEST_PIDS=()

cleanup() {
    for pid in "${TEST_PIDS[@]:-}"; do
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; ((PASSED++)) || true; }
fail() { echo "  FAIL: $1"; ((FAILED++)) || true; }

# ------------------------------------------------------------------
echo "=== Daemon lifecycle ==="

if [ ! -x "$BINARY" ]; then
    fail "Binary not found. Run 'make build' first."
    exit 1
fi

"$BINARY" > /dev/null 2>&1 &
PID1=$!
TEST_PIDS+=("$PID1")
sleep 2

if kill -0 "$PID1" 2>/dev/null; then
    pass "Starts and stays resident"
else
    fail "Exited prematurely"
fi

if grep -q "=== Started (PID $PID1)" "$LOG" 2>/dev/null; then
    pass "Logs startup with PID"
else
    fail "Startup not logged for PID $PID1"
fi

# ------------------------------------------------------------------
echo ""
echo "=== Signal handling ==="

kill -TERM "$PID1" 2>/dev/null || true
sleep 1

if ! kill -0 "$PID1" 2>/dev/null; then
    pass "Exits on SIGTERM"
else
    fail "Did not exit on SIGTERM"
fi

if grep -q "Received signal 15" "$LOG"; then
    pass "Logs SIGTERM before exit"
else
    fail "SIGTERM not logged"
fi

"$BINARY" > /dev/null 2>&1 &
PID2=$!
TEST_PIDS+=("$PID2")
sleep 2

kill -INT "$PID2" 2>/dev/null || true
sleep 1

if ! kill -0 "$PID2" 2>/dev/null; then
    pass "Exits on SIGINT"
else
    fail "Did not exit on SIGINT"
fi

if grep -q "Received signal 2" "$LOG"; then
    pass "Logs SIGINT before exit"
else
    fail "SIGINT not logged"
fi

# ------------------------------------------------------------------
echo ""
echo "=== Crash loop resilience ==="

for _ in $(seq 1 5); do
    "$BINARY" > /dev/null 2>&1 &
    RPID=$!
    TEST_PIDS+=("$RPID")
    sleep 0.3
    kill -TERM "$RPID" 2>/dev/null || true
    sleep 0.3
done
sleep 1

PROCS=$(pgrep -c "displaylink-watchdog" 2>/dev/null || echo "0")
if [ "$PROCS" -eq 0 ]; then
    pass "No leaked processes after crash loop"
else
    fail "Leaked $PROCS processes"
fi

# ------------------------------------------------------------------
echo ""
echo "=== Log integrity ==="

if [ -f "$LOG" ]; then
    BAD=$(/usr/bin/grep -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG" 2>/dev/null | /usr/bin/wc -l | tr -d ' ')
    if [ "$BAD" -eq 0 ]; then
        pass "All log lines well-formed"
    else
        fail "Log has $BAD malformed lines"
    fi
fi

STARTS=$(grep -c "=== Started" "$LOG" 2>/dev/null || echo "0")
EXITS=$(grep -c "Received signal" "$LOG" 2>/dev/null || echo "0")

if [ "$STARTS" -ge 2 ]; then
    pass "Multiple startups recorded (daemon is restartable)"
else
    fail "Expected multiple startup entries, got $STARTS"
fi

if [ "$EXITS" -ge 2 ]; then
    pass "Multiple clean exits recorded"
else
    fail "Expected multiple exit entries, got $EXITS"
fi

# ------------------------------------------------------------------
echo ""
echo "========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================="
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
