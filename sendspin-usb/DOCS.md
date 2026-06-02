# Sendspin USB Players

## Konfiguration

### log_level

Detailgrad der Log-Ausgabe. Standard: `INFO`.

> **Wichtig:** `DEBUG` im Dauerbetrieb vermeiden. Das Add-on loggt bei DEBUG-Level ~23 Zeilen pro Sekunde, was Python's asyncio Event-Loop kurzzeitig blockieren kann und den Sync-Loop begünstigt. `DEBUG` nur kurz zur Fehleranalyse aktivieren, danach auf `INFO` zurücksetzen.

### static_delay_ms

Korrigiert den Zeitversatz eines Players in Millisekunden. Standard: `0`.

> **Hinweis PulseAudio-Setups (HAOS):** sendspin 7.x verspricht automatische Hardware-Latenz-Kompensation — diese funktioniert jedoch nur wenn PortAudio die echte Hardware-Latenz messen kann. Über PulseAudio als Zwischenschicht meldet PortAudio oft `0ms`, wodurch die Auto-Kompensation wirkungslos bleibt. In diesem Fall ist der Wert aus sendspin <7.0 weiterhin korrekt. Erkennbar im Log: `Audio stream configured: output_latency=0.0 ms` → manuelle Kompensation nötig.

**So findest du den richtigen Wert:**

1. Starte mit dem Wert aus deiner bisherigen Konfiguration (z.B. `-390`)
2. Wenn du noch keinen Wert hattest: starte mit `0` und prüfe ob die Wiedergabe zeitlich stimmt
3. Spiele Musik auf zwei oder mehr Playern gleichzeitig ab
4. Höre genau hin, welcher Player voraus oder hinterher ist
5. Passe den Wert in 25ms-Schritten an:
   - Player spielt **zu spät** → negativer Wert (z.B. `-390`)
   - Player spielt **zu früh** → positiver Wert (z.B. `25`)
6. Speichern, Add-on neustarten, erneut testen

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
