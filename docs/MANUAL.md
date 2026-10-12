# Porting NavBot to Zombie Panic! Source 2.4: a hands-on manual

This manual explains how the bots in this repo were made to work on ZPS 2.4, and teaches the
techniques along the way. It is written for someone who knows a little programming and wants to
learn how Source engine modding, reverse engineering and low-level debugging actually work.

A note on languages: almost all of this is **C++**. Source, Metamod, SourceMod and
NavBot are C++ code bases. There's also some **SourcePawn** (SourceMod's scripting language,
which looks like C), **Python** for tools, and **shell** for automation. C++ is a superset of
C in spirit, so everything C-like you know still applies; this manual explains the C++ parts
(classes, virtual functions, vtables) as they come up.

---

## Contents

1. [The big picture](#1-the-big-picture)
2. [How the Source engine is put together](#2-how-the-source-engine-is-put-together)
3. [Virtual functions and vtables, the key to everything](#3-virtual-functions-and-vtables-the-key-to-everything)
4. [Metamod:Source, SourceHook and SourceMod](#4-metamodsource-sourcehook-and-sourcemod)
5. [Gamedata: telling plugins where things are](#5-gamedata-telling-plugins-where-things-are)
6. [Your toolbox](#6-your-toolbox)
7. [The journey, problem by problem](#7-the-journey-problem-by-problem)
8. [Building everything](#8-building-everything)
9. [Testing a game server without playing it](#9-testing-a-game-server-without-playing-it)
10. [Writing SourcePawn plugins](#10-writing-sourcepawn-plugins)
11. [Teaching the bots to play](#11-teaching-the-bots-to-play)
12. [The Windows port](#12-the-windows-port)
13. [The tricks, collected](#13-the-tricks-collected)
14. [Exercises](#14-exercises)
15. [Glossary](#15-glossary)

---

## 1. The big picture

**Goal:** bots in ZPS 2.4, using NavBot, a modern bot framework written for current Source
games (including ZPS 3.x).

**Why it was hard:** ZPS 2.4 runs on the 2007 version of the Source engine. Every piece of
modern tooling (Metamod:Source 1.12, SourceMod 1.12, NavBot 0.1.2) is built and tested against
newer engines. Things that "should" be compatible weren't, in ten separate ways.

**The architecture we ended up with:**

```
 ZPS 2.4 client (Windows, under Proton)  ──connect <LAN IP>──►   ZPS 2.4 dedicated server (Linux)
                                                                    │
                                                                    ├─ engine_i486.so    (Valve, 2007)
                                                                    ├─ server_i486.so    (ZPS game code)
                                                                    └─ addons/
                                                                        ├─ metamod   (patched by us)
                                                                        └─ sourcemod (official 1.12)
                                                                             ├─ navbot.ext.2.ep2.so (patched by us)
                                                                             ├─ gamedata          (translated by us)
                                                                             └─ plugins           (written by us)
```

Why a dedicated server instead of hosting from the game? The 2.4 client only exists for
Windows. A Windows game can only load Windows plugins (`.dll`), and building those from Linux
is a big extra project. The Linux dedicated server loads Linux plugins (`.so`), which we can
build here. So bots live on the server and you join it like any other server.

---

## 2. How the Source engine is put together

A Source game is not one program. It's a small launcher plus a set of shared libraries
(`.so` on Linux, `.dll` on Windows) that talk to each other.

| Library | Who wrote it | Job |
|---|---|---|
| `srcds_i486` | Valve | The dedicated server launcher. Loads everything else. |
| `engine_i486.so` | Valve | Networking, map loading, the console, the main loop. |
| `vstdlib_i486.so`, `tier0_i486.so` | Valve | Utility code: console variables, memory, threads. |
| `zps/bin/server_i486.so` | The ZPS team | The **game**: players, weapons, zombies, rules. |

The `_i486` suffix is how Valve named Linux libraries back then. Modern games use `_srv.so`
or plain `.so`.

### Interfaces and factories

How does the engine call into the game, and the game into the engine, when they're separate
libraries compiled at different times? Through **interfaces**: C++ classes containing only
virtual functions, published under a versioned name.

Each library exports one C function, `CreateInterface`:

```cpp
void* CreateInterface(const char* name, int* returnCode);
```

You ask a library for an interface by name and get back a pointer:

```cpp
// Ask the engine library for its server-side engine API, version 21.
IVEngineServer* engine = (IVEngineServer*)engineFactory("VEngineServer021", nullptr);
engine->ServerCommand("changelevel zps_town\n");
```

The version number in the name (`021`) matters. When Valve changes an interface, they bump
the number, and old code keeps asking for the old version. This is how a 2007 game and a 2026
plugin can still talk, **as long as both agree on the exact layout of that interface**. Much
of the work in this project came down to cases where they didn't.

One example from our debugging: NavBot asked for `BotManager001`. That interface was added to
Source after 2007, so ZPS 2.4 doesn't have it. `CreateInterface` returned NULL.

You can list which interface names a library knows by searching its strings:

```sh
strings -a server_i486.so | grep -E '^(ServerGameDLL|PlayerInfoManager|BotManager)[0-9]+$'
```

---

## 3. Virtual functions and vtables, the key to everything

If you learn one low-level concept from this manual, make it this one.

### What a virtual function is

In C++, a class can declare functions `virtual`, meaning subclasses can override them:

```cpp
class CBaseEntity {
public:
    virtual void Spawn();
    virtual void Think();
    virtual int  OnTakeDamage(const CTakeDamageInfo& info);
};

class CBasePlayer : public CBaseEntity {
public:
    void Spawn() override;           // players spawn differently
    int  OnTakeDamage(const CTakeDamageInfo& info) override;
};
```

When code calls `entity->Spawn()` and `entity` happens to be a player, the *player's* `Spawn`
runs. How does the compiled program know which one to call at runtime?

### How it's implemented: the vtable

Every object of a class with virtual functions starts with a hidden pointer, the **vptr**.
It points to a table of function pointers for that class, the **vtable**:

```
 a CBasePlayer object in memory          CBasePlayer's vtable (in the .so file)
 ┌──────────────────────┐               ┌──────────────────────────────────────┐
 │ vptr ────────────────┼──────────────►│ [0] ~CBasePlayer()   (destructor)    │
 │ m_iHealth            │               │ [1] ~CBasePlayer()   (deleting dtor) │
 │ m_vecOrigin          │               │ [2] SetRefEHandle                    │
 │ ...                  │               │ ...                                  │
 └──────────────────────┘               │ [22] CBasePlayer::Spawn              │
                                        │ [47] CBaseEntity::Think              │
                                        │ [62] CBasePlayer::OnTakeDamage       │
                                        └──────────────────────────────────────┘
```

A virtual call `entity->Spawn()` compiles to roughly this:

```cpp
void** vtable = *(void***)entity;      // read the vptr
auto fn = (void(*)(CBaseEntity*))vtable[22];   // slot 22 is Spawn
fn(entity);                            // call it, passing 'this'
```

In assembly (32-bit x86, Intel syntax) you'll see exactly this pattern everywhere:

```asm
mov  eax, DWORD PTR [esi]        ; eax = vptr (first 4 bytes of the object)
mov  DWORD PTR [esp], esi        ; push 'this' as the first argument
call DWORD PTR [eax+0x58]        ; call vtable slot 0x58/4 = 22
```

### Why this matters so much for modding

The **slot number** (the index into the vtable) is what plugins use to call or hook game
functions they don't have source code for. "Call slot 22 on this player" means "make it spawn."

Slot numbers depend on the exact class hierarchy the game was compiled with. ZPS 3.x added
virtual functions to its classes, which shifted everything after them. In 3.x,
`Event_Killed` is slot 66; in 2.4 it's slot 65. Use the wrong number and you call some other
random function, which almost always means a crash. Most of the "gamedata" work below is
about getting these numbers right.

### The Itanium C++ ABI

On Linux, GCC and Clang lay out vtables according to the **Itanium C++ ABI**. In a library,
a class's vtable is a symbol named `_ZTV` plus the mangled class name:

- `_ZTV13CHL2MP_Player` is the vtable for `CHL2MP_Player` (13 = length of the name).
- The first two entries are bookkeeping: the "offset to top" (0 for a primary vtable) and a
  pointer to type information (`_ZTI...`).
- The function pointers come after those two entries.
- A virtual destructor takes **two** slots: the "complete object" destructor and the
  "deleting" destructor.

On Windows, MSVC uses one destructor slot instead of two. That's why Windows offsets are
usually **one less** than Linux offsets in SourceMod gamedata files.

---

## 4. Metamod:Source, SourceHook and SourceMod

### Metamod:Source

The engine only loads one game library: `server.so`. **Metamod:Source** sneaks in by
pretending to be a "server plugin": a file the engine loads because a `.vdf` file in
`addons/` points to it:

```
"Plugin"
{
	"file"	"addons/metamod/bin/server"
}
```

Metamod then loads other plugins (like SourceMod) and gives them **SourceHook**.

### SourceHook: changing what a virtual function does

SourceHook lets you run your own code before or after any virtual function, on a specific
object, without the game's source. It works by **rewriting the object's vtable entry** to point
at a trampoline that calls your hooks and the original function.

```cpp
// 1. Declare the hook: class, function, attributes, overload index, return type, argument types.
SH_DECL_HOOK1(IVEngineServer, GetPlayerNetworkIDString, SH_NOATTRIB, 0, const char*, const edict_t*);

// 2. Add it: on the 'engine' object, call our member function after the original ("post" = true).
SH_ADD_HOOK(IVEngineServer, GetPlayerNetworkIDString, engine,
            SH_MEMBER(this, &NavBotExt::Hook_GetPlayerNetworkIDString), true);

// 3. In the hook, look at what the original returned and optionally override it.
const char* NavBotExt::Hook_GetPlayerNetworkIDString(const edict_t* edict)
{
    const char* original = META_RESULT_ORIG_RET(const char*);
    if (strcmp(original, "BOT") == 0)
        RETURN_META_VALUE(MRES_OVERRIDE, "STEAM_0:0:1001");   // replace the return value
    RETURN_META_VALUE(MRES_IGNORED, nullptr);                  // leave it alone
}
```

That's real code from our NavBot patch (simplified); section 7.8 explains why we needed it.

The result codes:

| Code | Meaning |
|---|---|
| `MRES_IGNORED` | "I did nothing." |
| `MRES_HANDLED` | "I did something, but call the original anyway." |
| `MRES_OVERRIDE` | "Call the original, but return my value." |
| `MRES_SUPERCEDE` | "Don't call the original at all; use my value." |

### SourceMod

**SourceMod** is a Metamod plugin that adds:

- a scripting language, **SourcePawn**, for plugins (`.sp` source files compiled to `.smx`);
- **extensions**: native C++ modules like NavBot (`navbot.ext.2.ep2.so`);
- **gamedata**: text files that say where things are in each game's binary (next section).

The `2.ep2` in NavBot's filename means "API version 2, engine `ep2`". `ep2` is the Episode Two /
Orange Box engine branch, the one ZPS 2.4 uses. SourceMod picks the right file for the engine
it detects.

---

## 5. Gamedata: telling plugins where things are

Because slot numbers and function addresses differ per game and per version, SourceMod keeps
them out of the code, in **gamedata** files. These are Valve KeyValues text files:

```
"Games"
{
	"zps"                          // the game folder name this section applies to
	{
		"Offsets"                  // vtable slot numbers
		{
			"Weapon_Switch"
			{
				"linux"		"239"
			}
		}
		"Signatures"               // ways to find non-virtual functions and variables
		{
			"gEntList"
			{
				"library"	"server"
				"linux"		"@gEntList"   // '@' = look up this exported symbol by name
			}
		}
		"Keys"                     // free-form settings
		{
			"HookPlayerRunCMD"	"0"
		}
	}
}
```

**Offsets** are vtable slots. **Signatures** find code or data by symbol name (on Linux, when
the binary still has symbols) or by a byte pattern (on Windows). **Keys** are settings the
extension reads with `GetKeyValue`.

You can override SourceMod's files without editing them: put a file in `gamedata/<name>.games/custom/`
and SourceMod reads it after its own. We used this for `core.games/custom/zps24.txt`.

---

## 6. Your toolbox

All of these are standard Linux tools. Learn them and you can take apart almost any program.

### `file`: what is this?

```sh
$ file engine_i486.so
engine_i486.so: ELF 32-bit LSB shared object, Intel 80386, ... not stripped
```

"Not stripped" is great news: the binary still contains **symbol names** (function and
variable names). That made this whole project feasible.

### `readelf`: look inside ELF files

```sh
readelf -lW lib.so | grep GNU_STACK      # program headers: is an executable stack requested?
readelf -dW lib.so | grep NEEDED         # which libraries does it link against?
readelf -sW lib.so                       # all symbols: address, size, type, name
readelf -rW lib.so                       # relocations: places the loader patches at load time
readelf -p .comment lib.so               # which compiler built it
```

### `c++filt`: turn mangled names into readable C++

```sh
$ echo _ZN11CHL2MPRules9JoinRoundEP13CHL2MP_Playerb | c++filt
CHL2MPRules::JoinRound(CHL2MP_Player*, bool)
```

C++ encodes argument types into symbol names ("name mangling") so overloads get distinct names.
`c++filt` reverses it. You can even read the encoding by eye: `_ZN` (nested name) `11CHL2MPRules`
(11-character class) `9JoinRound` (9-character function) `E` (end of name) `P13CHL2MP_Player`
(pointer to 13-character class) `b` (bool).

### `objdump`: disassemble machine code

```sh
objdump -d -M intel --no-show-raw-insn --start-address=0xd549b0 --stop-address=0xd54cf2 server_i486.so
```

`-M intel` gives the readable Intel syntax (`mov eax, ebx` means eax = ebx). Find a function's
address and size with `readelf -s`, then disassemble just that range.

### `strings`: find text in binaries

```sh
strings -a server_i486.so | grep -x joingame
```

Great for checking whether a console command, event name or interface version exists.

### `gdb`: the debugger

The most important tool in this project. Basic use:

```sh
gdb --args ./srcds_i486 -game zps +map zps_deadend
(gdb) run                 # start; it stops on a crash
(gdb) bt                  # backtrace: which functions led here
(gdb) info registers      # CPU registers at the crash
(gdb) x/6i $eip           # disassemble 6 instructions at the crash
(gdb) x/16wx $esp         # dump 16 words of the stack
```

Non-interactive (scriptable) use: `gdb -batch -ex run -ex bt --args ...`

Things that tripped us up, and how we got around them:

- **"ptrace: Operation not permitted"** when attaching to a running process. Linux's Yama
  security setting (`/proc/sys/kernel/yama/ptrace_scope` = 1) only lets you debug your own
  child processes. Fix: start the program *under* gdb instead of attaching later.
- **Interrupting a hung program:** from another shell, `kill -INT <pid>`. gdb stops it and you
  can run `thread apply all bt` to see what every thread is doing.
- **`run < file` dropped the program's arguments.** Use `set args ... < file` and then `run`.

### `LD_DEBUG`: watch the dynamic loader

```sh
LD_DEBUG=files ./srcds_i486 ... 2>&1 | grep metamod
```

Prints every library the loader opens. We used it to see which Metamod backend actually loaded.

### `pyelftools`: parse ELF from Python

When command-line tools aren't enough, write a script. Our `tools/vtable.py` uses pyelftools to
read symbols and relocations and print a class's whole vtable (section 7.5).

---

## 7. The journey, problem by problem

Each subsection follows the same shape: **symptom → investigation → root cause → fix → lesson**.
The investigations are the most valuable part, because that's where the techniques are.

### 7.1 Libraries won't load: the executable stack

**Symptom.** Even ZPS 3.x stopped launching natively. Steam's log said:

```
failed to dlopen engine.so: cannot enable executable stack as shared object requires: Invalid argument
```

**Investigation.**

```sh
$ readelf -lW engine.so | grep GNU_STACK
  GNU_STACK  0x000000 0x00000000 0x00000000 0x00000 0x00000 RWE 0x4
$ ldd --version | head -1
ldd (GNU libc) 2.41
```

`RWE` means read, write, **execute**. The system's glibc had been updated to 2.41 a few weeks
earlier.

**Root cause.** Every ELF file has a `PT_GNU_STACK` program header saying whether the program
needs an executable stack (old compilers asked for one to support a GCC feature called
"trampolines" for nested functions). Executable stacks are a security risk, so glibc 2.41
stopped allowing `dlopen()` of libraries that ask for one. Old Source binaries all ask, but none
actually need it.

**Fix.** Clear the "X" bit in that one header field. Here's the whole tool,
`tools/clear_execstack.py`, explained:

```python
PT_GNU_STACK = 0x6474E551   # the program header type for "stack permissions"
PF_X = 1                    # the "executable" permission bit

data = bytearray(open(path, 'rb').read())
phoff = struct.unpack_from('<I', data, 28)[0]          # where the program headers start
phentsize, phnum = struct.unpack_from('<HH', data, 42) # size of each header, how many
for i in range(phnum):
    entry = phoff + i * phentsize
    if struct.unpack_from('<I', data, entry)[0] != PT_GNU_STACK:   # p_type
        continue
    flags = struct.unpack_from('<I', data, entry + 24)[0]          # p_flags
    struct.pack_into('<I', data, entry + 24, flags & ~PF_X)        # clear the X bit
```

The numbers (28, 42, 24) come straight from the 32-bit ELF specification: `e_phoff` is at byte
28 of the file header, `e_phentsize` and `e_phnum` at bytes 42 and 44, and `p_flags` at byte 24
of each 32-byte program header.

**Lesson.** Read the error message literally, then find the exact field it's about. A
one-bit change fixed a whole game. (`GLIBC_TUNABLES=glibc.rtld.execstack=2` would also work,
but only from glibc 2.42.)

### 7.2 Metamod makes the server forget every command

**Symptom.** With Metamod 1.12 installed, the 2.4 server started but never loaded a map, and
printed `Unknown command "exec"`. Even `map` and `meta` were "unknown."

**Investigation, step 1: is it hung or crashed?** We started the server under gdb, waited,
and interrupted it:

```
#6  CSys::Sleep(int) () from bin/dedicated_i486.so
#7  RunServer() () from bin/dedicated_i486.so
```

Neither: it was idling happily in its main loop. It had simply lost its command list.

**Step 2: bisect the components.** Remove things until it works:

| Setup | Result |
|---|---|
| No Metamod | works |
| Metamod 1.12 alone, no SourceMod | broken |
| Metamod 1.11 | broken |
| Metamod 1.10.7 | **works** |

So the problem came in with Metamod 1.11, and SourceMod wasn't involved.

**Step 3: rule out the obvious.** Do the interface versions match?

```sh
strings -a engine_i486.so  | grep -E '^VEngineCvar[0-9]+'   # VEngineCvar004
strings -a metamod.2.ep2.so | grep -E '^VEngineCvar[0-9]+'  # VEngineCvar004
```

They matched. Did the compiler change? `readelf -p .comment` showed GCC 4.9 for both 1.10 and
1.11, so no.

**Step 4: build it ourselves and swap halves.** We built Metamod 1.12 from source (section 8)
and confirmed our build had the bug too. Then we combined the *old* loader with the *new*
core: still broken. So the bug was in the core library.

**Step 5: read the code.** Metamod's console code, `core/provider/console.cpp`:

```cpp
bool SMConVarAccessor::RegisterConCommandBase(ConCommandBase *pCommand)
{
	m_RegisteredCommands.push_back(pCommand);
#if SOURCE_ENGINE < SE_ALIENSWARM
	pCommand->m_pNext = NULL;          // <-- added after 1.10
#endif
	icvar->RegisterConCommand(pCommand);
	return true;
}
```

**Root cause.** In the 2007 engine, all console commands live in **one singly linked list**,
chained through each command's `m_pNext` field. Registering a command adds it at the head.
Metamod registers its `meta` command **twice**: once automatically when the library initializes,
and once explicitly. On the second call, `meta` is already in the engine's list, right at the
head, with `m_pNext` pointing to every other command. Setting `m_pNext = NULL` cuts the list off
after `meta`. Every engine command after it becomes unreachable, which is exactly
`Unknown command "exec"`.

```
before:  head → meta → exec → map → quit → ...
after:   head → meta ✂         (exec, map, quit... lost)
```

Newer engines store commands in a different data structure, so the line is harmless there,
which is why nobody had noticed.

**Fix** (`patches/metamod-zps24.patch`): leave already-registered commands alone.

```cpp
#if SOURCE_ENGINE < SE_ALIENSWARM
	if (pCommand->IsRegistered())
		return true;
#endif
```

**Lessons.**
- "Hung" and "idle" look the same from outside. Always get a backtrace.
- Bisect: find the newest working version and the oldest broken one, then look at what changed.
- When the bug is in code you can build, build it. Your own build lets you experiment freely.

### 7.3 The 2007 Steam library crashes under SourceMod

**Symptom.** With SourceMod loaded, the server crashed a minute or two in. The backtrace was
entirely inside `steamclient_i486.so`, on its own thread.

**Investigation.** The bare server ran fine for two minutes, so SourceMod triggers the crash, but
the crash happens in the 2007 Steam library that ships with the server. That library also
couldn't log in to Steam ("Unable to load Steam library").

**Fix.** Copy Valve's current 32-bit `steamclient.so` (from `~/.steam/sdk32/`) over the old one.
Valve keeps old Steam interfaces working in new builds, so the 2007 game code can still use it.
It immediately printed "Connection to Steam servers successful" and the crashes stopped.

**Lesson.** When an old program bundles an old copy of a library, try the new one. Backward
compatibility is common for system-level libraries.

### 7.4 SourceMod can't find the entity list

**Symptom.** NavBot refused to load: `NULL g_EntList from IGameHelpers!`. SourceMod's log
earlier said `Failed lookup of gEntList`.

**Investigation.** `gEntList` is the game's global list of all entities. Is it in the binary?

```sh
$ readelf -sW server_i486.so | awk '$4=="OBJECT"{print $3,$8}' | grep gEntList
65592 gEntList
```

Yes, exported by name. So why didn't SourceMod find it? Its gamedata for Source 2007 games
(`core.games/engine.ep2.txt`) lists specific games that get the `@gEntList` symbol lookup, and
`zps` isn't one of them.

**Fix.** A custom gamedata file, `gamedata/core.games-custom-zps24.txt`:

```
"zps"
{
	"Offsets"    { "EntInfo"  { "linux" "4" } }
	"Signatures" { "gEntList" { "library" "server"  "linux" "@gEntList" } }
}
```

`EntInfo` = 4 is the byte offset of the entity array inside the list object, after its 4-byte vptr.

**Lesson.** If a symbol exists but isn't found, the lookup rules are missing, not the symbol.

### 7.5 Translating every offset from 3.x to 2.4

**Problem.** SourceMod's SDK Tools and SDK Hooks, and NavBot, all ship gamedata for ZPS, but for
**3.x**. In 2.4 every slot number is different. Guessing would be hopeless: there are about 50.

**Key insight.** Both the 3.x and 2.4 Linux servers still have their symbols. So for each 3.x
offset, we can find *which function* sits in that slot in 3.x, then find *the same function* in
2.4's table. That's a reliable, mechanical translation.

**Step 1: dump a vtable** (`tools/vtable.py`). The heart of it:

```python
addr, size = binary.syms['_ZTV13CHL2MP_Player']     # where the vtable symbol is
for i in range((size - 8) // 4):                     # skip offset-to-top + typeinfo (8 bytes)
    slot = addr + 8 + 4 * i                          # each slot is a 4-byte pointer (32-bit)
    if slot in binary.rel:                           # filled in by the loader via a relocation?
        name = binary.rel[slot]                      #   then the relocation names the function
    else:
        target = read_u32(slot)                      # otherwise it holds the address directly
        name = binary.addr2sym[target]               #   map the address back to a function name
```

Why relocations? In a shared library, a vtable slot pointing at a function in another library
can't be filled in until load time. The file stores a **relocation** record instead ("at this
address, put the address of symbol X"). Reading those records tells us which function a slot
refers to, even though the bytes in the file are zero.

Output (trimmed):

```
$ tools/vtable.py server_i486.so CHL2MP_Player
0  CHL2MP_Player::~CHL2MP_Player()
1  CHL2MP_Player::~CHL2MP_Player()
...
62 CHL2MP_Player::OnTakeDamage(CTakeDamageInfo const&)
65 CHL2MP_Player::Event_Killed(CTakeDamageInfo const&)
```

**Step 2: translate** (`tools/port_gamedata.py`). For each `Offsets` entry:

```python
fn = short_name(old_vtable[old_index])             # e.g. "Event_Killed" (3.x slot 66)
new_index = first index in new_vtable whose short name == fn   # 2.4: 65
```

Output:

```
Event_Killed                 66 ->   65  CZP_Player::Event_Killed
Weapon_Switch               276 ->  239  CZP_Player::Weapon_Switch
CanBeAutobalanced           466 -> dropped (no such function in 2.4)
```

**Pitfalls we hit, and how to catch them:**

- **Wrong class.** `Reload` came out as `CBaseCombatCharacter::OnFriendDamaged`, which is
  obviously not a reload. `Reload` is a *weapon* function, so it must be looked up in a weapon
  class's vtable, not the player's. Same for `CBaseFilter::PassesFilterImpl`. The script now
  picks the class per key. **Always read the translation report**; a wrong-looking name means
  a wrong class.
- **Functions that don't exist in the old version** (`CanBeAutobalanced`, `GetMaxHealth`) are
  dropped. SDK Hooks then reports those hook types as unsupported, which is honest and safe.
- **Windows numbers:** we only run the Linux server, so the script removes them rather than
  guessing.

We also looked up two NavBot-specific slots directly:

```sh
tools/vtable.py server_i486.so CGameRules    | grep ShouldCollide      # 29
tools/vtable.py server_i486.so CHL2MP_Player | grep ProcessUsercmds    # 377
```

**Lesson.** Symbols turn reverse engineering into lookups. When two versions of a program both
have symbols, you can map anything between them by name.

### 7.6 No IBotManager: driving bots the old way

**Symptom.** `Unable to load extension "navbot.ext": Could not find interface: BotManager001`.

**Background.** Newer Source engines provide `IBotManager`, which creates bots and gives you an
`IBotController` to make them move (`RunPlayerMove`) and switch weapons (`SetActiveWeapon`).
2007 doesn't have it.

**What 2007 does have:**
- `engine->CreateFakeClient(name)`, which creates a player slot with no network connection;
- the game's own `CBasePlayer::ProcessUsercmds(...)`, the function that applies a real
  player's input each tick. If we call it with a `CUserCmd` we build, the bot "presses keys."

NavBot already contained both paths. The fix was making `IBotManager` optional
(`patches/navbot-zps24.patch`):

```cpp
// Before: fail the whole load if the interface is missing.
GET_V_IFACE_CURRENT(GetServerFactory, botmanager, IBotManager, INTERFACEVERSION_PLAYERBOTMANAGER);

// After: ask, and accept NULL.
botmanager = static_cast<IBotManager*>(
    ismm->VInterfaceMatch(ismm->GetServerFactory(), INTERFACEVERSION_PLAYERBOTMANAGER));
```

Then every use of it gets a fallback. For example, switching weapons through the game's own
`Weapon_Switch` virtual function (slot 239, from our gamedata):

```cpp
void CBaseBot::SelectWeaponByClassname(const char* szclassname)
{
	if (m_controller != nullptr) {                     // newer engines
		m_controller->SetActiveWeapon(szclassname);
		return;
	}
	edict_t* weapon = nullptr;                         // 2007: find the weapon the bot owns
	if (Weapon_OwnsThisType(szclassname, &weapon) && weapon != nullptr)
		sdkcalls->CBaseCombatCharacter_Weapon_Switch(GetEntity(),
		                                             UtilHelpers::EdictToBaseEntity(weapon));
}
```

We also set `"HookPlayerRunCMD" "0"` in the 2.4 gamedata. ZPS 3.x runs bot commands itself, so
NavBot just hooks that. 2.4 is HL2MP-based and doesn't, so NavBot must call `ProcessUsercmds`.

**Lesson.** Before writing new code, look for an existing fallback path. Often the job is just
to make it reachable.

### 7.7 The 84-byte CUserCmd: reading struct sizes from machine code

**Symptom.** Adding a bot crashed the server inside `memmove`, with a destroyed stack (the
backtrace was garbage: `#1 0xfffaffff in ?? ()`).

**Theory.** NavBot builds a `CUserCmd` (the struct holding one tick of input: view angles,
movement, buttons) from the SDK headers and passes a pointer to `ProcessUsercmds`. If ZPS 2.4's
`CUserCmd` is *bigger* than the SDK's, the game copies past the end of our struct.

**Measuring the game's struct without source code.** `ProcessUsercmds` receives an *array* of
commands. Indexing an array means multiplying the index by the element size, so look for a
multiply instruction:

```sh
$ objdump -d -M intel ... --start-address=<ProcessUsercmds> ... | grep imul
imul   edx,ebx,0x54
imul   ecx,eax,0x54
```

`0x54` = 84 bytes. The SDK's `CUserCmd` is 64. So **ZPS 2.4 added 20 bytes**.

**What's in those 20 bytes?** Disassemble `ReadUsercmd`, the function that fills a `CUserCmd`
from network data, and list every offset it writes:

```
+0x4 command_number   +0x8 tick_count    +0xc..0x14 viewangles
+0x18..0x20 moves     +0x24 buttons      +0x28 impulse ... +0x3c hasbeenpredicted
+0x4c  <- something new
```

Everything up to 0x40 matches the SDK. Then there's a 20-byte block, with a write at
0x40 + 12. A `CUtlVector` (Source's growable array) is exactly 20 bytes, with its element count
at byte 12. So ZPS 2.4 appended a `CUtlVector` to `CUserCmd`.

**Root cause.** The game copy-constructs the struct, including that "vector," from whatever
stack garbage sits after our 64 bytes. Garbage pointer + garbage size = `memmove` into nowhere.

**Fix.** Give the game a buffer of *its* size, zero-filled. A zeroed `CUtlVector` is a valid
empty vector. From the patch:

```cpp
alignas(16) unsigned char storage[256] = {};      // zero-filled, big enough
CUserCmd& ucmd = *new (mem) CUserCmd();           // "placement new": construct inside our buffer
ucmd.viewangles  = botcmd->viewangles;            // fill the SDK-known fields as before
ucmd.forwardmove = botcmd->forwardmove;
...
// call ProcessUsercmds(&ucmd, ...): the game reads 84 bytes, the last 20 are a valid empty vector
ucmd.~CUserCmd();                                 // placement new needs a manual destructor call
```

The size comes from gamedata (`"CUserCmdSize" "84"`), so other mods can set their own.

**Lesson.** You can measure a struct you've never seen by finding the code that indexes arrays
of it, or copies it, and reading the constants.

### 7.8 "BOT" is not a Steam ID: catching a stack smash

**Symptom.** The crash came back in the same place: `memmove` with a smashed stack.

**Technique: break on the bad call, before the damage.** After a stack smash, the backtrace is
useless because the evidence has been overwritten. So stop *at the start* of the damaging call
instead, while the stack is intact. On 32-bit x86 Linux, function arguments are on the stack:
at a function's first instruction, `[esp]` is the return address and `[esp+4]`, `[esp+8]`,
`[esp+12]` are arguments 1, 2 and 3. For `memmove(dst, src, n)`, `n` is at `[esp+12]`.

A conditional breakpoint that only fires on absurd sizes:

```
break __memmove_sse2_unaligned if *(unsigned int*)($esp+12) > 0x10000000
commands
  printf "HUGE dst=%p src=%p n=%u\n", *(void**)($esp+4), *(void**)($esp+8), *(unsigned int*)($esp+12)
  bt 20
  continue
end
```

(The first try used 1 MB and caught a legitimate 1 MB copy during map loading. Raising the limit
to 256 MB leaves only the impossible.)

Result:

```
HUGE dst=0xffff9c48 src=0xffff9c52 n=4294967290
#1 CHL2MPRules::JoinRound(CHL2MP_Player*, bool) () from server_i486.so
```

4294967290 is −6 as an unsigned 32-bit number: a length computation went negative.

**Reading `JoinRound`.** First find which external functions it calls, from its relocations:

```sh
readelf -rW server_i486.so | awk '...address range of JoinRound...' | c++filt
  V_strncpy, memmove, atoi, atoi
```

Copy a string, move part of it, parse two numbers. Then the disassembly:

```asm
call V_strncpy(buf, player+0xf7e, 32)  ; copy a 32-byte string stored in the player
call V_strncpy(tmp, buf+8, 2)          ; take 1 character at index 8
...  ecx = strlen(buf) + 1
sub  ecx, 0xa                          ; minus 10
call memmove(buf, buf+10, ecx)         ; drop the first 10 characters
call atoi(buf); call atoi(tmp)         ; parse both parts
```

That's parsing `STEAM_0:X:YYYYYY`: index 8 is `X`, and after the first 10 characters comes the
account number. And `player+0xf7e`? It's touched by `CBasePlayer::GetNetworkIDString()`: the
player's cached network ID. For a bot, the engine returns `"BOT"`. Then `strlen("BOT") + 1 - 10`
= −6. ZPS 2.4 never had bots, so this was never hit.

**Fix.** Hook the engine function (section 4 showed the code) so bots get a well-formed fake
ID, `STEAM_0:0:<1000+slot>`. It's switched on by a gamedata key (`"SpoofBotNetworkID" "1"`), so
it only affects ZPS 2.4. The returned string must stay valid after the hook returns, so it lives
in a static per-slot buffer, not on the stack:

```cpp
static char s_fakeids[ABSOLUTE_PLAYER_LIMIT + 1][32];
```

**Lessons.**
- When the stack is smashed, break *before* the damage.
- Huge unsigned numbers are often small negative numbers: compute `2^32 - n`.
- Read a function's imports first; they tell you what it does before you read any assembly.

### 7.9 Events nobody listens to

**Symptom.** Next crash: a NULL pointer read inside `CZPLRules::JoinRound`.

**Investigation.** `info registers` showed `eax = 0` at the faulting `mov ecx, [eax]`. The
instruction before was a call to `gameeventmanager->CreateEvent(...)`. The event name was a
string constant at `0x1217f44`; reading the bytes there (mapping the virtual address to a file
offset through the program headers) gave `zombie_death`.

**Root cause.** `CreateEvent` returns NULL when no one is listening to that event, an
optimization. On a normal server, connected players' clients listen. With only bots, nobody
does. ZPS 2.4 never checks for NULL.

**Fix.** A plugin, `plugins/zps24_compat.sp`, that listens to every event defined in the
game's event files (59 of them), so `CreateEvent` always succeeds. Section 10 walks through it.

**Lesson.** Code written for one situation (humans always present) breaks in a new one
(bots alone). Look for assumptions, not just bugs.

### 7.10 Nav commands on a dedicated server

**Symptom.** `sm_nav_generate` did nothing at all: no error, no output.

**Root cause.** NavBot's permission check:

```cpp
bool UTIL_IsCommandIssuedByServerAdmin()
{
	if (engine->IsDedicatedServer())
		return false;        // nav editing was only meant for listen servers
	...
}
```

**Fix.** Return `true` on a dedicated server. Server-side console commands can only be run from
the server's own console or RCON, never by connected clients, so this is safe.

**Lesson.** Silent failures usually mean an early `return`. Grep for the command's handler and
read its first lines.

### 7.11 The server that only talks to itself

**Symptom.** Everything worked from scripts, but the real game couldn't join:
"Connection failed after 4 retries."

**Investigation.** First, take the client out of the picture. Send the server the standard
query packet that server browsers use (A2S_INFO) from a few lines of Python:

```python
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'\xff\xff\xff\xffTSource Engine Query\x00', ('127.0.0.1', 27015))
print(s.recvfrom(4096))     # timed out: no reply
```

No reply, so it wasn't the client. Then a matrix of restarts, changing one thing at a time:

| Setup | Reply on 127.0.0.1? | Reply on LAN IP? |
|---|---|---|
| Full setup, `+ip 127.0.0.1` | no | - |
| No Metamod | no | - |
| Original steamclient | no | - |
| No `+ip` (binds the LAN address) | no | **yes** |
| `+ip 127.0.0.2` | no | - |

**Root cause.** The 2007 engine treats any 127.x address as its *internal* loopback (the
in-memory path a listen server uses to talk to its own client), and drops real UDP packets
that come from one. Our RCON tests worked because RCON uses TCP, a different code path.

**Fix.** Bind to the LAN address and connect to that. `sv_lan 1` keeps internet clients out.

**Lesson.** Test the thing users actually do (joining), not just what your scripts do (RCON).
And when testing networking, build the smallest possible client yourself so you know which
side is broken.

---

## 8. Building everything

### Why we build from source at all

Metamod needed a code fix, and NavBot needed several. SourceMod didn't, so we use its official build.

### AMBuild

AlliedModders projects use **AMBuild**, a Python build system. The pattern is always:

```sh
mkdir build && cd build
python3 ../configure.py --sdks=orangebox --hl2sdk-root=/path/to/sdks --targets=x86 --enable-optimize
python3 -c "from ambuild2.run import cli_run; cli_run()"     # the 'ambuild' command without installing it
```

- `--sdks=orangebox` builds only the Source 2007 target (named `ep2` in output filenames).
- `--hl2sdk-root` is the folder containing `hl2sdk-orangebox/`, a copy of Valve's SDK headers
  for that engine, kept by AlliedModders.
- `--targets=x86` builds 32-bit. The 2007 engine is 32-bit only.

### Two compilers, on purpose

- **Metamod** is built with **i686 GCC 10** inside the **Steam Runtime "sniper" SDK container**
  (`podman run ... registry.gitlab.steamos.cloud/steamrt/sniper/sdk`). That's the same compiler
  generation AlliedModders uses for official builds, so we change only one thing at a time:
  our patch.
- **NavBot** requires C++20 and GCC 13+, which the container's 32-bit compiler doesn't have,
  so it's built on the host with GCC 14 and `-m32`. (Check that 32-bit works on your system by
  compiling a small program with `g++ -m32`.)

### Problems we hit while building

| Error | Cause | Fix |
|---|---|---|
| `Error: hl2sdk-ep2 was not found` | The manifest calls the SDK `orangebox` | Name the folder `hl2sdk-orangebox` and pass `--sdks=orangebox` |
| `-Werror=class-memaccess` in `platform.h` | The 2008 SDK headers trip newer warnings, and `-Werror` turns warnings into errors | Remove `-Werror` from `AMBuildScript` (in the patch) |
| `Only GCC versions 13 or later are supported` | NavBot needs C++20 | Build NavBot on the host with GCC 14 |
| `pip3: not found` in the container | No pip | AMBuild is pure Python: set `PYTHONPATH` to its checkout |
| The patch showed the whole file as changed | Python rewrote Windows line endings (CRLF) as LF | Open files with `newline=''` and keep the original endings |

`scripts/build.sh` does all of this from pinned commits, so anyone gets the same result.

---

## 9. Testing a game server without playing it

You can't play 200 test matches by hand. Every fix above was verified from a terminal.

### Feeding commands

1. **Through stdin:** `(sleep 80; printf 'sm exts list\nquit\n') | ./srcds_i486 -console ...`.
   Simple, but under gdb the server didn't read stdin at all.
2. **Through RCON** (the remote console protocol): start the server with
   `+rcon_password <random>` and send commands over TCP. Works under gdb, at any time, from any
   script. `scripts/rcon.py` is a complete client in about 30 lines:

```python
def pkt(i, t, body):                       # Source RCON packet: size, id, type, body, two NULs
    body = body.encode() + b'\0\0'
    return struct.pack('<iii', len(body) + 8, i, t) + body

s.sendall(pkt(1, 3, password))             # type 3 = SERVERDATA_AUTH
...
s.sendall(pkt(2, 2, command))              # type 2 = SERVERDATA_EXECCOMMAND
s.sendall(pkt(3, 0, ''))                   # an empty "marker" packet: when its echo
                                           # comes back, all output for the command has arrived
```

Use a long random password. (We first bound the server to `127.0.0.1` to keep RCON private,
which broke joining; see section 7.11. It now binds to the LAN address, with `sv_lan 1`.)

### Seeing what bots do

`plugins/zps24_botprobe.sp` prints every bot's team, health, position and weapon:

```
[probe] Bot 2 team=2 alive=1 hp=100 pos=1207 -1027 78 weapon=weapon_emptyhand
[probe] Bot 2 team=2 alive=1 hp=100 pos=-236 -63 78   weapon=weapon_emptyhand
```

Two snapshots 15 seconds apart showed the bot had crossed the map. Movement confirmed, no
screen needed.

### Trap: `pkill -f` kills your own shell

`pkill -f 'port 27026'` matches the *full command line* of every process, including the shell
running the `pkill` command itself, because that text is in its command line. The command
kills its own shell. Use `pgrep -x <program name>`, or note the PID and use `kill <pid>`.

---

## 10. Writing SourcePawn plugins

SourcePawn looks like C, with a few differences: no pointers, typed handles like `KeyValues`
and `ConVar` are objects you `delete`, and plugins react to callbacks from SourceMod.

### Anatomy of `zps24_compat.sp`

```c
#include <sourcemod>                       // the core API

public Plugin myinfo =                     // metadata shown in 'sm plugins list'
{
	name = "ZPS 2.4 bot compatibility",
	author = "Dead Apocalypse",
	description = "Keeps ZPS 2.4 from crashing on unlistened game events",
	version = "1.0"
};

static const char g_eventFiles[][] =       // a constant array of strings
{
	"resource/modevents.res",              // paths are relative to the mod folder, zps/
	"../hl2/resource/GameEvents.res",      // the base game's events live in hl2/
	"../hl2/resource/serverevents.res",
	"../hl2/resource/hltvevents.res"
};

public void OnPluginStart()                // called once when the plugin loads
{
	int hooked = 0;
	for (int i = 0; i < sizeof(g_eventFiles); i++)
	{
		KeyValues kv = new KeyValues("events");
		if (kv.ImportFromFile(g_eventFiles[i]) && kv.GotoFirstSubKey())
		{
			char name[64];
			do
			{
				kv.GetSectionName(name, sizeof(name));        // each section is one event
				if (HookEventEx(name, Event_Ignore, EventHookMode_PostNoCopy))
					hooked++;
			} while (kv.GotoNextKey());
		}
		delete kv;                         // handles must be freed
	}
	LogMessage("Listening to %d game events", hooked);
}

void Event_Ignore(Event event, const char[] name, bool dontBroadcast)
{
	// Doing nothing is the point: being registered makes CreateEvent() return a real event.
}
```

Things to notice:
- `HookEventEx` returns false instead of failing for unknown events, so a robust loop doesn't
  need to know the list in advance.
- `EventHookMode_PostNoCopy` is the cheapest mode: SourceMod doesn't copy the event's data for us.
- The first version used `resource/gameevents.res`, which silently found nothing. The real file
  is `hl2/resource/GameEvents.res`: a different folder *and* different capitalization. Linux
  filenames are case-sensitive.

### Compiling

```sh
addons/sourcemod/scripting/spcomp -i addons/sourcemod/scripting/include my.sp -o addons/sourcemod/plugins/my.smx
```

Then `sm plugins load my` on the server, or restart the map.

---

## 11. Teaching the bots to play

Getting NavBot to *run* on 2.4 was the port. Getting the bots to *play* ZPS well is a different
job: almost all of it lives in SourcePawn plugins, and most problems are found by watching
bots from a terminal (section 9) and asking "what did it decide, and why?".

### 11.1 Steering NavBot from a plugin

NavBot runs its own behavior for each bot (roam, fight, collect items). A plugin can take over
movement with a **scripted plugin command**:

```c
bot.SendScriptedPluginCommand(OnScriptedUpdate);   // once, from a timer

Action OnScriptedUpdate(NavBot bot, float moveGoal[3], NavBotRouteType& routeType)
{
	moveGoal = somewhere;              // where to walk; NavBot finds the path
	routeType = NAVBOT_FASTEST_ROUTE;  // or NAVBOT_SAFEST_ROUTE
	return Plugin_Changed;             // walk there
}
```

NavBot calls the function every bot update. The return value decides what happens:

| Return | Meaning |
|---|---|
| `Plugin_Changed` | Path to `moveGoal` and walk |
| `Plugin_Continue` | Keep the task running, but don't path anywhere (stand, or steer the bot yourself) |
| `Plugin_Stop` | End the task; NavBot's own behavior takes over |

NavBot's combat code still aims and shoots on its own, so a plugin mostly decides *where to be*.
`zps24_zombies.sp` and `zps24_survivors.sp` are built entirely on this.

### 11.2 Zombies stuck in a corner behind a wall

**Symptom.** At the end of a round, zombies crowded into a corner of a room, facing a wall. The
last survivor was in the room on the other side.

**Root cause.** Zombies walked to "the nav area nearest the survivor". The survivor was hiding
where the nav mesh doesn't reach (a closet, on furniture), and the nearest area within reach
was in the next room, through the wall. The zombies arrived there and, having "arrived",
stopped.

**Fix.** Only accept goals the survivor can be *seen* from:
`NavBotNavArea.IsVisible(area, survivorEye)`. Search a wider box if nothing is close, then fall
back to the last area the survivor stood on (`NavBotBasePlayer.GetLastKnownNavArea()`, which is
the way they came in). And if a zombie reaches its goal but the survivor is still behind a wall
after 2 seconds, mark that area as a dead end for 20 seconds and choose again.

**Lesson.** "Nearest" is measured in a straight line; bots travel along paths. Whenever a goal is
picked by distance, ask whether there's a wall in between.

### 11.3 Survivors shooting their own door down

**Symptom.** In the church, survivor bots destroyed the main door that was keeping zombies out.

**Investigation.** The map's entity list (lump 0 of the BSP file, readable with a few lines of
Python) shows the church doors are `func_breakable` with `material 1` (wood) and 2000 health.
Doors aren't usually breakables, so that was the clue.

**Root cause.** The survivor AI picked targets with a line-of-sight trace, and counted any
entity whose class name contains "breakable" as see-through, meant for window glass. A
zombie behind the door was "visible", so bots shot through the door until it broke.

**Fix.** See-through means glass only: `func_breakable_surf`, or `func_breakable` whose
`m_Material` is 0 (`matGlass`).

**Lesson.** Class names describe how an entity *behaves* in code, not what it *is* in the map.
Check the entity's properties (material, health) before deciding what it represents.

### 11.4 Reacting to being hit

Survivors used to keep shooting at whatever they could see, even while a zombie clawed them from
behind. The game fires a `player_hurt` event (`userid`, `attacker`, `health`) for every hit,
which SourceMod can listen to:

```c
HookEventEx("player_hurt", Event_PlayerHurt, EventHookMode_Post);
```

On a hit by a zombie the bot remembers the attacker for 3 seconds, turns to it
(`AimAtEntity(..., LOOK_CRITICAL, ...)`), keeps firing, and backs off until it's outside
`sm_zps24ai_safe_distance`. If an event ever arrives without an attacker, the nearest zombie in
claw reach is blamed. That's a defensive fallback, because 2.4 might not fill every field.

To back off without walking into walls, the bot tries seven directions away from the zombie
(straight away, then 35, 70 and 90 degrees to either side). For each it traces a player-sized
box to see how far it can actually walk, and picks the open one that ends farthest from the
zombie.

### 11.5 When the nav mesh is wrong: the church tower stairs

**Symptom.** Zombies couldn't get up the church tower. They walked into walls under survivors
standing on the floors above.

**Investigation, step 1: look at the mesh.** Bots only know what the nav mesh tells them, so the
first question is what the mesh contains. `zps24_navdebug.sp` adds console commands for that.
`sm_navdump` lists every area in a box with its neighbors:

```
#49  (-1150 200 256)-(-925 400 256) -> S414(dz -36 gap 25)
#125 (-1125 275 104)-(-925 375 104) -> S429 S168 W817 W818
#414 (-1150 425 210)-(-1125 450 228) -> N49(dz 36 gap 25)
```

The tower has floors at z -47, 104 and 256. Each floor had areas, but nothing linked them: the
staircases had no areas at all.

**Step 2: look at the geometry.** `sm_floormap` traces down on a grid and prints floor heights.
One row along a staircase, every 4 units:

```
94 94 94 85 85 76 76 76 67 67 58 58 58 49 49 40 40 40 31 31 31 21 21 11 11 11 1 1 -8 -8 -8 -18 -18 -28
```

Steps 9.5 units high and about 10 deep: easy for a player (the step height is 18), but steep,
about 43 degrees.

**Step 3: read the generator.** NavBot's generator (based on Valve's) walks the map in steps of
`generation_step_size`, 25 units by default, and checks whether it can move from one sample
point to the next. On these stairs 25 units of run is more than two steps, about 24 units of
rise, so most samples look like a wall.

**Attempt 1: sample more finely.** NavBot reads `NavGen_StepSize` from the game's gamedata keys.
At 12.5 the generator did put more areas in the tower, but still none on the stairs, and
`sm_navreach` (a breadth-first search over area connections) showed the whole church mesh had
broken into thousands of disconnected pieces: from most places only 1 to 30 areas were
reachable, against 359 before. Reverted.

**Attempt 2: seed the stairs.** The generator grows outward from "walkable seed" points, and
there's a native to add one (`NavBotNavMesh.AddWalkableSeed`). Adding a seed at runtime crashed
the server within a second, in `CNavMesh::Update()` (backtrace from `ZPS24_GDB=1`). Dropped.

**Attempt 3: connect the floors directly.** `NavBotNavArea.ConnectToAdjacent()` links two areas.
But the bot's path cost function (`bot_pathcosts.cpp`) refuses any normal link that climbs more
than a step or a jump, and the floors are 150 units apart.

**Fix: hand-made stair routes.** `NavBotMovementInterface.MoveTowards(movement, point, weight)`
makes a bot walk toward a point with no pathfinding at all. `plugins/include/zps24_stairs.inc`
describes each staircase as a list of points, from an approach point on the lower floor's mesh,
up the steps, to an exit point on the upper floor's mesh. A zombie that needs another floor of
the tower:

1. paths normally to the near end of the right staircase (`Plugin_Changed`);
2. is then steered point to point with `MoveTowards`, returning `Plugin_Continue` so NavBot
   doesn't try to path;
3. leaves the route at the far end, back on the mesh, and paths normally again.

Going down walks the same route backwards. If a bot makes no progress for 3 seconds (someone in
the way), it drops the route and retries.

**Testing it without playing.** `sm_navtp` pins a survivor bot on the third floor,
`sm_zps24zombies_force_target` makes every zombie hunt it, and `sm_where 3` prints zombie
positions every 5 seconds. Before: zombies at the outside wall. After: all 8 zombies on the third
floor within 75 seconds, and the survivor dead 4 seconds after being unpinned.

**Lessons.**
- Check the data before the code: one dump of the nav mesh showed the stairs were missing.
- A config change can break things far from where you look. Measure the whole result (here,
  reachability), not only the spot you were fixing.
- When a system can't be made to understand something, work around it at a higher level. Bots
  don't need nav areas on the stairs if a plugin can walk them up.
- Debug output can lie too: an early version of the test script read the wrong columns and
  reported zero zombies in the tower. Sanity-check your measurements.

### 11.6 Playing like a human: hands, windows and the house you spawn in

**The complaints.**
- Barricading bots bumped into furniture until it happened to slide into place.
- Bots stood at windows and shot the glass out.
- The whole team ran across the map to one "best" building instead of defending where they were.

**Finding the right tool: bare hands.** A ZPS player who wants to move furniture presses H for
bare hands and right-clicks to shove it. Could bots do the same? The server binary has symbols,
so `nm -C server_i486.so | grep CWeaponEmptyHand` answers it:

```
CWeaponEmptyHand::SecondaryAttack()
CWeaponEmptyHand::PuntVPhysics(CBaseEntity*, Vector const&, CGameTrace&)
```

The secondary attack "punts" physics objects along the aim direction, which is exactly the
shove. (`weapon_arms` is the zombies' version.) So a bot does what a player does:

1. `use weapon_emptyhand` (what H does);
2. aim at the furniture;
3. press attack 2 (right click).

**Pushing something somewhere.** A shove goes where you're looking, so to push a cabinet toward
a door you stand on the far side of it. The bot's spot is on the line from the door through the
furniture, 50 units behind it, snapped to the nav mesh. It shoves, the furniture slides, and it
re-computes the spot and walks behind it again. Two details make this robust:
- **Measure progress, not effort.** The bot keeps the closest distance the furniture has been to
  the door. Six shoves without getting it 8 units closer mean it's too heavy or wedged, so the
  bot blacklists it and picks another piece.
- **Only furniture on the right side.** A dot product with the door's "inside" vector
  (`(prop - door) . inside >= 0`) keeps bots from pushing a bench from the porch into the
  outside of the door.

**Testing showed two more problems**, both visible in a per-shove log line ("furniture 144 is 93
from door 1"):
- **Bots shoved from too far away.** Bare hands reach about 70 units from the eyes. When the
  spot behind the furniture was off the nav mesh, the bot shoved from wherever it stood,
  sometimes 280 units away. Now it steps in (`MoveTowards`) until the furniture is in reach.
- **The punt is weak.** Light props slid; cabinets barely moved. Since the player's request was
  to "bump furniture harder", each shove that lands within reach also gives the prop a push
  0.25 s later, as the hands connect. `TeleportEntity(prop, NULL_VECTOR, NULL_VECTOR, velocity)`
  sets a physics prop's velocity: 220 units/s toward the door, with a little lift so it slides
  instead of digging into the floor.

The same shove clears the way when walking. NavBot reports what blocks a bot's path through the
`OnNavBotObstacleOnPath` forward (see 11.3). For a loose prop, the bot now shoves it about 20
degrees off its path, so it lands beside the route rather than further along it. Furniture that
is already blocking a door, and barricade boards (any model with `barricade` in its name), are
never shoved.

**Windows: hold back and wait.** The fix has three parts:
- **Classify every opening.** Doors are door entities, plus wooden `func_breakable`s of door
  height (the church's main doors). Everything else (`func_breakable_surf`, glass
  `func_breakable`) is a window.
- **Keep defend spots away from windows.** Any nav area within 150 units of a window gets a
  score penalty so large it is never picked. Retreat spots within 100 units of one are skipped.
  Furniture only goes into doors.
- **Never shoot through intact glass.** `ClearShot()` traces from the bot's eye to the zombie.
  Anything other than the zombie, the world or a shattered window (`m_bIsBroken`) blocks the
  shot. So a bot watches the window, lets the zombie break in, and shoots it as it climbs
  through. The same check now guards the "I've been hit" reaction (11.4), which used to fire
  blindly at the attacker, sometimes through a door or barricade.

**Defend the house you spawn in.** The old code picked one building for the whole team: the
densest cluster of doors and windows on the map. Now:
- **Remember the spawn.** `player_spawn` records where each survivor bot spawned (after a
  0.2 s timer, because the position isn't final yet when the event fires).
- **Find the house.** The exterior door or window nearest that point, plus every one within
  `sm_zps24ai_holdout_radius` of it, is the bot's **home**.
- **Share the home.** Bots that spawn in the same house find the same home, because a new home
  is only made when no existing one is within the radius. Up to four homes at once. Each home
  has its own defend spots, doors and barricaders.
- **Overrun:** if three bots die at a home and three zombies are inside it, it's marked bad and
  its bots move to the house nearest to where they are.

**A bug the test found at once.** On the cabin map one bot's home got a single defend spot.
`sm_navreach` from its position showed why: it stood on a two-area island of nav mesh with no
connection to the rest of the map. Searching outward from there found nothing. The fix: if the
search from the spawn finds fewer than 12 areas, the home is centered on its doors and windows
instead. Same house, 22 defend spots.

**Which doors lead outside?** Openings are found by headroom. Just beside an outside door, one
side has a roof (less than 400 units of space above) and the other has sky. The first test round
on the cabin found only 3 outside doors on the whole map. `sm_zps24ai_doors` lists every door
with its headroom on both sides and showed `73 / 73` for many of them: porches, roofed on both
sides at 48 units out. Doors now also sample 128 and 208 units out, and count as outside doors
when only one side reaches open sky. Doors inside a house stay roofed on both sides and are
still left out. `sm_zps24ai_status all` lists every home's doors and windows, so the
classification can be checked on any map.

**"Some bots are just standing."** During testing, survivors stood frozen. A new console command,
`sm_zps24ai_bots`, prints each bot's last decision ("walking to defend spot", "shoving
furniture aside"...) next to NavBot's task. The frozen bots showed NavBot's task as
`ScriptedBehavior` and an empty decision: the plugin's update function was never being called.
The cause was my own plugin reloads while testing:

- **The task outlives the plugin.** A scripted task holds a SourceMod forward with one function
  in it, the plugin's `OnScriptedUpdate`. When the plugin unloads, SourceMod removes that
  function from every forward. The task keeps running and calls an empty forward every frame.
  The result defaults to `Plugin_Continue`, which means "stand still, don't path".
- **Stopping it didn't work either.** The reloaded plugin sees a scripted task already running
  and sends the stop command, but the task never ended.

The fix is in NavBot (`patches/navbot-zps24.patch`). At the top of the task's update:

```cpp
if (m_updatecallback->GetFunctionCount() == 0)
    return AITask<BotClass>::Done("Scripted callback's plugin was unloaded!");
```

The task ends by itself, the bot falls back to its normal behavior, and the reloaded plugin
hands it a fresh scripted task on its next tick. Tested by reloading the plugin mid-round: every
bot was steered again within seconds.

**Lessons.**
- Give your AI a way to say what it's thinking (`sm_zps24ai_bots`). "Standing still" has a
  dozen causes, and one line per bot tells them apart.
- Anything that holds a callback into a plugin must handle that plugin going away.

### 11.7 Learning from the main player

**The request.** "Follow me and learn from my survival and waypoint movement skills, and follow
only me." Rather than guessing good hold spots and routes from map geometry, the bots copy
what the player does. This is *learning from demonstration*: no neural network, just careful
recording of the right events, and using them where the hand-written rules used to guess.

**Who to learn from.** `zps24_learn.sp` watches only the *teacher*: a player with admin rights
(the host is admin by IP, set up by `zps24_admin`), or whoever `sm_zps24learn_teacher` names.
Learning from everyone would mix good habits with bad ones.

**What gets recorded** (every 0.25 s while the teacher is alive):

1. **Hold spots.** An "anchor" is the spot where the player stopped. Moving more than 80 units
   away ends it, and if they stayed 10 seconds or more it becomes a hold spot. Seconds
   accumulate per spot, so places held often and long rank highest. Dying there counts a
   quarter: the spot was held, but it didn't save them.
2. **Routes.** This generalizes the hand-made stair routes from 11.5:
   - **Start:** while the player stands on the nav mesh (`GetNearestNavArea`, then
     `GetClosestPointOnArea` within 12 units and at the right height), remember the spot.
   - **Off the mesh:** when they leave it, record their path every 24 units of movement on the
     ground.
   - **Save:** when they're back on the mesh on a different floor (48+ units higher or lower),
     the path from the last on-mesh point to the first on-mesh point is a route.
   - **Discard:** paths with a ladder or noclip, or longer than 15 s off the mesh.
   - **Repeats:** the same route taken again (both ends within 64 units) just adds a use.
3. **Fighting distances.** The distance to the nearest zombie at the moment the player starts
   firing a gun, and at the moment they start moving away from it (velocity pointing away at
   more than 0.7 of their speed, within 600 units). Only the *start* of each action counts, so
   holding the trigger for three seconds is one sample, not twelve.

4. **Furniture placements** (added after the first test sessions, "continue learning"):
   - **Watch:** every physics prop that comes within 110 units of the teacher is watched (up
     to 32 at a time).
   - **Who moved it:** when a watched prop moves while the teacher is within 160 units, it's
     the teacher moving it; anything else moving it (a zombie, physics) just updates its start.
   - **Record:** once it comes to rest 48+ units from where it started, that's a placement:
     which prop, where it started the round, where the teacher left it.
   - **Recognize it next round:** by its `m_iHammerID`, the ID the map editor gave it, the same
     every round even though entity indexes change. Props without one are matched by start
     position.
   - **Undo:** putting a prop back where it started forgets the placement.

5. **Entrances**, while the teacher plays zombie. Each tick on the ground, the teacher is
   outdoors or indoors (more or less than 400 units of headroom). Going from outdoors to
   indoors within a second, and less than 200 units apart, is an entrance: the last point
   outside and the first point inside. The same entrance again (inside points within 80
   units) adds a use.

6. **Zombie tricks: building a step.** The player, as a zombie, pushed a car under a roof edge,
   jumped onto it, then onto the roof, and went in through a top window. Three changes taught
   the bots this:
   - **Furniture placements are recorded on both teams**, tagged with the team. Survivor
     placements are barricades; zombie placements are steps. Each round the nearest zombie bot
     is assigned to push the piece where the player put it. It stands on the far side, sized
     from the prop's bounds since a car is much bigger than a chair, and shoves with right
     click plus the push assist. Once the piece is in place, no zombie shoves it aside.
   - **Routes keep more and last longer:** up to 24 points (was 12) and 45 s off the mesh (was
     15), so a slow climb across a roof still counts and the point on top of the car isn't
     thinned away.
   - **Bots jump along routes.** When the next point is more than a step (18 units) higher,
     the bot presses jump and holds crouch, the HL2 crouch-jump players use to climb. The
     recorded climb went ground 8 → car 28 → 81 → 130 → roof 168: four jumps.

7. **Camera and posture at hold spots** ("record my movements and camera and learn"). While the
   teacher holds a spot, every 0.25 s the plugin traces their view (eyes along the view
   direction, world only) and keeps the hit point, a fair sample of up to 64 per hold, plus
   whether they're crouched. When they leave, the points are grouped into 8 compass sectors
   around the spot; every sector they watched at least 15% of the time becomes a watch point
   (the average hit point), up to 4, merged with earlier ones that point elsewhere. Crouched
   60%+ of the time marks the spot as a crouch spot. A survivor bot holding that spot crouches
   if the teacher did and looks at the teacher's watch points instead of random doors and
   windows.
8. **A raw recording** of everything, 10 times a second, as CSV per map (`rec/<map>.csv`): the
   material for anything else worth learning later (aim habits, movement between spots).

The file is a KeyValues text file per map in `data/zps24_learn/`, readable and editable by hand.

**How the bots use it** (`include/zps24_learned.inc`, loaded at map and round start):
- **Hold spots:** survivor homes put the player's spots in the house first, most-held first,
  ahead of the computed upstairs and corner spots. Bots spread over the best four or more
  instead of piling onto one.
- **Routes:** they join the hand-made stair routes in `zps24_stairs.inc`, with a general rule
  for picking one. A route qualifies if:
  - its start is on the bot's floor and within 1200 units;
  - its end is at least 40 units closer in height to where the bot wants to be;
  - its end is within 1500 units of that place.

  The cheapest one wins (distance to its start, half the distance from its end, plus the
  height left over). Zombies use them to chase, and survivors use them to reach their defend
  spot, which also gives survivors the church tower's hand-made stair routes at last.
- **Furniture placements:** a new job type, `JOB_PLACE`. When a house's furniture-pushers are
  handed out, they first take the teacher's placements in that house, then the doors. The
  shoving code from 11.6 became one function, `PushProp(prop, destination)`, shared by both
  jobs. Pieces the teacher uses are reserved: door barricaders don't take them, and bots
  walking past don't shove them aside once they're in place.
- **Entrances and spreading out:** a zombie outdoors, hunting a survivor who is indoors and out
  of sight, now picks its own way in. Candidates are the teacher's entrances near the target
  and every door or window near it that leads from outside (the point on the zombie's side
  has open sky, the far side has a roof). Cost: the distance to the target, minus a bonus for
  learned entrances (bigger for often-used ones), plus 300 for each other zombie already
  heading through it. That last term spreads the horde over every way in, so survivors can't
  hold one door. At the entrance the zombie pushes through to the inside point; anything in
  the way gets smashed or shoved.
- **Windows first, then open the door from the inside** (the player's tactics, refined over a
  play session):
  - *The car trick was dropped.* Teaching zombies to push a car under a roof edge and climb
    worked, but in practice they got "confused and inefficient". The lessons were removed with
    a new `sm_zps24learn_drop` command, step-building is off (`sm_zps24zombies_build_steps 0`),
    and furniture is only learned from survivors.
  - *Ground-floor windows get a big bonus* when choosing an entrance. A window counts only if
    its sill (the brush's bottom edge) is within a crouch-jump (56 units) of the ground outside.
    At the window the zombie swings until the glass is gone (`m_bIsBroken`), swings one more
    second to clear the shards, then climbs straight in, steering itself with jump + crouch.
    Leaving it to the pathfinder would walk it round to a door.
  - *Too strong or too slow?* After 8 s with the window intact (boarded, reinforced), the
    window goes on a list shared by the horde and the zombie tries doors for 30 s.
  - *Unbar from the inside.* Some doors are held shut by a physics object: on cabin, a plank
    (`func_physbox`) on one door, a padlock prop on the double gate, furniture against
    others. `sm_zps24_doorbars` lists them. A zombie that climbed in through a window looks for
    the nearest barred door on its floor, walks up on the inside, alternates swing (planks
    break) and shove with the push assist (padlocks and furniture move off the door), and
    once nothing physical is within 75 units of the door, fires the door's `Unlock` and `Open`
    inputs. The rest of the horde walks in.
  - *Always go in.* An entrance is used whenever the zombie is outside and its survivor inside,
    even if it can see them through the glass (rushing at them sent the pathfinder round to a
    door).
- **Sealed rooms: break through, don't link.** Cabin's ammo room was a nav island: a window on
  one side, a doorway with a plank across it (`func_physbox`) on the other. The first attempt
  linked the nav areas through planks, and it went wrong twice:
  - **A board over a window looked like a doorway.** The trace down from it stopped on the
    sill, so the floor seemed clear. Zombies pathed into the main house wall under the window.
  - **Survivors used the links too.** They plan their defence by walking the nav mesh, so they
    picked spots behind planks and barred doors, then stood stuck in front of barricades
    they're not allowed to break.

  So links are now only made through plain doors. Everything else found at map start
  becomes an *opening to break*: planks, doors with a bar against them, glass windows, and
  boarded windows within a climb of the floor. Each one stores its blocker, a walkable point on
  each side, and whether it needs a climb. Then the whole mesh is labelled into *regions*
  (connected areas, found with an undirected flood fill). A zombie whose survivor is in another
  region picks the cheapest opening between the two regions (distance, plus a penalty per zombie
  already using it) and goes through three phases:
  1. walk up to its side;
  2. break the blocker: swing at glass; swing and shove (with the push assist) at planks and
     bars until they're 40 units off; for a barred door, `Unlock` and `Open`;
  3. steer through to the far point, jumping if it's a climb.

  An opening that holds for 12 s is marked tough for the round. On cabin: 18 openings, 8 regions.
- **Survivors on ledges.** A survivor on a narrow ledge in the cabin's upstairs bedroom, 46
  units above the floor, made zombies grind into the wall. In the nav mesh that ledge only has
  connections leading off it, so a path can never end there. Goal areas must now be
  *enterable* (some neighbour connects into them); the nearest is chosen by horizontal distance
  first, so the floor right below wins. Close to a survivor who is 30+ units higher, a zombie
  jumps (crouched) while swinging.
- **Zombies shove furniture too** (right click with `weapon_arms`, the same push assist as
  survivors). Furniture that doesn't move goes on a list shared by the whole horde, so after
  the first zombie finds a fixed piece, the rest treat it like a wall.
- **Fighting distances:** with 20+ shooting samples, the engage range becomes the player's
  average plus 15% (kept within 250 to 1200 units). With 10+ back-off samples, the safe
  distance becomes the player's average (120 to 500).

**Lessons.**
- Learning from demonstration is mostly deciding which *moments* matter: the start of an action,
  the end of a stay, the points where the player did something the map data can't explain.
- Learn from one trusted teacher, and weight the outcome (time survived, death) into what you
  keep.
- Keep learned data in a plain text file: you can read it, fix a bad lesson by hand, or wipe it
  (`sm_zps24learn_forget`).
- Before building a workaround, look for the game's own mechanism (here, the hands' punt). A
  bot that plays with the player's controls looks human, and the game's physics does the work.
- Make every repeated action check its own progress, and give up after a few tries.
- "Don't do X" rules need a check right where the action happens, not just a general tendency.
  The "never shoot glass" rule lives in the line-of-fire trace, so every place that fires obeys
  it.

### 11.8 Nav meshes for every map

The request: bots on the cinema map, in the rotation, then meshes for all the other maps.

- **Generate without disturbing the player.** A second server instance from the same install,
  on another port with 2 slots, did the work while the player stayed on cabin (each instance
  writes `.smnav` files into the shared data folder).
- **"Generating Navigation Mesh..." and then nothing.** Generating kicks every bot (it's a
  "dangerous" edit, 7.x), so the server is empty. An empty Source server stops *simulating*,
  and NavBot's `GameFrame` hook returned early when not simulating, so generation never
  advanced. It used to work only because the player was connected. Patch: keep calling
  `TheNavMesh->Update()` while `IsGenerating()`, even when not simulating. Cinema then
  generated in under a minute.
- **Waiting on a server from a script.** The first batch run watched the server's stdout for
  "nav mesh loaded" lines. That output is block-buffered into the log file, so lines arrived
  late and the script raced ahead, changing maps every 2 seconds. Asking the server directly
  (RCON `status` until it reports the new map) fixed it.
- **Measuring the result.** After each map: reload, then `sm_navreach` from a bot to count
  reachable areas. Most maps: 85-99%. Objective maps can show much less from one spawn
  (shreddingfield: survivors 6%, zombies 68%) because they're built in sections that open as
  objectives are done.
- **The one failure, zpo_aquatica**: "Sampling walkable space" finished in 0.1 s with nothing.
  The spawns exist and have a floor under them (`sm_floormap`), but the generator's ground trace
  looks *through* entities it considers walkable; if the start areas stand on such entities, no
  seed lands on usable ground. Left without a mesh (an empty mesh is worse: bots load it and
  stand still).

**Lessons.**
- "Works on my server" can hide a dependency on someone being connected.
- Don't scrape a buffered log to decide when something is ready; ask the program.
- Measure every generated result; one number per map (reachability) catches bad meshes.
- Never kill processes by matching a pattern that's also in your own command line (this bit
  twice more tonight: `pkill -f srcds.exe`, then a `grep srcds_i486.*27035`). Track PIDs.

---

### 11.9 zps_cinema: hold the cinema, not the street

"All survivors stay outside when they're supposed to go inside, hide in different spots and
shoot zombies from the upper floors and basements." The nav mesh was fine (the survivor spawn
reached 97% of it, basements and upper floors included). The survivor AI's choices weren't:

- **Outdoor spots were only penalized a little**, so with a street spawn and few recognized
  doors and windows, the "house" was the street. Now defend spots must be roofed whenever the
  area has 6+ roofed areas, and the search widens (x1.8, twice) until it finds at least 16.
- **Only "upstairs" counted, measured from the lowest area.** With basements around, the
  lowest area *is* the basement. Heights are now measured from the home's ground level, and
  basements count as good spots too.
- **The cinema is 3,000 units from the spawn.** Every first-floor area cluster sat far west
  (x -2900 to -1900), next to where the player's learned route went up to z 152; "defend the
  house you spawned in" can never pick it. The player confirmed: the upper floors are *the*
  hiding place. So a per-map config, `configs/zps24_maps.cfg`, can name a hold-out: every
  survivor bot's home becomes the cinema, upper floors only (zombies spawn at basement level
  right next to it), heights from street level.
- **"Hide in different spots":** bots picked randomly among the best spots and three ended up
  on one. Now each takes a spot no other bot of its home holds.

Result: all survivor bots crossed to the cinema and spread over its upper floor (z 48-64,
about 150 above the street) within a minute.

**Lessons.** Measure the nav mesh before blaming it. A general rule ("defend where you spawn")
needs an escape hatch for maps that are designed differently, and the player knows the map.

### 11.10 Zombies at the tower door, and ladders

**"Zombies can't reach me on the second floor again"** (the church tower). The tower doorway was
open (a horizontal trace went straight through) and its nav area connected, yet over a minute no
zombie got inside. The log said why: 17 times "is stuck, smashing func_breakable". Twenty zombies
funnel into a 70-unit doorway and block each other; the ones at the back stop moving, the stuck
check fires after 1.5 s, and it smashed *the nearest breakable in any direction*: the tower's
closed side door (3000 hp) next to the open doorway. Their hits chipped it, so they never gave up.
Fixes:
- an obstacle only counts if it's **ahead**: in the direction the zombie faces (bots face where
  they walk) or towards its target;
- **a zombie with another zombie right in front of it is queuing, not stuck**: no smashing, no
  unstick detours, it keeps pushing.

**"Zombies can't climb the ladder in my house."** NavBot's own ladder movement never worked on
2.4's walk-in ladders (`info_ladder`; "you don't need E", as the player put it), and the nav mesh
had no ladder links there anyway. So ladders became routes, like the tower stairs (11.5): at map
start every `info_ladder` (its `mins`/`maxs` are in the datamap) gives four points: floor in front,
the foot, the top, and a step off onto the floor above, found by looking for nav areas on each side
at the bottom and top heights. On the climb the bot faces the ladder, looks the way it's going and
walks forward into it. Two details of the route code had to change for this:
- a point counts as reached only when it's also reached in **height** (foot and top have the same
  x and y, so the climb was skipped);
- progress is measured in **3D** (climbing doesn't change the horizontal distance, so the route
  gave up after 3 s).

Ladder routes are always used (learned routes only when stuck). Tested: zombies chasing a survivor
pinned upstairs climbed the church house ladder and finished at the top (z 72).

**Lessons.** "Stuck" needs a cause: blocked by *what*, and in *which direction*? And when one
mechanism (stair routes) works, reuse it for the next problem of the same shape (ladders).

### 11.11 Builders: the hammer, learned from the player

Why the hammer was hard (weight limit, no direct equip, the fit check that only passes for an
aim held through the whole animation, windows the bots were told to avoid, no
`CanAttachBarricade` on Windows) is explained in the docs; the way around most of it is the
player:

- **Builders.** A few survivor bots (`sm_zps24ai_builders`, 2 in total, one per house) drop
  their melee weapons and take the hammer: one lying within 600 units, else a fresh
  `weapon_barricade`, put in front of their face and taken with the real E key. Dropping the
  melee weapons is enough for ZPS 2.4's weight limit (tested: builder with an MP5 and the
  hammer); if the hammer still won't come after 3 offers, the main gun goes too.
- **Lessons.** The learner watches for new boards (props with a `barricades/barricade_` model).
  A new one within 220 units of the teacher, who holds the hammer and swung in the last 3 s, is
  theirs: it records where they stood, where their view hit and where the board went. Boards
  that bots nail are only marked as seen.
- **Replay.** A builder takes the nearest of the teacher's boards in its house that isn't up
  (never built this round, or broken by zombies), walks to where the teacher stood, switches to
  the hammer, aims where the teacher aimed and holds attack for the whole animation, then
  checks a board appeared there. Three misses and that board is skipped for the round; when all
  are up, back to the guns. Every 10 s it checks again, so broken boards get rebuilt.

No fit check is needed: the teacher's spot already fitted. So this works on the Windows build
too, where `CanAttachBarricade` doesn't exist.

**Handing in the melee weapon.** The first try used the `dropweapon` command. It worked, but the
bot was standing on the weapon it had just dropped and picked it straight back up: an endless
"drops its melee weapon" loop. Now the builder switches to the melee weapon, drops it through the
game's own `Weapon_Drop` (SDKHooks), so ZPS's weight bookkeeping stays right, and then removes
it. It's a real exchange: melee out, hammer in. Builders also skip the furniture and
barricade-an-opening jobs, so they don't get pulled away from their boards.

### 11.12 Basement doors: the one door survivors break

Survivors never break doors, windows or barricades (11.1). The church's basement doors are the
exception: they are `func_breakable`s, the nav path into the basement runs through them, and a
closed one leaves the bot standing in front of it forever.

When NavBot reports a `func_breakable` on the path (`OnNavBotObstacleOnPath`), the bot checks
whether it's a basement door:

- door-shaped: thinner than 16 units and at least 70 tall;
- its middle sits more than 60 units below the ground floor of the bot's home.

If so, the bot switches to its melee weapon (bare hands if it has none), walks up to the door,
aims at its middle and left-clicks until the door breaks (state "breaking the basement door",
20 s at most). Then it carries on down. Every time a bot goes there, it does the same. Doors at
ground level and above are still never touched.

### 11.13 Doors that don't move when you bump them: press E

ZPS has two kinds of doors. Physics doors (`prop_physics` shaped like a door) swing when pushed,
so walking or shoving through works. Hinged doors (`prop_door_rotating`, `func_door_rotating`,
`func_door`) are not physics objects: bumping them does nothing, and a player opens them with E.
Bots used to walk into these and stand there (survivors), or smash them (zombies).

`plugins/include/zps24_doors.inc` now handles hinged doors for both teams:

- **Every think:** if a closed, unlocked hinged door is within 80 units in front of the bot
  (where it faces or where it's moving), the bot aims at it and presses E (state "opening a door
  (E)"). It only presses on closed doors, so it never shuts an open one.
- **On the nav path:** when NavBot reports a hinged door as the obstacle, the bot presses E
  instead of bumping, shoving or breaking it.
- **If it stays shut:** two presses, then that door is left alone for 10 s. It is locked,
  barred by a plank or furniture, or this team can't use it. Zombies then fall back to the
  breach logic (break the bar, smash the door); survivors walk around, because they never break
  doors (except basement doors, 11.12).

### 11.14 Playing ZPS 3.x maps on 2.4 (the lake maps)

The four lake maps (zpo_lake_of_the_dead_v1b, zpo_lake_silence_sfr_v9, zpo_lake_dead_sfr_v10,
zpo_lake_plasterd_sfr_v10) came from the Steam Workshop for ZPS 3.x. Copied as they are, all four
crash the 2.4 server while loading. Three reasons, all fixed by `tools/bsp_to_24.py`:

1. **Static props, version 10.** The map compiler for 3.x (Source 2013) writes static props as
   version 10; the 2.4 engine (Source 2007) reads up to version 6 and segfaults. A v10 record
   begins with the v6 fields, so the tool keeps those 60 bytes, adds v6's two DX-level fields,
   and rewrites the game lump at the end of the file.
2. **3.x item names.** `item_ammo_rifle`, `_shotgun`, `_revolver`, barricade ammo and pills don't
   exist in 2.4, so those maps had almost no ammo. They are renamed to the 2.4 items
   (`item_ammo_rifle_clip`, `item_ammo_shotgun_clip`, `item_ammo_357`, the hammer, the health vial).
   2.4 skips the rest (armor, item crates, 3.x round logic).
3. **Physics props (lake_of_the_dead only).** The map crashed in
   `CPhysicsPropMultiplayer::Spawn`. Bisecting the 126 props (keep the first N, test, halve)
   found an `airboat_broken_engine` gib, which is now dropped. After that it still crashed past
   about 80 identical shelves, so it's a limit, not a bad model. With `--physprops` they become
   plain `prop_physics`, and the map loads. Furniture still moves and shoves the same way.

The client needs the same converted file: copy it into the 2.4 install's `zps/maps` too.
Otherwise the CRCs differ and the client refuses the map. Each map then got a nav mesh on the
test server (port 27035) and joined `mapcycle_bots.txt`.

How to test a map without disturbing the game: `zps24-test-server.sh start <map>`, then
`zps24-test-server.sh cmd status`. If no `map :` line comes back, it crashed. To see where, run
the same srcds command under `gdb -batch -ex run -ex bt`.

### 11.15 zps_cinema: spread out and patrol, and the balcony drops

**Spread and patrol.** Two new per-map keys in `configs/zps24_maps.cfg`:

- `"spread" "1"`: defend spots all over the building. Every floor counts the same (no
  upper-floor bonus), indoors only, never next to a window, and at least 220 units apart instead
  of 96, so 16-32 spots cover the whole cinema.
- `"patrol" "0.5"`: half the survivor bots (picked by client index, so the same ones all round)
  are patrollers. A patroller walks to a free spot 250-1500 units away (another room or floor),
  looks around there for 5-12 s, then moves on. The others hold a spot for 25-45 s as before.
  Nobody moves on while a zombie is within 900 units.

`sm_zps24ai_bots` now shows each bot's spot (`-> spot N (x y z)`, `patrol` for patrollers).

**"All stuck on the upper floor".** With spots on every floor, bots on the upper floor had to get
downstairs. The generated mesh had "drop down" connections from the balcony edge to the hall
167-176 units below, and the pathfinder took them as the shortcut. But a railing stands on that
edge: the bots walked into it and stayed there. Found with `sm_navdump` (the `dz -168 gap 25`
connections).

`sm_navfixdrops` (zps24_navdebug) checks every drop-down connection (more than 60 units down)
for any map. It sweeps a player hull off the ledge at step height (a railing or glass blocks it),
then down onto the lower area. `sm_navfixdrops` lists the blocked ones and `sm_navfixdrops apply`
removes them. Then `sv_cheats 1; sm_nav_save; sv_cheats 0` writes the fixed mesh. On zps_cinema
it found 16: the 12 balcony drops and 4 small ledges outside. Bots now use the stairs.

Removing connections at runtime kicks every bot; the quota adds them back within seconds.

### 11.16 Zombie hordes and picking off stragglers

On zps_cinema the zombies lost every round. Survivors hold out together in one building, and the
zombies came in one by one, each walking into a dozen guns. Two changes in zps24_zombies:

- **Hordes** (`sm_zps24zombies_waves 1`). Once a second the plugin checks whether the survivors are
  dug in: 3 or more within 900 units of their middle. If so, the zombies **gather** at a staging
  point 800 units from the survivors, on the zombies' side, snapped to the nav mesh (they walk
  there by the safest route and wait, facing their target). They **charge** together when 60%
  of the zombie bots are within 300 units of it, or after 30 s, so they never wait forever. A
  charge lasts 45 s, then they gather again. While gathering, a zombie still attacks anyone it
  sees within 500 units, and any lone survivor within 1500.
- **Stragglers first.** When choosing whom to hunt, each other survivor within 450 units of a
  target counts as 300 units of extra distance. So patrollers and anyone who wanders off get
  picked off first, and the zombie numbers grow before the big push.

Debug (`sm_zps24zombies_debug 1`, in server.log): "Horde: gathering at ..." and
"Horde: CHARGE with N of M zombies".

**Zombies that never attacked (zpo_lake_of_the_dead).** After a map change, every zombie was
roaming on NavBot's default behaviour and nobody got attacked. The plugin's think timer was
running, but its "is our script running?" check trusted NavBot's "plugin command running" flag.
That flag was still set while the bot was plainly not running a script, so the plugin kept
sending "stop" and never started its own. `sm_zps24zombies_status` (new: horde state, then every
zombie bot with its target, goal and current NavBot task) showed `scripted 0` and
`MainTask(Tactical(Scenario(ObjectiveZombie)))`, with no `ScriptedBehavior`. Now the check reads
the bot's task string. No `ScriptedBehavior` means the script isn't running, and after 4
unanswered stops the plugin starts it regardless.

**The hook's line, and "TempEntity System unsupported".** Every frame of the grappling hook (V)
logged an exception from `TE_SetupBeamPoints`, and the beam never showed. SourceMod's
temp-entity support (beams, sparks, smoke: effects sent to clients without an entity) has to find
the server's list of temp-entity types, `CBaseTempEntity::s_pTempEntities`. Its own gamedata
lists that only for a few named Source 2007 mods, not ZPS. The 2.4 `server_i486.so` exports the
symbol, so `gamedata/sdktools.games-game.zpanic.txt` now names it, with the same three offsets
the other 2007 mods use (name 4, next 8, server class 0). Check with `sm_dump_teprops te.txt`:
it writes 44 temp entities (into `zps/`). SDKTools reads this at startup, so it takes effect
after a server restart.

### 11.17 Getting out of the water (the lake maps)

On zpo_lake_of_the_dead the zombies spawn in the lake and paddled against the platforms forever.
Three things learned on the way:

- **The lake's `trigger_push` isn't a lift.** "zspawn" is a zombie-only push straight up, but
  it covers the whole lake below z 64. It just floats zombies to the surface. And the
  platforms are about 110 units above the surface, too high for Source's water jump (hold jump +
  forward against a ledge), which only climbs edges below eye height.
- **The way out is the main player's.** The recording (`data/zps24_learn/rec/<map>.csv`) shows
  the teacher walking along the lake bottom to (-40 1146 0), up an underwater slope to z 63,
  then up the bank to z 139 and onto the platform. zps24_learn had saved it as a route that
  starts in the water and ends on dry ground higher up.
- **Rule: always get out of the water first.** A zombie at water level 2 or more (waist deep)
  does nothing else (`UpdateSwim`, before hunting, hordes or entries). It holds jump to stay at
  the surface and heads for the nearest learned route that starts in the water and ends dry and
  60+ units higher. It then follows that route point by point, also after leaving the water,
  until the last point. If there is no such route, or a bank or ramp at about its own height is
  400+ units closer, it goes to the bank. After that the normal hunt takes over: windows and
  doors first, roofs through the teacher's climbing routes.

**They climbed out, and jumped straight back in.** Out of the water, a zombie hunting someone
across the lake took the shortest path, and the shortest path swims. So: out, in, out again,
looping around the lake. The lake is now **one-way** in the nav mesh. `sm_navwater` (zps24_navdebug)
finds every connection from a dry area into an area in water (area center + 16 units inside a
water brush), and `sm_navwater apply` removes them; then `sm_nav_save`. Connections out of the water
and inside it stay, so swimming out still works. But no path from dry ground leads into a lake,
so zombies go around over land, to the doors and windows. Done on all four lake maps: 105-245
connections each. (Removing connections kicks every bot, so it's done on the test server, and
the main server picks up the saved mesh at the next map load.)

**Still looping.** Dry-to-water wasn't enough. The exit slope on zpo_lake_of_the_dead is one big
nav area from z 6 to 148 that counts as water, and it was linked to the rest of the lake. From
there the shortest path to almost anyone was to swim across and climb out on the far side. Now
`sm_navwater apply` removes **every** connection into a water area, from water too: water areas
only lead out, onto dry ground. In the lake there is no path anywhere but out, and the swim
logic steers to the way out (the teacher's route within 4000 units, else the nearest bank within
1500). It also starts when a zombie wades ankle deep in a lake area, not only waist deep.
Removed: 2300-5400 connections per lake map (the command handles 4096 per run, so run it again
until it reports 0).

**Ways out that lead nowhere.** With no connections into water, a strip of bank whose only
connections had gone into the lake became a dead end. Zombies climbed onto it, had no path, and
wandered back in. Now the plugin labels the **dry regions** (dry areas joined by connections
between dry areas, `LabelDry`), and a way out only counts if it leads into the region of the
survivor being hunted. A zombie stranded on a small dry region (under 60 areas) that isn't the
survivors' region goes back in and out again at a real way out. Other rules on the way:

- once a way out is picked, the zombie keeps heading there until it stands on dry ground there or
  time runs out (it used to re-pick on every tick and never commit);
- banks: aim at the middle of the bank's area, not the water's edge (from the edge NavBot still
  thought it was in the lake and slid back), and only banks at most 45 units above the zombie
  (climbable);
- a way out that fails is skipped for 40 s.

Still weak: on zpo_lake_of_the_dead most of the shore is too high to climb, and the teacher's
route is the only real way out. **Swimming out once as a zombie at other spots teaches more
ways out**; each learned route that starts in the water and ends on the survivors' land is used.

`sm_contents x y z` prints the brush contents at a point (`WATER` or not), to check what counts
as water.

`sm_zps24zombies_status` shows each zombie's `water` level (0 dry, 1 feet, 2 waist, 3 under).
So for any map with water: swim out once as the teacher, and the zombies copy it.

### 11.18 The cabin garage: wooden door first, then open the big doors from inside

The garage on zpo_cabin_outbreak has two big automatic doors (`garagedoor1/2`, func_door_rotating
that swing up). They can't be damaged (0 hp, no damage taken); a func_button just inside each
(`(521, -1125)` and `(194, -1125)`, a pair each) opens them. Their glass is 8 panes of 25 hp,
but only 14 units tall between solid slats, so even with every pane broken nobody fits through.
The small wooden side door at (894, -1155) is the way in (2000 hp at the bottom, a 1500 hp hinged
top).

The teacher's plan, and the bots' now: **break the wooden side door, then once inside press E on
the button to open the big doors** for the horde, then kill the survivors.

- After getting in (`UpdateEntry`'s "through"), and every 2 s for any zombie indoors, the zombie
  looks for a `func_button` within 600 units on its floor, indoors, with a **closed** door
  (`m_toggle_state` 1) within 300 units of it, that it can **see** (a trace from its eyes, so a
  zombie outside under the overhang doesn't press through the closed door), and that isn't part
  of a keypad (3+ buttons within 150 units, like the main house's code panel).
- It walks up to it (eyes within 64 units), aims at it and presses E again and again until the
  door is no longer closed, or 20 s pass. Only the real E: no reaching through walls.

**Still walking into the big doors.** Source's nav generator ignores doors, so the mesh runs
straight through the closed garage doors. Zombies under the garage's overhang counted as indoors
and skipped the entrance logic, and anyone seeing a survivor through the broken glass rushed
straight at them. Now:

- a **button-only door** (func_door / func_door_rotating with neither "Use opens" 256 nor "Touch
  opens" 1024, closed) that a zombie runs into, whether NavBot reports it on the path or the
  zombie gets stuck on it, switches that zombie to the entrance logic for 30 s, even under an
  overhang. It then goes to the wooden side door ("door 713 only opens from a button, finding
  another way in");
- such doors, and the glass set into them (panes parented to them), are never chosen as
  entrances;
- "close and in plain view: go straight for them" only when a body-sized trace reaches them
  (`WalkableStraight`), not through glass or a door.

**Still colliding, and the open wooden door ignored.** Two more causes. First, the nav mesh itself
ran through the closed garage doors (16 connections), so the shortest path to anyone inside the
garage went there, never round to the side door. `sm_navbuttondoors` (zps24_navdebug) finds
connections crossing a closed button-only door (areas on opposite sides of the door's plane,
meeting within its width and height), and `sm_navbuttondoors apply` removes them; the cabin mesh
is saved without them. When such a door opens (a zombie pressed the button), the zombie plugin
links the floor on both sides again at three points across its width (`RelinkOpenedButtonDoors`,
the floor found with a trace down from the hinge), so the horde walks in. Second, zombies
re-picked their target every 8-14 s, and one that had reached the open side door walked off
after someone else. Now a zombie keeps its target while it is getting into a building (heading
for an entrance, breaking it, going through, opening its doors).

**The wooden door was open and still ignored.** The nav mesh had no connection through it at all:
the garage floor ended at x 875, the outside at x 900. The door-linking code (`LinkDoors`) skipped
it for two reasons. The door entity is only the bottom half (55 units tall; the minimum was 70,
now 50). And the hinged top half above it looked like a plank barring it (`DoorBar`: a physics
object within 75 units), so a prop whose middle is above the door's top edge no longer counts as
a bar. Since then zombies come in through it.

**Open and Close buttons.** Each big door has two buttons 5 units apart: the upper one opens it,
the lower one closes it. The zombies pressed whichever was nearest, so one opened the door and
the next closed it. SourceMod can't list an entity's outputs, so `Doors_LoadButtons`
(`plugins/include/zps24_doors.inc`) reads the map's own .bsp entity lump at map start (it needs
a 4 MB heap, `#pragma dynamic`). For every func_button it records, by Hammer ID, whether
OnPressed opens (or toggles) a door or closes one, and which door. On cabin: 6 open, 3 close.

- **Zombies** only press Open buttons, only while that button's own door is closed. An open door
  is left alone until survivors close it. Once their door is open, they move on to the next
  closed door's button, if any, then the survivors (a zombie used to keep pressing because the
  other garage door, also near the button, was still closed).
- **Survivor bots close it**: when a button-worked door is open and no zombie is within 300 units
  of its Close button, the nearest free survivor bot (no job, not a builder, within 900 units,
  same floor) walks to the button and presses E until the door starts closing (state "closing a
  door"). It gives up if zombies get within 250 units of the button.

Tried and dropped along the way: ranking entrances by toughness (it turned zombies away from the
wooden door, which is the right way in here), and pressing the button through the broken glass
("they can't reach that button"). Kept: after one pane of a stacked window breaks, the zombie
smashes the next pane in the same column (`NextPane`) before trying to climb in.

### 11.19 The main house doors: physics doors held by planks

On zpo_cabin_outbreak every zombie went in through the windows; nobody used the main house's
front or back door. Why: both are **physics doors** (a door-shaped `func_physbox` on a
`phys_hinge`: "newhousedoor1" at the front (-548, -562), "newdoor" at the back (-557, 97)), held
shut by wooden plank physboxes: 2 x 1000 hp at the front, 1 x 2500 hp at the back. The entrance
logic only knows real doors (func_door, func_door_rotating, prop_door_rotating) and glass, and the
"climb in, then unbar a door from inside" routine (`StartUnbar`) only looked at real doors too.
For the zombies these doors didn't exist.

**The teacher's demonstration** (logged every 0.2 s: their position, view and buttons, and each
plank's and door's position, angle and health):

1. From outside, left click at the upper plank, aiming about 35 degrees up. After a few hits it
   jumps off its brackets and falls inside. It lost only 42 of 1000 hp: hits knock planks
   loose, they don't break them.
2. The lower plank can't really be reached from outside (a crouched right-click shove only
   nudged it).
3. Round to the window just south (-527, -624): break it, crouch-jump in.
4. From inside, left click the lower plank (about 10 hits) until it drops, then push the door:
   it swings open on its hinge.

**What the bots do now:** step 4. `StartUnbar` also considers physics doors (`IsPhysDoor`: a
func_physbox 36-70 wide, 70-130 tall, at most 12 thick). `DoorBar` skips the door itself (a
physics door isn't its own bar) and ignores planks lying on the floor (middle less than 15 units
above the door's bottom edge). Planks are brushes of material wood, so `IsWooden` says left
click. Once no plank is left, the zombie shoves the door outward (300 units/s) instead of the
"Open" input a real door gets, and it swings open for the horde.

**Then from outside too** (the teacher: "if no planks on door just bust it open and go in instead
of window"). Physics doors are entrances now, in `ChooseEntry`. One with no planks left ranks
ahead of windows (-350 against a window's -250): the zombie walks straight at it, shoving it
open as it goes (it isn't linked in the nav mesh), until it's through. One still planked ranks
like a window: at the door the zombie aims at the planks and left-clicks, each hit giving the
plank an inward knock (as the teacher's hits did). When `DoorBar` finds no plank left, it busts the
door open and walks in. 20 s without clearing them: the door counts as too tough for a while and
it takes a window. The house the survivors use on cabin has `frontdoorwhite` (68, -476) and
`backdoor` (801, -116), each held by two 1000 hp planks; the house to the west has
`newhousedoor1` and `newdoor`.

### 11.20 Why builders never got a board up, and roof edges

**The hammer waits for the game client.** Builders aimed where the teacher aimed, the game's own
`CanAttachBarricade` said a board fits there, they clicked (even with the click put straight
into their usercmd through `OnPlayerRunCmd`, one short click like the teacher's recording shows),
and still no board was used up. The hammer (`CWeapon_Barricade`) has network fields
`m_bIsSmallBoard` / `m_bIsSmallBoardObtained` / `m_bCanAttachBoard` / `m_bAttachBarricade`, and
its `ItemPostFrame` tests `m_bIsSmallBoardObtained` (offset 1705, `cmpb $0x0,0x6a9`). A real
player's client reports the board size and sets it; a bot has no client, so on the bots' hammers it
stayed 0 and the hammer never got ready. `HammerReady` sets it (large board) on every builder's
hammer. Also: if `CanAttachBarricade` says no board fits from where the builder stands (the
teacher may have stood on furniture), the builder sweeps its aim around the teacher's aim point
(up to 30 units up/down, 20 sideways) until one does; each attempt logs the boards carried
before and after.

**Roof and balcony edges.** Bots fell off backing away from zombies. `DropAlong` walks the line
to where the bot wants to go (and a step past it) in 16-unit steps, tracing the floor below; a
floor more than 64 units under our feet is a drop. Falling back never crosses one: the bot holds
there and shoots the zombies below ("holding the edge, shooting down"). Only when **surrounded**
(3+ zombies within 160 units) may it jump. Directions that end in a drop are skipped when looking
for somewhere to back off to, and defend spots within 40 units of an edge with no railing
(`AtEdge`: nothing solid at step height, then a drop) are left out unless the teacher held them.

## 12. The Windows port

The same bots for a ZPS 2.4 dedicated server on **Windows**, in a second repo,
[zps24-bots-windows](https://github.com/DiogenesBipedal/zps24-bots-windows) (this repo is its
`core` submodule, so the plugins and patches stay in one place). Done in one night. Three jobs:
build the native code for Windows, find everything the gamedata names in a DLL with no
symbols, and test without a Windows PC.

### 12.1 Building with MSVC without Windows

Metamod:Source and NavBot are C++ and must be compiled with Microsoft's compiler to load into
a Windows `srcds.exe`. Instead of cross-compiling, a **GitHub Actions** workflow runs on a
Windows runner: same pinned versions, same patches, `configure.py --targets=x86`, `ambuild`.
NavBot's own CI already builds for Windows, so this was mostly copying its steps.

**The one failure:** `[WinError 206] The filename or extension is too long`, at the very end.
Everything compiled; the link failed. AMBuild names object files after their full source path,
NavBot has hundreds of files, and the linker command passed Windows' command line limit.
Building under `C:\w` instead of the default deep workspace path fixed it.

### 12.2 Vtable offsets without symbols: compute them

45 gamedata entries are vtable slots (see chapter 3). On Linux the tools read them by name. The
Windows `server.dll` has no names, but there are rules for how the two compilers differ:

1. **Destructors:** Itanium (Linux) has two vtable slots for a virtual destructor, MSVC one.
2. **Overloads:** MSVC puts all the overloads of a function name that one class declares
   together, at the first one's position, in **reverse** declaration order. Itanium keeps
   declaration order.

Everything else is the same: declaration order, base class first. So
`tools/msvc_layout.py` takes the Linux vtable (names and all), splits it into the part each
class in the chain adds (the chain comes from Linux RTTI: each `_ZTI` typeinfo points at its
base class's), applies the two rules inside each part, and gets a Windows index for every
Linux one. Most come out as "Linux minus one", but not all: `CommitSuicide` stays at 405 because
its two overloads swap places on Windows.

**How do we know it's right?** MSVC keeps RTTI in the DLL even without symbols:
- a **type descriptor** containing the decorated name, like `.?AVCHL2MP_Player@@`;
- a **complete object locator** pointing at it;
- the word just before a class's vtable points at that locator.

`tools/win_vtable.py` follows that chain and reads the real Windows vtables. For every class
used, the computed number of slots equals the real number exactly (477 for the player class,
363 for weapons, 184 for the game rules...). An off-by-one in the rules would have broken
that.

**When two methods disagreed.** A second method compared "fingerprints" of functions
(constants, struct offsets, strings) between Linux and Windows. It disagreed with the
computation 7 times. Reading the machine code side by side (`tools/side.py`) settled each one,
always in favour of the computation:
- `Think()` calls a stored member function pointer. Linux reads it at offset `0xc`, Windows
  at `+8`: on Linux a pointer to member function is 8 bytes, on MSVC 4, so field offsets
  differ while their *order* doesn't. The second pointer field is `m_pfnThink` on both; the
  fingerprint had matched the slot that reads the first one (`MoveDone`).
- `ProcessUsercmds` (how bots move) walks the commands `0x54` bytes apart, which also confirms
  ZPS 2.4's 84-byte `CUserCmd` (chapter 7.7) on Windows.

The lesson: when there are known rules, compute and verify; use similarity only as a hint.

### 12.3 Signatures: find functions by what they do

Four entries name non-virtual functions. Each was found from behaviour, then turned into a
unique byte pattern with `tools/makesig.py` (copy the function's first bytes, wildcard call
targets and absolute addresses, add instructions until exactly one match):

- **`gEntList`** (SourceMod's entity list): SourceMod reads it from an instruction inside
  `LevelShutdown` (`mov ecx, offset gEntList`) using a signature from its own gamedata for
  other 2007 mods. That signature matched twice in ZPS's DLL; extended until unique. It also
  had to go into our custom gamedata, because SourceMod's entry only applies to the mods it
  lists. Without it: "NULL g_EntList", and NavBot refused to load.
- **`FireOutput`**: a signature from another mod's gamedata matched once; the function prints
  `(%0.2f) output: (%s,%s) -> ...`, which is exactly `CBaseEntityOutput::FireOutput`.
- **`LookupAttachment`**: the function the game calls right after pushing an attachment name
  (`"eyes"`, `"anim_attachment_RH"`), 12 call sites. Its body matches Linux: model,
  `Studio_FindAttachment()`, `+ 1`.
- **`CanAttachBarricade`**: not in the DLL at all. Nothing in the game calls it (on Linux it
  exists only because every symbol is exported), and MSVC's linker removes unreferenced
  functions. The survivor plugin now treats it as optional.

### 12.4 Testing under Wine

`srcds.exe` runs under Wine. `scripts/wine-server.sh` starts the Windows server on port 27025
next to the Linux one. What came up, in order:
1. Metamod and SourceMod loaded; NavBot didn't: no entity list (fixed in 12.3).
2. Then everything loaded: nav mesh, 23 bots, survivor and zombie AI, and the lessons
   learned on Linux (the data files are the same on both platforms).
3. A clean install from the CI-built release zip, replaying the installer's steps, gave the
   same result. Then a 20-minute soak: rounds, map changes, no crashes.

### 12.5 Shipping it

The CI also compiles the plugins with SourceMod's Windows compiler and packs a release zip:
binaries, gamedata, plugins, configs, nav meshes for the bot maps, and an installer
(`install.ps1` behind a double-clickable `install.bat`). The installer gets SteamCMD and the
2.4 server, SourceMod, copies the maps from the player's ZPS 2.4 game, sets up admin by LAN IP,
a firewall rule and `start-server.bat`. Updating keeps the user's configs and nav meshes.

**Lessons.**
- Look for an existing build pipeline to copy (NavBot's CI) before inventing a toolchain.
- In a stripped binary, RTTI is a map: class names lead to vtables.
- Rules plus a check (the vtable lengths) beat guessing; reading the code settles the rest.
- An unused function can simply not exist on the other platform. Make such dependencies
  optional.

---

## 13. The tricks, collected

**Reverse engineering**
1. `file` first. "Not stripped" means you get names for everything.
2. Map a class's virtual functions by dumping `_ZTV<len><Class>` and resolving relocations.
3. Translate offsets between versions by function name, never by guessing.
4. Find a struct's size from `imul reg, reg, SIZE` where arrays of it are indexed.
5. Find a struct's layout from the offsets a "read/serialize" function writes.
6. Read a function's imports (its relocations) before its assembly.
7. Turn a virtual address into a file offset with the program headers, to read constants like strings.
8. Big unsigned numbers near 2^32 are small negative numbers.

**Debugging**
9. Get a backtrace before forming theories.
10. Interrupt a "hung" program to see where it really is; it may just be idle.
11. If ptrace attach is blocked, start the program under gdb.
12. For stack smashes, break at the start of the damaging call with a conditional breakpoint.
13. Use `LD_DEBUG=files` to see which libraries load.
14. Bisect versions: newest working vs. oldest broken.
15. Swap halves (old loader + new core) to find which half is broken.

**Building and patching**
16. Reproduce the official toolchain (containers are great for this) before changing anything.
17. Keep changes as patches against pinned upstream commits.
18. Preserve line endings when editing files programmatically.
19. Prefer gamedata keys over hardcoding game-specific behavior.

**Automation**
20. Drive servers with RCON; it works anywhere, even under a debugger.
20b. Test networking with a hand-made query packet before blaming the client.
21. Write tiny probe plugins to observe game state from a terminal.
22. Never `pkill -f` a pattern that appears in your own command line.

**Bot behavior**
23. Pick goals by what the bot can reach or see, not by straight-line distance.
24. Check an entity's properties (material, health, flags), not just its class name.
25. When bots can't get somewhere, dump the nav mesh before touching code.
26. After changing generation settings, measure reachability across the whole map.
27. If the pathfinder can't express a route, steer the bot yourself (`MoveTowards`) and hand it
    back to the pathfinder at the end.
28. Let bots use the player's controls (`use weapon_emptyhand`, attack 2) and the game's own
    physics, instead of moving things for them.
29. Track progress toward the goal, not the number of attempts, and blacklist what doesn't move.
30. Put "never do X" rules in the one check every action goes through (here, `ClearShot()`).
31. Give the AI a "what am I doing" readout (`sm_zps24ai_bots`) before debugging behavior.
32. To teach bots, record the moments that matter from one trusted player, and keep it as
    editable text.

**Porting**
33. Windows vtable index = Linux index after MSVC's rules (one destructor slot, overloads grouped
    and reversed per class); verify with the vtable lengths from RTTI.
34. Find a stripped function by what it does: its strings, its callers, its arguments.
35. Build Windows binaries on a CI Windows runner; keep build paths short.

---

## 14. Exercises

Each builds on something in this repo.

1. **Read a vtable.** Run `tools/vtable.py ~/zps24-server/zps/bin/server_i486.so CBaseCombatWeapon`.
   Find `PrimaryAttack` and `Reload`. Then do the same for the 3.x binary
   (`~/.local/share/zps-versions/zps3/zps/bin/server.so`) and explain why the numbers differ.
2. **Demangle by hand.** Decode `_ZN11CBasePlayer15ProcessUsercmdsEP8CUserCmdiiib` without
   `c++filt`, then check your answer with it.
3. **Measure a struct.** Find the size of `CTakeDamageInfo` in 2.4 the way section 7.7 did.
4. **Extend the probe.** Make `zps24_botprobe.sp` also print each bot's ammo, using
   `GetEntProp(client, Prop_Send, "m_iAmmo", _, index)`.
5. **A new hook.** In NavBot, add a gamedata key that makes bots announce themselves in chat on
   spawn. (Hint: hook `Spawn`, slot 22 in 2.4, using the SDK Hooks offset in our gamedata.)
6. **Find the next bug.** Run the bot server for an hour with `sm_botprobe_interval 30`. If it
   crashes, use the techniques from section 7 to find out why.

---

## 15. Glossary

| Term | Meaning |
|---|---|
| ABI | Application Binary Interface: the rules for how compiled code lays out data and calls functions. |
| AMBuild | AlliedModders' Python build system. |
| Backtrace | The chain of function calls that led to the current point. |
| `CUserCmd` | One tick of player input: view angles, movement, buttons. |
| Edict | The engine's handle for a networked entity. Players are edicts 1 to maxplayers. |
| ELF | The executable file format on Linux. |
| `ep2` / `orangebox` | The Source engine branch from 2007, used by ZPS 2.4. |
| Extension | A native C++ SourceMod module, like NavBot. |
| Factory | A library's `CreateInterface` function. |
| Gamedata | Text files with per-game offsets, signatures and settings. |
| Interface | A versioned C++ class of virtual functions shared between libraries. |
| Itanium ABI | The C++ ABI used by GCC and Clang on Linux. |
| Listen server | A server hosted from inside the game, as opposed to a dedicated server. |
| Mangling | Encoding C++ names and types into symbol names. |
| Dead end | Here: a goal area a zombie reached without being able to see its target; avoided for 20 s. |
| Hold-out | The building survivor bots choose to defend. |
| Complete object locator | MSVC RTTI record that sits just before a vtable and leads to the class's name. |
| MSVC | Microsoft's C++ compiler; Windows builds of Source games and plugins use it. |
| `MoveTowards` | NavBot native that walks a bot straight at a point, with no pathfinding. |
| Learning from demonstration | Teaching an AI by recording what a skilled player does and reusing it. |
| Home | The house a survivor bot defends: the doors and windows around where it spawned. |
| Nav island | Nav areas with no connection to the rest of the mesh; a search started there finds almost nothing. |
| Nav mesh | A map of walkable areas that bots use to find paths. |
| Punt | Source's word for shoving a physics object; ZPS's bare hands do it on right click. |
| Scripted plugin command | NavBot task that calls a plugin function every update to get the bot's move goal. |
| Stair route | A hand-made list of points that walks bots up a staircase the nav mesh doesn't cover. |
| Offset | Here: a vtable slot number. |
| Relocation | A note telling the loader to patch an address at load time. |
| RCON | Source's remote console protocol over TCP. |
| SourceHook | Metamod's library for hooking virtual functions. |
| SourcePawn | SourceMod's scripting language. |
| Stripped | A binary whose symbol names were removed. |
| Symbol | A named function or variable in a binary. |
| vptr / vtable | The hidden pointer in each object, and the table of virtual function pointers it points to. |
