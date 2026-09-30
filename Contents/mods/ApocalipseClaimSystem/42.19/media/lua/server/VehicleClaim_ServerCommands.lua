--[[
    VehicleClaim_ServerCommands.lua
    Server-side authoritative command processing
    Validates all requests, enforces ownership, manages modData
]] 
require "shared/VehicleClaim_Shared"
require "server/VehicleClaim_ServerDatabase"

local VehicleClaimServer = {}

-----------------------------------------------------------
-- Vehicle Lookup
-----------------------------------------------------------

local vehicleLookupCache = {
    byHash = {},
    vehicles = {},
    lastRefreshMs = 0
}

local trustedVehicleHashesById = {}

local VEHICLE_CACHE_MAX_AGE_MS = 60 * 1000

local function nowMs()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end
    return 0
end

local function cacheVehicle(vehicle)
    if not vehicle then return end
    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    local vehicleId = vehicle:getId()
    local trusted = vehicleId and trustedVehicleHashesById[vehicleId]
    if trusted and trusted.vehicle == vehicle then
        vehicleHash = trusted.vehicleHash
    elseif vehicleId and vehicleHash then
        trustedVehicleHashesById[vehicleId] = { vehicle = vehicle, vehicleHash = vehicleHash }
    end

    if vehicleHash then
        vehicleLookupCache.byHash[vehicleHash] = vehicle
    end
end

local function vehicleMatchesHash(vehicle, vehicleHash)
    if not vehicle or not vehicleHash then
        return false
    end

    local trusted = trustedVehicleHashesById[vehicle:getId()]
    if trusted and trusted.vehicle == vehicle then
        return trusted.vehicleHash == vehicleHash
    end

    return VehicleClaim.getVehicleHash(vehicle) == vehicleHash
end

