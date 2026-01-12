--[[
    VehicleClaim_ServerCommands.lua
    Server-side authoritative command processing
    Validates all requests, enforces ownership, manages modData
]]

require "shared/VehicleClaim_Shared"

local VehicleClaimServer = {}

-----------------------------------------------------------
-- Vehicle Lookup
-----------------------------------------------------------

--- Find a vehicle by ID on the server
--- @param vehicleID number
--- @return IsoVehicle|nil
local function findVehicleByID(vehicleID)
    if not vehicleID then return nil end
    
    local vehicles = getCell():getVehicles()
    if not vehicles then return nil end
    
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        if vehicle and vehicle:getId() == vehicleID then
            return vehicle
        end
    end
    
    return nil
end

--- Find player by Steam ID on the server
--- @param steamID string
--- @return IsoPlayer|nil
local function findPlayerBySteamID(steamID)
    if not steamID then return nil end
    
    local players = getOnlinePlayers()
    if not players then return nil end
    
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then
            local playerSteamID = VehicleClaim.getPlayerSteamID(player)
            if playerSteamID == steamID then
                return player
            end
        end
    end
    
    return nil
end

--- Find player by username on the server
--- @param username string
--- @return IsoPlayer|nil, string|nil steamID
local function findPlayerByName(username)
    if not username then return nil, nil end
    
    local players = getOnlinePlayers()
    if not players then return nil, nil end
    
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and player:getUsername() == username then
            return player, VehicleClaim.getPlayerSteamID(player)
        end
    end
    
    return nil, nil
end

--- Check if player is admin/moderator
--- @param player IsoPlayer
--- @return boolean
local function isAdmin(player)
    if not player then return false end
    local level = player:getAccessLevel()
    return level == "admin" or level == "moderator"
end

-----------------------------------------------------------
-- Global Registry Management
-----------------------------------------------------------

--- Get the global claim registry from server ModData
--- @return table registry (indexed by vehicleID)
local function getGlobalRegistry()
    local globalModData = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    if not globalModData.claims then
        globalModData.claims = {}
    end
    return globalModData.claims
end

--- Add a vehicle to the global registry
--- @param vehicleID number
--- @param ownerSteamID string
--- @param ownerName string
--- @param vehicleName string
--- @param x number
--- @param y number
local function addToGlobalRegistry(vehicleID, ownerSteamID, ownerName, vehicleName, x, y)
    local registry = getGlobalRegistry()
    registry[tostring(vehicleID)] = {
        vehicleID = vehicleID,
        ownerSteamID = ownerSteamID,
        ownerName = ownerName,
        vehicleName = vehicleName,
        x = x,
        y = y,
        claimTime = VehicleClaim.getCurrentTimestamp()
    }
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
end

--- Remove a vehicle from the global registry
--- @param vehicleID number
local function removeFromGlobalRegistry(vehicleID)
    local registry = getGlobalRegistry()
    registry[tostring(vehicleID)] = nil
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
end

--- Update vehicle position in global registry
--- @param vehicleID number
--- @param x number
--- @param y number
local function updateRegistryPosition(vehicleID, x, y)
    local registry = getGlobalRegistry()
    local entry = registry[tostring(vehicleID)]
    if entry then
        entry.x = x
        entry.y = y
        -- Don't transmit on every position update - let it batch
    end
end

--- Get all claims for a specific player from global registry
--- @param steamID string
--- @return table claims
local function getPlayerClaimsFromRegistry(steamID)
    local registry = getGlobalRegistry()
    local playerClaims = {}
    
    for vehicleIDStr, claimData in pairs(registry) do
        if claimData.ownerSteamID == steamID then
            table.insert(playerClaims, claimData)
        end
    end
    
    return playerClaims
end

--- Count claims for a player from global registry (more reliable than scanning loaded vehicles)
--- @param steamID string
--- @return number
local function countPlayerClaimsFromRegistry(steamID)
    local registry = getGlobalRegistry()
    local count = 0
    
    for vehicleIDStr, claimData in pairs(registry) do
        if claimData.ownerSteamID == steamID then
            count = count + 1
        end
    end
    
    return count
end

-----------------------------------------------------------
-- ModData Management
-----------------------------------------------------------

