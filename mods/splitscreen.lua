-- CrabeLoader mod: local splitscreen co-op. Full findings live in
-- docs/splitscreen.md. Player 2 joins and gets staged; spawning their
-- character in the world is the open problem.
--
-- No raw address anywhere below -- every one lives in Crabe.DropIn
-- (src/api/45_dropin.lua), behind named functions.

Crabe.Splitscreen = Crabe.Splitscreen or {}

local S = Crabe.Splitscreen
local D = Crabe.DropIn

-- Captain America; any sku_id from VirtualReaderPC_Data.AvatarData works.
S.defaultAvatarSku = 1000100

-- pcall wrapper: some natives hard-crash on a wrong arg count instead of
-- raising a Lua error, so nothing here is called uncertain of its arity.
local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

-- Requests the drop-in and stages the avatar assignment for a few ticks
-- later (ForceAvatar resolves the wrong slot if called same-tick).
function S.enable(padIndex, avatarSku)
    padIndex = padIndex or 1
    avatarSku = avatarSku or S.defaultAvatarSku

    local result = D.request(padIndex)
    if result == nil then return false, "requestDropIn failed (see loader.log)" end

    S._pendingAvatar = { sku = avatarSku, pad = padIndex, ticks = 0 }
    return true
end

S.characters = {
    captainAmerica = 1000100,
    ironMan        = 1000101,
    hulk           = 1000102,
    blackWidow     = 1000103,
    thor           = 1000104,
}

-- Assigns a character to player 2 (reader slot + actual avatar). Refuses if
-- player 2 doesn't exist -- see Crabe.DropIn.secondPlayerId, the failure
-- mode otherwise is overwriting player 1's character.
function S.setCharacter(sku)
    sku = sku or S.defaultAvatarSku

    local second = D.secondPlayerId()
    if not second then
        return nil, "no second player -- refusing, this would overwrite player 1's character"
    end

    try(Players_ForceAvatar, second, sku)
    try(Players_ChangeAvatar, second, sku)

    S._avatarSku = sku
    return sku
end

-- Finishes enable() (delayed avatar assignment) and keeps re-asserting the
-- avatar every tick -- closing the "figure manquante" popup drops player 2
-- otherwise, since there's no physical portal to keep it satisfied.
if not S._tickRegistered then
    S._tickRegistered = true

    Game.onTick(function()
        local pending = S._pendingAvatar
        if pending then
            pending.ticks = pending.ticks + 1
            if pending.ticks >= 4 then
                try(LockPlayerToController, 1, pending.pad)
                S.setCharacter(pending.sku)
                S._pendingAvatar = nil
            end
            return
        end

        if S._avatarSku and try(Players_IsValid, 1) == true then
            if try(UI_IsAvatarOnReader, 1) ~= true then
                local second = D.secondPlayerId()
                if second then try(Players_ForceAvatar, second, S._avatarSku) end
            end
        end
    end)
end

-- Prints Crabe.DropIn.dumpReaderEntries()'s report (see there for what it
-- means -- read-only, feeds the untried "forge a reader entry" idea).
function S.dumpReaderEntries(count)
    local entries = D.dumpReaderEntries(count)
    for _, entry in ipairs(entries) do
        print(string.format("reader entry [%s] %d @ 0x%X: %s",
            entry.label, entry.index, entry.address, tostring(entry.bytes)))
    end
    return entries
end

-- Tests whether the avatar resolver's handle is frame-transient (see
-- docs/splitscreen.md session 4) by arming AvatarRelayHook then triggering
-- a real resolve via a player-1 swap. Side effect: really swaps player 1 --
-- swap it back yourself.
function S.testAvatarRelay(seedSku, targetIndex)
    seedSku = seedSku or S.defaultAvatarSku
    targetIndex = targetIndex or D.secondPlayerId()
    if not targetIndex then return nil, "no second player -- nothing to target" end

    if not D.armAvatarRelay(targetIndex) then
        return nil, "arm failed -- AvatarRelayHook not installed? check loader.log"
    end

    try(Players_ForceAvatar, 0, seedSku)
    try(Players_ChangeAvatar, 0, seedSku)

    local status = try(Crabe._avatarRelayStatus) or "status unavailable"
    return status, S.player2()
end

-- Live snapshot of player 2.
function S.player2()
    return {
        valid       = try(Players_IsValid, 1),
        avatarSku   = try(UI_GetAvatarSKU, 1),
        alive       = try(UI_IsAvatarAlive, 1),
        onReader    = try(UI_IsAvatarOnReader, 1),
        controller  = try(GetLockedControllerIndex, 1),
        viewport    = try(Display_GetViewportIDFromPlayerID, 1),
        splitActive = try(UI_IsGamePlayVerticalSplit) or try(UI_IsGamePlayHorizontalSplit),
    }
end

-- Controllers seen but unassigned. Device name (not the index) tells you a
-- slot is real: "Empty" past however many pads are actually connected.
function S.controllers()
    local found = {}

    for index = 0, 3 do
        local deviceName = try(GetUnlockedControllerDeviceName, index)
        if deviceName and deviceName ~= "Empty" then
            found[#found + 1] = {
                index = index,
                device = deviceName,
                locked = try(IsControllerLocked, index) == true,
            }
        end
    end
    return found
end

