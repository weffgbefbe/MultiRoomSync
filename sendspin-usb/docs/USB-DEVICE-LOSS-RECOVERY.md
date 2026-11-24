# USB-DAC-Verlust: Wiederherstellung (sendspin-Patch v2)

Build-Input: `patches/usb-device-loss-recovery.patch`. Der Patch wird im Dockerfile auf die per pip installierte Bibliothek sendspin angewendet (`patch -F0` + grep-Check auf `_check_stream_health`).
Basis: Upstream `Sendspin/sendspin-cli` @ `016689dfe72200109078b18ff5af3ead8d78d1e6`. Geprüft gegen sendspin **7.5.0** (das löst `~=7.3` aktuell auf). Auf 7.3.1 passt der Patch **nicht**.
Ändert nur `sendspin/audio.py` (+97/−10).

## Problem

- Vorfall: Der USB-DAC war 10,5 s vom Bus weg (`usb 9-2: USB disconnect`). Danach blieb der Player dauerhaft stumm.
- Auf echtem PulseAudio nachgestellt: Wenn die Senke verschwindet, hören die Audio-Callbacks sofort auf. Kommt sie zurück, verbindet sich nichts neu. Der Player bleibt stumm, und die Queue wächst (25 s Rückstand nach 25 s).
- Ursache: PortAudio verbindet Streams mit `PA_STREAM_DONT_MOVE`. PulseAudio beendet den Stream deshalb, statt ihn auf eine andere Senke zu verschieben. PortAudio meldet das nicht an Python weiter.

## Warum v1 (Add-on v1.1.0) abgestürzt ist

```
INFO:sendspin.audio:Stream STARTED: 3 chunks, 0.29 seconds buffered
WARNING:sendspin.audio:Audio output stalled for 0.0 s (active=False); output device lost, reopening
Assertion 'o' failed at ../src/pulse/operation.c:136, function pa_operation_get_state(). Aborting.
```

1. `stream.start()` läuft asynchron im `_stream_executor`. Direkt nach `Stream STARTED` liefert `stream.active` deshalb `False`. v1 hat das als Geräteverlust gewertet, ein Fehlalarm bei jedem Streamstart.
2. Danach hat v1 `sounddevice._terminate()/_initialize()` aufgerufen, während der Executor noch am PA-Stream arbeitete. libpulse bricht dann mit SIGABRT ab (Exit 134), und das Add-on startet in einer Schleife neu.

Der damalige Simulator hat das übersehen, weil er den Executor synchron ausgeführt hat.

## Was v2 macht (gegenüber v1 nur Entfernungen)

- **Erkennung:** Ein Gerät gilt nur dann als verloren, wenn 2 s lang kein Audio-Callback kam (`_STREAM_STALL_TIMEOUT_US`). Gezählt wird ab dem letzten Callback bzw. ab dem Streamstart. Die Prüfung läuft am Anfang von `submit()` (`_check_stream_health`).
- **Neuöffnen:** `clear()` + `set_format()` mit **demselben** Gerät, höchstens alle 2 s (`_DEVICE_REOPEN_INTERVAL_US`). Ist das Gerät noch nicht zurück, schlägt das Öffnen fehl (`PortAudioError` wird in `set_format()` abgefangen) oder es kommen keine Callbacks. Dann folgt ein neuer Versuch.
- Kein `_terminate/_initialize`, keine private API, keine Gerätesuche über den Namen.
- **Reanchor-Fix (aus v1 übernommen):** Beim Reanchor wird veraltetes Audio verworfen (`_actual_read_position_us`, `_skip_input_frames`). Sonst bleibt der Player verspätet, obwohl der Cursor „synchron“ meldet.

## Tests (aus der Übergabe)

Echter Stack: PortAudio-Master mit `-DPA_USE_PULSEAUDIO=ON` und PulseAudio 16 mit einer Nullsenke namens wie der echte DAC. Die Geräteliste ist identisch zum Add-on.

| Szenario | v1 | v2 |
|---|---|---|
| 40 Streamstarts hintereinander | Abbruch (134) beim 1. Start | 0 Watchdog-Auslösungen |
| 60 s Dauerbetrieb, mit und ohne Last | – | 0 Auslösungen, größte Lücke zwischen Callbacks 60–66 ms |
| 5× Pause (20 s Leerlauf), weiter | – | 0 Auslösungen |
| Senke 10 s weg, kommt wieder | – | erholt sich ≤ ~1 s nach Rückkehr, synchron |
| Pause → Senke weg → neuer Stream → Senke zurück | – | erholt sich, synchron |
| 5 Abbrüche (3–11 s) | – | jedes Mal erholt, 0 Abstürze |

Simulator (Reanchor-Fall): synchron, echte Verspätung ≈ 0,1 s. Upstream-`pytest`: 171/171.
„USB weg“ wurde per `pactl unload-module` der Senke nachgestellt.

## Was im Log normal ist

Solange der DAC fehlt, erscheint etwa alle 2 s:
- `WARNING … No audio callback for X s; output device lost, reopening`
- `ERROR … Stream operation start failed` (mit Traceback)

Bei einem kurzen Ausfall ist das harmlos. Bei einem dauerhaft abgezogenen DAC wächst dadurch das Log.

**Nicht normal** (würde auf den v1-Fehler hindeuten): `stalled for 0.0 s` direkt nach `Stream STARTED`, oder `Assertion 'o' failed`.

## Bekannte Grenzen (bewusst nicht gelöst)

1. Log-Rauschen, solange der DAC fehlt (siehe oben).
2. Die Geräte werden nicht neu eingelesen. Bei direkter ALSA-Ausgabe mit geändertem PortAudio-Index nach dem Wiederanstecken erholt sich v2 nicht. Für dieses Add-on nicht relevant: Der Name der PA-Senke ist stabil (USB-Seriennummer), und das Neuöffnen über den gespeicherten Index ist auf echtem PA getestet.
3. Getestet mit PortAudio-Master (Stand 2026-11-19). Das Add-on baut ebenfalls PortAudio-Master (`git clone --depth 1`).
4. Der Reanchor-Fix ist nur simuliert, nicht auf echter Hardware geprüft.
5. Die Hardware-Ursache des Disconnects (USB-Passthrough der VM, Autosuspend, Port, Hub) deckt der Patch nicht ab.

## Bei einem sendspin-Upgrade

Lässt sich der Patch nicht mehr sauber einspielen, scheitert der Build absichtlich laut. Dann den Patch gegen die neue `sendspin/audio.py` neu erstellen, oder prüfen, ob Upstream das Problem inzwischen selbst löst.
