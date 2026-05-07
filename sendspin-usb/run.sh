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
VERSION="0.10.9"
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

# --- Wait for PulseAudio, then disable idle-suspend ---
wait_for_pulseaudio
if pactl unload-module module-suspend-on-idle 2>/dev/null; then
    echo "[INFO] Disabled PulseAudio module-suspend-on-idle."
else
    echo "[INFO] module-suspend-on-idle not loaded or could not be unloaded (benign)."
fi

# --- USB audio device reset via USBDEVFS_RESET ioctl ---
# Simulates physical replug: resets device firmware state + triggers PA re-enumeration.
# Requires /dev/bus/usb/ access (full_access: true). Falls back gracefully if unavailable.
echo "[DEBUG] /dev/bus/usb contents:"
ls /dev/bus/usb/ 2>&1 || echo "[DEBUG] /dev/bus/usb not accessible"
python3 - <<'PYEOF' || true
import os, glob, fcntl, re, time
USBDEVFS_RESET = 0x5514
seen = set()
reset_count = 0
for iface in sorted(glob.glob('/sys/bus/usb/devices/*:*')):
    try:
        cls = open(os.path.join(iface, 'bInterfaceClass')).read().strip()
        if cls != '01':
            continue
        dev_name = re.sub(r':\d+\.\d+$', '', os.path.basename(iface))
        if dev_name in seen:
            continue
        seen.add(dev_name)
        dev_dir = '/sys/bus/usb/devices/' + dev_name
        bus = int(open(dev_dir + '/busnum').read())
        dev = int(open(dev_dir + '/devnum').read())
        path = f'/dev/bus/usb/{bus:03d}/{dev:03d}'
        print(f'[DEBUG] USB audio device: {dev_name} -> {path}', flush=True)
        if not os.path.exists(path):
            print(f'[INFO] {path} not accessible in container', flush=True)
            continue
        fd = os.open(path, os.O_WRONLY)
        fcntl.ioctl(fd, USBDEVFS_RESET, 0)
        os.close(fd)
        print(f'[INFO] USB reset sent: {dev_name} ({path})', flush=True)
        reset_count += 1
    except Exception as e:
        print(f'[DEBUG] USB reset: {e}', flush=True)
if reset_count > 0:
    print(f'[INFO] Reset {reset_count} USB audio device(s), waiting 3s for PA re-detection...', flush=True)
    time.sleep(3)
else:
    print('[INFO] No USB audio devices were reset (no access or none found)', flush=True)
PYEOF

# Flush PA hardware buffer (suspend+resume) to clear accumulated clock drift.
echo "[INFO] Flushing PulseAudio sink buffers..."
pactl list sinks short 2>/dev/null | awk '{print $2}' > /tmp/flush-sinks.txt
while IFS= read -r s; do
    [ -z "$s" ] && continue
    pactl suspend-sink "$s" 1 2>/dev/null || true
    pactl suspend-sink "$s" 0 2>/dev/null || true
    echo "[INFO] Flushed sink: $s"
done < /tmp/flush-sinks.txt
rm -f /tmp/flush-sinks.txt
sleep 1

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
