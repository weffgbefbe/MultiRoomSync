# Übergabe: sendspin-cli – Wiederherstellung nach Verlust des USB-DACs

Zu dieser Übergabe gehören zwei Dateien:
- `sendspin-usb-recovery.patch`: Patch gegen `sendspin/audio.py`
- `sendspin-usb-stresstest.py`: Simulator mit Fehlerinjektion (virtuelle Uhr, nachgebauter PortAudio-Stream)

**Kein Pull Request.** Der Nutzer will ausdrücklich keinen PR. Nur lokal arbeiten.

---

## 1. Setup und Vorfall

- Home Assistant OS (Kernel `6.18.58-haos`) läuft als VM (QEMU/KVM), darin das **Sendspin-Player-Addon**. Es basiert auf `sendspin-cli` (Python, `aiosendspin`, `sounddevice`/PortAudio).
- Ausgabe über einen USB-DAC **Synaptics „Hi-Res Audio“** (`0572:1b09`), per USB-Passthrough in die VM durchgereicht. Er hängt auf Bus 9 (`xhci 0000:07:1b.0`), an derselben Weiterleitung wie der Nabu Casa ZBT-2.
- Der Server ist Music Assistant. Der Player bekommt FLAC mit 48 kHz, 24 Bit, Stereo und spielt auf PortAudio-Index `device=2`.
- **Vorfall:** Mitten im Betrieb blieb die Wiedergabe stehen. Vorher gab es kein Update, keinen Reboot, keinen Snapshot und keine Automation oder Durchsage.

Addon-Log (Ausschnitt, ohne Zeitstempel):
```
INFO:sendspin.audio:Stream STARTED: 3 chunks, 0.29 seconds buffered
INFO:sendspin.audio:Sync error 532.5 ms too large; scheduling reanchor
INFO:aiosendspin.client.client:Stream started with codec flac
INFO:sendspin.audio:Audio stream configured: ... device=2
INFO:sendspin.audio:Stream STARTED: 3 chunks, 0.29 seconds buffered
INFO:sendspin.audio:Sync error 13336.3 ms too large; scheduling reanchor
INFO:sendspin.audio:Sync error 21323.1 ms too large; scheduling reanchor
```

`dmesg` in der VM, und das ist die eigentliche Ursache:
```
[323034.304827] usb 9-2: USB disconnect, device number 3
[323044.787125] usb 9-2: new full-speed USB device number 4 using xhci_hcd
[323044.930942] usb 9-2: Product: Hi-Res Audio
```
Der DAC war 10,5 s weg, nach etwa 3 Tagen und 18 Stunden Laufzeit. Die Sync-Fehler sind nur die Folge davon, die Ursache liegt nicht in der Uhr.

## 2. Befund im Code

Basis: `github.com/Sendspin/sendspin-cli`, Commit `016689dfe72200109078b18ff5af3ead8d78d1e6` (2026-11-23). Lokaler Branch `fix/usb-device-loss-recovery`.

**Fehler A – Geräteverlust wird nicht erkannt.**
- Fällt ein ALSA-Gerät weg, beendet PortAudio nur den Callback-Thread. In Python kommt dabei keine Exception an.
- `AudioPlayer` überwacht das nicht und bleibt stumm, bis der Prozess neu startet.
- Das Gerät wird beim Start einmal als Integer-Index aufgelöst (`AudioDevice.device_id`). PortAudio speichert seine Geräteliste ab `Pa_Initialize()` und kennt danach nur noch den alten Stand.
- Startet MA einen neuen Stream (`audio_connector` → `player.clear()` + `player.set_format(fmt, device=self._audio_device)`), wird deshalb wieder der veraltete Index 2 geöffnet.

**Fehler B – Der Reanchor verdeckt den Versatz.**
- Der Reanchor-Zweig in `_audio_callback` setzt nur `_server_ts_cursor_us = _last_known_playback_position_us`.
- Das Audio, das sich während des Aussetzers in der Queue angestaut hat, bleibt liegen.
- Folge: Der gefilterte Sync-Fehler sieht danach wieder gut aus (etwa 1 ms), tatsächlich spielt der Player aber um die Länge des Aussetzers zu spät, und das dauerhaft.