local function refreshVehicleLookupCache()
    vehicleLookupCache.byHash = {}
    vehicleLookupCache.vehicles = {}

    local vehicles = getCell():getVehicles()
    if vehicles then
        local iterator = vehicles:iterator()
        while iterator:hasNext() do
            local vehicle = iterator:next()
            if vehicle then
                vehicleLookupCache.vehicles[#vehicleLookupCache.vehicles + 1] = vehicle
                cacheVehicle(vehicle)
            end
        end
    end

    vehicleLookupCache.lastRefreshMs = nowMs()
end

local function refreshVehicleLookupCacheIfStale()
    local lastRefreshMs = tonumber(vehicleLookupCache.lastRefreshMs) or 0
    if lastRefreshMs <= 0 or nowMs() - lastRefreshMs >= VEHICLE_CACHE_MAX_AGE_MS then
        refreshVehicleLookupCache()
    end
end

--- Find a vehicle by hash on the server
--- @param vehicleHash string Vehicle hash from ModData
--- @return IsoVehicle|nil
local function findVehicleByHash(vehicleHash)
    if not vehicleHash then
        return nil
    end

    refreshVehicleLookupCacheIfStale()

    local cached = vehicleLookupCache.byHash[vehicleHash]
    if cached and vehicleMatchesHash(cached, vehicleHash) then
        return cached
    end

    refreshVehicleLookupCache()
    cached = vehicleLookupCache.byHash[vehicleHash]
    if cached and vehicleMatchesHash(cached, vehicleHash) then
        return cached
    end

    return nil
end

local function findClosestVehicleAt(targetX, targetY, targetZ)
    refreshVehicleLookupCacheIfStale()

    local bestVehicle = nil
    local bestDist = 2.0

    for _, vehicle in ipairs(vehicleLookupCache.vehicles) do
        if vehicle then
            local z = tonumber(vehicle:getZ()) or 0
            if targetZ == nil or math.abs(z - targetZ) < 0.5 then
                local dx = vehicle:getX() - targetX
                local dy = vehicle:getY() - targetY
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < bestDist then
                    bestDist = dist
                    bestVehicle = vehicle
                end
            end
        end
    end

    if bestVehicle then return bestVehicle end

    refreshVehicleLookupCache()
    for _, vehicle in ipairs(vehicleLookupCache.vehicles) do
        if vehicle then
            local z = tonumber(vehicle:getZ()) or 0
            if targetZ == nil or math.abs(z - targetZ) < 0.5 then
                local dx = vehicle:getX() - targetX
                local dy = vehicle:getY() - targetY
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < bestDist then
                    bestDist = dist
                    bestVehicle = vehicle
                end
            end
        end
    end

    return bestVehicle
end

--- Find player by Steam ID on the server
--- @param steamID string
--- @return IsoPlayer|nil
local function findPlayerBySteamID(steamID)
    if not steamID then
        return nil
    end

    local players = getOnlinePlayers()
    if not players then
        return nil
    end

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
    if not username then
        return nil, nil
    end

    local players = getOnlinePlayers()
    if not players then
        return nil, nil
    end

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
    if not player then
        return false
    end
    local level = player:getAccessLevel()
    return level == "admin" or level == "moderator"
end

-----------------------------------------------------------
-- Vehicle ModData Broadcast (replaces vehicle:transmitModData)
-----------------------------------------------------------

local function isPlayerInVehicleSyncRange(player, vehicle)
    if not player or not vehicle then
        return false
    end

    local dz = math.abs((tonumber(player:getZ()) or 0) - (tonumber(vehicle:getZ()) or 0))
    if dz > 1 then
        return false
    end

    local dx = player:getX() - vehicle:getX()
    local dy = player:getY() - vehicle:getY()
    local syncDistance = VehicleClaim.SYNC_DISTANCE or 100.0

    return (dx * dx + dy * dy) <= (syncDistance * syncDistance)
end

--- Broadcast vehicle modData changes to nearby online players via sendServerCommand
--- Each client will find the vehicle locally and update its modData
--- @param vehicle IsoVehicle
--- @param vehicleHash string
local function broadcastVehicleModData(vehicle, vehicleHash)
    if not vehicle or not vehicleHash then
        return
    end

    local modData = vehicle:getModData()
    local claimData = modData[VehicleClaim.MODDATA_KEY]         -- may be nil (unclaim)
    local vehicleHashKey = modData[VehicleClaim.VEHICLE_HASH_KEY] -- may be nil

    local syncArgs = {
        vehicleHash = vehicleHash,
        vehicleHashKey = vehicleHashKey,
        vehicleTempId = vehicle:getId()
    }

    -- Only include claimData if it exists (nil means vehicle was unclaimed)
    if claimData then
        syncArgs.claimData = claimData
    end

    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local player = players:get(i)
            if isPlayerInVehicleSyncRange(player, vehicle) then
                sendServerCommand(player, VehicleClaim.COMMAND_MODULE,
                    VehicleClaim.RESP_SYNC_VEHICLE_MODDATA, syncArgs)
            end
        end
    end
end

-- Expose so VehicleClaim_Shared.lua (getOrCreateVehicleHash) can call it server-side
VehicleClaim.broadcastVehicleModData = broadcastVehicleModData

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
--- @param vehicleName string Vehicle model/script name
--- @param allowedPlayers table|nil Optional allowed players table
local function addToGlobalRegistry(vehicleHash, ownerSteamID, ownerName, x, y, vehicleName, allowedPlayers)
    local registry = getGlobalRegistry()
    registry[vehicleHash] = {
        vehicleHash = vehicleHash,
        ownerSteamID = ownerSteamID,
        ownerName = ownerName,
        x = x,
        y = y,
        vehicleName = vehicleName or "Unknown Vehicle",
        claimTime = VehicleClaim.getCurrentTimestamp(),
        lastSeen = VehicleClaim.getCurrentTimestamp(),
        allowedPlayers = allowedPlayers or {}
    }
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
end

local function getRegistryClaimForVehicle(vehicle)
    if not vehicle then
        return nil, nil
    end

    local registry = getGlobalRegistry()
    local vehicleId = vehicle:getId()
    local trusted = vehicleId and trustedVehicleHashesById[vehicleId]
    if trusted and trusted.vehicle == vehicle then
        local entry = registry[trusted.vehicleHash]
        return entry, trusted.vehicleHash
    end

    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    local entry = vehicleHash and registry[vehicleHash]
    if entry then
        if vehicleId then
            trustedVehicleHashesById[vehicleId] = { vehicle = vehicle, vehicleHash = vehicleHash }
        end
        return entry, vehicleHash
    end

    return nil, vehicleHash
end

local function buildClaimDataFromRegistry(entry, vehicleHash)
    return {
        [VehicleClaim.OWNER_KEY] = entry.ownerSteamID,
        [VehicleClaim.OWNER_NAME_KEY] = entry.ownerName,
        [VehicleClaim.VEHICLE_NAME_KEY] = entry.vehicleName or "Unknown Vehicle",
        [VehicleClaim.ALLOWED_PLAYERS_KEY] = entry.allowedPlayers or {},
        [VehicleClaim.CLAIM_TIME_KEY] = entry.claimTime or 0,
        [VehicleClaim.LAST_SEEN_KEY] = entry.lastSeen or entry.claimTime or 0,
        [VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
    }
end

local function claimDataMatchesRegistry(claimData, entry, vehicleHash)
    if type(claimData) ~= "table" then
        return false
    end

    local expected = buildClaimDataFromRegistry(entry, vehicleHash)
    for key, value in pairs(expected) do
        if key ~= VehicleClaim.ALLOWED_PLAYERS_KEY and claimData[key] ~= value then
            return false
        end
    end

    local currentAllowed = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY]
    local expectedAllowed = expected[VehicleClaim.ALLOWED_PLAYERS_KEY]
    if type(currentAllowed) ~= "table" then
        return false
    end
    for steamID, playerName in pairs(expectedAllowed) do
        if currentAllowed[steamID] ~= playerName then
            return false
        end
    end
    for steamID in pairs(currentAllowed) do
        if expectedAllowed[steamID] == nil then
            return false
        end
    end

    return true
end

local function syncVehicleClaimFromRegistry(vehicle)
    local entry, vehicleHash = getRegistryClaimForVehicle(vehicle)
    if not vehicle then
        return nil, nil, false
    end

    local modData = vehicle:getModData()
    if not entry then
        local vehicleId = vehicle:getId()
        local trusted = vehicleId and trustedVehicleHashesById[vehicleId]
        local changed = false
        if trusted and trusted.vehicle == vehicle and modData[VehicleClaim.VEHICLE_HASH_KEY] ~= trusted.vehicleHash then
            modData[VehicleClaim.VEHICLE_HASH_KEY] = trusted.vehicleHash
            vehicleHash = trusted.vehicleHash
            changed = true
        end
        if modData[VehicleClaim.MODDATA_KEY] ~= nil then
            modData[VehicleClaim.MODDATA_KEY] = nil
            changed = true
        end
        if changed and vehicleHash then
            broadcastVehicleModData(vehicle, vehicleHash)
        end
        return nil, vehicleHash, changed
    end

    vehicleHash = entry.vehicleHash or vehicleHash
    local changed = modData[VehicleClaim.VEHICLE_HASH_KEY] ~= vehicleHash or
        not claimDataMatchesRegistry(modData[VehicleClaim.MODDATA_KEY], entry, vehicleHash)
    modData[VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
    modData[VehicleClaim.MODDATA_KEY] = buildClaimDataFromRegistry(entry, vehicleHash)
    if changed then
        broadcastVehicleModData(vehicle, vehicleHash)
    end

    return entry, vehicleHash, changed
end

local function hasRegistryVehicleAccess(vehicle, steamID)
    if not steamID then
        return false
    end

    local entry = syncVehicleClaimFromRegistry(vehicle)
    if not entry then
        return true
    end

    local allowedPlayers = entry.allowedPlayers or {}
    return entry.ownerSteamID == steamID or allowedPlayers[steamID] ~= nil
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

--- Update allowed players in global registry
--- @param vehicleHash string
--- @param allowedPlayers table
local function updateRegistryAllowedPlayers(vehicleHash, allowedPlayers)
    local registry = getGlobalRegistry()
    local entry = registry[vehicleHash]
    if entry then
        entry.allowedPlayers = allowedPlayers or {}
        ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
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
                vehicleName = claimData.vehicleName or "Unknown Vehicle",
                x = claimData.x,
                y = claimData.y,
                claimTime = claimData.claimTime,
                lastSeen = claimData.lastSeen,
                allowedPlayers = claimData.allowedPlayers or {} -- Use from registry
            }

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
--- Initialize registry claim data and project it to the vehicle ModData mirror
    -- The registry is authoritative; ModData is synchronized for client display.
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
    cacheVehicle(vehicle)

    -- Get vehicle name/model
    local vehicleName = VehicleClaim.getVehicleName(vehicle)

    -- Create claim data
    local claimData = {
        [VehicleClaim.OWNER_KEY] = ownerSteamID,
        [VehicleClaim.OWNER_NAME_KEY] = ownerName,
        [VehicleClaim.VEHICLE_NAME_KEY] = vehicleName,
        [VehicleClaim.ALLOWED_PLAYERS_KEY] = {},
        [VehicleClaim.CLAIM_TIME_KEY] = VehicleClaim.getCurrentTimestamp(),
        [VehicleClaim.LAST_SEEN_KEY] = VehicleClaim.getCurrentTimestamp(),
        [VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
    }

    -- Write to ModData (source of truth for access checks)
    modData[VehicleClaim.MODDATA_KEY] = claimData
    broadcastVehicleModData(vehicle, vehicleHash)

    -- Also add to global registry (for tracking when vehicle is unloaded)
    addToGlobalRegistry(vehicleHash, ownerSteamID, ownerName, vehicle:getX(), vehicle:getY(), vehicleName)
    syncVehicleClaimFromRegistry(vehicle)

    -- Return claimData and hash so caller can send response
    return claimData, vehicleHash
end

--- Clear claim data from a vehicle (removes from both ModData and registry)
--- @param vehicle IsoVehicle
local function clearClaimData(vehicle)
    if not vehicle then
        return
    end

    -- Get hash and remove from registry
    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    if vehicleHash then
        removeFromGlobalRegistry(vehicleHash)
        VehicleClaim.log("Removed claim from registry: " .. vehicleHash)
    end

    -- Clear ModData
    local modData = vehicle:getModData()
    modData[VehicleClaim.MODDATA_KEY] = nil
    broadcastVehicleModData(vehicle, vehicleHash or "unknown")
    VehicleClaim.log("Cleared ModData for vehicle: " .. tostring(vehicleHash))
end

--- Update last seen timestamp
--- Only updates if at least 5 minutes have passed since last update to avoid constant modData broadcast
--- @param vehicle IsoVehicle
local function updateLastSeen(vehicle)
    local registryEntry, vehicleHash = getRegistryClaimForVehicle(vehicle)
    if registryEntry then
        local currentTime = VehicleClaim.getCurrentTimestamp()
        local lastSeen = registryEntry.lastSeen or registryEntry.claimTime or 0

        -- Only update if at least 5 minutes have passed
        if (currentTime - lastSeen) >= 5 then
            registryEntry.lastSeen = currentTime
            registryEntry.x = vehicle:getX()
            registryEntry.y = vehicle:getY()
            ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)
            syncVehicleClaimFromRegistry(vehicle)
        end
    end
end

-----------------------------------------------------------
-- Vehicle Key Management
-----------------------------------------------------------

--- Spawn a vehicle key in the player's inventory on successful claim
--- Ensures the vehicle has a key ID assigned, then creates a matching CarKey item
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @return boolean success
local function spawnVehicleKey(player, vehicle)
    if not player or not vehicle then
        return false
    end

    local inventory = player:getInventory()
    if not inventory then
        VehicleClaim.log("WARNING: Player inventory not found for key spawn")
        return false
    end

    -- Ensure vehicle has a key ID assigned
    local keyId = vehicle:getKeyId()
    if not keyId or keyId <= 0 then
        -- Generate a new key ID for this vehicle
        keyId = ZombRandBetween(1, 99999)
        vehicle:setKeyId(keyId)
        VehicleClaim.log("Assigned new key ID " .. keyId .. " to vehicle")
    end

    -- Create and add the key item (server-safe: AddItem(string) works server-side)
    local key = inventory:AddItem("Base.CarKey")
    if not key then
        VehicleClaim.log("WARNING: Failed to create CarKey item")
        return false
    end

    -- Configure the key to match this vehicle
    key:setKeyId(keyId)

    VehicleClaim.log("Spawned vehicle key (keyId=" .. keyId .. ") for player: " .. player:getUsername())
    return true
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

    -- The server registry is authoritative; vehicle ModData is a client-facing mirror.
    local existingClaim = getGlobalRegistry()[vehicleHash]
    if existingClaim then
        syncVehicleClaimFromRegistry(vehicle)
        -- Vehicle is already claimed
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_ALREADY_CLAIMED,
            ownerName = existingClaim.ownerName or "Unknown"
        })
        VehicleClaim.log("Claim rejected: Vehicle hash " .. vehicleHash .. " already claimed by " ..
                             (existingClaim.ownerName or "Unknown"))
        return
    end

    syncVehicleClaimFromRegistry(vehicle)

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

        -- Spawn vehicle key in the claiming player's inventory
        local keySpawned = spawnVehicleKey(player, vehicle)
        if not keySpawned then
            VehicleClaim.log("WARNING: Claim succeeded but failed to spawn key for " .. playerName)
        end

        -- Persist to car database
        --VehicleClaim.updateCarDatabase(vehicle)

        -- Notify client with claim data
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_SUCCESS, {
            vehicleHash = claimVehicleHash,
            claimData = claimData
        })
    else
        VehicleClaim.log("ERROR: Failed to initialize claim data")
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_INIT_FAILED
        })
    end