--- Initialize claim data on a vehicle
--- @param vehicle IsoVehicle
--- @param ownerSteamID string
--- @param ownerName string
local function initializeClaimData(vehicle, ownerSteamID, ownerName)
    local modData = vehicle:getModData()
    local vehicleID = vehicle:getId()
    local vehicleName = VehicleClaim.getVehicleName(vehicle)
    
    modData[VehicleClaim.MODDATA_KEY] = {
        [VehicleClaim.OWNER_KEY] = ownerSteamID,
        [VehicleClaim.OWNER_NAME_KEY] = ownerName,
        [VehicleClaim.ALLOWED_PLAYERS_KEY] = {},
        [VehicleClaim.CLAIM_TIME_KEY] = VehicleClaim.getCurrentTimestamp(),
        [VehicleClaim.LAST_SEEN_KEY] = VehicleClaim.getCurrentTimestamp()
    }
    
    -- Add to global registry
    addToGlobalRegistry(vehicleID, ownerSteamID, ownerName, vehicleName, vehicle:getX(), vehicle:getY())
    
    -- Sync to all clients
    vehicle:transmitModData()
end

--- Clear claim data from a vehicle
--- @param vehicle IsoVehicle
local function clearClaimData(vehicle)
    local modData = vehicle:getModData()
    local vehicleID = vehicle:getId()
    
    modData[VehicleClaim.MODDATA_KEY] = nil
    
    -- Remove from global registry
    removeFromGlobalRegistry(vehicleID)
    
    vehicle:transmitModData()
end

--- Update last seen timestamp
--- @param vehicle IsoVehicle
local function updateLastSeen(vehicle)
    local claimData = VehicleClaim.getClaimData(vehicle)
    if claimData then
        claimData[VehicleClaim.LAST_SEEN_KEY] = VehicleClaim.getCurrentTimestamp()
        -- Also update position in registry
        updateRegistryPosition(vehicle:getId(), vehicle:getX(), vehicle:getY())
        vehicle:transmitModData()
    end
end

-----------------------------------------------------------
-- Command Handlers
-----------------------------------------------------------

--- Handle claim vehicle request
--- @param player IsoPlayer
--- @param args table
local function handleClaimVehicle(player, args)
    local vehicleID = args.vehicleID
    local steamID = args.steamID
    local playerName = args.playerName
    
    -- Defensive validation
    if not vehicleID or not steamID then
        VehicleClaim.log("Claim rejected: missing parameters")
        return
    end
    
    -- Verify steamID matches the requesting player
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Claim rejected: steamID mismatch")
        return
    end
    
    -- Find vehicle
    local vehicle = findVehicleByID(vehicleID)
    if not vehicle then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_FOUND
        })
        return
    end
    
    -- Check proximity
    if not VehicleClaim.isWithinRange(player, vehicle) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_TOO_FAR
        })
        return
    end
    
    -- Check if already claimed
    if VehicleClaim.isClaimed(vehicle) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_ALREADY_CLAIMED,
            ownerName = VehicleClaim.getOwnerName(vehicle)
        })
        return
    end
    
    -- Check claim limit (use registry for accurate count)
    local currentClaims = countPlayerClaimsFromRegistry(steamID)
    local maxClaims = VehicleClaim.getMaxClaimsPerPlayer()
    
    if currentClaims >= maxClaims then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_CLAIM_LIMIT_REACHED,
            currentClaims = currentClaims,
            maxClaims = maxClaims
        })
        return
    end
    
    -- All validations passed - create claim
    initializeClaimData(vehicle, steamID, playerName or player:getUsername())
    
    local vehicleName = VehicleClaim.getVehicleName(vehicle)
    VehicleClaim.log("Vehicle claimed: " .. vehicleName .. " by " .. playerName)
    
    -- Notify client
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_SUCCESS, {
        vehicleID = vehicleID,
        vehicleName = vehicleName
    })
end