## 3. Der Patch (`sendspin/audio.py`, +131/−11)

- **Neue Konstanten:**
  - `_STREAM_STALL_TIMEOUT_US = 2_000_000`
  - `_DEVICE_REOPEN_INTERVAL_US = 2_000_000`
- **Neuer Zustand in `__init__`:**
  - `_audio_format`, `_device`, `_last_callback_loop_time_us`, `_stream_started_loop_time_us`, `_device_lost`, `_last_reopen_attempt_us`
- **`_audio_callback`:** setzt bei jedem Aufruf `_last_callback_loop_time_us`.
- **Reanchor:**
  - Neue Hilfsmethode `_actual_read_position_us()`: Server-Zeitstempel des nächsten Frames, der wirklich gelesen wird (aktueller Chunk plus Offset, sonst Kopf der Queue).
  - Liegt diese Position hinter dem Ziel, wird die Differenz mit dem vorhandenen `_skip_input_frames()` verworfen. Erst danach wird der Cursor gesetzt.
- **`_check_stream_health(now_us)`:** wird am Anfang von `submit()` aufgerufen.
  - Löst aus, wenn der Stream gestartet ist und entweder 2 s lang kein Callback kam oder `stream.active == False` ist.
  - Dann wird der Stream geschlossen und `_device_lost` gesetzt. Neue Öffnungsversuche kommen höchstens alle 2 s.
- **`_reopen_lost_device()`:**
  - Ruft `sounddevice._terminate()` und `sounddevice._initialize()` auf (private API, damit PortAudio die Geräte neu einliest).
  - Sucht das Gerät über `query_devices()` per `name` wieder; bei `alsa_device_name` wird das alte Gerät weiterverwendet.
  - Dann `clear()`, `self._device = device`, `set_format()`.
  - Schlägt das Öffnen fehl, gibt es den nächsten Versuch beim nächsten Durchlauf.
- **`set_format()`:**
  - Bekommt es ein Gerät mit demselben Namen wie `self._device`, verwendet es den neu aufgelösten Index. Der Connector hält nämlich weiterhin das alte `AudioDevice`.
  - Ein `sounddevice.PortAudioError` beim Öffnen führt jetzt zu Warnung, `_stream = None` und `_device_lost = True`. Bisher ist die Exception bis in den Worker durchgeschlagen.
- **`_open_stream()`:** der Aufbau des `RawOutputStream` als eigene Methode herausgezogen, ohne inhaltliche Änderung.

**Threading:** `submit()` und `set_format()` laufen beide im Audio-Worker-Thread des Connectors (`audio_connector.py`, Zeilen ~291/316/327). Der Watchdog ruft also nichts aus einem fremden Thread auf.

Anwenden: `git apply sendspin-usb-recovery.patch` auf dem oben genannten Commit.

## 4. Simulator

Voraussetzungen:
- `libportaudio2`
- `pip install -e ".[test]"` im Repo; das Paket `sendspin` muss importierbar sein.

Der Simulator ersetzt `sounddevice.RawOutputStream`, `_terminate`/`_initialize` und `sendspin.audio.query_devices`. Ein wieder eingesteckter DAC bekommt darin einen **neuen Index** (2 → 3).

Aufruf (am besten aus einem Ordner außerhalb des Repos):
```
python3 -I sendspin-usb-stresstest.py 1 2 3 4 5 7 8 9 10 P1 P2 P3 P4 6
```

Pro Szenario gibt er aus:
- relevante Log-Zeilen
- Endzustand
- `ECHTE Verspätung`: Wiedergabezeit minus Zeitstempel des tatsächlich gespielten Frames. Normal sind etwa 0,1 s.

Ergebnisse:

