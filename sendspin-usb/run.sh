#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
STATIC_DELAY=""
if [ -f /data/options.json ]; then
    delay=$(grep -o '"static_delay_ms"\s*:\s*[0-9.eE\-]*' /data/options.json | grep -o '[0-9.eE\-]*$')
    [ -n "$delay" ] && [ "$delay" != "0" ] && STATIC_DELAY="$delay"
fi
AUDIO_FORMAT=""
if [ -f /data/options.json ]; then
    fmt=$(grep -o '"audio_format"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$fmt" ] && AUDIO_FORMAT="$fmt"
fi
VERSION="0.9.0"
echo "[INFO] Sendspin USB Players v${VERSION} starting (log_level=${LOG_LEVEL}, static_delay_ms=${STATIC_DELAY:-0}, audio_format=${AUDIO_FORMAT:-auto})"

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

# --- Debug output ---
echo "[DEBUG] PulseAudio sinks:"
pactl list sinks short 2>&1 || echo "[DEBUG] pactl failed"
echo "[DEBUG] sendspin devices:"
sendspin --list-audio-devices 2>&1 || echo "[DEBUG] sendspin list failed"
echo "[DEBUG] ---"

# --- Enumerate PulseAudio output sinks ---
SINK_NAMES=$(pactl list sinks short 2>/dev/null | awk '{print $2}') || true

if [ -z "$SINK_NAMES" ]; then
    echo "[WARNING] No PulseAudio sinks found."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

# --- Start one sendspin daemon per sink ---
CARD_COUNT=0

# Write sink names to temp file to avoid pipe subshell
echo "$SINK_NAMES" > /tmp/sinks.txt

while IFS= read -r sink_name; do
    [ -z "$sink_name" ] && continue

    # Get human-readable description for display in Music Assistant
    sink_desc=$(pactl list sinks 2>/dev/null | grep -A1 "Name: ${sink_name}$" | grep "Description:" | sed 's/.*Description: //')
    [ -z "$sink_desc" ] && sink_desc="$sink_name"

    card_id="sendspin-$(echo "$sink_name" | md5sum | cut -c1-8)"

    echo "[INFO] Starting daemon: ${sink_desc} (device=${sink_name}, id=${card_id})"

    # Pass PulseAudio sink name as audio-device (matches sendspin device name exactly)
    sendspin daemon \
        --name "$sink_desc" \
        --audio-device "$sink_name" \
        --id "$card_id" \
        --log-level "$LOG_LEVEL" \
        ${STATIC_DELAY:+--static-delay-ms "$STATIC_DELAY"} \
        ${AUDIO_FORMAT:+--audio-format "$AUDIO_FORMAT"} &
    PIDS="$PIDS $!"
    CARD_COUNT=$((CARD_COUNT + 1))

done < /tmp/sinks.txt

if [ "$CARD_COUNT" -eq 0 ]; then
    echo "[WARNING] No daemons started."
    tail -f /dev/null &
    wait
    exit 0
fi

echo "[INFO] Started ${CARD_COUNT} sendspin daemon(s). Waiting..."
wait
