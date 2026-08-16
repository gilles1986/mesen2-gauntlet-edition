# Mesen 2 — Gauntlet Edition

A fork of [Mesen Community Edition](https://github.com/nesdev-org/MesenCE) (itself a fork of
[Mesen 2](https://github.com/SourMesen/Mesen2) by Sour) that turns the emulator into a
purpose-built platform for timed Kaizo/speedrun challenges.

Everything the upstream emulator does — NES, SNES, Game Boy (GB/SGB/GBC), Game Boy Advance,
PC Engine, SMS/Game Gear and WonderSwan emulation — still works exactly as before. The
Gauntlet Edition adds a challenge layer on top of it.

## What this fork adds

- **Challenge engine** — an embedded Lua engine (`Challenge/relay.lua`) that chains ROM
  segments together via savestate drop-in, counts frames, and draws the in-game HUD,
  done-screen and achievement popups.
- **Lockdown mode** — while a challenge is running the C++ core blocks savestates, rewind,
  speed changes, cheats and the debugger, so runs stay comparable.
- **Timing, splits and personal bests** — per-segment PBs, sum-of-best, attempt counters.
- **Ghosts and replays** — live PB ghost overlay, shareable ghosts, and a `.creplay` replay
  format with a protocol handler so a replay can be opened straight from a link.
- **Challenge packages** — `.cha` archives containing segment definitions, savestates and BPS
  patches, applied to a clean base ROM at install time. Browse-and-install from a catalog or
  import a file manually.
- **Leaderboard submission** — signed run submission, an offline retry queue, and an optional
  Twitch account link using the OAuth device-authorization flow.
- **Stream integration** — an OBS browser-source overlay written next to the executable.

## Building

Build requirements and steps are unchanged from upstream — see [COMPILING.md](COMPILING.md).
`build.bat` additionally packages the release ZIP; it locates MSBuild through `vswhere`, so a
standard Visual Studio 2022 installation needs no configuration.

The challenge engine ships as an embedded resource, so `build.bat` has to run again after any
change to `Challenge/relay.lua` for the new engine to end up inside the executable.

The leaderboard signing key is not part of this repository:
`UI/Utilities/ChallengeSecrets.cs` carries a placeholder, and that file explains how to supply
your own. Everything in the emulator works normally with the placeholder in place; only
leaderboard submissions are rejected, because the signature will not match.

## Modifications

This is a modified version of Mesen Community Edition, forked in 2026 at commit `95ceb59d` and
extended with the challenge system described above. Mesen and Mesen CE are the work of Sour and
the MesenCE contributors; these modifications are not endorsed by them.

## License

Mesen is available under the GPL V3 license. Full text here:
<http://www.gnu.org/licenses/gpl-3.0.en.html>

Copyright (C) 2014-2025 Sour, 2026 contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