end

--- Handle release claim request
local function finishRegistryRelease(player, vehicleHash, contested)
    local vehicle = findVehicleByHash(vehicleHash)
    if vehicle then
        local modData = vehicle:getModData()
        modData[VehicleClaim.MODDATA_KEY] = nil
        broadcastVehicleModData(vehicle, vehicleHash)
    end

    removeFromGlobalRegistry(vehicleHash)
    VehicleClaim.removeFromCarDatabase(vehicleHash)
    VehicleClaim.log("[Release] Vehicle " .. vehicleHash .. " released by " .. player:getUsername())

    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_RELEASE_SUCCESS, {
        vehicleHash = vehicleHash,
        contested = contested == true
    })
end

--- Handle remote release claim request (vehicle doesn't need to be loaded)
--- This allows players to unclaim vehicles from far away
--- The vehicle's modData will be synced when it's eventually loaded
--- @param player IsoPlayer
--- @param args table
handleReleaseClaimRemote = function(player, args)
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID

    if not vehicleHash or not steamID then
        VehicleClaim.log("Remote release rejected: missing parameters")
        return
    end

    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Remote release rejected: steamID mismatch")
        return
    end

    -- Check if claim exists in registry
    local registry = getGlobalRegistry()
    local registryEntry = registry[vehicleHash]

    if not registryEntry then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_CLAIMED
        })
        VehicleClaim.log("Remote release rejected: Vehicle not found in registry")
        return
    end

    -- Verify ownership from registry
    if registryEntry.ownerSteamID ~= steamID then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        VehicleClaim.log("Remote release rejected: Player is not the owner")
        return
    end

    finishRegistryRelease(player, vehicleHash, false)
