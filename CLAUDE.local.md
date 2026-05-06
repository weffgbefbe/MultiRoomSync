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

## static_delay_ms

- Vor sendspin 7.0: manuell groß-negativ setzen (z.B. `-390.5`) um Hardware-Latenz zu kompensieren
- Ab sendspin 7.0+: Auto-Kompensation eingebaut → Wert auf `0` oder kleinen positiven Wert setzen
- Empfehlung: `0` als Startpunkt, dann in ±25ms-Schritten für Multi-Room-Sync tunen

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

## Was funktioniert (aktueller Stand v0.10.7)

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