-- Binds player 2 to a controller and gives them a character. Not the same as
-- player 2 existing -- check S.diagnose().playerValid.
function S.prepare(controllerIndex, avatarSku)
    controllerIndex = controllerIndex or 1
    avatarSku = avatarSku or S.defaultAvatarSku

    try(LockPlayerToController, 1, controllerIndex)
    if try(GetLockedControllerIndex, 1) ~= controllerIndex then
        return false, "controller " .. controllerIndex .. " could not be locked to player 2"
    end

    try(Players_ForceAvatar, 1, avatarSku)
    if try(Players_ChangeAvatar, 1, avatarSku) ~= avatarSku then
        return false, "avatar " .. avatarSku .. " was refused for player 2"
    end
    return true
end

function S.diagnose()
    return {
        maxPlayers = try(Players_MaxPlayers),
        multiplayerAllowed = try(IsMultiplayerAllowed, 0),
        dropInNativePresent = type(_G.System_InGameStartButtonPushed) == "function",

        localPlayers = try(Players_NumLocalPlayers),
        playerValid = try(Players_IsValid, 1),

        player2Controller = try(GetLockedControllerIndex, 1),
        controllers = S.controllers(),

        viewportCount = try(GetViewportCount),
        player2Viewport = try(Display_GetViewportIDFromPlayerID, 1),
        horizontalSplit = try(UI_IsGamePlayHorizontalSplit),
        verticalSplit = try(UI_IsGamePlayVerticalSplit),

        readerAvatarCount = try(UI_GetReaderAvatarCount),
        usingVirtualReader = try(UI_UseVirtualReader),

        zone = try(UI_GetPlayerZoneName, 0),
        zoneAllowsSplitJoin = (function()
            local zoneName = try(UI_GetPlayerZoneName, 0)
            if type(zoneName) ~= "string" then return nil end
            return try(UI_GetZoneMgrBool, zoneName, "SplitScreenJoinAllowed")
        end)(),
    }
end

function S.report()
    local d = S.diagnose()

    print("=== Crabe.Splitscreen ===")
    print(string.format("  engine      : maxPlayers=%s multiplayerAllowed=%s dropInNative=%s",
        tostring(d.maxPlayers), tostring(d.multiplayerAllowed), tostring(d.dropInNativePresent)))
    print(string.format("  players     : local=%s player2Valid=%s",
        tostring(d.localPlayers), tostring(d.playerValid)))
    print(string.format("  staging     : player2Controller=%s (-1 means unassigned)",
        tostring(d.player2Controller)))
    print(string.format("  rendering   : viewports=%s player2Viewport=%s hSplit=%s vSplit=%s",
        tostring(d.viewportCount), tostring(d.player2Viewport),
        tostring(d.horizontalSplit), tostring(d.verticalSplit)))
    print(string.format("  reader      : avatars=%s virtual=%s",
        tostring(d.readerAvatarCount), tostring(d.usingVirtualReader)))
    print(string.format("  zone        : %s splitJoinAllowed=%s",
        tostring(d.zone), tostring(d.zoneAllowsSplitJoin)))

    for _, controller in ipairs(d.controllers) do
        print(string.format("  controller %d: %s locked=%s",
            controller.index, controller.device, tostring(controller.locked)))
    end

    if d.playerValid then
        print("  -> player 2 IS live.")
    elseif d.player2Controller and d.player2Controller >= 0 then
        print("  -> player 2 staged on controller " .. d.player2Controller .. " but not instantiated.")
    else
        print("  -> player 2 not staged. Call Crabe.Splitscreen.prepare().")
    end
    return d
end

-- Re-checks the binary findings against the running process (post-update
-- drift), rather than trusting comments.
function S.inspectEngine()
    if not Crabe.inspect then
        print("splitscreen: Crabe.inspect unavailable (api/40_inspect.lua not loaded)")
        return nil
    end

    local result = {}
    for _, name in ipairs({ "System_StartButtonPushed", "System_ValidStartingController",
                            "RemovePlayer", "UI_GetZoneMgrBool" }) do
        result[name] = Crabe.inspect.native(name)
    end
    result.inGameDropInPresent = Crabe.inspect.native("System_InGameStartButtonPushed") ~= nil

    result.messages = {}
    for _, message in ipairs({ "StartButtonPushed", "DropInBlocked", "EnableDropIn",
                               "SecondPlayerJoining", "SplitScreenAllowed", "MissingAvatar",
                               "InGameStartButtonPushed" }) do
        result.messages[message] = Crabe._findString(message) ~= nil
    end

    print("=== splitscreen: engine binary ===")
    for _, name in ipairs({ "System_StartButtonPushed", "System_ValidStartingController",
                            "RemovePlayer", "UI_GetZoneMgrBool" }) do
        local address = result[name]
        print(string.format("  %-32s %s", name,
            address and string.format("RVA 0x%X", Crabe.inspect.rva(address)) or "NOT FOUND"))
    end
    print("  drop-in native present          : " .. tostring(result.inGameDropInPresent))

    for message, present in pairs(result.messages) do
        print(string.format("  message %-26s %s", message, present and "present" or "ABSENT"))
    end
    return result
end

-- Auto-stage player 2 on load if a free second controller is present.
local secondController = nil
for _, controller in ipairs(S.controllers()) do
    if controller.index ~= 0 and not controller.locked then
        secondController = controller.index
        break
    end
end

if secondController then
    local ok, err = S.prepare(secondController)
    if ok then
        print("splitscreen: player 2 staged on controller " .. secondController ..
              " -- run Crabe.Splitscreen.report() for the full picture")
    else
        print("splitscreen: staging failed -- " .. tostring(err))
    end
else
    print("splitscreen: no free second controller found; Crabe.Splitscreen.report() still works")
end