end

--- Handle contest claim request (for abandoned vehicles)
--- Allows non-owners to unclaim vehicles that haven't been used in X days
--- @param player IsoPlayer
--- @param args table
local function handleContestClaim(player, args)
    local vehicleHash = args.vehicleHash
    local steamID = args.steamID
    
    if not vehicleHash or not steamID then
        VehicleClaim.log("Contest claim rejected: missing parameters")
        return
    end
    
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= steamID then
        VehicleClaim.log("Contest claim rejected: steamID mismatch")
        return
    end
    
    local registryEntry = getGlobalRegistry()[vehicleHash]
    if not registryEntry then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_CLAIMED
        })
        VehicleClaim.log("Contest claim rejected: Vehicle not in server registry")
        return
    end

    local vehicle = findVehicleByHash(vehicleHash)
    local vehicleX = vehicle and vehicle:getX() or registryEntry.x
    local vehicleY = vehicle and vehicle:getY() or registryEntry.y
    if not vehicleX or not vehicleY then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_LOADED
        })
        return
    end
    local dx = player:getX() - vehicleX
    local dy = player:getY() - vehicleY
    if (dx * dx + dy * dy) > (VehicleClaim.CLAIM_DISTANCE * VehicleClaim.CLAIM_DISTANCE) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_TOO_FAR
        })
        VehicleClaim.log("Contest claim rejected: Player too far from vehicle")
        return
    end

    if vehicle then
        syncVehicleClaimFromRegistry(vehicle)
    end
    
    -- Verify player is NOT the owner (owners should use normal unclaim)
    if registryEntry.ownerSteamID == steamID then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = "cannotContestOwnVehicle"
        })
        VehicleClaim.log("Contest claim rejected: Player is the owner (use normal release instead)")
        return
    end
    
    -- Check abandonment using server-owned registry timestamps, not vehicle ModData.
    local lastSeen = registryEntry.lastSeen or registryEntry.claimTime or 0
    local minutesSinceLastSeen = VehicleClaim.getCurrentTimestamp() - lastSeen
    local daysSinceLastSeen = math.max(0, minutesSinceLastSeen / (24 * 60 * 16))
    if daysSinceLastSeen < VehicleClaim.getAbandonedDaysThreshold() then
        local threshold = VehicleClaim.getAbandonedDaysThreshold()
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = "vehicleNotAbandoned",
            daysSinceLastSeen = math.floor(daysSinceLastSeen),
            daysRequired = threshold
        })
        VehicleClaim.log(string.format("Contest claim rejected: Vehicle not abandoned (%.1f days, need %d days)", 
            daysSinceLastSeen, threshold))
        return
    end
    
    VehicleClaim.log(string.format("[Contest Claim] Vehicle %s contested by %s (abandoned for %.1f days)", 
        vehicleHash, player:getUsername(), daysSinceLastSeen))
    finishRegistryRelease(player, vehicleHash, true)
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

    -- Find vehicle (REQUIRED - must be near vehicle to modify access list)
    local vehicle = findVehicleByHash(vehicleHash)
    if not vehicle then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_LOADED
        })
        VehicleClaim.log("Add player rejected: Vehicle not loaded (player must be nearby)")
        return
    end

    -- Check proximity (REQUIRED - ensures vehicle ModData can be updated)
    if not VehicleClaim.isWithinRange(player, vehicle) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_TOO_FAR
        })
        VehicleClaim.log("Add player rejected: Player too far from vehicle")
        return
    end

    -- Check ownership
    local registryEntry = getGlobalRegistry()[vehicleHash]
    if not registryEntry or (registryEntry.ownerSteamID ~= steamID and not isAdmin(player)) then
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

    local allowedPlayers = registryEntry.allowedPlayers or {}
    allowedPlayers[targetSteamID] = targetPlayerName
    updateRegistryAllowedPlayers(vehicleHash, allowedPlayers)
    syncVehicleClaimFromRegistry(vehicle)
    local claimData = buildClaimDataFromRegistry(registryEntry, vehicleHash)

    VehicleClaim.log("Added " .. targetPlayerName .. " to vehicle access")
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_ADDED, {
        vehicleHash = vehicleHash,
        addedSteamID = targetSteamID,
        addedPlayerName = targetPlayerName,
        claimData = claimData
    })
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

    -- Find vehicle (REQUIRED - must be near vehicle to modify access list)
    local vehicle = findVehicleByHash(vehicleHash)
    if not vehicle then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_VEHICLE_NOT_LOADED
        })
        VehicleClaim.log("Remove player rejected: Vehicle not loaded (player must be nearby)")
        return
    end

    -- Check proximity (REQUIRED - ensures vehicle ModData can be updated)
    if not VehicleClaim.isWithinRange(player, vehicle) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_TOO_FAR
        })
        VehicleClaim.log("Remove player rejected: Player too far from vehicle")
        return
    end

    -- Check ownership
    local registryEntry = getGlobalRegistry()[vehicleHash]
    if not registryEntry or (registryEntry.ownerSteamID ~= steamID and not isAdmin(player)) then
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_CLAIM_FAILED, {
            reason = VehicleClaim.ERR_NOT_OWNER
        })
        return
    end

    local allowedPlayers = registryEntry.allowedPlayers or {}
    local removedName = allowedPlayers[targetSteamID] or "Player"
    allowedPlayers[targetSteamID] = nil
    updateRegistryAllowedPlayers(vehicleHash, allowedPlayers)
    syncVehicleClaimFromRegistry(vehicle)
    local claimData = buildClaimDataFromRegistry(registryEntry, vehicleHash)

    VehicleClaim.log("Removed " .. removedName .. " from vehicle access")
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_PLAYER_REMOVED, {
        vehicleHash = vehicleHash,
        removedSteamID = targetSteamID,
        removedPlayerName = removedName,
        claimData = claimData
    })
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

    VehicleClaim.log("[ADMIN] Cleared ModData from " .. vehiclesCleared .. " vehicles")

    -- Clear the entire registry
    local globalModData = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    globalModData.claims = {}
    ModData.transmit(VehicleClaim.GLOBAL_REGISTRY_KEY)

    -- Clear the car database file
    VehicleClaim.clearCarDatabase()

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

