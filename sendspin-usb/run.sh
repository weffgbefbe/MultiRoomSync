#!/bin/sh
set -e

# --- Read HAOS options ---
LOG_LEVEL="INFO"
if [ -f /data/options.json ]; then
    level=$(grep -o '"log_level"\s*:\s*"[^"]*"' /data/options.json | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$level" ] && LOG_LEVEL="$level"
fi
VERSION="0.5.0"
export ALSA_CONFIG_PATH="/tmp/asound.conf"
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

    # --- Create ALSA config so PortAudio can find the device ---
    cat >> /tmp/asound.conf <<ALSA
pcm.card${card_num} {
    type hw
    card ${card_num}
}
ctl.card${card_num} {
    type hw
    card ${card_num}
}
ALSA

    CARD_COUNT=$((CARD_COUNT + 1))
    # Store for later (sh-compatible, no arrays)
    eval "CARD_NUM_${CARD_COUNT}=${card_num}"
    eval "CARD_NAME_${CARD_COUNT}=${card_name}"
done

if [ "$CARD_COUNT" -eq 0 ]; then
    echo "[WARNING] No playback devices found in /dev/snd/."
    echo "[WARNING] Idling. Restart add-on after connecting USB audio."
    tail -f /dev/null &
    wait
    exit 0
fi

# Set first detected card as default
eval "first_card=\$CARD_NUM_1"
cat >> /tmp/asound.conf <<ALSA
pcm.!default {
    type hw
    card ${first_card}
}
ctl.!default {
    type hw
    card ${first_card}
}
ALSA

echo "[DEBUG] /tmp/asound.conf:"
cat /tmp/asound.conf
echo "[DEBUG] ---"

# --- Debug: what does PortAudio/sounddevice see? ---
echo "[DEBUG] sounddevice devices:"
python3 -c "import sounddevice; print(sounddevice.query_devices())" 2>&1 || echo "[DEBUG] sounddevice query failed"
echo "[DEBUG] ---"

# --- Start daemons ---
i=1
while [ "$i" -le "$CARD_COUNT" ]; do
    eval "card_num=\$CARD_NUM_${i}"
    eval "card_name=\$CARD_NAME_${i}"
    card_id="sendspin-usb-${card_num}"

    echo "[INFO] Starting daemon for card ${card_num}: ${card_name} -> hw:${card_num}"

    sendspin daemon \
        --name "$card_name" \
        --audio-device "hw:${card_num}" \
        --id "$card_id" \
        --log-level "$LOG_LEVEL" &
    PIDS="$PIDS $!"
    i=$((i + 1))
done

echo "[INFO] Started ${CARD_COUNT} sendspin daemon(s). Waiting..."
wait
