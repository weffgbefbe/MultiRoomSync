# Sendspin USB Players

## Konfiguration

### log_level

Detailgrad der Log-Ausgabe. Standard: `INFO`.

> **Wichtig:** `DEBUG` im Dauerbetrieb vermeiden. Das Add-on loggt bei DEBUG-Level ~23 Zeilen pro Sekunde, was Python's asyncio Event-Loop kurzzeitig blockieren kann und den Sync-Loop begünstigt. `DEBUG` nur kurz zur Fehleranalyse aktivieren, danach auf `INFO` zurücksetzen.

### static_delay_ms

Korrigiert den Zeitversatz eines Players in Millisekunden. Standard: `0`.

**So findest du den richtigen Wert:**

1. Starte mit `0` und prüfe ob die Wiedergabe zeitlich stimmt
2. Spiele Musik auf zwei oder mehr Playern gleichzeitig ab
3. Höre genau hin, welcher Player voraus oder hinterher ist
4. Passe den Wert in 25ms-Schritten an:
   - Player spielt **zu spät** → positiver Wert (z.B. `390`)
   - Player spielt **zu früh** → negativer Wert (z.B. `-25`)
5. Speichern, Add-on neustarten, erneut testen

> **Upgrade von v0.9.x:** sendspin 7.x verwendet einen neuen Sync-Algorithmus. Das Vorzeichen hat sich umgedreht und der alte Wert gilt nicht mehr — bitte von `0` neu kalibrieren.

> **Fetzen/Aussetzer trotz korrektem Wert?** Das ist ein bekanntes Problem wenn Music Assistant bereits längere Zeit spielt bevor das Add-on startet. Abhilfe: MA-Wiedergabe stoppen, Add-on neustarten, dann Wiedergabe neu starten.

### audio_format

Erzwingt ein einheitliches Audio-Format für alle Player. Standard: leer (automatisch).

Format: `codec:samplerate:bitdepth:channels`

**Beispiele:**

| Wert | Bedeutung |
|------|-----------|
| _(leer)_ | Automatisch (Standard) |
| `flac:44100:16:2` | CD-Qualität, verlustfrei |
| `flac:48000:24:2` | Hi-Res, verlustfrei |

Alle Player im selben Sync-Verbund sollten das gleiche Format verwenden, um Resampling-Unterschiede zu vermeiden.

## Fehlerbehebung

### DBus/MPRIS-Warnung (behoben)

Frühere Versionen zeigten bei jedem Player-Start:

```
WARNING:aiosendspin_mpris.mpris_service:MPRIS not available: DBus address error
```

MPRIS braucht einen Session-DBus, den es im HAOS-Add-on-Container (headless, `init: false`) nicht gibt — und MPRIS ist hier ohnehin nutzlos, weil die Steuerung über Music Assistant läuft. Seit **v1.0.1** startet das Add-on jeden Daemon mit `--disable-mpris`; die Warnung entfällt.

### Re-Anchor-Loop nach langer Inaktivität

Nach sehr langer Audio-Pause lief sendspin früher in einen endlosen „Sync error … too large; re-anchoring"-Loop (Stille oder Fetzen). Ursache: PulseAudio suspendierte den Sink bei Inaktivität und stoppte die Device-Clock (Details: `docs/SENDSPIN_REANCHOR_BUG.md`).

Seit **v1.0.1** wird beim Start `module-suspend-on-idle` entladen — das entfernt die Ursache. Ein zusätzlicher Watchdog (Daemon bei wiederholten Re-Anchors automatisch neustarten) wurde bewusst **nicht** eingebaut: Er würde die bewährte, schlanke `run.sh`-Struktur gefährden, und ein früherer FIFO-basierter Watchdog blockierte den asyncio-Event-Loop bis zu 16 s. Sollte der Loop trotz v1.0.1 je wieder auftreten, bleibt der manuelle Fix ein **Add-on-Neustart**.

### Aussetzer / Desync / Stottern (VBAN im Signalweg)

Symptom: kurze Hänger, dann Desync und große Latenz, dann Stottern; ein vorgelagerter VBAN-Puffer läuft voll.

Ein großer VBAN-Puffer (z. B. 200 MB) behebt **keinen** Clock-Drift — er verzögert nur den Überlauf und addiert Latenz. Läuft der Puffer voll, driftet die Quelle gegenüber der Senke; Ursache ist der Sync-Loop bzw. das VM-Timing, nicht die Puffergröße. Empfehlung: Puffer wieder auf Standardgröße stellen und zuerst die Drift-Ursachen beheben (v1.0.1 deaktiviert Idle-Suspend; `log_level` auf `INFO` lassen; Proxmox-Hinweise unten).

### Proxmox / VM-Timing

Läuft HAOS in einer Proxmox-VM, verbessern diese Einstellungen die Audio-Stabilität:

- USB-Controller per **PCIe-Passthrough** durchreichen, nicht per USB-Device-Passthrough.
- CPU-Typ `host`.
- Kein Memory-Ballooning.
- Keine CPU-Überbuchung.
- Clocksource in der VM prüfen: `cat /sys/devices/system/clocksource/clocksource0/current_clocksource` → sollte `kvm-clock` oder `tsc` sein.

## Rollback

HAOS erkennt Add-on-Updates **ausschließlich** über die Versionsnummer in `config.yaml`. Ein reines `git revert` **ohne** Versionsänderung wird deshalb nicht erkannt.

**Einzelnen Fix zurücknehmen:**

1. Commit finden: `git log --oneline`
2. `git revert <hash>`
3. Version in `config.yaml` **und** `run.sh` **hochzählen** (z. B. `1.0.1` → `1.0.2`)
4. Committen, `git push`
5. In HAOS beim Add-on **Update** ausführen.

**Komplett auf den letzten stabilen Stand (v1.0.0) zurück:**

Der Tag `v1.0.0-backup` markiert den v1.0.0-Stand.

1. Inhalt zurückholen: `git checkout v1.0.0-backup -- sendspin-usb/`
2. Version in `config.yaml`/`run.sh` auf eine **neue, höhere** Nummer setzen (z. B. `1.0.2`), damit HAOS das „Update" erkennt.
3. Committen, `git push`, in HAOS **Update** ausführen.

> Wurde das **`Dockerfile`** geändert (z. B. der sendspin-Pin in v1.1.0), reicht kein Update — das Add-on muss dann **neu installiert** werden.
