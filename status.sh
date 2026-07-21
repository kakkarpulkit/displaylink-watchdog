#!/bin/bash
# Answer one question: is this thing actually working?
#
# A watchdog that is dead, misconfigured, or unloaded looks exactly like one
# that is healthy and idle — until the day you need it. This prints the
# difference.
set -uo pipefail

PLIST_LABEL="com.displaylink-watchdog"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
INSTALL_DIR="${DLW_INSTALL_DIR:-$HOME/scripts}"
BINARY="$INSTALL_DIR/displaylink-watchdog"
LOG="${DLW_LOG_PATH:-$HOME/scripts/logs/displaylink-watchdog.log}"

ok() { echo "  ok   $1"; }
bad() { echo " FAIL  $1"; PROBLEMS=$((PROBLEMS + 1)); }
note() { echo "       $1"; }
PROBLEMS=0

# Run a command with a time bound. macOS ships no coreutils `timeout`, and a
# binary older than 1.1.0 ignores unknown flags and daemonizes instead of
# exiting — which would hang this script forever. Never trust the installed
# binary to terminate.
run_bounded() {
    local secs="$1" outfile="$2"; shift 2
    "$@" > "$outfile" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1; waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
}

echo "displaylink-watchdog status"
echo ""

# --- Installed? -------------------------------------------------------------
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/dlw-status.XXXXXX")
trap 'rm -f "$TMPOUT"' EXIT

if [ -x "$BINARY" ]; then
    if run_bounded 5 "$TMPOUT" "$BINARY" --version; then
        ok "binary installed: $BINARY ($(cat "$TMPOUT"))"
    else
        bad "binary at $BINARY did not respond to --version"
        note "predates 1.1.0+ (older builds daemonize on unknown flags) — run 'make install' to update"
    fi
else
    bad "binary not installed at $BINARY — run 'make install'"
fi

[ -f "$PLIST" ] && ok "plist present: $PLIST" || bad "plist missing — run 'make install'"

# --- Loaded and running? ----------------------------------------------------
if PRINT=$(launchctl print "$DOMAIN/$PLIST_LABEL" 2>/dev/null); then
    STATE=$(echo "$PRINT" | awk -F'= ' '/^\tstate = /{print $2; exit}')
    PID=$(echo "$PRINT" | awk -F'= ' '/^\tpid = /{print $2; exit}')
    EXITCODE=$(echo "$PRINT" | awk -F'= ' '/last exit code = /{print $2; exit}')

    if [ "$STATE" = "running" ]; then
        ok "daemon running (pid ${PID:-?})"
    else
        bad "agent registered but not running (state=$STATE, last exit=${EXITCODE:-?})"
        note "launchd may have it in a penalty box; check the paths in the plist"
    fi

    CONF=$(echo "$PRINT" | sed -n '/environment = {/,/}/p')
    VID=$(echo "$CONF" | awk -F'=> ' '/DLW_VENDOR_ID/{print $2}' | tr -d ' ')
    PID_ID=$(echo "$CONF" | awk -F'=> ' '/DLW_PRODUCT_ID/{print $2}' | tr -d ' ')
    EXP=$(echo "$CONF" | awk -F'=> ' '/DLW_EXPECTED/{print $2}' | tr -d ' ')
    BSE=$(echo "$CONF" | awk -F'=> ' '/DLW_BASE/{print $2}' | tr -d ' ')
    [ -n "$VID" ] && ok "config: VID=$VID PID=$PID_ID expected=$EXP base=$BSE" \
                  || bad "no DLW_* config in the agent environment"
else
    bad "agent not registered with launchd — run 'make install'"
fi

# --- Does the config match reality? -----------------------------------------
echo ""
if [ -x "$BINARY" ]; then
    if [ -n "${VID:-}" ]; then
        DLW_VENDOR_ID="$VID" DLW_PRODUCT_ID="$PID_ID" \
        DLW_EXPECTED="$EXP" DLW_BASE="$BSE" \
        run_bounded 10 "$TMPOUT" "$BINARY" --selftest || PROBLEMS=$((PROBLEMS + 1))
    else
        run_bounded 10 "$TMPOUT" "$BINARY" --selftest || PROBLEMS=$((PROBLEMS + 1))
    fi
    if [ -s "$TMPOUT" ]; then
        sed 's/^/  /' "$TMPOUT"
    else
        note "self-test produced no output (binary too old to support --selftest)"
    fi
fi

# --- Is the log alive? ------------------------------------------------------
echo ""
if [ -f "$LOG" ]; then
    LAST=$(tail -1 "$LOG")
    LAST_TS=$(echo "$LAST" | cut -d: -f1-3)
    echo "  last log entry: $LAST_TS"
    note "$(echo "$LAST" | cut -d' ' -f2-)"

    # Log timestamps are UTC. Parsing them in local time skews the age by the
    # UTC offset and can report a negative "hours ago".
    LAST_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "${LAST_TS}Z" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date -u +%s)
    if [ "$LAST_EPOCH" -gt 0 ]; then
        AGE_H=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
        if [ "$AGE_H" -gt 24 ]; then
            bad "no log activity for ${AGE_H}h — heartbeat should appear every DLW_HEARTBEAT_HOURS (default 6)"
        else
            ok "log active (${AGE_H}h ago)"
        fi
    fi
    # `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback
    # yields a two-line value and corrupts the output.
    FIXES=$(grep -c "Restarting DisplayLink" "$LOG" 2>/dev/null | head -1 | tr -d ' ')
    note "lifetime fixes attempted: ${FIXES:-0}"
else
    bad "no log at $LOG"
fi

echo ""
if [ "$PROBLEMS" -eq 0 ]; then
    echo "Healthy. The watchdog is loaded, running, and matches your hardware."
else
    echo "$PROBLEMS problem(s) found — the watchdog may not fire when you need it."
    exit 1
fi
