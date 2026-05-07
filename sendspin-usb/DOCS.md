# Sendspin USB Players

## Konfiguration

### log_level

Detailgrad der Log-Ausgabe. Standard: `INFO`.

> **Wichtig:** `DEBUG` im Dauerbetrieb vermeiden — das Add-on loggt bei DEBUG-Level ~23 Zeilen pro Sekunde. `DEBUG` nur kurz zur Fehleranalyse aktivieren, danach auf `INFO` zurücksetzen.

### static_delay_ms

Korrigiert den Zeitversatz eines Players in Millisekunden. Standard: `0`.

Der Wert wird ausschließlich durch Hören kalibriert — eine automatische Messung des akustischen Pfads (DAC → Verstärker → Lautsprecher) ist nicht möglich.

**So findest du den richtigen Wert:**

1. Spiele Musik auf zwei oder mehr Playern gleichzeitig ab
2. Höre genau hin, welcher Player voraus oder hinterher ist
3. Passe den Wert in 25ms-Schritten an:
   - Player spielt **zu spät** → negativer Wert (z.B. `-390`)
   - Player spielt **zu früh** → positiver Wert (z.B. `25`)
4. Speichern, Add-on neustarten, erneut testen

> **Hinweis bei sendspin-Upgrade:** Bei einem Upgrade auf sendspin 7.x ändert sich der Sync-Algorithmus grundlegend. Der bestehende Wert ist dann nicht mehr gültig und muss neu kalibriert werden.

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