--- Handle client request to update last seen (triggered when owned vehicle loads on client)
--- @param player IsoPlayer
--- @param args table { vehicleHash, steamID }
local function handleUpdateLastSeen(player, args)
    if not args or not args.vehicleHash or not args.steamID then
        return
    end

    -- Anti-spoof: verify steamID matches the sending player
    local actualSteamID = VehicleClaim.getPlayerSteamID(player)
    if actualSteamID ~= args.steamID then
        VehicleClaim.log("SECURITY: SteamID mismatch in updateLastSeen from " .. player:getUsername())
        return
    end

    local vehicle = findVehicleByHash(args.vehicleHash)
    if not vehicle then
        return
    end

    -- Verify the player actually owns or has access to this vehicle
    if not hasRegistryVehicleAccess(vehicle, actualSteamID) then
        return
    end

    updateLastSeen(vehicle)
end

--- Handle client request to generate a vehicle hash
--- The client sends the vehicle position so the server can find it and generate a hash
--- @param player IsoPlayer
--- @param args table { vehicleX, vehicleY, vehicleZ }
local function handleRequestVehicleHash(player, args)
    if not args or not args.vehicleX or not args.vehicleY then
        VehicleClaim.log("RequestHash rejected: missing position parameters")
        return
    end

    local targetX = args.vehicleX
    local targetY = args.vehicleY
    local targetZ = args.vehicleZ or 0

    local bestVehicle = findClosestVehicleAt(targetX, targetY, targetZ)

    if not bestVehicle then
        VehicleClaim.log("RequestHash: No vehicle found at position " .. targetX .. ", " .. targetY)
        return
    end

    -- Generate hash (or return existing one)
    local vehicleHash = VehicleClaim.getOrCreateVehicleHash(bestVehicle)
    if not vehicleHash then
        VehicleClaim.log("RequestHash: Failed to generate hash")
        return
    end
    cacheVehicle(bestVehicle)

    VehicleClaim.log("RequestHash: Generated hash " .. vehicleHash .. " for vehicle at " .. targetX .. ", " .. targetY)

    -- Send the hash back to the requesting player with position so client can match the vehicle
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_VEHICLE_HASH, {
        vehicleHash = vehicleHash,
        vehicleX = bestVehicle:getX(),
        vehicleY = bestVehicle:getY(),
        vehicleZ = bestVehicle:getZ()
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
    if module ~= VehicleClaim.COMMAND_MODULE then
        return
    end

    VehicleClaim.log("Server received command: " .. tostring(command) .. " from " .. tostring(player:getUsername()))

    if command == VehicleClaim.CMD_CLAIM then
        handleClaimVehicle(player, args)

    elseif command == VehicleClaim.CMD_RELEASE_REMOTE then
        handleReleaseClaimRemote(player, args)

    elseif command == VehicleClaim.CMD_ADD_PLAYER then
        handleAddPlayer(player, args)

    elseif command == VehicleClaim.CMD_REMOVE_PLAYER then
        handleRemovePlayer(player, args)

    elseif command == VehicleClaim.CMD_REQUEST_INFO then
        handleRequestInfo(player, args)
    
    elseif command == VehicleClaim.CMD_CONTEST_CLAIM then
        handleContestClaim(player, args)

    elseif command == VehicleClaim.CMD_REQUEST_MY_CLAIMS then
        handleRequestMyClaims(player, args)

    elseif command == VehicleClaim.CMD_CONSOLIDATE_CLAIMS then
        handleConsolidateClaims(player, args)

    elseif command == VehicleClaim.CMD_UPDATE_LAST_SEEN then
        handleUpdateLastSeen(player, args)

    elseif command == VehicleClaim.CMD_ADMIN_CLEAR_ALL then
        handleAdminClearAllClaims(player, args)

    elseif command == VehicleClaim.CMD_REQUEST_HASH then
        handleRequestVehicleHash(player, args)
    end
end

-----------------------------------------------------------
-- Vehicle Load Synchronization
-----------------------------------------------------------

--- Synchronize vehicle claim data when a vehicle is loaded/rendered
--- Rebuild the vehicle claim ModData mirror from the server registry when loaded.
--- @param vehicle IsoVehicle
local function syncVehicleClaimOnLoad(vehicle)
    if not isServer() then
        return
    end
    if not vehicle then
        return
    end

    local registryEntry, vehicleHash = syncVehicleClaimFromRegistry(vehicle)
    if registryEntry then
        updateRegistryPosition(vehicleHash, vehicle:getX(), vehicle:getY())
        VehicleClaim.updateCarDatabase(vehicle)
    end
end

--- Hook for when vehicles are created/loaded
--- @param vehicle IsoVehicle
function VehicleClaimServer.onVehicleCreated(vehicle)
    if not vehicle then
        return
    end

    cacheVehicle(vehicle)

    -- Perform sync check
    syncVehicleClaimOnLoad(vehicle)
end

-----------------------------------------------------------
-- Vehicle Interaction Enforcement
-----------------------------------------------------------

local unauthorizedVehicleStrikes = {}
local UNAUTHORIZED_VEHICLE_STRIKE_LIMIT = 3

local function enforceVehicleAccess(player, vehicle)
    if not player or not vehicle then
        return true
    end

    local steamID = VehicleClaim.getPlayerSteamID(player)
    local registryEntry = syncVehicleClaimFromRegistry(vehicle)
    local hasAccess = not registryEntry
    if registryEntry and steamID then
        local allowedPlayers = registryEntry.allowedPlayers or {}
        hasAccess = registryEntry.ownerSteamID == steamID or allowedPlayers[steamID] ~= nil
    end
    if hasAccess or isAdmin(player) then
        return true
    end

    player:setVehicle(nil)

    local playerKey = steamID or player:getUsername() or tostring(player)
    unauthorizedVehicleStrikes[playerKey] = (unauthorizedVehicleStrikes[playerKey] or 0) + 1
    local strikes = unauthorizedVehicleStrikes[playerKey]
    local playerName = tostring(player:getUsername() or playerKey)
    local ownerName = registryEntry.ownerName or "another player"

    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
        action = "enter",
        ownerName = ownerName
    })

    VehicleClaim.log("Ejected " .. playerName .. " from unauthorized vehicle (strike " .. strikes .. "/" ..
        UNAUTHORIZED_VEHICLE_STRIKE_LIMIT .. ")")

    if strikes >= UNAUTHORIZED_VEHICLE_STRIKE_LIMIT then
        local kill = player.Kill
        local killed = false
        if type(kill) == "function" then
            killed = pcall(function()
                player:Kill(nil)
            end)
        end
        if not killed and type(player.setHealth) == "function" then
            player:setHealth(0)
        end
        VehicleClaim.log("Killed " .. playerName .. " after repeated unauthorized vehicle access")
    end

    return false
