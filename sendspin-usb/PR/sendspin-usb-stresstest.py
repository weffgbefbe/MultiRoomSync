"""Fault-injection simulator for sendspin AudioPlayer (virtual clock, fake PortAudio stream).

Models a USB DAC that disappears mid-playback, the way PortAudio/ALSA behaves:
the running stream's callback thread stops; a device index cached at startup
may or may not work again after the device re-enumerates.
"""
from __future__ import annotations
import logging, sys, types
from types import SimpleNamespace

import sounddevice
import sendspin.audio as audio_mod
from sendspin.audio import AudioPlayer

SR, CH, BITS = 48_000, 2, 24
FRAME = CH * 3
BLOCK = 2048
DAC_LAT_US = 85_000           # pretend output latency
LEAD_US = 2_000_000           # server sends audio 2 s ahead
CHUNK_FRAMES = 960            # 20 ms chunks

class Clock:
    t = 1_000_000_000         # virtual monotonic µs
clock = Clock()

class Device:
    """Physical USB DAC state."""
    present = True
    generation = 0            # bumps on every re-enumeration
dev = Device()

class FakeStream:
    instances: list["FakeStream"] = []
    def __init__(self, *, callback, device, **kw):
        self.cb = callback
        self.generation = PA.gen  # PortAudio enumerates once at Pa_Initialize
        if not dev.present or (device != 2 + dev.generation and PA.gen == dev.generation):
            raise sounddevice.PortAudioError('Invalid device')
        self.started = False
        self.dead = False
        self.latency = 0.0
        self.next_cb_t = None
        FakeStream.instances.append(self)
    def start(self):
        self.started = True
        self.next_cb_t = clock.t
    def stop(self): self.started = False
    def close(self): self.dead = True
    @property
    def active(self): return self.started and not self.dead
    def tick(self):
        if not self.started or self.dead:
            return
        # USB gone, or stream bound to an old enumeration -> ALSA returns ENODEV,
        # PortAudio's callback thread terminates. No exception reaches Python.
        if not dev.present or self.generation != dev.generation and not REOPEN_WORKS:
            self.dead = True
            return
        if PAUSED:
            self.next_cb_t = clock.t
            return
        while self.next_cb_t <= clock.t:
            out = bytearray(BLOCK * FRAME)
            status = SimpleNamespace(input_underflow=False, output_underflow=False, __bool__=lambda s: False)
            class St:
                input_underflow = False; output_underflow = False
                def __bool__(self): return False
            self.cb(memoryview(out), BLOCK,
                    SimpleNamespace(outputBufferDacTime=(FROZEN_DAC if FROZEN_DAC is not None else (clock.t + DAC_LAT_US)) / 1e6), St())
            self.next_cb_t += BLOCK * 1_000_000 // SR

REOPEN_WORKS = True
class PA: gen = 0
import atexit
atexit.unregister(sounddevice._exit_handler)
def _terminate(): pass
def _initialize(): PA.gen = dev.generation
sounddevice._terminate = _terminate; sounddevice._initialize = _initialize
import sendspin.audio_devices as ad
from sendspin.audio_devices import AudioDevice
def fake_query_devices():
    # re-plugged DAC comes back with a different PortAudio index
    return [AudioDevice(index=2 + dev.generation, name="Synaptics Hi-Res Audio: USB Audio (hw:1,0)",
                        output_channels=2, sample_rate=48000.0, is_default=False)] if dev.present else []
audio_mod.query_devices = fake_query_devices
PAUSED = False
FROZEN_DAC = None
sounddevice.RawOutputStream = FakeStream
audio_mod.sounddevice.RawOutputStream = FakeStream

class InlineExecutor:
    def submit(self, fn, *a, **k): fn(*a, **k)
    def shutdown(self, wait=True): pass

def make_player():
    p = AudioPlayer(lambda ts: ts, lambda ts: ts, now_us=lambda: clock.t)
    p._stream_executor = InlineExecutor()
    return p

FMT = SimpleNamespace(pcm_format=SimpleNamespace(sample_rate=SR, channels=CH, bit_depth=BITS, frame_size=FRAME),
                      codec=SimpleNamespace(value="flac"))
DEVICE = AudioDevice(index=2, name="Synaptics Hi-Res Audio: USB Audio (hw:1,0)", output_channels=2, sample_rate=48000.0, is_default=False)

def new_stream(p, state):
    """What audio_connector does on 'stream/start': clear + set_format (reopen device 2)."""
    p.clear(); p.set_format(FMT, DEVICE)
    state["next_ts"] = clock.t + LEAD_US

