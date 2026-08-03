# Local splitscreen on the PC build

A [CrabeLoader](https://github.com/LucasLhomme/CrabeLoader) mod — requires
it installed and running. See this repo's `README.md` for setup.

Disney Infinity 3.0 shipped local 2-player splitscreen on consoles, where the
second player joined by placing a second figure on the physical portal. The PC
port has no way to do it from the UI. This documents how far the engine still
supports it, exactly where the wiring was cut, and how to pick the work back up.

> **Splitscreen works. Player 2 has no character yet — not playable.**
>
> One call: **`Crabe.Splitscreen.enable(1)`**, in-game, with a second
> controller connected.
>
> Confirmed live and stable:
> ```
> valid1=true   nLocal=2   vSplit=true   onReader1=true   lock1=1
> ```
> - the screen splits vertically (screenshot)
> - the engine holds a real second player slot, with its own viewport
> - the second pad's input is routed to player 2 — confirmed by a human, who
>   used it to operate an on-screen popup
> - it persists: no `MissingAvatar`, no `PlayerDropout` over two minutes
>
> **What is still missing**: player 2 has **no character in the world**.
> Nothing is visible in their half of the screen and there is nothing to move.
> Do not trust `UI_IsAvatarAlive(1)` / `UI_GetAvatarSKU(1)` here — neither
> takes a player index, and both were misread as evidence of a character.
>
> The message log says exactly where it stops. Player 1 runs the full avatar
> lifecycle, player 2 stops after the first step:
>
> ```
> player 1: AvatarCreated -> AvatarLevelingReset -> AvatarReady
>           -> AvatarCreationComplete -> AvatarSpawnChoFinished
> player 2: AvatarCreated -> (nothing) -> AvatarRemoved
> ```
>
> So the avatar object is constructed but never initialised or spawned. That
> gap is the next thing to close, and it is a concrete, narrow target.
>
> ### The three things that made it work
>
> 1. **Force one byte.** `[g_gamePlayers+0x98] = 1` clears bit 1 of
>    `DropInCheck`'s refusal mask.
> 2. **Call the handler nobody calls.** `GameStandAloneLoop::OnDropInRequest`
>    (RVA `0x69E480`) — intact in the PC binary, never dispatched to.
> 3. **Assign the avatar one tick later, then keep re-asserting it.** This is
>    the part that took longest to see, and it is two separate timing traps:
>    - `ReaderMgr::ForceAvatar` resolves the reader slot via
>      `sub_2CAA0(playerIndex)`, which returns `-1` until player 2 has
>      propagated — and `-1` is coerced to `0`, so an immediate call writes the
>      avatar into **player 1's** slot. It must wait a few ticks.
>    - Closing the "Figurine Disney Infinity manquante" popup makes the engine
>      re-check the reader and run `MissingAvatar` → `PlayerDropout` →
>      `AvatarRemoved`. **The popup was never the obstacle — it was holding
>      player 2 up.** Re-asserting the avatar each tick is what stands in for
>      the physical portal.
>
> Every earlier "it got dropped again" was one of those two, not a new lock.
>
> ### The trap that damages player 1 — read before touching the avatar natives
>
> `Players_ForceAvatar` / `Players_ChangeAvatar` take a **player id**, resolved
> through `sub_2CAA0(id)`:
>
> ```
> id == GetPrimaryPlayerId()  -> slot 0   (player 1)
> id == GetSecondPlayerId()   -> slot 1   (player 2)
> anything else               -> -1, and the caller coerces -1 to 0
> ```
>
> The ids happen to be `0` and `1`, so `Players_ForceAvatar(1, sku)` looks like
> it means "player 2" and usually does. **But when player 2 does not exist,
> `GetSecondPlayerId()` returns -1, no branch matches, and the write lands on
> player 1** — silently replacing the first player's character mid-game.
> Observed live: the user's own character was swapped this way, and the message
> log shows `AvatarCreated(0, …)` where index 1 had been requested.
>
> So it is never enough to check `Players_IsValid(1)`. Ask the same question
> the native asks — `Crabe.Splitscreen.secondPlayerId()`, which returns the id
> only when a second player genuinely exists — and skip the write otherwise.
> `setCharacter()` and the tick loop both do this; a bare
> `Players_ForceAvatar(1, …)` is unsafe by construction.
>
> Two results from that, one settled and one open:
>
> - **Settled**: the engine reconfigures rendering *by itself* once player 2
>   exists. The viewport/container question this document carried for several
>   sessions needed no answer at all.
> - **Open**: player 2 is dropped again after a few seconds. The game shows
>   "Figurine Disney Infinity manquante" and then runs `MissingAvatarDropout`,
>   because `UI_IsAvatarOnReader(1)` is false — the *reader* never gains a
>   second figure, even though `Players_ChangeAvatar(1, sku)` is accepted and
>   echoes the sku back. Player and reader are two different pieces of state.
>
> See "The reader wall" below for why that is the hard part, and the two ways
> around it. The sections after it are the investigation that got here, kept
> because the addresses and the reasoning are what make this reproducible.

**Status (historical, pre-breakthrough): the missing piece is named.** The refusal check
has been found, disassembled, and flipped (forcing one byte makes it return
"allowed", live, with a screenshot proving the game's own "place a figure for
player 2" prompt is real and reachable). The handler that *should* call it has
since been identified too: **`GameStandAloneLoop::OnDropInRequest`**, RVA
`0x69E480` — fully intact in the PC binary, GameLoop.cpp strings and all, with
two of its four gates stubbed out to always pass. Nothing dispatches to it.
That is the cut cable.

Calling it by hand is the next experiment and has **not been run with a level
loaded yet** — the attempt from the main menu faulted on a null global (gate
4), which is itself documented below. Making splitscreen work still means the
loader becomes the missing caller. Below is the map so none of this has to be
re-discovered.

## `DropInCheck`'s refusal mask, decoded

The `DropInBlocked(mask, 0)` message carries a bitmask built at RVA
`0xFA41D8`–`0xFA4220`. Two bits are understood:

| bit | value | condition |
|---|---|---|
| 0 | 1 | an internal flag is set |
| 1 | 2 | `[g_gamePlayers+0x98] == 0` — **the one `forceDropInAllowed()` clears** |
| 2 | 4 | a `GameFrontEndLayer` check returns 0 (below) |

**Bit 2 is what blocks reproduction now.** It comes from a virtual call on
`[0x2289E88]`, which RTTI identifies as **`GameFrontEndLayer`** — vtable slot
`+0x98` (RVA `0x73E5D0`), which in turn calls slot `+0x94` (RVA `0x742150`).

That function has three exits, and only the last one is a flag:

```
if (sub_114FB40(playerIndex))            return 1;   // -> blocks
if (sub_1151200(frontEnd, playerIndex) != -1) return 1;   // a screen is open for this player -> blocks
if (sub_8472C0())                                       // the `mov al,1; ret` stub -- always true
    return ([frontEnd+0xD4C] >> playerIndex) & 1;
```

`0xD4C` is a per-player bitmask and **is** writable — but clearing it (tested
live: `0x1` -> `0x0`) does **not** lift the refusal, because one of the two
earlier exits fires first. The most likely one is the screen check: the caller
at `0x73E5D0` also special-cases the screens `IGP_Popup` and
`MBA_Versus_Hub`, treating "a popup is up" as *permission to drop in*. That
inverted-looking logic is consistent with the one run that did work — the
successful call happened in a screen state that has not been reproduced since.

**Next step here**: identify `sub_1151200` (which screen it reports for a
player) and `sub_114FB40`, rather than forcing more bytes. This is a state
problem, not a flag problem.

## The avatar spawn function (found, not yet tried)

All four messages missing for player 2 are dispatched, in order, by a single
function:

**RVA `0x9EA280`** — a `ReaderMgr` method, `__thiscall`, **no arguments**
(so `_callThis0`). Its `this` is the reader manager at image address
`0x213E27C` — the same object `Players_ForceAvatar` ends up on, which is how
it was identified: both reach `0x9D19E0` with `ecx = this`.

Its tail is unmistakable — four `0x28BBB0` dispatches back to back:

```
"CreationComplete" -> "AvatarReady" -> "AvatarCreationComplete"
  -> "AvatarSpawnChoFinished"
```

Before them, three guards skip the whole thing:

```
0x9EA49B  cmp ebx, -1        ; unrecognised player slot -> skip everything
0x9EA4A4  cmp [esp+0x1c], 0  ; -> skip
0x9EA4C3  (result of 0xEBF72C) == 0 -> skip
```

`ebx == -1` is the same sentinel `sub_2CAA0` returns for a player it does not
recognise — the exact failure mode that already bit us once on the avatar
natives. The real work in between calls `0x9AB3C0`, then `0x9D19E0` (the
reader-slot writer), then polls `0x9C0750` up to 10000 times waiting for
something to become ready, which reads like waiting on the character's assets.

It works from **`[readerMgr+0xA10]`**, and in the shipped build its only
caller (`0x9F2DB0`) is gated behind an `"Intro"` check — which would explain
why it never runs for a drop-in.

What `[readerMgr+0xA10]` actually *is* remains unconfirmed. It is fed both to
a zone-manager lookup (`"OverrideInitialCreation"`) and to the reader-slot
writer, and it reads back as **1281** at the main menu — neither a player id
nor an obvious index. Sample it in-game, with and without a second player,
before assuming it selects the player.

Exposed as `Crabe.Splitscreen.spawnAvatar()`. **Not called automatically** — it
writes engine state, so a bad result means reload the level rather than retry.

### Tested — it works, but it targets player 1

Called live with player 2 present, it ran the **full lifecycle** … for index 0:

```
AvatarCreated(0, …) -> AvatarReady(0, …) -> AvatarLevelingReset(0, …)
  -> AvatarCreationComplete(0, …) -> AvatarSpawnChoFinished(0, …)
```

So the function does exactly what is missing — it just does it for the wrong
player. Player 2 stayed `valid/alive/split=true` throughout; nothing broke.

**`[readerMgr+0xA10]` is not the player selector.** Writing `1` into it and
re-running produced the same index-0 lifecycle (original value restored
afterwards). Ruled out.

### What the function actually is

It is a loop over the reader's **two** slots, fully decoded:

```
ebp = 0x50 ; ebp += 8 ; while ebp < 0x60      -> exactly 2 iterations (edi = 0, 1)
slot pointer starts at readerMgr+0x60, += 4   -> the array ForceAvatar writes
per slot: strcmp([slot + 0x94c], "None") != 0 -> skip this slot
```

so player 2 *is* iterated. The names live at `readerMgr+0x9AC + i*4` (the two
strings `0x9D1F00` also touches). Read live, both slots were **empty strings**,
and both `[readerMgr+0x60+i*4]` entries were **0** — so neither matches
`"None"` and the loop skips both. Player 1's avatar was therefore spawned by
the *other* branch, selected by `[readerMgr+0x88C]` (read live: `0`).

The code past the check builds `DefaultProxyAvatar` / `_ProxyAvatar`, so this
loop looks like "give empty slots a placeholder character" rather than "spawn
the real one" — worth keeping in mind before trying to force its condition.

**Resolved**: `UI_IsAvatarOnReader(1)` returns true while `[readerMgr+0x60+4]`
is 0 because it doesn't read that array at all. Its handler delegates to
`sub_2CBC0(readerMgr, playerId)` → `sub_2CAA0` (slot resolve) →
`sub_28500(slot)`, which compares an **8-byte tag** at
`[ptrA + slot*8 + 0x50]` against the same offset in `[ptrB]`, where
`ptrA = [readerMgr+8]` and `ptrB = [readerMgr+0xC]` — two *different* pointers
from `[readerMgr+0x60]`. Read live: player 1's slot holds `[1000100, 0]` in
both (real data, matches); player 2's holds `[0, 0]` in both — **equal because
both are empty**, so the check trivially passes. This is a real, reproducible
false positive: `onReader=true` proves nothing about player 2 having a
character.

## The real per-player spawn function (found, one live test, caused a regression — do not call blindly)

`sub_9EA280` turned out to be a dead end for this: its per-slot loop (the one
matching slot names against `"None"`) and its message-dispatch tail are two
*unrelated* code paths in the same function. The dispatch tail is
unconditional and appears hardcoded to whatever `esi` (the reader manager)
considers "the" avatar — not slot-selectable. Confirmed by forcing player 1's
slot to look occupied and player 2's to read `"None"` (a single reversible
pointer write, restored immediately): the lifecycle still fired for index 0.
The proxy-avatar loop it guards doesn't dispatch `AvatarCreated` at all — it
calls into a different subsystem (`0x2CB10`, `0x92E20`, `0x346FE0`), so it was
never going to work for this.

**The actual dispatcher for `AvatarCreated` was found by searching for the one
real call site**, not registration sites — of the ~10 references to the
string, only **one** (`RVA 0xFACEA1`) is inside a `call 0x28BBB0` (the message
dispatcher `MessageHook` hooks); the rest are `RegisterHandler`-shaped
listener registrations. The function containing it, `sub_FACC10`
(`__thiscall`, `this, arg1, arg2, arg3`, `ret 0xC`), uses `arg1` throughout as
a player-index array subscript (`[this+0x108] + arg1*0x50`) and converges on
`sub_F99390` — the same helper `ReaderMgr::ForceAvatar` calls. It has exactly
one caller: **`sub_68D680`**, which has zero direct callers itself — a virtual
method. Its vtable resolves via RTTI to **`GamePlayers`**, slot index 7 (RVA
`0x18D6390` relative to the vtable at `0x18D6374`). `GamePlayers` is the
*same* singleton `DropInCheck` already uses (`S.gamePlayersSingleton()`).
`sub_68D680` guards `arg1 == -1` (skip), matching the usual invalid-slot
sentinel, and forwards `(arg1, arg2, arg3)` straight into `sub_FACC10`.

So: `Crabe._callThis(base + 0x68D680, gamePlayersSingleton(), playerIndex, 0, 0)`
is structurally the right call — correct object, correct function, correct
arity (`__thiscall`, 3 stack args → `_callThis`, not `_callThis1`).

**One live test was run, with `playerIndex = secondPlayerId() = 1`.** Result:
no crash, but a **regression** — `UI_IsGamePlayVerticalSplit` went from
`true` to `false`, `PlayerDisconnected(0, …)` fired (player **1**, not 2), and
only `MissingAvatar` followed — no `AvatarCreated` at all. Recovered cleanly
by re-running `Crabe.Splitscreen.enable(1)`, back to the known-stable
`valid=true, split=true, alive=false` baseline.

**Conclusion: `playerIndex` here is not simply "0 or 1 the way `secondPlayerId()`
reports it."** Something about `sub_FACC10`'s early gates (the
`"PlayerControllable"`/`"ActorType"` lookup, or the `[this+0x108+idx*0x50+0x48]`
check before it ever reaches the dispatch) reads player/viewport bookkeeping
that this call disturbed — plausibly the same array `GetViewportCount` and
`Display_GetViewportIDFromPlayerID` read, given the visible symptom was a lost
split rather than a spawn.

