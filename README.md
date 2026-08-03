# CrabeLoader Splitscreen

Local (couch) 2-player splitscreen for **Disney Infinity 3.0 (PC)**, built as
a [CrabeLoader](https://github.com/LucasLhomme/CrabeLoader) mod.

**Status: experimental / work in progress.** Splitscreen itself works —
player 2 gets a controller, a real second viewport, and the screen splits.
Player 2 does **not** yet get a character in the world; that's the open
problem. Full investigation log, addresses, and session-by-session findings:
[docs/splitscreen.md](docs/splitscreen.md).

## Requirements

- Disney Infinity 3.0 (PC), with [CrabeLoader](https://github.com/LucasLhomme/CrabeLoader)
  installed and working.
- A second controller.

## Installation

1. Copy `api/45_dropin.lua` into CrabeLoader's `api/` folder (next to
   `40_inspect.lua`).
2. Copy `mods/splitscreen.lua` into CrabeLoader's `mods/` folder.
3. Launch the game. The overlay console (`Insert`) should log
   `splitscreen: player 2 staged on controller N` if a second controller is
   already connected.

## Usage

```lua
Crabe.Splitscreen.enable(1)                              -- pad 1 joins as player 2
Crabe.Splitscreen.setCharacter(Crabe.Splitscreen.characters.ironMan)
Crabe.Splitscreen.report()                                -- full diagnostic
```

See [docs/splitscreen.md](docs/splitscreen.md) ("Using it") for the full API
and what each field of `report()` means.

## Why this is a separate repo

CrabeLoader is a generic platform: it exposes the tools (call any game
function by address, read/write memory, trace messages, ...) so mods don't
need loader changes. This mod is exactly that — a consumer of CrabeLoader's
API, not part of it — so it lives on its own, the same way a plugin lives
apart from the app it plugs into. See CrabeLoader's `docs/modding.md`.

## License

GPLv3, matching CrabeLoader — see [LICENSE](LICENSE).
