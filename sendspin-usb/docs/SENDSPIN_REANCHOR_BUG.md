# Bug Report: sendspin Re-Anchor Endless Loop after PulseAudio Idle Suspend

**Target:** `Sendspin/sendspin-cli` on GitHub  
**Severity:** High — renders player unusable until manually restarted

---

## Summary

After a period of audio inactivity (reproducible at >1 hour), `sendspin daemon` enters an
endless re-anchor loop. Every attempt to start playback fails silently (fragments or complete
silence), and the only recovery is a manual process restart.

---

## Reproduction Steps

1. Start `sendspin daemon` connected to a PulseAudio sink (HAOS / hassio_audio setup)
2. Play audio briefly to confirm the player is registered and working
3. Leave the system idle with no audio output for at least 1 hour
4. Trigger playback from Music Assistant or another source
5. Observe the daemon log — the re-anchor loop starts immediately and does not resolve

**Environment:**
- Host: Home Assistant OS (hassio_audio container, PulseAudio backend)
- `sendspin` installed via pip in an Alpine Linux Docker container
- PulseAudio has `module-suspend-on-idle` loaded (default configuration)
- `static_delay_ms`: approximately −343 ms

---

## Log Output

### Variant A — ~29 second loop (typical after >1h idle)

```
INFO:sendspin.audio:Stream STARTED: 1 chunks, 0.10 seconds buffered
INFO:sendspin.audio:Sync error 29429.3 ms too large; re-anchoring
INFO:sendspin.audio:Stream STARTED: 1 chunks, 0.10 seconds buffered
INFO:sendspin.audio:Sync error 29464.8 ms too large; re-anchoring
INFO:sendspin.audio:Stream STARTED: 1 chunks, 0.10 seconds buffered
INFO:sendspin.audio:Sync error 29501.2 ms too large; re-anchoring
(repeats indefinitely)
```

The sync error value is stable (drifts only by ~35 ms per cycle), confirming the offset is
fixed and not converging.

### Variant B — ~600 ms loop (shorter idle, or after partial re-anchor)

```
INFO:sendspin.audio:Stream STARTED: 1 chunks, 0.10 seconds buffered
INFO:sendspin.audio:Sync error 612.4 ms too large; re-anchoring
INFO:sendspin.audio:Stream STARTED: 1 chunks, 0.10 seconds buffered
INFO:sendspin.audio:Sync error 647.1 ms too large; re-anchoring
(repeats indefinitely)
```

---

## Root Cause Analysis

PulseAudio's `module-suspend-on-idle` suspends the audio sink after a configurable idle
timeout (default: 5 seconds of silence). When a sink is suspended, **its device clock stops**.

`sendspin`'s internal time reference — likely `_reference_time`, `_start_timestamp`, or an
equivalent field in `sendspin/audio.py` — continues advancing while the device clock is
paused. When playback resumes:

1. sendspin receives an audio chunk and computes the playback offset relative to its internal
   reference time
2. The offset equals the duration of the clock-stopped idle period (~29 seconds in Variant A)
3. This exceeds the re-anchor threshold, so `re-anchoring` is called
4. **`re-anchoring` resets the stream's buffer/offset position, but does NOT reset the
   internal time reference**
5. The next chunk is computed against the same stale reference → identical offset → loop

The function responsible is the re-anchor logic in `sendspin/audio.py`. The stream offset is
corrected, but `self._reference_time` (or the equivalent timestamp anchor) retains the
pre-suspend wall-clock value, making every subsequent chunk appear ~29 seconds early.

---

## Proposed Fix

At the re-anchor call site in `sendspin/audio.py`, after resetting the stream offset, also
**fully invalidate the internal time reference** so it is recomputed from the next received
audio chunk — equivalent to a fresh stream start:

```python
def _re_anchor(self):
    # existing: reset stream buffer / offset
    self._stream_offset = 0
    self._chunks.clear()

    # proposed addition: discard stale time reference so next chunk re-initialises it
    self._reference_time = None   # or equivalent field name
    self._start_timestamp = None  # or equivalent field name
```

The exact field names depend on the internal implementation. The invariant to preserve is:
after re-anchoring, the next chunk received must be treated as if the stream is starting for
the first time, with no carry-over from the pre-suspend reference.

---

## Workaround (in this add-on)

1. **Disable `module-suspend-on-idle`** — *implemented in v1.0.1.* At container start,
   `run.sh` runs `pactl unload-module module-suspend-on-idle`, which prevents the device
   clock from ever stopping and eliminates the root condition.

2. **Watchdog** — *evaluated, deliberately not implemented.* A watchdog that monitors daemon
   stdout for consecutive re-anchor lines and restarts the daemon (e.g. 5 re-anchors within
   30 s → restart, max 3 restarts per 5 min) was considered as a secondary safety net.
   It was left out because mitigation 1 removes the root cause, and a prior FIFO-based
   watchdog in this project blocked the asyncio event loop for up to 16 s. Stability was
   prioritized over the extra feature. See `DOCS.md` for the rationale.
