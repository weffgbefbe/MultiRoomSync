#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
VERSION="0.6.0"
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

# --- Diagnostic output ---
echo "[DEBUG] /dev/snd contents: $(ls /dev/snd/ 2>/dev/null || echo 'not available')"
echo "[DEBUG] /run/audio contents: $(ls /run/audio/ 2>/dev/null || echo 'not available')"
echo "[DEBUG] /etc/pulse/client.conf:"
cat /etc/pulse/client.conf 2>/dev/null || echo "[DEBUG] not found"
echo "[DEBUG] /etc/asound.conf:"
cat /etc/asound.conf 2>/dev/null || echo "[DEBUG] not found"
echo "[DEBUG] ---"

echo "[DEBUG] PulseAudio sinks (pactl):"
pactl list sinks short 2>&1 || echo "[DEBUG] pactl failed"
echo "[DEBUG] ---"

echo "[DEBUG] PortAudio devices (sounddevice):"
python3 -c "import sounddevice; print(sounddevice.query_devices())" 2>&1 || echo "[DEBUG] sounddevice query failed"
echo "[DEBUG] ---"

echo "[DEBUG] sendspin audio devices:"
sendspin --list-audio-devices 2>&1 || echo "[DEBUG] sendspin list failed"
echo "[DEBUG] ---"

# --- Detect players via PulseAudio sinks ---
CARD_COUNT=0

pactl list sinks short 2>/dev/null | while IFS= read -r line; do
    # Format: "INDEX  SINK_NAME  MODULE  SAMPLE_SPEC  STATE"
    sink_name=$(echo "$line" | awk '{print $2}')
    [ -z "$sink_name" ] && continue

    # Get human-readable description
    sink_desc=$(pactl list sinks 2>/dev/null | grep -A1 "Name: ${sink_name}" | grep "Description:" | sed 's/.*Description: //')
    [ -z "$sink_desc" ] && sink_desc="$sink_name"

    card_id="sendspin-$(echo "$sink_name" | sed 's/[^a-zA-Z0-9]/-/g')"

    echo "[INFO] Found PulseAudio sink: ${sink_name} (${sink_desc})"
done

echo "[INFO] Diagnostic complete. Check output above."
echo "[INFO] Idling for log inspection..."
tail -f /dev/null &
wait