**This chain is real and is the correct direction**, but is not yet safe to
call again blindly. Deliberately **not exposed as a mod function** — the
existing `spawnAvatar()`/`avatarSpawnTarget()` wrappers stay as documented
dead ends, and this new lead is here in prose only until it's safe to wrap.

### Root cause of the regression, found by reading (not calling) — `arg1` was right, `arg2` was not

A read-only live probe of `[gamePlayers+0x108]` (no call, no write) settles
what `arg1` means: it **is** a plain player-slot index after all. Both
player 0 and player 1 have live, valid-looking entries there
(`+0x10 == 1` for both, matching `Players_IsValid(0)`/`Players_IsValid(1)`
both being true) — so passing `secondPlayerId()` as `arg1` was structurally
correct, contrary to what the regression suggested.

The field that differs is `+0x48`: player 0 has a real pointer-like value
there (`0x880070D0` — presumably a handle to their current character
template); **player 1's is `0`** — no character assigned, which is exactly
the symptom being chased.

Tracing `sub_FACC10` against this: it calls `sub_34B200(arg2)` once near the
top, and later `sub_34B200([this+0x108 + arg1*0x50 + 0x48])` (the same field
just read). If the two results are **equal**, the function concludes "this
player already has the requested type" and returns `false` immediately,
*before* the code that dispatches `AvatarCreated`. The test that regressed
things passed `arg2 = 0`. `sub_34B200(0)` and `sub_34B200(player 1's 0)`
compare equal — both resolve whatever "null" means to the same value — so the
function bailed out silently. **No `AvatarCreated` fired in that test, which
matches this exactly.**

