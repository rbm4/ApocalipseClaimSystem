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

--- Find a vehicle by hash on the server
--- @param vehicleHash string Vehicle hash from ModData
--- @return IsoVehicle|nil
local function findVehicleByHash(vehicleHash)
    if not vehicleHash then return nil end
    
    local vehicles = getCell():getVehicles()
    if not vehicles then return nil end
    
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        if vehicle then
            local hash = VehicleClaim.getVehicleHash(vehicle)
            if hash == vehicleHash then
                return vehicle
            end
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
--- Registry is indexed by vehicle hash (stored in vehicle ModData) for persistence
--- @return table registry (indexed by vehicleHash)
local function getGlobalRegistry()
    local globalModData = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    if not globalModData.claims then
        globalModData.claims = {}
    end
    return globalModData.claims
end

--- Add a vehicle to the global registry
--- @param vehicleHash string Vehicle hash from ModData
--- @param ownerSteamID string
--- @param ownerName string
--- @param x number
--- @param y number
local function addToGlobalRegistry(vehicleHash, ownerSteamID, ownerName, x, y)
    local registry = getGlobalRegistry()
    registry[vehicleHash] = {
        vehicleHash = vehicleHash,
        ownerSteamID = ownerSteamID,
        ownerName = ownerName,
        x = x,
        y = y,
        claimTime = VehicleClaim.getCurrentTimestamp()
    }
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
end

--- Remove a vehicle from the global registry
--- @param vehicleHash string
local function removeFromGlobalRegistry(vehicleHash)
    local registry = getGlobalRegistry()
    registry[vehicleHash] = nil
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
end

--- Update vehicle position in global registry
--- @param vehicleHash string
--- @param x number
--- @param y number
local function updateRegistryPosition(vehicleHash, x, y)
    local registry = getGlobalRegistry()
    local entry = registry[vehicleHash]
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
    
    for vehicleHash, claimData in pairs(registry) do
        if claimData.ownerSteamID == steamID then
            -- Create a copy of the claim data
            local claimEntry = {
                vehicleHash = claimData.vehicleHash,
                ownerSteamID = claimData.ownerSteamID,
                ownerName = claimData.ownerName,
                x = claimData.x,
                y = claimData.y,
                claimTime = claimData.claimTime,
                lastSeen = claimData.lastSeen,
                allowedPlayers = {}
            }
            
            -- Try to get allowed players from the loaded vehicle if available
            local vehicle = findVehicleByHash(claimData.vehicleHash)
            if vehicle then
                local vehicleClaimData = VehicleClaim.getClaimData(vehicle)
                if vehicleClaimData then
                    claimEntry.allowedPlayers = vehicleClaimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
                end
            end
            
            table.insert(playerClaims, claimEntry)
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
    
    for vehicleHash, claimData in pairs(registry) do
        if claimData.ownerSteamID == steamID then
            count = count + 1
        end
    end
    
    return count
end

-----------------------------------------------------------
-- ModData Management
-----------------------------------------------------------

