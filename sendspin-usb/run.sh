#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
VERSION="0.2.0"
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

# --- Debug: show what audio access we have ---
echo "[DEBUG] /proc/asound/cards exists: $([ -f /proc/asound/cards ] && echo yes || echo no)"
echo "[DEBUG] /dev/snd contents: $(ls /dev/snd/ 2>/dev/null || echo 'not available')"
echo "[DEBUG] aplay -l output:"
aplay -l 2>&1 || true
echo "[DEBUG] ---"

# --- Detect audio devices via aplay -l ---
CARD_COUNT=0
APLAY_OUTPUT=$(aplay -l 2>/dev/null) || true

if [ -z "$APLAY_OUTPUT" ]; then
    echo "[WARNING] No ALSA devices found (aplay -l returned nothing)."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

# Parse "card X: <name> [<longname>]" lines from aplay -l
echo "$APLAY_OUTPUT" | grep '^card ' | while IFS= read -r line; do
    card_num=$(echo "$line" | sed 's/^card \([0-9]*\):.*/\1/')
    card_name=$(echo "$line" | sed 's/^card [0-9]*: \([^[]*\)\[.*/\1/' | sed 's/ *$//')
    [ -z "$card_name" ] && card_name="Audio-${card_num}"
    card_id="sendspin-usb-${card_num}"

    echo "[INFO] Found card ${card_num}: ${card_name} -> ${card_id}"

    sendspin daemon \
        --name "$card_name" \
        --audio-device "hw:${card_num}" \
        --id "$card_id" \
        --log-level "$LOG_LEVEL" &
    PIDS="$PIDS $!"
    CARD_COUNT=$((CARD_COUNT + 1))
done

# --- Fallback if no devices found ---
if [ "$CARD_COUNT" -eq 0 ]; then
    echo "[WARNING] No audio cards detected."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

echo "[INFO] Started ${CARD_COUNT} sendspin daemon(s). Waiting..."
wait