end

local onlinePlayerVehicleCheckIndex = 0

local function checkOneOnlinePlayerVehicleAccess()
    if not isServer() then
        return
    end

    local players = getOnlinePlayers()
    if not players then
        onlinePlayerVehicleCheckIndex = 0
        return
    end

    local playerCount = players:size()
    if playerCount <= 0 then
        onlinePlayerVehicleCheckIndex = 0
        return
    end

    if onlinePlayerVehicleCheckIndex >= playerCount then
        onlinePlayerVehicleCheckIndex = 0
    end

    local player = players:get(onlinePlayerVehicleCheckIndex)
    onlinePlayerVehicleCheckIndex = onlinePlayerVehicleCheckIndex + 1
    if onlinePlayerVehicleCheckIndex >= playerCount then
        onlinePlayerVehicleCheckIndex = 0
    end

    local vehicle = player and player:getVehicle()
    if vehicle then
        enforceVehicleAccess(player, vehicle)
    end
end

--- Block unauthorized vehicle entry
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @param seat number
function VehicleClaimServer.onEnterVehicle(player, vehicle, seat)
    if not player or not vehicle then
        return
    end

    if not enforceVehicleAccess(player, vehicle) then
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
    if not player or not vehicle then
        return true
    end

    local steamID = VehicleClaim.getPlayerSteamID(player)

    if not hasRegistryVehicleAccess(vehicle, steamID) and not isAdmin(player) then
        local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
            action = "repair",
            ownerName = ownerName
        })
        return false
    end
    updateLastSeen(vehicle)
    return true
