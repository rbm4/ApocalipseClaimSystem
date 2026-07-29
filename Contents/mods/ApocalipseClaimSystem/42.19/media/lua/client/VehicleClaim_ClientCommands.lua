--[[
    VehicleClaim_ClientCommands.lua
    Client-side command handler for server responses
    Processes server confirmations and updates local state
]] require "shared/VehicleClaim_Shared"

local VehicleClaimClient = {}

-----------------------------------------------------------
-- Custom Events
-----------------------------------------------------------
-- These events fire when claim data changes
-- Components can listen to these for reactive updates
LuaEventManager.AddEvent("OnVehicleClaimSuccess")
LuaEventManager.AddEvent("OnVehicleClaimChanged")
LuaEventManager.AddEvent("OnVehicleClaimReleased")
LuaEventManager.AddEvent("OnVehicleClaimAccessChanged")
LuaEventManager.AddEvent("OnVehicleInfoReceived")
LuaEventManager.AddEvent("OnVehicleHashGenerated")

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
        
    elseif command == VehicleClaim.RESP_ADMIN_CLEAR_ALL_SUCCESS then
        VehicleClaimClient.onAdminClearAllSuccess(args)

    elseif command == VehicleClaim.RESP_SYNC_VEHICLE_MODDATA then
        VehicleClaimClient.onSyncVehicleModData(args)

    elseif command == VehicleClaim.RESP_VEHICLE_HASH then
        VehicleClaimClient.onVehicleHash(args)
    end
end

--- Handle successful claim
function VehicleClaimClient.onClaimSuccess(args)
    local vehicleHash = args.vehicleHash or "Unknown"
    local player = getPlayer()

    print("[VehicleClaim] onClaimSuccess - vehicleHash: " .. tostring(vehicleHash))

    -- Show notification to player
    if player then
        player:Say(getText("UI_VehicleClaim_SuccessfullyClaimed", tostring(vehicleHash)))
    end

    -- Trigger events for reactive components
    -- Server has already transmitted ModData, UI components will read it directly
    if vehicleHash and vehicleHash ~= "Unknown" then
        local claimData = args.claimData
        triggerEvent("OnVehicleClaimChanged", vehicleHash, claimData)
    end
end