| # | Szenario | Original | Mit Patch |
|---|---|---|---|
| 1 | Baseline, 60 s | ok | ok |
| 2 | USB weg ab 20 s, nach 10,5 s zurück | dauerhaft stumm | nach ~1,5 s synchron, Index 2 → 3 |
| 3/4 | wie 2, dann neuer Stream von MA (alter Index gültig bzw. ungültig) | stumm | synchron |
| 5 | Callbacks hängen 10,5 s, laufen dann weiter | einmal „Sync error 506 ms“, danach **10,6 s zu spät** bei gefiltertem Fehler ~1 ms | synchron |
| 9 | kurzer Hänger 1,5 s (unter der Watchdog-Schwelle) | 1,6 s zu spät, bleibt so | synchron (Fix B allein) |
| 10 | 10 min, 52 zufällige USB-Abbrüche/Hänger/Neustarts (Seed 42) | am Ende stumm, 57 s in der Queue | synchron |
| P1 | 60 s Pause, Stream bleibt offen | – | 0 Watchdog-Meldungen, synchron |
| P2 | Pause per `stream/clear`, 60 s Leerlauf | – | 0 Meldungen |
| P3 | `stream/end`, 10 min Leerlauf, neuer Stream | – | 0 Meldungen |
| P4 | 10 min ganz ohne Stream | – | 0 Meldungen (Ausgabe „SILENT“ ist hier richtig) |
| 6 | DAC-Zeitstempel bleibt stehen | ok | ok |

## 5. Tests und Lint

- Ohne `pytest-asyncio` scheitern 44 async-Tests mit „async def functions are not natively supported“. Das ist ein Problem der Umgebung, nicht des Codes. Deshalb immer die `[test]`-Abhängigkeiten installieren.
- Mit `[test]`-Abhängigkeiten: **171/171 bestanden**, mit und ohne Patch.
- `ruff check`/`ruff format --check` (gepinnt auf 0.14.5) sind sauber.
  - **Achtung:** `ruff check` korrigiert in diesem Repo automatisch und entfernt dabei drei bestehende `# noqa`-Kommentare (`N815` bei `outputBufferDacTime`, `PLR0915` bei `_audio_callback` und `submit`). Die gehören nicht zum Patch und sollten bleiben. Zum reinen Prüfen `ruff check --no-fix` verwenden.
- `mypy sendspin/audio.py` meldet nur einen Fehler, und der war schon vorher da (Rückgabetyp `bytes | bytearray`). Aus dem Patch kommt keiner.

## 6. Offene Punkte

1. **Nur simuliert.** Auf echter Hardware ist der Patch nicht getestet. Ob PortAudio/ALSA bei einem echten Abziehen `active=False` meldet oder nur keine Callbacks mehr liefert, deckt der Watchdog in beiden Fällen ab. Bestätigt ist es aber nicht.
2. **Die Werte 13 s und 21 s** aus dem echten Log hat der Simulator nicht genau nachgebildet; nur der erste Wert passt (532 ms gegenüber 506 ms in der Simulation).
3. **Private API:** `sounddevice._terminate()`/`_initialize()` ist der gängige Weg, damit PortAudio neue Geräte erkennt, aber es ist kein offizielles API.
4. **Grenzfall:** Braucht `stream.start()` nach einer Pause länger als 2 s, öffnet der Watchdog das Gerät einmal unnötig neu. Das kostet nur einen kurzen Aussetzer und kam in der Simulation nicht vor.
5. **Geräte per Name finden:** Der Abgleich nutzt den PortAudio-Gerätenamen (z. B. `Synaptics Hi-Res Audio: USB Audio (hw:1,0)`). Bekommt die Karte nach dem Wiederanstecken eine andere ALSA-Nummer, ändert sich dieser Name und der Abgleich schlägt fehl. Robuster wäre ein Abgleich ohne den `(hw:N,M)`-Teil.
6. **Hardware-Ursache** liegt außerhalb dieses Patches:
   - USB-Passthrough bzw. Host prüfen: `dmesg` des Hosts zur selben Zeit, USB-Autosuspend auf dem Host.
   - Port oder Kabel wechseln, einen aktiven Hub verwenden, oder den ganzen USB-Controller per PCIe durchreichen.
7. **Das Addon selbst:** Der Patch muss in das Image, das das Addon verwendet. Wie das Addon gebaut wird, ist noch nicht geklärt.