--- Handle release claim request
--- @param player IsoPlayer
--- @param args table
local function handleReleaseClaim(player, args)
    local vehicleID = args.vehicleID
    local steamID = args.steamID
    
    if not vehicleID or not steamID then
        VehicleClaim.log("Release rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Release rejected: steamID mismatch")
        return
    end
    
    local vehicle = findVehicleByID(vehicleID)
    if not vehicle then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_FOUND
        })
        return
    end
    
    -- Check ownership (or admin override)
    local ownerID = VehicleClaim.getOwnerID(vehicle)
    if ownerID ~= steamID and not isAdmin(player) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        return
    end
    
    local vehicleName = VehicleClaim.getVehicleName(vehicle)
    
    -- Clear claim
    clearClaimData(vehicle)
    
    VehicleClaim.log("Vehicle released: " .. vehicleName .. " by " .. player:getUsername())
    
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_RELEASE_SUCCESS, {
        vehicleID = vehicleID,
        vehicleName = vehicleName
    })
end

--- Handle add allowed player request
--- @param player IsoPlayer
--- @param args table
local function handleAddPlayer(player, args)
    local vehicleID = args.vehicleID
    local steamID = args.steamID
    local targetPlayerName = args.targetPlayerName
    
    if not vehicleID or not steamID or not targetPlayerName then
        VehicleClaim.log("Add player rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        return
    end
    
    local vehicle = findVehicleByID(vehicleID)
    if not vehicle then
        return
    end
    
    -- Check ownership
    local ownerID = VehicleClaim.getOwnerID(vehicle)
    if ownerID ~= steamID and not isAdmin(player) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        return
    end
    
    -- Find target player
    local targetPlayer, targetSteamID = findPlayerByName(targetPlayerName)
    if not targetPlayer or not targetSteamID then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_PLAYER_NOT_FOUND
        })
        return
    end
    
    -- Add to allowed list
    local claimData = VehicleClaim.getClaimData(vehicle)
    if claimData then
        if not claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] then
            claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] = {}
        end
        claimData[VehicleClaim.ALLOWED_PLAYERS_KEY][targetSteamID] = targetPlayerName
        vehicle:transmitModData()
        
        VehicleClaim.log("Added " .. targetPlayerName .. " to vehicle access")
        
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_ADDED, {
            vehicleID = vehicleID,
            addedSteamID = targetSteamID,
            addedPlayerName = targetPlayerName
        })
    end
end

--- Handle remove allowed player request
--- @param player IsoPlayer
--- @param args table
local function handleRemovePlayer(player, args)
    local vehicleID = args.vehicleID
    local steamID = args.steamID
    local targetSteamID = args.targetSteamID
    
    if not vehicleID or not steamID or not targetSteamID then
        VehicleClaim.log("Remove player rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        return
    end
    
    local vehicle = findVehicleByID(vehicleID)
    if not vehicle then
        return
    end
    
    -- Check ownership
    local ownerID = VehicleClaim.getOwnerID(vehicle)
    if ownerID ~= steamID and not isAdmin(player) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        return
    end
    
    -- Remove from allowed list
    local claimData = VehicleClaim.getClaimData(vehicle)
    if claimData and claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] then
        local removedName = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY][targetSteamID] or "Player"
        claimData[VehicleClaim.ALLOWED_PLAYERS_KEY][targetSteamID] = nil
        vehicle:transmitModData()
        
        VehicleClaim.log("Removed " .. removedName .. " from vehicle access")
        
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_REMOVED, {
            vehicleID = vehicleID,
            removedSteamID = targetSteamID,
            removedPlayerName = removedName
        })
    end
end

--- Handle vehicle info request
--- @param player IsoPlayer
--- @param args table
local function handleRequestInfo(player, args)
    local vehicleID = args.vehicleID
    
    if not vehicleID then return end
    
    local vehicle = findVehicleByID(vehicleID)
    if not vehicle then return end
    
    local claimData = VehicleClaim.getClaimData(vehicle)
    local info = {
        vehicleID = vehicleID,
        vehicleName = VehicleClaim.getVehicleName(vehicle),
        isClaimed = VehicleClaim.isClaimed(vehicle)
    }
    
    if claimData then
        info.ownerSteamID = claimData[VehicleClaim.OWNER_KEY]
        info.ownerName = claimData[VehicleClaim.OWNER_NAME_KEY]
        info.allowedPlayers = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
        info.claimTime = claimData[VehicleClaim.CLAIM_TIME_KEY]
        info.lastSeen = claimData[VehicleClaim.LAST_SEEN_KEY]
    end
    
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_VEHICLE_INFO, info)
end

