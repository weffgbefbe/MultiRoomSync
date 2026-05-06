# Sendspin USB Players

## Konfiguration

### log_level

Detailgrad der Log-Ausgabe. Standard: `INFO`.

> **Wichtig:** `DEBUG` im Dauerbetrieb vermeiden. Das Add-on loggt bei DEBUG-Level ~23 Zeilen pro Sekunde, was Python's asyncio Event-Loop kurzzeitig blockieren kann und den Sync-Loop begünstigt. `DEBUG` nur kurz zur Fehleranalyse aktivieren, danach auf `INFO` zurücksetzen.

### static_delay_ms

Korrigiert den Zeitversatz eines Players in Millisekunden. Standard: `0`.

**So findest du den richtigen Wert:**

1. Spiele Musik auf zwei oder mehr Playern gleichzeitig ab
2. Höre genau hin, welcher Player voraus oder hinterher ist
3. Passe den Wert an:
   - Player spielt **zu spät** → negativer Wert (z.B. `-80`)
   - Player spielt **zu früh** → positiver Wert (z.B. `50`)
4. Speichern, Add-on neustarten, erneut testen
5. In 25ms-Schritten anpassen bis es passt

Typische Werte liegen zwischen `-200` und `200`. USB-DACs haben oft 50-150ms Hardware-Puffer.

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
