-- Run from the repository root with Lua 5.1, or with Python/lupa.lua51:
-- python -c "from lupa.lua51 import LuaRuntime; from pathlib import Path; LuaRuntime().execute(Path('tests/vehicle_claim_access_sync.lua').read_text())"
local root = "Contents/mods/ApocalipseClaimSystem/42.19/media/lua/"
require = function() end
Events = setmetatable({}, { __index = function(t, name)
    local event = { Add = function() end, Remove = function() end }
    rawset(t, name, event)
    return event
end })
LuaEventManager = { AddEvent = function() end }
triggerEvent = function() end
isServer = function() return true end
isClient = function() return false end
isDebugEnabled = function() return false end
getTimestampMs = function() return 1000 end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

local function player(name, steamID, x)
    return {
        getUsername = function() return name end,
        getSteamID = function() return steamID end,
        getAccessLevel = function() return "" end,
        getX = function() return x or 0 end,
        getY = function() return 0 end,
        getZ = function() return 0 end,
        getVehicle = function() return nil end,
        Say = function() end,
    }
end

local owner = player("Owner", "owner")
local friend = player("Friend", "friend")
local stranger = player("Stranger", "stranger")
local distant = player("Distant", "distant", 200)
local players = { owner, friend, stranger, distant }
getOnlinePlayers = function() return {
    size = function() return #players end,
    get = function(_, i) return players[i + 1] end,
} end
getPlayer = function() return friend end

local function vehicle()
    local data = { vehicleHash = "VH1" }
    return {
        getModData = function() return data end,
        getId = function() return 1 end,
        getX = function() return 0 end,
        getY = function() return 0 end,
        getZ = function() return 0 end,
    }
end

local serverVehicle, clientVehicle = vehicle(), vehicle()
local visibleVehicle = serverVehicle
getCell = function() return { getVehicles = function() return {
    iterator = function()
        local pending = true
        return {
            hasNext = function() return pending end,
            next = function() pending = false; return visibleVehicle end,
        }
    end,
} end } end

local entry = {
    vehicleHash = "VH1", ownerSteamID = "owner", ownerName = "Owner",
    vehicleName = "Car", claimTime = 1, lastSeen = 1,
    allowedPlayers = { existing = "Existing" },
}
local registry = { claims = { VH1 = entry } }
local transmissions = 0
ModData = {
    getOrCreate = function() return registry end,
    transmit = function() transmissions = transmissions + 1 end,
}
local packets = {}
sendServerCommand = function(recipient, module, command, args)
    packets[#packets + 1] = {
        recipient = recipient, module = module, command = command,
        args = copy(args), -- Model the independent table received over the network.
    }
end

dofile(root .. "shared/VehicleClaim_Shared.lua")
VehicleClaim.updateCarDatabase = function() end
local server = dofile(root .. "server/VehicleClaim_ServerCommands.lua")
local client = dofile(root .. "client/VehicleClaim_ClientCommands.lua")

local function deliverSyncs(expected)
    local counts = {}
    visibleVehicle = clientVehicle
    for _, packet in ipairs(packets) do
        if packet.command == VehicleClaim.RESP_SYNC_VEHICLE_MODDATA then
            counts[packet.recipient] = (counts[packet.recipient] or 0) + 1
            if packet.recipient == friend then
                client.onSyncVehicleModData(packet.args)
            end
        end
    end
    visibleVehicle = serverVehicle
    for _, recipient in ipairs({ owner, friend, stranger }) do
        assert((counts[recipient] or 0) == expected, "missing or redundant permission broadcast")
    end
    assert(counts[distant] == nil, "broadcast exceeded sync range")
    packets = {}
end

server.onVehicleCreated(serverVehicle)
deliverSyncs(1)
assert(not VehicleClaim.hasAccess(clientVehicle, "friend"))

-- Exercise an existing shared table as well as a freshly rebuilt mirror.
-- This can exist before the first reconciliation after an update.
serverVehicle:getModData().VehicleClaimData.allowedPlayers = entry.allowedPlayers
server.onClientCommand("VehicleClaim", VehicleClaim.CMD_ADD_PLAYER, owner, {
    vehicleHash = "VH1", steamID = "owner", targetPlayerName = "Friend",
})
deliverSyncs(1)
assert(transmissions == 1)
assert(entry.allowedPlayers.friend == "Friend")
assert(entry.allowedPlayers.existing == "Existing")
assert(VehicleClaim.hasAccess(clientVehicle, "friend"), "added player still denied on client")
assert(not VehicleClaim.hasAccess(clientVehicle, "stranger"))
assert(VehicleClaim.hasAccess(clientVehicle, "owner"))
assert(serverVehicle:getModData().VehicleClaimData.allowedPlayers ~= entry.allowedPlayers)

server.onVehicleCreated(serverVehicle)
deliverSyncs(0)

-- A change to the vehicle mirror must not mutate the authoritative registry.
serverVehicle:getModData().VehicleClaimData.allowedPlayers.stranger = "Stranger"
assert(entry.allowedPlayers.stranger == nil)
server.onVehicleCreated(serverVehicle)
deliverSyncs(1)
assert(not VehicleClaim.hasAccess(clientVehicle, "stranger"))

serverVehicle:getModData().VehicleClaimData.allowedPlayers = entry.allowedPlayers
server.onClientCommand("VehicleClaim", VehicleClaim.CMD_REMOVE_PLAYER, owner, {
    vehicleHash = "VH1", steamID = "owner", targetSteamID = "friend",
})
deliverSyncs(1)
assert(transmissions == 2)
assert(entry.allowedPlayers.friend == nil)
assert(entry.allowedPlayers.existing == "Existing")
assert(not VehicleClaim.hasAccess(clientVehicle, "friend"), "removed player retains client access")
assert(VehicleClaim.hasAccess(clientVehicle, "owner"))
server.onVehicleCreated(serverVehicle)
deliverSyncs(0)

print("PASS: grant/revoke sync, existing shared tables, registry isolation, owner access, range, unchanged sync")