--- Handle request for all player's claims (from global registry)
--- @param player IsoPlayer
--- @param args table
local function handleRequestMyClaims(player, args)
    local steamID = args.steamID
    
    if not steamID then
        VehicleClaim.log("RequestMyClaims rejected: missing steamID")
        return
    end
    
    -- Verify steamID matches requesting player
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("RequestMyClaims rejected: steamID mismatch")
        return
    end
    
    -- Get claims from global registry
    local claims = getPlayerClaimsFromRegistry(steamID)
    local maxClaims = VehicleClaim.getMaxClaimsPerPlayer()
    
    VehicleClaim.log("Sending " .. #claims .. " claims to " .. player:getUsername())
    
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_MY_CLAIMS, {
        claims = claims,
        currentCount = #claims,
        maxClaims = maxClaims
    })
end

-----------------------------------------------------------
-- Client Command Router
-----------------------------------------------------------

--- Main command router for client requests
--- @param module string
--- @param command string
--- @param player IsoPlayer
--- @param args table
function VehicleClaimServer.onClientCommand(module, command, player, args)
    if module ~= VehicleClaim.COMMAND_MODULE then return end
    
    VehicleClaim.log("Server received command: " .. tostring(command) .. " from " .. tostring(player:getUsername()))
    
    if command == VehicleClaim.CMD_CLAIM then
        handleClaimVehicle(player, args)
        
    elseif command == VehicleClaim.CMD_RELEASE then
        handleReleaseClaim(player, args)
        
    elseif command == VehicleClaim.CMD_ADD_PLAYER then
        handleAddPlayer(player, args)
        
    elseif command == VehicleClaim.CMD_REMOVE_PLAYER then
        handleRemovePlayer(player, args)
        
    elseif command == VehicleClaim.CMD_REQUEST_INFO then
        handleRequestInfo(player, args)
        
    elseif command == VehicleClaim.CMD_REQUEST_MY_CLAIMS then
        handleRequestMyClaims(player, args)
    end
end

-----------------------------------------------------------
-- Vehicle Interaction Enforcement
-----------------------------------------------------------

--- Block unauthorized vehicle entry
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @param seat number
function VehicleClaimServer.onEnterVehicle(player, vehicle, seat)
    if not player or not vehicle then return end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    
    -- Check access
    if not VehicleClaim.hasAccess(vehicle, steamID) and not isAdmin(player) then
        -- Force exit (server-side enforcement)
        player:setVehicle(nil)
        
        local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
            action = "enter",
            ownerName = ownerName
        })
        
        VehicleClaim.log("Blocked " .. player:getUsername() .. " from entering vehicle owned by " .. ownerName)
        return false
    end
    
    -- Update last seen for owner
    updateLastSeen(vehicle)
    return true
end

--- Block unauthorized vehicle mechanics/interaction
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @param part VehiclePart
function VehicleClaimServer.onMechanicsAction(player, vehicle, part)
    if not player or not vehicle then return true end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    
    if not VehicleClaim.hasAccess(vehicle, steamID) and not isAdmin(player) then
        local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
            action = "repair",
            ownerName = ownerName
        })
        return false
    end
    
    return true
end

--- Validate timed actions against claimed vehicles
--- @param action ISBaseTimedAction
function VehicleClaimServer.onTimedActionValidate(action)
    -- Check if this action involves a vehicle
    if not action or not action.vehicle then return end
    
    local player = action.character
    if not player then return end
    
    local vehicle = action.vehicle
    local steamID = VehicleClaim.getPlayerSteamID(player)
    
    if not VehicleClaim.hasAccess(vehicle, steamID) and not isAdmin(player) then
        -- Cancel the action
        action:forceStop()
        
        local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
            action = "interact with",
            ownerName = ownerName
        })
    end
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnClientCommand.Add(VehicleClaimServer.onClientCommand)

-- Vehicle entry hook
local originalOnEnterVehicle = Events.OnEnterVehicle
if Events.OnEnterVehicle then
    Events.OnEnterVehicle.Add(function(player)
        local vehicle = player:getVehicle()
        if vehicle then
            VehicleClaimServer.onEnterVehicle(player, vehicle, 0)
        end
    end)
end

return VehicleClaimServer
