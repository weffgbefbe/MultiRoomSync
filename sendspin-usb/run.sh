#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
VERSION="0.7.1"
echo "[INFO] Sendspin USB Players v${VERSION} starting (log_level=${LOG_LEVEL})"

# --- Signal handling ---
PIDS=""
cleanup() {
    echo "[INFO] Shutting down sendspin daemons..."
    for pid in $PIDS; do
        kill "$pid" 2>/dev/null || true
    done
    wait
    echo "[INFO] All daemons stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Debug: what do the audio subsystems see? ---
echo "[DEBUG] PulseAudio sinks:"
pactl list sinks short 2>&1 || echo "[DEBUG] pactl failed"
echo "[DEBUG] sendspin devices:"
sendspin --list-audio-devices 2>&1 || echo "[DEBUG] sendspin list failed"
echo "[DEBUG] ---"

# --- Enumerate PulseAudio output sinks ---
CARD_COUNT=0
SINK_LIST=$(pactl list sinks short 2>/dev/null) || true

if [ -z "$SINK_LIST" ]; then
    echo "[WARNING] No PulseAudio sinks found."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

echo "$SINK_LIST" | while IFS= read -r line; do
    # Format: "INDEX  SINK_NAME  MODULE  SAMPLE_SPEC  STATE"
    sink_name=$(echo "$line" | awk '{print $2}')
    [ -z "$sink_name" ] && continue

    # Get human-readable description for display in Music Assistant
    sink_desc=$(pactl list sinks 2>/dev/null | grep -A1 "Name: ${sink_name}$" | grep "Description:" | sed 's/.*Description: //')
    [ -z "$sink_desc" ] && sink_desc="$sink_name"

    card_id="sendspin-$(echo "$sink_name" | md5sum | cut -c1-8)"

    echo "[INFO] Starting daemon: ${sink_desc} (sink=${sink_name}, id=${card_id})"

    # Pass sink description as audio-device name prefix (sendspin matches via startswith)
    sendspin daemon \
        --name "$sink_desc" \
        --audio-device "$sink_desc" \
        --id "$card_id" \
        --log-level "$LOG_LEVEL" &
    PIDS="$PIDS $!"
    CARD_COUNT=$((CARD_COUNT + 1))
done

# Check if any daemons were started (pipe subshell issue workaround)
if ! kill -0 $PIDS 2>/dev/null; then
    echo "[WARNING] No daemons started."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

echo "[INFO] Sendspin daemons running. Waiting..."
wait
