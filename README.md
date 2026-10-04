# Who's in my way?

A Transport Fever 3 mod that tells you which train is blocking yours.

When a train's vehicle window shows **"Waiting for Free Path"**, the mod adds a row of clickable train names below it: the train blocking yours, the train blocking that one, and so on. Clicking a name opens that train's window. If the chain loops back on itself (a deadlock), it is marked with **∞**. The chain is capped at 19 names, followed by "…".

![Screenshot](whoblocksme_1/_metadata/0.png)

## Installation

- **mod.io / in-game Mod Hub:** subscribe to "Who's in my way?" and enable it for your game.
- **Manual:** copy the `whoblocksme_1` folder into your mods folder and restart the game:
  - Linux: `~/.local/share/Transport Fever 3/mods/`
  - Windows: the `mods` folder inside the Transport Fever 3 userdata directory

## How it works

Transport Fever 3 does not expose which vehicle is blocking a waiting train. The mod reads every train's path and takes the track it occupies plus the track it has reserved (`reservedFrom`..`reservedTo`). For the waiting train it takes the path ahead up to the second real signal (waypoints are ignored), because a train only passes a signal if the block behind it is free too. Another train holding any edge in that range is the blocker. Switches and crossings are matched through their shared node. The search then repeats from the blocking train, as long as that train is waiting itself, to build the chain.

## Known limitations

- Clicking a name keeps the chain's windows visible for a moment, but the game may still hide unpinned windows later. Pin a window to keep it open.

## Development

- Start the game in debug mode to get the in-game console (open it with `^`).
- Hot-reload the mod scripts with `AltGr+Shift+R`.
- Set `local DEBUG = true` in `whoblocksme_1/content/whoblocksme.script.tl` to log what the search finds for each train (logged only when it changes).
- Log output goes to `crash_dump/stdout.txt` in the game's userdata folder.

## License

MIT, see [LICENSE](LICENSE).

---

## Deutsch

**Wer ist im Weg?** zeigt im Fahrzeugfenster eines Zugs mit „Warte auf freie Wege“ die Kette der blockierenden Züge als anklickbare Namen. Ein Klick öffnet das Fenster des jeweiligen Zugs, ein Kreis (Deadlock) wird mit ∞ markiert, nach 19 Namen folgt „…“.

Installation über mod.io bzw. den Mod Hub im Spiel, oder manuell den Ordner `whoblocksme_1` nach `~/.local/share/Transport Fever 3/mods/` (Linux) bzw. in den `mods`-Ordner der Userdata (Windows) kopieren und das Spiel neu starten.

Funktionsweise: Die Mod liest Belegung und Reservierung der Gleise jedes Zugs. Für den wartenden Zug gilt der Weg bis zum zweiten Signal voraus (Wegpunkte zählen nicht); wer dort ein Gleis belegt oder reserviert hat, ist der Blocker, auch an Weichen und Kreuzungen.

Grenzen: Nach dem Klick bleiben die Fenster der Kette sichtbar, das Spiel kann nicht angeheftete Fenster aber später ausblenden; zum dauerhaften Behalten anheften.
