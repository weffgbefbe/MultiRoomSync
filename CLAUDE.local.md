# MultiRoomSync — Projektspezifische Hinweise

## Was dieses Projekt ist

Minimales HAOS Add-on (`sendspin-usb/`) das USB-Audio-Geräte via PulseAudio erkennt und pro Sink einen `sendspin daemon` startet. Jeder Daemon meldet sich als Music-Assistant-Player an.

Stack: Alpine Linux Container → PortAudio (from source) → PulseAudio (HAOS hassio_audio) → USB-DAC

## Versionierung

Beim Bump immer **beide** Dateien anpassen:
- `sendspin-usb/config.yaml` → `version: "X.Y.Z"`
- `sendspin-usb/run.sh` → `VERSION="X.Y.Z"`

Erste Log-Zeile zeigt immer: `[INFO] Sendspin USB Players vX.Y.Z starting`

## HAOS-spezifische Fallen

- **`/proc/asound/` existiert nicht** in HAOS-Containern → kein ALSA-Device-Listing
- **`/etc` ist read-only** → Configs nach `/tmp` schreiben
- **`/sys` ist read-only** → USB-Reset via sysfs funktioniert NICHT
- **PortAudio muss from source gebaut werden** — Alpine hat kein Paket mit PulseAudio-Backend
- `ALSA_CONFIG_PATH` NICHT setzen — überschreibt HAOS PulseAudio-Redirect
- `audio: true` mountet PA-Socket, `full_access: true` aber sysfs bleibt read-only

## sendspin Pakete (wichtig zu verstehen)

Zwei separate PyPI-Pakete:
- `sendspin` — der Client-Daemon (was wir installieren), aktuell `>=7.3.0`
- `aiosendspin` — geteilte Protokoll-Bibliothek; `sendspin 7.3.0` braucht `aiosendspin ~= 5.2`

MA 2.8.x nutzt `aiosendspin 4.2.0` server-seitig → **trotzdem kompatibel** (beide sprechen Wire-Protokoll "version 1", bewiesen durch Handshake-Logs).

`sendspin>=7.3.0` ist der korrekte Pin — enthält Fix für "unwanted catch-up when joining mid-stream playback".

## static_delay_ms — KRITISCH

**Definitive Erkenntnis (v0.10.8-Log-Analyse):**

`static_delay_ms=-390.5` + sendspin 7.3.0 DAC-anchored sync = Audio-Fetzen.

Beweis aus Log:
```
INFO:sendspin.audio:Audio stream configured: output_latency=0.0 ms
DEBUG:sendspin.audio:Sync error: 6.7 ms, buffer: 0.00 s, speed: 120.48%, dropped: 9832
```

`output_latency=0.0ms` bedeutet: sendspin hat Hardware-Latenz gemessen und kompensiert (DAC-anchored).
Zusätzliches `-390.5ms` bewirkt Doppelkompensation → sendspin kann Timestamps nicht erfüllen → 115–120% Speed → ~9000 Samples/Callback gedroppt → Fetzen.

**Regel:** 
- sendspin 7.x verspricht Auto-Kompensation, aber über PulseAudio (HAOS) meldet PortAudio `output_latency=0.0ms` → Auto-Kompensation schlägt fehl
- Deshalb: manueller Wert (z.B. `-390`) bleibt nötig — wie vor 7.0
- Fetzen entstehen NICHT direkt durch `-390ms`, sondern durch den Reanchor-Nacheffekt: Speed-Controller überschwingt nach Reanchor mit großem negativem Ziel
- Reanchor triggert wenn MA > ~500ms spielt bevor sendspin verbindet → Workaround: MA stoppen, Add-on neustarten, dann MA starten

## Re-Anchor-Loop (bekannter Bug)

**Ursache:** sendspin's Re-Anchor-Algorithmus resettet den Stream-Offset aber nicht die interne Zeitreferenz → gleicher Fehler sofort wieder → Endlosschleife.

**Trigger:** Sync-Fehler > Threshold (~500ms) beim ersten Audio-Chunk nach Verbindungsaufbau. Dieser Fehler entspricht: Zeit die MA seit Beginn des aktuellen Streams gespielt hat.

**Workaround:** Add-on in HAOS neustarten. Wird besser wenn MA gleichzeitig neustartet (gemeinsame Zeitbasis).

**Upstream-Fix:** `sendspin 7.3.0` behebt "unwanted catch-up when joining mid-stream" — hilft bei kleinen Offsets. Sehr große Offsets (>10s, nach langem Daemon-Crash) können weiterhin initial einen kurzen Loop verursachen, erholen sich aber.

## Dinge die wir versucht haben (und warum sie nicht funktionieren)

| Ansatz | Ergebnis |
|---|---|
| `pactl suspend-sink 0` auf IDLE-Sink | No-op — IDLE ≠ SUSPENDED |
| USB-Reset via `/sys/bus/usb/.../authorized` | Read-only filesystem in HAOS |
| `pacat < /dev/zero` Warmup (parallel zum Daemon) | Zwei Clients auf gleicher PA-Sink erhöhen Latenz von ~562ms auf ~1557ms — macht es schlechter |
| FIFO-basierter Watchdog (daemon_wrapper) | FIFO-Backpressure blockiert asyncio Event-Loop für bis zu 16s → verschlimmert Sync-Fehler massiv |
| `pactl suspend-sink 1 + suspend-sink 0` (Buffer-Flush) | Hilft gegen akkumulierte PA-Latenz (1.23s → ~0), aber nicht gegen MA-Stream-Timing |

## Was funktioniert (aktueller Stand v0.10.8)

- `wait_for_pulseaudio()` → wartet auf PA
- `pactl unload-module module-suspend-on-idle` → verhindert zukünftige Suspensions
- USB-Reset-Versuch (schlägt fehl, macht nichts)
- PA-Flush (suspend 1 + 0) als Fallback → räumt akkumulierten PA-Puffer auf
- Direkter `sendspin daemon ... &` (kein Wrapper, kein FIFO)

## Push

Geht nicht aus der Claude-Shell — User muss selbst pushen:
```bash
cd ~/Schreibtisch/Projekte/MultiRoomSync && git push
```
Nach Push: HAOS Add-on Store → **Neu-Installieren** (nicht nur Update) wenn Dockerfile geändert wurde.
