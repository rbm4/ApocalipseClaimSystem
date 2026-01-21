--[[
    VehicleClaim_Shared.lua
    Common constants, validation helpers, and utility functions
    Loaded on both client and server
]]

VehicleClaim = VehicleClaim or {}

-- Global state tracking
VehicleClaim.pendingActions = VehicleClaim.pendingActions or {}  -- {[vehicleHash] = actionType}

-- Constants
VehicleClaim.MOD_ID = "VehicleClaim"
VehicleClaim.COMMAND_MODULE = "VehicleClaim"

-- ModData keys stored on IsoVehicle
VehicleClaim.MODDATA_KEY = "VehicleClaimData"
VehicleClaim.OWNER_KEY = "ownerSteamID"
VehicleClaim.OWNER_NAME_KEY = "ownerName"
VehicleClaim.VEHICLE_NAME_KEY = "vehicleName"
VehicleClaim.ALLOWED_PLAYERS_KEY = "allowedPlayers"  -- Table: { [steamID] = playerName }
VehicleClaim.CLAIM_TIME_KEY = "claimTimestamp"
VehicleClaim.LAST_SEEN_KEY = "lastSeenTimestamp"
VehicleClaim.VEHICLE_HASH_KEY = "vehicleHash"  -- Unique persistent hash for this vehicle

-- Proximity settings
VehicleClaim.CLAIM_DISTANCE = 4.0  -- Max distance to claim/interact
VehicleClaim.CLAIM_TIME_TICKS = 400  -- Timed action duration (~2 seconds)

-- Command types (client -> server)
VehicleClaim.CMD_CLAIM = "claimVehicle"
VehicleClaim.CMD_RELEASE = "releaseClaim"
VehicleClaim.CMD_ADD_PLAYER = "addAllowedPlayer"
VehicleClaim.CMD_REMOVE_PLAYER = "removeAllowedPlayer"
VehicleClaim.CMD_REQUEST_INFO = "requestVehicleInfo"
VehicleClaim.CMD_ADMIN_CLEAR_ALL = "adminClearAllClaims"

-- Response types (server -> client)
VehicleClaim.RESP_CLAIM_SUCCESS = "claimSuccess"
VehicleClaim.RESP_CLAIM_FAILED = "claimFailed"
VehicleClaim.RESP_RELEASE_SUCCESS = "releaseSuccess"
VehicleClaim.RESP_PLAYER_ADDED = "playerAdded"
VehicleClaim.RESP_PLAYER_REMOVED = "playerRemoved"
VehicleClaim.RESP_ACCESS_DENIED = "accessDenied"
VehicleClaim.RESP_VEHICLE_INFO = "vehicleInfo"
VehicleClaim.RESP_ADMIN_CLEAR_ALL_SUCCESS = "adminClearAllSuccess"

-- Error codes
VehicleClaim.ERR_VEHICLE_NOT_FOUND = "vehicleNotFound"
VehicleClaim.ERR_ALREADY_CLAIMED = "alreadyClaimed"
VehicleClaim.ERR_NOT_OWNER = "notOwner"
VehicleClaim.ERR_TOO_FAR = "tooFar"
VehicleClaim.ERR_PLAYER_NOT_FOUND = "playerNotFound"
VehicleClaim.ERR_CLAIM_LIMIT_REACHED = "claimLimitReached"
VehicleClaim.ERR_NOT_ADMIN = "notAdmin"
VehicleClaim.ERR_VEHICLE_NOT_LOADED = "vehicleNotLoaded"
VehicleClaim.ERR_VEHICLE_NOT_CLAIMED = "vehicleNotClaimed"
VehicleClaim.ERR_INIT_FAILED = "initializationFailed"

-- Sandbox settings
VehicleClaim.DEFAULT_MAX_CLAIMS = 3

-- Global registry commands (for claim list sync)
VehicleClaim.CMD_REQUEST_MY_CLAIMS = "requestMyClaims"
VehicleClaim.RESP_MY_CLAIMS = "myClaims"

-- Global ModData key for server-side claim registry
-- IMPORTANT: Registry is indexed by vehicle hash (stored in vehicle ModData)
-- Hash is generated on first interaction and persists with the vehicle
-- This ensures reliable vehicle identification across server restarts
VehicleClaim.GLOBAL_REGISTRY_KEY = "VehicleClaimRegistry"

-----------------------------------------------------------
-- Utility Functions
-----------------------------------------------------------