So `arg2` is not a free "pass zero" parameter — it needs to be whatever
`sub_34B200` produces for a *real* character template, e.g. derived from
Captain America's sku (`1000100`), not a literal `0`. What `sub_34B200`
actually takes as input (a sku directly? a resolved actor-type handle, the
way `+0x48` stores one for player 0?) is the one remaining unknown — and the
next thing to read (not call) before trying this live again: dump
`sub_34B200`'s disassembly, and read what player 0's `+0x48` handle actually
points to (its first few fields), to learn what shape of value it expects.

The regression's other symptom — the lost split and `PlayerDisconnected(0,…)`
— is very likely a side effect of `sub_68D680` (the caller) rather than of
`sub_FACC10` itself; that function does other bookkeeping after the call this
document hasn't traced yet. Worth confirming once `arg2` is right and the
call can be judged on whether `AvatarCreated` fires, rather than worked around
blind.

**Update, later in the same session**: retried with `arg2 = 1000100` (Captain
America's sku, the obvious real-value guess). No regression this time
(`split` stayed `true`, player 1 untouched) — but also no `AvatarCreated`,
`call` still returned `false`, same silent-bail signature as `arg2 = 0`. So a
raw sku is not what `sub_34B200` expects either, and the first test's
regression looks like it was **not reliably caused by this call at all** —
same inputs pattern (arg1/arg3 identical), same bail path, no repeat of the
disconnect. Treat the first regression as unexplained/possibly coincidental
rather than a proven consequence of calling `sub_68D680`.

Tried to pin down `sub_34B200`'s expected input directly, in isolation:
`__cdecl`, one stack argument, does not touch `ecx` (confirmed by reading its
disassembly — no `this` used anywhere), so it's callable through
`_callThis1(addr, 0, value)` with a throwaway "this" since the thiscall
wrapper's stack layout happens to line up with what `sub_34B200` reads. Tried
`value = 1000100` and `value = 0` **on their own, uncalled from the rest of
the chain** — both **faulted** (SEH-caught, no crash). So it is not safely
callable in isolation the way its disassembly suggested; it likely depends on
engine state (thread-local data, a table that's only valid mid-call from its
real caller, or similar) that a bare standalone call doesn't set up. This
avenue is now closed for further isolated probing — any future attempt should
call the whole chain from `sub_68D680` down, varying `arg2`, rather than
`sub_34B200` alone.

**State after all of this**: confirmed stable —
`valid0=true valid1=true split=true ctrl=1 vp=1`. No corruption, no crash,
across every experiment in this section.

## Session 3: Cheat Engine breakpoints pin down `sub_34B200`, and a Lua dead end

This session used the CE bridge's `set_breakpoint(capture_registers=True,
capture_stack=True)` to watch the real, legitimate call path live — a much
stronger technique than guessing arguments — and cross-referenced the game's
own decompiled Lua (`decompiled/avatarselect.lua`,
`decompiled/virtualreader_in3.lua`, already extracted in a prior session's
scratchpad) to confirm `Players_ForceAvatar`+`Players_ChangeAvatar` is
genuinely the API the game itself uses (`virtualreader_in3.lua:1040-1041`) —
ruling out "wrong Lua API" as the cause. `AvatarSelect.lua`'s `SwapPlayer`
native, the other candidate, **does not exist in the PC binary**
(`Crabe._findString("SwapPlayer")` → false) — cut, like
`System_InGameStartButtonPushed`.

### `arg2`'s real nature, confirmed by breakpoint on `sub_FACC10`'s entry

Setting a breakpoint at RVA `0xFACC10` (live `0x01CFCC10` this session) and
triggering **real, visually-confirmed** avatar switches for player 0 (Iron
Man, Thor — captured live, `EDX` at entry = `arg2`) gives the actual values
the engine uses:

| switch | captured `arg2` (EDX) |
|---|---|
| player 0 → Iron Man (sku 1000101) | `0x5000709D` |
| player 0 → Thor (sku 1000104) | `0x5C007027` |

Neither resembles a raw sku (`1000101`/`1000104` in hex are `0xF4365`/
`0xF4368` — nothing like the captured values). **`arg2` is a resolved
handle, not a sku.** The function fires **once per unique sku per session**
(confirmed: repeating an already-switched-to sku produces zero hits — a
caching layer, not a bug in the observation).

### Reusing a captured handle for player 2 — still fails, and now precisely localised

Passed Thor's captured handle (`0x5C007027`) as `arg2` in
`Crabe._callThis(base+0x68D680, gamePlayers, secondPlayerId(), 0x5C007027, 0)`.
Confirmed via breakpoint that the call **does** reach `sub_FACC10` with the
exact intended arguments (`EDI=1`, `EDX=0x5C007027`, `ECX=gamePlayers`) — the
call mechanics are not the problem. But breakpoints at each of `sub_FACC10`'s
internal branch points show it bails at the **very first** one:

```
RVA 0xFACC50  test ebx,ebx     <- ebx = result of sub_34B200(arg2)
```

`EBX = 0` both times tried — for the reused handle **and** for the raw sku
(`1000104`) tried the same way. So `sub_34B200`, called with either a
previously-resolved handle or a bare sku, returns 0 (not found) in both
cases. A direct, standalone call to `sub_34B200` alone (outside `sub_FACC10`)
also **faults** (see the "root cause" note above) — it depends on context a
bare call doesn't provide.

**Working hypothesis, not yet tested**: the handle `sub_FACC10` receives is
likely **frame-transient** — resolved fresh by `Players_ChangeAvatar`'s own
call chain immediately before invoking `GamePlayers::vtable[7]`, in the same
call stack, same frame. Every live test so far has round-tripped through the
Lua console (`crabe_remote_cmd.txt`), which costs multiple **seconds** between
capturing a handle and reusing it — while a frame is ~16 ms. If the handle (or
whatever `sub_34B200` looks it up by) only lives for one frame or one call
stack, no amount of console round-tripping could ever reuse it correctly,
regardless of which value is chosen. This has not been falsified or confirmed
— it would require resolving and calling within the same tick, in C++
(`Game.onTick` in the loader already provides this), not from the console.

### A second internal API, traced and ruled out as unrelated

`Players_ChangeAvatar`'s own handler chain (`sub_773060` → `sub_762750`) was
fully traced this session, initially suspecting it held the missing piece.
It doesn't: `sub_762750` gates on an unrelated check (resolves a scene node
named **`"Center_Mover6"`** — a camera/rig anchor, not a UI screen despite an
"IGP_" string red herring nearby — then validates it via `sub_1213A40`, which
returned false in every test). Its gated final step, `0xB44DD0`, calls
`0x7923C0`/`0x800F90` — **neither leads to `GamePlayers::vtable[7]` or
`sub_FACC10`**. This confirms `Players_ChangeAvatar`'s internal gate is a
separate mechanism (plausibly a visual model-swap effect for an
*already-existing* avatar) and is not the path to creating one. Spent real
effort tracing this before ruling it out — recorded so it isn't retraced.

### State: stable throughout

Every experiment this session, including four simultaneous hardware
breakpoints, left the game in the same stable baseline:
`valid0=true valid1=true split=true ctrl=1 vp=1`. No crash, no corruption.

### Ruled out: file decryption, wrong thread, missing symbols

Three more avenues checked and closed this session, so they aren't retried:

- **No PDB.** The binary carries a debug link
  (`D:\in3\Main\Game\.builds\in3\win32\image\Game.consumer.pdb`, found via the
  RSDS record) but the file itself isn't shipped, as expected for a retail
  build. No local copy anywhere in the install.
- **`assets/data.zip` and `assets/excel/excel.zip` aren't standard zips** —
  both start with non-`PK` bytes, meaning a custom or encrypted container.
  Extracting them would need a format-specific `quickbms` script that doesn't
  currently exist for this engine. More importantly, even fully decrypted
  they would not contain the answer: `sub_34B200`'s dictionary is populated
  **in memory at runtime** from loaded assets, not stored on disk in a
  directly-readable key format. This is a live-state question, not a file
  format question.
- **Not a wrong-thread issue.** Confirmed by reading `LuaCall::hkPcall`
  (`src/luacall.cpp:131-149`): `drainRemoteCommandFile`/`drainPendingSnippets`
  — what runs a console command — are called directly inside the game's own
  hooked `lua_pcall`, i.e. on the main game thread, the same thread that
  processes ticks. Console-submitted calls are not happening on some other,
  wrong thread.

## Session 4: the frame-transient hypothesis is now testable, not just theorized

Everything in Session 3 established that a handle captured for `sub_34B200`
through the Lua console always comes back "not found" when replayed — for a
raw sku, for a previously-captured real handle, both in isolation and
through the real `sub_FACC10` chain. The open question was whether that is
because the *value* is wrong, or because the handle only lives for the one
frame it was produced in, which no console round-trip (seconds) could ever
rule out (a frame is ~16 ms). This session builds the tool needed to answer
that from C++ instead of guessing further from Lua — **not run against the
live game yet**, because this assistant has no way to launch or attach to
the game process in this environment. It is built, compiles clean, and is
ready for the next in-game session.

### `AvatarRelayHook` — capture the handle and reuse it in the same call stack

New hook, `src/avatar_relay_hook.cpp` / `include/loader/avatar_relay_hook.hpp`,
same MinHook-backed `Hook` class `MessageHook`/`InputHook` already use.
Installed permanently at startup (`Loader::initialize`), disarmed by
default — it costs nothing until armed.

It hooks `sub_34B200` (RVA `0x34B200`) itself. When armed with
`(gamePlayersThis, targetPlayerIndex)`:

1. The real resolver call happens first, always, unconditionally — this is
   never a replacement for whatever the game itself was doing.
2. The moment it returns a non-zero handle, **on the same thread, inside the
   same call stack, microseconds later**, the hook calls
   `GamePlayers::vtable[7]` (RVA `0x68D680`, the `sub_FACC10` entry point)
   with `(targetPlayerIndex, thatExactHandle, 0)`.
3. Single-shot: disarmed before the relay call fires, so a normal avatar
   swap the mod never armed for is never hijacked, and re-entrancy (if the
   relay call itself ends up back in the resolver) can't relay twice.

The relay call is SEH-guarded the same way `Crabe._callThis` is — a fault
is caught and reported, not fatal to the process.

Three new natives (`src/lua_runtime.cpp`, registered in `LuaRuntime::registerNatives`):
`Crabe._armAvatarRelay(gamePlayersThis, targetPlayerIndex)`,
`Crabe._disarmAvatarRelay()`, `Crabe._avatarRelayStatus()`.

Wrapped in `mods/splitscreen.lua` as `Crabe.Splitscreen.testAvatarRelay(seedSku, targetIndex)`:
arms the relay for `targetIndex` (defaults to `secondPlayerId()`), then
triggers a **real** resolve by swapping player 1's own character to
`seedSku` (`Players_ForceAvatar`/`Players_ChangeAvatar` on player 0 — the
only player a resolve can safely be triggered from). Returns the relay
status string and a fresh `player2()` snapshot.

**What a result means**: if `fired=1` and `player2().alive` flips true (or
the `AvatarCreated`/`AvatarReady`/... lifecycle shows up for index 1 in
`Crabe._messageReport()`), the frame-transient hypothesis was right and this
*is* the missing piece — the next step is turning `testAvatarRelay` into
something that seeds with the *player 2's own intended* sku rather than
borrowing player 1's swap. If `fired=1` but nothing changes, the handle
itself is not what `vtable[7]` wants even fetched same-frame, and this whole
avenue (arg2 resolution via `sub_34B200`) is closed for good — worth
recording here so it isn't retried a third way.

**Known side effect, not yet worked around**: this visibly swaps player 1's
character to `seedSku` for real. `testAvatarRelay` does not restore it —
call `Players_ChangeAvatar(0, yourOriginalSku)` by hand afterwards.

### `dumpReaderEntries` — data for the untried "forge a reader entry" idea

The reader wall section below documents a second, never-attempted avenue:
appending an entry to the list `UI_GetReaderAvatarCount` enumerates at image
address `0x213E278` (`0x50` bytes/entry, accepted types `1`/`5`/`6`/`0xC`).
Nothing is known about that struct's layout, or even whether `0x213E278` is
the array base directly or a pointer to it — guessing and writing blind
risks corrupting engine state for no evidence either way, and this session
had no live game to check against. `Crabe.Splitscreen.dumpReaderEntries(count)`
is the read-only half of that investigation: it prints both interpretations
side by side so real bytes exist to reason from next time, without writing
anything.

### Why this session couldn't go further than building it

The `disasm` (capstone, static) and `cheatengine` (live breakpoints) MCP
servers documented under "Tools this relies on" were **not registered in
this session** — they're added per-project and only picked up by a fresh
Claude Code session after `claude mcp add`. Static disassembly and live
breakpoint work is exactly what would settle two things fast: what
`sub_34B200` actually reads from `esi`/`edi`/`ebx` (an alternative to the
frame-transient theory — see "for you with Cheat Engine open" below), and
the real offset/type field inside a `0x213E278` entry. Both remain open for
whoever has those tools connected.

## Session 5: a C++ SplitscreenEngine was tried and reverted, then the addresses moved to a named Lua API

Two corrections in one session. First: an attempt moved every address/RVA
out of `mods/splitscreen.lua` into a new `SplitscreenEngine` C++ class, on
the reasoning "no raw addresses in Lua". Reverted -- this project's rule is
the opposite for anything that isn't a genuine hook. `Crabe._callThis`/
`_readBytes`/`_writeBytes`/`Crabe.inspect.*` exist precisely so RE work like
this stays in Lua.

Second: the addresses were still sitting as bare literals inside
`mods/splitscreen.lua` itself, which turned out not to be acceptable either
-- a mod file must never contain a raw address, named function or not. They
now live in `api/45_dropin.lua`, `Crabe.DropIn.*`
(`gamePlayers()`, `gameLoop()`, `tryCheck()`, `forceAllowed()`, `request()`,
`secondPlayerId()`, `readerManager()`, `dumpReaderEntries()`,
`armAvatarRelay()`) -- same Lua, same toolkit, just one file over, so
`mods/splitscreen.lua` only ever calls named functions. Third correction,
right after: this whole mod (including `Crabe.DropIn`) moved out of the
CrabeLoader repo into this one, since it's a mod, not modloader
infrastructure -- see CrabeLoader's `docs/modding.md` for the rule this is
now the reference example of.

Only `AvatarRelayHook` stays C++, because it is a real inline hook (runs
inside the game's own call stack) -- not something any amount of
`_callThis` could express. Project still targets C++23
(`CMAKE_CXX_STANDARD 23`) for whatever C++ work is genuinely needed.

## The reader wall (solved, and why it looked unsolvable)

This was the last blocker: player 2 is created, the screen splits, then the
game posts "Figurine Disney Infinity manquante" and drops them.

**Solved** by re-asserting the avatar from the tick loop (see the summary at
the top). The diagnosis below is kept because it is what made the fix
obvious — and because the reasoning was right even when the conclusion was
premature.

The reason the port was cut in the first place is a design problem rather than
a missing branch: **the PC virtual reader has no second-player interface at
all.** On console the second player joins by
putting a physical figure on the portal. On PC that portal is replaced by a
character-select screen that only ever existed in a one-player form — there is
no UI through which player 2 could pick a character, so there is nothing to
re-enable. Anything here has to go *around* the reader, not through it.

What the code says:

- `UI_GetReaderAvatarCount` (RVA `0x747230`) does not read a counter. It
  enumerates the objects currently *placed on the reader* (`[0x213E278]`,
  entries of `0x50` bytes) and counts those whose type is `1`, `5`, `6` or
  `0xC`. So it reports what is on the reader, and nothing sets a second entry.
- `UI_IsAvatarOnReader(1)` is `false` even after `Players_ChangeAvatar(1, sku)`
  succeeds and echoes the sku back. **Player avatar and reader contents are
  separate state** — assigning one does not populate the other.
- The dropout path has names: `MissingAvatar`, `MissingAvatarQuit`,
  `MissingAvatarDropout`, and an RTTI symbol `MissingAvatar@IGPGameFlow@@`.
  `IGPGameFlow` is the state machine to look at.

Two ways around it, neither tried yet:

1. **Neutralise the check.** Find where `IGPGameFlow` decides a player has no
   avatar and short-circuit it (hook or patch). Most direct; leaves the reader
   inconsistent, which may or may not matter elsewhere.
2. **Forge a second reader entry.** Append an entry to the list at
   `[0x213E278]` with one of the accepted types so `UI_GetReaderAvatarCount`
   returns 2 on its own. More faithful, more invasive — the entry layout
   (`0x50` bytes) would have to be worked out first.

`DisableIGP` exists as a native but takes **no** arguments (`DisableIGP(true)`
errors with "no value expected, got boolean"); calling it correctly is worth a
try before either of the above.

## Tools this relies on

- **`Crabe.inspect`** (CrabeLoader's `src/api/40_inspect.lua`, backed by C++
  natives in `src/lua_runtime.cpp`) — live introspection from the loader
  console: resolve a game native's address, read bytes, list a function's
  `call` targets, find every `call` site targeting an address, find pointers
  to a value anywhere in the process, and **call an arbitrary game function**
  (`_callThis`/`_callThis1`, SEH-guarded) and **write memory**
  (`_writeBytes`, SEH-guarded, 64 bytes max). All of it works from the
  console with the game running, no rebuild needed for a new question.
- **`MessageHook`** (CrabeLoader's `src/message_hook.cpp`) — hooks the
  engine's named message dispatcher (RVA `0x28BBB0`) and records any message
  whose name matches a watched substring. `Crabe._messageWatch(sub)` /
  `_messageReport()` / `_messageClear()`.
- **`InputHook`** (CrabeLoader's `src/input_hook.cpp`) — hooks
  `XInputGetState` and counts polls/connects per slot. `Crabe._inputReport()`.
- **Static disassembler** (local `tools/mcp_server/server.py`,
  capstone-based, reads the `.exe` directly) — registered as MCP server
  `disasm`. Also callable as a plain script:
  `python server.py`'s `disassemble(rva_hex, size)` / `find_string(text)` /
  `find_function_refs(text)`, importable directly
  (`sys.path.insert(0, r"...\tools\mcp_server"); from server import disassemble`)
  when the MCP tool itself isn't available in-session.
- **Cheat Engine bridge** (local `tools/cheatengine-mcp-bridge`,
  registered as MCP server `cheatengine`) — live breakpoints
  (`set_breakpoint`/`get_breakpoint_hits`, hardware, documented
  "non-breaking/logging only"), RTTI class names, structure dissection. Also
  directly importable as a plain script the same way as `disasm` above
  (`import mcp_cheatengine as ce`, its tools are plain functions). **Caution**:
  once during this investigation the game froze hard within seconds of
  arming a breakpoint on `DropInCheck`; a later identical arm on a fresh
  process was fine for tens of seconds under real input. Cause unconfirmed
  (anti-tamper trip vs. one-off DBVM glitch) — arm one breakpoint at a time
  and watch `loader.log` keep growing for a few seconds before relying on it.
- Both external tools need their MCP server registered per-project
  (`claude mcp add disasm -- <venv>\python.exe <path>\server.py`, same
  pattern for `cheatengine`) and picked up by a **fresh** Claude Code
  session — `/mcp reconnect` does not add newly-registered servers to an
  already-running session's tool roster.

## The ASLR rebasing rule (needed for every static-to-live translation)

The static disassembler reads the `.exe` on disk, which declares a preferred
image base of `0x400000` (`parse_pe`'s `image_base`). The live process loads
at a **different, per-launch base** — confirmed to vary between runs
(`0x430000` in one session, `0x200000` in another). Code RVAs are
base-independent and match directly. **Absolute operands embedded in
instructions** (e.g. `mov ecx, dword ptr [0x225f540]`) are not — they are
literal addresses computed relative to the preferred base at link time.

```
live_address = static_literal + (Crabe.inspect.base() - 0x400000)
```

Verified by reading the exact same instruction's bytes live and comparing:
static literal `0x22028DC`, live bytes at the matching RVA decoded to
`0x020028DC` when live base was `0x200000` — matches the formula exactly
(`0x22028DC + (0x200000 - 0x400000) = 0x020028DC`).

In practice, prefer reading the instruction's bytes live and extracting the
operand directly over doing the arithmetic by hand — it's self-verifying and
immune to transcription mistakes:

```lua
local b = Crabe._moduleBase()
local insn = Crabe._readBytes(b + 0x69E3CF, 6)  -- "8B 0D <addr32>"
-- parse the last 4 bytes little-endian -> that IS the live global slot address
```

## What the PC build still has

Not stripped, all present and verified:

- **Split rendering natives** — `UI_IsGamePlayHorizontalSplit`,
  `UI_IsGamePlayVerticalSplit`, `UI_ScreenSplitDirection`, `UI_ScreenViewports`,
  `GetViewportCount`, `Display_GetViewportIDFromPlayerID`,
  `GetPlayerNumberFromViewport`.
- **Capacity** — `Players_MaxPlayers()` returns `4`; `IsMultiplayerAllowed(0..3)`
  returns `true` for every slot.
- **Per-controller player assignment** — `LockPlayerToController`,
  `UnlockPlayerFromController`, `GetLockedControllerIndex`,
  `IsControllerLocked`, `GetUnlockedController`,
  `GetUnlockedControllerDeviceName`. These *work* (see below).
- **The 2-player UI layout** — `assets/presentation/containerdata.lua` ships
  `view0` **and** `view1` coordinates for the `horizontal`, `vertical` and
  `combined` split modes, for `Player2_HUD_Combined`, `Player3_HUD_Combined_MBA`,
  and `Player_HUD_IGP_MissingP2` (the "place player 2's figure" prompt, loc
  key `IGP_PlaceAvatarP2`) — **confirmed on screen**, see below.
- **Player 2 leaving** — `pausemenu.lua`'s `Pause_Drop_Out` option calls
  `RemovePlayer(playerNum)`, ungated by platform.

## What works from Lua

Confirmed in-game, persists across a level reload:

```lua
LockPlayerToController(1, 1)        -- player 2 (playerNum 1) <- controller 1
GetLockedControllerIndex(1)         -- was -1, now 1
IsControllerLocked(1)               -- was false, now true

