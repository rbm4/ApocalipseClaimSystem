--[[
    VehicleClaim_ClientCommands.lua
    Client-side command handler for server responses
    Processes server confirmations and updates local state
]] require "shared/VehicleClaim_Shared"

local VehicleClaimClient = {}

-----------------------------------------------------------
-- Server Response Handlers
-----------------------------------------------------------

--- Process server commands sent to this client
--- @param module string Command module identifier
--- @param command string Command type
--- @param args table Command arguments
function VehicleClaimClient.onServerCommand(module, command, args)
    if module ~= VehicleClaim.COMMAND_MODULE then
        return
    end

    VehicleClaim.log("Client received command: " .. tostring(command))

    local player = getPlayer()
    if not player then
        return
    end

    if command == VehicleClaim.RESP_CLAIM_SUCCESS then
        VehicleClaimClient.onClaimSuccess(args)

    elseif command == VehicleClaim.RESP_CLAIM_FAILED then
        VehicleClaimClient.onClaimFailed(args)

    elseif command == VehicleClaim.RESP_RELEASE_SUCCESS then
        VehicleClaimClient.onReleaseSuccess(args)

    elseif command == VehicleClaim.RESP_PLAYER_ADDED then
        VehicleClaimClient.onPlayerAdded(args)

    elseif command == VehicleClaim.RESP_PLAYER_REMOVED then
        VehicleClaimClient.onPlayerRemoved(args)

    elseif command == VehicleClaim.RESP_ACCESS_DENIED then
        VehicleClaimClient.onAccessDenied(args)

    elseif command == VehicleClaim.RESP_VEHICLE_INFO then
        VehicleClaimClient.onVehicleInfo(args)

    elseif command == VehicleClaim.RESP_MY_CLAIMS then
        VehicleClaimClient.onMyClaims(args)

    elseif command == VehicleClaim.RESP_CONSOLIDATE_RESULT then
        VehicleClaimClient.onConsolidateResult(args)
    end
end

--- Handle successful claim
function VehicleClaimClient.onClaimSuccess(args)
    local vehicleID = args.vehicleID or "Unknown"
    local player = getPlayer()

    -- Show notification to player
    if player then
        player:Say("Successfully claimed vehicle ID: " .. tostring(vehicleID))
    end

    -- Refresh any open UI panels
    VehicleClaimClient.refreshOpenPanels()
end

--- Handle failed claim attempt
function VehicleClaimClient.onClaimFailed(args)
    local reason = args.reason or "Unknown error"
    local player = getPlayer()

    local message = "Claim failed: "

    if reason == VehicleClaim.ERR_ALREADY_CLAIMED then
        message = message .. "Vehicle is already claimed"
    elseif reason == VehicleClaim.ERR_VEHICLE_NOT_FOUND then
        message = message .. "Vehicle not found"
    elseif reason == VehicleClaim.ERR_TOO_FAR then
        message = message .. "Too far from vehicle"
    elseif reason == VehicleClaim.ERR_CLAIM_LIMIT_REACHED then
        local current = args.currentClaims or 0
        local max = args.maxClaims or 0
        message = string.format("Claim limit reached (%d/%d vehicles)", current, max)
    else
        message = message .. reason
    end

    if player then
        player:Say(message)
    end
end

--- Handle successful release
function VehicleClaimClient.onReleaseSuccess(args)
    local vehicleID = args.vehicleID or "Unknown"
    local player = getPlayer()

    if player then
        player:Say("Released claim on vehicle ID: " .. tostring(vehicleID))
    end

    VehicleClaimClient.refreshOpenPanels()
end

--- Handle player added to access list
function VehicleClaimClient.onPlayerAdded(args)
    local playerName = args.addedPlayerName or "Player"
    local player = getPlayer()

    if player then
        player:Say("Added " .. playerName .. " to vehicle access")
    end

    VehicleClaimClient.refreshOpenPanels()
end

--- Handle player removed from access list
function VehicleClaimClient.onPlayerRemoved(args)
    local playerName = args.removedPlayerName or "Player"
    local player = getPlayer()

    if player then
        player:Say("Removed " .. playerName .. " from vehicle access")
    end

    VehicleClaimClient.refreshOpenPanels()
end

--- Handle access denied notification
function VehicleClaimClient.onAccessDenied(args)
    local action = args.action or "interact with"
    local ownerName = args.ownerName or "another player"
    local player = getPlayer()

    if player then
        player:Say("You cannot " .. action .. " this vehicle. Owner: " .. ownerName)
    end
end

--- Handle vehicle info response (for UI panel)
function VehicleClaimClient.onVehicleInfo(args)
    -- Dispatch to any listening UI panels
    if VehicleClaimClient.pendingInfoCallback then
        VehicleClaimClient.pendingInfoCallback(args)
        VehicleClaimClient.pendingInfoCallback = nil
    end
