-- Native export backend and legacy snapshot reader. No event handlers are installed here.
require "shared/VehicleClaim_Shared"
require "shared/VehicleClaim_Config"

local Native = { name = "native" }

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
        local value, pos = parseValue(jsonStr, 1)
        if skipWhitespace(jsonStr, pos) <= #jsonStr then error("Trailing JSON data") end
        return value
    end)
    if ok then
        return result
    else
        VehicleClaim.log("[Database] ERROR: Failed to parse JSON: " .. tostring(result))
        return nil
    end
end

local function directory()
    return (VehicleClaim.Sync.filename:gsub("%.json$", ""))
end

function Native.carPath(hash)
    return directory() .. "/cars/" .. tostring(hash):gsub("[^%w%._%-]", "_") .. ".txt"
end

local function read(filename)
    local reader = getFileReader(filename, false)
    if not reader then return nil end
    local lines, line = {}, reader:readLine()
    while line ~= nil do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    local text = table.concat(lines, "\n")
    if text == "" then return nil end
    local value = parseJson(text)
    if type(value) ~= "table" then error("Invalid export file " .. filename) end
    return value
end

local function write(filename, value)
    -- Encode before opening/truncating the destination.
    local text = serializeToJson(value)
    local writer = getFileWriter(filename, true, false)
    if not writer then return false end
    writer:write(text)
    writer:close()
    return true
end

function Native.readSnapshots(registry)
    local snapshots = {}
    local index = read(directory() .. "/index.txt")
    if index and type(index.cars) ~= "table" then error("Invalid native export index") end
    local legacy = read(VehicleClaim.Sync.filename) or {}
    for hash in pairs(registry) do
        local entry
        local indexed = index and index.cars[hash]
        if indexed then
            if indexed.vehicleHash ~= hash or indexed.path ~= Native.carPath(hash) then
                error("Invalid native export path for " .. hash)
            end
            entry = read(indexed.path)
            if not entry then error("Missing indexed export for " .. hash) end
        else
            entry = legacy[hash]
        end
        if entry then
            if entry.vehicleHash ~= hash then error("Invalid native snapshot for " .. hash) end
            -- A crash after release followed by a new claim can leave the old
            -- retirement marker indexed. It contains no usable item snapshot.
            if not entry.deletedAt then snapshots[hash] = entry end
        end
    end
    return snapshots
end

function Native:start(registry, callback)
    callback({ status = "OK", snapshots = Native.readSnapshots(registry), rewrite = true })
end

function Native:save(entry, callback)
    callback({ status = write(Native.carPath(entry.vehicleHash), entry) and "OK" or "FILE_ERROR" })
end

function Native:delete(hash, previous, callback)
    local archived = {}
    for key, value in pairs(previous or {}) do archived[key] = value end
    archived.version, archived.vehicleHash = 2, hash
    archived.deletedAt = string.format("%.0f", getTimestampMs())
    local filename = directory() .. "/deleted/" .. tostring(hash):gsub("[^%w%._%-]", "_") .. ".txt"
    local success = write(filename, archived)
    if success then
        -- The Lua file API has no unlink/rename operation. Retire the active
        -- payload after archiving it, leaving a small marker at its old path.
        success = write(Native.carPath(hash), {
            version = 2, vehicleHash = hash, deletedAt = archived.deletedAt
        })
    end
    callback({ status = success and "OK" or "FILE_ERROR" })
end

function Native:writeIndex(index, callback)
    callback({ status = write(directory() .. "/index.txt", index) and "OK" or "FILE_ERROR" })
end

return Native