Players_ForceAvatar(1, 1000100)     -- accepted
Players_ChangeAvatar(1, 1000100)    -- echoes the sku back = accepted
```

Both avatar calls mirror the console reader path, `virtualreader_in3.lua:1040-1041`.
`sku_id`s come from `VirtualReaderPC_Data.AvatarData` (104 entries).

`Players_IsValid(1)` still ends up `false` and `Display_GetViewportIDFromPlayerID(1)`
still `-1` — none of this alone creates the player. See below for why.

## `DropInCheck`: found, disassembled, and flippable

**Correction, in case an earlier note or memory says otherwise: RVA `0xFA3D00`
is NOT this function.** An earlier pass (before a real disassembler was
available) mis-identified it by scanning backward for 3+ consecutive `int3`
bytes and stopping at the wrong one — `0xFA3D00` is an unrelated avatar/string
comparison function three functions earlier in the binary. Everything built on
that address (a supposed vtable thunk at `0xFA7F70`, a vtable slot at
`0x19A639C`, ephemeral heap objects whose vtable pointer changed every
microsecond) was chasing the wrong target. If you find old notes referencing
those addresses for "DropInCheck", they are wrong.

**The real function is at RVA `0xFA40A0`.** Confirmed by full capstone
disassembly (`Crabe.inspect` alone cannot decode instructions, only find/read
raw bytes — this needed the static disassembler). Signature:
`bool __thiscall DropInCheck(GamePlayers* this, int suppressMessage)` —
`ret 4` (this + exactly one stack dword; calling it through a 3-arg thiscall
wrapper corrupts the stack by 8 bytes on return — that mismatch is why
`Crabe._callThis1` exists separately from `_callThis`).

Structure of the function:
1. A long early section (calls to `0xF9E6E0`, `0x13631D0`, `0xF84CB0`,
   `0x9B4110`, `0x9ACD30`, ...) computing several local flags from avatar/
   entitlement state.
2. A **fast-path accept**: if a cascade of byte comparisons between those
   locals and fields `[this+0x9B]`/`[this+0x9C]` all line up, returns `true`
   immediately (`FA41C6`), no message.
3. Otherwise, if the caller didn't request silence (arg `!= 1`), computes a
   **bitmask of refusal reasons** and posts it as `DropInBlocked(mask, 0)` on
   the message bus, then returns `false`:

```
xor ecx, ecx
test al, al                    ; al from the early section
je   +skip
mov  ecx, 1                    ; bit 0
cmp  byte [this+0x98], 0
jne  +skip
or   ecx, 2                    ; bit 1 -- confirmed: THE one that mattered live
cmp  byte [esp+0x10], 0
je   +skip2
cmp  byte [esp+0xe], 0
jne  +skip3
or   ecx, 4                    ; bit 2 -- local-flag dependent, changed between calls
cmp  byte [this+0x9c], 0
jne  +skip4
cmp  byte [esp+0x11], 0
jne  +skip5
cmp  byte [esp+0xf], 0
jne  +skip4
cmp  byte [this+0x9b], 0
je   +skip5
or   ecx, 8                    ; bit 3 -- never observed set
push 0
push ecx                       ; the mask
mov  ecx, [0x22028DC]          ; message dispatcher (same one StartButtonPushed uses)
push "DropInBlocked"
call 0x28BBB0
```

### Finding a live `this` — a real global, not a moving target

`DropInCheck` has **3 direct (non-virtual) call sites**, found with a from-
scratch static scan (search every `E8` in the image, resolve its target,
keep the ones landing on `0xFA40A0`) — RVAs `0x69E3D7`, `0x69E50A`,
`0xA02925`. All three set up `this` the same way:

```
mov ecx, dword ptr [0x225f540]   ; a fixed GLOBAL pointer slot -- NOT a vtable
push 0                            ; (or 1, at 0xA02925)
call 0xfa40a0
```

`[0x225f540]` (static literal — rebase per the formula above) is a **stable
global singleton pointer**, almost certainly the `GamePlayers` object (RTTI
`.?AVGamePlayers@@` was found earlier). Read 4 times in a row live: identical
every time. This is the opposite of the earlier (wrong) investigation's
ephemeral heap objects — completely safe to read and reuse.

### Confirmed live, this session

```lua
local b = Crabe._moduleBase()
local function rd32(a)
  local h = Crabe._readBytes(a, 4)
  local v, m = 0, 1
  for x in h:gmatch("%x%x") do v = v + tonumber(x,16)*m; m = m*256 end
  return v
