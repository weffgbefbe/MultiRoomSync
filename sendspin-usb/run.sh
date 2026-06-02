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
VERSION="1.0.2"
# sendspin 7.x (DAC-anchored sync) needs pulsectl-asyncio to reach the HAOS PA socket.
# Without this, output_latency=0.0ms → DAC timing reference broken → silent playback.
export PULSE_SERVER="unix:/run/audio/pulse.sock"
SENDSPIN_VERSION=$(pip show sendspin 2>/dev/null | grep ^Version | awk '{print $2}')
echo "[INFO] Sendspin USB Players v${VERSION} starting (log_level=${LOG_LEVEL}, static_delay_ms=${STATIC_DELAY:-0}, audio_format=${AUDIO_FORMAT:-auto}, sendspin=${SENDSPIN_VERSION:-unknown})"

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

# --- Wait for PulseAudio ---
echo "[INFO] Waiting for PulseAudio..."
retries=0
while [ "$retries" -lt 30 ]; do
    if pactl info >/dev/null 2>&1; then
        echo "[INFO] PulseAudio ready (after ${retries}s)."
        break
    fi
    retries=$((retries + 1))
    sleep 1
done
if [ "$retries" -eq 30 ]; then
    echo "[ERROR] PulseAudio not available after 30s. Exiting."
    exit 1
fi

# Disable suspend-on-idle: sendspin 7.x DAC-anchored sync drops audio if PA
# wakes a suspended sink mid-stream (timing window missed → silence).
if pactl unload-module module-suspend-on-idle 2>/dev/null; then
    echo "[INFO] Disabled PulseAudio module-suspend-on-idle."
else
    echo "[INFO] module-suspend-on-idle not loaded (benign)."
fi

# Flush PA sink buffers to ensure active state before daemons start.
pactl list sinks short 2>/dev/null | awk '{print $2}' > /tmp/flush-sinks.txt
while IFS= read -r s; do
    [ -z "$s" ] && continue
    pactl suspend-sink "$s" 1 2>/dev/null || true
    pactl suspend-sink "$s" 0 2>/dev/null || true
    echo "[INFO] Flushed sink: $s"
done < /tmp/flush-sinks.txt
rm -f /tmp/flush-sinks.txt

# --- Debug output ---
echo "[DEBUG] PulseAudio sinks:"
pactl list sinks short 2>&1 || echo "[DEBUG] pactl failed"
echo "[DEBUG] sendspin devices:"
sendspin audio-devices list 2>&1 || echo "[DEBUG] sendspin list failed"
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