--- Initialize claim data on a vehicle (writes to both ModData and registry)
--- @param vehicle IsoVehicle
--- @param ownerSteamID string
--- @param ownerName string
--- @return table|nil claimData, string|nil vehicleHash
local function initializeClaimData(vehicle, ownerSteamID, ownerName)
    local modData = vehicle:getModData()
    
    -- Get or create vehicle hash
    local vehicleHash = VehicleClaim.getOrCreateVehicleHash(vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get/create vehicle hash")
        return nil, nil
    end
    
    -- Create claim data
    local claimData = {
        [VehicleClaim.OWNER_KEY] = ownerSteamID,
        [VehicleClaim.OWNER_NAME_KEY] = ownerName,
        [VehicleClaim.ALLOWED_PLAYERS_KEY] = {},
        [VehicleClaim.CLAIM_TIME_KEY] = VehicleClaim.getCurrentTimestamp(),
        [VehicleClaim.LAST_SEEN_KEY] = VehicleClaim.getCurrentTimestamp(),
        [VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
    }
    
    -- Write to ModData (source of truth for access checks)
    modData[VehicleClaim.MODDATA_KEY] = claimData
    vehicle:transmitModData()
    
    -- Also add to global registry (for tracking when vehicle is unloaded)
    addToGlobalRegistry(vehicleHash, ownerSteamID, ownerName, vehicle:getX(), vehicle:getY())
    
    -- Return claimData and hash so caller can send response
    return claimData, vehicleHash
end

--- Clear claim data from a vehicle (removes from both ModData and registry)
--- @param vehicle IsoVehicle
local function clearClaimData(vehicle)
    if not vehicle then return end
    
    -- Get hash and remove from registry
    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    if vehicleHash then
        removeFromGlobalRegistry(vehicleHash)
        VehicleClaim.log("Removed claim from registry: " .. vehicleHash)
    end
    
    -- Clear ModData
    local modData = vehicle:getModData()
    modData[VehicleClaim.MODDATA_KEY] = nil
    vehicle:transmitModData()
    VehicleClaim.log("Cleared ModData for vehicle: " .. tostring(vehicleHash))
end

--- Update last seen timestamp
--- @param vehicle IsoVehicle
local function updateLastSeen(vehicle)
    local claimData = VehicleClaim.getClaimData(vehicle)
    if claimData then
        claimData[VehicleClaim.LAST_SEEN_KEY] = VehicleClaim.getCurrentTimestamp()
        -- Also update position in registry
        local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
        if vehicleHash then
            updateRegistryPosition(vehicleHash, vehicle:getX(), vehicle:getY())
        end
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
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID
    local playerName = args.playerName
    
    -- Defensive validation
    if not vehicleHash or not steamID then
        VehicleClaim.log("Claim rejected: missing parameters")
        return
    end
    
    -- Verify steamID matches the requesting player
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Claim rejected: steamID mismatch")
        return
    end
    
    -- Find vehicle by hash
    local vehicle = findVehicleByHash(vehicleHash)
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
    
    -- Check if already claimed by reading ModData
    local existingClaimData = VehicleClaim.getClaimData(vehicle)
    if existingClaimData and existingClaimData[VehicleClaim.OWNER_KEY] then
        -- Vehicle is already claimed
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_ALREADY_CLAIMED,
            ownerName = existingClaimData[VehicleClaim.OWNER_NAME_KEY] or "Unknown"
        })
        VehicleClaim.log("Claim rejected: Vehicle hash " .. vehicleHash .. " already claimed by " .. (existingClaimData[VehicleClaim.OWNER_NAME_KEY] or "Unknown"))
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
    local claimData, claimVehicleHash = initializeClaimData(vehicle, steamID, playerName or player:getUsername())
    
    if claimData and claimVehicleHash then
        VehicleClaim.log("Vehicle claimed: Hash " .. claimVehicleHash .. " by " .. playerName)
        
        -- Notify client with claim data
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_SUCCESS, {
            vehicleHash = claimVehicleHash,
            claimData = claimData
        })
    else
        VehicleClaim.log("ERROR: Failed to initialize claim data")
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = "Failed to initialize claim"
        })
    end
end

--- Handle release claim request
--- @param player IsoPlayer
--- @param args table
local function handleReleaseClaim(player, args)
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID
    
    if not vehicleHash or not steamID then
        VehicleClaim.log("Release rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Release rejected: steamID mismatch")
        return
    end
    
    -- Check global registry to verify ownership
    local registry = getGlobalRegistry()
    local registryEntry = registry[vehicleHash]
    
    if not registryEntry then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_FOUND
        })
        return
    end
    
    if registryEntry.ownerSteamID ~= steamID and not isAdmin(player) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        return
    end
    
    -- Find vehicle to check proximity (REQUIRED - must be near vehicle to unclaim)
    local vehicle = findVehicleByHash(vehicleHash)
    if not vehicle then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = "Vehicle not loaded. You must be near the vehicle to release the claim."
        })
        VehicleClaim.log("Release rejected: Vehicle not loaded (player must be nearby)")
        return
    end
    
    -- Check proximity (REQUIRED - ensures vehicle ModData can be cleared)
    if not VehicleClaim.isWithinRange(player, vehicle) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_TOO_FAR
        })
        VehicleClaim.log("Release rejected: Player too far from vehicle")
        return
    end
    
    -- Remove from both registry and ModData
    removeFromGlobalRegistry(vehicleHash)
    VehicleClaim.log("Vehicle released: Hash " .. vehicleHash .. " by " .. player:getUsername())
    
    -- Clear ModData (vehicle is loaded and player is nearby)
    local modData = vehicle:getModData()
    modData[VehicleClaim.MODDATA_KEY] = nil
    vehicle:transmitModData()
    VehicleClaim.log("Cleared ModData for vehicle: " .. vehicleHash)
    
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_RELEASE_SUCCESS, {
        vehicleHash = vehicleHash
    })
end

--- Handle add allowed player request
--- @param player IsoPlayer
--- @param args table
local function handleAddPlayer(player, args)
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID
    local targetPlayerName = args.targetPlayerName
    
    if not vehicleHash or not steamID or not targetPlayerName then
        VehicleClaim.log("Add player rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        return
    end
    
    local vehicle = findVehicleByHash(vehicleHash)
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
        
        -- Send back full claimData so UI can refresh
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_ADDED, {
            vehicleHash = vehicleHash,
            addedSteamID = targetSteamID,
            addedPlayerName = targetPlayerName,
            claimData = claimData  -- Include full claim data for UI update
        })
    end