end
local slot = rd32(b + 0x69E3CF + 2)   -- +2 skips the "8B 0D" opcode bytes
local this = rd32(slot)
local fn = b + 0xFA40A0

Crabe._callThis1(fn, this, 0)
-- -> al=0 (refused), DropInBlocked(6, 0) the first time, DropInBlocked(2, 0) on
--    a re-call (one of the local-flag reasons clears itself between calls)

Crabe._writeBytes(this + 0x98, "01")
Crabe._callThis1(fn, this, 0)
-- -> al=1 (ALLOWED), no DropInBlocked message at all
```

**No crash, either call.** `[this+0x98]` is the field that mattered live
(bit 1 of the mask). This is a real, reproducible unlock of the check itself.

Also confirmed: calling `DropInCheck` live triggers a real, visible UI side
effect — the game briefly showed **"Joueur 2 — Place une Disney Infinity
Figurine sur l'emplacement du Lecteur du joueur 2"**, the genuine
`Player_HUD_IGP_MissingP2` console prompt, complete with the portal icon.
Screenshotted during this session. This proves the UI layer, the message
bus, and the check itself are all still live and wired to each other on PC —
only the *input trigger* is missing.

## Where it actually stops: nothing calls any of this

This is the real finding of the session, and it changes the shape of the
remaining work.

- The function containing all 3 of `DropInCheck`'s call sites (starts before
  RVA `0x69E390`) has **zero callers found** — direct or virtual (a targeted
  scan for both `call rel32` and vtable-style data pointers to it, wide RVA
  range `0x69E200`–`0x69E3A0`, found nothing).
- A hardware execution breakpoint placed directly on `DropInCheck`
  (`0xFA40A0`, via the Cheat Engine bridge, `capture_stack=true`) **never
  fired** across two separate real-controller test rounds — dozens of Start
  presses on a second, XInput-confirmed-connected pad, both during normal
  play and with the pause menu open. The game stayed responsive and
  `loader.log` kept ticking the whole time, so this is a real negative
  result, not a frozen/broken breakpoint.
- `System_InGameStartButtonPushed` (what `ingamepressstart.lua:70` needs) is
  absent from the binary — 0 occurrences, ASCII and UTF-16.
- No Lua script anywhere in `assets/presentation/` ever calls
  `AddScreen({screenName = "InGamePressStart"})` — grepped all three files
  that mention the string at all (`buttonlegend.lua`, `containerdata.lua`,
  `ingamepressstart.lua` itself); none of them create the screen. It must be
  meant to be created natively, and whatever would do that was not found.

**Conclusion**: this isn't "the check refuses," it's "the entire call chain
from physical input to the check is disconnected." The pieces are all
individually intact and functional — proven by manually driving them one at a
time — but nothing in the shipped PC code path walks from a Start-button
press to `DropInCheck`. Something that exists on console (probably a
callback registered against the portal/controller subsystem) was never wired
up for PC, the same shape of cut as `System_InGameStartButtonPushed` itself.

## The missing caller, identified: `GameStandAloneLoop::OnDropInRequest`

The function that *should* be called when a second player presses Start is
intact in the PC binary. It was found by asking who writes the two fields the
`DropInCheck` caller reads (`+0x39C`/`+0x3A0` on its `this`) rather than by
chasing call sites, which had already been proven to lead nowhere.

**RVA `0x69E480`** — `__thiscall`, one stack arg (`ret 4`), returns nothing
useful. The argument is a pad/user index (`1` for the second player).

Identity is not guessed. The enclosing class has RTTI: walking back from the
single `.rdata` reference to this function lands on a vtable at RVA
`0x194418C` whose `RTTICompleteObjectLocator` names
**`.?AVGameStandAloneLoop@@`**. Two slots matter:

| vtable slot | RVA | role |
|---|---|---|
| `+0xAC` | `0x69E480` | **`OnDropInRequest(padIndex)`** — the entry point |
| `+0xC4` | `0x69E2A0` | consumes the pending request a tick later |

The function also carries its own source path as a string literal:
`D:\in3\Main\Game\Code\Main/GameLoop.cpp`, alongside
`@Popup_Message_Game_Full` (party full) and `frontend_cancel` (the sound
played on every refusal). This is unambiguously the shipped drop-in handler.

### Its four gates, and what each does on PC

```
1. permission check   call 0xF3C840 -> 0x8472C0   ; `mov al,1; ret` -- STUBBED, always passes
2. players < max      [g_gamePlayers+0x90] vs 0xE04CF0()
3. DropInCheck        call 0xFA40A0                ; THE refusal -- see above, one byte flips it
4. hub restriction    cmp byte ptr [g_hubState+0xE75], 0
                      -> if set, requires world "MatchmakingHubWorld"
