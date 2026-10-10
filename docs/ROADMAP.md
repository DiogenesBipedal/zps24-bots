# Roadmap

Where the project is (v0.1) and what's next. Nothing here has a date.

## Known issues

- **Barricading uses furniture only.** Survivor bots shove furniture into the ground-floor doors
  with bare hands (windows are left alone: bots keep back from them and shoot what climbs in). The barricade hammer is off: ZPS 2.4's carry-weight limit stops armed bots from
  picking it up. The options are raising the limit (the weight is a float at `CHuman+0x28`; the
  limit check is somewhere in the pickup path) or keeping barricaders lightly armed.
- **Steep staircases.** NavBot's generator leaves out stairs steeper than about 45 degrees (it
  samples every 25 units, and these rise more than a step per sample). The church tower's are
  handled with hand-made stair routes (`plugins/include/zps24_stairs.inc`), for zombies so far;
  survivors can't use the tower's upper floors yet. Other maps with steep stairs need their own
  routes. Lowering `NavGen_StepSize` is not a fix: at 12.5 the church mesh came out in thousands
  of disconnected pieces.
- **Church ladders.** The nav mesh has ladders (from `info_ladder`), but bots fail the climb
  itself. NavBot's ladder movement needs looking at for HL2-style ladders.
- **Chat gibberish.** Some bots occasionally put random text in chat without going through the
  `say` command. `ZPS24_GDB=1` mode sets a `Host_Say` breakpoint to catch where it comes from.
- **Crash on shutdown.** Harmless, but noisy.

## Next

- Barricading, once the weight limit is solved.
- Tuning for more 2.4 maps beyond cabin and church.

## Later

### Windows hosting
**Done, in testing.** A native Windows build lives in a separate repo (not public yet): patched
Metamod:Source and NavBot built with MSVC on GitHub Actions, Windows gamedata (vtable offsets
computed from the Linux vtables with MSVC's layout rules and checked against the DLL's RTTI;
signatures found by behaviour), a PowerShell installer, and nav meshes for the bot maps. Tested
with the Windows 2.4 server under Wine. How it was done: [MANUAL.md chapter 12](MANUAL.md#12-the-windows-port).

### Steam Community guide
A guide on the ZPS community hub pointing to the releases (the Workshop can't deliver server
plugins).

## Contributing

Bug reports are welcome. Say which map, what the bots did, and include `server.log`. A gdb
backtrace (`ZPS24_GDB=1`) helps for crashes, and `!here` in chat logs the exact spot of a
movement problem.
