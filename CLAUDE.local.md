# MultiRoomSync — Projektspezifische Hinweise

## Was dieses Projekt ist

Minimales HAOS Add-on (`sendspin-usb/`) das USB-Audio-Geräte via PulseAudio erkennt und pro Sink einen `sendspin daemon` startet. Jeder Daemon meldet sich als Music-Assistant-Player an.

Stack: Alpine Linux Container → PortAudio (from source) → PulseAudio (HAOS hassio_audio) → USB-DAC

## Versionierung

**Schema: Semantic Versioning (semver) — MAJOR.MINOR.PATCH**

| Typ | Wann | Beispiel |
|---|---|---|
| MAJOR | Nutzer muss manuell eingreifen (Neu-Kalibrierung, Neu-Installation) | sendspin 7.x Upgrade |
| MINOR | Neue Funktion, rückwärtskompatibel | Neues Config-Feld |
| PATCH | Bugfix ohne Nutzeraktion nötig | PULSE_SERVER-Fix |

**Regel: Jeder Commit mit Funktionsänderung bekommt einen Versionsbump — keine Ausnahme.**
Der Versionsbump gehört in denselben Commit wie die Änderung selbst, nie nachträglich.
HAOS erkennt Updates **ausschließlich** über die Versionsnummer in `config.yaml`.

Beim Bump immer **beide** Dateien gleichzeitig anpassen:
- `sendspin-usb/config.yaml` → `version: "X.Y.Z"`
- `sendspin-usb/run.sh` → `VERSION="X.Y.Z"`

Erste Log-Zeile zeigt immer: `[INFO] Sendspin USB Players vX.Y.Z starting`

## Git-Workflow

Claude erledigt: `git add`, `git commit`
User erledigt nur: `git push`

Nach Push:
- **Update** reicht wenn nur `run.sh`/`DOCS.md`/`config.yaml` geändert
- **Neu-Installieren** wenn `Dockerfile` geändert wurde

## HAOS-spezifische Fallen

- **`/proc/asound/` existiert nicht** in HAOS-Containern → kein ALSA-Device-Listing
- **`/etc` ist read-only** → Configs nach `/tmp` schreiben
- **`/sys` ist read-only** → USB-Reset via sysfs funktioniert NICHT (auch mit `full_access: true`)
- **PortAudio muss from source gebaut werden** — Alpine hat kein Paket mit PulseAudio-Backend
- `ALSA_CONFIG_PATH` NICHT setzen — überschreibt HAOS PulseAudio-Redirect

## sendspin Versionen — KRITISCH beim Upgrade

**Aktuell: `sendspin~=7.3`** (Dockerfile-Pin, seit v1.0.0)

sendspin 7.0 führte "DAC-anchored sync" ein — einen grundlegend anderen Sync-Algorithmus:
- `static_delay_ms` Vorzeichen umgedreht: Player zu spät → **positiver** Wert (in 6.x war es negativ)
- `PULSE_SERVER="unix:/run/audio/pulse.sock"` muss gesetzt sein — damit pulsectl-asyncio den HAOS-PA-Socket findet (Hardware-Volume-Check)
- `sendspin --list-audio-devices` heißt jetzt `sendspin audio-devices list`
- `output_latency=0.0ms` im Log ist **normal** mit PortAudio+PulseAudio — kein Fehler, kein Fix nötig

Wire-Protokoll: sendspin 7.3.x ist mit MA 2.8.8 kompatibel (Protokoll "version 1"). Nur die Sync-Kalibrierung ist inkompatibel zu 6.x-Werten.

## static_delay_ms

- Akustischer Pfad (DAC → Verstärker → Lautsprecher) ist nie automatisch messbar
- Jedes Setup hat andere Hardware (DAC-Modell, Verstärker, Lautsprecher, Raumakustik) → der Delay ist immer individuell
- Kalibrierung ausschließlich durch Hören — kein Software-Tool ersetzt das, kein Log-Wert gibt den echten Delay an
- 1–2ms Timing-Jitter im Betrieb ist die architektonische Untergrenze (USB-DAC-Takt vs. Netzwerktakt) — nicht reduzierbar von unserer Seite, nicht weiter relevant

## Bekannte offene Probleme

**Physisches USB-Replug** ist der einzige bekannte Fix wenn der DAC nach langem Betrieb in einen schlechten Hardware-Zustand gerät. Software-Simulation bisher nicht gelungen:
- `pactl suspend-sink 1+0`: setzt nur PA-Software-Buffer zurück — unzureichend
- sysfs unbind/bind: read-only in HAOS — unmöglich
- `USBDEVFS_RESET` ioctl via `/dev/bus/usb/`: Code in v0.10.9 vorhanden, aber in HAOS noch ungetestet

## PA Hardware-Volume — KRITISCH

sendspin's Hardware-Volume-Matching schlägt auf diesem Gerät fehl (`no sink matched device`-Warning im Log). Dadurch kann sendspin die PA-Sink-Lautstärke nie selbst korrigieren.

**Ursache für stilles Audio:** PA-Sink-Lautstärke war 9% (-62.75 dB) — durch HAOS/MA irgendwann gesetzt, nie zurückgesetzt.

**Fix in run.sh (v0.9.2+):** Vor jedem Daemon-Start:
```sh
pactl set-sink-volume "$sink_name" 100%
pactl set-sink-mute "$sink_name" 0
```

**Prüfung:** `PULSE_SERVER=unix:/run/audio/pulse.sock pactl get-sink-volume 0`

Diese beiden Zeilen sind zwingend — ohne sie kann HAOS/MA die Hardware-Lautstärke jederzeit auf 0 setzen und das Add-on bleibt still, obwohl sendspin korrekt spielt (RUNNING im Log).

## Was nicht funktioniert (getestet)

| Ansatz | Ergebnis |
|---|---|
| USB-Reset via `/sys/bus/usb/.../authorized` | Read-only in HAOS — scheitert lautlos |
| `pacat < /dev/zero` Warmup parallel zum Daemon | PA-Latenz steigt von ~562ms auf ~1557ms |
| FIFO-basierter Watchdog (daemon_wrapper) | Blockiert asyncio Event-Loop bis zu 16s |
| `pactl suspend-sink 1 + 0` als Buffer-Flush | Nur PA-Software-Layer, nicht USB-Hardware-State |

## Push

Geht nicht aus der Claude-Shell — User führt nur aus:
```bash
cd ~/Schreibtisch/Projekte/MultiRoomSync && git push
```
