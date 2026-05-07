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
- **`/sys` ist read-only** → USB-Reset via sysfs funktioniert NICHT (auch mit `full_access: true`)
- **PortAudio muss from source gebaut werden** — Alpine hat kein Paket mit PulseAudio-Backend
- `ALSA_CONFIG_PATH` NICHT setzen — überschreibt HAOS PulseAudio-Redirect

## sendspin Versionen — KRITISCH beim Upgrade

**Aktuell: `sendspin<7.0.0`** (Dockerfile-Pin)

sendspin 7.0 führte "DAC-anchored sync" ein — einen grundlegend anderen Sync-Algorithmus. Bestätigt durch Test (Mai 2026):
- `sendspin<7.0.0` + bestehender `static_delay_ms`-Wert → Sync korrekt ✓
- `sendspin 7.3.0` + gleicher `static_delay_ms`-Wert → Sync falsch ✗

**Bei Upgrade auf sendspin 7.x:** `static_delay_ms` muss komplett neu kalibriert werden (von 0 ausgehend, nach Gehör). Der alte Wert ist nicht übertragbar.

Wire-Protokoll: sendspin 7.3.0 ist mit MA 2.8.6 kompatibel (Protokoll "version 1" — durch Handshake-Logs bestätigt). Nur die Sync-Kalibrierung ist inkompatibel.

## static_delay_ms

- Akustischer Pfad (DAC → Verstärker → Lautsprecher) ist nie automatisch messbar
- Kalibrierung ausschließlich durch Hören — kein Software-Tool ersetzt das
- 1–2ms Timing-Jitter im Betrieb ist die architektonische Untergrenze (USB-DAC-Takt vs. Netzwerktakt) — nicht reduzierbar von unserer Seite, nicht weiter relevant

## Bekannte offene Probleme

**Physisches USB-Replug** ist der einzige bekannte Fix wenn der DAC nach langem Betrieb in einen schlechten Hardware-Zustand gerät. Software-Simulation bisher nicht gelungen:
- `pactl suspend-sink 1+0`: setzt nur PA-Software-Buffer zurück — unzureichend
- sysfs unbind/bind: read-only in HAOS — unmöglich
- `USBDEVFS_RESET` ioctl via `/dev/bus/usb/`: Code in v0.10.9 vorhanden, aber in HAOS noch ungetestet

## Was nicht funktioniert (getestet)

| Ansatz | Ergebnis |
|---|---|
| USB-Reset via `/sys/bus/usb/.../authorized` | Read-only in HAOS — scheitert lautlos |
| `pacat < /dev/zero` Warmup parallel zum Daemon | PA-Latenz steigt von ~562ms auf ~1557ms |
| FIFO-basierter Watchdog (daemon_wrapper) | Blockiert asyncio Event-Loop bis zu 16s |
| `pactl suspend-sink 1 + 0` als Buffer-Flush | Nur PA-Software-Layer, nicht USB-Hardware-State |

## Push

Geht nicht aus der Claude-Shell — User muss selbst pushen:
```bash
cd ~/Schreibtisch/Projekte/MultiRoomSync && git push
```
Nach Push: HAOS Add-on Store → **Neu-Installieren** wenn Dockerfile geändert wurde.
