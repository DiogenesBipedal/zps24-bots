# Roadmap

Where the project is (v0.1) and what's next. Nothing here has a date.

## Known issues

- **Barricading is off.** Survivor bots should board up doors and windows with the barricade
  hammer, using the game's own placement. What blocks it: ZPS 2.4's carry-weight limit stops
  armed bots from picking up the hammer. The options are raising the limit (the weight is a float
  at `CHuman+0x28`; the limit check is somewhere in the pickup path) or keeping barricaders
  lightly armed.
- **Church ladders.** The nav mesh has ladders (from `info_ladder`), but bots fail the climb
  itself. NavBot's ladder movement needs looking at for HL2-style ladders.
- **Chat gibberish.** Some bots occasionally put random text in chat without going through the
  `say` command. `ZPS24_GDB=1` mode sets a `Host_Say` breakpoint to catch where it comes from.
- **Crash on shutdown.** Harmless, but noisy.
- **Plugin reloads during development** leave stale NavBot tasks behind; change map after reloading
  the AI plugins.

## Next

- Barricading, once the weight limit is solved.
- Tuning for more 2.4 maps beyond cabin and church.

## Later

### Windows hosting
Players on any OS can join already. Hosting on Windows:

- **No code needed:** document running the Linux server in WSL2 (Ubuntu), including the 32-bit
  libraries and networking (mirrored mode on Windows 11, port forwarding on Windows 10).
- **Native support** is a bigger project:
  - Build the patched Metamod and NavBot with MSVC (NavBot's CI already makes Windows builds; the
    Metamod fix is the same on Windows). The official SourceMod Windows build works as-is.
  - Windows gamedata is the hard part. 2.4's Windows `server.dll` has no symbols, so the
    symbol-name tricks in `tools/` don't apply. Offsets and functions (`ProcessUsercmds`,
    `CanAttachBarricade`, `gEntList`, ...) need byte-pattern signatures, each verified.
  - Test the Windows 2.4 dedicated server under Wine on Linux.

### Steam Community guide
A guide on the ZPS community hub pointing to the releases (the Workshop can't deliver server
plugins).

## Contributing

Bug reports are welcome. Say which map, what the bots did, and include `server.log`. A gdb
backtrace (`ZPS24_GDB=1`) helps for crashes, and `!here` in chat logs the exact spot of a
movement problem.