end

--- Handle my claims response (for vehicle list panel)
function VehicleClaimClient.onMyClaims(args)
    VehicleClaim.log("Received " .. (args.currentCount or 0) .. " claims from server")

    -- Store the claims data for panels to use
    VehicleClaimClient.cachedClaims = args.claims or {}
    VehicleClaimClient.cachedClaimCount = args.currentCount or 0
    VehicleClaimClient.cachedMaxClaims = args.maxClaims or 5

    -- Dispatch to callback if one is pending
    if VehicleClaimClient.pendingClaimsCallback then
        VehicleClaimClient.pendingClaimsCallback(args)
        VehicleClaimClient.pendingClaimsCallback = nil

    end

    -- Refresh all open panels
    VehicleClaimClient.refreshOpenPanels()
end

--- Handle consolidation result (admin command)
function VehicleClaimClient.onConsolidateResult(args)
    local count = args.consolidated or 0
    local message = args.message or "Consolidation complete"
    
    local player = getPlayer()
    if player then
        player:Say(message)
    end
    
    VehicleClaim.log("Consolidation result: " .. count .. " claims")
end
-----------------------------------------------------------
-- Client Request Helpers
-----------------------------------------------------------

--- Request all player's claims from global registry
--- @param callback function Optional callback to receive response
function VehicleClaimClient.requestMyClaims(callback)
    local player = getPlayer()
    if not player then
        return
    end

    if callback then
        VehicleClaimClient.pendingClaimsCallback = callback
    end

    local args = {
        steamID = VehicleClaim.getPlayerSteamID(player)
    }

    sendClientCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_REQUEST_MY_CLAIMS, args)
end

--- Get cached claims (useful for panels)
--- @return table claims, number count, number max
function VehicleClaimClient.getCachedClaims()
    return VehicleClaimClient.cachedClaims or {}, VehicleClaimClient.cachedClaimCount or 0,
        VehicleClaimClient.cachedMaxClaims or 5
end

--- Request vehicle info from server (for UI sync)
--- @param vehicle IsoVehicle
--- @param callback function Callback to receive response
function VehicleClaimClient.requestVehicleInfo(vehicle, callback)
    if not vehicle then
        return
    end

    local player = getPlayer()
    if not player then
        return
    end

    VehicleClaimClient.pendingInfoCallback = callback

    local args = {
        vehicleID = vehicle:getId(),
        steamID = VehicleClaim.getPlayerSteamID(player)
    }

    sendClientCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_REQUEST_INFO, args)
end

--- Request to add a player to vehicle access
--- @param vehicle IsoVehicle
--- @param targetPlayerName string
function VehicleClaimClient.addPlayer(vehicle, targetPlayerName)
    if not vehicle or not targetPlayerName then
        return
    end

    local player = getPlayer()
    if not player then
        return
    end

    local args = {
        vehicleID = vehicle:getId(),
        steamID = VehicleClaim.getPlayerSteamID(player),
        targetPlayerName = targetPlayerName
    }

    sendClientCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_ADD_PLAYER, args)
end

--- Request to remove a player from vehicle access
--- @param vehicle IsoVehicle
--- @param targetSteamID string
function VehicleClaimClient.removePlayer(vehicle, targetSteamID)
    if not vehicle or not targetSteamID then
        return
    end

    local player = getPlayer()
    if not player then
        return
    end

    local args = {
        vehicleID = vehicle:getId(),
        steamID = VehicleClaim.getPlayerSteamID(player),
        targetSteamID = targetSteamID
    }

    sendClientCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_REMOVE_PLAYER, args)
end

-----------------------------------------------------------
-- UI Panel Registry
-----------------------------------------------------------

VehicleClaimClient.openPanels = {}

--- Register an open panel for refresh events
function VehicleClaimClient.registerPanel(panel)
    table.insert(VehicleClaimClient.openPanels, panel)
end

--- Unregister a closed panel
function VehicleClaimClient.unregisterPanel(panel)
    for i = #VehicleClaimClient.openPanels, 1, -1 do
        if VehicleClaimClient.openPanels[i] == panel then
            table.remove(VehicleClaimClient.openPanels, i)
            break
        end
    end
end

--- Refresh all open panels
function VehicleClaimClient.refreshOpenPanels()
    for _, panel in ipairs(VehicleClaimClient.openPanels) do
        if panel and panel.refreshData then
            panel:refreshData()
        end
    end
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnServerCommand.Add(VehicleClaimClient.onServerCommand)

-- Export for use by other client modules
VehicleClaimClientCommands = VehicleClaimClient

return VehicleClaimClient
