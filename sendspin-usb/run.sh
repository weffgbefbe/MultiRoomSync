#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
VERSION="0.3.0"
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
echo "[DEBUG] /dev/snd contents: $(ls /dev/snd/ 2>/dev/null || echo 'not available')"
echo "[DEBUG] /dev/snd/by-id: $(ls /dev/snd/by-id/ 2>/dev/null || echo 'not available')"

# --- Detect audio devices from /dev/snd playback nodes ---
CARD_COUNT=0

for pcm in /dev/snd/pcmC*D*p; do
    [ -e "$pcm" ] || continue
    # Extract card number from pcmC<num>D<dev>p
    card_num=$(echo "$pcm" | sed 's|.*/pcmC\([0-9]*\)D.*|\1|')

    # Try to get friendly name from by-id symlinks
    card_name=""
    for link in /dev/snd/by-id/*; do
        [ -e "$link" ] || continue
        target=$(readlink "$link")
        if echo "$target" | grep -q "controlC${card_num}$"; then
            card_name=$(basename "$link" | sed 's/^usb-//' | sed 's/-[0-9]*$//')
            break
        fi
    done
    [ -z "$card_name" ] && card_name="Audio-Card-${card_num}"

    card_id="sendspin-usb-${card_num}"

    echo "[INFO] Found card ${card_num}: ${card_name} -> hw:${card_num}"

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
    echo "[WARNING] No playback devices found in /dev/snd/."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

echo "[INFO] Started ${CARD_COUNT} sendspin daemon(s). Waiting..."
wait