end

--- Validate timed actions against claimed vehicles
--- @param action ISBaseTimedAction
function VehicleClaimServer.onTimedActionValidate(action)
    -- Check if this action involves a vehicle
    if not action or not action.vehicle then
        return
    end

    local player = action.character
    if not player then
        return
    end

    local vehicle = action.vehicle
    local steamID = VehicleClaim.getPlayerSteamID(player)

    if not hasRegistryVehicleAccess(vehicle, steamID) and not isAdmin(player) then
        -- Cancel the action
        action:forceStop()

        local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
        sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
            action = "interact with",
            ownerName = ownerName
        })
    end
end

--- Block unauthorized vehicle/trailer attachments sent through the vanilla vehicle command module.
--- @param module string
--- @param command string
--- @param player IsoPlayer
--- @param args table
function VehicleClaimServer.onVehicleAttachTrailerCommand(module, command, player, args)
    if module ~= "vehicle" or command ~= "attachTrailer" then
        return
    end

    if not player or not args then
        return
    end

    local vehicleA = getVehicleById(args.vehicleA)
    local vehicleB = getVehicleById(args.vehicleB)
    if not vehicleA or not vehicleB then
        return
    end

    local steamID = VehicleClaim.getPlayerSteamID(player)
    local deniedVehicle = nil

    if not hasRegistryVehicleAccess(vehicleA, steamID) and not isAdmin(player) then
        deniedVehicle = vehicleA
    elseif not hasRegistryVehicleAccess(vehicleB, steamID) and not isAdmin(player) then
        deniedVehicle = vehicleB
    end

    if not deniedVehicle then
        updateLastSeen(vehicleA)
        updateLastSeen(vehicleB)
        return
    end

    local ownerName = VehicleClaim.getOwnerName(deniedVehicle) or "another player"
    sendServerCommand(player, VehicleClaim.COMMAND_MODULE, VehicleClaim.RESP_ACCESS_DENIED, {
        action = "attach",
        ownerName = ownerName
    })

    VehicleClaim.log("Blocked " .. player:getUsername() .. " from attaching vehicle owned by " .. ownerName)

    -- Vanilla also handles the same client command. Break now and once more next tick so
    -- this guard works regardless of event listener order.
    vehicleA:breakConstraint(true, false)

    local removeInvalidTow
    removeInvalidTow = function()
        if vehicleA then
            vehicleA:breakConstraint(true, false)
        end
        Events.OnTick.Remove(removeInvalidTow)
    end
    Events.OnTick.Add(removeInvalidTow)
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnClientCommand.Add(VehicleClaimServer.onClientCommand)
Events.OnClientCommand.Add(VehicleClaimServer.onVehicleAttachTrailerCommand)

if Events.OnServerStarted then
    Events.OnServerStarted.Add(refreshVehicleLookupCache)
end

-- Vehicle creation/load hook - sync claim data when vehicles are loaded
Events.OnSpawnVehicleStart.Add(VehicleClaimServer.onVehicleCreated)

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

if Events.OnTick then
    Events.OnTick.Add(checkOneOnlinePlayerVehicleAccess)
end

return VehicleClaimServer