def run(name, events, duration_s=60, reopen_works=True):
    global REOPEN_WORKS, PAUSED, FROZEN_DAC
    PAUSED = False; FROZEN_DAC = None
    REOPEN_WORKS = reopen_works
    dev.present, dev.generation = True, 0
    PA.gen = 0
    FakeStream.instances.clear()
    clock.t = 1_000_000_000
    t0 = clock.t
    p = make_player()
    state = {}
    new_stream(p, state)
    logs = []
    h = logging.Handler(); h.emit = lambda r: logs.append(((clock.t - t0) / 1e6, r.getMessage()))
    lg = logging.getLogger("sendspin.audio"); lg.handlers = [h]; lg.setLevel(logging.INFO); lg.propagate = False
    ev = sorted(events)
    step = 10_000
    max_err = 0; silent_since = None
    while clock.t - t0 < duration_s * 1_000_000:
        rel = (clock.t - t0) / 1e6
        while ev and ev[0][0] <= rel:
            _, action = ev.pop(0)
            action(p, state)
            logs.append((rel, f"--- EVENT {action.__name__}"))
        # server pushes audio ahead of time
        while state.get("sending", True) and state["next_ts"] < clock.t + LEAD_US:
            p.submit(state["next_ts"], b"\x01" * (CHUNK_FRAMES * FRAME))
            state["next_ts"] += CHUNK_FRAMES * 1_000_000 // SR
        if p._stream is not None:
            p._stream.tick()
        clock.t += step
    s = p._stream
    c = p._current_chunk
    real_lag = None
    if c is not None and s is not None and s.active:
        playing_ts = c.server_timestamp_us + (p._current_chunk_offset // FRAME) * 1_000_000 // SR
        real_lag = (clock.t + DAC_LAT_US - playing_ts) / 1e6
    print(f"\n=== {name}")
    for t, m in logs:
        if "Sync error" in m or "EVENT" in m or "underflow" in m.lower() or "STARTED" in m or "device" in m.lower():
            print(f"  t={t:6.1f}s  {m}")
    print(f"  END: stream active={s.active if s else None}, sync_error_filtered={p._sync_error_filtered_us/1000:.1f} ms, "
          f"queued={p._queued_duration_us/1e6:.1f}s, ECHTE Verspätung={real_lag if real_lag is None else round(real_lag,2)} s  -> {'AUDIO PLAYS' if s and s.active else 'SILENT (stuck)'}")

def usb_disconnect(p, s): dev.present = False
def usb_reconnect(p, s): dev.present = True; dev.generation += 1
def pause_callbacks(p, s):
    global PAUSED; PAUSED = True
def resume_callbacks(p, s):
    global PAUSED; PAUSED = False
def freeze_dac_clock(p, s):
    global FROZEN_DAC; FROZEN_DAC = clock.t + DAC_LAT_US
def chunks_stop(p, s): s["sending"] = False
def chunks_resume(p, s): s["sending"] = True; s["next_ts"] = clock.t + LEAD_US
def ma_stream_end(p, s): s["sending"] = False; p.close_stream()
def ma_stream_clear(p, s): s["sending"] = False; p.clear()
def ma_new_stream_after_end(p, s): s["sending"] = True; new_stream(p, s)
def ma_restarts_stream(p, s): new_stream(p, s)

if __name__ == "__main__":
    which = sys.argv[1:] or ["1","2","3","4","5","6"]
    if "1" in which: run("1 Baseline, 60 s ohne Störung", [])
    if "2" in which: run("2 USB weg bei 20 s, nach 10.5 s zurück, kein neuer Stream",
        [(20, usb_disconnect), (30.5, usb_reconnect)])
    if "3" in which: run("3 wie 2, danach neuer Stream von MA; gecachter Index 2 funktioniert zufällig wieder",
        [(20, usb_disconnect), (30.5, usb_reconnect), (35, ma_restarts_stream)])
    if "4" in which: run("4 wie 3, aber gecachter Index 2 zeigt auf die alte, tote Enumeration",
        [(20, usb_disconnect), (30.5, usb_reconnect), (35, ma_restarts_stream)], reopen_works=False)
    if "5" in which: run("5 Callbacks pausieren 10.5 s und laufen dann im selben Stream weiter",
        [(20, pause_callbacks), (30.5, resume_callbacks)])
    if "7" in which: run("7 wie 5, danach startet MA einen neuen Stream",
        [(20, pause_callbacks), (30.5, resume_callbacks), (40, ma_restarts_stream)])
    if "8" in which: run("8 wie 5, aber 120 s weiterlaufen lassen",
        [(20, pause_callbacks), (30.5, resume_callbacks)], duration_s=120)
    if "9" in which: run("9 Kurzer Aussetzer 1.5 s (unter Watchdog-Schwelle)",
        [(20, pause_callbacks), (21.5, resume_callbacks)])
    if "10" in which:
        import random
        rnd = random.Random(42); ev = []; t = 15.0
        while t < 560:
            kind = rnd.choice(["usb", "usb", "stall", "short", "restart"])
            d = rnd.uniform(0.3, 15)
            if kind == "usb": ev += [(t, usb_disconnect), (t + d, usb_reconnect)]
            elif kind == "stall": ev += [(t, pause_callbacks), (t + d, resume_callbacks)]
            elif kind == "short": ev += [(t, pause_callbacks), (t + rnd.uniform(0.2, 1.9), resume_callbacks)]
            else: ev += [(t, ma_restarts_stream)]
            t += d + rnd.uniform(5, 25)
        print(f"Stresstest: {len(ev)} Ereignisse in 10 min")
        run("10 Stresstest 10 min, zufällige USB-Abbrüche/Stalls/Stream-Neustarts", ev, duration_s=600)
    if "P1" in which: run("P1 Pause ohne stream/end: Server sendet 60 s nichts, Stream bleibt offen",
        [(20, chunks_stop), (80, chunks_resume)], duration_s=110)
    if "P2" in which: run("P2 Pause als stream/clear (Stream gestoppt), 60 s Leerlauf, dann weiter",
        [(20, ma_stream_clear), (80, chunks_resume)], duration_s=110)
    if "P3" in which: run("P3 Stop als stream/end (Stream geschlossen), 10 min Leerlauf, dann neuer Stream",
        [(20, ma_stream_end), (620, ma_new_stream_after_end)], duration_s=660)
    if "P4" in which: run("P4 Player nie gestartet: 10 min ohne jeden Stream",
        [(0.0, ma_stream_end)], duration_s=600)
    if "6" in which: run("6 Callbacks laufen weiter, aber DAC-Zeitstempel bleibt stehen",
        [(20, freeze_dac_clock)])