```

Then it branches: if a screen is already up it performs the drop-in inline,
otherwise it creates a pending request (`[this+0x39C]`, `[this+0x3A0]`) for
slot `+0xC4` to consume next tick — that second path is the one that shows the
"place a figurine for player 2" prompt from the screenshot.

Gate 1 being a `mov al,1; ret` stub is worth noting: it is the same shape of
cut as `0xC99BA0` further down (also `mov al,1; ret 4`). The PC build did not
remove this code, it neutered the checks around it and stopped calling it.

### Calling it: the two prerequisites

- **A level must be loaded.** Gate 4 dereferences `g_hubState` (image
  `0x228DB60`) unconditionally, and that global is still null at the main
  menu — calling from there faults. Confirmed live; `_callThis1`'s SEH guard
  caught it and the process survived.
- **Gate 3 must be forced first** (`[g_gamePlayers+0x98] = 1`), or the call
  is a no-op that just plays `frontend_cancel`.

Exposed as `Crabe.Splitscreen.requestDropIn(padIndex)`, which does both.

### Finding the `GameStandAloneLoop` instance

No global points at it, so it is found by its vtable pointer. A plain scan
returns several hits per run — heap memory that briefly held a copy — so the
match is confirmed against the *secondary* vtables too. The class uses
multiple inheritance, which makes this decisive: a coincidental hit will not
carry all four. From the constructor (RVA `0xCCC060`, `new(0x3a8)`):

| offset | image value |
|---|---|
| `+0x00` | `0x1D4418C` |
| `+0x58` | `0x1D44180` |
| `+0x308` | `0x1D44174` |
| `+0x378` | `0x1D43F88` |

These are *file* constants, so they need rebasing (see the rebasing rule —
and note the inverse trap documented there: values read out of live memory
are already relocated and must **not** be rebased again). Implemented as
`Crabe.Splitscreen.gameLoop()`.

## Dead ends (do not re-run these)

- Locking **both** controllers before `UI_LaunchLevel`. Lock survives reload;
  player count does not change.
- `System_StartButtonPushed(1)` in-game — posts the front-end message,
  nothing downstream answers it (confirmed via `MessageHook`: dispatched,
  zero `DropInBlocked` in response).
- `System_SendMessage(name, _, n)` — 3rd arg is `luaL_optinteger`, so the
  real form is `System_SendMessage("EnableDropIn", 0, 1)`. Tried with
  `EnableDropIn`/`StartButtonPushed`, controllers 0/1: accepted, no effect.
  This native swallows anything including no args, so "no error" proves
  nothing on its own.
- Forcing `VirtualReader_IN3` (the console reader screen) via `AddScreen` —
  loads and returns a valid handle, then **crashes the game on open**; its
  console-only assets are not all present on PC.
- `VirtualReaderPC_ActivateChanges(1, true)`,
  `VirtualReaderPC_SetCurrentCharacter(sku, 1)` — accepted, no effect.
- `VirtualReader_AddToPlacedObjectCount(1)` — a toybox-object counter, not
  figures on a reader. False friend.
- Pausing the game before pressing Start on controller 2 — no different from
  unpaused; `DropInCheck` breakpoint still never fires either way.

Also: `Place_SetActiveVirtualController`, `System_LockController` and
`GetPlayerAvatarData` **hard-crash the process** on a wrong argument count
rather than raising a Lua error. Confirm arity live before calling them
(the game was fully restarted at least twice this session because of exactly
this class of mistake, plus once from the CE breakpoint incident above).

### Two traps that each cost a game session

- **Arity mismatch is not caught by the SEH guard.** `_callThis` (3 args) on
  a function whose disassembly ends in a bare `ret` pushes three dwords the
  callee never pops; the caller then returns into a shifted frame and dies
  somewhere unrelated. SEH cannot see this — the fault is elsewhere, later.
  Read the callee's `ret` first, every time, and pick the matching wrapper:
  `_callThis0` / `_callThis1` / `_callThis`. `_callThis0` exists because this
  exact mistake killed a session (`0xE04CF0`, a plain `ret`, called with 3).
- **A crashing remote command used to be a boot loop.** `crabe_remote_cmd.txt`
  outlives the process but the "already ran this one" state did not, so a
  command that killed the game was replayed on every relaunch — the game
  appeared to "crash instantly" with no obvious cause. Fixed in
  `Loader::drainRemoteCommandFile`: the file is now consumed (deleted) before
  its contents run. If an old build ever shows this symptom, delete the file
  by hand.

## Using it

```lua
Crabe.Splitscreen.enable(1)                              -- pad 1 joins as player 2
Crabe.Splitscreen.setCharacter(Crabe.Splitscreen.characters.ironMan)  -- swap live
Crabe.Splitscreen.player2()                              -- live snapshot
```

`enable()` must be called **in-game**, not from the main menu (gate 4
dereferences a global that is still null there). It handles the tick delay and
the avatar itself; `setCharacter` is only needed to change character
afterwards.

`player2()` reports `valid`, `avatarSku`, `alive`, `onReader`, `controller`,
`viewport`, `splitActive`. Note that `controller` (`GetLockedControllerIndex`)
only says the engine *recorded* a binding — it is not evidence that input
reaches a character. The pad actually driving player 2 was confirmed by a human
using it, which is the only check that counts.

`UI_GetAvatarSKU(1)` reports `0` even with a character assigned and alive; it
does not take a player index. Use `player2().alive` / `onReader` instead.

The first `gameLoop()` of a session scans process memory for the vtable
pointer and takes ~26 s (measured); the result is cached and re-verified
against its four vtables on later calls, which then cost ~0.004 s. So the
first `enable()` is slow and everything after it is instant.

Measured stable over two minutes with zero `MissingAvatar` / `PlayerDropout` /
`AvatarRemoved` messages.

## Concrete next steps, in order

1. **Spawn player 2's character.** This is the blocker. Confirmed by a human:
   nothing is visible in player 2's viewport and the pad moves nothing.

   The right function has been found — `GamePlayers::vtable[7]` (RVA
   `0x68D680`) → `sub_FACC10`, see "The real per-player spawn function"
   below. It is the one that dispatches the real `AvatarCreated` message.
   `arg1` (the player index) is confirmed correct as `secondPlayerId()`.
   What's still unknown is `arg2` — neither `0` nor a raw sku (`1000100`)
   gets past the "already has this type" gate built around `sub_34B200`.
   That function turned out not to be safely callable in isolation (faults
   outside its real call chain), so the productive next step is varying
   `arg2` **through the full chain** (`sub_68D680`), not probing `sub_34B200`
   on its own. `spawnAvatar()` (RVA `0x9EA280`) is a confirmed dead end — do
   not revisit it, see the section above for why.
2. **Make it trigger itself.** Right now `enable(1)` is a console call.
   `InputHook` already sees every `XInputGetState`; extend it to detect Start
   on a connected-but-unassigned pad and run the sequence from C++ — that is
   the cable the PC build is missing, and it would make this a real mod rather
   than a procedure.
3. **More than two players.** Nothing examined so far is hardcoded to two —
   `sub_2CAA0` only knows "primary" and "second", but the drop-in path takes
   a pad index. Whether slots 2 and 3 work is untested.
3. Handle the render side once a valid player 2 exists — confirm
   `UI_IsGamePlayHorizontalSplit`/viewport count update on their own once
   `Players_IsValid(1)` goes true, or whether the container/viewport system
   also needs an explicit kick (it may — `CointainerBase:Update`,
   `containerbase.lua:265`, reads `self.numberOfPlayers`, which is presumably
   engine-pushed, not something Lua sets itself).

No one has published a splitscreen mod for this game — checked across Steam
Community, GitHub, PCGamingWiki, ModDB and GameBanana this session; existing
threads are feature requests with no technical content.