end

--- Handle remove allowed player request
--- @param player IsoPlayer
--- @param args table
local function handleRemovePlayer(player, args)
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID
    local targetSteamID = args.targetSteamID
    
    if not vehicleHash or not steamID or not targetSteamID then
        VehicleClaim.log("Remove player rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        return
    end
    
    local vehicle = findVehicleByHash(vehicleHash)
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
        
        -- Send back full claimData so UI can refresh
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_REMOVED, {
            vehicleHash = vehicleHash,
            removedSteamID = targetSteamID,
            removedPlayerName = removedName,
            claimData = claimData  -- Include full claim data for UI update
        })
    end
end

--- Handle vehicle info request - REMOVED (clients read ModData directly)
--- This function is kept for backwards compatibility but returns minimal data
--- @param player IsoPlayer
--- @param args table
local function handleRequestInfo(player, args)
    -- No longer needed - clients read ModData directly
    -- Kept for backwards compatibility only
    VehicleClaim.log("RequestInfo called (deprecated - clients should read ModData directly)")
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

--- Handle admin request to clear all claims
--- @param player IsoPlayer
--- @param args table
local function handleAdminClearAllClaims(player, args)
    -- Only admins can clear all claims
    if not isAdmin(player) then
        VehicleClaim.log("[ADMIN] Clear all claims rejected: player " .. player:getUsername() .. " is not admin")
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_ADMIN
        })
        return
    end
    
    VehicleClaim.log("[ADMIN] " .. player:getUsername() .. " initiated CLEAR ALL CLAIMS command")
    
    -- Get current registry statistics before clearing
    local registry = getGlobalRegistry()
    local claimCount = 0
    local ownerCount = {}
    
    for vehicleHash, claimData in pairs(registry) do
        claimCount = claimCount + 1
        ownerCount[claimData.ownerSteamID] = (ownerCount[claimData.ownerSteamID] or 0) + 1
    end
    
    local uniqueOwners = 0
    for _ in pairs(ownerCount) do
        uniqueOwners = uniqueOwners + 1
    end
    
    VehicleClaim.log("[ADMIN] Clearing " .. claimCount .. " claims from " .. uniqueOwners .. " players")
    
    -- Clear all vehicle ModData
    local vehiclesCleared = 0
    local vehicles = getCell():getVehicles()
    if vehicles then
        for i = 0, vehicles:size() - 1 do
            local vehicle = vehicles:get(i)
            if vehicle then
                local modData = vehicle:getModData()
                if modData[VehicleClaim.MODDATA_KEY] then
                    modData[VehicleClaim.MODDATA_KEY] = nil
                    vehicle:transmitModData()
                    vehiclesCleared = vehiclesCleared + 1
                end
            end
        end
    end
    
    VehicleClaim.log("[ADMIN] Cleared ModData from " .. vehiclesCleared .. " vehicles")
    
    -- Clear the entire registry
    local globalModData = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    globalModData.claims = {}
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
    
    VehicleClaim.log("[ADMIN] Registry cleared. All claims removed.")
    VehicleClaim.log("[ADMIN] Clear all claims operation completed successfully by " .. player:getUsername())
    
    -- Notify admin of success
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ADMIN_CLEAR_ALL_SUCCESS, {
        clearedClaims = claimCount,
        clearedVehicles = vehiclesCleared,
        affectedPlayers = uniqueOwners
    })
end

--- Handle admin request to consolidate claims
--- @param player IsoPlayer
--- @param args table
local function handleConsolidateClaims(player, args)
    -- Only admins can trigger manual consolidation
    if not isAdmin(player) then
        VehicleClaim.log("ConsolidateClaims rejected: player is not admin")
        return
    end
    
    VehicleClaim.log("Admin " .. player:getUsername() .. " triggered manual claim consolidation")
    
    local count = consolidateClaimsToRegistry()
    
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CONSOLIDATE_RESULT, {
        consolidated = count,
        message = "Consolidated " .. count .. " claims into global registry"
    })
    
    VehicleClaim.log("Manual consolidation completed: " .. count .. " claims")
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
        
    elseif command == VehicleClaim.CMD_CONSOLIDATE_CLAIMS then
        handleConsolidateClaims(player, args)
        
    elseif command == VehicleClaim.CMD_ADMIN_CLEAR_ALL then
        handleAdminClearAllClaims(player, args)
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
    
    -- Check access (reads from vehicle ModData)
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
