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
VERSION="0.10.4"
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

# --- Wait for PulseAudio to become ready ---
wait_for_pulseaudio() {
    local retries=0
    echo "[INFO] Waiting for PulseAudio..."
    while [ "$retries" -lt 30 ]; do
        if pactl info >/dev/null 2>&1; then
            echo "[INFO] PulseAudio ready (after ${retries}s)."
            return 0
        fi
        retries=$((retries + 1))
        sleep 1
    done
    echo "[ERROR] PulseAudio not available after 30s. Exiting."
    exit 1
}

# Reset the USB audio device via sysfs (equivalent to unplugging and replugging).
# This resets the USB device's hardware clock PLL to zero, eliminating the clock
# drift that accumulates over hours (~100ppm) and causes sendspin's initial sync
# error. PulseAudio detects the removal/re-addition via module-udev-detect and
# recreates the sink with a fresh, accurately-timed clock.
# Falls back to PA buffer flush if sysfs access is unavailable.
reset_usb_audio_device() {
    local sysfs_path
    sysfs_path=$(pactl list sinks 2>/dev/null | grep "sysfs.path" | head -1 | \
        sed 's/.*"\(.*\)".*/\1/')
    if [ -z "$sysfs_path" ]; then
        echo "[INFO] No USB sink sysfs path found, skipping USB reset."
        return 1
    fi

    # Strip interface/sound suffix to reach the USB device root
    # e.g. /devices/.../usb2/2-4/2-4:1.0/sound/card1 → /sys/.../usb2/2-4
    local usb_dev_path
    usb_dev_path=$(printf '/sys%s' "$sysfs_path" | sed 's|/[0-9]*-[0-9.]*:[0-9]*\.[0-9]*/.*||')
    local authorized="${usb_dev_path}/authorized"

    if [ ! -f "$authorized" ]; then
        echo "[INFO] $authorized not found, skipping USB reset."
        return 1
    fi

    echo "[INFO] Resetting USB audio device at $usb_dev_path..."
    if ! printf '0' > "$authorized" 2>/dev/null; then
        echo "[INFO] USB reset not permitted (no sysfs write access), using PA flush instead."
        return 1
    fi
    sleep 1
    printf '1' > "$authorized" 2>/dev/null || { echo "[WARN] USB re-enable failed."; return 1; }

    echo "[INFO] USB reset done. Waiting for PulseAudio to re-detect sink..."
    local retries=0
    while [ "$retries" -lt 20 ]; do
        if pactl list sinks short 2>/dev/null | grep -q "alsa_output.usb"; then
            echo "[INFO] USB sink redetected (after ${retries}s)."
            return 0
        fi
        retries=$((retries + 1))
        sleep 1
    done
    echo "[WARN] USB sink did not reappear within 20s."
    return 1
}

# --- Wait for PulseAudio, then disable idle-suspend ---
wait_for_pulseaudio
if pactl unload-module module-suspend-on-idle 2>/dev/null; then
    echo "[INFO] Disabled PulseAudio module-suspend-on-idle."
else
    echo "[INFO] module-suspend-on-idle not loaded or could not be unloaded (benign)."
fi

# Reset USB device clock (primary fix) or flush PA buffer (fallback).
# The USB audio hardware clock drifts ~100ppm from PA's software clock over hours,
# causing sendspin to receive inaccurate PortAudio timestamps and enter a sync loop.
# A USB reset re-enumerates the device with a fresh PLL — identical to HAOS restart
# for the audio subsystem. If sysfs access is unavailable, flushing the PA buffer
# via suspend(1)+resume(0) removes accumulated drift from the hardware buffer.
if reset_usb_audio_device; then
    sleep 2
else
    echo "[INFO] Flushing PulseAudio sink buffers (fallback)..."
    pactl list sinks short 2>/dev/null | awk '{print $2}' > /tmp/flush-sinks.txt
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        pactl suspend-sink "$s" 1 2>/dev/null || true
        pactl suspend-sink "$s" 0 2>/dev/null || true
        echo "[INFO] Flushed sink: $s"
    done < /tmp/flush-sinks.txt
    rm -f /tmp/flush-sinks.txt
    sleep 2
fi

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
