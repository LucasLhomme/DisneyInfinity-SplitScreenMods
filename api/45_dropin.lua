-- Crabe.DropIn: Disney Infinity 3.0's internal second-player/drop-in engine
-- state, confirmed live and documented in docs/splitscreen.md. Every address
-- involved lives here, behind named functions -- mods/*.lua must never
-- contain a raw address; call these instead.

Crabe.DropIn = Crabe.DropIn or {}

local D = Crabe.DropIn

local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

-- Reads a live little-endian dword at `address`.
local function readLiveDword(address)
    local hex = try(Crabe._readBytes, address, 4)
    if not hex then return nil end

    local value, scale = 0, 1
    for byte in hex:gmatch("%x%x") do
        value = value + tonumber(byte, 16) * scale
        scale = scale * 256
    end
    return value
end

-- Turns a file-address constant (from a disassembly listing) into a live one.
-- Only for literal operands baked into instructions -- code RVAs (base + RVA)
-- need no rebasing, and values already read from live memory are relocated.
local kPreferredBase = 0x400000

local function rebase(imageAddress)
    local base = Crabe._moduleBase()
    if not base or not imageAddress then return nil end
    return imageAddress - kPreferredBase + base
end

-- The GamePlayers-like singleton DropInCheck/avatar natives use as `this`.
function D.gamePlayers()
    local base = Crabe._moduleBase()
    if not base then return nil end

    local slotAddress = readLiveDword(base + 0x69E3CF + 2)
    if not slotAddress then return nil end

    return readLiveDword(slotAddress)
end

-- GameStandAloneLoop's 4 vtable pointers (multiple inheritance -- one base
-- class per offset), read from its constructor at RVA 0xCCC060. No global or
-- native points at a live instance, so matching all 4 against a heap scan
-- hit is the only reliable way to identify one (a single match is a coin
-- flip: other heap objects briefly hold a copy of any one vtable pointer).
local kGameLoopVtableByOffset = {
    [0x000] = 0x1D4418C,
    [0x058] = 0x1D44180,
    [0x308] = 0x1D44174,
    [0x378] = 0x1D43F88,
}

local function looksLikeGameLoop(object)
    if not object then return false end

    for offset, vtable in pairs(kGameLoopVtableByOffset) do
        if readLiveDword(object + offset) ~= rebase(vtable) then return false end
    end
    return true
end

local gameLoopCache = nil

-- The live GameStandAloneLoop instance (owns the drop-in path).
function D.gameLoop()
    -- ~30s first scan, cached after (and re-verified, not just trusted).
    if looksLikeGameLoop(gameLoopCache) then
        return gameLoopCache
    end

    local candidates = try(Crabe._findPointers, rebase(0x1D4418C), 16)
    if not candidates then return nil end

    for text in tostring(candidates):gmatch("[^,]+") do
        local object = tonumber(text)
        if looksLikeGameLoop(object) then
            gameLoopCache = object
            return object
        end
    end

    return nil
end

-- Calls DropInCheck (RVA 0xFA40A0). Does NOT create player 2 by itself --
-- nothing in the shipped binary calls this naturally.
function D.tryCheck(suppressMessage)
    local base = Crabe._moduleBase()
    local this = D.gamePlayers()
    if not base or not this then return nil end

    local result = try(Crabe._callThis1, base + 0xFA40A0, this, suppressMessage or 0)
    if not result then return nil end

    return math.floor(result) % 256 ~= 0
end

-- Clears DropInCheck's refusal bit ([this+0x98]). Data-only, safe, does not
-- persist across a level reload.
function D.forceAllowed()
    local this = D.gamePlayers()
    if not this then return false end

    return try(Crabe._writeBytes, this + 0x98, "01") == true
end

-- GameStandAloneLoop::OnDropInRequest (RVA 0x69E480) -- the drop-in entry
-- point nothing in the PC build calls. Needs a level loaded (gate 4 derefs
-- a global that's null at the main menu).
function D.request(padIndex, force)
    local loop = D.gameLoop()
    if not loop then return nil end

    if force ~= false then D.forceAllowed() end

    local base = Crabe._moduleBase()
    if not base then return nil end

    local result = try(Crabe._callThis1, base + 0x69E480, loop, padIndex or 1)
    if not result then return nil end

    return math.floor(result) % 256
end

-- Whether a second player genuinely exists. NOT the same as Players_IsValid(1):
-- when player 2 doesn't exist, the resolver behind ForceAvatar/ChangeAvatar
-- returns -1 and callers coerce that to 0, silently hitting player 1 instead.
function D.secondPlayerId()
    local base = Crabe._moduleBase()
    local players = D.gamePlayers()
    if not base or not players then return nil end

    local primary = try(Crabe._callThis0, base + 0xF80740, players)
    if not primary then return nil end

    local second = try(Crabe._callThis1, base + 0xF806E0, players, primary)
    if not second or second < 0 then return nil end

    return second
end

-- The reader manager `this`, image address 0x213E27C.
function D.readerManager()
    return readLiveDword(rebase(0x213E27C))
end

-- Read-only dump of the reader entry list (image 0x213E278, 0x50 bytes/entry,
-- UI_GetReaderAvatarCount's source). Layout is unknown, so this only reads --
-- see docs/splitscreen.md, "forge a reader entry".
function D.dumpReaderEntries(count)
    count = count or 4

    local arrayAddress = rebase(0x213E278)
    if not arrayAddress then return nil, "no module base" end

    local asPointer = readLiveDword(arrayAddress)
    local bases = { { label = "direct", address = arrayAddress } }
    if asPointer and asPointer > 0x10000 then
        bases[#bases + 1] = { label = "indirect", address = asPointer }
    end

    local out = {}
    for _, base in ipairs(bases) do
        for i = 0, count - 1 do
            local entryAddress = base.address + i * 0x50
            local bytes = try(Crabe._readBytes, entryAddress, 0x50)
            out[#out + 1] = { label = base.label, index = i, address = entryAddress, bytes = bytes }
        end
    end
    return out
end

-- Arms AvatarRelayHook (src/avatar_relay_hook.cpp) for `targetPlayerIndex`,
-- resolving `this` here so the caller never sees it. See docs/splitscreen.md
-- session 4 for what this tests.
function D.armAvatarRelay(targetPlayerIndex)
    local players = D.gamePlayers()
    if not players then return false end

    return try(Crabe._armAvatarRelay, players, targetPlayerIndex) == 1
end
