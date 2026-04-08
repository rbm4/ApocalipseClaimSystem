--[[
    VehicleClaim_ServerDatabase.lua
    Server-side vehicle database persistence module
    
    Maintains a JSON file on the server filesystem that acts as a car database.
    Each claimed vehicle is stored keyed by its vehicleHash, including:
      - Owner info (steamID, name)
      - Vehicle info (script name, display name, coordinates)
      - Full item inventory snapshot (fullType, count, container)
    
    The file is read once on load and written back on a timer (~60s batching)
    and on server shutdown so no data is lost.
    
    The external backend reads this file to sync vehicle data into an
    external database for management outside the game.
]]

require "shared/VehicleClaim_Shared"
require "shared/VehicleClaim_Config"

-----------------------------------------------------------
-- JSON Serializer (supports nested tables/arrays)
-----------------------------------------------------------

--- Escape a string for JSON output
--- @param s string
--- @return string
local function jsonEscapeString(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

--- Check if a table is an array (contiguous integer keys starting at 1)
--- @param t table
--- @return boolean
local function isArray(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    if count == 0 then
        -- Empty table: treat as object by default
        return false
    end
    for i = 1, count do
        if t[i] == nil then
            return false
        end
    end
    return true
end

--- Serialize a Lua value to a JSON string
--- Handles strings, numbers, booleans, nil, and tables (arrays + objects)
--- @param value any
--- @return string
local function serializeToJson(value)
    local vtype = type(value)

    if value == nil then
        return "null"
    elseif vtype == "string" then
        return '"' .. jsonEscapeString(value) .. '"'
    elseif vtype == "number" then
        -- Use %g to preserve decimals for coordinates but avoid unnecessary trailing zeros
        return string.format("%g", value)
    elseif vtype == "boolean" then
        return value and "true" or "false"
    elseif vtype == "table" then
        if isArray(value) then
            -- Serialize as JSON array
            local parts = {}
            for i = 1, #value do
                parts[i] = serializeToJson(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            -- Serialize as JSON object
            local parts = {}
            for k, v in pairs(value) do
                local keyStr = '"' .. jsonEscapeString(tostring(k)) .. '"'
                table.insert(parts, keyStr .. ":" .. serializeToJson(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return '"' .. tostring(value) .. '"'
    end
end

-----------------------------------------------------------
-- JSON Parser (minimal recursive descent)
-----------------------------------------------------------

local parseValue -- forward declaration

--- Skip whitespace in the JSON string starting from position pos
--- @param str string
--- @param pos number
--- @return number newPos
local function skipWhitespace(str, pos)
    while pos <= #str do
        local c = str:sub(pos, pos)
        if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
            pos = pos + 1
        else
            break
        end
    end
    return pos
end

--- Parse a JSON string value starting from position pos (after opening quote)
--- @param str string
--- @param pos number Position of the opening quote
--- @return string value, number newPos
local function parseString(str, pos)
    -- pos should be at the opening "
    pos = pos + 1  -- skip opening quote
    local result = {}
    while pos <= #str do
        local c = str:sub(pos, pos)
        if c == '"' then
            return table.concat(result), pos + 1
        elseif c == '\\' then
            pos = pos + 1
            local escaped = str:sub(pos, pos)
            if escaped == '"' then
                table.insert(result, '"')
            elseif escaped == '\\' then
                table.insert(result, '\\')
            elseif escaped == '/' then
                table.insert(result, '/')
            elseif escaped == 'n' then
                table.insert(result, '\n')
            elseif escaped == 'r' then
                table.insert(result, '\r')
            elseif escaped == 't' then
                table.insert(result, '\t')
            elseif escaped == 'b' then
                table.insert(result, '\b')
            elseif escaped == 'f' then
                table.insert(result, '\f')
            elseif escaped == 'u' then
                -- Unicode escape: skip 4 hex digits, insert placeholder
                local hex = str:sub(pos + 1, pos + 4)
                pos = pos + 4
                local codepoint = tonumber(hex, 16)
                if codepoint and codepoint < 128 then
                    table.insert(result, string.char(codepoint))
                else
                    table.insert(result, "?")
                end
            else
                table.insert(result, escaped)
            end
            pos = pos + 1
        else
            table.insert(result, c)
            pos = pos + 1
        end
    end
    return table.concat(result), pos
end

--- Parse a JSON number starting from position pos
--- @param str string
--- @param pos number
--- @return number value, number newPos
local function parseNumber(str, pos)
    local startPos = pos
    -- Optional minus
    if str:sub(pos, pos) == '-' then
        pos = pos + 1
    end
    -- Digits
    while pos <= #str and str:sub(pos, pos):match('[0-9]') do
        pos = pos + 1
    end
    -- Optional decimal
    if pos <= #str and str:sub(pos, pos) == '.' then
        pos = pos + 1
        while pos <= #str and str:sub(pos, pos):match('[0-9]') do
            pos = pos + 1
        end
    end
    -- Optional exponent
    if pos <= #str and (str:sub(pos, pos) == 'e' or str:sub(pos, pos) == 'E') then
        pos = pos + 1
        if pos <= #str and (str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-') then
            pos = pos + 1
        end
        while pos <= #str and str:sub(pos, pos):match('[0-9]') do
            pos = pos + 1
        end
    end
    local numStr = str:sub(startPos, pos - 1)
    return tonumber(numStr), pos
end

--- Parse a JSON array starting from position pos (at '[')
--- @param str string
--- @param pos number
--- @return table value, number newPos
local function parseArray(str, pos)
    local arr = {}
    pos = pos + 1  -- skip '['
    pos = skipWhitespace(str, pos)

    if pos <= #str and str:sub(pos, pos) == ']' then
        return arr, pos + 1
    end

    while pos <= #str do
        local value
        value, pos = parseValue(str, pos)
        table.insert(arr, value)

        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = pos + 1
            pos = skipWhitespace(str, pos)
        else
            break
        end
    end
    return arr, pos
end

--- Parse a JSON object starting from position pos (at '{')
--- @param str string
--- @param pos number
--- @return table value, number newPos
local function parseObject(str, pos)
    local obj = {}
    pos = pos + 1  -- skip '{'
    pos = skipWhitespace(str, pos)

    if pos <= #str and str:sub(pos, pos) == '}' then
        return obj, pos + 1
    end

    while pos <= #str do
        pos = skipWhitespace(str, pos)
        -- Parse key (must be string)
        local key
        key, pos = parseString(str, pos)

        pos = skipWhitespace(str, pos)
        -- Expect ':'
        if str:sub(pos, pos) == ':' then
            pos = pos + 1
        end
        pos = skipWhitespace(str, pos)

        -- Parse value
        local value
        value, pos = parseValue(str, pos)
        obj[key] = value

        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = pos + 1
            pos = skipWhitespace(str, pos)
        else
            break
        end
    end
    return obj, pos
end

--- Parse any JSON value starting from position pos
--- @param str string
--- @param pos number
--- @return any value, number newPos
parseValue = function(str, pos)
    pos = skipWhitespace(str, pos)
    if pos > #str then
        return nil, pos
    end

    local c = str:sub(pos, pos)

    if c == '"' then
        return parseString(str, pos)
    elseif c == '{' then
        return parseObject(str, pos)
    elseif c == '[' then
        return parseArray(str, pos)
    elseif c == 't' then
        -- true
        pos = pos + 4
        return true, pos
    elseif c == 'f' then
        -- false
        pos = pos + 5
        return false, pos
    elseif c == 'n' then
        -- null
        pos = pos + 4
        return nil, pos
    elseif c == '-' or c:match('[0-9]') then
        return parseNumber(str, pos)
    end

    return nil, pos + 1
end

--- Parse a complete JSON string into a Lua table
--- @param jsonStr string
--- @return table|nil
local function parseJson(jsonStr)
    if not jsonStr or jsonStr == "" then
        return nil
    end
    local ok, result = pcall(function()
        local value, _ = parseValue(jsonStr, 1)
        return value
    end)
    if ok then
        return result
    else
        VehicleClaim.log("[Database] ERROR: Failed to parse JSON: " .. tostring(result))
        return nil
    end
end

-----------------------------------------------------------
-- In-Memory Database & File I/O
-----------------------------------------------------------

local database = {}   -- In-memory cache: { [vehicleHash] = vehicleEntry }
local isDirty = false  -- Flag: database has unsaved changes
local isLoaded = false -- Flag: database has been loaded from disk

--- Get the database filename from config
--- @return string
local function getDatabaseFilename()
    if VehicleClaim.Sync and VehicleClaim.Sync.filename then
        return VehicleClaim.Sync.filename
    end
    return "VehicleClaimSystemDatabase.json"
end

--- Load the database from the JSON file on disk
--- Called once on module initialization
--- @return table The loaded database (or empty table if file doesn't exist/is invalid)
local function loadDatabase()
    local filename = getDatabaseFilename()
    VehicleClaim.log("[Database] Loading database from: " .. filename)

    local reader = getFileReader(filename, false)
    if not reader then
        VehicleClaim.log("[Database] No existing database file found, starting fresh")
        return {}
    end

    local lines = {}
    local line = reader:readLine()
    while line ~= nil do
        table.insert(lines, line)
        line = reader:readLine()
    end
    reader:close()

    local jsonStr = table.concat(lines, "\n")
    if jsonStr == "" then
        VehicleClaim.log("[Database] Database file is empty, starting fresh")
        return {}
    end

    local parsed = parseJson(jsonStr)
    if parsed and type(parsed) == "table" then
        local count = 0
        for _ in pairs(parsed) do
            count = count + 1
        end
        VehicleClaim.log("[Database] Loaded " .. count .. " vehicles from database")
        return parsed
    else
        VehicleClaim.log("[Database] WARNING: Could not parse database file, starting fresh")
        return {}
    end
end

--- Save the entire database to the JSON file on disk
--- Overwrites the existing file with the full serialized database
local function saveDatabase()
    if not isDirty then
        return
    end

    local filename = getDatabaseFilename()
    local jsonStr = serializeToJson(database)

    local writer = getFileWriter(filename, true, false)  -- createIfNull=true, append=false (overwrite)
    if not writer then
        VehicleClaim.log("[Database] ERROR: Could not open file for writing: " .. filename)
        return
    end

    writer:write(jsonStr)
    writer:close()

    isDirty = false

    local count = 0
    for _ in pairs(database) do
        count = count + 1
    end
    VehicleClaim.log("[Database] Saved " .. count .. " vehicles to database file")
end

-----------------------------------------------------------
-- Vehicle Item Inventory Extraction
-----------------------------------------------------------

--- Build a full item inventory snapshot from all vehicle containers
--- @param vehicle IsoVehicle
--- @return table Array of {fullType, count, container}
local function buildItemInventory(vehicle)
    local items = {}

    local partCount = vehicle:getPartCount()
    for i = 0, partCount - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            local container = part:getItemContainer()
            if container then
                local containerItems = container:getItems()
                if containerItems then
                    local containerName = part:getId() or "unknown"
                    for j = 0, containerItems:size() - 1 do
                        local item = containerItems:get(j)
                        if item then
                            table.insert(items, {
                                fullType = item:getFullType() or "unknown",
                                count = item:getCount() or 1,
                                container = containerName
                            })
                        end
                    end
                end
            end
        end
    end

    return items
end

-----------------------------------------------------------
-- Public API (registered on VehicleClaim module)
-----------------------------------------------------------

--- Update or create a vehicle entry in the car database
--- Called when a claimed vehicle is loaded or when a vehicle is first claimed
--- @param vehicle IsoVehicle
function VehicleClaim.updateCarDatabase(vehicle)
    if not isServer() then return end
    if not vehicle then return end

    -- Ensure database is loaded
    if not isLoaded then
        database = loadDatabase()
        isLoaded = true
    end

    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    if not vehicleHash then
        VehicleClaim.log("[Database] Cannot update: vehicle has no hash")
        return
    end

    -- Get claim data - only track claimed vehicles
    local claimData = VehicleClaim.getClaimData(vehicle)
    if not claimData then
        VehicleClaim.log("[Database] Skipping unclaimed vehicle: " .. vehicleHash)
        return
    end

    -- Build the vehicle entry
    local scriptName = "Unknown"
    local script = vehicle:getScript()
    if script then
        scriptName = script:getScriptObjectFullType() or "Unknown"
    end

    local steamId = string.format("%.0f", tonumber(claimData[VehicleClaim.OWNER_KEY])) or 0

    local entry = {
        vehicleHash = vehicleHash,
        ownerSteamID = steamId,
        ownerName = claimData[VehicleClaim.OWNER_NAME_KEY] or "",
        vehicleName = VehicleClaim.getVehicleName(vehicle) or "Unknown Vehicle",
        scriptName = scriptName,
        x = vehicle:getX(),
        y = vehicle:getY(),
        lastUpdated = string.format("%.0f", getTimestampMs()),
        items = buildItemInventory(vehicle)
    }

    -- Insert or replace the entry in the database
    database[vehicleHash] = entry
    isDirty = true

    VehicleClaim.log("[Database] Updated vehicle entry: " .. vehicleHash .. " (" .. scriptName .. ")")
end

--- Remove a vehicle entry from the car database
--- Called when a vehicle is unclaimed (release, remote release, contest, or admin clear)
--- @param vehicleHash string The vehicle hash to remove
function VehicleClaim.removeFromCarDatabase(vehicleHash)
    if not isServer() then return end
    if not vehicleHash then return end

    -- Ensure database is loaded
    if not isLoaded then
        database = loadDatabase()
        isLoaded = true
    end

    if database[vehicleHash] then
        database[vehicleHash] = nil
        isDirty = true
        VehicleClaim.log("[Database] Removed vehicle from database: " .. vehicleHash)
    else
        VehicleClaim.log("[Database] Vehicle not found in database for removal: " .. vehicleHash)
    end
end

--- Clear the entire car database
--- Called by admin clear all claims
function VehicleClaim.clearCarDatabase()
    if not isServer() then return end

    database = {}
    isDirty = true
    VehicleClaim.log("[Database] Entire car database cleared")
end

-----------------------------------------------------------
-- Periodic Flush & Server Shutdown Hook
-----------------------------------------------------------

--- Flush pending changes to disk (called periodically by timer)
local function onPeriodicFlush()
    if not isServer() then return end

    -- Ensure database is loaded on first tick
    if not isLoaded then
        database = loadDatabase()
        isLoaded = true
    end

    if isDirty then
        saveDatabase()
    end
end

--- Flush on server shutdown to avoid data loss
local function onServerShutdown()
    if not isServer() then return end

    VehicleClaim.log("[Database] Server shutting down - flushing database...")
    if isDirty then
        saveDatabase()
    end
    VehicleClaim.log("[Database] Shutdown flush complete")
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Periodic flush every ~60 seconds (in-game minute)
Events.EveryOneMinute.Add(onPeriodicFlush)

-- Flush on server shutdown / game exit to avoid data loss
if Events.OnServerShutdown then
    Events.OnServerShutdown.Add(onServerShutdown)
end

VehicleClaim.log("[Database] VehicleClaim_ServerDatabase module loaded")
