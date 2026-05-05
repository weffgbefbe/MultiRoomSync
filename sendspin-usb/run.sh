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
VERSION="0.10.0"
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

# --- Watchdog wrapper: runs one sendspin daemon with restart + re-anchor detection ---
daemon_wrapper() {
    set +e
    local desc="$1"
    local device="$2"
    local cid="$3"
    local fifo="/tmp/sd-${cid}.fifo"
    local restart_count=0
    local first_restart_time=0
    local inner_pid=""
    local anchor_count=0
    local anchor_window_start=0
    local do_restart=0
    local now=0
    local line_time=0
    local window_age=0
    local elapsed=0
    local line=""

    _wrapper_cleanup() {
        [ -n "$inner_pid" ] && kill "$inner_pid" 2>/dev/null
        rm -f "$fifo"
        exit 0
    }
    trap _wrapper_cleanup SIGTERM SIGINT

    while true; do
        # Enforce restart rate limit: max 3 restarts within 300s
        now=$(date +%s)
        if [ "$restart_count" -ge 3 ]; then
            echo "[ERROR] Watchdog [${desc}]: max restarts (3) reached within 300s. Giving up."
            rm -f "$fifo"
            exit 1
        fi
        if [ "$restart_count" -gt 1 ]; then
            elapsed=$((now - first_restart_time))
            if [ "$elapsed" -ge 300 ]; then
                restart_count=1
                first_restart_time=$now
            fi
        fi

        [ "$restart_count" -gt 0 ] && \
            echo "[WARN] Watchdog [${desc}]: restarting daemon (attempt ${restart_count}/3)..."

        # Reset per-run monitoring state
        anchor_count=0
        anchor_window_start=0
        do_restart=0

        # Create FIFO to decouple daemon writer from monitoring reader
        rm -f "$fifo"
        mkfifo "$fifo"

        # Start daemon writing to FIFO; track its PID for targeted kill
        sendspin daemon \
            --name "$desc" \
            --audio-device "$device" \
            --id "$cid" \
            --log-level "$LOG_LEVEL" \
            ${STATIC_DELAY:+--static-delay-ms "$STATIC_DELAY"} \
            ${AUDIO_FORMAT:+--audio-format "$AUDIO_FORMAT"} \
            > "$fifo" 2>&1 &
        inner_pid=$!

        # Monitor daemon output line by line
        while IFS= read -r line; do
            echo "[${desc}] $line"
            case "$line" in
                *"too large; re-anchoring"*)
                    line_time=$(date +%s)
                    # Start window on first re-anchor in a sequence
                    [ "$anchor_count" -eq 0 ] && anchor_window_start="$line_time"
                    window_age=$((line_time - anchor_window_start))
                    if [ "$window_age" -le 30 ]; then
                        anchor_count=$((anchor_count + 1))
                        echo "[WARN] Watchdog [${desc}]: re-anchor #${anchor_count}/5 detected"
                        if [ "$anchor_count" -ge 5 ]; then
                            echo "[WARN] Watchdog [${desc}]: loop detected, killing daemon (pid=${inner_pid})"
                            kill "$inner_pid" 2>/dev/null
                            do_restart=1
                            break
                        fi
                    else
                        # Window expired; start fresh window with this event
                        anchor_count=1
                        anchor_window_start="$line_time"
                        echo "[WARN] Watchdog [${desc}]: re-anchor #1/5 (new 30s window)"
                    fi
                    ;;
                *"Sync error:"*)
                    # Line has "Sync error:" but not "too large" → stable sync; reset counter
                    anchor_count=0
                    anchor_window_start=0
                    ;;
            esac
        done < "$fifo"

        wait "$inner_pid" 2>/dev/null
        inner_pid=""
        rm -f "$fifo"

        restart_count=$((restart_count + 1))
        [ "$restart_count" -eq 1 ] && first_restart_time=$(date +%s)
    done
}

# --- Wait for PulseAudio, then disable idle-suspend to prevent device-clock drift ---
wait_for_pulseaudio
if pactl unload-module module-suspend-on-idle 2>/dev/null; then
    echo "[INFO] Disabled PulseAudio module-suspend-on-idle."
else
    echo "[INFO] module-suspend-on-idle not loaded or could not be unloaded (benign)."
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

# --- Start one watchdog-wrapped sendspin daemon per sink ---
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

    daemon_wrapper "$sink_desc" "$sink_name" "$card_id" &
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