--- Handle failed claim attempt
function VehicleClaimClient.onClaimFailed(args)
    local reason = args.reason or "Unknown error"
    local player = getPlayer()

    -- Clear pending action for all vehicles (we don't know which one failed)
    -- This is safe because claim failures are immediate
    for hash, action in pairs(VehicleClaim.pendingActions) do
        if action == "CLAIM" then
            VehicleClaim.pendingActions[hash] = nil
        end
    end

    local message = getText("UI_VehicleClaim_ClaimFailedPrefix")

    if reason == VehicleClaim.ERR_ALREADY_CLAIMED then
        message = message .. getText("UI_VehicleClaim_VehicleIsAlreadyClaimed")
    elseif reason == VehicleClaim.ERR_VEHICLE_NOT_FOUND then
        message = message .. getText("UI_VehicleClaim_VehicleNotFoundError")
    elseif reason == VehicleClaim.ERR_TOO_FAR then
        message = message .. getText("UI_VehicleClaim_TooFarFromVehicle")
    elseif reason == VehicleClaim.ERR_CLAIM_LIMIT_REACHED then
        local current = args.currentClaims or 0
        local max = args.maxClaims or 0
        message = getText("UI_VehicleClaim_ClaimLimitReachedFormat", tostring(current), tostring(max))
    elseif reason == VehicleClaim.ERR_VEHICLE_NOT_LOADED then
        message = message .. getText("UI_VehicleClaim_VehicleNotLoadedError")
    elseif reason == VehicleClaim.ERR_VEHICLE_NOT_CLAIMED then
        message = message .. getText("UI_VehicleClaim_VehicleNotClaimedError")
    elseif reason == VehicleClaim.ERR_INIT_FAILED then
        message = message .. getText("UI_VehicleClaim_InitializationFailedError")
    elseif reason == VehicleClaim.ERR_PLAYER_NOT_FOUND then
        message = message .. getText("UI_VehicleClaim_PlayerNotFound")
    elseif reason == "vehicleNotAbandoned" then
        local daysRequired = args.daysRequired or 7
        local daysSince = args.daysSinceLastSeen or 0
        local daysRemaining = math.max(0, daysRequired - daysSince)
        message = getText("UI_VehicleClaim_VehicleNotAbandoned", tostring(daysRemaining))
    elseif reason == "cannotContestOwnVehicle" then
        message = "Cannot contest your own vehicle. Use the release button instead."
    else
        message = message .. reason
    end

    if player then
        player:Say(message)
    end
end

--- Handle successful release
function VehicleClaimClient.onReleaseSuccess(args)
    local vehicleHash = args.vehicleHash or "Unknown"
    local contested = args.contested or false
    local player = getPlayer()

    if player then
        if contested then
            player:Say(getText("UI_VehicleClaim_ClaimContested"))
        else
            player:Say(getText("UI_VehicleClaim_ReleasedClaimOnVehicle", tostring(vehicleHash)))
        end
    end

    -- Trigger event for reactive components
    -- Server has already cleared ModData
    if vehicleHash and vehicleHash ~= "Unknown" then
        triggerEvent("OnVehicleClaimReleased", vehicleHash, nil)
    end

    -- Close mechanics UI if open
    if ISVehicleMechanics and ISVehicleMechanics.instance then
        ISVehicleMechanics.instance:close()
    end

    VehicleClaimClient.refreshOpenPanels()
end

--- Handle player added to access list
function VehicleClaimClient.onPlayerAdded(args)
    local playerName = args.addedPlayerName or "Player"
    local vehicleHash = args.vehicleHash
    local player = getPlayer()

    if player then
        player:Say("Added " .. playerName .. " to vehicle access")
    end

    -- Trigger event for reactive components
    -- Server has already transmitted updated ModData
    if vehicleHash then
        local claimData = args.claimData
        triggerEvent("OnVehicleClaimAccessChanged", vehicleHash, claimData)
    end

    VehicleClaimClient.refreshOpenPanels()
end

--- Handle player removed from access list
function VehicleClaimClient.onPlayerRemoved(args)
    local playerName = args.removedPlayerName or "Player"
    local vehicleHash = args.vehicleHash
    local player = getPlayer()

    if player then
        player:Say("Removed " .. playerName .. " from vehicle access")
    end

    -- Trigger event for reactive components
    -- Server has already transmitted updated ModData
    if vehicleHash then
        local claimData = args.claimData
        triggerEvent("OnVehicleClaimAccessChanged", vehicleHash, claimData)
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

--- Handle vehicle info response (DEPRECATED - clients now read ModData directly)
function VehicleClaimClient.onVehicleInfo(args)
    -- This is kept for backwards compatibility but should not be used
    -- Clients should read vehicle ModData directly instead of requesting info
    VehicleClaim.log("onVehicleInfo called (deprecated - read ModData directly)")
    
    local vehicleHash = args.vehicleHash
    
    -- Trigger event for backwards compatibility
    if vehicleHash then
        local claimData = args.claimData
        triggerEvent("OnVehicleInfoReceived", vehicleHash, claimData)
    end
    
    -- Dispatch to any listening UI panels (legacy callback support)
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

--- Handle admin clear all success response
function VehicleClaimClient.onAdminClearAllSuccess(args)
    local player = getPlayer()
    local clearedClaims = args.clearedClaims or 0
    local clearedVehicles = args.clearedVehicles or 0
    local affectedPlayers = args.affectedPlayers or 0
    
    local message = string.format(
        "[ADMIN] All claims cleared successfully!\nClaims removed: %d\nVehicles cleared: %d\nPlayers affected: %d",
        clearedClaims, clearedVehicles, affectedPlayers
    )
    
    if player then
        player:Say(message)
    end
    
    print("[VehicleClaim Admin] Clear all operation completed:")
    print("  - Claims removed: " .. clearedClaims)
    print("  - Vehicles cleared: " .. clearedVehicles)
    print("  - Players affected: " .. affectedPlayers)
    
    -- Refresh any open panels
    VehicleClaimClient.refreshOpenPanels()
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

--- Request vehicle info from server (DEPRECATED - clients should read ModData directly)
--- @param vehicle IsoVehicle
--- @param callback function Callback to receive response
function VehicleClaimClient.requestVehicleInfo(vehicle, callback)
    -- This function is deprecated - clients should read vehicle ModData directly
    -- Kept for backwards compatibility only
    VehicleClaim.log("requestVehicleInfo called (deprecated - read ModData directly)")
    
    if callback and vehicle then
        -- Just call callback with ModData
        local claimData = VehicleClaim.getClaimData(vehicle)
        local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
        callback({
            vehicleHash = vehicleHash,
            claimData = claimData
        })
    end
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

    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get vehicle hash for add player")
        return
    end
    
    local args = {
        vehicleHash = vehicleHash,
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

    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get vehicle hash for remove player")
        return
    end
    
    local args = {
        vehicleHash = vehicleHash,
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
    print("[VehicleClaim] refreshOpenPanels called")
    
    for _, panel in ipairs(VehicleClaimClient.openPanels) do
        if panel and panel.refreshData then
            panel:refreshData()
        end
    end
    
end

-----------------------------------------------------------
-- Vehicle ModData Sync Handler
-----------------------------------------------------------

--- Find a vehicle on the client by its hash
--- @param vehicleHash string
--- @return IsoVehicle|nil
local function findLocalVehicleByHash(vehicleHash)
    if not vehicleHash then
        return nil
    end

    local cell = getCell()
    if not cell then
        return nil
    end

    local vehicles = cell:getVehicles()
    if not vehicles then
        return nil
    end

    local iterator = vehicles:iterator()
    while iterator:hasNext() do
        local vehicle = iterator:next()
        if vehicle then
            local hash = VehicleClaim.getVehicleHash(vehicle)
            if hash == vehicleHash then
                return vehicle
            end
        end
    end

    return nil
end

--- Handle server broadcast of vehicle modData changes
--- Updates the local vehicle's modData so enforcement and UI reflect changes instantly
function VehicleClaimClient.onSyncVehicleModData(args)
    local vehicleHash = args.vehicleHash
    if not vehicleHash then
        return
    end

    local vehicle = findLocalVehicleByHash(vehicleHash)
    if not vehicle and args.vehicleTempId then
        -- Hash not synced yet on this client - try finding by vehicle ID
        local cell = getCell()
        if cell then
            local vehicles = cell:getVehicles()
            if vehicles then
                local iterator = vehicles:iterator()
                while iterator:hasNext() do
                    local v = iterator:next()
                    if v and v:getId() == args.vehicleTempId then
                        vehicle = v
                        break
                    end
                end
            end
        end
    end
    if not vehicle then
        -- Vehicle not loaded on this client - ignore silently
        -- When vehicle loads later, server's onVehicleCreated sync will handle it
        return
    end

    local modData = vehicle:getModData()

    -- Update vehicle hash key if provided
    if args.vehicleHashKey then
        modData[VehicleClaim.VEHICLE_HASH_KEY] = args.vehicleHashKey
    end

    -- Update claim data (nil means unclaimed)
    local previousClaimData = modData[VehicleClaim.MODDATA_KEY]
    if args.claimData then
        modData[VehicleClaim.MODDATA_KEY] = args.claimData
    else
        modData[VehicleClaim.MODDATA_KEY] = nil
    end

    -- Fire appropriate event so UI components refresh
    if args.claimData then
        triggerEvent("OnVehicleClaimChanged", vehicleHash, args.claimData)
    elseif previousClaimData then
        triggerEvent("OnVehicleClaimReleased", vehicleHash, nil)
    elseif args.vehicleHashKey then
        -- Hash was synced but no claim data changed - notify UI panels
        triggerEvent("OnVehicleHashGenerated", vehicleHash, vehicle)
    end
end

--- Handle server response with a generated vehicle hash
--- Finds the local vehicle by position and stores the hash in its modData
function VehicleClaimClient.onVehicleHash(args)
    local vehicleHash = args.vehicleHash
    local vehicleX = args.vehicleX
    local vehicleY = args.vehicleY

    if not vehicleHash or not vehicleX or not vehicleY then
        return
    end

    local cell = getCell()
    if not cell then
        return
    end

    local vehicles = cell:getVehicles()
    if not vehicles then
        return
    end

    -- Find the local vehicle by position
    local bestVehicle = nil
    local bestDist = 2.0

    local iterator = vehicles:iterator()
    while iterator:hasNext() do
        local vehicle = iterator:next()
        if vehicle then
            local dx = vehicle:getX() - vehicleX
            local dy = vehicle:getY() - vehicleY
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < bestDist then
                bestDist = dist
                bestVehicle = vehicle
            end
        end
    end

    if bestVehicle then
        local modData = bestVehicle:getModData()
        modData[VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
        VehicleClaim.log("Received vehicle hash: " .. vehicleHash)
        triggerEvent("OnVehicleHashGenerated", vehicleHash, bestVehicle)
    end
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnServerCommand.Add(VehicleClaimClient.onServerCommand)

-- Export for use by other client modules
VehicleClaimClientCommands = VehicleClaimClient

return VehicleClaimClient
