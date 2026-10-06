# Porting NavBot to Zombie Panic! Source 2.4: a hands-on manual

This manual explains how the bots in this repo were made to work on ZPS 2.4, and teaches the
techniques along the way. It is written for someone who knows a little programming and wants to
learn how Source engine modding, reverse engineering and low-level debugging actually work.

One clarification first: almost all of this is **C++**, not C. Source, Metamod, SourceMod and
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
11. [The tricks, collected](#11-the-tricks-collected)
12. [Exercises](#12-exercises)
13. [Glossary](#13-glossary)

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

## 11. The tricks, collected

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

---

## 12. Exercises

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

## 13. Glossary

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
| Nav mesh | A map of walkable areas that bots use to find paths. |
| Offset | Here: a vtable slot number. |
| Relocation | A note telling the loader to patch an address at load time. |
| RCON | Source's remote console protocol over TCP. |
| SourceHook | Metamod's library for hooking virtual functions. |
| SourcePawn | SourceMod's scripting language. |
| Stripped | A binary whose symbol names were removed. |
| Symbol | A named function or variable in a binary. |
| vptr / vtable | The hidden pointer in each object, and the table of virtual function pointers it points to. |
