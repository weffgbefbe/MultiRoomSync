#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
echo "[INFO] Sendspin USB Players starting (log_level=${LOG_LEVEL})"

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

# --- Detect audio devices from /proc/asound/cards ---
if [ ! -f /proc/asound/cards ]; then
    echo "[WARNING] /proc/asound/cards not found — no ALSA devices available."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

CARD_COUNT=0

while IFS= read -r line; do
    # Lines with card numbers look like: " 1 [K5Pro          ]: USB-Audio - FiiO K5 Pro"
    card_num=$(echo "$line" | grep -oE '^\s*[0-9]+' | tr -d ' ')
    [ -z "$card_num" ] && continue

    # Next line has the long name — but we can parse name from this line too
    card_name=$(echo "$line" | sed 's/.*- //')
    [ -z "$card_name" ] && card_name="USB-Audio-${card_num}"

    # Sanitize name for use as ID
    card_id="sendspin-usb-${card_num}"

    echo "[INFO] Found card ${card_num}: ${card_name} -> ${card_id}"

    sendspin daemon \
        --name "$card_name" \
        --audio-device "hw:${card_num}" \
        --id "$card_id" \
        --log-level "$LOG_LEVEL" &
    PIDS="$PIDS $!"
    CARD_COUNT=$((CARD_COUNT + 1))

done < /proc/asound/cards

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