--- Get or generate a unique hash for a vehicle
--- Hash is stored in vehicle ModData and persists across sessions
--- @param vehicle IsoVehicle
--- @return string|nil vehicleHash
function VehicleClaim.getOrCreateVehicleHash(vehicle)
    if not vehicle then return nil end
    
    local modData = vehicle:getModData()
    
    -- Check if hash already exists in main ModData
    if modData[VehicleClaim.VEHICLE_HASH_KEY] then
        return modData[VehicleClaim.VEHICLE_HASH_KEY]
    end
    
    -- Check if hash exists in claim data (for backwards compatibility)
    local claimData = modData[VehicleClaim.MODDATA_KEY]
    if claimData and claimData[VehicleClaim.VEHICLE_HASH_KEY] then
        -- Migrate to main ModData for faster access
        modData[VehicleClaim.VEHICLE_HASH_KEY] = claimData[VehicleClaim.VEHICLE_HASH_KEY]
        vehicle:transmitModData()
        return claimData[VehicleClaim.VEHICLE_HASH_KEY]
    end
    
    -- Generate new hash based on vehicle properties
    -- Use multiple vehicle properties to create a unique identifier
    local x = math.floor(vehicle:getX() * 100)
    local y = math.floor(vehicle:getY() * 100)
    local z = math.floor(vehicle:getZ() * 100)
    local scriptName = vehicle:getScript() and vehicle:getScript():getName() or "Unknown"
    local timestamp = os.time()
    local random = ZombRand(999999)
    
    -- Create hash string
    local hashSource = string.format("%s_%d_%d_%d_%d_%d", scriptName, x, y, z, timestamp, random)
    
    -- Simple hash function (you could use a more sophisticated one)
    local hash = 0
    for i = 1, #hashSource do
        hash = ((hash * 31) + string.byte(hashSource, i)) % 2147483647
    end
    
    local vehicleHash = string.format("VH%010d", hash)
    
    -- Store in ModData
    modData[VehicleClaim.VEHICLE_HASH_KEY] = vehicleHash
    vehicle:transmitModData()
    vehicle:saveToVehicleTable()
    
    return vehicleHash
end

--- Get vehicle hash without creating one
--- @param vehicle IsoVehicle
--- @return string|nil vehicleHash
function VehicleClaim.getVehicleHash(vehicle)
    if not vehicle then return nil end
    
    local modData = vehicle:getModData()
    
    -- Check main ModData first
    if modData[VehicleClaim.VEHICLE_HASH_KEY] then
        return modData[VehicleClaim.VEHICLE_HASH_KEY]
    end
    
    -- Check claim data for backwards compatibility
    local claimData = modData[VehicleClaim.MODDATA_KEY]
    if claimData and claimData[VehicleClaim.VEHICLE_HASH_KEY] then
        return claimData[VehicleClaim.VEHICLE_HASH_KEY]
    end
    
    return nil
end

--- Get the claim data table from a vehicle's modData
--- ModData is the single source of truth for claim data
--- Server transmits changes automatically via transmitModData()
--- @param vehicle IsoVehicle
--- @return table|nil claimData
function VehicleClaim.getClaimData(vehicle)
    if not vehicle then return nil end
    
    -- Read directly from vehicle's ModData
    local modData = vehicle:getModData()
    if not modData then return nil end
    
    return modData[VehicleClaim.MODDATA_KEY]
end



--- Check if a vehicle is claimed
--- A vehicle is only claimed if it has claim data AND has a valid owner ID
--- (Vehicle hash alone does not constitute a claim)
--- @param vehicle IsoVehicle
--- @return boolean
function VehicleClaim.isClaimed(vehicle)
    local data = VehicleClaim.getClaimData(vehicle)
    if not data then
        return false
    end
    
    -- Check if ownerID exists and is not empty
    local ownerID = data[VehicleClaim.OWNER_KEY]
    return ownerID ~= nil and ownerID ~= ""
end

--- Get the owner's Steam ID of a claimed vehicle
--- @param vehicle IsoVehicle
--- @return string|nil steamID
function VehicleClaim.getOwnerID(vehicle)
    local data = VehicleClaim.getClaimData(vehicle)
    if not data then
        return nil
    end
    
    local ownerID = data[VehicleClaim.OWNER_KEY]
    -- Return nil if owner is empty string
    if ownerID == "" then
        return nil
    end
    
    return ownerID
end

--- Get the owner's display name
--- @param vehicle IsoVehicle
--- @return string|nil ownerName
function VehicleClaim.getOwnerName(vehicle)
    local data = VehicleClaim.getClaimData(vehicle)
    if data then
        return data[VehicleClaim.OWNER_NAME_KEY]
    end
    return nil
end

--- Get allowed players table
--- @param vehicle IsoVehicle
--- @return table allowedPlayers (steamID -> playerName)
function VehicleClaim.getAllowedPlayers(vehicle)
    local data = VehicleClaim.getClaimData(vehicle)
    if data and data[VehicleClaim.ALLOWED_PLAYERS_KEY] then
        return data[VehicleClaim.ALLOWED_PLAYERS_KEY]
    end
    return {}
end

