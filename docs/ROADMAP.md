# Roadmap

Status as of v0.1 (2026-10-05).

## On hold until there are enough requests

### Public release
Share the 2.4 bots with other server hosts. The Steam Workshop can't deliver server plugins
(and 2.4 has no Workshop), so the plan is:

1. Prebuilt zip of the Linux server addons plus `install.sh`, attached to a GitHub release.
2. Make this repo public first (NavBot is GPLv3: the source of our changes must ship with the
   binaries). Check the repo for anything private before flipping it.
3. A Steam Community Guide on the ZPS hub (how 2.4 add-ons are shared): features, requirements,
   install, how players connect, known limitations.
4. Don't ship the radio's music (copyrighted); the radio plugin and importer are fine.

### Windows hosting
Players on any OS can already join. Hosting on Windows:

- **Short term (no code):** document running the Linux server in WSL2 (Ubuntu), including the
  32-bit libraries and networking (mirrored mode on Windows 11, port forwarding on Windows 10).
- **Native support (multi-session project):**
  - Build the patched Metamod and NavBot for Windows (MSVC, e.g. GitHub Actions; NavBot's CI
    already does Windows builds). The Metamod fix is the same on Windows.
  - Official SourceMod Windows build works as-is.
  - Windows gamedata is the hard part: 2.4's Windows server.dll has no symbols, so the
    symbol-name tricks in `tools/` don't work. Offsets and functions (ProcessUsercmds,
    CanAttachBarricade, gEntList, ...) need byte-pattern signatures and per-item verification.
  - Test the Windows 2.4 dedicated server under Wine on Linux.

## Open issues

- **Barricading:** off by default. Bots need the real barricade hammer and the game's own
  placement (hold attack for the whole animation; that placed real boards once). Blocker: 2.4's
  hard-coded carry-weight limit keeps armed bots from picking up the hammer; raise the limit
  (weight is a float at CHuman+0x28; find the limit compare in the pickup path) or keep
  barricaders light.
- **Church ladders:** nav ladders now exist (info_ladder support), but bots fail the physical
  climb. Investigate NavBot's ladder movement on HL2-style ladders.
- **Chat gibberish:** some bots occasionally send random text to all-chat without using the
  `say` command; `Host_Say` breakpoint in `ZPS24_GDB=1` mode is set up to catch the caller.
- **Plugin reloads during development** leave stale NavBot scripted tasks (STOPCMD doesn't clear
  them); change map after reloading the AI plugins.
