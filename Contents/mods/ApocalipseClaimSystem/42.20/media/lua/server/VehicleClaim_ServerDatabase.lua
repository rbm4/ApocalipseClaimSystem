--[[
    VehicleClaim_ServerDatabase.lua
    Server-side vehicle database export module

    GlobalModData is the source of truth for which cars are claimed.
    This module maintains a throttled filesystem projection for external
    services:
      - VehicleClaimSystemDatabase/index.json lists currently claimed cars
      - VehicleClaimSystemDatabase/cars/<vehicleHash>.json stores snapshots
      - VehicleClaimSystemDatabase/deleted/<vehicleHash>.json stores tombstones

    Vehicle item contents are captured only when the vehicle is loaded, using
    the same pattern as the older monolithic JSON database.
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
    if type(t) ~= "table" then
        return false
    end
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
    pos = pos + 1 -- skip opening quote
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
    pos = pos + 1 -- skip '['
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
    pos = pos + 1 -- skip '{'
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
-- In-Memory Database & Throttled File I/O
-----------------------------------------------------------

local EXPORT_VERSION = 2
local FLUSH_INTERVAL_MS = 30 * 60 * 1000
local OPS_PER_TICK = 1

local database = {} -- In-memory cache: { [vehicleHash] = vehicleEntry }
local isLoaded = false
local indexDirty = false
local dirtyCars = {}
local deletedCars = {}
local pendingOps = {}
local nextFlushAtMs = 0
local flushInProgress = false

--- Get the legacy database filename from config
--- @return string
local function getLegacyDatabaseFilename()
    if VehicleClaim.Sync and VehicleClaim.Sync.filename then
        return VehicleClaim.Sync.filename
    end
    return "VehicleClaimSystemDatabase.json"
end

--- Get the export directory from the configured legacy filename
--- @return string
local function getDatabaseDirectory()
    local filename = getLegacyDatabaseFilename()
    local dir = filename:gsub("%.json$", "")
    if dir == "" then
        return "VehicleClaimSystemDatabase"
    end
    return dir
end

--- Sanitize a vehicle hash for use as a relative filename
--- @param vehicleHash string
--- @return string
local function getSafeVehicleFilename(vehicleHash)
    return tostring(vehicleHash):gsub("[^%w%._%-]", "_")
end

local function getIndexFilename()
    return getDatabaseDirectory() .. "/index.json"
end

local function getCarFilename(vehicleHash)
    return getDatabaseDirectory() .. "/cars/" .. getSafeVehicleFilename(vehicleHash) .. ".json"
end

local function getDeletedFilename(vehicleHash)
    return getDatabaseDirectory() .. "/deleted/" .. getSafeVehicleFilename(vehicleHash) .. ".json"
end

--- Read a JSON file from the Lua cache directory
--- @param filename string
--- @return table|nil
local function readJsonFile(filename)
    local reader = getFileReader(filename, false)
    if not reader then
        return nil
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
        return nil
    end

    return parseJson(jsonStr)
end

--- Write a JSON file to the Lua cache directory
--- @param filename string
--- @param data table
--- @return boolean
local function writeJsonFile(filename, data)
    local writer = getFileWriter(filename, true, false)
    if not writer then
        VehicleClaim.log("[Database] ERROR: Could not open file for writing: " .. filename)
        return false
    end

    writer:write(serializeToJson(data))
    writer:close()
    return true
end

--- Read the global claim registry without changing its shape
--- @return table
local function getGlobalRegistry()
    local globalModData = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    if not globalModData.claims then
        globalModData.claims = {}
    end
    return globalModData.claims
end

local function countEntries(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

--- Convert the in-memory database to a compact index for external readers
--- @return table
local function buildIndex()
    local cars = {}
    local count = 0

    for vehicleHash, entry in pairs(database) do
        count = count + 1
        cars[vehicleHash] = {
            vehicleHash = vehicleHash,
            ownerSteamID = entry.ownerSteamID or "",
            ownerName = entry.ownerName or "",
            vehicleName = entry.vehicleName or "Unknown Vehicle",
            scriptName = entry.scriptName or "Unknown",
            x = entry.x or 0,
            y = entry.y or 0,
            lastUpdated = entry.lastUpdated or "",
            path = getCarFilename(vehicleHash)
        }
    end

    return {
        version = EXPORT_VERSION,
        generatedAt = string.format("%.0f", getTimestampMs()),
        count = count,
        cars = cars
    }
end

--- Build a basic entry from the authoritative registry, preserving old snapshot fields
--- @param vehicleHash string
--- @param claimData table
--- @param previous table|nil
--- @return table
local function buildEntryFromRegistry(vehicleHash, claimData, previous)
    previous = previous or {}

    return {
        vehicleHash = vehicleHash,
        ownerSteamID = tostring(claimData.ownerSteamID or claimData[VehicleClaim.OWNER_KEY] or previous.ownerSteamID or ""),
        ownerName = claimData.ownerName or claimData[VehicleClaim.OWNER_NAME_KEY] or previous.ownerName or "",
        vehicleName = claimData.vehicleName or claimData[VehicleClaim.VEHICLE_NAME_KEY] or previous.vehicleName or "Unknown Vehicle",
        scriptName = previous.scriptName or "Unknown",
        x = claimData.x or previous.x or 0,
        y = claimData.y or previous.y or 0,
        lastUpdated = previous.lastUpdated or string.format("%.0f", getTimestampMs()),
        items = previous.items or {}
    }
end

--- Load existing snapshot data from the indexed export, if present
--- @return table
local function loadIndexedSnapshots()
    local snapshots = {}
    local index = readJsonFile(getIndexFilename())
    if not index or type(index.cars) ~= "table" then
        return snapshots
    end

    for _, car in pairs(index.cars) do
        if car and car.vehicleHash and car.path then
            local entry = readJsonFile(car.path)
            if entry and type(entry) == "table" then
                snapshots[car.vehicleHash] = entry
            end
        end
    end

    return snapshots
end

--- Load legacy monolithic JSON snapshots for one-time migration
--- @return table
local function loadLegacySnapshots()
    local parsed = readJsonFile(getLegacyDatabaseFilename())
    if parsed and type(parsed) == "table" then
        return parsed
    end
    return {}
end

--- Load the in-memory database from GlobalModData, preserving old item snapshots
--- @return table
local function loadDatabase()
    VehicleClaim.log("[Database] Loading export database from GlobalModData registry")

    local registry = getGlobalRegistry()
    local indexedSnapshots = loadIndexedSnapshots()
    local legacySnapshots = loadLegacySnapshots()
    local loaded = {}

    for vehicleHash, claimData in pairs(registry) do
        local previous = indexedSnapshots[vehicleHash] or legacySnapshots[vehicleHash]
        loaded[vehicleHash] = buildEntryFromRegistry(vehicleHash, claimData or {}, previous)
        dirtyCars[vehicleHash] = true
    end

    indexDirty = true
    VehicleClaim.log("[Database] Prepared " .. countEntries(loaded) .. " claimed vehicles for indexed export")
    return loaded
end

local function ensureDatabaseLoaded()
    if not isLoaded then
        database = loadDatabase()
        isLoaded = true
    end
end

local function enqueueOp(op)
    table.insert(pendingOps, op)
end

local function enqueueIndexWrite()
    enqueueOp({
        type = "index"
    })
end

local function enqueueCarWrite(vehicleHash)
    enqueueOp({
        type = "car",
        vehicleHash = vehicleHash
    })
end

local function enqueueDeleteWrite(vehicleHash)
    enqueueOp({
        type = "delete",
        vehicleHash = vehicleHash
    })
end

--- Sync the in-memory cache with the authoritative registry before exporting
local function mirrorRegistryIntoDatabase()
    local registry = getGlobalRegistry()

    for vehicleHash, _ in pairs(database) do
        if not registry[vehicleHash] then
            database[vehicleHash] = nil
            deletedCars[vehicleHash] = true
            indexDirty = true
        end
    end

    for vehicleHash, claimData in pairs(registry) do
        if not database[vehicleHash] then
            database[vehicleHash] = buildEntryFromRegistry(vehicleHash, claimData or {}, nil)
            dirtyCars[vehicleHash] = true
            indexDirty = true
        else
            local entry = database[vehicleHash]
            local beforeOwner = entry.ownerSteamID
            entry.ownerSteamID = tostring(claimData.ownerSteamID or claimData[VehicleClaim.OWNER_KEY] or entry.ownerSteamID or "")
            entry.ownerName = claimData.ownerName or claimData[VehicleClaim.OWNER_NAME_KEY] or entry.ownerName or ""
            entry.vehicleName = claimData.vehicleName or claimData[VehicleClaim.VEHICLE_NAME_KEY] or entry.vehicleName or "Unknown Vehicle"
            entry.x = claimData.x or entry.x or 0
            entry.y = claimData.y or entry.y or 0
            if beforeOwner ~= entry.ownerSteamID then
                dirtyCars[vehicleHash] = true
            end
        end
    end
end

--- Build a throttled flush queue from the current memory snapshot
--- @param full boolean
--- @param reason string
local function requestDatabaseFlush(full, reason)
    if not isServer() then
        return
    end

    ensureDatabaseLoaded()
    mirrorRegistryIntoDatabase()

    for vehicleHash, _ in pairs(deletedCars) do
        enqueueDeleteWrite(vehicleHash)
    end
    deletedCars = {}

    for vehicleHash, _ in pairs(database) do
        if full or dirtyCars[vehicleHash] then
            enqueueCarWrite(vehicleHash)
        end
    end
    dirtyCars = {}

    if full or indexDirty then
        enqueueIndexWrite()
        indexDirty = false
    end

    flushInProgress = #pendingOps > 0
    nextFlushAtMs = getTimestampMs() + FLUSH_INTERVAL_MS

    if flushInProgress then
        VehicleClaim.log("[Database] Queued " .. tostring(#pendingOps) .. " export operations (" .. tostring(reason) .. ")")
    end
end

--- Execute one queued filesystem operation
--- @return boolean true if an operation was processed
local function processOnePendingOp()
    local op = table.remove(pendingOps, 1)
    if not op then
        flushInProgress = false
        return false
    end

    if op.type == "index" then
        writeJsonFile(getIndexFilename(), buildIndex())
    elseif op.type == "car" then
        local entry = database[op.vehicleHash]
        if entry then
            writeJsonFile(getCarFilename(op.vehicleHash), entry)
        end
    elseif op.type == "delete" then
        writeJsonFile(getDeletedFilename(op.vehicleHash), {
            version = EXPORT_VERSION,
            vehicleHash = op.vehicleHash,
            deletedAt = string.format("%.0f", getTimestampMs())
        })
    end

    flushInProgress = #pendingOps > 0
    return true
end

local function drainPendingOps()
    while processOnePendingOp() do
    end
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
    if not isServer() then
        return
    end
    if not vehicle then
        return
    end

    ensureDatabaseLoaded()

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

    local ownerSteamID = claimData[VehicleClaim.OWNER_KEY] or ""
    local steamId = tonumber(ownerSteamID) and string.format("%.0f", tonumber(ownerSteamID)) or tostring(ownerSteamID)

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

    -- Insert or replace the entry in memory. Disk export happens in throttled flushes.
    database[vehicleHash] = entry
    dirtyCars[vehicleHash] = true
    indexDirty = true

    VehicleClaim.log("[Database] Updated vehicle entry: " .. vehicleHash .. " (" .. scriptName .. ")")
end

--- Remove a vehicle entry from the car database
--- Called when a vehicle is unclaimed (release, remote release, contest, or admin clear)
--- @param vehicleHash string The vehicle hash to remove
function VehicleClaim.removeFromCarDatabase(vehicleHash)
    if not isServer() then
        return
    end
    if not vehicleHash then
        return
    end

    ensureDatabaseLoaded()

    if database[vehicleHash] then
        database[vehicleHash] = nil
        deletedCars[vehicleHash] = true
        indexDirty = true
        VehicleClaim.log("[Database] Removed vehicle from database: " .. vehicleHash)
    else
        deletedCars[vehicleHash] = true
        indexDirty = true
        VehicleClaim.log("[Database] Vehicle not found in database for removal, queued tombstone: " .. vehicleHash)
    end
end

--- Clear the entire car database
--- Called by admin clear all claims
function VehicleClaim.clearCarDatabase()
    if not isServer() then
        return
    end

    ensureDatabaseLoaded()

    for vehicleHash, _ in pairs(database) do
        deletedCars[vehicleHash] = true
    end

    database = {}
    dirtyCars = {}
    indexDirty = true
    VehicleClaim.log("[Database] Entire car database cleared")
end

-----------------------------------------------------------
-- Periodic Flush & Server Shutdown Hook
-----------------------------------------------------------

--- Queue pending changes to disk (called periodically by timer)
local function onPeriodicFlush()
    if not isServer() then
        return
    end

    if getTimestampMs() < nextFlushAtMs then
        return
    end

    requestDatabaseFlush(false, "periodic")
end

--- Spread disk writes over frames
local function onTick()
    if not isServer() then
        return
    end

    if not isLoaded then
        ensureDatabaseLoaded()
        requestDatabaseFlush(true, "startup")
    end

    if not flushInProgress then
        return
    end

    for _ = 1, OPS_PER_TICK do
        if not processOnePendingOp() then
            break
        end
    end
end

--- Flush on server shutdown to avoid data loss
local function onServerShutdown()
    if not isServer() then
        return
    end

    VehicleClaim.log("[Database] Server shutting down - flushing database...")
    requestDatabaseFlush(false, "shutdown")
    drainPendingOps()
    VehicleClaim.log("[Database] Shutdown flush complete")
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Periodic queue check. Actual file writes are spread by OnTick.
Events.EveryOneMinute.Add(onPeriodicFlush)
Events.OnTick.Add(onTick)

-- Flush on server shutdown / game exit to avoid data loss
if Events.OnServerShutdown then
    Events.OnServerShutdown.Add(onServerShutdown)
end

VehicleClaim.log("[Database] VehicleClaim_ServerDatabase module loaded")