--- Check if a player has access to a vehicle (owner or allowed)
--- @param vehicle IsoVehicle
--- @param steamID string
--- @return boolean
function VehicleClaim.hasAccess(vehicle, steamID)
    if not steamID then return false end
    
    local data = VehicleClaim.getClaimData(vehicle)
    if not data then
        -- Unclaimed vehicles are accessible to everyone
        return true
    end
    
    -- Owner always has access
    if data[VehicleClaim.OWNER_KEY] == steamID then
        return true
    end
    
    -- Check allowed players
    local allowed = data[VehicleClaim.ALLOWED_PLAYERS_KEY]
    if allowed and allowed[steamID] then
        return true
    end
    
    return false
end

--- Calculate distance between player and vehicle
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @return number distance
function VehicleClaim.getDistance(player, vehicle)
    if not player or not vehicle then return math.huge end
    
    local px, py = player:getX(), player:getY()
    local vx, vy = vehicle:getX(), vehicle:getY()
    
    return math.sqrt((px - vx)^2 + (py - vy)^2)
end

--- Check if player is within claim distance of vehicle
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @return boolean
function VehicleClaim.isWithinRange(player, vehicle)
    return VehicleClaim.getDistance(player, vehicle) <= VehicleClaim.CLAIM_DISTANCE
end

--- Get player's Steam ID (works on both client and server)
--- @param player IsoPlayer
--- @return string|nil steamID
function VehicleClaim.getPlayerSteamID(player)
    if not player then return nil end
    
    -- Try getSteamID first (multiplayer)
    if player.getSteamID then
        local steamID = player:getSteamID()
        if steamID and steamID ~= "" and steamID ~= "0" then
            return steamID
        end
    end
    
    -- Fallback to username for local/singleplayer
    if player.getUsername then
        return player:getUsername()
    end
    
    return nil
end

--- Get readable vehicle name
--- @param vehicle IsoVehicle
--- @return string
function VehicleClaim.getVehicleName(vehicle,vehicleID)
    
    
    if vehicleID then
        local vehicleData = getVehicleById(vehicleID)
        if vehicleData then
            return vehicleData:getName()
        end
    end
    
    if not vehicle then 
        return "Unknown Vehicle" 
    end
    local script = vehicle:getScript()
    if script then
        local name = script:getName()
        if name then return name end
    end

    
    return "Vehicle"
end

--- Format timestamp for display
--- @param timestamp number
--- @return string
function VehicleClaim.formatTimestamp(timestamp)
    if not timestamp then return "Unknown" end
    
    local gameTime = getGameTime()
    if not gameTime then return tostring(timestamp) end
    
    -- Convert to in-game date format
    return string.format("Day %d, %02d:%02d", 
        math.floor(timestamp / (24 * 60)),
        math.floor((timestamp % (24 * 60)) / 60),
        timestamp % 60)
end

--- Get current game timestamp (minutes since start)
--- @return number
function VehicleClaim.getCurrentTimestamp()
    local gameTime = getGameTime()
    if not gameTime then return 0 end
    
    local day = gameTime:getNightsSurvived()
    local hour = gameTime:getHour()
    local minute = gameTime:getMinutes()
    
    return (day * 24 * 60) + (hour * 60) + minute
end

--- Debug logging (only in debug mode)
--- @param message string
function VehicleClaim.log(message)
    if isDebugEnabled() then
        print("[VehicleClaim] " .. tostring(message))
    end
end

--- Get max claims per player from sandbox options
--- @return number
function VehicleClaim.getMaxClaimsPerPlayer()
    if isServer() or isClient() then
        local sandboxVars = SandboxVars
        if sandboxVars and sandboxVars.VehicleClaimSystem then
            return sandboxVars.VehicleClaimSystem.MaxClaimsPerPlayer or VehicleClaim.DEFAULT_MAX_CLAIMS
        end
    end
    return VehicleClaim.DEFAULT_MAX_CLAIMS
end

--- Count how many vehicles a player has claimed
--- @param steamID string
--- @return number
function VehicleClaim.countPlayerClaims(steamID)
    if not steamID then return 0 end
    
    local count = 0
    local cell = getCell()
    if not cell then return 0 end
    
    local vehicles = cell:getVehicles()
    if not vehicles then return 0 end
    
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        if vehicle then
            local ownerID = VehicleClaim.getOwnerID(vehicle)
            if ownerID == steamID then
                count = count + 1
            end
        end
    end
    
    return count
end

--- Check if player can claim more vehicles
--- @param steamID string
--- @return boolean canClaim
--- @return number currentClaims
--- @return number maxClaims
function VehicleClaim.canClaimMore(steamID)
    local currentClaims = VehicleClaim.countPlayerClaims(steamID)
    local maxClaims = VehicleClaim.getMaxClaimsPerPlayer()
    return currentClaims < maxClaims, currentClaims, maxClaims
end

return VehicleClaim
